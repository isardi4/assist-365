-- Medición del conector real, no una aproximación de cuatro queries.
-- Cambiar la ventana UTC para medir otra apertura o interacción aislada.
DECLARE inicio TIMESTAMP DEFAULT TIMESTAMP '2026-09-30 21:08:13.362+00';
DECLARE fin TIMESTAMP DEFAULT TIMESTAMP '2026-09-30 21:09:00+00';
DECLARE reporte STRING DEFAULT 'be1247ad-58d9-4ed1-ba70-ca4830505fb3';
DECLARE limite_bytes INT64 DEFAULT 50000000;

WITH jobs AS (
  SELECT creation_time, job_id, state, error_result, cache_hit,
         COALESCE(total_bytes_processed, 0) AS processed_bytes,
         COALESCE(total_bytes_billed, 0) AS billed_bytes, query
  FROM `a365-de-ignacio.region-us-central1.INFORMATION_SCHEMA.JOBS_BY_PROJECT`
  WHERE creation_time >= inicio AND creation_time < fin
    AND job_type = 'QUERY' AND parent_job_id IS NULL
    AND EXISTS (SELECT 1 FROM UNNEST(labels)
                WHERE key = 'requestor' AND value = 'looker_studio')
    AND EXISTS (SELECT 1 FROM UNNEST(labels)
                WHERE key = 'looker_studio_report_id' AND value = reporte)
)
SELECT inicio AS window_start_utc, fin AS window_end_utc,
       COUNT(*) AS job_count, COUNTIF(cache_hit) AS bigquery_cache_hits,
       SUM(processed_bytes) AS processed_bytes,
       ROUND(SUM(processed_bytes) / 1000000, 6) AS processed_mb,
       SUM(billed_bytes) AS billed_bytes,
       ROUND(SUM(billed_bytes) / 1000000, 6) AS billed_mb,
       CASE WHEN COUNT(*) = 0 THEN 'SIN_JOBS_OBSERVADOS'
            WHEN COUNTIF(state != 'DONE' OR error_result IS NOT NULL) > 0
              THEN 'INCOMPLETO_O_ERROR'
            WHEN SUM(processed_bytes) <= limite_bytes THEN 'PASS'
            ELSE 'SUPERA_LIMITE' END AS scan_check,
       ARRAY_AGG(STRUCT(creation_time, job_id, cache_hit, processed_bytes,
                        billed_bytes, state, query) ORDER BY creation_time, job_id) AS jobs
FROM jobs;
