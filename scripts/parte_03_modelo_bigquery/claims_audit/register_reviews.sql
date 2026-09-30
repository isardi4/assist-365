CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.claim_reviews` (
 siniestro_id STRING OPTIONS(description='Clave del siniestro que presenta una anomalía revisable.'),
 issue_code STRING OPTIONS(description='Motivo independiente de revisión del siniestro fuente.'),
 first_seen_at TIMESTAMP OPTIONS(description='Instante UTC en que se registró por primera vez el caso.'),
 last_seen_at TIMESTAMP OPTIONS(description='Instante UTC de la última revisión automática del caso.'),
 review_status STRING OPTIONS(description='Estado de revisión pendiente o de desaparición del caso.'),
 suggested_currency STRING OPTIONS(description='Moneda histórica única de póliza sugerida sin imputar.'),
 evidence JSON OPTIONS(description='Valores de negocio que explican el motivo de revisión.')
) PARTITION BY DATE(first_seen_at) CLUSTER BY issue_code,review_status
OPTIONS(description='Registro operativo de anomalías de siniestros detectadas desde silver y verificadas contra archivos raw existentes. Separa problemas de cobertura, montos negativos y monedas nulas sin alterar el estado comercial ni los valores originales. Guarda evidencia y una sugerencia de moneda cuando la póliza tiene una sola moneda histórica; no autoriza su imputación.');
CREATE TEMP TABLE review_candidates AS
WITH currencies AS (SELECT poliza_id,IF(COUNT(DISTINCT moneda)=1,ANY_VALUE(moneda),NULL) suggested_currency FROM `a365-de-ignacio.assist365_staging.polizas` GROUP BY poliza_id)
SELECT s.siniestro_id,issue_code,c.suggested_currency,
 IF(issue_code='MONEDA_NULA' AND s.origen_moneda_analisis='INFERIDA_POLIZA','INFERENCE_APPLIED','PENDING') inferred_status,
 TO_JSON(STRUCT(s.poliza_id,s.estado,s.fecha_ocurrencia,s.monto,s.moneda,s.estado_cobertura,s.estado_importe,s.moneda_analisis,s.origen_moneda_analisis,s.excluir_calculos)) evidence
FROM `a365-de-ignacio.assist365_staging.siniestros` s LEFT JOIN currencies c USING(poliza_id),
UNNEST(ARRAY_CONCAT(IF(s.estado_cobertura!='COINCIDE',[s.estado_cobertura],ARRAY<STRING>[]),IF(s.monto<0,['MONTO_NEGATIVO'],ARRAY<STRING>[]),IF(s.moneda IS NULL,['MONEDA_NULA'],ARRAY<STRING>[]))) issue_code;
MERGE `a365-de-ignacio.assist365_control.claim_reviews` t USING review_candidates s
ON t.siniestro_id=s.siniestro_id AND t.issue_code=s.issue_code AND DATE(t.first_seen_at)>=DATE '1970-01-01'
WHEN MATCHED THEN UPDATE SET last_seen_at=CURRENT_TIMESTAMP(),suggested_currency=s.suggested_currency,evidence=s.evidence,review_status=s.inferred_status
WHEN NOT MATCHED THEN INSERT VALUES(s.siniestro_id,s.issue_code,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP(),s.inferred_status,s.suggested_currency,s.evidence)
WHEN NOT MATCHED BY SOURCE AND t.review_status='PENDING' THEN UPDATE SET review_status='NO_LONGER_PRESENT',last_seen_at=CURRENT_TIMESTAMP();
SELECT issue_code,review_status,COUNT(*) cases FROM `a365-de-ignacio.assist365_control.claim_reviews` WHERE DATE(first_seen_at)>=DATE '1970-01-01' GROUP BY 1,2;
