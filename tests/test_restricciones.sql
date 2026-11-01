-- Pruebas de las restricciones del modelo. Todo se deshace al final (ROLLBACK).
-- Cada caso debe fallar (o funcionar) como se indica; se informa OK / FALLO.
BEGIN;

CREATE TEMP TABLE resultado (caso TEXT, esperado TEXT, obtenido TEXT);

CREATE FUNCTION pg_temp.probar(caso TEXT, sentencia TEXT, debe_fallar BOOLEAN) RETURNS void AS $$
BEGIN
    BEGIN
        EXECUTE sentencia;
        INSERT INTO resultado VALUES (caso, CASE WHEN debe_fallar THEN 'rechaza' ELSE 'acepta' END, 'acepta');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO resultado VALUES (caso, CASE WHEN debe_fallar THEN 'rechaza' ELSE 'acepta' END,
                                      'rechaza (' || SQLERRM || ')');
    END;
END $$ LANGUAGE plpgsql;

-- Datos mínimos válidos
INSERT INTO control.ejecucion (fichero_origen, entidad, tipo_carga, hash_fichero, estado)
VALUES ('test.csv', 'pedidos', 'completa', repeat('a', 64), 'correcta');
INSERT INTO core.categoria (categoria_id, nombre) VALUES (1, 'Hogar');
INSERT INTO core.subcategoria (subcategoria_id, categoria_id, nombre) VALUES (1, 1, 'Cocina');
INSERT INTO core.producto (producto_id, id_producto_erp, nombre, subcategoria_id, precio_lista, coste)
VALUES (1, 'P00001', 'Cocina Lumen 328', 1, 5.74, 3.55);
INSERT INTO core.cliente (cliente_id, fecha_alta) VALUES (1, '2025-10-07');
INSERT INTO core.cliente_id_erp VALUES ('C000001', 1, 'alta', now(), NULL);
INSERT INTO core.cliente_version (cliente_id, nombre, email, codigo_pais, consentimiento_marketing,
                                  valido_desde, es_actual, hash_atributos)
VALUES (1, 'Paula', 'paula.munoz3644@empresa.com', 'FR', true, now(), true, md5('x'));
INSERT INTO core.pedido (pedido_id, id_pedido_erp, cliente_id, id_cliente_erp_origen, fecha_pedido,
                         canal_id, estado_id, importe_total_erp)
OVERRIDING SYSTEM VALUE
VALUES (1, 'PED0000001', 1, 'C000001', '2025-04-05 10:33:38', 1, 2, 11.48);
INSERT INTO consume.dim_canal VALUES (1, 'WEB', 'Web');
INSERT INTO consume.dim_cliente (cliente_id, nombre, nombre_completo) VALUES (-1, 'Cliente desconocido', 'Cliente desconocido');
INSERT INTO consume.dim_producto (producto_id, id_producto_erp, nombre, categoria, subcategoria, activo)
VALUES (-1, 'DESCONOCIDO', 'Producto desconocido', 'Desconocida', 'Desconocida', false);
-- Los ids se han insertado a mano: se avanzan las secuencias para no colisionar.
SELECT setval(pg_get_serial_sequence('core.pedido', 'pedido_id'), 100),
       setval(pg_get_serial_sequence('core.producto', 'producto_id'), 100),
       setval(pg_get_serial_sequence('core.cliente', 'cliente_id'), 100),
       setval(pg_get_serial_sequence('core.categoria', 'categoria_id'), 100),
       setval(pg_get_serial_sequence('core.subcategoria', 'subcategoria_id'), 100);

\o /dev/null

-- Casos que deben ACEPTARSE
SELECT pg_temp.probar('Línea válida',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario, descuento_pct) VALUES (1, 1, 1, 'P00001', 2, 2, 5.74, 0)$q$, false);
SELECT pg_temp.probar('Línea corregida (original -1)',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario, descuento_pct) VALUES (1, 2, 1, 'P00001', 1, -1, 5.74, 10)$q$, false);
SELECT pg_temp.probar('Pedido de cliente desconocido (-1)',
  $q$INSERT INTO core.pedido (id_pedido_erp, cliente_id, id_cliente_erp_origen, fecha_pedido, canal_id,
     estado_id, importe_total_erp) VALUES ('PED9', -1, 'C982322', now(), 1, 2, 10)$q$, false);
SELECT pg_temp.probar('Línea de producto desconocido (-1)',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario) VALUES (1, 3, -1, 'P99538', 1, 1, 9.99)$q$, false);
SELECT pg_temp.probar('Producto sin precio de lista',
  $q$INSERT INTO core.producto (id_producto_erp, nombre, subcategoria_id, coste) VALUES ('P00014', 'X', 1, 26.44)$q$, false);

-- Casos que deben RECHAZARSE
SELECT pg_temp.probar('Cantidad 0',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario) VALUES (1, 4, 1, 'P00001', 0, 0, 5.74)$q$, true);
SELECT pg_temp.probar('Descuento 150 %',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario, descuento_pct) VALUES (1, 5, 1, 'P00001', 1, 1, 5.74, 150)$q$, true);
SELECT pg_temp.probar('Línea duplicada (misma PK)',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario) VALUES (1, 1, 1, 'P00001', 1, 1, 5.74)$q$, true);
SELECT pg_temp.probar('Línea de pedido inexistente (FK)',
  $q$INSERT INTO core.linea_pedido (pedido_id, num_linea, producto_id, id_producto_erp_origen, cantidad,
     cantidad_original, precio_unitario) VALUES (999, 1, 1, 'P00001', 1, 1, 5.74)$q$, true);
SELECT pg_temp.probar('Importe de línea escrito a mano (columna calculada)',
  $q$UPDATE core.linea_pedido SET importe_linea = 0 WHERE pedido_id = 1$q$, true);
SELECT pg_temp.probar('Pedido duplicado (id ERP único)',
  $q$INSERT INTO core.pedido (id_pedido_erp, cliente_id, id_cliente_erp_origen, fecha_pedido, canal_id,
     estado_id, importe_total_erp) VALUES ('PED0000001', 1, 'C000001', now(), 1, 2, 10)$q$, true);
SELECT pg_temp.probar('Canal inexistente (FK)',
  $q$INSERT INTO core.pedido (id_pedido_erp, cliente_id, id_cliente_erp_origen, fecha_pedido, canal_id,
     estado_id, importe_total_erp) VALUES ('PED8', 1, 'C000001', now(), 9, 2, 10)$q$, true);
SELECT pg_temp.probar('Dos versiones actuales del mismo cliente',
  $q$INSERT INTO core.cliente_version (cliente_id, nombre, valido_desde, es_actual, hash_atributos)
     VALUES (1, 'Paula', now(), true, md5('y'))$q$, true);
SELECT pg_temp.probar('Versión cerrada marcada como actual',
  $q$INSERT INTO core.cliente_version (cliente_id, nombre, valido_desde, valido_hasta, es_actual, hash_atributos)
     VALUES (1, 'Paula', now() - interval '1 day', now(), true, md5('z'))$q$, true);
SELECT pg_temp.probar('Email sin @',
  $q$UPDATE core.cliente_version SET email = 'lucia.castro4522 outlook.com' WHERE cliente_id = 1$q$, true);
SELECT pg_temp.probar('Email en mayúsculas',
  $q$UPDATE core.cliente_version SET email = 'PAULA@EMPRESA.COM' WHERE cliente_id = 1$q$, true);
SELECT pg_temp.probar('País inexistente en el catálogo (FK)',
  $q$UPDATE core.cliente_version SET codigo_pais = 'XX' WHERE cliente_id = 1$q$, true);
SELECT pg_temp.probar('Mapeo con valor de origen en minúsculas',
  $q$INSERT INTO control.mapeo_valores VALUES ('pais', 'spain', 'ES')$q$, true);
SELECT pg_temp.probar('Mismo fichero cargado dos veces correctamente',
  $q$INSERT INTO control.ejecucion (fichero_origen, entidad, tipo_carga, hash_fichero, estado)
     VALUES ('test_bis.csv', 'pedidos', 'completa', repeat('a', 64), 'correcta')$q$, true);
SELECT pg_temp.probar('Fact con importes incoherentes',
  $q$INSERT INTO consume.fact_ventas VALUES (1,1,20250405,-1,-1,1,'X','ENTREGADO',true,1,10,0,10,0,9,NULL,NULL)$q$, true);

\o
SELECT CASE WHEN left(obtenido, 7) = esperado THEN 'OK   ' ELSE 'FALLO' END AS res, caso,
       obtenido
FROM resultado;

SELECT 'importe_linea calculado' AS comprobacion, num_linea, cantidad, cantidad_original,
       cantidad_corregida, precio_unitario, descuento_pct, importe_linea
FROM core.linea_pedido WHERE pedido_id = 1 ORDER BY num_linea;

ROLLBACK;
