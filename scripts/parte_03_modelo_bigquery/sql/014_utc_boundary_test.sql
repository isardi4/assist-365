-- Comprobar la conversión de fechas UTC con casos de borde temporales.
CREATE TEMP TABLE attempts AS
SELECT
  'midnight-test' job_id,
  TIMESTAMP '2024-01-01 23:59:00+00' started_at,
  CAST(NULL AS TIMESTAMP) finished_at,
  'RUNNING' run_status,
  CAST(NULL AS JSON) summary;
CREATE TEMP TABLE silver_checks (check_name STRING);
CREATE TEMP TABLE batch_polizas (poliza_id STRING);
CREATE TEMP TABLE silver_mutations (table_name STRING, changed_rows INT64);
UPDATE attempts SET
  finished_at = CURRENT_TIMESTAMP(),
  run_status = 'SUCCESS',
  summary
  = TO_JSON(
    STRUCT(
      (SELECT COUNT(*) FROM silver_checks) AS checks_passed,
      'test-hash' AS batch_fingerprint,
      (SELECT COUNT(*) FROM batch_polizas) AS policy_events_in_batch,
      (SELECT ARRAY_AGG(STRUCT(table_name, changed_rows)) FROM silver_mutations) AS business_mutations
    )
  )
WHERE DATE(started_at) >= DATE '1970-01-01' AND job_id = 'midnight-test';
ASSERT (SELECT run_status FROM attempts)
= 'SUCCESS' AS 'Un intento de un día anterior puede finalizar después de medianoche';
SELECT
  'PASS' status,
  'UTC boundary' scope;
