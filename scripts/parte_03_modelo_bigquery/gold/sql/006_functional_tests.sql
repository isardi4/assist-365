DECLARE fecha_corte DATE DEFAULT DATE '2024-02-29';
-- Uses the exact production transformation against temporary fixtures only.
CREATE TEMP TABLE fixture_policies AS SELECT * FROM UNNEST([STRUCT('A' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '100' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-01 00:00:00+00' AS updated_at),STRUCT('A' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '200' AS prima,'ARS' AS moneda,'ANULADA' AS estado,'U' AS operacion,TIMESTAMP '2024-01-05 00:00:00+00' AS updated_at),STRUCT('B' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-02 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'USD' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-02 00:00:00+00' AS updated_at),STRUCT('B' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-02 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '20' AS prima,'USD' AS moneda,'VENCIDA' AS estado,'U' AS operacion,TIMESTAMP '2024-01-06 00:00:00+00' AS updated_at),STRUCT('C' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-03 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-03 00:00:00+00' AS updated_at),STRUCT('D' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-04 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-04 00:00:00+00' AS updated_at),STRUCT('D' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-04 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'D' AS operacion,TIMESTAMP '2024-01-08 00:00:00+00' AS updated_at),STRUCT('E' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-08 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '5' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-08 00:00:00+00' AS updated_at)]);
INSERT INTO fixture_policies VALUES ('F','PRD','AR','WEB',TIMESTAMP '2024-01-10 00:00:00+00',DATE '2024-01-10',DATE '2024-02-10',NUMERIC '10','USD','EMITIDA','I',TIMESTAMP '2024-01-10 00:00:00+00');
CREATE TEMP TABLE fixture_active AS SELECT * EXCEPT(operacion),'AG' agencia_id FROM fixture_policies QUALIFY ROW_NUMBER() OVER(PARTITION BY poliza_id ORDER BY updated_at DESC)=1 AND operacion!='D';
CREATE TEMP TABLE fixture_products AS SELECT 'PRD' AS producto_id,'MEDICO' tipo,TRUE es_premium,'Plan médico' nombre_plan;
CREATE TEMP TABLE fixture_agencies AS SELECT 'AG' agencia_id,'ONLINE' canal;
CREATE TEMP TABLE fixture_claims AS SELECT *, CAST(NULL AS STRING) estado_cobertura, CAST(NULL AS STRING) estado_importe, CAST(NULL AS STRING) moneda_analisis, CAST(NULL AS STRING) origen_moneda_analisis, CAST(NULL AS BOOL) excluir_calculos FROM UNNEST([STRUCT('S1' AS siniestro_id,'A' AS poliza_id,DATE '2024-01-03' AS fecha_ocurrencia,'PAGADO' AS estado,NUMERIC '10' AS monto,'ARS' AS moneda),STRUCT('S2','B',DATE '2024-01-03','RECHAZADO',NUMERIC '40','USD'),STRUCT('S3','Z',DATE '2024-01-09','PAGADO',NUMERIC '10','ARS'),STRUCT('S4','C',DATE '2024-01-10','PAGADO',NUMERIC '20','USD')]);
CREATE TEMP TABLE fixture_rates AS SELECT * FROM UNNEST([STRUCT(DATE '2024-01-01' AS fecha,'ARS' AS moneda,NUMERIC '1' AS factor_usd),STRUCT(DATE '2024-01-05','ARS',NUMERIC '2'),STRUCT(DATE '2024-01-10','ARS',NUMERIC '3')]);

INSERT INTO fixture_claims(siniestro_id,poliza_id,fecha_ocurrencia,estado,monto,moneda) VALUES
 ('S5','C',DATE '2024-01-03','PAGADO',4,NULL),
 ('S6','C',DATE '2024-01-03','PAGADO',-9,'ARS'),
 ('S7','C',DATE '2024-01-03','PAGADO',-9,NULL),
 ('S8','Z',DATE '2024-01-03','PAGADO',2,NULL),
 ('S9','F',DATE '2024-02-07','PAGADO',30,'USD'),
 ('S10','D',DATE '2024-01-09','PAGADO',15,'USD'),
 ('S11','C',DATE '2024-03-01','PAGADO',40,'USD');
-- Derived business flags; original currency, amount and status are preserved.
CREATE TEMP TABLE claim_policy_keys AS SELECT DISTINCT poliza_id FROM fixture_policies;
CREATE TEMP TABLE claim_policy_periods AS SELECT DISTINCT poliza_id,inicio_vigencia,fin_vigencia FROM fixture_policies WHERE operacion!='D';
CREATE TEMP TABLE claim_policy_currencies AS
SELECT poliza_id,IF(COUNT(DISTINCT UPPER(TRIM(moneda)))=1,MAX(UPPER(TRIM(moneda))),NULL) policy_currency
FROM fixture_policies GROUP BY poliza_id;
CREATE TEMP TABLE claim_business_flags AS
WITH candidates AS (
 SELECT s.*,COALESCE(NULLIF(UPPER(TRIM(s.moneda)),''),p.policy_currency) analysis_currency,
 CASE WHEN NULLIF(TRIM(s.moneda),'') IS NOT NULL THEN 'FUENTE'
 WHEN p.policy_currency IS NOT NULL THEN 'INFERIDA_POLIZA' ELSE 'NO_DISPONIBLE' END currency_origin
 FROM fixture_claims s LEFT JOIN claim_policy_currencies p USING(poliza_id)
), coverage AS (
 SELECT s.siniestro_id,
 CASE WHEN k.poliza_id IS NULL THEN 'POLIZA_AUSENTE'
 WHEN COUNT(v.poliza_id)=0 THEN 'FUERA_PERIODO'
 WHEN COUNT(v.poliza_id)=1 THEN 'COINCIDE' ELSE 'COBERTURA_AMBIGUA' END coverage_state
 FROM fixture_claims s LEFT JOIN claim_policy_keys k USING(poliza_id)
 LEFT JOIN claim_policy_periods v ON s.poliza_id=v.poliza_id AND s.fecha_ocurrencia BETWEEN v.inicio_vigencia AND v.fin_vigencia
 GROUP BY s.siniestro_id,k.poliza_id
)
SELECT siniestro_id,coverage_state estado_cobertura,
 CASE WHEN monto IS NULL THEN 'MONTO_NULO'
 WHEN monto<0 AND moneda IS NULL THEN 'MONTO_NEGATIVO_Y_MONEDA_NULA'
 WHEN monto<0 THEN 'MONTO_NEGATIVO'
 WHEN analysis_currency IS NULL THEN 'MONEDA_NO_RECUPERABLE'
 WHEN analysis_currency!='USD' AND NOT EXISTS(SELECT 1 FROM fixture_rates f WHERE f.moneda=analysis_currency AND f.fecha<=fecha_ocurrencia AND f.factor_usd>0) THEN 'SIN_COTIZACION'
 WHEN currency_origin='INFERIDA_POLIZA' THEN 'VALIDO_MONEDA_INFERIDA' ELSE 'VALIDO' END estado_importe,
 analysis_currency moneda_analisis,currency_origin origen_moneda_analisis,
 monto IS NULL OR monto<0 OR analysis_currency IS NULL OR
 (analysis_currency!='USD' AND NOT EXISTS(SELECT 1 FROM fixture_rates f WHERE f.moneda=analysis_currency AND f.fecha<=fecha_ocurrencia AND f.factor_usd>0)) excluir_calculos
FROM candidates s JOIN coverage USING(siniestro_id);
MERGE fixture_claims t USING claim_business_flags s ON t.siniestro_id=s.siniestro_id
WHEN MATCHED AND (t.estado_cobertura IS DISTINCT FROM s.estado_cobertura OR t.estado_importe IS DISTINCT FROM s.estado_importe OR t.moneda_analisis IS DISTINCT FROM s.moneda_analisis OR t.origen_moneda_analisis IS DISTINCT FROM s.origen_moneda_analisis OR t.excluir_calculos IS DISTINCT FROM s.excluir_calculos)
THEN UPDATE SET estado_cobertura=s.estado_cobertura,estado_importe=s.estado_importe,moneda_analisis=s.moneda_analisis,origen_moneda_analisis=s.origen_moneda_analisis,excluir_calculos=s.excluir_calculos;
-- Business transformations only; execution metadata is published separately.
-- Cohortes mensuales: prima y siniestros pertenecen a la misma población.
CREATE TEMP TABLE policies AS
SELECT p.*,COALESCE(p.pais_emision,'DESCONOCIDO') pais,
 COALESCE(d.nombre_plan,'DESCONOCIDO') producto,d.es_premium,
 COALESCE(d.tipo,'DESCONOCIDO') tipo_producto,
 COALESCE(p.canal_origen,'DESCONOCIDO') canal,
 COALESCE(a.canal,'DESCONOCIDO') canal_agencia,
 DATE(p.fecha_emision_utc) business_date
FROM fixture_active p
LEFT JOIN fixture_products d USING(producto_id)
LEFT JOIN fixture_agencies a USING(agencia_id);
ASSERT NOT EXISTS(SELECT poliza_id FROM policies GROUP BY 1 HAVING COUNT(*)>1) AS 'Join duplica pólizas';
ASSERT NOT EXISTS(SELECT 1 FROM policies WHERE business_date IS NULL) AS 'Póliza sin emisión';
CREATE TEMP TABLE claim_scope AS
SELECT s.*,CASE
 WHEN p.poliza_id IS NULL THEN 'POLIZA_D_O_AUSENTE'
 WHEN UPPER(TRIM(COALESCE(p.estado,'')))='ANULADA' THEN 'POLIZA_ANULADA'
 WHEN DATE(p.fecha_emision_utc)>fecha_corte THEN 'EMISION_FUTURA'
 WHEN s.fecha_ocurrencia>fecha_corte THEN 'OCURRENCIA_FUTURA'
 ELSE 'INCLUIDO' END alcance
FROM fixture_claims s
LEFT JOIN fixture_active p USING(poliza_id);
ASSERT NOT EXISTS(SELECT 1 FROM claim_scope WHERE fecha_ocurrencia IS NULL) AS 'Siniestro sin ocurrencia';
CREATE TEMP TABLE claims AS SELECT * FROM claim_scope WHERE alcance='INCLUIDO';
ASSERT NOT EXISTS(SELECT 1 FROM claims WHERE estado_cobertura='COBERTURA_AMBIGUA') AS 'Cobertura ambigua';
CREATE TEMP TABLE date_bounds AS
SELECT MIN(d) first_date,MAX(d) last_date FROM (
 SELECT business_date d FROM policies WHERE business_date<=fecha_corte
 UNION ALL SELECT fecha_ocurrencia FROM claims
 UNION ALL SELECT MIN(fecha) FROM fixture_rates);
CREATE TEMP TABLE fx_daily AS
WITH valid_rates AS (
 SELECT fecha,moneda,factor_usd FROM fixture_rates WHERE factor_usd>0
), grid AS (
 SELECT moneda,d FROM (SELECT DISTINCT moneda FROM valid_rates),date_bounds,
 UNNEST(GENERATE_DATE_ARRAY(first_date,last_date)) d
)
SELECT g.moneda,g.d,
 LAST_VALUE(r.factor_usd IGNORE NULLS) OVER(PARTITION BY g.moneda ORDER BY g.d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) factor_usd,
 LAST_VALUE(r.fecha IGNORE NULLS) OVER(PARTITION BY g.moneda ORDER BY g.d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) rate_date
FROM grid g LEFT JOIN valid_rates r ON r.moneda=g.moneda AND r.fecha=g.d;
ASSERT NOT EXISTS(SELECT 1 FROM fx_daily WHERE rate_date>d) AS 'Cotización futura';
ASSERT NOT EXISTS(SELECT moneda,fecha FROM fixture_rates GROUP BY 1,2 HAVING COUNT(*)>1) AS 'FX duplicado';
CREATE TEMP TABLE policy_values AS
SELECT p.*,IF(prima>=0,SAFE_MULTIPLY(prima,IF(UPPER(TRIM(p.moneda))='USD',NUMERIC '1',f.factor_usd)),NULL) amount_usd
FROM policies p LEFT JOIN fx_daily f ON UPPER(TRIM(p.moneda))=f.moneda AND p.business_date=f.d
WHERE UPPER(TRIM(COALESCE(p.estado,'')))!='ANULADA' AND business_date<=fecha_corte;
CREATE TEMP TABLE claim_values AS
SELECT c.*,IF(NOT c.excluir_calculos,SAFE_MULTIPLY(monto,IF(c.moneda_analisis='USD',NUMERIC '1',f.factor_usd)),NULL) amount_usd
FROM claims c LEFT JOIN fx_daily f ON c.moneda_analisis=f.moneda AND c.fecha_ocurrencia=f.d;
CREATE TEMP TABLE claims_by_policy AS
SELECT poliza_id,
 COUNTIF(NOT excluir_calculos) siniestros,
 COUNTIF(NOT excluir_calculos AND estado='PAGADO') siniestros_pagados,
 COUNTIF(NOT excluir_calculos AND estado='RECHAZADO') siniestros_rechazados,
 COUNTIF(NOT excluir_calculos AND estado='EN_ANALISIS') siniestros_en_analisis,
 COUNTIF(NOT excluir_calculos AND (estado IS NULL OR estado NOT IN ('PAGADO','RECHAZADO','EN_ANALISIS'))) siniestros_otros_estados,
 COUNTIF(estado='PAGADO' AND amount_usd IS NOT NULL) siniestros_pagados_con_costo_usd,
 SUM(IF(estado='PAGADO',COALESCE(amount_usd,0),0)) costo_pagado_usd,
 CAST(0 AS INT64) siniestros_sin_poliza,
 COUNTIF(NOT excluir_calculos AND estado_cobertura!='COINCIDE') siniestros_sin_periodo,
 COUNTIF(NOT excluir_calculos AND estado='PAGADO' AND estado_cobertura!='COINCIDE') siniestros_pagados_sin_periodo,
 SUM(IF(estado='PAGADO' AND estado_cobertura!='COINCIDE',COALESCE(amount_usd,0),0)) costo_pagado_sin_periodo_usd,
 CAST(0 AS INT64) siniestros_poliza_anulada,
 CAST(0 AS INT64) siniestros_poliza_borrada,
 COUNTIF(NOT excluir_calculos AND estado='PAGADO' AND estado_cobertura='COINCIDE') siniestros_pagados_con_periodo,
 COUNTIF(estado='PAGADO' AND estado_cobertura='COINCIDE' AND amount_usd IS NOT NULL) siniestros_pagados_con_periodo_con_costo_usd,
 SUM(IF(estado='PAGADO' AND estado_cobertura='COINCIDE',COALESCE(amount_usd,0),0)) costo_pagado_con_periodo_usd,
 COUNTIF(excluir_calculos) siniestros_excluidos,
 COUNTIF(excluir_calculos AND estado='PAGADO') siniestros_pagados_excluidos,
 COUNTIF(NOT excluir_calculos AND origen_moneda_analisis='INFERIDA_POLIZA') siniestros_moneda_inferida,
 COUNTIF(NOT excluir_calculos AND estado='PAGADO' AND origen_moneda_analisis='INFERIDA_POLIZA') siniestros_pagados_moneda_inferida
FROM claim_values GROUP BY poliza_id;
CREATE TEMP TABLE policy_detail AS
SELECT p.*,
 COALESCE(c.siniestros,0) siniestros,
 COALESCE(c.siniestros_pagados,0) siniestros_pagados,
 COALESCE(c.siniestros_rechazados,0) siniestros_rechazados,
 COALESCE(c.siniestros_en_analisis,0) siniestros_en_analisis,
 COALESCE(c.siniestros_otros_estados,0) siniestros_otros_estados,
 COALESCE(c.siniestros_pagados_con_costo_usd,0) siniestros_pagados_con_costo_usd,
 COALESCE(c.costo_pagado_usd,0) costo_pagado_usd,
 COALESCE(c.siniestros_sin_poliza,0) siniestros_sin_poliza,
 COALESCE(c.siniestros_sin_periodo,0) siniestros_sin_periodo,
 COALESCE(c.siniestros_pagados_sin_periodo,0) siniestros_pagados_sin_periodo,
 COALESCE(c.costo_pagado_sin_periodo_usd,0) costo_pagado_sin_periodo_usd,
 COALESCE(c.siniestros_poliza_anulada,0) siniestros_poliza_anulada,
 COALESCE(c.siniestros_poliza_borrada,0) siniestros_poliza_borrada,
 COALESCE(c.siniestros_pagados_con_periodo,0) siniestros_pagados_con_periodo,
 COALESCE(c.siniestros_pagados_con_periodo_con_costo_usd,0) siniestros_pagados_con_periodo_con_costo_usd,
 COALESCE(c.costo_pagado_con_periodo_usd,0) costo_pagado_con_periodo_usd,
 COALESCE(c.siniestros_excluidos,0) siniestros_excluidos,
 COALESCE(c.siniestros_pagados_excluidos,0) siniestros_pagados_excluidos,
 COALESCE(c.siniestros_moneda_inferida,0) siniestros_moneda_inferida,
 COALESCE(c.siniestros_pagados_moneda_inferida,0) siniestros_pagados_moneda_inferida
FROM policy_values p LEFT JOIN claims_by_policy c USING(poliza_id);
CREATE TEMP TABLE candidate AS
SELECT DATE_TRUNC(business_date,MONTH) `date`,
 EXTRACT(YEAR FROM business_date) year,EXTRACT(MONTH FROM business_date) month,
 1 day,FORMAT_DATE('%Y-%m',business_date) year_month,
 CONCAT(CAST(EXTRACT(YEAR FROM business_date) AS STRING),'-Q',CAST(EXTRACT(QUARTER FROM business_date) AS STRING)) year_quarter,
 CONCAT(CAST(EXTRACT(YEAR FROM business_date) AS STRING),'-S',IF(EXTRACT(MONTH FROM business_date)<=6,'1','2')) year_semester,
 ['domingo','lunes','martes','miércoles','jueves','viernes','sábado'][OFFSET(EXTRACT(DAYOFWEEK FROM DATE_TRUNC(business_date,MONTH))-1)] day_of_week,
 pais,producto,es_premium,canal canal_origen,
 COUNT(*) polizas,COUNTIF(amount_usd IS NOT NULL) polizas_con_prima_usd,
 SUM(COALESCE(amount_usd,0)) prima_usd,
 SUM(siniestros) siniestros,
 SUM(siniestros_pagados) siniestros_pagados,
 SUM(siniestros_rechazados) siniestros_rechazados,
 SUM(siniestros_en_analisis) siniestros_en_analisis,
 SUM(siniestros_otros_estados) siniestros_otros_estados,
 SUM(siniestros_pagados_con_costo_usd) siniestros_pagados_con_costo_usd,
 SUM(costo_pagado_usd) costo_pagado_usd,
 SUM(siniestros_sin_poliza) siniestros_sin_poliza,
 SUM(siniestros_sin_periodo) siniestros_sin_periodo,
 SUM(siniestros_pagados_sin_periodo) siniestros_pagados_sin_periodo,
 SUM(costo_pagado_sin_periodo_usd) costo_pagado_sin_periodo_usd,
 SUM(siniestros_poliza_anulada) siniestros_poliza_anulada,
 SUM(siniestros_poliza_borrada) siniestros_poliza_borrada,
 SUM(siniestros_pagados_con_periodo) siniestros_pagados_con_periodo,
 SUM(siniestros_pagados_con_periodo_con_costo_usd) siniestros_pagados_con_periodo_con_costo_usd,
 SUM(costo_pagado_con_periodo_usd) costo_pagado_con_periodo_usd,
 SUM(siniestros_excluidos) siniestros_excluidos,
 SUM(siniestros_pagados_excluidos) siniestros_pagados_excluidos,
 SUM(siniestros_moneda_inferida) siniestros_moneda_inferida,
 SUM(siniestros_pagados_moneda_inferida) siniestros_pagados_moneda_inferida,
 tipo_producto,canal_agencia
FROM policy_detail
GROUP BY `date`,year,month,day,year_month,year_quarter,year_semester,day_of_week,pais,producto,es_premium,canal,tipo_producto,canal_agencia;
CREATE TEMP TABLE checks AS
SELECT 'POLICY_COUNT' name,(SELECT SUM(polizas) FROM candidate)=(SELECT COUNT(*) FROM policy_values) passed
UNION ALL SELECT 'ANNULLED_EXCLUDED',NOT EXISTS(SELECT 1 FROM policy_values WHERE UPPER(TRIM(estado))='ANULADA')
UNION ALL SELECT 'LATEST_STATE_ELIGIBILITY',(SELECT COUNT(*) FROM policy_values)=(SELECT COUNT(*) FROM fixture_active WHERE UPPER(TRIM(COALESCE(estado,'')))!='ANULADA' AND DATE(fecha_emision_utc)<=fecha_corte)
UNION ALL SELECT 'PREMIUM_SUM',(SELECT SUM(prima_usd) FROM candidate)=(SELECT SUM(amount_usd) FROM policy_values)
UNION ALL SELECT 'CLAIM_COUNT',(SELECT SUM(siniestros+siniestros_excluidos) FROM candidate)=(SELECT COUNT(*) FROM claims)
UNION ALL SELECT 'SOURCE_SCOPE_PARTITION',(SELECT COUNT(*) FROM claim_scope)=(SELECT COUNT(*) FROM claims)+(SELECT COUNTIF(alcance!='INCLUIDO') FROM claim_scope)
UNION ALL SELECT 'PAID_COUNT',(SELECT SUM(siniestros_pagados) FROM candidate)=(SELECT COUNTIF(estado='PAGADO' AND NOT excluir_calculos) FROM claims)
UNION ALL SELECT 'PAID_COST',(SELECT SUM(costo_pagado_usd) FROM candidate)=(SELECT SUM(amount_usd) FROM claim_values WHERE estado='PAGADO')
UNION ALL SELECT 'CLAIM_STATES',NOT EXISTS(SELECT 1 FROM candidate WHERE siniestros!=siniestros_pagados+siniestros_rechazados+siniestros_en_analisis+siniestros_otros_estados)
UNION ALL SELECT 'MISSING_PERIOD_COUNT',(SELECT SUM(siniestros_sin_periodo) FROM candidate)=(SELECT COUNTIF(estado_cobertura!='COINCIDE' AND NOT excluir_calculos) FROM claims)
UNION ALL SELECT 'PREMIUM_VALID_COUNT',(SELECT SUM(polizas_con_prima_usd) FROM candidate)=(SELECT COUNTIF(amount_usd IS NOT NULL) FROM policy_values)
UNION ALL SELECT 'PAID_VALID_COUNT',(SELECT SUM(siniestros_pagados_con_costo_usd) FROM candidate)=(SELECT COUNTIF(estado='PAGADO' AND amount_usd IS NOT NULL) FROM claim_values)
UNION ALL SELECT 'GRAIN_UNIQUE',NOT EXISTS(SELECT `date`,pais,producto,es_premium,canal_origen,tipo_producto,canal_agencia FROM candidate GROUP BY 1,2,3,4,5,6,7 HAVING COUNT(*)>1)
UNION ALL SELECT 'COVERED_PAID_COUNT',(SELECT SUM(siniestros_pagados_con_periodo) FROM candidate)=(SELECT COUNTIF(estado='PAGADO' AND estado_cobertura='COINCIDE' AND NOT excluir_calculos) FROM claims)
UNION ALL SELECT 'COVERED_PAID_COST',(SELECT SUM(costo_pagado_con_periodo_usd) FROM candidate)=(SELECT SUM(amount_usd) FROM claim_values WHERE estado='PAGADO' AND estado_cobertura='COINCIDE')
UNION ALL SELECT 'NO_EXCLUDED_COST',NOT EXISTS(SELECT 1 FROM claim_values WHERE excluir_calculos AND amount_usd IS NOT NULL)
UNION ALL SELECT 'EXCLUDED_COUNT',(SELECT SUM(siniestros_excluidos) FROM candidate)=(SELECT COUNTIF(excluir_calculos) FROM claims)
UNION ALL SELECT 'PAID_PARTITION',(SELECT SUM(siniestros_pagados+siniestros_pagados_excluidos) FROM candidate)=(SELECT COUNTIF(estado='PAGADO') FROM claims)
UNION ALL SELECT 'POLICY_DETAIL_UNIQUE',(SELECT COUNT(*) FROM policy_detail)=(SELECT COUNT(*) FROM policy_values)
UNION ALL SELECT 'CLAIMS_HAVE_POLICY',NOT EXISTS(SELECT 1 FROM claims c LEFT JOIN policy_values p USING(poliza_id) WHERE p.poliza_id IS NULL)
UNION ALL SELECT 'COHORT_MONTH',NOT EXISTS(SELECT 1 FROM candidate WHERE EXTRACT(DAY FROM `date`)!=1)
UNION ALL SELECT 'OCCURRENCE_CUTOFF',NOT EXISTS(SELECT 1 FROM claims WHERE fecha_ocurrencia>fecha_corte)
UNION ALL SELECT 'LEGACY_OUT_OF_SCOPE_ZERO',NOT EXISTS(SELECT 1 FROM candidate WHERE siniestros_sin_poliza!=0 OR siniestros_poliza_anulada!=0 OR siniestros_poliza_borrada!=0)
UNION ALL SELECT 'INFERRED_INCLUDED_COUNT',(SELECT SUM(siniestros_moneda_inferida) FROM candidate)=(SELECT COUNTIF(NOT excluir_calculos AND origen_moneda_analisis='INFERIDA_POLIZA') FROM claims);
ASSERT NOT EXISTS(SELECT 1 FROM checks WHERE NOT COALESCE(passed,FALSE)) AS 'Gold no conciliada';
CREATE TEMP TABLE validation AS SELECT
 fecha_corte fecha_corte,
 (SELECT COUNT(*) FROM checks) checks_passed,COUNT(*) row_count,
 SUM(8+8+8+8+COALESCE(BYTE_LENGTH(`year_month`),0)+2+COALESCE(BYTE_LENGTH(`year_quarter`),0)+2+COALESCE(BYTE_LENGTH(`year_semester`),0)+2+COALESCE(BYTE_LENGTH(`day_of_week`),0)+2+COALESCE(BYTE_LENGTH(`pais`),0)+2+COALESCE(BYTE_LENGTH(`producto`),0)+2+1+COALESCE(BYTE_LENGTH(`canal_origen`),0)+2+8+8+16+8+8+8+8+8+8+16+8+8+8+16+8+8+8+8+16+8+8+8+8+COALESCE(BYTE_LENGTH(`tipo_producto`),0)+2+COALESCE(BYTE_LENGTH(`canal_agencia`),0)+2) logical_bytes_upper_bound,
 CAST(SUM(CAST(FARM_FINGERPRINT(TO_JSON_STRING(c)) AS BIGNUMERIC)) AS STRING) content_fingerprint,
 SUM(polizas) policies,SUM(prima_usd) premium_usd_known,
 SUM(polizas)-SUM(polizas_con_prima_usd) policies_without_usd,
 SUM(siniestros) claims,SUM(siniestros_excluidos) claims_excluded,
 SUM(siniestros+siniestros_excluidos) claims_in_scope,
 SUM(siniestros_pagados) paid_claims,SUM(siniestros_pagados_excluidos) paid_claims_excluded,
 SUM(siniestros_pagados+siniestros_pagados_excluidos) paid_claims_in_scope,
 SUM(siniestros_moneda_inferida) claims_inferred_currency,
 SUM(siniestros_pagados_moneda_inferida) paid_claims_inferred_currency,
 SUM(costo_pagado_usd) paid_cost_usd_known,
 SUM(siniestros_pagados)-SUM(siniestros_pagados_con_costo_usd) paid_claims_without_usd,
 SUM(siniestros_sin_periodo) claims_without_period,
 (SELECT COUNT(*) FROM claim_scope) claims_source,
 (SELECT COUNTIF(alcance!='INCLUIDO') FROM claim_scope) claims_out_of_scope,
 (SELECT COUNTIF(alcance='POLIZA_D_O_AUSENTE') FROM claim_scope) claims_deleted_or_missing_policy,
 (SELECT COUNTIF(alcance='POLIZA_ANULADA') FROM claim_scope) claims_annulled_policy,
 (SELECT COUNTIF(alcance='OCURRENCIA_FUTURA') FROM claim_scope) claims_future_occurrence,
 (SELECT COUNTIF(alcance='EMISION_FUTURA') FROM claim_scope) claims_future_emission,
 (SELECT COUNTIF(UPPER(TRIM(estado))='ANULADA') FROM policies) excluded_annulled_policies
FROM candidate c;
ASSERT (SELECT logical_bytes_upper_bound<=50000000 FROM validation) AS 'Gold supera 50 MB';

ASSERT NOT EXISTS(SELECT 1 FROM policy_values WHERE poliza_id IN ('A','D')) AS 'Última ANULADA y D no recuperan I';
ASSERT (SELECT prima=20 FROM policy_values WHERE poliza_id='B') AS 'U usa última prima';
ASSERT (SELECT SUM(prima_usd)=50 AND SUM(polizas)=4 FROM candidate) AS 'Primas iguales suman por póliza';
ASSERT (SELECT SUM(siniestros)=4 AND SUM(siniestros_excluidos)=2 FROM candidate) AS 'Población común y flags monetarios';
ASSERT (SELECT SUM(siniestros_pagados)=3 AND SUM(siniestros_pagados_excluidos)=2 FROM candidate) AS 'Negativos fuera de conteos';
ASSERT (SELECT SUM(costo_pagado_usd)=54 FROM candidate) AS 'Costo válido con moneda inferida';
ASSERT (SELECT SUM(siniestros_pagados_con_periodo)=3 AND SUM(costo_pagado_con_periodo_usd)=54 FROM candidate) AS 'Cobertura preservada';
ASSERT (SELECT moneda IS NULL AND moneda_analisis='ARS' AND origen_moneda_analisis='INFERIDA_POLIZA' AND NOT excluir_calculos FROM fixture_claims WHERE siniestro_id='S5') AS 'Inferencia preserva fuente';
ASSERT (SELECT excluir_calculos AND monto=-9 FROM fixture_claims WHERE siniestro_id='S6') AS 'Negativo intacto';
ASSERT (SELECT excluir_calculos AND moneda_analisis='ARS' FROM fixture_claims WHERE siniestro_id='S7') AS 'Negativo inferido excluido';
ASSERT (SELECT excluir_calculos AND moneda_analisis IS NULL FROM fixture_claims WHERE siniestro_id='S8') AS 'No inventar moneda';
ASSERT NOT EXISTS(SELECT 1 FROM fx_daily WHERE d BETWEEN DATE '2024-01-02' AND DATE '2024-01-04' AND factor_usd!=1) AS 'Arrastre tasa día 1';
ASSERT NOT EXISTS(SELECT 1 FROM fx_daily WHERE d BETWEEN DATE '2024-01-06' AND DATE '2024-01-09' AND factor_usd!=2) AS 'Arrastre tasa día 5';
ASSERT (SELECT factor_usd=3 FROM fx_daily WHERE d=DATE '2024-01-10') AS 'Tasa día 10';
ASSERT (SELECT COUNT(*)=1 AND MIN(date)=DATE '2024-01-01' AND SUM(costo_pagado_usd)=54 FROM candidate) AS 'Siniestro de febrero pertenece a enero';
ASSERT (SELECT day_of_week='lunes' AND day=1 FROM candidate) AS 'Calendario de cohorte';
ASSERT (SELECT SUM(siniestros_pagados_moneda_inferida)=1 FROM candidate) AS 'Inferido válido incluido';
ASSERT NOT EXISTS(SELECT 1 FROM claims WHERE siniestro_id IN ('S1','S3','S8','S10','S11')) AS 'Fuera de alcance no entra en numerador';
ASSERT (SELECT claims_source=11 AND claims_in_scope=6 AND claims_out_of_scope=5 FROM validation) AS 'Conservación de fuente y alcance';
ASSERT (SELECT tipo_producto='MEDICO' AND producto='Plan médico' AND canal_agencia='ONLINE' FROM candidate) AS 'Plan, tipo y canal de catálogo';
ASSERT (SELECT COUNT(*)=4 FROM policy_detail) AS 'Sin siniestros conserva póliza y prima';
SELECT 'PASS' status,21 functional_checks,(SELECT checks_passed FROM validation) production_checks;
