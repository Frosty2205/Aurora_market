-- Procesamiento y preparación para el negocio (capa de consume)
-- SELECT * FROM consume.refrescar();          -- tras cada carga

-- Hipótesis de negocio (documentadas también en el README):
--   H1. Solo cuentan como venta los pedidos con estado_pedido.cuenta_como_venta
--       (ENTREGADO). Configurable en core.estado_pedido sin tocar código.
--   H2. Pendientes, cancelados y devueltos no cuentan en importes ni frecuencia.
--       Las devoluciones son de pedido completo (no hay devoluciones parciales).
--   H3. Fecha de referencia = fecha del último pedido cargado (no "hoy"): el
--       resultado es reproducible.
--   H4. Periodo: todo el histórico disponible.
--   H5. Pedidos de cliente desconocido (-1): cuentan en los totales del panel
--       (fact_ventas) pero no en las métricas por cliente.
--   H6. Categoría predominante = la de más importe; canal predominante = el de
--       más pedidos (empates: el más reciente).
--   H7. Puntuaciones R, F y M de 1 a 5 por quintiles (percent_rank); los empates
--       reciben la misma puntuación.
--   H8. Recomendación: los 3 productos más vendidos (unidades) de la categoría
--       predominante que el cliente aún no ha comprado, activos y con precio.
--       Sin compras o sin candidatos suficientes: los más vendidos del catálogo.
--   H9. Audiencia: solo consentimiento explícito "sí" y email válido.

-- Cómo se refresca cada tabla:
--   dim_*                       upsert (nunca se vacían: los historiales apuntan a ellas)
--   fact_ventas, cliente_360    se reconstruyen enteras
--   cliente_rfm, recomendacion  una "foto" por fecha de referencia (se reemplaza si se repite)
--   audiencia_campana           una campaña por fecha de referencia (se reemplaza si se repite)

-- Ajustes de estructura (idempotentes)

-- Reglas de cada segmento en la propia tabla: cambiar un criterio = cambiar una fila.
-- Una condición NULL no se comprueba
-- Se asigna el primer segmento (por prioridad) cuyas condiciones se cumplen.
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS r_min             SMALLINT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS r_max             SMALLINT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS f_min             SMALLINT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS f_max             SMALLINT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS pedidos_max       INT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS recencia_max_dias INT;
ALTER TABLE consume.segmento ADD COLUMN IF NOT EXISTS es_rfm            BOOLEAN NOT NULL DEFAULT true;

-- Campos que pide el enunciado y que no estaban en el diseño inicial
ALTER TABLE consume.cliente_360       ADD COLUMN IF NOT EXISTS recencia_dias INT;
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS nombre_completo          VARCHAR(201);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS telefono                 VARCHAR(20);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS pais                     VARCHAR(60);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS producto_recomendado     VARCHAR(150);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS categoria_recomendada    VARCHAR(60);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS motivo_recomendacion     VARCHAR(200);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS accion_recomendada       VARCHAR(300);
ALTER TABLE consume.audiencia_campana ADD COLUMN IF NOT EXISTS consentimiento_marketing BOOLEAN;

INSERT INTO consume.segmento (segmento_id, codigo, nombre, descripcion, criterio, accion_recomendada, prioridad,
                              r_min, r_max, f_min, f_max, pedidos_max, recencia_max_dias, es_rfm) VALUES
    (1, 'CAMPEONES', 'Campeones', 'Compran a menudo y hace poco.', 'R >= 4 y F >= 4',
        'Fidelizar: novedades, acceso anticipado, programa VIP.', 1, 4, 5, 4, 5, NULL, NULL, true),
    (2, 'LEALES', 'Leales', 'Compran a menudo; su última compra no es tan reciente.', 'R = 3 y F >= 4',
        'Venta cruzada y programa de puntos.', 2, 3, 3, 4, 5, NULL, NULL, true),
    (3, 'NUEVOS', 'Nuevos', 'Una sola compra, en los últimos 90 días.', '1 pedido y recencia <= 90 días',
        'Bienvenida y incentivo para la segunda compra.', 3, NULL, NULL, NULL, NULL, 1, 90, true),
    (4, 'PROMETEDORES', 'Prometedores', 'Han comprado hace poco, pero con poca frecuencia.', 'R >= 4',
        'Aumentar la frecuencia con ofertas de su categoría favorita.', 4, 4, 5, NULL, NULL, NULL, NULL, true),
    (5, 'EN_RIESGO', 'En riesgo', 'Compraban a menudo y llevan tiempo sin hacerlo.', 'R <= 2 y F >= 3',
        'Reactivación con oferta personalizada.', 5, 1, 2, 3, 5, NULL, NULL, true),
    (6, 'HIBERNANDO', 'Hibernando', 'Pocas compras y hace tiempo.', 'R <= 2 y F <= 2',
        'Campaña de bajo coste o pausa de envíos.', 6, 1, 2, 1, 2, NULL, NULL, true),
    (7, 'ATENCION', 'Necesitan atención', 'Comportamiento intermedio.', 'Resto de clientes con compras',
        'Recordatorio con su categoría favorita.', 7, NULL, NULL, NULL, NULL, NULL, NULL, true),
    (8, 'SIN_COMPRAS', 'Sin compras', 'Clientes sin ningún pedido entregado.', '0 pedidos entregados',
        'Primera compra con los productos más vendidos.', 99, NULL, NULL, NULL, NULL, NULL, NULL, false)
ON CONFLICT (segmento_id) DO UPDATE SET
    codigo = EXCLUDED.codigo, nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion,
    criterio = EXCLUDED.criterio, accion_recomendada = EXCLUDED.accion_recomendada,
    prioridad = EXCLUDED.prioridad, r_min = EXCLUDED.r_min, r_max = EXCLUDED.r_max,
    f_min = EXCLUDED.f_min, f_max = EXCLUDED.f_max, pedidos_max = EXCLUDED.pedidos_max,
    recencia_max_dias = EXCLUDED.recencia_max_dias, es_rfm = EXCLUDED.es_rfm;

-- Función de refresco

DROP FUNCTION IF EXISTS consume.refrescar(DATE);

CREATE FUNCTION consume.refrescar(p_fecha_referencia DATE DEFAULT NULL)
RETURNS TABLE (tabla TEXT, filas BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    v_ref     DATE := coalesce(p_fecha_referencia, (SELECT max(fecha_pedido)::DATE FROM core.pedido));
    v_campana TEXT;
BEGIN
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'No hay pedidos cargados: ejecuta antes la ingesta';
    END IF;
    v_campana := 'GENERAL_' || to_char(v_ref, 'YYYYMMDD');

    -- Dimensiones (upsert)
    INSERT INTO consume.dim_canal (canal_id, codigo, nombre)
    SELECT canal_id, codigo, nombre FROM core.canal
    ON CONFLICT (canal_id) DO UPDATE SET codigo = EXCLUDED.codigo, nombre = EXCLUDED.nombre;

    INSERT INTO consume.dim_producto (producto_id, id_producto_erp, nombre, categoria, subcategoria,
                                      marca, precio_lista, coste, activo, fecha_actualizacion)
    SELECT p.producto_id, p.id_producto_erp, p.nombre, c.nombre, s.nombre, p.marca,
           p.precio_lista, p.coste, p.activo, now()
    FROM core.producto p
    JOIN core.subcategoria s USING (subcategoria_id)
    JOIN core.categoria c    USING (categoria_id)
    ON CONFLICT (producto_id) DO UPDATE SET
        id_producto_erp = EXCLUDED.id_producto_erp, nombre = EXCLUDED.nombre,
        categoria = EXCLUDED.categoria, subcategoria = EXCLUDED.subcategoria, marca = EXCLUDED.marca,
        precio_lista = EXCLUDED.precio_lista, coste = EXCLUDED.coste, activo = EXCLUDED.activo,
        fecha_actualizacion = now();

    INSERT INTO consume.dim_cliente (cliente_id, nombre, apellidos, nombre_completo, email, codigo_pais,
                                     pais, ciudad, fecha_alta, consentimiento_marketing, fecha_actualizacion)
    SELECT v.cliente_id, v.nombre, v.apellidos, trim(v.nombre || ' ' || coalesce(v.apellidos, '')),
           v.email, v.codigo_pais, pa.nombre, v.ciudad, c.fecha_alta, v.consentimiento_marketing, now()
    FROM core.cliente_version v
    JOIN core.cliente c USING (cliente_id)
    LEFT JOIN core.pais pa ON pa.codigo_pais = v.codigo_pais
    WHERE v.es_actual
    ON CONFLICT (cliente_id) DO UPDATE SET
        nombre = EXCLUDED.nombre, apellidos = EXCLUDED.apellidos, nombre_completo = EXCLUDED.nombre_completo,
        email = EXCLUDED.email, codigo_pais = EXCLUDED.codigo_pais, pais = EXCLUDED.pais,
        ciudad = EXCLUDED.ciudad, fecha_alta = EXCLUDED.fecha_alta,
        consentimiento_marketing = EXCLUDED.consentimiento_marketing, fecha_actualizacion = now();

    -- Hechos: una fila por línea de pedido
    TRUNCATE consume.fact_ventas;
    INSERT INTO consume.fact_ventas (pedido_id, num_linea, fecha_id, cliente_id, producto_id, canal_id,
                                     id_pedido_erp, estado_pedido, es_venta_valida, cantidad, precio_unitario,
                                     descuento_pct, importe_bruto, importe_descuento, importe_neto,
                                     coste_total, margen)
    SELECT l.pedido_id, l.num_linea,
           to_char(p.fecha_pedido, 'YYYYMMDD')::INT,
           p.cliente_id, l.producto_id, p.canal_id, p.id_pedido_erp, e.codigo, e.cuenta_como_venta,
           l.cantidad, l.precio_unitario, l.descuento_pct,
           round(l.cantidad * l.precio_unitario, 2),
           round(l.cantidad * l.precio_unitario, 2) - l.importe_linea,
           l.importe_linea,
           round(l.cantidad * pr.coste, 2),
           l.importe_linea - round(l.cantidad * pr.coste, 2)
    FROM core.linea_pedido l
    JOIN core.pedido p         USING (pedido_id)
    JOIN core.estado_pedido e  ON e.estado_id = p.estado_id
    JOIN core.producto pr      ON pr.producto_id = l.producto_id;

    -- Métricas por cliente (base de 360, RFM y recomendaciones)
    DROP TABLE IF EXISTS t_metricas;
    CREATE TEMP TABLE t_metricas ON COMMIT DROP AS
    WITH ventas AS (   -- pedidos válidos de clientes conocidos (H1, H2, H5)
        SELECT p.cliente_id, p.pedido_id, p.fecha_pedido, p.canal_id,
               coalesce(sum(l.importe_linea), 0) AS importe
        FROM core.pedido p
        JOIN core.estado_pedido e ON e.estado_id = p.estado_id AND e.cuenta_como_venta
        LEFT JOIN core.linea_pedido l USING (pedido_id)
        WHERE p.cliente_id > 0 AND p.fecha_pedido::DATE <= v_ref
        GROUP BY p.cliente_id, p.pedido_id, p.fecha_pedido, p.canal_id
    ),
    cat AS (           -- categoría predominante por importe (H6)
        SELECT DISTINCT ON (v.cliente_id) v.cliente_id, c.nombre AS categoria
        FROM ventas v
        JOIN core.linea_pedido l USING (pedido_id)
        JOIN core.producto pr    ON pr.producto_id = l.producto_id
        JOIN core.subcategoria s USING (subcategoria_id)
        JOIN core.categoria c    USING (categoria_id)
        WHERE l.producto_id > 0
        GROUP BY v.cliente_id, c.nombre
        ORDER BY v.cliente_id, sum(l.importe_linea) DESC, max(v.fecha_pedido) DESC
    ),
    can AS (           -- canal predominante por número de pedidos (H6)
        SELECT DISTINCT ON (v.cliente_id) v.cliente_id, c.nombre AS canal
        FROM ventas v JOIN core.canal c USING (canal_id)
        GROUP BY v.cliente_id, c.nombre
        ORDER BY v.cliente_id, count(*) DESC, max(v.fecha_pedido) DESC
    )
    SELECT cl.cliente_id,
           count(v.pedido_id)::INT                   AS num_pedidos,
           coalesce(sum(v.importe), 0)::NUMERIC(12,2) AS importe_total,
           min(v.fecha_pedido)::DATE                 AS primera_compra,
           max(v.fecha_pedido)::DATE                 AS ultima_compra,
           (v_ref - max(v.fecha_pedido)::DATE)       AS recencia_dias,
           max(cat.categoria)                        AS categoria,
           max(can.canal)                            AS canal,
           NULL::SMALLINT AS r, NULL::SMALLINT AS f, NULL::SMALLINT AS m, NULL::SMALLINT AS segmento_id
    FROM core.cliente cl
    LEFT JOIN ventas v USING (cliente_id)
    LEFT JOIN cat     USING (cliente_id)
    LEFT JOIN can     USING (cliente_id)
    WHERE cl.cliente_id > 0
    GROUP BY cl.cliente_id;

    -- Puntuaciones 1-5 por quintiles, solo entre clientes con compras (H7)
    UPDATE t_metricas t
    SET r = q.r, f = q.f, m = q.m
    FROM (SELECT cliente_id,
                 (5 - least(4, floor(5 * percent_rank() OVER (ORDER BY recencia_dias))))::SMALLINT AS r,
                 (1 + least(4, floor(5 * percent_rank() OVER (ORDER BY num_pedidos))))::SMALLINT   AS f,
                 (1 + least(4, floor(5 * percent_rank() OVER (ORDER BY importe_total))))::SMALLINT AS m
          FROM t_metricas WHERE num_pedidos > 0) q
    WHERE t.cliente_id = q.cliente_id;

    -- Segmento: el primero (por prioridad) cuyas reglas se cumplen
    UPDATE t_metricas t
    SET segmento_id = (
        SELECT s.segmento_id FROM consume.segmento s
        WHERE s.es_rfm
          AND (s.r_min IS NULL OR t.r >= s.r_min) AND (s.r_max IS NULL OR t.r <= s.r_max)
          AND (s.f_min IS NULL OR t.f >= s.f_min) AND (s.f_max IS NULL OR t.f <= s.f_max)
          AND (s.pedidos_max IS NULL OR t.num_pedidos <= s.pedidos_max)
          AND (s.recencia_max_dias IS NULL OR t.recencia_dias <= s.recencia_max_dias)
        ORDER BY s.prioridad LIMIT 1)
    WHERE t.num_pedidos > 0;

    UPDATE t_metricas SET segmento_id = (SELECT segmento_id FROM consume.segmento WHERE codigo = 'SIN_COMPRAS')
    WHERE num_pedidos = 0;

    -- RFM (foto por fecha de referencia)
    DELETE FROM consume.cliente_rfm WHERE fecha_calculo = v_ref;
    INSERT INTO consume.cliente_rfm (cliente_id, fecha_calculo, recencia_dias, frecuencia, valor_monetario,
                                     r_score, f_score, m_score, segmento_id)
    SELECT cliente_id, v_ref, recencia_dias, num_pedidos, importe_total, r, f, m, segmento_id
    FROM t_metricas WHERE num_pedidos > 0;

    UPDATE consume.dim_cliente d SET segmento_actual = s.nombre
    FROM t_metricas t JOIN consume.segmento s USING (segmento_id)
    WHERE d.cliente_id = t.cliente_id AND d.segmento_actual IS DISTINCT FROM s.nombre;

    -- Visión 360
    TRUNCATE consume.cliente_360;
    INSERT INTO consume.cliente_360 (cliente_id, num_pedidos, importe_total, ticket_medio,
                                     fecha_primera_compra, fecha_ultima_compra, recencia_dias,
                                     categoria_principal, canal_principal, segmento,
                                     consentimiento_marketing, fecha_calculo)
    SELECT t.cliente_id, t.num_pedidos, t.importe_total,
           round(t.importe_total / nullif(t.num_pedidos, 0), 2),
           t.primera_compra, t.ultima_compra, t.recencia_dias, t.categoria, t.canal, s.nombre,
           d.consentimiento_marketing, v_ref
    FROM t_metricas t
    JOIN consume.segmento s     USING (segmento_id)
    JOIN consume.dim_cliente d  USING (cliente_id);

    -- Recomendaciones (H8)
    DELETE FROM consume.recomendacion WHERE fecha_calculo = v_ref;

    DROP TABLE IF EXISTS t_populares;
    CREATE TEMP TABLE t_populares ON COMMIT DROP AS
    SELECT dp.producto_id, dp.nombre, dp.categoria, coalesce(sum(f.cantidad), 0) AS unidades
    FROM consume.dim_producto dp
    LEFT JOIN consume.fact_ventas f ON f.producto_id = dp.producto_id AND f.es_venta_valida
    WHERE dp.producto_id > 0 AND dp.activo AND dp.precio_lista IS NOT NULL
    GROUP BY dp.producto_id, dp.nombre, dp.categoria;

    INSERT INTO consume.recomendacion (cliente_id, fecha_calculo, ranking, producto_id, motivo, puntuacion)
    SELECT cliente_id, v_ref, ranking, producto_id, motivo, puntuacion
    FROM (
        SELECT c.cliente_id, c.producto_id, c.motivo, c.puntuacion,
               row_number() OVER (PARTITION BY c.cliente_id ORDER BY c.prioridad, c.unidades DESC, c.producto_id)::SMALLINT AS ranking
        FROM (
            SELECT DISTINCT ON (x.cliente_id, x.producto_id) x.*
            FROM (
                -- 1º: los más vendidos de su categoría predominante
                SELECT t.cliente_id, p.producto_id, p.unidades, 1 AS prioridad,
                       'Top ventas en ' || p.categoria || ', su categoría favorita' AS motivo,
                       round(p.unidades::NUMERIC / nullif(max(p.unidades) OVER (PARTITION BY p.categoria), 0), 4) AS puntuacion
                FROM t_metricas t JOIN t_populares p ON p.categoria = t.categoria
                UNION ALL
                -- 2º: los más vendidos del catálogo (sin compras o sin candidatos suficientes)
                SELECT t.cliente_id, p.producto_id, p.unidades, 2,
                       'Top ventas del catálogo',
                       round(p.unidades::NUMERIC / nullif(max(p.unidades) OVER (), 0), 4)
                FROM t_metricas t CROSS JOIN (SELECT * FROM t_populares ORDER BY unidades DESC, producto_id LIMIT 20) p
            ) x
            WHERE NOT EXISTS (   -- que aún no haya comprado
                SELECT 1 FROM consume.fact_ventas f
                WHERE f.cliente_id = x.cliente_id AND f.producto_id = x.producto_id AND f.es_venta_valida)
            ORDER BY x.cliente_id, x.producto_id, x.prioridad
        ) c
    ) r
    WHERE ranking <= 3;

    -- Audiencia de campaña (H9)
    DELETE FROM consume.audiencia_campana WHERE campana_id = v_campana;
    INSERT INTO consume.audiencia_campana (campana_id, cliente_id, fecha_generacion, nombre_completo, email,
                                           telefono, pais, segmento, accion_recomendada,
                                           producto_recomendado_id, producto_recomendado,
                                           categoria_recomendada, motivo_recomendacion, consentimiento_marketing)
    SELECT v_campana, d.cliente_id, v_ref, d.nombre_completo, d.email, v.telefono, d.pais, s.nombre,
           s.accion_recomendada, r.producto_id, dp.nombre, dp.categoria, r.motivo, d.consentimiento_marketing
    FROM consume.dim_cliente d
    JOIN core.cliente_version v    ON v.cliente_id = d.cliente_id AND v.es_actual
    JOIN t_metricas t              ON t.cliente_id = d.cliente_id
    JOIN consume.segmento s        ON s.segmento_id = t.segmento_id
    LEFT JOIN consume.recomendacion r ON r.cliente_id = d.cliente_id AND r.fecha_calculo = v_ref AND r.ranking = 1
    LEFT JOIN consume.dim_producto dp ON dp.producto_id = r.producto_id
    WHERE d.cliente_id > 0
      AND d.consentimiento_marketing IS TRUE   -- solo consentimiento explícito
      AND d.email IS NOT NULL;                 -- y contactable por correo

    RETURN QUERY
    SELECT 'fecha de referencia: ' || v_ref, NULL::BIGINT
    UNION ALL SELECT 'consume.fact_ventas',       count(*) FROM consume.fact_ventas
    UNION ALL SELECT 'consume.cliente_360',       count(*) FROM consume.cliente_360
    UNION ALL SELECT 'consume.cliente_rfm',       count(*) FROM consume.cliente_rfm WHERE fecha_calculo = v_ref
    UNION ALL SELECT 'consume.recomendacion',     count(*) FROM consume.recomendacion WHERE fecha_calculo = v_ref
    UNION ALL SELECT 'consume.audiencia_campana (' || v_campana || ')',
                     count(*) FROM consume.audiencia_campana WHERE campana_id = v_campana;
END $$;

COMMENT ON FUNCTION consume.refrescar(DATE) IS
    'Recalcula la capa de consume (dimensiones, hechos, 360, RFM, recomendaciones y audiencia). Re-ejecutable.';
