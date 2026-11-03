"""
Aurora Market - Orquestador de la ingesta

Uso:
    python ingesta.py inicial [--forzar]       # productos, clientes, pedidos y líneas (_erp)
    python ingesta.py delta   [--forzar]       # clientes, pedidos y líneas (_delta)
    python ingesta.py fichero RUTA [--forzar]  # un fichero suelto (entidad y tipo por el nombre)
    python ingesta.py resumen                  # últimas ejecuciones registradas

Python solo hace tres cosas: calcular el hash del fichero, copiarlo a staging con
COPY y llamar a la función SQL de su entidad. Toda la transformación es SQL

Por cada fichero:
  1. Se registra la ejecución en control.ejecucion (transacción propia)
  2. Si su hash ya se cargó correctamente, se marca como 'omitida' y se salta
     (salvo --forzar, que reprocesa para demostrar la idempotencia por registro)
  3. Copia a staging + carga en core + cierre de la ejecución, en una transacción:
     Se aplica todo o nada. Si falla, la ejecución queda 'fallida' con el error
     y se detienen los ficheros siguientes (dependen de este)

Conexión: variables PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD.
Ficheros: carpeta indicada en DATOS_DIR (por defecto /datos).
"""

import argparse
import csv
import hashlib
import os
import sys
import time
from pathlib import Path

import psycopg # Librería para conectar Python con PostgreSQL

DATOS_DIR = Path(os.environ.get("DATOS_DIR", "/datos"))
SQL_FUNCIONES = Path(os.environ.get("SQL_FUNCIONES", "/app/sql/06_funciones_ingesta.sql"))

# Entidad -> columnas esperadas en el CSV y función SQL que la carga
ENTIDADES = {
    "productos": {
        "columnas": ["id_producto", "nombre", "categoria", "subcategoria", "marca",
                     "precio_lista", "coste", "activo"],
        "funcion": "core.cargar_productos",
    },
    "clientes": {
        "columnas": ["id_cliente", "nombre", "apellidos", "email", "telefono", "pais",
                     "ciudad", "fecha_alta", "consentimiento_marketing"],
        "funcion": "core.cargar_clientes",
    },
    "pedidos": {
        "columnas": ["id_pedido", "id_cliente", "fecha_pedido", "estado", "canal",
                     "importe_total_erp"],
        "funcion": "core.cargar_pedidos",
    },
    "lineas_pedido": {
        "columnas": ["id_pedido", "num_linea", "id_producto", "cantidad",
                     "precio_unitario", "descuento_pct"],
        "funcion": "core.cargar_lineas_pedido",
    },
}

# Orden de dependencias: un pedido necesita su cliente; una línea, su pedido y su producto
CARGAS = {
    "inicial": ["productos_erp.csv", "clientes_erp.csv", "pedidos_erp.csv", "lineas_pedido_erp.csv"],
    "delta": ["clientes_delta.csv", "pedidos_delta.csv", "lineas_pedido_delta.csv"],
}


def identificar(fichero: Path) -> tuple[str, str]:
    """Deduce entidad y tipo de carga del nombre: <entidad>_<erp|delta>.csv"""
    base = fichero.stem.lower()
    for entidad in sorted(ENTIDADES, key=len, reverse=True):
        if base.startswith(entidad + "_"):
            sufijo = base[len(entidad) + 1:]
            return entidad, "delta" if sufijo.startswith("delta") else "completa"
    raise ValueError(f"No se reconoce la entidad del fichero {fichero.name}")


def hash_fichero(fichero: Path) -> str:
    h = hashlib.sha256()
    with fichero.open("rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def conectar() -> psycopg.Connection:
    for intento in range(10):   # la base de datos puede estar arrancando
        try:
            return psycopg.connect(autocommit=False)
        except psycopg.OperationalError:
            if intento == 9:
                raise
            time.sleep(2)


def preparar_funciones(conn: psycopg.Connection) -> None:
    """Aplica las funciones de carga (CREATE OR REPLACE): siempre la versión actual"""
    conn.execute(SQL_FUNCIONES.read_text(encoding="utf-8"))
    conn.commit()


def copiar_a_staging(conn, id_ejecucion: int, fichero: Path, entidad: str) -> int:
    columnas = ENTIDADES[entidad]["columnas"]
    with fichero.open(encoding="utf-8-sig", newline="") as f:
        lector = csv.reader(f)
        cabecera = [c.strip().lower() for c in next(lector)]
        if cabecera != columnas:
            raise ValueError(f"Cabecera inesperada en {fichero.name}: {cabecera}")

        sql = (f"COPY staging.{entidad} (id_ejecucion, num_fila, fichero_origen, hash_fila, "
               f"{', '.join(columnas)}) FROM STDIN")
        filas = 0
        with conn.cursor().copy(sql) as copia:
            for num_fila, fila in enumerate(lector, start=2):   # fila 1 = cabecera
                if not any(campo.strip() for campo in fila):
                    continue                                    # líneas en blanco
                fila = (fila + [""] * len(columnas))[:len(columnas)]
                huella = hashlib.md5("\x1f".join(fila).encode("utf-8")).hexdigest()
                copia.write_row([id_ejecucion, num_fila, fichero.name, huella, *fila])
                filas += 1
    return filas


def procesar(conn, fichero: Path, forzar: bool) -> bool:
    entidad, tipo = identificar(fichero)
    huella = hash_fichero(fichero)

    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO control.ejecucion (fichero_origen, entidad, tipo_carga, hash_fichero, forzada)
            VALUES (%s, %s, %s, %s, %s) RETURNING id_ejecucion""",
            (fichero.name, entidad, tipo, huella, forzar))
        id_ejecucion = cur.fetchone()[0]

        cur.execute("""
            SELECT id_ejecucion FROM control.ejecucion
            WHERE hash_fichero = %s AND estado = 'correcta' AND NOT forzada""", (huella,))
        previa = cur.fetchone()
    conn.commit()

    if previa and not forzar:
        conn.execute("""
            UPDATE control.ejecucion SET estado = 'omitida', fecha_fin = now(),
                   mensaje_error = %s WHERE id_ejecucion = %s""",
            (f"Fichero ya cargado en la ejecución {previa[0]}", id_ejecucion))
        conn.commit()
        print(f"  {fichero.name:<26} omitido (ya cargado en la ejecución {previa[0]})")
        return True

    try:
        leidas = copiar_a_staging(conn, id_ejecucion, fichero, entidad)
        ins, act, sin, corr, rech = conn.execute(
            f"SELECT * FROM {ENTIDADES[entidad]['funcion']}(%s)", (id_ejecucion,)).fetchone()
        conn.execute("""
            UPDATE control.ejecucion
            SET estado = 'correcta', fecha_fin = now(), filas_leidas = %s, filas_insertadas = %s,
                filas_actualizadas = %s, filas_sin_cambios = %s, filas_corregidas = %s,
                filas_rechazadas = %s
            WHERE id_ejecucion = %s""", (leidas, ins, act, sin, corr, rech, id_ejecucion))
        conn.commit()
        print(f"  {fichero.name:<26} leídas {leidas:>7} | insertadas {ins:>7} | actualizadas {act:>5} | "
              f"sin cambios {sin:>7} | corregidas {corr:>6} | rechazadas {rech:>5}")
        return True
    except Exception as error:   # se deshace este fichero y se deja constancia
        conn.rollback()
        conn.execute("""
            UPDATE control.ejecucion SET estado = 'fallida', fecha_fin = now(), mensaje_error = %s
            WHERE id_ejecucion = %s""", (str(error)[:2000], id_ejecucion))
        conn.commit()
        print(f"  {fichero.name:<26} FALLIDA: {error}", file=sys.stderr)
        return False


def resumen(conn, limite: int = 10) -> None:
    filas = conn.execute("""
        SELECT id_ejecucion, fichero_origen, estado, to_char(fecha_inicio, 'YYYY-MM-DD HH24:MI:SS'),
               filas_leidas, filas_insertadas, filas_actualizadas, filas_sin_cambios,
               filas_corregidas, filas_rechazadas
        FROM control.ejecucion ORDER BY id_ejecucion DESC LIMIT %s""", (limite,)).fetchall()
    print(f"\n{'id':>4}  {'fichero':<26} {'estado':<9} {'inicio':<19} {'leídas':>7} {'insert.':>7} "
          f"{'actual.':>7} {'sin camb.':>9} {'correg.':>7} {'rechaz.':>7}")
    for f in reversed(filas):
        print(f"{f[0]:>4}  {f[1]:<26} {f[2]:<9} {f[3]:<19} " +
              " ".join(f"{('-' if v is None else v):>{w}}" for v, w in zip(f[4:], (7, 7, 7, 9, 7, 7))))


def main() -> int:
    parser = argparse.ArgumentParser(description="Ingesta de los ficheros del ERP de Aurora Market")
    parser.add_argument("modo", choices=["inicial", "delta", "fichero", "resumen"])
    parser.add_argument("ruta", nargs="?", help="ruta del fichero (modo 'fichero')")
    parser.add_argument("--forzar", action="store_true",
                        help="reprocesa aunque el fichero ya se haya cargado")
    args = parser.parse_args()

    with conectar() as conn:
        if args.modo == "resumen":
            resumen(conn, 50)
            return 0

        preparar_funciones(conn)
        if args.modo == "fichero":
            if not args.ruta:
                parser.error("indica la ruta del fichero")
            ficheros = [Path(args.ruta)]
        else:
            ficheros = [DATOS_DIR / nombre for nombre in CARGAS[args.modo]]

        faltan = [f.name for f in ficheros if not f.exists()]
        if faltan:
            print(f"No se encuentran: {', '.join(faltan)} (carpeta {DATOS_DIR})", file=sys.stderr)
            return 1

        print(f"Carga {args.modo}{' (forzada)' if args.forzar else ''}:")
        for fichero in ficheros:
            if not procesar(conn, fichero, args.forzar):
                print("Se detiene la carga: los ficheros siguientes dependen de este.", file=sys.stderr)
                resumen(conn, len(ficheros))
                return 1
        resumen(conn, len(ficheros))
    return 0


if __name__ == "__main__":
    sys.exit(main())
