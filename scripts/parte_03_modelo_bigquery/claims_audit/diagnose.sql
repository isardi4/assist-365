-- Revisar negativos, monedas faltantes y casos sin cobertura coincidente.
CREATE TEMP TABLE periods AS
SELECT DISTINCT
  poliza_id,
  inicio_vigencia,
  fin_vigencia
FROM `a365-de-ignacio.assist365_staging.polizas`
WHERE operacion != 'D';
CREATE TEMP TABLE policies AS
SELECT
  poliza_id,
  moneda,
  estado,
  operacion,
  inicio_vigencia,
  fin_vigencia
FROM `a365-de-ignacio.assist365_staging.polizas`
QUALIFY ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;
CREATE TEMP TABLE audit AS
SELECT
  s.*,
  p.moneda moneda_poliza,
  p.estado estado_poliza,
  p.operacion,
  CASE
    WHEN p.poliza_id IS NULL THEN 'POLIZA_AUSENTE'
    WHEN
      EXISTS (
        SELECT 1 FROM periods v
        WHERE v.poliza_id = s.poliza_id AND s.fecha_ocurrencia BETWEEN v.inicio_vigencia AND v.fin_vigencia
      )
      THEN 'COINCIDE'
    ELSE 'FUERA_PERIODO'
  END estado_cobertura,
  CASE WHEN p.poliza_id IS NULL THEN NULL ELSE DATE_DIFF(s.fecha_ocurrencia, p.inicio_vigencia, DAY) END
    dias_desde_inicio,
  CASE WHEN p.poliza_id IS NULL THEN NULL ELSE DATE_DIFF(s.fecha_ocurrencia, p.fin_vigencia, DAY) END dias_desde_fin
FROM `a365-de-ignacio.assist365_staging.siniestros` s LEFT JOIN policies p USING (poliza_id);
SELECT
  estado_cobertura,
  estado,
  COUNT(*) cantidad,
  COUNTIF(monto < 0) negativos,
  COUNTIF(moneda IS NULL) moneda_nula
FROM audit
GROUP BY 1, 2
ORDER BY 1, 2;
SELECT
  estado_cobertura,
  CASE WHEN dias_desde_inicio < 0 THEN 'ANTES_INICIO' ELSE 'DESPUES_FIN' END posicion,
  COUNT(*) cantidad,
  MIN(IF(dias_desde_inicio < 0, -dias_desde_inicio, dias_desde_fin)) dias_min,
  MAX(IF(dias_desde_inicio < 0, -dias_desde_inicio, dias_desde_fin)) dias_max
FROM audit
WHERE estado_cobertura = 'FUERA_PERIODO'
GROUP BY 1, 2
;
SELECT
  estado,
  moneda,
  COUNT(*) cantidad,
  MIN(monto) minimo,
  MAX(monto) maximo,
  SUM(monto) total_local
FROM audit
WHERE monto < 0
GROUP BY 1, 2
ORDER BY 1, 2;
SELECT
  estado,
  moneda_poliza,
  COUNT(*) cantidad
FROM audit
WHERE moneda IS NULL
GROUP BY 1, 2
ORDER BY 1, 2;
SELECT
  COUNT(*) con_moneda_y_poliza,
  COUNTIF(moneda = moneda_poliza) misma_moneda,
  COUNTIF(moneda != moneda_poliza) diferente_moneda
FROM audit
WHERE moneda IS NOT NULL AND moneda_poliza IS NOT NULL;
SELECT
  'missing_currency_paid' caso,
  COUNT(*) cantidad,
  COUNTIF(estado_cobertura != 'COINCIDE') sin_periodo,
  COUNTIF(monto < 0) negativos
FROM audit
WHERE moneda IS NULL AND estado = 'PAGADO'
UNION ALL
SELECT
  'negative_paid',
  COUNT(*),
  COUNTIF(estado_cobertura != 'COINCIDE'),
  COUNTIF(moneda IS NULL)
FROM audit
WHERE monto < 0 AND estado = 'PAGADO';
