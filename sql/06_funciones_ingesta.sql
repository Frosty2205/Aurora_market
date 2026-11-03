-- Funciones de carga staging -> core

-- Toda la transformación se hace en SQL, sobre el conjunto de filas de una
-- ejecución (no fila a fila). Python solo copia el fichero a staging y llama a
-- la función de su entidad, que devuelve los contadores de la ejecución.

-- Patrón de cada función:
--   1. Leer de staging la ejecución, normalizar y tipar en una tabla temporal.
--   2. Marcar los rechazos (primera regla incumplida) y llevarlos a cuarentena.
--   3. Registrar incidencias de lo que se corrige o se marca.
--   4. Clasificar cada fila: insertar / actualizar / sin_cambios.
--   5. Aplicar en core (upsert, SCD2, historial de estados).

-- Re-ejecutable: CREATE OR REPLACE / ON CONFLICT
-- El orquestador lo aplica en cada arranque, así funciona también sobre una base de datos ya creada.

-- Ajustes sobre objetos existentes (idempotentes)

-- Recarga forzada (--forzar): permite reprocesar un fichero ya cargado para
-- demostrar la idempotencia a nivel de registro.
ALTER TABLE control.ejecucion ADD COLUMN IF NOT EXISTS forzada BOOLEAN NOT NULL DEFAULT false;
DROP INDEX IF EXISTS control.ux_ejecucion_hash_correcta;
CREATE UNIQUE INDEX ux_ejecucion_hash_correcta
    ON control.ejecucion (hash_fichero) WHERE estado = 'correcta' AND NOT forzada;

-- Contador de clientes fusionados por deduplicación.
ALTER TABLE control.ejecucion ADD COLUMN IF NOT EXISTS filas_fusionadas INT CHECK (filas_fusionadas >= 0);

-- Clave de deduplicación guardada en cada versión del cliente (indexada): permite
-- reconocer un duplicado aunque coincida con un teléfono antiguo del historial.
CREATE EXTENSION IF NOT EXISTS unaccent;
ALTER TABLE core.cliente_version ADD COLUMN IF NOT EXISTS clave_duplicado VARCHAR(250);
CREATE INDEX IF NOT EXISTS ix_cliente_version_clave_dup
    ON core.cliente_version (clave_duplicado) WHERE clave_duplicado IS NOT NULL;

-- Las funciones de carga devuelven ahora 6 contadores (se añade 'fusionadas').
DROP FUNCTION IF EXISTS core.cargar_productos(BIGINT);
DROP FUNCTION IF EXISTS core.cargar_clientes(BIGINT);
DROP FUNCTION IF EXISTS core.cargar_pedidos(BIGINT);
DROP FUNCTION IF EXISTS core.cargar_lineas_pedido(BIGINT);

-- Reglas añadidas al diseñar la ingesta y la calidad.
INSERT INTO control.regla_calidad (regla_id, entidad, descripcion, severidad, accion) VALUES
    ('GEN_CLAVE_VACIA',             'general',       'Identificador obligatorio vacío.', 'alta', 'rechazar'),
    ('GEN_VALOR_INVALIDO',          'general',       'Campo obligatorio vacío, no convertible o fuera de rango.', 'alta', 'rechazar'),
    ('GEN_VALOR_DESCARTADO',        'general',       'Campo opcional no convertible; se guarda vacío.', 'media', 'marcar'),
    ('GEN_CLAVE_DUPLICADA_FICHERO', 'general',       'Identificador repetido dentro del mismo fichero; prevalece la última fila.', 'baja', 'rechazar'),
    ('CLI_EMAIL_VACIO',             'clientes',      'Cliente sin email: no es contactable por correo.', 'media', 'marcar'),
    ('PRD_PRECIO_VACIO',            'productos',     'Producto sin precio de lista.', 'media', 'marcar'),
    ('PRD_CATEGORIA_NUEVA',         'productos',     'Una carga incremental crea una categoría o subcategoría nueva (posible errata).', 'media', 'marcar'),
    ('PED_TRANSICION_INVALIDA',     'pedidos',       'Cambio de estado desde un estado final (cancelado o devuelto).', 'media', 'marcar'),
    ('LIN_PEDIDO_INEXISTENTE',      'lineas_pedido', 'Línea de un pedido que no existe en core.', 'alta', 'rechazar'),
    ('CLI_EMAIL_CORREGIDO',         'clientes',      'Email con un espacio en lugar de la @ y dominio habitual; se corrige.', 'media', 'corregir'),
    ('CLI_DUPLICADO_FUSIONADO',     'clientes',      'Ficha duplicada (mismo nombre normalizado y teléfono); se fusiona con la ficha más antigua.', 'alta', 'corregir')
ON CONFLICT (regla_id) DO UPDATE
    SET entidad = EXCLUDED.entidad, descripcion = EXCLUDED.descripcion,
        severidad = EXCLUDED.severidad, accion = EXCLUDED.accion;

-- Utilidades de conversión

CREATE OR REPLACE FUNCTION control.normalizar(p_dominio TEXT, p_valor TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT valor_normalizado FROM control.mapeo_valores
    WHERE dominio = p_dominio AND valor_origen = upper(trim(p_valor));
$$;

-- Acepta AAAA-MM-DD[ HH:MI[:SS]] y DD/MM/AAAA[ HH:MI[:SS]]. Devuelve NULL si no es válida.
CREATE OR REPLACE FUNCTION control.a_fecha(p_valor TEXT) RETURNS TIMESTAMP
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v TEXT := trim(p_valor);
BEGIN
    IF v ~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' THEN
        RETURN v::TIMESTAMP;
    ELSIF v ~ '^\d{2}/\d{2}/\d{4}( \d{2}:\d{2}(:\d{2})?)?$' THEN
        RETURN to_timestamp(v, CASE length(v) WHEN 10 THEN 'DD/MM/YYYY'
                                               WHEN 16 THEN 'DD/MM/YYYY HH24:MI'
                                               ELSE 'DD/MM/YYYY HH24:MI:SS' END)::TIMESTAMP;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;   -- p. ej. 31/02/2026
END $$;

CREATE OR REPLACE FUNCTION control.es_fecha_dmy(p_valor TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(trim(p_valor) ~ '^\d{2}/\d{2}/\d{4}', false) $$;

CREATE OR REPLACE FUNCTION control.a_numero(p_valor TEXT) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN trim(p_valor) ~ '^-?\d+(\.\d+)?$' THEN trim(p_valor)::NUMERIC END
$$;

CREATE OR REPLACE FUNCTION control.a_entero(p_valor TEXT) RETURNS INT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN trim(p_valor) ~ '^-?\d{1,9}$' THEN trim(p_valor)::INT END
$$;

-- Clave de deduplicación: nombre normalizado | últimos 9 dígitos del teléfono.
-- NULL si no hay teléfono utilizable (sin teléfono no se deduplica).
CREATE OR REPLACE FUNCTION control.clave_duplicado(p_nombre TEXT, p_apellidos TEXT, p_telefono TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) >= 9 THEN
        regexp_replace(translate(lower(public.unaccent(trim(coalesce(p_nombre, '')) || ' ' || trim(coalesce(p_apellidos, '')))),
                                 'zñ', 'sn'), '\s+', ' ', 'g')
        || '|' || right(regexp_replace(p_telefono, '\D', '', 'g'), 9)
    END
$$;

UPDATE core.cliente_version
SET clave_duplicado = control.clave_duplicado(nombre, apellidos, telefono)
WHERE clave_duplicado IS NULL AND cliente_id > 0;

-- Filas con al menos una corrección en la ejecución (para el contador filas_corregidas).
CREATE OR REPLACE FUNCTION control.contar_corregidas(p_id BIGINT, p_entidad TEXT) RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT count(DISTINCT i.clave_registro)::INT
    FROM control.incidencia_calidad i
    JOIN control.regla_calidad r USING (regla_id)
    WHERE i.id_ejecucion = p_id AND i.entidad = p_entidad AND r.accion = 'corregir';
$$;

-- Productos

CREATE OR REPLACE FUNCTION core.cargar_productos(p_id BIGINT)
RETURNS TABLE (insertadas INT, actualizadas INT, sin_cambios INT, corregidas INT, rechazadas INT, fusionadas INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_fichero TEXT;
    v_tipo    TEXT;
BEGIN
    SELECT e.fichero_origen, e.tipo_carga INTO v_fichero, v_tipo
    FROM control.ejecucion e WHERE e.id_ejecucion = p_id;

    DROP TABLE IF EXISTS t_prod;
    CREATE TEMP TABLE t_prod ON COMMIT DROP AS
    SELECT s.num_fila,
           upper(trim(s.id_producto))        AS id_erp,
           trim(s.nombre)                    AS nombre,
           trim(s.categoria)                 AS categoria,
           trim(s.subcategoria)              AS subcategoria,
           nullif(trim(s.marca), '')         AS marca,
           s.precio_lista                    AS precio_lista_txt,
           control.a_numero(s.precio_lista)  AS precio_lista,
           control.a_numero(s.coste)         AS coste,
           CASE trim(s.activo) WHEN '1' THEN true WHEN '0' THEN false END AS activo,
           to_jsonb(s) - ARRAY['id_ejecucion', 'fichero_origen', 'fecha_carga', 'hash_fila'] AS registro,
           NULL::TEXT AS regla, NULL::TEXT AS motivo,
           NULL::INT  AS subcategoria_id, NULL::TEXT AS accion
    FROM staging.productos s
    WHERE s.id_ejecucion = p_id;

    -- Rechazos
    UPDATE t_prod SET regla = 'GEN_CLAVE_VACIA', motivo = 'id_producto vacío'
    WHERE coalesce(id_erp, '') = '';
    UPDATE t_prod SET regla = 'GEN_VALOR_INVALIDO', motivo = 'nombre, categoría o subcategoría vacíos'
    WHERE regla IS NULL AND (coalesce(nombre, '') = '' OR coalesce(categoria, '') = '' OR coalesce(subcategoria, '') = '');
    UPDATE t_prod SET regla = 'GEN_VALOR_INVALIDO', motivo = 'coste no numérico o negativo'
    WHERE regla IS NULL AND (coste IS NULL OR coste < 0);
    UPDATE t_prod SET regla = 'GEN_VALOR_INVALIDO', motivo = 'precio_lista no numérico o negativo'
    WHERE regla IS NULL AND trim(coalesce(precio_lista_txt, '')) <> '' AND (precio_lista IS NULL OR precio_lista < 0);
    UPDATE t_prod SET regla = 'GEN_VALOR_INVALIDO', motivo = 'activo distinto de 0/1'
    WHERE regla IS NULL AND activo IS NULL;
    UPDATE t_prod t SET regla = 'GEN_CLAVE_DUPLICADA_FICHERO', motivo = 'id_producto repetido en el fichero'
    FROM (SELECT num_fila, row_number() OVER (PARTITION BY id_erp ORDER BY num_fila DESC) AS rn
          FROM t_prod WHERE regla IS NULL) d
    WHERE t.num_fila = d.num_fila AND d.rn > 1;

    INSERT INTO control.cuarentena (id_ejecucion, regla_id, entidad, fichero_origen, num_fila, registro, motivo)
    SELECT p_id, regla, 'productos', v_fichero, num_fila, registro, motivo FROM t_prod WHERE regla IS NOT NULL;

    -- Incidencias marcadas
    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original)
    SELECT p_id, 'PRD_PRECIO_VACIO', 'productos', id_erp, num_fila, 'precio_lista', precio_lista_txt
    FROM t_prod WHERE regla IS NULL AND precio_lista IS NULL;

    IF v_tipo = 'delta' THEN
        INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_nuevo)
        SELECT p_id, 'PRD_CATEGORIA_NUEVA', 'productos', t.id_erp, t.num_fila, 'categoria / subcategoria',
               t.categoria || ' / ' || t.subcategoria
        FROM t_prod t
        WHERE t.regla IS NULL
          AND NOT EXISTS (SELECT 1 FROM core.subcategoria sc JOIN core.categoria c USING (categoria_id)
                          WHERE c.nombre = t.categoria AND sc.nombre = t.subcategoria);
    END IF;

    -- Catálogo de categorías y subcategorías (el maestro de productos es la fuente)
    INSERT INTO core.categoria (nombre)
    SELECT DISTINCT categoria FROM t_prod WHERE regla IS NULL
    ON CONFLICT (nombre) DO NOTHING;

    INSERT INTO core.subcategoria (categoria_id, nombre)
    SELECT DISTINCT c.categoria_id, t.subcategoria
    FROM t_prod t JOIN core.categoria c ON c.nombre = t.categoria
    WHERE t.regla IS NULL
    ON CONFLICT (categoria_id, nombre) DO NOTHING;

    UPDATE t_prod t SET subcategoria_id = sc.subcategoria_id
    FROM core.categoria c JOIN core.subcategoria sc ON sc.categoria_id = c.categoria_id
    WHERE t.regla IS NULL AND c.nombre = t.categoria AND sc.nombre = t.subcategoria;

    -- Clasificación
    UPDATE t_prod t SET accion = CASE
            WHEN p.producto_id IS NULL THEN 'insertar'
            WHEN (p.nombre, p.subcategoria_id, p.marca, p.precio_lista, p.coste, p.activo)
                 IS DISTINCT FROM (t.nombre, t.subcategoria_id, t.marca, t.precio_lista, t.coste, t.activo)
                 THEN 'actualizar'
            ELSE 'sin_cambios' END
    FROM t_prod t2 LEFT JOIN core.producto p ON p.id_producto_erp = t2.id_erp
    WHERE t.num_fila = t2.num_fila AND t.regla IS NULL;

    INSERT INTO core.producto (id_producto_erp, nombre, subcategoria_id, marca, precio_lista, coste, activo, id_ejecucion)
    SELECT id_erp, nombre, subcategoria_id, marca, precio_lista, coste, activo, p_id
    FROM t_prod WHERE accion = 'insertar';

    UPDATE core.producto p
    SET nombre = t.nombre, subcategoria_id = t.subcategoria_id, marca = t.marca,
        precio_lista = t.precio_lista, coste = t.coste, activo = t.activo,
        fecha_actualizacion = now(), id_ejecucion = p_id
    FROM t_prod t
    WHERE t.accion = 'actualizar' AND p.id_producto_erp = t.id_erp;

    -- Líneas que esperaban este producto (estaban en -1)
    UPDATE core.linea_pedido l SET producto_id = p.producto_id
    FROM core.producto p
    WHERE l.producto_id = -1 AND p.id_producto_erp = l.id_producto_erp_origen;

    RETURN QUERY
    SELECT count(*) FILTER (WHERE accion = 'insertar')::INT,
           count(*) FILTER (WHERE accion = 'actualizar')::INT,
           count(*) FILTER (WHERE accion = 'sin_cambios')::INT,
           control.contar_corregidas(p_id, 'productos'),
           count(*) FILTER (WHERE regla IS NOT NULL)::INT,
           0
    FROM t_prod;
END $$;

-- Clientes (identidad + ids ERP + versiones SCD2 + deduplicación)
-- Deduplicación (apartado 8). Criterio: mismo nombre normalizado + mismo teléfono.
--   * Nombre normalizado: minúsculas, sin tildes, z = s, ñ = n, espacios simples
--     ("Muñoz Martínez" y "Munos Martínes" coinciden).
--   * Teléfono: últimos 9 dígitos (ignora prefijo, espacios y guiones).
-- Se aplica sobre las filas nuevas del lote (cliente_id NULL), en este orden:
--   1. Coincide con un cliente que ya existe (cualquier versión de su historial).
--   2. Coincide con otra fila del lote que ya tiene cliente.
--   3. Coincide con otras filas nuevas: prevalece la de alta más antigua.
-- Las fusionadas quedan con motivo_asignacion = 'fusion_duplicado'.
CREATE OR REPLACE FUNCTION core.resolver_duplicados_clientes(p_id BIGINT) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_fusionadas INT;
BEGIN
    UPDATE t_cli t SET cliente_id = v.cliente_id, motivo_asignacion = 'fusion_duplicado'
    FROM (SELECT DISTINCT ON (clave_duplicado) clave_duplicado, cliente_id
          FROM core.cliente_version
          WHERE clave_duplicado IS NOT NULL AND cliente_id > 0
          ORDER BY clave_duplicado, cliente_id) v
    WHERE t.regla IS NULL AND t.cliente_id IS NULL AND t.clave_dup = v.clave_duplicado;

    UPDATE t_cli t SET cliente_id = k.cliente_id, motivo_asignacion = 'fusion_duplicado'
    FROM (SELECT DISTINCT ON (clave_dup) clave_dup, cliente_id
          FROM t_cli
          WHERE regla IS NULL AND cliente_id IS NOT NULL AND clave_dup IS NOT NULL
          ORDER BY clave_dup, cliente_id) k
    WHERE t.regla IS NULL AND t.cliente_id IS NULL AND t.clave_dup = k.clave_dup;

    UPDATE t_cli t SET absorbe_en_fila = g.fila_superviviente, motivo_asignacion = 'fusion_duplicado'
    FROM (SELECT num_fila,
                 first_value(num_fila) OVER (PARTITION BY clave_dup
                                             ORDER BY fecha_alta NULLS LAST, id_erp) AS fila_superviviente
          FROM t_cli
          WHERE regla IS NULL AND cliente_id IS NULL AND clave_dup IS NOT NULL) g
    WHERE t.num_fila = g.num_fila AND g.fila_superviviente <> g.num_fila;

    SELECT count(*) INTO v_fusionadas FROM t_cli WHERE motivo_asignacion = 'fusion_duplicado';
    RETURN v_fusionadas;
END $$;

CREATE OR REPLACE FUNCTION core.cargar_clientes(p_id BIGINT)
RETURNS TABLE (insertadas INT, actualizadas INT, sin_cambios INT, corregidas INT, rechazadas INT, fusionadas INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_fichero TEXT;
    v_ts      TIMESTAMPTZ;
    v_regex_email CONSTANT TEXT := '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$';
BEGIN
    SELECT e.fichero_origen, e.fecha_inicio INTO v_fichero, v_ts
    FROM control.ejecucion e WHERE e.id_ejecucion = p_id;

    DROP TABLE IF EXISTS t_cli;
    CREATE TEMP TABLE t_cli ON COMMIT DROP AS
    SELECT s.num_fila,
           upper(trim(s.id_cliente))                          AS id_erp,
           trim(s.nombre)                                     AS nombre,
           nullif(trim(s.apellidos), '')                      AS apellidos,
           s.email                                            AS email_txt,
           CASE WHEN lower(trim(s.email)) ~ v_regex_email THEN lower(trim(s.email)) END AS email,
           false                                              AS email_corregido,
           nullif(regexp_replace(coalesce(s.telefono, ''), '[^0-9+]', '', 'g'), '') AS telefono,
           s.pais                                             AS pais_txt,
           control.normalizar('pais', s.pais)                 AS codigo_pais,
           nullif(trim(s.ciudad), '')                         AS ciudad,
           s.fecha_alta                                       AS fecha_alta_txt,
           control.a_fecha(s.fecha_alta)::DATE                AS fecha_alta,
           s.consentimiento_marketing                         AS consent_txt,
           control.normalizar('consentimiento', s.consentimiento_marketing)::BOOLEAN AS consentimiento,
           control.clave_duplicado(s.nombre, s.apellidos, s.telefono) AS clave_dup,
           to_jsonb(s) - ARRAY['id_ejecucion', 'fichero_origen', 'fecha_carga', 'hash_fila'] AS registro,
           NULL::TEXT   AS regla, NULL::TEXT AS motivo,
           NULL::BIGINT AS cliente_id, NULL::TEXT AS motivo_asignacion, NULL::INT AS absorbe_en_fila,
           NULL::TEXT   AS accion
    FROM staging.clientes s
    WHERE s.id_ejecucion = p_id;

    -- Rechazos
    UPDATE t_cli SET regla = 'GEN_CLAVE_VACIA', motivo = 'id_cliente vacío'
    WHERE coalesce(id_erp, '') = '';
    UPDATE t_cli SET regla = 'GEN_VALOR_INVALIDO', motivo = 'nombre vacío'
    WHERE regla IS NULL AND coalesce(nombre, '') = '';
    UPDATE t_cli t SET regla = 'GEN_CLAVE_DUPLICADA_FICHERO', motivo = 'id_cliente repetido en el fichero'
    FROM (SELECT num_fila, row_number() OVER (PARTITION BY id_erp ORDER BY num_fila DESC) AS rn
          FROM t_cli WHERE regla IS NULL) d
    WHERE t.num_fila = d.num_fila AND d.rn > 1;

    INSERT INTO control.cuarentena (id_ejecucion, regla_id, entidad, fichero_origen, num_fila, registro, motivo)
    SELECT p_id, regla, 'clientes', v_fichero, num_fila, registro, motivo FROM t_cli WHERE regla IS NOT NULL;

    -- Email con un espacio en lugar de la @: se corrige si el dominio resultante es
    -- uno de los habituales en los emails válidos (aparece al menos 10 veces).
    WITH dominios AS (
        SELECT split_part(e, '@', 2) AS dominio
        FROM (SELECT email AS e FROM t_cli WHERE email IS NOT NULL
              UNION ALL
              SELECT email FROM core.cliente_version WHERE es_actual AND email IS NOT NULL) z
        GROUP BY 1 HAVING count(*) >= 10
    )
    UPDATE t_cli
    SET email = replace(lower(trim(email_txt)), ' ', '@'), email_corregido = true
    WHERE regla IS NULL AND email IS NULL
      AND lower(trim(email_txt)) ~ '^[^@[:space:]]+ [^@[:space:]]+\.[a-z]{2,}$'
      AND split_part(lower(trim(email_txt)), ' ', 2) IN (SELECT dominio FROM dominios);

    -- Incidencias (correcciones y marcas)
    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original, valor_nuevo)
    SELECT p_id, x.regla, 'clientes', t.id_erp, t.num_fila, x.campo, x.original, x.nuevo
    FROM t_cli t
    CROSS JOIN LATERAL (VALUES
        ('GEN_FECHA_FORMATO', 'fecha_alta', t.fecha_alta_txt, t.fecha_alta::TEXT,
            control.es_fecha_dmy(t.fecha_alta_txt) AND t.fecha_alta IS NOT NULL),
        ('GEN_VALOR_DESCARTADO', 'fecha_alta', t.fecha_alta_txt, NULL,
            trim(coalesce(t.fecha_alta_txt, '')) <> '' AND t.fecha_alta IS NULL),
        ('GEN_VALOR_MAPEADO', 'pais', t.pais_txt, t.codigo_pais,
            t.codigo_pais IS NOT NULL AND upper(trim(t.pais_txt)) <> t.codigo_pais),
        ('GEN_VALOR_SIN_MAPEO', 'pais', t.pais_txt, NULL,
            trim(coalesce(t.pais_txt, '')) <> '' AND t.codigo_pais IS NULL),
        ('CLI_EMAIL_VACIO', 'email', t.email_txt, NULL,
            trim(coalesce(t.email_txt, '')) = ''),
        ('CLI_EMAIL_CORREGIDO', 'email', t.email_txt, t.email,
            t.email_corregido),
        ('CLI_EMAIL_INVALIDO', 'email', t.email_txt, NULL,
            trim(coalesce(t.email_txt, '')) <> '' AND t.email IS NULL),
        ('CLI_CONSENT_DESCONOCIDO', 'consentimiento_marketing', t.consent_txt, NULL,
            trim(coalesce(t.consent_txt, '')) = ''),
        ('GEN_VALOR_SIN_MAPEO', 'consentimiento_marketing', t.consent_txt, NULL,
            trim(coalesce(t.consent_txt, '')) <> '' AND t.consentimiento IS NULL)
    ) AS x(regla, campo, original, nuevo, aplica)
    WHERE t.regla IS NULL AND x.aplica;

    -- Identidad: ids del ERP ya conocidos (incluidos los que se fusionaron en cargas anteriores)
    UPDATE t_cli t SET cliente_id = m.cliente_id, motivo_asignacion = m.motivo_asignacion
    FROM core.cliente_id_erp m
    WHERE t.regla IS NULL AND m.id_cliente_erp = t.id_erp;

    -- Deduplicación de los ids nuevos
    PERFORM core.resolver_duplicados_clientes(p_id);

    -- Clientes realmente nuevos: se reservan sus claves de una vez (operación de conjunto)
    UPDATE t_cli SET cliente_id = nextval(pg_get_serial_sequence('core.cliente', 'cliente_id')),
                     motivo_asignacion = 'alta', accion = 'insertar'
    WHERE regla IS NULL AND cliente_id IS NULL AND absorbe_en_fila IS NULL;

    -- Duplicados dentro del lote: toman el cliente de su superviviente
    UPDATE t_cli t SET cliente_id = s.cliente_id
    FROM t_cli s WHERE t.absorbe_en_fila = s.num_fila;

    -- Ids nuevos que se fusionan con un cliente
    UPDATE t_cli t SET accion = 'fusionar'
    WHERE t.regla IS NULL AND t.motivo_asignacion = 'fusion_duplicado'
      AND NOT EXISTS (SELECT 1 FROM core.cliente_id_erp m WHERE m.id_cliente_erp = t.id_erp);

    INSERT INTO core.cliente (cliente_id, fecha_alta, id_ejecucion)
    SELECT cliente_id, fecha_alta, p_id FROM t_cli WHERE accion = 'insertar';

    INSERT INTO core.cliente_id_erp (id_cliente_erp, cliente_id, motivo_asignacion, id_ejecucion)
    SELECT t.id_erp, t.cliente_id, t.motivo_asignacion, p_id
    FROM t_cli t
    WHERE t.regla IS NULL
      AND NOT EXISTS (SELECT 1 FROM core.cliente_id_erp m WHERE m.id_cliente_erp = t.id_erp);

    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original, valor_nuevo)
    SELECT p_id, 'CLI_DUPLICADO_FUSIONADO', 'clientes', t.id_erp, t.num_fila, 'id_cliente', t.id_erp, sup.id_erp
    FROM t_cli t
    CROSS JOIN LATERAL (SELECT min(m.id_cliente_erp) AS id_erp FROM core.cliente_id_erp m
                        WHERE m.cliente_id = t.cliente_id AND m.motivo_asignacion = 'alta') sup
    WHERE t.accion = 'fusionar';

    -- Atributos resultantes por cliente.
    -- Base: la fila de su ficha original (motivo 'alta') si viene en el lote; si no, su versión vigente.
    -- Las fichas fusionadas solo aportan: datos que falten, su fecha de alta si es anterior
    -- y la negativa de consentimiento (si alguna ficha dice "no", el resultado es "no").
    DROP TABLE IF EXISTS t_obj;
    CREATE TEMP TABLE t_obj ON COMMIT DROP AS
    SELECT k.cliente_id,
           (p.num_fila IS NOT NULL) AS viene_principal,
           CASE WHEN p.num_fila IS NOT NULL THEN p.nombre         ELSE v.nombre                   END AS nombre,
           CASE WHEN p.num_fila IS NOT NULL THEN p.apellidos      ELSE v.apellidos                END AS apellidos,
           CASE WHEN p.num_fila IS NOT NULL THEN p.email          ELSE v.email                    END AS email,
           CASE WHEN p.num_fila IS NOT NULL THEN p.telefono       ELSE v.telefono                 END AS telefono,
           CASE WHEN p.num_fila IS NOT NULL THEN p.codigo_pais    ELSE v.codigo_pais              END AS codigo_pais,
           CASE WHEN p.num_fila IS NOT NULL THEN p.ciudad         ELSE v.ciudad                   END AS ciudad,
           CASE WHEN p.num_fila IS NOT NULL THEN p.consentimiento ELSE v.consentimiento_marketing END AS consentimiento,
           CASE WHEN p.num_fila IS NOT NULL THEN coalesce(p.fecha_alta, c.fecha_alta) ELSE c.fecha_alta END AS fecha_alta,
           c.fecha_alta     AS fecha_alta_actual,
           v.hash_atributos AS hash_actual,
           NULL::TEXT       AS hash_nuevo,
           false            AS nueva_version,
           false            AS cambia_fecha_alta,
           EXISTS (SELECT 1 FROM t_cli n WHERE n.cliente_id = k.cliente_id AND n.accion = 'insertar') AS es_nuevo
    FROM (SELECT DISTINCT cliente_id FROM t_cli WHERE regla IS NULL) k
    LEFT JOIN t_cli p ON p.cliente_id = k.cliente_id AND p.regla IS NULL AND p.motivo_asignacion = 'alta'
    LEFT JOIN core.cliente c ON c.cliente_id = k.cliente_id
    LEFT JOIN core.cliente_version v ON v.cliente_id = k.cliente_id AND v.es_actual;

    UPDATE t_obj o SET
        apellidos      = coalesce(o.apellidos,   s.apellidos),
        email          = coalesce(o.email,       s.email),
        telefono       = coalesce(o.telefono,    s.telefono),
        codigo_pais    = coalesce(o.codigo_pais, s.codigo_pais),
        ciudad         = coalesce(o.ciudad,      s.ciudad),
        consentimiento = CASE WHEN o.consentimiento IS FALSE OR s.algun_no THEN false
                              WHEN o.consentimiento IS TRUE  OR s.algun_si THEN true END,
        fecha_alta     = least(o.fecha_alta, s.fecha_alta_min)
    FROM (SELECT cliente_id,
                 (array_agg(apellidos   ORDER BY num_fila) FILTER (WHERE apellidos   IS NOT NULL))[1] AS apellidos,
                 (array_agg(email       ORDER BY num_fila) FILTER (WHERE email       IS NOT NULL))[1] AS email,
                 (array_agg(telefono    ORDER BY num_fila) FILTER (WHERE telefono    IS NOT NULL))[1] AS telefono,
                 (array_agg(codigo_pais ORDER BY num_fila) FILTER (WHERE codigo_pais IS NOT NULL))[1] AS codigo_pais,
                 (array_agg(ciudad      ORDER BY num_fila) FILTER (WHERE ciudad      IS NOT NULL))[1] AS ciudad,
                 bool_or(consentimiento IS FALSE) AS algun_no,
                 bool_or(consentimiento IS TRUE)  AS algun_si,
                 min(fecha_alta) AS fecha_alta_min
          FROM t_cli
          WHERE regla IS NULL AND motivo_asignacion = 'fusion_duplicado'
          GROUP BY cliente_id) s
    WHERE o.cliente_id = s.cliente_id;

    UPDATE t_obj SET hash_nuevo = md5(concat_ws('|', nombre, coalesce(apellidos, ''), coalesce(email, ''),
                                                coalesce(telefono, ''), coalesce(codigo_pais, ''),
                                                coalesce(ciudad, ''), coalesce(consentimiento::TEXT, 'null')));
    UPDATE t_obj SET nueva_version     = hash_actual IS DISTINCT FROM hash_nuevo,
                     cambia_fecha_alta = NOT es_nuevo AND fecha_alta IS NOT NULL
                                         AND fecha_alta IS DISTINCT FROM fecha_alta_actual;

    -- Clasificación de las filas restantes (para los contadores)
    UPDATE t_cli t SET accion = CASE
            WHEN t.motivo_asignacion = 'alta' AND (o.nueva_version OR o.cambia_fecha_alta) THEN 'actualizar'
            WHEN t.motivo_asignacion <> 'alta' AND NOT o.viene_principal
                 AND (o.nueva_version OR o.cambia_fecha_alta) THEN 'actualizar'
            ELSE 'sin_cambios' END
    FROM t_obj o
    WHERE t.regla IS NULL AND t.accion IS NULL AND o.cliente_id = t.cliente_id;

    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, campo, valor_original, valor_nuevo)
    SELECT p_id, 'CLI_FECHA_ALTA_CAMBIA', 'clientes',
           (SELECT min(m.id_cliente_erp) FROM core.cliente_id_erp m WHERE m.cliente_id = o.cliente_id),
           'fecha_alta', o.fecha_alta_actual::TEXT, o.fecha_alta::TEXT
    FROM t_obj o WHERE o.cambia_fecha_alta;

    UPDATE core.cliente c
    SET fecha_alta = o.fecha_alta, fecha_actualizacion = now(), id_ejecucion = p_id
    FROM t_obj o WHERE o.cambia_fecha_alta AND c.cliente_id = o.cliente_id;

    -- SCD2: se cierra la versión vigente y se abre la nueva
    UPDATE core.cliente_version v
    SET valido_hasta = v_ts, es_actual = false
    FROM t_obj o
    WHERE o.nueva_version AND v.cliente_id = o.cliente_id AND v.es_actual;

    INSERT INTO core.cliente_version (cliente_id, nombre, apellidos, email, telefono, codigo_pais, ciudad,
                                      consentimiento_marketing, valido_desde, es_actual, hash_atributos,
                                      clave_duplicado, id_ejecucion)
    SELECT cliente_id, nombre, apellidos, email, telefono, codigo_pais, ciudad, consentimiento,
           v_ts, true, hash_nuevo, control.clave_duplicado(nombre, apellidos, telefono), p_id
    FROM t_obj WHERE nueva_version;

    -- Pedidos que esperaban a este cliente (estaban en -1)
    UPDATE core.pedido p SET cliente_id = m.cliente_id, fecha_actualizacion = now(), id_ejecucion = p_id
    FROM core.cliente_id_erp m
    WHERE p.cliente_id = -1 AND m.id_cliente_erp = p.id_cliente_erp_origen;

    RETURN QUERY
    SELECT count(*) FILTER (WHERE accion = 'insertar')::INT,
           count(*) FILTER (WHERE accion = 'actualizar')::INT,
           count(*) FILTER (WHERE accion = 'sin_cambios')::INT,
           control.contar_corregidas(p_id, 'clientes'),
           count(*) FILTER (WHERE regla IS NOT NULL)::INT,
           count(*) FILTER (WHERE accion = 'fusionar')::INT
    FROM t_cli;
END $$;

-- -----------------------------------------------------------------------------
-- Pedidos (cabecera + historial de estados)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.cargar_pedidos(p_id BIGINT)
RETURNS TABLE (insertadas INT, actualizadas INT, sin_cambios INT, corregidas INT, rechazadas INT, fusionadas INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_fichero TEXT;
    v_ts      TIMESTAMPTZ;
BEGIN
    SELECT e.fichero_origen, e.fecha_inicio INTO v_fichero, v_ts
    FROM control.ejecucion e WHERE e.id_ejecucion = p_id;

    DROP TABLE IF EXISTS t_ped;
    CREATE TEMP TABLE t_ped ON COMMIT DROP AS
    SELECT s.num_fila,
           upper(trim(s.id_pedido))                     AS id_erp,
           coalesce(upper(trim(s.id_cliente)), '')      AS id_cliente_erp,
           s.fecha_pedido                               AS fecha_txt,
           control.a_fecha(s.fecha_pedido)              AS fecha_pedido,
           s.estado                                     AS estado_txt,
           e.estado_id, e.nombre                        AS estado_nombre,
           s.canal                                      AS canal_txt,
           c.canal_id, c.nombre                         AS canal_nombre,
           control.a_numero(s.importe_total_erp)        AS importe,
           coalesce(m.cliente_id, -1)                   AS cliente_id,
           to_jsonb(s) - ARRAY['id_ejecucion', 'fichero_origen', 'fecha_carga', 'hash_fila'] AS registro,
           NULL::TEXT AS regla, NULL::TEXT AS motivo,
           NULL::TEXT AS accion, NULL::SMALLINT AS estado_anterior
    FROM staging.pedidos s
    LEFT JOIN core.estado_pedido e ON e.codigo = control.normalizar('estado_pedido', s.estado)
    LEFT JOIN core.canal c         ON c.codigo = control.normalizar('canal', s.canal)
    LEFT JOIN core.cliente_id_erp m ON m.id_cliente_erp = upper(trim(s.id_cliente))
    WHERE s.id_ejecucion = p_id;

    -- Rechazos
    UPDATE t_ped SET regla = 'GEN_CLAVE_VACIA', motivo = 'id_pedido vacío'
    WHERE coalesce(id_erp, '') = '';
    UPDATE t_ped SET regla = 'GEN_VALOR_INVALIDO', motivo = 'fecha_pedido no válida'
    WHERE regla IS NULL AND fecha_pedido IS NULL;
    UPDATE t_ped SET regla = 'GEN_VALOR_INVALIDO', motivo = 'estado no reconocido'
    WHERE regla IS NULL AND estado_id IS NULL;
    UPDATE t_ped SET regla = 'GEN_VALOR_INVALIDO', motivo = 'canal no reconocido'
    WHERE regla IS NULL AND canal_id IS NULL;
    UPDATE t_ped SET regla = 'GEN_VALOR_INVALIDO', motivo = 'importe no numérico o negativo'
    WHERE regla IS NULL AND (importe IS NULL OR importe < 0);
    UPDATE t_ped t SET regla = 'GEN_CLAVE_DUPLICADA_FICHERO', motivo = 'id_pedido repetido en el fichero'
    FROM (SELECT num_fila, row_number() OVER (PARTITION BY id_erp ORDER BY num_fila DESC) AS rn
          FROM t_ped WHERE regla IS NULL) d
    WHERE t.num_fila = d.num_fila AND d.rn > 1;

    INSERT INTO control.cuarentena (id_ejecucion, regla_id, entidad, fichero_origen, num_fila, registro, motivo)
    SELECT p_id, regla, 'pedidos', v_fichero, num_fila, registro, motivo FROM t_ped WHERE regla IS NOT NULL;

    -- Incidencias
    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original, valor_nuevo)
    SELECT p_id, x.regla, 'pedidos', t.id_erp, t.num_fila, x.campo, x.original, x.nuevo
    FROM t_ped t
    CROSS JOIN LATERAL (VALUES
        ('GEN_FECHA_FORMATO', 'fecha_pedido', t.fecha_txt, t.fecha_pedido::TEXT, control.es_fecha_dmy(t.fecha_txt)),
        ('GEN_VALOR_MAPEADO', 'estado', t.estado_txt, t.estado_nombre, trim(t.estado_txt) <> t.estado_nombre),
        ('GEN_VALOR_MAPEADO', 'canal',  t.canal_txt,  t.canal_nombre,  trim(t.canal_txt)  <> t.canal_nombre),
        ('PED_CLIENTE_DESCONOCIDO', 'id_cliente', t.id_cliente_erp, '-1', t.cliente_id = -1)
    ) AS x(regla, campo, original, nuevo, aplica)
    WHERE t.regla IS NULL AND x.aplica;

    -- Clasificación frente a core
    UPDATE t_ped t SET
        estado_anterior = p.estado_id,
        accion = CASE
            WHEN p.pedido_id IS NULL THEN 'insertar'
            WHEN (p.cliente_id, p.id_cliente_erp_origen, p.fecha_pedido, p.canal_id, p.estado_id, p.importe_total_erp)
                 IS DISTINCT FROM (t.cliente_id, t.id_cliente_erp, t.fecha_pedido, t.canal_id, t.estado_id, t.importe)
                 THEN 'actualizar'
            ELSE 'sin_cambios' END
    FROM t_ped t2 LEFT JOIN core.pedido p ON p.id_pedido_erp = t2.id_erp
    WHERE t.num_fila = t2.num_fila AND t.regla IS NULL;

    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original, valor_nuevo)
    SELECT p_id, 'PED_TRANSICION_INVALIDA', 'pedidos', t.id_erp, t.num_fila, 'estado', ea.codigo, en.codigo
    FROM t_ped t
    JOIN core.estado_pedido ea ON ea.estado_id = t.estado_anterior
    JOIN core.estado_pedido en ON en.estado_id = t.estado_id
    WHERE t.accion = 'actualizar' AND t.estado_anterior <> t.estado_id AND ea.es_final;

    -- Nuevos
    INSERT INTO core.pedido (id_pedido_erp, cliente_id, id_cliente_erp_origen, fecha_pedido, canal_id,
                             estado_id, importe_total_erp, id_ejecucion)
    SELECT id_erp, cliente_id, id_cliente_erp, fecha_pedido, canal_id, estado_id, importe, p_id
    FROM t_ped WHERE accion = 'insertar';

    INSERT INTO core.pedido_estado_hist (pedido_id, estado_id, valido_desde, id_ejecucion)
    SELECT p.pedido_id, t.estado_id, v_ts, p_id
    FROM t_ped t JOIN core.pedido p ON p.id_pedido_erp = t.id_erp
    WHERE t.accion = 'insertar';

    -- Modificados: historial solo si cambia el estado
    UPDATE core.pedido_estado_hist h
    SET valido_hasta = v_ts
    FROM t_ped t JOIN core.pedido p ON p.id_pedido_erp = t.id_erp
    WHERE t.accion = 'actualizar' AND t.estado_anterior <> t.estado_id
      AND h.pedido_id = p.pedido_id AND h.valido_hasta IS NULL;

    INSERT INTO core.pedido_estado_hist (pedido_id, estado_id, valido_desde, id_ejecucion)
    SELECT p.pedido_id, t.estado_id, v_ts, p_id
    FROM t_ped t JOIN core.pedido p ON p.id_pedido_erp = t.id_erp
    WHERE t.accion = 'actualizar' AND t.estado_anterior <> t.estado_id;

    UPDATE core.pedido p
    SET cliente_id = t.cliente_id, id_cliente_erp_origen = t.id_cliente_erp, fecha_pedido = t.fecha_pedido,
        canal_id = t.canal_id, estado_id = t.estado_id, importe_total_erp = t.importe,
        fecha_actualizacion = now(), id_ejecucion = p_id
    FROM t_ped t
    WHERE t.accion = 'actualizar' AND p.id_pedido_erp = t.id_erp;

    RETURN QUERY
    SELECT count(*) FILTER (WHERE accion = 'insertar')::INT,
           count(*) FILTER (WHERE accion = 'actualizar')::INT,
           count(*) FILTER (WHERE accion = 'sin_cambios')::INT,
           control.contar_corregidas(p_id, 'pedidos'),
           count(*) FILTER (WHERE regla IS NOT NULL)::INT,
           0
    FROM t_ped;
END $$;

-- Líneas de pedido

CREATE OR REPLACE FUNCTION core.cargar_lineas_pedido(p_id BIGINT)
RETURNS TABLE (insertadas INT, actualizadas INT, sin_cambios INT, corregidas INT, rechazadas INT, fusionadas INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_fichero    TEXT;
    v_tolerancia CONSTANT NUMERIC := 0.05;   -- € de diferencia admitida al cuadrar importes
BEGIN
    SELECT e.fichero_origen INTO v_fichero FROM control.ejecucion e WHERE e.id_ejecucion = p_id;

    DROP TABLE IF EXISTS t_lin;
    CREATE TEMP TABLE t_lin ON COMMIT DROP AS
    SELECT s.num_fila,
           upper(trim(s.id_pedido))                     AS id_pedido_erp,
           p.pedido_id,
           p.importe_total_erp,
           control.a_entero(s.num_linea)                AS num_linea,
           upper(trim(s.id_producto))                   AS id_producto_erp,
           coalesce(pr.producto_id, -1)                 AS producto_id,
           control.a_entero(s.cantidad)                 AS cantidad_original,
           control.a_entero(s.cantidad)                 AS cantidad,
           control.a_numero(s.precio_unitario)          AS precio_unitario,
           control.a_numero(s.descuento_pct)            AS descuento_pct,
           to_jsonb(s) - ARRAY['id_ejecucion', 'fichero_origen', 'fecha_carga', 'hash_fila'] AS registro,
           md5(concat_ws('|', trim(s.id_producto), trim(s.cantidad), trim(s.precio_unitario), trim(s.descuento_pct))) AS huella,
           NULL::TEXT AS regla, NULL::TEXT AS motivo, NULL::TEXT AS accion
    FROM staging.lineas_pedido s
    LEFT JOIN core.pedido p    ON p.id_pedido_erp = upper(trim(s.id_pedido))
    LEFT JOIN core.producto pr ON pr.id_producto_erp = upper(trim(s.id_producto))
    WHERE s.id_ejecucion = p_id;

    -- 1. Integridad y tipos
    UPDATE t_lin SET regla = 'LIN_PEDIDO_INEXISTENTE', motivo = 'el pedido ' || coalesce(id_pedido_erp, '(vacío)') || ' no existe'
    WHERE pedido_id IS NULL;
    UPDATE t_lin SET regla = 'GEN_VALOR_INVALIDO', motivo = 'num_linea no válido'
    WHERE regla IS NULL AND (num_linea IS NULL OR num_linea <= 0);
    UPDATE t_lin SET regla = 'GEN_VALOR_INVALIDO', motivo = 'cantidad no entera'
    WHERE regla IS NULL AND cantidad IS NULL;
    UPDATE t_lin SET regla = 'GEN_VALOR_INVALIDO', motivo = 'precio no numérico o negativo'
    WHERE regla IS NULL AND (precio_unitario IS NULL OR precio_unitario < 0);
    UPDATE t_lin SET regla = 'GEN_VALOR_INVALIDO', motivo = 'descuento fuera de 0-100'
    WHERE regla IS NULL AND (descuento_pct IS NULL OR descuento_pct NOT BETWEEN 0 AND 100);

    -- 2. Duplicados en el fichero: prevalece la versión válida (cantidad > 0) y, si empatan, la última
    UPDATE t_lin t
    SET regla  = CASE WHEN t.huella = d.huella_ganadora THEN 'LIN_DUPLICADA' ELSE 'LIN_CONFLICTO' END,
        motivo = CASE WHEN t.huella = d.huella_ganadora THEN 'copia exacta de otra línea'
                      ELSE 'misma línea con datos distintos; se conserva la versión válida' END
    FROM (SELECT num_fila, rn, first_value(huella) OVER w AS huella_ganadora
          FROM (SELECT num_fila, huella, pedido_id, num_linea, cantidad,
                       row_number() OVER (PARTITION BY pedido_id, num_linea
                                          ORDER BY (cantidad > 0) DESC, num_fila DESC) AS rn
                FROM t_lin WHERE regla IS NULL) z
          WINDOW w AS (PARTITION BY pedido_id, num_linea ORDER BY rn)) d
    WHERE t.num_fila = d.num_fila AND d.rn > 1;

    -- 3. Cantidad 0 o negativa: se corrige a 1 solo si con 1 cuadra el importe del pedido
    WITH lineas_pedido AS (
        SELECT pedido_id, num_linea,
               round(CASE WHEN cantidad > 0 THEN cantidad ELSE 1 END * precio_unitario * (1 - descuento_pct / 100), 2) AS importe
        FROM t_lin WHERE regla IS NULL
        UNION ALL   -- líneas que el pedido ya tenía en core y no vienen en este fichero
        SELECT l.pedido_id, l.num_linea, l.importe_linea
        FROM core.linea_pedido l
        WHERE l.pedido_id IN (SELECT pedido_id FROM t_lin WHERE regla IS NULL AND cantidad <= 0)
          AND NOT EXISTS (SELECT 1 FROM t_lin t WHERE t.regla IS NULL AND t.pedido_id = l.pedido_id AND t.num_linea = l.num_linea)
    ),
    cuadre AS (
        SELECT lp.pedido_id, abs(sum(lp.importe) - max(p.importe_total_erp)) < v_tolerancia AS cuadra
        FROM lineas_pedido lp JOIN core.pedido p USING (pedido_id)
        WHERE lp.pedido_id IN (SELECT pedido_id FROM t_lin WHERE regla IS NULL AND cantidad <= 0)
        GROUP BY lp.pedido_id
    )
    UPDATE t_lin t
    SET cantidad = CASE WHEN c.cuadra THEN 1 ELSE t.cantidad END,
        regla    = CASE WHEN c.cuadra THEN NULL ELSE 'LIN_CANTIDAD_INVALIDA' END,
        motivo   = CASE WHEN c.cuadra THEN NULL
                        ELSE 'cantidad ' || t.cantidad || ' sin evidencia para corregirla (el importe del pedido no cuadra)' END
    FROM cuadre c
    WHERE t.regla IS NULL AND t.cantidad <= 0 AND c.pedido_id = t.pedido_id;

    INSERT INTO control.cuarentena (id_ejecucion, regla_id, entidad, fichero_origen, num_fila, registro, motivo)
    SELECT p_id, regla, 'lineas_pedido', v_fichero, num_fila, registro, motivo FROM t_lin WHERE regla IS NOT NULL;

    -- Incidencias
    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, num_fila, campo, valor_original, valor_nuevo)
    SELECT p_id, x.regla, 'lineas_pedido', t.id_pedido_erp || '#' || t.num_linea, t.num_fila, x.campo, x.original, x.nuevo
    FROM t_lin t
    CROSS JOIN LATERAL (VALUES
        ('LIN_CANTIDAD_CORREGIDA',   'cantidad',    t.cantidad_original::TEXT, t.cantidad::TEXT, t.cantidad <> t.cantidad_original),
        ('LIN_PRODUCTO_DESCONOCIDO', 'id_producto', t.id_producto_erp,         '-1',             t.producto_id = -1)
    ) AS x(regla, campo, original, nuevo, aplica)
    WHERE t.regla IS NULL AND x.aplica;

    -- Clasificación frente a core
    UPDATE t_lin t SET accion = CASE
            WHEN l.pedido_id IS NULL THEN 'insertar'
            WHEN (l.producto_id, l.id_producto_erp_origen, l.cantidad, l.cantidad_original, l.precio_unitario, l.descuento_pct)
                 IS DISTINCT FROM (t.producto_id, t.id_producto_erp, t.cantidad, t.cantidad_original, t.precio_unitario, t.descuento_pct)
                 THEN 'actualizar'
            ELSE 'sin_cambios' END
    FROM t_lin t2 LEFT JOIN core.linea_pedido l ON l.pedido_id = t2.pedido_id AND l.num_linea = t2.num_linea
    WHERE t.num_fila = t2.num_fila AND t.regla IS NULL;

    INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
                                   cantidad_original, precio_unitario, descuento_pct, id_ejecucion)
    SELECT pedido_id, num_linea, producto_id, id_producto_erp, cantidad, cantidad_original,
           precio_unitario, descuento_pct, p_id
    FROM t_lin WHERE accion = 'insertar';

    UPDATE core.linea_pedido l
    SET producto_id = t.producto_id, id_producto_erp_origen = t.id_producto_erp, cantidad = t.cantidad,
        cantidad_original = t.cantidad_original, precio_unitario = t.precio_unitario,
        descuento_pct = t.descuento_pct, id_ejecucion = p_id
    FROM t_lin t
    WHERE t.accion = 'actualizar' AND l.pedido_id = t.pedido_id AND l.num_linea = t.num_linea;

    -- Cuadre de importes de los pedidos tocados por este fichero
    INSERT INTO control.incidencia_calidad (id_ejecucion, regla_id, entidad, clave_registro, campo, valor_original, valor_nuevo)
    SELECT p_id, 'PED_IMPORTE_DESCUADRE', 'pedidos', p.id_pedido_erp, 'importe_total_erp',
           p.importe_total_erp::TEXT, coalesce(sum(l.importe_linea), 0)::TEXT
    FROM core.pedido p
    LEFT JOIN core.linea_pedido l ON l.pedido_id = p.pedido_id
    WHERE p.pedido_id IN (SELECT DISTINCT pedido_id FROM t_lin WHERE pedido_id IS NOT NULL)
    GROUP BY p.pedido_id, p.id_pedido_erp, p.importe_total_erp
    HAVING abs(p.importe_total_erp - coalesce(sum(l.importe_linea), 0)) >= v_tolerancia;

    RETURN QUERY
    SELECT count(*) FILTER (WHERE accion = 'insertar')::INT,
           count(*) FILTER (WHERE accion = 'actualizar')::INT,
           count(*) FILTER (WHERE accion = 'sin_cambios')::INT,
           control.contar_corregidas(p_id, 'lineas_pedido'),
           count(*) FILTER (WHERE regla IS NOT NULL)::INT,
           0
    FROM t_lin;
END $$;