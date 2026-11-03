"""
Aurora Market · Orquestador de la ingesta.

Uso:
    python ingesta.py inicial [--forzar]       # productos, clientes, pedidos y líneas (_erp)
    python ingesta.py delta   [--forzar]       # clientes, pedidos y líneas (_delta)
    python ingesta.py fichero RUTA [--forzar]  # un fichero suelto (entidad y tipo por el nombre)
    python ingesta.py resumen                  # últimas ejecuciones registradas
    python ingesta.py informe                  # informe de calidad antes / después
    python ingesta.py procesar                 # recalcula la capa de consumo (360, RFM, recomendaciones, audiencia)

Python solo hace tres cosas: calcular el hash del fichero, copiarlo a staging con
COPY y llamar a la función SQL de su entidad. Toda la transformación es SQL.

Por cada fichero:
  1. Se registra la ejecución en control.ejecucion (transacción propia).
  2. Si su hash ya se cargó correctamente, se marca como 'omitida' y se salta
     (salvo --forzar, que reprocesa para demostrar la idempotencia por registro).
  3. Copia a staging + carga en core + cierre de la ejecución, en UNA transacción:
     o se aplica todo o nada. Si falla, la ejecución queda 'fallida' con el error
     y se detienen los ficheros siguientes (dependen de este).

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

import psycopg

DATOS_DIR = Path(os.environ.get("DATOS_DIR", "/datos"))
SQL_DIR = Path(os.environ.get("SQL_DIR", "/app/sql"))


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
    """Aplica las funciones de carga, las vistas de calidad y el procesamiento (06 en adelante).
    Son re-ejecutables (CREATE OR REPLACE): siempre se usa la versión actual."""
    for script in sorted(SQL_DIR.glob("0[6-9]_*.sql")):
        conn.execute(script.read_text(encoding="utf-8"))
    conn.commit()


def procesar_consumo(conn) -> None:
    """Recalcula la capa de consumo: 360, RFM, recomendaciones y audiencia."""
    filas = conn.execute("SELECT * FROM consume.refrescar()").fetchall()
    conn.commit()
    print("Procesamiento de la capa de consumo:")
    for tabla, n in filas:
        print(f"  {tabla:<52} {'' if n is None else n:>8}")
    segmentos = conn.execute("""
        SELECT s.nombre, count(c.cliente_id), round(100.0 * count(c.cliente_id) / sum(count(c.cliente_id)) OVER (), 1),
               coalesce(round(sum(c.importe_total)), 0),
               count(a.cliente_id)
        FROM consume.segmento s
        LEFT JOIN consume.cliente_360 c ON c.segmento = s.nombre
        LEFT JOIN consume.audiencia_campana a ON a.cliente_id = c.cliente_id
              AND a.campana_id = (SELECT max(campana_id) FROM consume.audiencia_campana)
        GROUP BY s.nombre, s.prioridad ORDER BY s.prioridad""").fetchall()
    print(f"\n  {'segmento':<20} {'clientes':>9} {'%':>6} {'importe (€)':>12} {'en audiencia':>13}")
    for nombre, n, pct, imp, aud in segmentos:
        print(f"  {nombre:<20} {n:>9} {pct:>6} {imp:>12} {aud:>13}")


def informe(conn) -> None:
    """Informe de calidad: antes/después, reglas aplicadas, deduplicación y emails."""
    def tabla(titulo, cabecera, filas, anchos):
        print(f"\n## {titulo}")
        numericas = [bool(filas) and isinstance(v, int) for v in (filas[0] if filas else cabecera)]
        print("  ".join(f"{c:>{a}}" if n else f"{c:<{a}}" for c, a, n in zip(cabecera, anchos, numericas)))
        for f in filas:
            print("  ".join(f"{str(v):>{a}}" if n else f"{str(v):<{a}}" for v, a, n in zip(f, anchos, numericas)))

    print("## 1. Calidad antes (datos tal como llegaron) / después (core)")
    filas = conn.execute("""
        SELECT entidad, dimension, indicador, antes_ok, antes_total, antes_pct,
               despues_ok, despues_total, despues_pct
        FROM control.v_informe_calidad ORDER BY orden""").fetchall()
    print(f"{'entidad':<14} {'dimensión':<13} {'indicador':<64} {'antes':>22} {'después':>22}")
    for e, d, i, ao, at, ap, do, dt, dp in filas:
        print(f"{e:<14} {d:<13} {i:<64} {f'{ap}% ({ao}/{at})':>22} {f'{dp}% ({do}/{dt})':>22}")

    filas = conn.execute("""
        SELECT accion, regla_id, entidad, registros FROM control.v_resumen_reglas
        WHERE registros > 0
        ORDER BY CASE accion WHEN 'rechazar' THEN 1 WHEN 'corregir' THEN 2 ELSE 3 END, registros DESC""").fetchall()
    tabla("2. Registros afectados por cada regla (cargas no forzadas)",
          ["acción", "regla", "entidad", "registros"], filas, [10, 28, 14, 10])

    filas = conn.execute("""
        SELECT e.fichero_origen, count(*)
        FROM control.incidencia_calidad i JOIN control.ejecucion e USING (id_ejecucion)
        WHERE i.regla_id = 'CLI_DUPLICADO_FUSIONADO' AND NOT e.forzada
        GROUP BY 1 ORDER BY 1""").fetchall()
    tabla("3. Deduplicación de clientes (mismo nombre normalizado + teléfono)",
          ["fichero", "fichas fusionadas"], filas, [22, 18])
    total = conn.execute("""
        SELECT (SELECT count(*) FROM core.cliente WHERE cliente_id > 0),
               (SELECT count(*) FROM core.cliente_id_erp)""").fetchone()
    print(f"Resultado: {total[1]} ids del ERP -> {total[0]} clientes únicos.")
    filas = conn.execute("""
        SELECT f.id_cliente_erp, vf.nombre || ' ' || coalesce(vf.apellidos, ''),
               o.id_cliente_erp,
               (SELECT count(*) FROM core.pedido p WHERE p.cliente_id = f.cliente_id)
        FROM core.cliente_id_erp f
        JOIN core.cliente_id_erp o ON o.cliente_id = f.cliente_id AND o.motivo_asignacion = 'alta'
        JOIN core.cliente_version vf ON vf.cliente_id = f.cliente_id AND vf.es_actual
        WHERE f.motivo_asignacion = 'fusion_duplicado'
        ORDER BY f.id_cliente_erp LIMIT 5""").fetchall()
    tabla("3b. Ejemplos (la ficha fusionada se une a la más antigua)",
          ["id fusionado", "cliente", "id que prevalece", "pedidos totales"], filas, [14, 28, 18, 16])

    filas = conn.execute("""
        SELECT valor_original, valor_nuevo FROM control.incidencia_calidad
        WHERE regla_id = 'CLI_EMAIL_CORREGIDO'
          AND id_ejecucion IN (SELECT id_ejecucion FROM control.ejecucion WHERE NOT forzada)
        ORDER BY 1""").fetchall()
    tabla(f"4. Emails corregidos (espacio en lugar de @ y dominio habitual): {len(filas)}",
          ["original", "corregido"], filas[:5], [34, 34])


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
        ins, act, sin, corr, rech, fus = conn.execute(
            f"SELECT * FROM {ENTIDADES[entidad]['funcion']}(%s)", (id_ejecucion,)).fetchone()
        conn.execute("""
            UPDATE control.ejecucion
            SET estado = 'correcta', fecha_fin = now(), filas_leidas = %s, filas_insertadas = %s,
                filas_actualizadas = %s, filas_sin_cambios = %s, filas_corregidas = %s,
                filas_rechazadas = %s, filas_fusionadas = %s
            WHERE id_ejecucion = %s""", (leidas, ins, act, sin, corr, rech, fus, id_ejecucion))
        conn.commit()
        print(f"  {fichero.name:<26} leídas {leidas:>7} | insertadas {ins:>7} | actualizadas {act:>5} | "
              f"sin cambios {sin:>7} | fusionadas {fus:>4} | corregidas {corr:>6} | rechazadas {rech:>5}")
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
               filas_fusionadas, filas_corregidas, filas_rechazadas
        FROM control.ejecucion ORDER BY id_ejecucion DESC LIMIT %s""", (limite,)).fetchall()
    print(f"\n{'id':>4}  {'fichero':<26} {'estado':<9} {'inicio':<19} {'leídas':>7} {'insert.':>7} "
          f"{'actual.':>7} {'sin camb.':>9} {'fusion.':>7} {'correg.':>7} {'rechaz.':>7}")
    for f in reversed(filas):
        print(f"{f[0]:>4}  {f[1]:<26} {f[2]:<9} {f[3]:<19} " +
              " ".join(f"{('-' if v is None else v):>{w}}" for v, w in zip(f[4:], (7, 7, 7, 9, 7, 7, 7))))


def main() -> int:
    parser = argparse.ArgumentParser(description="Ingesta de los ficheros del ERP de Aurora Market")
    parser.add_argument("modo", choices=["inicial", "delta", "fichero", "resumen", "informe", "procesar"])
    parser.add_argument("ruta", nargs="?", help="ruta del fichero (modo 'fichero')")
    parser.add_argument("--forzar", action="store_true",
                        help="reprocesa aunque el fichero ya se haya cargado")
    args = parser.parse_args()

    with conectar() as conn:
        if args.modo == "resumen":
            resumen(conn, 50)
            return 0
        if args.modo == "informe":
            preparar_funciones(conn)
            informe(conn)
            return 0
        if args.modo == "procesar":
            preparar_funciones(conn)
            procesar_consumo(conn)
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