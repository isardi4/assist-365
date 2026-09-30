-- Revisar cambios de vigencia y coincidencia de cobertura con siniestros.
CREATE TEMP TABLE events AS
SELECT
  *,
  LAG(STRUCT(inicio_vigencia, fin_vigencia, prima, moneda, operacion))
    OVER (PARTITION BY poliza_id ORDER BY updated_at)
    anterior
FROM `a365-de-ignacio.assist365_staging.polizas`;
SELECT
  'updates' metrica,
  COUNT(*) cantidad
FROM events
WHERE operacion = 'U'
UNION ALL
SELECT
  'updates_same_period',
  COUNT(*)
FROM events
WHERE
  operacion = 'U'
  AND inicio_vigencia IS NOT DISTINCT FROM anterior.inicio_vigencia
  AND fin_vigencia IS NOT DISTINCT FROM anterior.fin_vigencia
UNION ALL
SELECT
  'updates_changed_period',
  COUNT(*)
FROM events
WHERE
  operacion = 'U'
  AND anterior IS NOT NULL
  AND (inicio_vigencia IS DISTINCT FROM anterior.inicio_vigencia OR fin_vigencia IS DISTINCT FROM anterior.fin_vigencia)
UNION ALL
SELECT
  'updates_without_predecessor',
  COUNT(*)
FROM events
WHERE operacion = 'U' AND anterior IS NULL
UNION ALL
SELECT
  'updates_same_period_changed_premium',
  COUNT(*)
FROM events
WHERE
  operacion = 'U'
  AND inicio_vigencia IS NOT DISTINCT FROM anterior.inicio_vigencia
  AND fin_vigencia IS NOT DISTINCT FROM anterior.fin_vigencia
  AND (prima IS DISTINCT FROM anterior.prima OR moneda IS DISTINCT FROM anterior.moneda)
UNION ALL
SELECT
  'policies_with_updates',
  COUNT(DISTINCT poliza_id)
FROM events
WHERE operacion = 'U'
UNION ALL
SELECT
  'invalid_period_events',
  COUNT(*)
FROM events
WHERE inicio_vigencia IS NULL OR fin_vigencia IS NULL OR inicio_vigencia > fin_vigencia;
CREATE TEMP TABLE periods AS
SELECT * FROM events
WHERE operacion != 'D'
QUALIFY ROW_NUMBER() OVER (PARTITION BY poliza_id, inicio_vigencia, fin_vigencia ORDER BY updated_at DESC) = 1;
SELECT
  'distinct_policy_periods' metrica,
  COUNT(*) cantidad
FROM periods
UNION ALL
SELECT
  'policies_multiple_periods',
  COUNT(*)
FROM (
  SELECT poliza_id FROM periods
  GROUP BY poliza_id
  HAVING COUNT(*) > 1
)
UNION ALL
SELECT
  'overlapping_period_pairs',
  COUNT(*)
FROM periods a
JOIN
  periods b
  ON a.poliza_id = b.poliza_id AND a.inicio_vigencia < b.inicio_vigencia AND b.inicio_vigencia <= a.fin_vigencia
UNION ALL
SELECT
  'same_start_different_end_pairs',
  COUNT(*)
FROM periods a
JOIN
  periods b
  ON a.poliza_id = b.poliza_id AND a.inicio_vigencia = b.inicio_vigencia AND a.fin_vigencia < b.fin_vigencia;
SELECT
  e.operacion,
  COUNT(*) eventos,
  COUNT(DISTINCT e.poliza_id) polizas
FROM events e
GROUP BY 1;
SELECT
  COUNT(*) siniestros,
  COUNTIF(matches = 0) sin_periodo,
  COUNTIF(matches = 1) un_periodo,
  COUNTIF(matches > 1) multiples_periodos
FROM
  (
    SELECT
      s.siniestro_id,
      COUNT(p.poliza_id) matches
    FROM `a365-de-ignacio.assist365_staging.siniestros` s
    LEFT JOIN periods p ON s.poliza_id = p.poliza_id AND s.fecha_ocurrencia BETWEEN p.inicio_vigencia AND p.fin_vigencia
    GROUP BY s.siniestro_id
  );
