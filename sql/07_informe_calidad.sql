-- Informe de calidad que mide el antes (datos tal como llegaron) y el después (core)
-- SELECT * FROM control.v_informe_calidad;
-- Antes -> filas del staging de las cargas correctas y no forzadas, tal cual llegaron en los ficheros
-- Después -> estado actual de core. Se recalcula solo al consultarla. Siempre refleja la última carga
-- Cada indicador tiene registros que cumplen / total y su porcentaje

CREATE OR REPLACE VIEW control.v_informe_calidad AS
WITH
ej AS (SELECT id_ejecucion FROM control.ejecucion WHERE estado = 'correcta' AND NOT forzada),
cli_antes AS (
    SELECT s.*, upper(trim(s.id_cliente)) AS id,
           control.clave_duplicado(s.nombre, s.apellidos, s.telefono) AS clave
    FROM staging.clientes s WHERE s.id_ejecucion IN (SELECT id_ejecucion FROM ej)
),
cli_despues AS (
    SELECT v.*, c.fecha_alta
    FROM core.cliente_version v JOIN core.cliente c USING (cliente_id)
    WHERE v.es_actual AND v.cliente_id > 0
),
ped_antes AS (
    SELECT s.* FROM staging.pedidos s WHERE s.id_ejecucion IN (SELECT id_ejecucion FROM ej)
),
lin_antes AS (
    SELECT s.* FROM staging.lineas_pedido s WHERE s.id_ejecucion IN (SELECT id_ejecucion FROM ej)
),
-- Cuadre de importes tal como llegaron
-- Para cada pedido, su última cabecera y las líneas del último fichero que lo trae (sin limpiar duplicados ni cantidades)
cuadre_antes AS (
    SELECT p.id, abs(p.importe - coalesce(l.suma, 0)) < 0.05 AS cuadra
    FROM (SELECT DISTINCT ON (upper(trim(id_pedido))) upper(trim(id_pedido)) AS id,
                 control.a_numero(importe_total_erp) AS importe
          FROM ped_antes ORDER BY upper(trim(id_pedido)), id_ejecucion DESC) p
    LEFT JOIN (SELECT id, sum(round(control.a_entero(cantidad) * control.a_numero(precio_unitario)
                                    * (1 - control.a_numero(descuento_pct) / 100), 2)) AS suma
               FROM (SELECT l.*, upper(trim(l.id_pedido)) AS id,
                            max(l.id_ejecucion) OVER (PARTITION BY upper(trim(l.id_pedido))) AS ultima
                     FROM lin_antes l) z
               WHERE id_ejecucion = ultima
               GROUP BY id) l ON l.id = p.id
),
cuadre_despues AS (
    SELECT p.pedido_id, abs(p.importe_total_erp - coalesce(sum(l.importe_linea), 0)) < 0.05 AS cuadra
    FROM core.pedido p LEFT JOIN core.linea_pedido l USING (pedido_id)
    GROUP BY p.pedido_id, p.importe_total_erp
),
indicadores AS (
    -- Clientes
    SELECT 1 AS orden, 'clientes' AS entidad, 'completitud' AS dimension,
           'Email informado y con formato válido' AS indicador,
           (SELECT count(*) FILTER (WHERE email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$') FROM cli_antes) AS antes_ok,
           (SELECT count(*) FROM cli_antes) AS antes_total,
           (SELECT count(*) FILTER (WHERE email IS NOT NULL) FROM cli_despues) AS despues_ok,
           (SELECT count(*) FROM cli_despues) AS despues_total
    UNION ALL
    SELECT 2, 'clientes', 'completitud', 'Consentimiento de marketing informado',
           (SELECT count(*) FILTER (WHERE trim(coalesce(consentimiento_marketing, '')) <> '') FROM cli_antes),
           (SELECT count(*) FROM cli_antes),
           (SELECT count(*) FILTER (WHERE consentimiento_marketing IS NOT NULL) FROM cli_despues),
           (SELECT count(*) FROM cli_despues)
    UNION ALL
    SELECT 3, 'clientes', 'validez', 'Fecha de alta en formato estándar (AAAA-MM-DD)',
           (SELECT count(*) FILTER (WHERE fecha_alta ~ '^\d{4}-\d{2}-\d{2}$') FROM cli_antes),
           (SELECT count(*) FROM cli_antes),
           (SELECT count(*) FILTER (WHERE fecha_alta IS NOT NULL) FROM cli_despues),
           (SELECT count(*) FROM cli_despues)
    UNION ALL
    SELECT 4, 'clientes', 'validez', 'País en código ISO de 2 letras',
           (SELECT count(*) FILTER (WHERE pais IN (SELECT codigo_pais FROM core.pais)) FROM cli_antes),
           (SELECT count(*) FROM cli_antes),
           (SELECT count(*) FILTER (WHERE codigo_pais IS NOT NULL) FROM cli_despues),
           (SELECT count(*) FROM cli_despues)
    UNION ALL
    SELECT 5, 'clientes', 'validez', 'Consentimiento en un valor único (sí/no)',
           (SELECT count(*) FILTER (WHERE consentimiento_marketing IN ('S', 'N')) FROM cli_antes),
           (SELECT count(*) FILTER (WHERE trim(coalesce(consentimiento_marketing, '')) <> '') FROM cli_antes),
           (SELECT count(*) FILTER (WHERE consentimiento_marketing IS NOT NULL) FROM cli_despues),
           (SELECT count(*) FILTER (WHERE consentimiento_marketing IS NOT NULL) FROM cli_despues)
    UNION ALL
    SELECT 6, 'clientes', 'unicidad', 'Fichas que corresponden a una persona distinta (sin duplicados)',
           (SELECT count(DISTINCT coalesce(clave, id)) FROM (SELECT DISTINCT ON (id) id, clave FROM cli_antes
                                                             ORDER BY id, id_ejecucion) primera_ficha),
           (SELECT count(DISTINCT id) FROM cli_antes),
           (SELECT count(DISTINCT coalesce(clave_duplicado, cliente_id::TEXT)) FROM cli_despues),
           (SELECT count(*) FROM cli_despues)
    -- Productos
    UNION ALL
    SELECT 7, 'productos', 'completitud', 'Precio de lista informado',
           (SELECT count(*) FILTER (WHERE trim(coalesce(precio_lista, '')) <> '') FROM staging.productos
            WHERE id_ejecucion IN (SELECT id_ejecucion FROM ej)),
           (SELECT count(*) FROM staging.productos WHERE id_ejecucion IN (SELECT id_ejecucion FROM ej)),
           (SELECT count(*) FILTER (WHERE precio_lista IS NOT NULL) FROM core.producto WHERE producto_id > 0),
           (SELECT count(*) FROM core.producto WHERE producto_id > 0)
    -- Pedidos
    UNION ALL
    SELECT 8, 'pedidos', 'validez', 'Fecha de pedido en formato estándar',
           (SELECT count(*) FILTER (WHERE fecha_pedido ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') FROM ped_antes),
           (SELECT count(*) FROM ped_antes),
           (SELECT count(*) FROM core.pedido), (SELECT count(*) FROM core.pedido)
    UNION ALL
    SELECT 9, 'pedidos', 'validez', 'Estado y canal con su valor estándar',
           (SELECT count(*) FILTER (WHERE estado IN (SELECT nombre FROM core.estado_pedido)
                                      AND canal  IN (SELECT nombre FROM core.canal)) FROM ped_antes),
           (SELECT count(*) FROM ped_antes),
           (SELECT count(*) FROM core.pedido), (SELECT count(*) FROM core.pedido)
    UNION ALL
    SELECT 10, 'pedidos', 'integridad', 'Pedidos de un cliente existente',
           (SELECT count(*) FILTER (WHERE upper(trim(id_cliente)) IN (SELECT id FROM cli_antes)) FROM ped_antes),
           (SELECT count(*) FROM ped_antes),
           (SELECT count(*) FILTER (WHERE cliente_id <> -1) FROM core.pedido),
           (SELECT count(*) FROM core.pedido)
    UNION ALL
    SELECT 11, 'pedidos', 'consistencia', 'Importe del pedido igual a la suma de sus líneas',
           (SELECT count(*) FILTER (WHERE cuadra) FROM cuadre_antes), (SELECT count(*) FROM cuadre_antes),
           (SELECT count(*) FILTER (WHERE cuadra) FROM cuadre_despues), (SELECT count(*) FROM cuadre_despues)
    -- Líneas de pedido
    UNION ALL
    SELECT 12, 'lineas_pedido', 'unicidad', 'Líneas sin duplicar (pedido + número de línea)',
           (SELECT count(DISTINCT (upper(trim(id_pedido)), trim(num_linea))) FROM lin_antes),
           (SELECT count(*) FROM lin_antes),
           (SELECT count(*) FROM core.linea_pedido), (SELECT count(*) FROM core.linea_pedido)
    UNION ALL
    SELECT 13, 'lineas_pedido', 'validez', 'Cantidad mayor que cero',
           (SELECT count(*) FILTER (WHERE control.a_entero(cantidad) > 0) FROM lin_antes),
           (SELECT count(*) FROM lin_antes),
           (SELECT count(*) FILTER (WHERE cantidad > 0) FROM core.linea_pedido),
           (SELECT count(*) FROM core.linea_pedido)
    UNION ALL
    SELECT 14, 'lineas_pedido', 'integridad', 'Líneas de un producto existente',
           (SELECT count(*) FILTER (WHERE upper(trim(id_producto)) IN
                (SELECT upper(trim(id_producto)) FROM staging.productos WHERE id_ejecucion IN (SELECT id_ejecucion FROM ej)))
            FROM lin_antes),
           (SELECT count(*) FROM lin_antes),
           (SELECT count(*) FILTER (WHERE producto_id <> -1) FROM core.linea_pedido),
           (SELECT count(*) FROM core.linea_pedido)
)
SELECT orden, entidad, dimension, indicador,
       antes_ok, antes_total,
       round(100.0 * antes_ok / nullif(antes_total, 0), 1)     AS antes_pct,
       despues_ok, despues_total,
       round(100.0 * despues_ok / nullif(despues_total, 0), 1) AS despues_pct
FROM indicadores;

COMMENT ON VIEW control.v_informe_calidad IS
    'Calidad antes (staging, tal como llegó) y después (core) por entidad y dimensión.';

-- Resumen de lo que se ha hecho con cada regla (todas las cargas no forzadas)
CREATE OR REPLACE VIEW control.v_resumen_reglas AS
SELECT r.regla_id, r.entidad, r.accion, r.severidad, r.descripcion,
       coalesce(i.n, 0) + coalesce(q.n, 0) AS registros
FROM control.regla_calidad r
LEFT JOIN (SELECT regla_id, count(*) AS n FROM control.incidencia_calidad
           WHERE id_ejecucion IN (SELECT id_ejecucion FROM control.ejecucion WHERE NOT forzada)
           GROUP BY 1) i USING (regla_id)
LEFT JOIN (SELECT regla_id, count(*) AS n FROM control.cuarentena
           WHERE id_ejecucion IN (SELECT id_ejecucion FROM control.ejecucion WHERE NOT forzada)
           GROUP BY 1) q USING (regla_id);
