-- Migración de la tabla raw heredada a tablas por recurso; no es una carga diaria.
CREATE SCHEMA IF NOT EXISTS `a365-de-ignacio.assist365_control` OPTIONS (
  location = "us-central1",
  description
  = "Controles operativos de extracción, carga, conciliación, errores, avance de watermarks y comparación de snapshots del pipeline Assist-365. Separados de los datasets de datos raw, staging y mart para mantener responsabilidades claras."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.polizas` LIKE `a365-de-ignacio.assist365_raw.records`;

INSERT INTO `a365-de-ignacio.assist365_raw.polizas` SELECT * FROM `a365-de-ignacio.assist365_raw.records` r
WHERE
  DATE(ingested_at) = '2026-09-29' AND resource = 'polizas'
  AND NOT EXISTS (
    SELECT 1
    FROM `a365-de-ignacio.assist365_raw.polizas` d
    WHERE
      DATE(d.ingested_at) = '2026-09-29'
      AND d.run_id = r.run_id AND d.page_number = r.page_number AND d.record_index = r.record_index
  );

ALTER TABLE `a365-de-ignacio.assist365_raw.polizas` SET OPTIONS (
  description
  = "Esta tabla conserva exclusivamente los registros raw del recurso polizas recibidos desde la API Assist-365. Mantiene el payload JSON completo, sus variantes y anomalías de origen junto a los metadatos técnicos de extracción para auditoría, trazabilidad y reproceso. Constituye la entrada del modelado de este recurso en staging y no aplica normalización ni deduplicación de negocio."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.siniestros` LIKE `a365-de-ignacio.assist365_raw.records`;

INSERT INTO `a365-de-ignacio.assist365_raw.siniestros` SELECT * FROM `a365-de-ignacio.assist365_raw.records` r
WHERE
  DATE(ingested_at) = '2026-09-29' AND resource = 'siniestros'
  AND NOT EXISTS (
    SELECT 1
    FROM `a365-de-ignacio.assist365_raw.siniestros` d
    WHERE
      DATE(d.ingested_at) = '2026-09-29'
      AND d.run_id = r.run_id AND d.page_number = r.page_number AND d.record_index = r.record_index
  );

ALTER TABLE `a365-de-ignacio.assist365_raw.siniestros` SET OPTIONS (
  description
  = "Esta tabla conserva exclusivamente los registros raw del recurso siniestros recibidos desde la API Assist-365. Mantiene el payload JSON completo, sus variantes y anomalías de origen junto a los metadatos técnicos de extracción para auditoría, trazabilidad y reproceso. Constituye la entrada del modelado de este recurso en staging y no aplica normalización ni deduplicación de negocio."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.agencias` LIKE `a365-de-ignacio.assist365_raw.records`;

INSERT INTO `a365-de-ignacio.assist365_raw.agencias` SELECT * FROM `a365-de-ignacio.assist365_raw.records` r
WHERE
  DATE(ingested_at) = '2026-09-29' AND resource = 'agencias'
  AND NOT EXISTS (
    SELECT 1
    FROM `a365-de-ignacio.assist365_raw.agencias` d
    WHERE
      DATE(d.ingested_at) = '2026-09-29'
      AND d.run_id = r.run_id AND d.page_number = r.page_number AND d.record_index = r.record_index
  );

ALTER TABLE `a365-de-ignacio.assist365_raw.agencias` SET OPTIONS (
  description
  = "Esta tabla conserva exclusivamente los registros raw del recurso agencias recibidos desde la API Assist-365. Mantiene el payload JSON completo, sus variantes y anomalías de origen junto a los metadatos técnicos de extracción para auditoría, trazabilidad y reproceso. Constituye la entrada del modelado de este recurso en staging y no aplica normalización ni deduplicación de negocio."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.productos` LIKE `a365-de-ignacio.assist365_raw.records`;

INSERT INTO `a365-de-ignacio.assist365_raw.productos` SELECT * FROM `a365-de-ignacio.assist365_raw.records` r
WHERE
  DATE(ingested_at) = '2026-09-29' AND resource = 'productos'
  AND NOT EXISTS (
    SELECT 1
    FROM `a365-de-ignacio.assist365_raw.productos` d
    WHERE
      DATE(d.ingested_at) = '2026-09-29'
      AND d.run_id = r.run_id AND d.page_number = r.page_number AND d.record_index = r.record_index
  );

ALTER TABLE `a365-de-ignacio.assist365_raw.productos` SET OPTIONS (
  description
  = "Esta tabla conserva exclusivamente los registros raw del recurso productos recibidos desde la API Assist-365. Mantiene el payload JSON completo, sus variantes y anomalías de origen junto a los metadatos técnicos de extracción para auditoría, trazabilidad y reproceso. Constituye la entrada del modelado de este recurso en staging y no aplica normalización ni deduplicación de negocio."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.tipo_cambio` LIKE `a365-de-ignacio.assist365_raw.records`;

INSERT INTO `a365-de-ignacio.assist365_raw.tipo_cambio` SELECT * FROM `a365-de-ignacio.assist365_raw.records` r
WHERE
  DATE(ingested_at) = '2026-09-29' AND resource = 'tipo_cambio'
  AND NOT EXISTS (
    SELECT 1
    FROM `a365-de-ignacio.assist365_raw.tipo_cambio` d
    WHERE
      DATE(d.ingested_at) = '2026-09-29'
      AND d.run_id = r.run_id AND d.page_number = r.page_number AND d.record_index = r.record_index
  );

ALTER TABLE `a365-de-ignacio.assist365_raw.tipo_cambio` SET OPTIONS (
  description
  = "Esta tabla conserva exclusivamente los registros raw del recurso tipo_cambio recibidos desde la API Assist-365. Mantiene el payload JSON completo, sus variantes y anomalías de origen junto a los metadatos técnicos de extracción para auditoría, trazabilidad y reproceso. Constituye la entrada del modelado de este recurso en staging y no aplica normalización ni deduplicación de negocio."
);

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.ingestion_runs` CLONE `a365-de-ignacio.assist365_raw.ingestion_runs`;

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.ingestion_errors` CLONE `a365-de-ignacio.assist365_raw.ingestion_errors`;

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.reconciliations` CLONE `a365-de-ignacio.assist365_raw.reconciliations`;

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.watermarks` CLONE `a365-de-ignacio.assist365_raw.watermarks`;

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.snapshot_diffs` CLONE `a365-de-ignacio.assist365_raw.snapshot_diffs`;

CREATE TEMP TABLE migrated AS
SELECT TO_JSON_STRING(t) AS row_json
FROM `a365-de-ignacio.assist365_raw.polizas` t
WHERE DATE(ingested_at) = '2026-09-29'
UNION ALL
SELECT TO_JSON_STRING(t) AS row_json
FROM `a365-de-ignacio.assist365_raw.siniestros` t
WHERE DATE(ingested_at) = '2026-09-29'
UNION ALL
SELECT TO_JSON_STRING(t) AS row_json
FROM `a365-de-ignacio.assist365_raw.agencias` t
WHERE DATE(ingested_at) = '2026-09-29'
UNION ALL
SELECT TO_JSON_STRING(t) AS row_json
FROM `a365-de-ignacio.assist365_raw.productos` t
WHERE DATE(ingested_at) = '2026-09-29'
UNION ALL
SELECT TO_JSON_STRING(t) AS row_json
FROM `a365-de-ignacio.assist365_raw.tipo_cambio` t
WHERE DATE(ingested_at) = '2026-09-29';

ASSERT (SELECT COUNT(*) FROM migrated)
= (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.records`
  WHERE DATE(ingested_at) = '2026-09-29'
) AS 'Raw row counts differ';

ASSERT (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.records`
  WHERE DATE(ingested_at) >= '1970-01-01'
)
= (SELECT COUNT(*) FROM migrated) AS 'Unexpected source partitions';

ASSERT NOT EXISTS (
  (
    SELECT TO_JSON_STRING(t) AS row_json FROM `a365-de-ignacio.assist365_raw.records` t
    WHERE DATE(ingested_at) = '2026-09-29'
  )
  EXCEPT DISTINCT
  (SELECT row_json FROM migrated)
) AS 'Missing or changed raw rows';

ASSERT NOT EXISTS (
  (SELECT row_json FROM migrated)
  EXCEPT DISTINCT
  (
    SELECT TO_JSON_STRING(t) AS row_json FROM `a365-de-ignacio.assist365_raw.records` t
    WHERE DATE(ingested_at) = '2026-09-29'
  )
) AS 'Unexpected raw rows';

ASSERT (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_control.ingestion_runs`
  WHERE started_at >= TIMESTAMP('1970-01-01')
)
= (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.ingestion_runs`
  WHERE started_at >= TIMESTAMP('1970-01-01')
) AS 'Control count differs: ingestion_runs';

ASSERT (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_control.ingestion_errors`
  WHERE created_at >= TIMESTAMP('1970-01-01')
)
= (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.ingestion_errors`
  WHERE created_at >= TIMESTAMP('1970-01-01')
) AS 'Control count differs: ingestion_errors';

ASSERT (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_control.reconciliations`
  WHERE checked_at >= TIMESTAMP('1970-01-01')
)
= (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.reconciliations`
  WHERE checked_at >= TIMESTAMP('1970-01-01')
) AS 'Control count differs: reconciliations';

ASSERT (SELECT COUNT(*) FROM `a365-de-ignacio.assist365_control.watermarks`)
= (SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.watermarks`) AS 'Control count differs: watermarks';

ASSERT (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_control.snapshot_diffs`
  WHERE compared_at >= TIMESTAMP('1970-01-01')
)
= (
  SELECT COUNT(*) FROM `a365-de-ignacio.assist365_raw.snapshot_diffs`
  WHERE compared_at >= TIMESTAMP('1970-01-01')
) AS 'Control count differs: snapshot_diffs';

DROP TABLE `a365-de-ignacio.assist365_raw.ingestion_runs`;

DROP TABLE `a365-de-ignacio.assist365_raw.ingestion_errors`;

DROP TABLE `a365-de-ignacio.assist365_raw.reconciliations`;

DROP TABLE `a365-de-ignacio.assist365_raw.watermarks`;

DROP TABLE `a365-de-ignacio.assist365_raw.snapshot_diffs`;

DROP TABLE `a365-de-ignacio.assist365_raw.records`;

SELECT
  table_schema,
  table_name
FROM `a365-de-ignacio.region-us-central1.INFORMATION_SCHEMA.TABLES`
WHERE table_schema IN ('assist365_raw', 'assist365_control', 'assist365_staging', 'assist365_mart')
ORDER BY table_schema, table_name;
