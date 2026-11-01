-- Esquema de control
-- Una fila por fichero procesado
-- Necesario para la trazabilidad: su id se guarda en staging, core, incidencias y cuarentena
CREATE TABLE IF NOT EXISTS control.ejecucion (
    id_ejecucion        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fichero_origen      VARCHAR(255) NOT NULL,
    entidad             VARCHAR(30)  NOT NULL
                        CHECK (entidad IN ('clientes', 'productos', 'pedidos', 'lineas_pedido')),
    tipo_carga          VARCHAR(10)  NOT NULL CHECK (tipo_carga IN ('completa', 'delta')),
    hash_fichero        CHAR(64)     NOT NULL,              -- SHA-256 del contenido
    estado              VARCHAR(15)  NOT NULL DEFAULT 'en_curso'
                        CHECK (estado IN ('en_curso', 'correcta', 'fallida', 'omitida')),
    fecha_inicio        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    fecha_fin           TIMESTAMPTZ,
    filas_leidas        INT CHECK (filas_leidas       >= 0),
    filas_insertadas    INT CHECK (filas_insertadas   >= 0),
    filas_actualizadas  INT CHECK (filas_actualizadas >= 0),
    filas_sin_cambios   INT CHECK (filas_sin_cambios  >= 0),
    filas_corregidas    INT CHECK (filas_corregidas   >= 0),
    filas_rechazadas    INT CHECK (filas_rechazadas   >= 0),
    mensaje_error       TEXT,
    CONSTRAINT ck_ejecucion_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio)
);

-- Idempotencia a nivel de fichero
-- Un mismo contenido solo puede cargarse correctamente una vez
-- Si se repite, la ejecución se registra como 'omitida'
CREATE UNIQUE INDEX IF NOT EXISTS ux_ejecucion_hash_correcta
    ON control.ejecucion (hash_fichero) WHERE estado = 'correcta';

COMMENT ON TABLE control.ejecucion IS 'Registro de cada fichero procesado, con su hash, estado y contadores.';

-- Traducción de valores sucios del origen a valores normalizados
-- valor_origen se guarda en MAYÚSCULAS y sin espacios laterales
-- La búsqueda se hace con upper(trim(valor))
-- Añadir un país nuevo inserta filas aquí
CREATE TABLE IF NOT EXISTS control.mapeo_valores (
    dominio             VARCHAR(30)  NOT NULL
                        CHECK (dominio IN ('pais', 'canal', 'estado_pedido', 'consentimiento')),
    valor_origen        VARCHAR(100) NOT NULL CHECK (valor_origen = upper(trim(valor_origen))),
    valor_normalizado   VARCHAR(100) NOT NULL,
    PRIMARY KEY (dominio, valor_origen)
);

COMMENT ON TABLE control.mapeo_valores IS 'Tabla de normalización: España/ESP/Spain -> ES, Teléfono/Telefono -> TELEFONO, S/SI/1 -> true...';

-- Catálogo de reglas de calidad y la acción que se toma cuando se incumplen
CREATE TABLE IF NOT EXISTS control.regla_calidad (
    regla_id            VARCHAR(40)  PRIMARY KEY,
    entidad             VARCHAR(30)  NOT NULL
                        CHECK (entidad IN ('clientes', 'productos', 'pedidos', 'lineas_pedido', 'general')),
    descripcion         VARCHAR(300) NOT NULL,
    severidad           VARCHAR(10)  NOT NULL CHECK (severidad IN ('baja', 'media', 'alta')),
    accion              VARCHAR(10)  NOT NULL CHECK (accion IN ('corregir', 'marcar', 'rechazar')),
    activa              BOOLEAN      NOT NULL DEFAULT true
);

-- Registros corregidos o marcados (siguen entrando en core)
CREATE TABLE IF NOT EXISTS control.incidencia_calidad (
    incidencia_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_ejecucion        BIGINT       NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    regla_id            VARCHAR(40)  NOT NULL REFERENCES control.regla_calidad (regla_id),
    entidad             VARCHAR(30)  NOT NULL,
    clave_registro      VARCHAR(100) NOT NULL,
    num_fila            INT,                               -- fila del fichero de origen
    campo               VARCHAR(50),
    valor_original      TEXT,
    valor_nuevo         TEXT,
    fecha_registro      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_incidencia_ejecucion ON control.incidencia_calidad (id_ejecucion);
CREATE INDEX IF NOT EXISTS ix_incidencia_regla     ON control.incidencia_calidad (regla_id);

-- Registros rechazados (no entran en core)
-- Se guarda la fila completa en JSON para poder revisarla y reprocesarla
CREATE TABLE IF NOT EXISTS control.cuarentena (
    cuarentena_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_ejecucion        BIGINT       NOT NULL REFERENCES control.ejecucion (id_ejecucion),
    regla_id            VARCHAR(40)  NOT NULL REFERENCES control.regla_calidad (regla_id),
    entidad             VARCHAR(30)  NOT NULL,
    fichero_origen      VARCHAR(255) NOT NULL,
    num_fila            INT          NOT NULL,
    registro            JSONB        NOT NULL,
    motivo              TEXT         NOT NULL,
    reprocesado         BOOLEAN      NOT NULL DEFAULT false,
    fecha_registro      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_cuarentena_ejecucion ON control.cuarentena (id_ejecucion);
CREATE INDEX IF NOT EXISTS ix_cuarentena_pendiente ON control.cuarentena (entidad) WHERE NOT reprocesado;
