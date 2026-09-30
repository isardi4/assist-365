-- Derived business flags; original currency, amount and status are preserved.
CREATE TEMP TABLE claim_policy_keys AS SELECT DISTINCT poliza_id FROM `a365-de-ignacio.assist365_staging.polizas`;
CREATE TEMP TABLE claim_policy_periods AS SELECT DISTINCT poliza_id,inicio_vigencia,fin_vigencia FROM `a365-de-ignacio.assist365_staging.polizas` WHERE operacion!='D';
CREATE TEMP TABLE claim_policy_currencies AS
SELECT poliza_id,IF(COUNT(DISTINCT UPPER(TRIM(moneda)))=1,MAX(UPPER(TRIM(moneda))),NULL) policy_currency
FROM `a365-de-ignacio.assist365_staging.polizas` GROUP BY poliza_id;
CREATE TEMP TABLE claim_business_flags AS
WITH candidates AS (
 SELECT s.*,COALESCE(NULLIF(UPPER(TRIM(s.moneda)),''),p.policy_currency) analysis_currency,
 CASE WHEN NULLIF(TRIM(s.moneda),'') IS NOT NULL THEN 'FUENTE'
 WHEN p.policy_currency IS NOT NULL THEN 'INFERIDA_POLIZA' ELSE 'NO_DISPONIBLE' END currency_origin
 FROM `a365-de-ignacio.assist365_staging.siniestros` s LEFT JOIN claim_policy_currencies p USING(poliza_id)
), coverage AS (
 SELECT s.siniestro_id,
 CASE WHEN k.poliza_id IS NULL THEN 'POLIZA_AUSENTE'
 WHEN COUNT(v.poliza_id)=0 THEN 'FUERA_PERIODO'
 WHEN COUNT(v.poliza_id)=1 THEN 'COINCIDE' ELSE 'COBERTURA_AMBIGUA' END coverage_state
 FROM `a365-de-ignacio.assist365_staging.siniestros` s LEFT JOIN claim_policy_keys k USING(poliza_id)
 LEFT JOIN claim_policy_periods v ON s.poliza_id=v.poliza_id AND s.fecha_ocurrencia BETWEEN v.inicio_vigencia AND v.fin_vigencia
 GROUP BY s.siniestro_id,k.poliza_id
)
SELECT siniestro_id,coverage_state estado_cobertura,
 CASE WHEN monto IS NULL THEN 'MONTO_NULO'
 WHEN monto<0 AND moneda IS NULL THEN 'MONTO_NEGATIVO_Y_MONEDA_NULA'
 WHEN monto<0 THEN 'MONTO_NEGATIVO'
 WHEN analysis_currency IS NULL THEN 'MONEDA_NO_RECUPERABLE'
 WHEN analysis_currency!='USD' AND NOT EXISTS(SELECT 1 FROM `a365-de-ignacio.assist365_staging.tipo_cambio` f WHERE f.moneda=analysis_currency AND f.fecha<=fecha_ocurrencia AND f.factor_usd>0) THEN 'SIN_COTIZACION'
 WHEN currency_origin='INFERIDA_POLIZA' THEN 'VALIDO_MONEDA_INFERIDA' ELSE 'VALIDO' END estado_importe,
 analysis_currency moneda_analisis,currency_origin origen_moneda_analisis,
 monto IS NULL OR monto<0 OR analysis_currency IS NULL OR
 (analysis_currency!='USD' AND NOT EXISTS(SELECT 1 FROM `a365-de-ignacio.assist365_staging.tipo_cambio` f WHERE f.moneda=analysis_currency AND f.fecha<=fecha_ocurrencia AND f.factor_usd>0)) excluir_calculos
FROM candidates s JOIN coverage USING(siniestro_id);
MERGE `a365-de-ignacio.assist365_staging.siniestros` t USING claim_business_flags s ON t.siniestro_id=s.siniestro_id
WHEN MATCHED AND (t.estado_cobertura IS DISTINCT FROM s.estado_cobertura OR t.estado_importe IS DISTINCT FROM s.estado_importe OR t.moneda_analisis IS DISTINCT FROM s.moneda_analisis OR t.origen_moneda_analisis IS DISTINCT FROM s.origen_moneda_analisis OR t.excluir_calculos IS DISTINCT FROM s.excluir_calculos)
THEN UPDATE SET estado_cobertura=s.estado_cobertura,estado_importe=s.estado_importe,moneda_analisis=s.moneda_analisis,origen_moneda_analisis=s.origen_moneda_analisis,excluir_calculos=s.excluir_calculos;
