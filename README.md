# Aurora Market - Modelo de datos

Scripts DDL de la plataforma de datos de personalización comercial (PostgreSQL 16)

## Estructura

```
sql/
  00_esquemas.sql           Crea los 4 esquemas (capas)
  01_control.sql            Ejecuciones, mapeos, reglas de calidad, incidencias y cuarentena
  02_staging.sql            Espejo de los CSV (todo TEXT) + trazabilidad
  03_core.sql               Modelo normalizado: clientes (SCD2), productos, pedidos, líneas
  04_consume.sql            Estrella (fact_ventas + dimensiones) y resultados analíticos
  05_datos_referencia.sql   Catálogos, mapeos, reglas, registros -1 y calendario
  06_funciones_ingesta.sql  Funciones SQL de carga staging -> core (una por entidad)
ingesta/
  ingesta.py                Orquestador: hash, COPY a staging, llamada a las funciones, registro
  Dockerfile                Imagen del proceso de ingesta (Python 3.12 + psycopg)
datos/                      Aquí van los 7 CSV del ERP
evidencias/
  evidencia_ingesta.txt     Salida de la carga inicial, delta, delta repetido y delta forzado
  informe_calidad.txt       Calidad antes/después, reglas aplicadas, deduplicación y emails
  evidencia_procesamiento.txt   Resultado del procesamiento, segmentos, ejemplo y comprobaciones
tests/
  test_restricciones.sql    20 pruebas de restricciones (se deshacen al terminar)
diagramas/
  core.dbml, consume.dbml, completo.dbml   Para dbdiagram.io
  diagrama_logico_completo.png, diagrama_logico_consume.png, diagrama_logico_core.png   En versión imagen de lo que da de los dbml
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

## Calidad y deduplicación

Las reglas de calidad viven en `control.regla_calidad` (qué se comprueba, severidad y acción:
corregir, marcar o rechazar) y se aplican automáticamente en cada carga. Resultados:

- `control.cuarentena`: registros rechazados, con la fila completa en JSON y el motivo.
- `control.incidencia_calidad`: registros corregidos o marcados, con valor original y nuevo.
- `control.v_resumen_reglas`: cuántos registros ha afectado cada regla.
- `control.v_informe_calidad`: completitud, validez, unicidad, integridad y consistencia,
  antes (staging, tal como llegó) y después (core). Se recalcula al consultarla.

**Deduplicación de clientes.** Dos fichas son la misma persona si coinciden el nombre
normalizado (minúsculas, sin tildes, z = s, ñ = n) y el teléfono (últimos 9 dígitos). Se aplica
en cada carga, contra los clientes existentes (incluido su historial) y dentro del propio
fichero. Prevalece la ficha más antigua; la fusionada aporta sus pedidos, los datos que le
falten a la original y, si la tiene, la negativa de consentimiento (prudencia legal). Ambos ids
del ERP quedan en `core.cliente_id_erp` apuntando al mismo cliente (`fusion_duplicado`).
Resultado: 150 duplicados en la carga inicial y 6 en el delta, sin falsos positivos.

**Emails con un espacio en lugar de la @** (49): se corrigen si el dominio resultante es uno
de los habituales en los emails válidos (aparece al menos 10 veces). Si no, el email se deja
vacío (el cliente sigue existiendo, pero no es contactable por correo).

## Procesamiento (capa de consumo)

`docker compose run --rm ingesta procesar` ejecuta `consume.refrescar()`, que se puede lanzar
tras cada carga tantas veces como se quiera (mismo resultado).

| Resultado | Tabla | Cómo se calcula |
|---|---|---|
| Hechos de venta | `fact_ventas` | Una fila por línea de pedido, con importes bruto, descuento, neto, coste y margen |
| Visión 360 | `cliente_360` | Pedidos, importe, ticket medio, primera y última compra, recencia, categoría y canal predominantes, segmento |
| Segmentación RFM | `cliente_rfm` + `segmento` | Notas R, F y M de 1 a 5 por quintiles; segmento = primera regla de `segmento` que se cumple |
| Recomendaciones | `recomendacion` | 3 por cliente: los más vendidos de su categoría favorita que aún no ha comprado |
| Audiencia | `audiencia_campana` | Solo consentimiento "sí" y email válido, con contacto, país, segmento y recomendación |

**Hipótesis de negocio**

1. Solo cuentan como venta los pedidos **entregados** (configurable en `core.estado_pedido.cuenta_como_venta`).
2. Pendientes, cancelados y devueltos no cuentan en importes ni frecuencia. Los pendientes son
   de las 3 últimas semanas y el 29 % de los ya resueltos acabó cancelado. Las devoluciones son
   de pedido completo (las cantidades negativas eran errores, no devoluciones parciales).
3. La recencia se mide contra la fecha del último pedido cargado (14/10/2026), no contra "hoy":
   el resultado es reproducible.
4. Periodo: todo el histórico (octubre 2024 a octubre 2026).
5. Los pedidos de cliente desconocido (-1) cuentan en los totales, no en métricas por cliente.
6. Categoría predominante = la de más importe; canal predominante = el de más pedidos.
7. Notas RFM por quintiles entre los clientes con compras; los empates reciben la misma nota.
8. Segmentos (por orden): Campeones (R≥4, F≥4), Leales (R=3, F≥4), Nuevos (1 pedido en 90 días),
   Prometedores (R≥4), En riesgo (R≤2, F≥3), Hibernando (R≤2, F≤2), Necesitan atención (resto)
   y Sin compras. Las reglas están en la tabla `segmento`: cambiar un criterio es cambiar una fila.
9. Recomendación por afinidad de categoría, porque es explicable, se calcula en SQL y escala.
   Sin compras o sin candidatos suficientes: los más vendidos del catálogo. Evolución natural:
   co-compra ("quien compró X también compró Y").
10. Audiencia: solo consentimiento explícito; el consentimiento desconocido queda fuera.


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
| PostgreSQL, 4 esquemas (staging, core, consume, control) | Separar dato de origen, depurado y de consume; trazabilidad |
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
| Duplicado = nombre normalizado + teléfono | El email cambia con facilidad; el teléfono identifica a la persona. 156 casos, 0 falsos positivos |
| Deduplicar en cada carga, no al final | Si el delta cambia el teléfono, a posteriori ya no coincidirían |
| Prevalece la ficha más antigua; la otra aporta pedidos y huecos | La duplicada suele llevar erratas; los cambios posteriores entran por el historial |
| Consentimiento: si alguna ficha dice "no", es "no" | Prudencia ante el riesgo legal de contactar sin permiso | 
Venta = pedido entregado; recencia contra la fecha del último pedido | Métricas sin ventas dudosas y resultado reproducible |
| Reglas de segmento en una tabla | Marketing puede ajustar criterios sin tocar código |
| Recomendación por categoría favorita | Explicable y barata; la co-compra queda como evolución |
| Audiencia solo con consentimiento explícito y email | Cumplimiento: 2.514 de 5.120 clientes son contactables |
