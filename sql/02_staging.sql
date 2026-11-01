-- Esquema de staging
-- Una tabla por entidad
-- La carga completa y los delta van a la misma tabla y se distinguen por id_ejecucion / fichero_origen
-- Todas las columnas de negocio son TEXT para no rechazar nada al leer
-- Clave: (id_ejecucion, num_fila) -> identifica la fila exacta del fichero

CREATE TABLE IF NOT EXISTS staging.clientes (
    id_ejecucion             BIGINT      NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    num_fila                 INT         NOT NULL,
    fichero_origen           VARCHAR(255) NOT NULL,
    fecha_carga              TIMESTAMPTZ NOT NULL DEFAULT now(),
    hash_fila                CHAR(32)    NOT NULL,          -- MD5 de la fila original
    id_cliente               TEXT,
    nombre                   TEXT,
    apellidos                TEXT,
    email                    TEXT,
    telefono                 TEXT,
    pais                     TEXT,
    ciudad                   TEXT,
    fecha_alta               TEXT,
    consentimiento_marketing TEXT,
    PRIMARY KEY (id_ejecucion, num_fila)
);

CREATE TABLE IF NOT EXISTS staging.productos (
    id_ejecucion             BIGINT      NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    num_fila                 INT         NOT NULL,
    fichero_origen           VARCHAR(255) NOT NULL,
    fecha_carga              TIMESTAMPTZ NOT NULL DEFAULT now(),
    hash_fila                CHAR(32)    NOT NULL,
    id_producto              TEXT,
    nombre                   TEXT,
    categoria                TEXT,
    subcategoria             TEXT,
    marca                    TEXT,
    precio_lista             TEXT,
    coste                    TEXT,
    activo                   TEXT,
    PRIMARY KEY (id_ejecucion, num_fila)
);

CREATE TABLE IF NOT EXISTS staging.pedidos (
    id_ejecucion             BIGINT      NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    num_fila                 INT         NOT NULL,
    fichero_origen           VARCHAR(255) NOT NULL,
    fecha_carga              TIMESTAMPTZ NOT NULL DEFAULT now(),
    hash_fila                CHAR(32)    NOT NULL,
    id_pedido                TEXT,
    id_cliente               TEXT,
    fecha_pedido             TEXT,
    estado                   TEXT,
    canal                    TEXT,
    importe_total_erp        TEXT,
    PRIMARY KEY (id_ejecucion, num_fila)
);

CREATE TABLE IF NOT EXISTS staging.lineas_pedido (
    id_ejecucion             BIGINT      NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    num_fila                 INT         NOT NULL,
    fichero_origen           VARCHAR(255) NOT NULL,
    fecha_carga              TIMESTAMPTZ NOT NULL DEFAULT now(),
    hash_fila                CHAR(32)    NOT NULL,
    id_pedido                TEXT,
    num_linea                TEXT,
    id_producto              TEXT,
    cantidad                 TEXT,
    precio_unitario          TEXT,
    descuento_pct            TEXT,
    PRIMARY KEY (id_ejecucion, num_fila)
);