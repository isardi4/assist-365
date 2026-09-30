-- Incremental raw → silver. Toda actualización y checkpoint se confirma atómicamente.

ASSERT EXISTS(SELECT 1 FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id = @run_id AND run_status IN ('SUCCESS','SUCCESS_WITH_QUARANTINE')) AS 'La extracción raw no está completa';

ASSERT NOT EXISTS(SELECT 1 FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id = @run_id AND invocation_mode != 'full' AND EXISTS(SELECT 1 FROM UNNEST(@resources) r WHERE r != 'polizas')) AS 'Catálogos y siniestros requieren captura completa';

CREATE TEMP TABLE incoming_polizas AS SELECT
 JSON_VALUE(payload, '$.poliza_id') AS poliza_id,
 JSON_VALUE(payload, '$.cliente_id') AS cliente_id,
 JSON_VALUE(payload, '$.producto_id') AS producto_id,
 JSON_VALUE(payload, '$.agencia_id') AS agencia_id,
 JSON_VALUE(payload, '$.pais_emision') AS pais_emision,
 JSON_VALUE(payload, '$.canal_origen') AS canal_origen,
 SAFE_CAST(JSON_VALUE(payload, '$.fecha_emision_utc') AS TIMESTAMP) AS fecha_emision_utc,
 COALESCE(SAFE_CAST(JSON_VALUE(payload, '$.inicio_vigencia') AS DATE),
   DATE(SAFE_CAST(JSON_VALUE(payload, '$.inicio_vigencia') AS TIMESTAMP))) AS inicio_vigencia,
 COALESCE(SAFE_CAST(JSON_VALUE(payload, '$.fin_vigencia') AS DATE),
   DATE(SAFE_CAST(JSON_VALUE(payload, '$.fin_vigencia') AS TIMESTAMP))) AS fin_vigencia,
 SAFE_CAST(JSON_VALUE(payload, '$.prima') AS NUMERIC) AS prima,
 JSON_VALUE(payload, '$.moneda') AS moneda,
 JSON_VALUE(payload, '$.estado') AS estado,
 JSON_VALUE(payload, '$.op') AS operacion,
 SAFE_CAST(JSON_VALUE(payload, '$.updated_at') AS TIMESTAMP) AS updated_at
FROM `a365-de-ignacio.assist365_raw.polizas`
WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'polizas' IN UNNEST(@resources);

ASSERT (SELECT COUNT(*) FROM incoming_polizas) = @polizas_rows AS 'Raw incompleto para polizas';

ASSERT NOT EXISTS(SELECT 1 FROM incoming_polizas WHERE poliza_id IS NULL OR updated_at IS NULL) AS 'Clave inválida en polizas';

ASSERT NOT EXISTS(SELECT poliza_id, updated_at FROM incoming_polizas x GROUP BY poliza_id, updated_at HAVING COUNT(DISTINCT TO_JSON_STRING(x)) > 1) AS 'Versiones ambiguas en polizas';

CREATE TEMP TABLE batch_polizas AS SELECT DISTINCT * FROM incoming_polizas;

CREATE TEMP TABLE incoming_agencias AS SELECT JSON_VALUE(payload,'$.agencia_id') agencia_id, JSON_VALUE(payload,'$.nombre') nombre, JSON_VALUE(payload,'$.pais') pais, JSON_VALUE(payload,'$.canal') canal FROM `a365-de-ignacio.assist365_raw.agencias` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'agencias' IN UNNEST(@resources);

ASSERT (SELECT COUNT(*) FROM incoming_agencias) = @agencias_rows AS 'Raw incompleto para agencias';

ASSERT NOT EXISTS(SELECT 1 FROM incoming_agencias WHERE agencia_id IS NULL) AS 'Clave inválida en agencias';

ASSERT NOT EXISTS(SELECT agencia_id FROM incoming_agencias x GROUP BY agencia_id HAVING COUNT(DISTINCT TO_JSON_STRING(x)) > 1) AS 'Versiones ambiguas en agencias';

CREATE TEMP TABLE batch_agencias AS SELECT DISTINCT * FROM incoming_agencias;

CREATE TEMP TABLE incoming_productos AS SELECT JSON_VALUE(payload,'$.producto_id') producto_id, JSON_VALUE(payload,'$.nombre_plan') nombre_plan, JSON_VALUE(payload,'$.tipo') tipo, SAFE_CAST(JSON_VALUE(payload,'$.cobertura_max_usd') AS NUMERIC) cobertura_max_usd, CASE LOWER(JSON_VALUE(payload,'$.es_premium')) WHEN '1' THEN TRUE WHEN 'true' THEN TRUE WHEN '0' THEN FALSE WHEN 'false' THEN FALSE END es_premium FROM `a365-de-ignacio.assist365_raw.productos` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'productos' IN UNNEST(@resources);

ASSERT (SELECT COUNT(*) FROM incoming_productos) = @productos_rows AS 'Raw incompleto para productos';

ASSERT NOT EXISTS(SELECT 1 FROM incoming_productos WHERE producto_id IS NULL) AS 'Clave inválida en productos';

ASSERT NOT EXISTS(SELECT producto_id FROM incoming_productos x GROUP BY producto_id HAVING COUNT(DISTINCT TO_JSON_STRING(x)) > 1) AS 'Versiones ambiguas en productos';

CREATE TEMP TABLE batch_productos AS SELECT DISTINCT * FROM incoming_productos;

CREATE TEMP TABLE incoming_tipo_cambio AS SELECT SAFE_CAST(JSON_VALUE(payload,'$.fecha') AS DATE) fecha, JSON_VALUE(payload,'$.moneda') moneda, SAFE_CAST(JSON_VALUE(payload,'$.factor_usd') AS NUMERIC) factor_usd, SAFE_CAST(JSON_VALUE(payload,'$.unidades_por_usd') AS NUMERIC) unidades_por_usd FROM `a365-de-ignacio.assist365_raw.tipo_cambio` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'tipo_cambio' IN UNNEST(@resources);

ASSERT (SELECT COUNT(*) FROM incoming_tipo_cambio) = @tipo_cambio_rows AS 'Raw incompleto para tipo_cambio';

ASSERT NOT EXISTS(SELECT 1 FROM incoming_tipo_cambio WHERE fecha IS NULL OR moneda IS NULL) AS 'Clave inválida en tipo_cambio';

ASSERT NOT EXISTS(SELECT fecha, moneda FROM incoming_tipo_cambio x GROUP BY fecha, moneda HAVING COUNT(DISTINCT TO_JSON_STRING(x)) > 1) AS 'Versiones ambiguas en tipo_cambio';

CREATE TEMP TABLE batch_tipo_cambio AS SELECT DISTINCT * FROM incoming_tipo_cambio;

CREATE TEMP TABLE incoming_siniestros AS SELECT JSON_VALUE(payload,'$.claim_id') siniestro_id, JSON_VALUE(payload,'$.policy_id') poliza_id,
COALESCE(SAFE.PARSE_DATE('%d/%m/%Y',JSON_VALUE(payload,'$.occurred_at')), SAFE_CAST(JSON_VALUE(payload,'$.occurred_at') AS DATE)) fecha_ocurrencia,
COALESCE(SAFE.PARSE_DATE('%d/%m/%Y',JSON_VALUE(payload,'$.reported_at')), SAFE_CAST(JSON_VALUE(payload,'$.reported_at') AS DATE)) fecha_reporte,
JSON_VALUE(payload,'$.type') tipo, JSON_VALUE(payload,'$.status') estado, SAFE_CAST(JSON_VALUE(payload,'$.amount.value') AS NUMERIC) monto, JSON_VALUE(payload,'$.amount.currency') moneda,
COALESCE(JSON_VALUE(payload,'$.detail.city'),JSON_VALUE(payload,'$.detail.ciudad_atencion')) ciudad,
COALESCE(JSON_VALUE(payload,'$.detail.diagnosis'),JSON_VALUE(payload,'$.detail.diagnostico')) diagnostico,
JSON_VALUE(payload,'$.detail.proveedor') proveedor
FROM `a365-de-ignacio.assist365_raw.siniestros` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'siniestros' IN UNNEST(@resources);

ASSERT (SELECT COUNT(*) FROM incoming_siniestros) = @siniestros_rows AS 'Raw incompleto para siniestros';

ASSERT NOT EXISTS(SELECT 1 FROM incoming_siniestros WHERE siniestro_id IS NULL) AS 'Clave inválida en siniestros';

ASSERT NOT EXISTS(SELECT siniestro_id FROM incoming_siniestros x GROUP BY siniestro_id HAVING COUNT(DISTINCT TO_JSON_STRING(x)) > 1) AS 'Versiones ambiguas en siniestros';

CREATE TEMP TABLE batch_siniestros AS SELECT DISTINCT * FROM incoming_siniestros;

ASSERT NOT EXISTS(SELECT 1 FROM batch_polizas WHERE operacion NOT IN ('I','U','D') OR operacion IS NULL) AS 'Operación CDC inválida';

ASSERT NOT EXISTS(SELECT 1 FROM batch_polizas s JOIN `a365-de-ignacio.assist365_staging.polizas` t USING(poliza_id,updated_at) WHERE TO_JSON_STRING(STRUCT(t.poliza_id AS poliza_id, t.cliente_id AS cliente_id, t.producto_id AS producto_id, t.agencia_id AS agencia_id, t.pais_emision AS pais_emision, t.canal_origen AS canal_origen, t.fecha_emision_utc AS fecha_emision_utc, t.inicio_vigencia AS inicio_vigencia, t.fin_vigencia AS fin_vigencia, t.prima AS prima, t.moneda AS moneda, t.estado AS estado, t.operacion AS operacion, t.updated_at AS updated_at)) != TO_JSON_STRING(STRUCT(s.poliza_id AS poliza_id, s.cliente_id AS cliente_id, s.producto_id AS producto_id, s.agencia_id AS agencia_id, s.pais_emision AS pais_emision, s.canal_origen AS canal_origen, s.fecha_emision_utc AS fecha_emision_utc, s.inicio_vigencia AS inicio_vigencia, s.fin_vigencia AS fin_vigencia, s.prima AS prima, s.moneda AS moneda, s.estado AS estado, s.operacion AS operacion, s.updated_at AS updated_at))) AS 'El lote cambia un evento ya registrado';

CREATE TEMP TABLE capture_times AS SELECT 'polizas' resource, IF('polizas' IN UNNEST(@resources), COALESCE(MAX(ingested_at),(SELECT MAX(finished_at) FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id=@run_id)), NULL) source_snapshot_at FROM `a365-de-ignacio.assist365_raw.polizas` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'polizas' IN UNNEST(@resources) UNION ALL SELECT 'agencias' resource, IF('agencias' IN UNNEST(@resources), COALESCE(MAX(ingested_at),(SELECT MAX(finished_at) FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id=@run_id)), NULL) source_snapshot_at FROM `a365-de-ignacio.assist365_raw.agencias` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'agencias' IN UNNEST(@resources) UNION ALL SELECT 'productos' resource, IF('productos' IN UNNEST(@resources), COALESCE(MAX(ingested_at),(SELECT MAX(finished_at) FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id=@run_id)), NULL) source_snapshot_at FROM `a365-de-ignacio.assist365_raw.productos` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'productos' IN UNNEST(@resources) UNION ALL SELECT 'tipo_cambio' resource, IF('tipo_cambio' IN UNNEST(@resources), COALESCE(MAX(ingested_at),(SELECT MAX(finished_at) FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id=@run_id)), NULL) source_snapshot_at FROM `a365-de-ignacio.assist365_raw.tipo_cambio` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'tipo_cambio' IN UNNEST(@resources) UNION ALL SELECT 'siniestros' resource, IF('siniestros' IN UNNEST(@resources), COALESCE(MAX(ingested_at),(SELECT MAX(finished_at) FROM `a365-de-ignacio.assist365_control.ingestion_runs` WHERE DATE(started_at) BETWEEN @source_from_date AND @source_to_date AND run_id=@run_id)), NULL) source_snapshot_at FROM `a365-de-ignacio.assist365_raw.siniestros` WHERE DATE(ingested_at) BETWEEN @from_date AND @to_date AND run_id = @run_id AND 'siniestros' IN UNNEST(@resources);

CREATE TEMP TABLE previous_state AS SELECT * FROM `a365-de-ignacio.assist365_control.silver_resource_state`;

INSERT INTO `a365-de-ignacio.assist365_control.silver_runs`(run_id,job_id,started_at,run_status,resources,source_partitions) VALUES(@run_id,@job_id,CURRENT_TIMESTAMP(),'RUNNING',TO_JSON(@resources),TO_JSON(STRUCT(@from_date AS from_date,@to_date AS to_date)));

CREATE TEMP TABLE silver_mutations(table_name STRING, changed_rows INT64);

BEGIN TRANSACTION;

MERGE `a365-de-ignacio.assist365_staging.polizas` t USING batch_polizas s ON t.poliza_id=s.poliza_id AND t.updated_at=s.updated_at AND t.operacion=s.operacion WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES('polizas',@@row_count);

CREATE TEMP TABLE affected_latest AS SELECT p.* FROM `a365-de-ignacio.assist365_staging.polizas` p WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY ROW_NUMBER() OVER(PARTITION BY poliza_id ORDER BY updated_at DESC)=1;

ASSERT NOT EXISTS(SELECT poliza_id FROM `a365-de-ignacio.assist365_staging.polizas` WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) GROUP BY poliza_id HAVING COUNTIF(operacion='I') != 1) AS 'La historia de póliza requiere una única alta I';

MERGE `a365-de-ignacio.assist365_staging.polizas_activas` t USING affected_latest s ON t.poliza_id=s.poliza_id
WHEN MATCHED AND s.operacion='D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D' AND TO_JSON_STRING(STRUCT(t.poliza_id AS poliza_id, t.cliente_id AS cliente_id, t.producto_id AS producto_id, t.agencia_id AS agencia_id, t.pais_emision AS pais_emision, t.canal_origen AS canal_origen, t.fecha_emision_utc AS fecha_emision_utc, t.inicio_vigencia AS inicio_vigencia, t.fin_vigencia AS fin_vigencia, t.prima AS prima, t.moneda AS moneda, t.estado AS estado, t.updated_at AS updated_at)) != TO_JSON_STRING(STRUCT(s.poliza_id AS poliza_id, s.cliente_id AS cliente_id, s.producto_id AS producto_id, s.agencia_id AS agencia_id, s.pais_emision AS pais_emision, s.canal_origen AS canal_origen, s.fecha_emision_utc AS fecha_emision_utc, s.inicio_vigencia AS inicio_vigencia, s.fin_vigencia AS fin_vigencia, s.prima AS prima, s.moneda AS moneda, s.estado AS estado, s.updated_at AS updated_at)) THEN UPDATE SET cliente_id=s.cliente_id, producto_id=s.producto_id, agencia_id=s.agencia_id, pais_emision=s.pais_emision, canal_origen=s.canal_origen, fecha_emision_utc=s.fecha_emision_utc, inicio_vigencia=s.inicio_vigencia, fin_vigencia=s.fin_vigencia, prima=s.prima, moneda=s.moneda, estado=s.estado, updated_at=s.updated_at
WHEN NOT MATCHED AND s.operacion != 'D' THEN INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES('polizas_activas',@@row_count);

IF 'agencias' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='agencias') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='agencias'),TIMESTAMP('1970-01-01')) THEN

MERGE `a365-de-ignacio.assist365_staging.agencias` t USING batch_agencias s ON t.agencia_id = s.agencia_id
WHEN MATCHED AND TO_JSON_STRING(STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)) != TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)) THEN UPDATE SET nombre = s.nombre, pais = s.pais, canal = s.canal
WHEN NOT MATCHED THEN INSERT (agencia_id, nombre, pais, canal) VALUES (s.agencia_id, s.nombre, s.pais, s.canal)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
INSERT INTO silver_mutations VALUES('agencias',@@row_count);

END IF;

IF 'productos' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='productos') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='productos'),TIMESTAMP('1970-01-01')) THEN

MERGE `a365-de-ignacio.assist365_staging.productos` t USING batch_productos s ON t.producto_id = s.producto_id
WHEN MATCHED AND TO_JSON_STRING(STRUCT(t.producto_id AS producto_id, t.nombre_plan AS nombre_plan, t.tipo AS tipo, t.cobertura_max_usd AS cobertura_max_usd, t.es_premium AS es_premium)) != TO_JSON_STRING(STRUCT(s.producto_id AS producto_id, s.nombre_plan AS nombre_plan, s.tipo AS tipo, s.cobertura_max_usd AS cobertura_max_usd, s.es_premium AS es_premium)) THEN UPDATE SET nombre_plan = s.nombre_plan, tipo = s.tipo, cobertura_max_usd = s.cobertura_max_usd, es_premium = s.es_premium
WHEN NOT MATCHED THEN INSERT (producto_id, nombre_plan, tipo, cobertura_max_usd, es_premium) VALUES (s.producto_id, s.nombre_plan, s.tipo, s.cobertura_max_usd, s.es_premium)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
INSERT INTO silver_mutations VALUES('productos',@@row_count);

END IF;

IF 'tipo_cambio' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='tipo_cambio') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='tipo_cambio'),TIMESTAMP('1970-01-01')) THEN

MERGE `a365-de-ignacio.assist365_staging.tipo_cambio` t USING batch_tipo_cambio s ON t.fecha = s.fecha AND t.moneda = s.moneda
WHEN MATCHED AND TO_JSON_STRING(STRUCT(t.fecha AS fecha, t.moneda AS moneda, t.factor_usd AS factor_usd, t.unidades_por_usd AS unidades_por_usd)) != TO_JSON_STRING(STRUCT(s.fecha AS fecha, s.moneda AS moneda, s.factor_usd AS factor_usd, s.unidades_por_usd AS unidades_por_usd)) THEN UPDATE SET factor_usd = s.factor_usd, unidades_por_usd = s.unidades_por_usd
WHEN NOT MATCHED THEN INSERT (fecha, moneda, factor_usd, unidades_por_usd) VALUES (s.fecha, s.moneda, s.factor_usd, s.unidades_por_usd)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
INSERT INTO silver_mutations VALUES('tipo_cambio',@@row_count);

END IF;

IF 'siniestros' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='siniestros') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='siniestros'),TIMESTAMP('1970-01-01')) THEN

INSERT INTO `a365-de-ignacio.assist365_control.snapshot_diffs`(compared_at,resource,previous_snapshot_id,current_snapshot_id,source_key,change_type,previous_hash,current_hash,review_status)
SELECT CURRENT_TIMESTAMP(),'siniestros',(SELECT source_run_id FROM previous_state WHERE resource='siniestros'),@run_id,t.siniestro_id,'ABSENT_REVIEW',TO_HEX(SHA256(TO_JSON_STRING(t))),NULL,'PENDING'
FROM `a365-de-ignacio.assist365_staging.siniestros` t LEFT JOIN batch_siniestros s USING(siniestro_id)
WHERE s.siniestro_id IS NULL AND NOT EXISTS(SELECT 1 FROM `a365-de-ignacio.assist365_control.snapshot_diffs` d WHERE DATE(d.compared_at) >= DATE '1970-01-01' AND d.current_snapshot_id=@run_id AND d.resource='siniestros' AND d.source_key=t.siniestro_id AND d.change_type='ABSENT_REVIEW');

MERGE `a365-de-ignacio.assist365_staging.siniestros` t USING batch_siniestros s ON t.siniestro_id = s.siniestro_id
WHEN MATCHED AND TO_JSON_STRING(STRUCT(t.siniestro_id AS siniestro_id, t.poliza_id AS poliza_id, t.fecha_ocurrencia AS fecha_ocurrencia, t.fecha_reporte AS fecha_reporte, t.tipo AS tipo, t.estado AS estado, t.monto AS monto, t.moneda AS moneda, t.ciudad AS ciudad, t.diagnostico AS diagnostico, t.proveedor AS proveedor)) != TO_JSON_STRING(STRUCT(s.siniestro_id AS siniestro_id, s.poliza_id AS poliza_id, s.fecha_ocurrencia AS fecha_ocurrencia, s.fecha_reporte AS fecha_reporte, s.tipo AS tipo, s.estado AS estado, s.monto AS monto, s.moneda AS moneda, s.ciudad AS ciudad, s.diagnostico AS diagnostico, s.proveedor AS proveedor)) THEN UPDATE SET poliza_id = s.poliza_id, fecha_ocurrencia = s.fecha_ocurrencia, fecha_reporte = s.fecha_reporte, tipo = s.tipo, estado = s.estado, monto = s.monto, moneda = s.moneda, ciudad = s.ciudad, diagnostico = s.diagnostico, proveedor = s.proveedor
WHEN NOT MATCHED THEN INSERT (siniestro_id, poliza_id, fecha_ocurrencia, fecha_reporte, tipo, estado, monto, moneda, ciudad, diagnostico, proveedor) VALUES (s.siniestro_id, s.poliza_id, s.fecha_ocurrencia, s.fecha_reporte, s.tipo, s.estado, s.monto, s.moneda, s.ciudad, s.diagnostico, s.proveedor);
INSERT INTO silver_mutations VALUES('siniestros',@@row_count);

END IF;

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

INSERT INTO silver_mutations VALUES('siniestros_clasificacion',@@row_count);

CREATE TEMP TABLE silver_checks AS SELECT 'POLICY_EVENTS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT TO_JSON_STRING(STRUCT(poliza_id,updated_at,operacion))) FROM `a365-de-ignacio.assist365_staging.polizas`) actual_count,CAST(0 AS INT64) expected_count UNION ALL SELECT 'ACTIVE_POLICY_KEYS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT poliza_id) FROM `a365-de-ignacio.assist365_staging.polizas_activas`) actual_count,CAST(0 AS INT64) expected_count UNION ALL SELECT 'CLAIM_KEYS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT siniestro_id) FROM `a365-de-ignacio.assist365_staging.siniestros`) actual_count,CAST(0 AS INT64) expected_count UNION ALL SELECT 'AGENCY_KEYS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT agencia_id) FROM `a365-de-ignacio.assist365_staging.agencias`) actual_count,CAST(0 AS INT64) expected_count UNION ALL SELECT 'PRODUCT_KEYS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT producto_id) FROM `a365-de-ignacio.assist365_staging.productos`) actual_count,CAST(0 AS INT64) expected_count UNION ALL SELECT 'FX_KEYS_UNIQUE' check_name,(SELECT COUNT(*)-COUNT(DISTINCT TO_JSON_STRING(STRUCT(fecha,moneda))) FROM `a365-de-ignacio.assist365_staging.tipo_cambio`) actual_count,CAST(0 AS INT64) expected_count;

INSERT INTO silver_checks SELECT 'POLICY_BATCH_PRESERVED',COUNT(*),0 FROM batch_polizas s LEFT JOIN `a365-de-ignacio.assist365_staging.polizas` t USING(poliza_id,updated_at,operacion) WHERE t.poliza_id IS NULL;

IF 'agencias' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='agencias') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='agencias'),TIMESTAMP('1970-01-01')) THEN INSERT INTO silver_checks SELECT 'AGENCIAS_BATCH_PRESERVED',COUNT(*),0 FROM batch_agencias s LEFT JOIN `a365-de-ignacio.assist365_staging.agencias` t ON t.agencia_id=s.agencia_id WHERE t.agencia_id IS NULL OR TO_JSON_STRING(STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)) != TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)); END IF;

IF 'productos' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='productos') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='productos'),TIMESTAMP('1970-01-01')) THEN INSERT INTO silver_checks SELECT 'PRODUCTOS_BATCH_PRESERVED',COUNT(*),0 FROM batch_productos s LEFT JOIN `a365-de-ignacio.assist365_staging.productos` t ON t.producto_id=s.producto_id WHERE t.producto_id IS NULL OR TO_JSON_STRING(STRUCT(t.producto_id AS producto_id, t.nombre_plan AS nombre_plan, t.tipo AS tipo, t.cobertura_max_usd AS cobertura_max_usd, t.es_premium AS es_premium)) != TO_JSON_STRING(STRUCT(s.producto_id AS producto_id, s.nombre_plan AS nombre_plan, s.tipo AS tipo, s.cobertura_max_usd AS cobertura_max_usd, s.es_premium AS es_premium)); END IF;

IF 'tipo_cambio' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='tipo_cambio') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='tipo_cambio'),TIMESTAMP('1970-01-01')) THEN INSERT INTO silver_checks SELECT 'TIPO_CAMBIO_BATCH_PRESERVED',COUNT(*),0 FROM batch_tipo_cambio s LEFT JOIN `a365-de-ignacio.assist365_staging.tipo_cambio` t ON t.fecha=s.fecha AND t.moneda=s.moneda WHERE t.fecha IS NULL OR TO_JSON_STRING(STRUCT(t.fecha AS fecha, t.moneda AS moneda, t.factor_usd AS factor_usd, t.unidades_por_usd AS unidades_por_usd)) != TO_JSON_STRING(STRUCT(s.fecha AS fecha, s.moneda AS moneda, s.factor_usd AS factor_usd, s.unidades_por_usd AS unidades_por_usd)); END IF;

IF 'siniestros' IN UNNEST(@resources) AND (SELECT source_snapshot_at FROM capture_times WHERE resource='siniestros') >= COALESCE((SELECT source_snapshot_at FROM previous_state WHERE resource='siniestros'),TIMESTAMP('1970-01-01')) THEN INSERT INTO silver_checks SELECT 'SINIESTROS_BATCH_PRESERVED',COUNT(*),0 FROM batch_siniestros s LEFT JOIN `a365-de-ignacio.assist365_staging.siniestros` t ON t.siniestro_id=s.siniestro_id WHERE t.siniestro_id IS NULL OR TO_JSON_STRING(STRUCT(t.siniestro_id AS siniestro_id, t.poliza_id AS poliza_id, t.fecha_ocurrencia AS fecha_ocurrencia, t.fecha_reporte AS fecha_reporte, t.tipo AS tipo, t.estado AS estado, t.monto AS monto, t.moneda AS moneda, t.ciudad AS ciudad, t.diagnostico AS diagnostico, t.proveedor AS proveedor)) != TO_JSON_STRING(STRUCT(s.siniestro_id AS siniestro_id, s.poliza_id AS poliza_id, s.fecha_ocurrencia AS fecha_ocurrencia, s.fecha_reporte AS fecha_reporte, s.tipo AS tipo, s.estado AS estado, s.monto AS monto, s.moneda AS moneda, s.ciudad AS ciudad, s.diagnostico AS diagnostico, s.proveedor AS proveedor)); END IF;

INSERT INTO silver_checks SELECT 'ACTIVE_POLICY_LATEST_STATE',COUNT(*),0 FROM affected_latest s FULL JOIN (SELECT * FROM `a365-de-ignacio.assist365_staging.polizas_activas` WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)) t USING(poliza_id) WHERE (s.operacion='D' AND t.poliza_id IS NOT NULL) OR (s.operacion!='D' AND (t.poliza_id IS NULL OR TO_JSON_STRING(STRUCT(t.poliza_id AS poliza_id, t.cliente_id AS cliente_id, t.producto_id AS producto_id, t.agencia_id AS agencia_id, t.pais_emision AS pais_emision, t.canal_origen AS canal_origen, t.fecha_emision_utc AS fecha_emision_utc, t.inicio_vigencia AS inicio_vigencia, t.fin_vigencia AS fin_vigencia, t.prima AS prima, t.moneda AS moneda, t.estado AS estado, t.updated_at AS updated_at)) != TO_JSON_STRING(STRUCT(s.poliza_id AS poliza_id, s.cliente_id AS cliente_id, s.producto_id AS producto_id, s.agencia_id AS agencia_id, s.pais_emision AS pais_emision, s.canal_origen AS canal_origen, s.fecha_emision_utc AS fecha_emision_utc, s.inicio_vigencia AS inicio_vigencia, s.fin_vigencia AS fin_vigencia, s.prima AS prima, s.moneda AS moneda, s.estado AS estado, s.updated_at AS updated_at))));

INSERT INTO silver_checks SELECT 'CLAIM_BUSINESS_FLAGS',COUNT(*),0 FROM `a365-de-ignacio.assist365_staging.siniestros` s JOIN claim_business_flags f USING(siniestro_id) WHERE s.estado_cobertura IS DISTINCT FROM f.estado_cobertura OR s.estado_importe IS DISTINCT FROM f.estado_importe OR s.moneda_analisis IS DISTINCT FROM f.moneda_analisis OR s.origen_moneda_analisis IS DISTINCT FROM f.origen_moneda_analisis OR s.excluir_calculos IS DISTINCT FROM f.excluir_calculos;

ASSERT NOT EXISTS(SELECT 1 FROM silver_checks WHERE actual_count != expected_count) AS 'Silver no concilia';

INSERT INTO `a365-de-ignacio.assist365_control.reconciliations`(checked_at,run_id,resource,check_name,check_status,expected_count,actual_count,difference_count,details) SELECT CURRENT_TIMESTAMP(),@run_id,'silver',check_name,'PASS',expected_count,actual_count,actual_count-expected_count,TO_JSON(STRUCT(@job_id AS job_id)) FROM silver_checks;

MERGE `a365-de-ignacio.assist365_control.silver_resource_state` t USING (SELECT * FROM capture_times WHERE source_snapshot_at IS NOT NULL) s ON t.resource=s.resource WHEN MATCHED AND s.source_snapshot_at >= t.source_snapshot_at THEN UPDATE SET source_snapshot_at=s.source_snapshot_at,source_run_id=@run_id,applied_at=CURRENT_TIMESTAMP() WHEN NOT MATCHED THEN INSERT(resource,source_snapshot_at,source_run_id,applied_at) VALUES(s.resource,s.source_snapshot_at,@run_id,CURRENT_TIMESTAMP());

UPDATE `a365-de-ignacio.assist365_control.silver_runs` SET finished_at=CURRENT_TIMESTAMP(),run_status='SUCCESS',summary=TO_JSON(STRUCT((SELECT COUNT(*) FROM silver_checks) AS checks_passed,@batch_fingerprint AS batch_fingerprint,(SELECT COUNT(*) FROM batch_polizas) AS policy_events_in_batch,(SELECT ARRAY_AGG(STRUCT(table_name,changed_rows)) FROM silver_mutations) AS business_mutations)) WHERE DATE(started_at)>=DATE '1970-01-01' AND job_id=@job_id;

COMMIT TRANSACTION;

SELECT check_name,'PASS' check_status,expected_count,actual_count FROM silver_checks ORDER BY check_name;
