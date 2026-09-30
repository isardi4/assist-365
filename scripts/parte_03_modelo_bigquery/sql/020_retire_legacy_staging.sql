-- Retirar tablas y vistas heredadas solo después de validar el nuevo staging.
DROP VIEW IF EXISTS `a365-de-ignacio.assist365_staging.v_polizas_eventos_iniciales`;
DROP VIEW IF EXISTS `a365-de-ignacio.assist365_staging.v_siniestros_iniciales`;
DROP VIEW IF EXISTS `a365-de-ignacio.assist365_staging.v_tipo_cambio_inicial`;
DROP VIEW IF EXISTS `a365-de-ignacio.assist365_staging.v_polizas_no_borradas`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.dim_polizas`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.dim_agencias`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.dim_productos`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.fact_polizas_eventos`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.fact_polizas_emisiones`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.fact_siniestros`;
DROP TABLE IF EXISTS `a365-de-ignacio.assist365_staging.fact_tipo_cambio`;
