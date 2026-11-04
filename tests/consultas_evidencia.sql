-- Consultas de comprobación usadas para las evidencias
-- Uso, después de "inicial", "delta" y "procesar":
-- docker exec -i aurora_market_db psql -U aurora -d aurora_market < tests/consultas_evidencia.sql

\echo '## Registro de ejecuciones (control.ejecucion)'
SELECT id_ejecucion, fichero_origen, estado,
       to_char(fecha_inicio, 'YYYY-MM-DD HH24:MI:SS') AS inicio,
       filas_leidas, filas_insertadas, filas_actualizadas, filas_sin_cambios,
       filas_fusionadas, filas_corregidas, filas_rechazadas
FROM control.ejecucion
ORDER BY id_ejecucion;

\echo '## Rechazos (control.cuarentena)'
SELECT entidad, regla_id, count(*) AS registros
FROM control.cuarentena
GROUP BY entidad, regla_id
ORDER BY entidad, regla_id;

\echo '## Resultado en core'
SELECT (SELECT count(*) FROM core.cliente WHERE cliente_id > 0)          AS clientes,
       (SELECT count(*) FROM core.cliente_id_erp)                        AS ids_erp,
       (SELECT count(*) FROM core.cliente_version WHERE cliente_id > 0)  AS versiones_cliente,
       (SELECT count(*) FROM core.producto WHERE producto_id > 0)        AS productos,
       (SELECT count(*) FROM core.pedido)                                AS pedidos,
       (SELECT count(*) FROM core.pedido_estado_hist)                    AS historial_estados,
       (SELECT count(*) FROM core.linea_pedido)                          AS lineas;

SELECT (SELECT count(*) FROM core.pedido WHERE cliente_id = -1)          AS pedidos_cliente_desconocido,
       (SELECT count(*) FROM core.linea_pedido WHERE producto_id = -1)   AS lineas_producto_desconocido,
       (SELECT count(*) FROM core.linea_pedido WHERE cantidad_corregida) AS lineas_cantidad_corregida;

\echo '## Ejemplo de historial de estados (pedido que cambia en el delta)'
SELECT p.id_pedido_erp, e.codigo AS estado, h.valido_desde, h.valido_hasta
FROM core.pedido_estado_hist h
JOIN core.pedido p        ON p.pedido_id = h.pedido_id
JOIN core.estado_pedido e ON e.estado_id = h.estado_id
WHERE p.id_pedido_erp = 'PED0000052'
ORDER BY h.valido_desde;

\echo '## Ejemplo de historial de cliente (SCD2: cambio de consentimiento)'
SELECT m.id_cliente_erp, v.ciudad, v.consentimiento_marketing,
       v.valido_desde, v.valido_hasta, v.es_actual
FROM core.cliente_version v
JOIN core.cliente_id_erp m ON m.cliente_id = v.cliente_id
WHERE v.cliente_id = (SELECT cliente_id FROM core.cliente_id_erp
                      WHERE id_cliente_erp = 'C000037')  -- incluye su id fusionado
ORDER BY v.valido_desde, m.id_cliente_erp;

-- ---------------------------------------------------------------------
-- Procesamiento (consume)
-- ---------------------------------------------------------------------

\echo '## Reglas de los segmentos (consume.segmento)'
SELECT prioridad, nombre, criterio, accion_recomendada
FROM consume.segmento
ORDER BY prioridad;

\echo '## Ejemplo: Nuria Rubio Muñoz (C000784 + C005101 fusionados)'
SELECT c.num_pedidos, c.importe_total, c.ticket_medio,
       c.fecha_primera_compra, c.fecha_ultima_compra, c.recencia_dias,
       c.categoria_principal, c.canal_principal,
       r.r_score, r.f_score, r.m_score,
       c.segmento, c.consentimiento_marketing
FROM consume.cliente_360 c
JOIN core.cliente_id_erp m ON m.cliente_id = c.cliente_id AND m.id_cliente_erp = 'C000784'
LEFT JOIN consume.cliente_rfm r ON r.cliente_id = c.cliente_id AND r.fecha_calculo = c.fecha_calculo;

SELECT rc.ranking, p.nombre AS producto, p.categoria, rc.motivo
FROM consume.recomendacion rc
JOIN core.cliente_id_erp m  ON m.cliente_id = rc.cliente_id AND m.id_cliente_erp = 'C000784'
JOIN consume.dim_producto p ON p.producto_id = rc.producto_id
WHERE rc.fecha_calculo = (SELECT max(fecha_calculo) FROM consume.recomendacion)
ORDER BY rc.ranking;

SELECT count(*) AS nuria_en_audiencia
FROM consume.audiencia_campana a
JOIN core.cliente_id_erp m ON m.cliente_id = a.cliente_id AND m.id_cliente_erp = 'C000784';

\echo '## Muestra de la audiencia de campaña (consume.audiencia_campana)'
SELECT nombre_completo, email, pais, segmento,
       producto_recomendado, categoria_recomendada, consentimiento_marketing
FROM consume.audiencia_campana
ORDER BY md5(cliente_id::text)
LIMIT 8;

\echo '## Comprobaciones (deben dar 0)'
SELECT
  -- Nadie sin consentimiento explícito en la audiencia
  (SELECT count(*) FROM consume.audiencia_campana
    WHERE consentimiento_marketing IS NOT TRUE)                          AS audiencia_sin_permiso,
  -- No se recomienda un producto que el cliente ya ha comprado
  (SELECT count(*) FROM consume.recomendacion r
    WHERE r.fecha_calculo = (SELECT max(fecha_calculo) FROM consume.recomendacion)
      AND EXISTS (SELECT 1 FROM consume.fact_ventas f
                   WHERE f.cliente_id = r.cliente_id
                     AND f.producto_id = r.producto_id
                     AND f.es_venta_valida))                             AS recomendaciones_ya_compradas,
  -- El importe de la vista 360 cuadra con la tabla de hechos
  (SELECT coalesce(sum(importe_total), 0) FROM consume.cliente_360)
  - (SELECT coalesce(sum(importe_neto), 0) FROM consume.fact_ventas
      WHERE es_venta_valida AND cliente_id > 0)                          AS descuadre_360_vs_hechos;