-- Datos de referencia (catálogos, mapeos, reglas, registros desconocidos)
-- Re-ejecutable

-- Catálogos de core

INSERT INTO core.pais (codigo_pais, nombre) VALUES
    ('ES', 'España'), ('PT', 'Portugal'), ('FR', 'Francia'), ('DE', 'Alemania'), ('IT', 'Italia')
ON CONFLICT DO NOTHING;

INSERT INTO core.canal (canal_id, codigo, nombre) VALUES
    (1, 'WEB', 'Web'), (2, 'TIENDA', 'Tienda'), (3, 'TELEFONO', 'Teléfono')
ON CONFLICT DO NOTHING;

-- cuenta_como_venta: decisión de negocio, configurable aquí sin tocar código.
INSERT INTO core.estado_pedido (estado_id, codigo, nombre, es_final, cuenta_como_venta) VALUES
    (1, 'PENDIENTE', 'Pendiente', false, false),
    (2, 'ENTREGADO', 'Entregado', false, true),   -- no es final: puede pasar a devuelto
    (3, 'CANCELADO', 'Cancelado', true,  false),
    (4, 'DEVUELTO',  'Devuelto',  true,  false)
ON CONFLICT DO NOTHING;

-- Registros "desconocido" (id -1)

INSERT INTO core.categoria (categoria_id, nombre) VALUES (-1, 'Desconocida')
ON CONFLICT DO NOTHING;

INSERT INTO core.subcategoria (subcategoria_id, categoria_id, nombre) VALUES (-1, -1, 'Desconocida')
ON CONFLICT DO NOTHING;

INSERT INTO core.producto (producto_id, id_producto_erp, nombre, subcategoria_id, activo)
VALUES (-1, 'DESCONOCIDO', 'Producto desconocido', -1, false)
ON CONFLICT DO NOTHING;

INSERT INTO core.cliente (cliente_id) VALUES (-1)
ON CONFLICT DO NOTHING;

INSERT INTO core.cliente_version (cliente_id, nombre, valido_desde, es_actual, hash_atributos)
SELECT -1, 'Cliente desconocido', TIMESTAMPTZ '1900-01-01', true, md5('desconocido')
WHERE NOT EXISTS (SELECT 1 FROM core.cliente_version WHERE cliente_id = -1);

-- Mapeos de normalización (valor_origen en MAYÚSCULAS)

INSERT INTO control.mapeo_valores (dominio, valor_origen, valor_normalizado) VALUES
    ('pais', 'ES', 'ES'), ('pais', 'ESP', 'ES'), ('pais', 'SPAIN', 'ES'), ('pais', 'ESPAÑA', 'ES'),
    ('pais', 'PT', 'PT'), ('pais', 'PORTUGAL', 'PT'),
    ('pais', 'FR', 'FR'), ('pais', 'FRANCE', 'FR'), ('pais', 'FRANCIA', 'FR'),
    ('pais', 'DE', 'DE'), ('pais', 'GERMANY', 'DE'), ('pais', 'ALEMANIA', 'DE'),
    ('pais', 'IT', 'IT'), ('pais', 'ITALY', 'IT'), ('pais', 'ITALIA', 'IT'),
    ('canal', 'WEB', 'WEB'), ('canal', 'TIENDA', 'TIENDA'),
    ('canal', 'TELEFONO', 'TELEFONO'), ('canal', 'TELÉFONO', 'TELEFONO'),
    ('estado_pedido', 'PENDIENTE', 'PENDIENTE'), ('estado_pedido', 'ENTREGADO', 'ENTREGADO'),
    ('estado_pedido', 'CANCELADO', 'CANCELADO'), ('estado_pedido', 'DEVUELTO', 'DEVUELTO'),
    ('consentimiento', 'S', 'true'), ('consentimiento', 'SI', 'true'), ('consentimiento', 'SÍ', 'true'),
    ('consentimiento', '1', 'true'),
    ('consentimiento', 'N', 'false'), ('consentimiento', 'NO', 'false'), ('consentimiento', '0', 'false')
    -- Vacío no se mapea: consentimiento desconocido (NULL)
ON CONFLICT DO NOTHING;

-- Reglas de calidad acordadas hasta ahora (se completarán en la fase de calidad)

INSERT INTO control.regla_calidad (regla_id, entidad, descripcion, severidad, accion) VALUES
    ('GEN_FECHA_FORMATO',        'general',       'Fecha en formato dd/mm/aaaa convertida a ISO.', 'baja', 'corregir'),
    ('GEN_VALOR_MAPEADO',        'general',       'Valor normalizado mediante control.mapeo_valores (país, canal, estado, consentimiento).', 'baja', 'corregir'),
    ('GEN_VALOR_SIN_MAPEO',      'general',       'Valor sin correspondencia en control.mapeo_valores.', 'media', 'marcar'),
    ('CLI_EMAIL_INVALIDO',       'clientes',      'Email con formato inválido; se guarda vacío y se conserva el original en la incidencia.', 'media', 'corregir'),
    ('CLI_CONSENT_DESCONOCIDO',  'clientes',      'Consentimiento vacío; se trata como sin consentimiento.', 'alta', 'marcar'),
    ('CLI_FECHA_ALTA_CAMBIA',    'clientes',      'El delta modifica la fecha de alta de un cliente existente.', 'media', 'marcar'),
    ('PED_CLIENTE_DESCONOCIDO',  'pedidos',       'Pedido de un cliente inexistente; se asigna al cliente -1.', 'alta', 'marcar'),
    ('PED_IMPORTE_DESCUADRE',    'pedidos',       'El importe del ERP no coincide con la suma de sus líneas.', 'media', 'marcar'),
    ('LIN_PRODUCTO_DESCONOCIDO', 'lineas_pedido', 'Línea de un producto inexistente; se asigna al producto -1.', 'alta', 'marcar'),
    ('LIN_CANTIDAD_CORREGIDA',   'lineas_pedido', 'Cantidad 0 o negativa corregida a 1 porque el importe del pedido lo confirma.', 'media', 'corregir'),
    ('LIN_CANTIDAD_INVALIDA',    'lineas_pedido', 'Cantidad 0 o negativa sin evidencia para corregirla.', 'alta', 'rechazar'),
    ('LIN_DUPLICADA',            'lineas_pedido', 'Línea duplicada exacta; se descarta la copia.', 'baja', 'rechazar'),
    ('LIN_CONFLICTO',            'lineas_pedido', 'Misma línea (pedido + número) con datos distintos; se conserva la versión válida.', 'media', 'rechazar')
ON CONFLICT DO NOTHING;

-- Calendario (dim_fecha): 2022-2027

INSERT INTO consume.dim_fecha
    (fecha_id, fecha, anio, trimestre, mes, nombre_mes, semana_iso, dia_semana, nombre_dia, es_fin_semana)
SELECT
    to_char(d, 'YYYYMMDD')::INT,
    d::DATE,
    extract(year    FROM d)::SMALLINT,
    extract(quarter FROM d)::SMALLINT,
    extract(month   FROM d)::SMALLINT,
    (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
           'septiembre','octubre','noviembre','diciembre'])[extract(month FROM d)::INT],
    extract(week    FROM d)::SMALLINT,
    extract(isodow  FROM d)::SMALLINT,
    (ARRAY['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow FROM d)::INT],
    extract(isodow  FROM d) IN (6, 7)
FROM generate_series(DATE '2022-01-01', DATE '2027-12-31', INTERVAL '1 day') AS d
ON CONFLICT DO NOTHING;
