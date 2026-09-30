-- Uses the exact production transformation against temporary fixtures only.
CREATE TEMP TABLE fixture_policies AS SELECT * FROM UNNEST([STRUCT('A' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '100' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-01 00:00:00+00' AS updated_at),STRUCT('A' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '200' AS prima,'ARS' AS moneda,'ANULADA' AS estado,'U' AS operacion,TIMESTAMP '2024-01-05 00:00:00+00' AS updated_at),STRUCT('B' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-02 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'USD' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-02 00:00:00+00' AS updated_at),STRUCT('B' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-02 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '20' AS prima,'USD' AS moneda,'VENCIDA' AS estado,'U' AS operacion,TIMESTAMP '2024-01-06 00:00:00+00' AS updated_at),STRUCT('C' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-03 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-03 00:00:00+00' AS updated_at),STRUCT('D' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-04 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-04 00:00:00+00' AS updated_at),STRUCT('D' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-04 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '10' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'D' AS operacion,TIMESTAMP '2024-01-08 00:00:00+00' AS updated_at),STRUCT('E' AS poliza_id,'PRD' AS producto_id,'AR' AS pais_emision,'WEB' AS canal_origen,TIMESTAMP '2024-01-08 00:00:00+00' AS fecha_emision_utc,DATE '2024-01-01' AS inicio_vigencia,DATE '2024-01-31' AS fin_vigencia,NUMERIC '5' AS prima,'ARS' AS moneda,'EMITIDA' AS estado,'I' AS operacion,TIMESTAMP '2024-01-08 00:00:00+00' AS updated_at)]);
CREATE TEMP TABLE fixture_active AS SELECT * EXCEPT(operacion) FROM fixture_policies QUALIFY ROW_NUMBER() OVER(PARTITION BY poliza_id ORDER BY updated_at DESC)=1 AND operacion!='D';
CREATE TEMP TABLE fixture_products AS SELECT 'PRD' AS producto_id,'MEDICO' tipo,TRUE es_premium;
CREATE TEMP TABLE fixture_claims AS SELECT *, CAST(NULL AS STRING) estado_cobertura, CAST(NULL AS STRING) estado_importe, CAST(NULL AS STRING) moneda_analisis, CAST(NULL AS STRING) origen_moneda_analisis, CAST(NULL AS BOOL) excluir_calculos FROM UNNEST([STRUCT('S1' AS siniestro_id,'A' AS poliza_id,DATE '2024-01-03' AS fecha_ocurrencia,'PAGADO' AS estado,NUMERIC '10' AS monto,'ARS' AS moneda),STRUCT('S2','B',DATE '2024-01-03','RECHAZADO',NUMERIC '40','USD'),STRUCT('S3','Z',DATE '2024-01-09','PAGADO',NUMERIC '10','ARS'),STRUCT('S4','C',DATE '2024-01-10','PAGADO',NUMERIC '20','USD')]);
CREATE TEMP TABLE fixture_rates AS SELECT * FROM UNNEST([STRUCT(DATE '2024-01-01' AS fecha,'ARS' AS moneda,NUMERIC '1' AS factor_usd),STRUCT(DATE '2024-01-05','ARS',NUMERIC '2'),STRUCT(DATE '2024-01-10','ARS',NUMERIC '3')]);

INSERT INTO fixture_claims(siniestro_id,poliza_id,fecha_ocurrencia,estado,monto,moneda) VALUES
 ('S5','C',DATE '2024-01-03','PAGADO',4,NULL),
 ('S6','C',DATE '2024-01-03','PAGADO',-9,'ARS'),
 ('S7','C',DATE '2024-01-03','PAGADO',-9,NULL),
 ('S8','Z',DATE '2024-01-03','PAGADO',2,NULL);
-- Derived business flags; original currency, amount and status are preserved.
CREATE OR REPLACE TEMP TABLE claim_policy_keys AS SELECT DISTINCT poliza_id FROM fixture_policies;
CREATE OR REPLACE TEMP TABLE claim_policy_periods AS SELECT DISTINCT poliza_id,inicio_vigencia,fin_vigencia FROM fixture_policies WHERE operacion!='D';
CREATE OR REPLACE TEMP TABLE claim_policy_currencies AS
SELECT poliza_id,IF(COUNT(DISTINCT UPPER(TRIM(moneda)))=1,MAX(UPPER(TRIM(moneda))),NULL) policy_currency
FROM fixture_policies GROUP BY poliza_id;
CREATE OR REPLACE TEMP TABLE claim_business_flags AS
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

ASSERT (SELECT estado_cobertura='POLIZA_AUSENTE' FROM fixture_claims WHERE siniestro_id='S3') AS 'Póliza ausente';
ASSERT (SELECT moneda IS NULL AND moneda_analisis='ARS' AND origen_moneda_analisis='INFERIDA_POLIZA' AND NOT excluir_calculos FROM fixture_claims WHERE siniestro_id='S5') AS 'Inferida incluida';
ASSERT (SELECT excluir_calculos AND estado='PAGADO' AND monto=-9 FROM fixture_claims WHERE siniestro_id='S6') AS 'Negativo excluido sin cambiar original';
ASSERT (SELECT excluir_calculos AND moneda_analisis='ARS' FROM fixture_claims WHERE siniestro_id='S7') AS 'Moneda inferida no habilita negativo';
ASSERT (SELECT excluir_calculos AND moneda_analisis IS NULL FROM fixture_claims WHERE siniestro_id='S8') AS 'Sin moneda recuperable';
ASSERT (SELECT COUNT(*)=8 FROM fixture_claims) AS 'Conservar todos los registros';
INSERT INTO fixture_policies VALUES('Z','PRD','AR','WEB',TIMESTAMP '2024-01-01',DATE '2024-01-01',DATE '2024-01-31',100,'ARS','EMITIDA','I',TIMESTAMP '2024-01-01');
-- Derived business flags; original currency, amount and status are preserved.
CREATE OR REPLACE TEMP TABLE claim_policy_keys AS SELECT DISTINCT poliza_id FROM fixture_policies;
CREATE OR REPLACE TEMP TABLE claim_policy_periods AS SELECT DISTINCT poliza_id,inicio_vigencia,fin_vigencia FROM fixture_policies WHERE operacion!='D';
CREATE OR REPLACE TEMP TABLE claim_policy_currencies AS
SELECT poliza_id,IF(COUNT(DISTINCT UPPER(TRIM(moneda)))=1,MAX(UPPER(TRIM(moneda))),NULL) policy_currency
FROM fixture_policies GROUP BY poliza_id;
CREATE OR REPLACE TEMP TABLE claim_business_flags AS
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

ASSERT (SELECT estado_cobertura='COINCIDE' FROM fixture_claims WHERE siniestro_id='S3') AS 'Llegada de póliza actualiza cobertura';
ASSERT (SELECT moneda IS NULL AND moneda_analisis='ARS' AND NOT excluir_calculos FROM fixture_claims WHERE siniestro_id='S8') AS 'Llegada de póliza habilita inferencia válida';
SELECT 'PASS' status,8 functional_checks;
