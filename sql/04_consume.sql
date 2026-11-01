-- Esquema consume
-- Como se refresca cada tipo de tabla:
--   * Dimensiones (dim_*):         upsert desde core 
--     Nunca se vacían, porque las tablas de historial apuntan a ellas
--   * Hechos (fact_ventas) y
--     tablas anchas (cliente_360): se vacían y se reconstruyen en cada carga
--   * Historiales (cliente_rfm,
--     recomendacion, audiencia): solo se añaden filas una por fecha de cálculo
-- Las claves de cliente, producto, pedido y canal son las mismas que en core
-- No se declaran FK hacia core: la coherencia la garantiza el proceso de carga

-- Dimensiones

CREATE TABLE IF NOT EXISTS consume.dim_fecha (
    fecha_id        INT         PRIMARY KEY CHECK (fecha_id BETWEEN 19000101 AND 29991231),  -- AAAAMMDD
    fecha           DATE        NOT NULL UNIQUE,
    anio            SMALLINT    NOT NULL,
    trimestre       SMALLINT    NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    mes             SMALLINT    NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nombre_mes      VARCHAR(12) NOT NULL,
    semana_iso      SMALLINT    NOT NULL CHECK (semana_iso BETWEEN 1 AND 53),
    dia_semana      SMALLINT    NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),  -- 1 = lunes
    nombre_dia      VARCHAR(12) NOT NULL,
    es_fin_semana   BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS consume.dim_canal (
    canal_id        SMALLINT    PRIMARY KEY,
    codigo          VARCHAR(20) NOT NULL UNIQUE,
    nombre          VARCHAR(40) NOT NULL
);

-- Versión actual de cada cliente (SCD tipo 1). El historial vive en core
CREATE TABLE IF NOT EXISTS consume.dim_cliente (
    cliente_id               BIGINT       PRIMARY KEY,
    nombre                   VARCHAR(80)  NOT NULL,
    apellidos                VARCHAR(120),
    nombre_completo          VARCHAR(201) NOT NULL,
    email                    VARCHAR(254),
    codigo_pais              CHAR(2),
    pais                     VARCHAR(60),
    ciudad                   VARCHAR(80),
    fecha_alta               DATE,
    consentimiento_marketing BOOLEAN,
    segmento_actual          VARCHAR(40),
    fecha_actualizacion      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Dimensión aplanada: categoría y subcategoría como texto
-- La redundancia es intencionada
CREATE TABLE IF NOT EXISTS consume.dim_producto (
    producto_id         INT           PRIMARY KEY,
    id_producto_erp     VARCHAR(20)   NOT NULL UNIQUE,
    nombre              VARCHAR(150)  NOT NULL,
    categoria           VARCHAR(60)   NOT NULL,
    subcategoria        VARCHAR(60)   NOT NULL,
    marca               VARCHAR(60),
    precio_lista        NUMERIC(10,2),
    coste               NUMERIC(10,2),
    activo              BOOLEAN       NOT NULL,
    fecha_actualizacion TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Hechos: una fila por línea de pedido

CREATE TABLE IF NOT EXISTS consume.fact_ventas (
    pedido_id          BIGINT        NOT NULL,
    num_linea          SMALLINT      NOT NULL,
    fecha_id           INT           NOT NULL REFERENCES consume.dim_fecha (fecha_id),
    cliente_id         BIGINT        NOT NULL REFERENCES consume.dim_cliente (cliente_id),
    producto_id        INT           NOT NULL REFERENCES consume.dim_producto (producto_id),
    canal_id           SMALLINT      NOT NULL REFERENCES consume.dim_canal (canal_id),
    id_pedido_erp      VARCHAR(20)   NOT NULL,      -- dimensión degenerada
    estado_pedido      VARCHAR(20)   NOT NULL,      -- dimensión degenerada (4 valores)
    es_venta_valida    BOOLEAN       NOT NULL,      -- según core.estado_pedido.cuenta_como_venta
    cantidad           INT           NOT NULL CHECK (cantidad > 0),
    precio_unitario    NUMERIC(10,2) NOT NULL,
    descuento_pct      NUMERIC(5,2)  NOT NULL,
    importe_bruto      NUMERIC(12,2) NOT NULL,      -- cantidad * precio
    importe_descuento  NUMERIC(12,2) NOT NULL,
    importe_neto       NUMERIC(12,2) NOT NULL,      -- bruto - descuento
    coste_total        NUMERIC(12,2),               -- cantidad * coste actual del producto
    margen             NUMERIC(12,2),               -- neto - coste_total
    PRIMARY KEY (pedido_id, num_linea),
    CONSTRAINT ck_fact_importes CHECK (importe_neto = importe_bruto - importe_descuento)
);

CREATE INDEX IF NOT EXISTS ix_fact_ventas_fecha    ON consume.fact_ventas (fecha_id);
CREATE INDEX IF NOT EXISTS ix_fact_ventas_cliente  ON consume.fact_ventas (cliente_id);
CREATE INDEX IF NOT EXISTS ix_fact_ventas_producto ON consume.fact_ventas (producto_id);

COMMENT ON COLUMN consume.fact_ventas.coste_total IS
    'Se calcula con el coste actual del producto: el ERP no aporta coste histórico';

-- Resultados analíticos

-- Catálogo de segmentos: si Marketing cambia una definición, se cambia una fila
CREATE TABLE IF NOT EXISTS consume.segmento (
    segmento_id        SMALLINT     PRIMARY KEY,
    codigo             VARCHAR(30)  NOT NULL UNIQUE,
    nombre             VARCHAR(40)  NOT NULL UNIQUE,
    descripcion        VARCHAR(300) NOT NULL,
    criterio           VARCHAR(300) NOT NULL,
    accion_recomendada VARCHAR(300) NOT NULL,
    prioridad          SMALLINT     NOT NULL UNIQUE    -- orden de evaluación de las reglas
);

-- Historial RFM: una fila por cliente y fecha de cálculo
CREATE TABLE IF NOT EXISTS consume.cliente_rfm (
    cliente_id       BIGINT        NOT NULL REFERENCES consume.dim_cliente (cliente_id),
    fecha_calculo    DATE          NOT NULL,
    recencia_dias    INT           NOT NULL CHECK (recencia_dias >= 0),
    frecuencia       INT           NOT NULL CHECK (frecuencia > 0),
    valor_monetario  NUMERIC(12,2) NOT NULL CHECK (valor_monetario >= 0),
    r_score          SMALLINT      NOT NULL CHECK (r_score BETWEEN 1 AND 5),
    f_score          SMALLINT      NOT NULL CHECK (f_score BETWEEN 1 AND 5),
    m_score          SMALLINT      NOT NULL CHECK (m_score BETWEEN 1 AND 5),
    segmento_id      SMALLINT      NOT NULL REFERENCES consume.segmento (segmento_id),
    PRIMARY KEY (cliente_id, fecha_calculo)
);

CREATE INDEX IF NOT EXISTS ix_rfm_fecha_segmento ON consume.cliente_rfm (fecha_calculo, segmento_id);

-- Recomendaciones: varias por cliente, ordenadas por ranking
CREATE TABLE IF NOT EXISTS consume.recomendacion (
    cliente_id       BIGINT       NOT NULL REFERENCES consume.dim_cliente (cliente_id),
    fecha_calculo    DATE         NOT NULL,
    ranking          SMALLINT     NOT NULL CHECK (ranking >= 1),
    producto_id      INT          NOT NULL REFERENCES consume.dim_producto (producto_id),
    motivo           VARCHAR(200) NOT NULL,
    puntuacion       NUMERIC(8,4) NOT NULL,
    PRIMARY KEY (cliente_id, fecha_calculo, ranking),
    CONSTRAINT uq_recomendacion_producto UNIQUE (cliente_id, fecha_calculo, producto_id)  -- sin repetir producto
);

CREATE INDEX IF NOT EXISTS ix_recomendacion_producto ON consume.recomendacion (producto_id);

-- Visión 360: una fila por cliente con el último cálculo
CREATE TABLE IF NOT EXISTS consume.cliente_360 (
    cliente_id               BIGINT        PRIMARY KEY REFERENCES consume.dim_cliente (cliente_id),
    num_pedidos              INT           NOT NULL CHECK (num_pedidos >= 0),
    importe_total            NUMERIC(12,2) NOT NULL,
    ticket_medio             NUMERIC(12,2),
    fecha_primera_compra     DATE,
    fecha_ultima_compra      DATE,
    categoria_principal      VARCHAR(60),
    canal_principal          VARCHAR(40),
    segmento                 VARCHAR(40),
    consentimiento_marketing BOOLEAN,
    fecha_calculo            DATE          NOT NULL,
    CONSTRAINT ck_360_fechas CHECK (fecha_ultima_compra >= fecha_primera_compra)
);

-- Audiencias entregadas a Marketing: solo clientes con consentimiento y email válido
CREATE TABLE IF NOT EXISTS consume.audiencia_campana (
    campana_id              VARCHAR(40)  NOT NULL,
    cliente_id              BIGINT       NOT NULL REFERENCES consume.dim_cliente (cliente_id),
    fecha_generacion        DATE         NOT NULL,
    email                   VARCHAR(254) NOT NULL,
    segmento                VARCHAR(40),
    producto_recomendado_id INT          REFERENCES consume.dim_producto (producto_id),
    PRIMARY KEY (campana_id, cliente_id)
);

CREATE INDEX IF NOT EXISTS ix_audiencia_cliente ON consume.audiencia_campana (cliente_id);
