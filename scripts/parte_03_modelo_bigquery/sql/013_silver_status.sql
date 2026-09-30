-- Evidencia operativa; staging permanece libre de identificadores de carga.
SELECT run_id,job_id,run_status,
 JSON_VALUE(summary,'$.checks_passed') checks_passed,
 JSON_VALUE(summary,'$.batch_fingerprint') batch_fingerprint,
 JSON_QUERY(summary,'$.business_mutations') business_mutations,
 error_message
FROM `a365-de-ignacio.assist365_control.silver_runs`
WHERE DATE(started_at)>=DATE '2026-09-29'
ORDER BY started_at;
