-- Definición de los esquema (capas) de Aurora Market
-- staging -> datos tal cual llegan del CSV, todo en texto
-- core -> modelo normalizado y depurado
-- consume -> modelo dimensional (estrella) y resultados analíticos
-- control -> operativa del proceso (ejecuciones, mapeos, calidad, cuarentena)
-- IMPORTANTE: todos los scripts son re-ejecutables

CREATE SCHEMA IF NOT EXISTS control;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS consume;