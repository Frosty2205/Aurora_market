# Aurora Market - Modelo de datos

Scripts DDL de la plataforma de datos de personalización comercial (PostgreSQL 16)

## Estructura

```
sql/
  00_esquemas.sql           Crea los 4 esquemas (capas)
  01_control.sql            Ejecuciones, mapeos, reglas de calidad, incidencias y cuarentena
  02_staging.sql            Espejo de los CSV (todo TEXT) + trazabilidad
  03_core.sql               Modelo normalizado: clientes (SCD2), productos, pedidos, líneas
  04_consumo.sql            Estrella (fact_ventas + dimensiones) y resultados analíticos
  05_datos_referencia.sql   Catálogos, mapeos, reglas, registros -1 y calendario
  06_funciones_ingesta.sql  Funciones SQL de carga staging -> core (una por entidad)
ingesta/
  ingesta.py                Orquestador: hash, COPY a staging, llamada a las funciones, registro
  Dockerfile                Imagen del proceso de ingesta (Python 3.12 + psycopg)
datos/                      Aquí van los 7 CSV del ERP
evidencias/
  evidencia_ingesta.txt     Salida de la carga inicial, delta, delta repetido y delta forzado
tests/
  test_restricciones.sql    20 pruebas de restricciones (se deshacen al terminar)
diagramas/
  core.dbml, consumo.dbml, completo.dbml   Para dbdiagram.io
docker-compose.yml
```

## Levantar la base de datos

Con Docker:

```bash
docker compose up -d
```

Al arrancar por primera vez, PostgreSQL ejecuta los scripts de `sql/` en orden.
Conexión: `localhost:5432`, base `aurora_market`, usuario y contraseña `aurora`

Para empezar de cero: `docker compose down -v && docker compose up -d`

Sin Docker, con un PostgreSQL ya instalado:

```bash
createdb aurora_market
for f in sql/*.sql; do psql -v ON_ERROR_STOP=1 -d aurora_market -f "$f"; done
```

Los scripts son re-ejecutables: lanzarlos dos veces no duplica nada

## Ingesta

Copia los 7 CSV en `datos/` y ejecuta:

```bash
docker compose run --rm ingesta inicial    # productos, clientes, pedidos y líneas (_erp)
docker compose run --rm ingesta delta      # clientes, pedidos y líneas (_delta)
docker compose run --rm ingesta resumen    # registro de ejecuciones
```

La primera vez construye la imagen del proceso. Otras opciones:

```bash
docker compose run --rm ingesta delta --forzar           # reprocesa aunque ya se haya cargado
docker compose run --rm ingesta fichero /datos/X.csv     # un fichero suelto
```

Cómo funciona por fichero, en orden de dependencias:

1. Registra la ejecución en `control.ejecucion` con el hash SHA-256 del fichero
2. Si ese hash ya se cargó correctamente, la marca como `omitida` y no hace nada más
3. Copia el fichero tal cual a `staging` con `COPY` (fila y huella de cada registro)
4. Llama a la función SQL de su entidad (`core.cargar_*`), que normaliza, valida, manda los
   rechazos a `control.cuarentena`, registra correcciones y marcas en
   `control.incidencia_calidad` y aplica los cambios en `core` (upsert, SCD2 de clientes,
   historial de estados de pedido)
5. Cierra la ejecución con sus contadores. Los pasos 3 a 5 van en una única transacción: si
   algo falla, se deshace el fichero, la ejecución queda `fallida` con el error y se detienen
   los ficheros que dependen de él

Idempotencia en tres niveles: fichero (hash), registro (comparación de atributos: sin cambios
no se escribe nada) y estado de pedido (solo se historifica si cambia). Evidencia en
`evidencias/evidencia_ingesta.txt`: tras repetir y forzar el delta, `core` queda idéntico

## Pruebas

Sobre una base de datos **sin datos cargados** (usa ids fijos):

```bash
docker exec -i aurora_market_db psql -U aurora -d aurora_market < tests/test_restricciones.sql
```

Comprueba que el modelo acepta los casos válidos (cliente/producto desconocido, cantidad
corregida, producto sin precio) y rechaza los inválidos (cantidad 0, descuento > 100 %,
duplicados, claves foráneas rotas, dos versiones actuales de un cliente, email mal formado,
fichero cargado dos veces, importes incoherentes en la tabla de hechos).

## Diagramas

Se generarón con dbdiagram.io.

## Decisiones principales

| Decisión | Motivo |
|---|---|
| PostgreSQL, 4 esquemas (staging, core, consumo, control) | Separar dato de origen, depurado y de consumo; trazabilidad |
| Clave sustituta + id del ERP con UNIQUE | Independencia del ERP, trazabilidad y base de los upserts |
| Cliente en 3 tablas (identidad, ids ERP, versiones SCD2) | Deduplicación sin perder ids y historial del consentimiento |
| Historial de estados de pedido | El delta solo cambia estados; no se pierde la evolución |
| Registro -1 para cliente y producto desconocidos | Son ventas reales; se reasignan cuando llega el dato |
| Cantidad 0 o negativa corregida a 1 solo si el importe del ERP lo confirma | Evidencia en los datos; el valor original se conserva |
| `importe_linea` y `cantidad_corregida` como columnas calculadas | Imposible guardar valores incoherentes |
| Tabla de mapeos para país, canal, estado y consentimiento | Normalización configurable; un país nuevo = insertar filas |
| Hash de fichero único por carga correcta | Idempotencia: un fichero repetido no se carga dos veces |
| Estrella a nivel de línea de pedido; dimensiones aplanadas | Máximo detalle y consultas sencillas para el panel |
| RFM y recomendaciones con fecha de cálculo en la clave | Historial de segmentos para medir migraciones entre ellos |
| Ingesta ELT: Python solo copia (COPY), la lógica es SQL sobre conjuntos | Escala a x100 y la lógica es portable a un warehouse o a dbt |
| Una transacción por fichero; reglas como consultas de conjunto | Un registro erróneo no para la carga; un fichero roto no deja datos a medias |
| Rechazos a cuarentena con la fila completa en JSON y su motivo | Se pueden revisar y reprocesar; nada se pierde |
| Hash de atributos para decidir si hay nueva versión de cliente | Solo cambios reales generan historial (los de formato no) |
