CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.records` (
  ingested_at TIMESTAMP,
  run_id STRING,
  batch_id STRING,
  resource STRING,
  snapshot_id STRING,
  page_number INT64,
  record_index INT64,
  source_key STRING,
  source_updated_at TIMESTAMP,
  record_hash STRING,
  source_file STRING,
  payload JSON
)
PARTITION BY DATE(ingested_at)
CLUSTER BY resource, run_id, source_key
OPTIONS (require_partition_filter = TRUE, description = "Esta tabla conserva en BigQuery la representación raw de los registros obtenidos de la API, junto con el contexto de extracción que permite rastrear cada elemento hasta su ejecución, lote, página y archivo local de origen. Se utiliza como fuente auditable para reprocesos, perfilado y modelos posteriores, manteniendo el payload completo sin limitarlo a columnas analíticas conocidas.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.ingestion_runs` (
  run_id STRING,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  run_status STRING,
  invocation_mode STRING,
  source_watermark_before TIMESTAMP,
  source_watermark_after TIMESTAMP,
  http_requests INT64,
  http_retries INT64,
  summary JSON
)
PARTITION BY DATE(started_at)
CLUSTER BY run_status, run_id
OPTIONS (require_partition_filter = TRUE, description = "Esta tabla registra en BigQuery el ciclo de vida y el resultado operativo de cada ejecución de extracción. Permite medir solicitudes y reintentos, conocer los watermarks observados y consultar el resumen de procesamiento para demostrar qué se intentó cargar, detectar ejecuciones incompletas y comparar corridas sin depender de logs efímeros de la máquina.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.ingestion_errors` (
  created_at TIMESTAMP,
  run_id STRING,
  resource STRING,
  batch_id STRING,
  page_number INT64,
  record_index INT64,
  source_key STRING,
  error_class STRING,
  message STRING,
  fingerprint_sha256 STRING,
  source_file STRING,
  resolution_status STRING
)
PARTITION BY DATE(created_at)
CLUSTER BY resource, run_id, error_class
OPTIONS (require_partition_filter = TRUE, description = "Esta tabla centraliza en BigQuery los errores asociados a registros o etapas de extracción, con referencias para volver al recurso, lote, página, archivo y ejecución que los originó. Sirve como cola auditable de investigación y resolución: cada falla debe quedar identificada, clasificable y vinculada a su estado de tratamiento, evitando que errores individuales queden ocultos en un resultado agregado.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.reconciliations` (
  checked_at TIMESTAMP,
  run_id STRING,
  resource STRING,
  check_name STRING,
  check_status STRING,
  expected_count INT64,
  actual_count INT64,
  difference_count INT64,
  details JSON
)
PARTITION BY DATE(checked_at)
CLUSTER BY resource, run_id, check_status
OPTIONS (require_partition_filter = TRUE, description = "Esta tabla almacena en BigQuery los resultados de controles de integridad y reconciliación ejecutados sobre cada recurso y corrida. Sus conteos esperados, observados y diferencias permiten confirmar explícitamente si una extracción o proceso fue completo; el detalle JSON conserva evidencia diagnóstica para investigar discrepancias sin escanear nuevamente los datos de origen.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.watermarks` (
  resource STRING,
  watermark TIMESTAMP,
  committed_at TIMESTAMP,
  committed_run_id STRING,
  overlap_seconds INT64
)
CLUSTER BY resource
OPTIONS (description = "Esta tabla mantiene en BigQuery el punto de avance confirmado por recurso para orientar las siguientes cargas incrementales. El watermark solo debe avanzar tras completar las validaciones de la corrida asociada; el margen de solapamiento facilita recuperar cambios tardíos y su historial permite auditar qué ejecución comprometió cada posición de lectura.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_raw.snapshot_diffs` (
  compared_at TIMESTAMP,
  resource STRING,
  previous_snapshot_id STRING,
  current_snapshot_id STRING,
  source_key STRING,
  change_type STRING,
  previous_hash STRING,
  current_hash STRING,
  review_status STRING
)
PARTITION BY DATE(compared_at)
CLUSTER BY resource, change_type, source_key
OPTIONS (require_partition_filter = TRUE, description = "Esta tabla conserva en BigQuery las diferencias calculadas entre snapshots sucesivos, incluyendo claves presentes, hashes comparados y estado de revisión. Se usa para detectar altas, modificaciones y posibles ausencias que requieren análisis; una ausencia no se interpreta automáticamente como baja y cada diferencia queda disponible para revisión y trazabilidad.");
