-- Probar los MERGE de producción con tablas temporales, sin modificar staging.

CREATE TEMP TABLE history (
  poliza_id STRING,
  cliente_id STRING,
  producto_id STRING,
  agencia_id STRING,
  pais_emision STRING,
  canal_origen STRING,
  fecha_emision_utc TIMESTAMP,
  inicio_vigencia DATE,
  fin_vigencia DATE,
  prima NUMERIC,
  moneda STRING,
  estado STRING,
  operacion STRING,
  updated_at TIMESTAMP
);

CREATE TEMP TABLE active (
  poliza_id STRING,
  cliente_id STRING,
  producto_id STRING,
  agencia_id STRING,
  pais_emision STRING,
  canal_origen STRING,
  fecha_emision_utc TIMESTAMP,
  inicio_vigencia DATE,
  fin_vigencia DATE,
  prima NUMERIC,
  moneda STRING,
  estado STRING,
  updated_at TIMESTAMP
);

CREATE TEMP TABLE claims (
  siniestro_id STRING,
  poliza_id STRING,
  fecha_ocurrencia DATE,
  fecha_reporte DATE,
  tipo STRING,
  estado STRING,
  monto NUMERIC,
  moneda STRING,
  ciudad STRING,
  diagnostico STRING,
  proveedor STRING
);

CREATE TEMP TABLE catalog (agencia_id STRING, nombre STRING, pais STRING, canal STRING);

CREATE TEMP TABLE silver_mutations (table_name STRING, changed_rows INT64);

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(100 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "EMITIDA" AS estado,
  "I" AS operacion,
  TIMESTAMP '2024-01-01 00:00:00+00' AS updated_at
UNION ALL
SELECT
  "B" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(50 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "EMITIDA" AS estado,
  "I" AS operacion,
  TIMESTAMP '2024-01-01 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT (SELECT COUNT(*) FROM active) = 2 AS 'I inserts two policies';

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(150 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "ANULADA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-03 00:00:00+00' AS updated_at
UNION ALL
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(120 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "EMITIDA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-02 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT (
  SELECT prima = 150 AND estado = 'ANULADA' FROM active
  WHERE poliza_id = 'A'
) AS 'Latest U replaces premium and ANULADA is retained';

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(150 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "ANULADA" AS estado,
  "D" AS operacion,
  TIMESTAMP '2024-01-05 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT NOT EXISTS (
  SELECT 1 FROM active
  WHERE poliza_id = 'A'
) AS 'D removes the latest state';

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(130 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "EMITIDA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-04 00:00:00+00' AS updated_at
UNION ALL
SELECT
  "B" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(70 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "VENCIDA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-02 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT NOT EXISTS (
  SELECT 1 FROM active
  WHERE poliza_id = 'A'
) AS 'Late U cannot resurrect a later D';

ASSERT (
  SELECT prima = 70 AND estado = 'VENCIDA' FROM active
  WHERE poliza_id = 'B'
) AS 'VENCIDA is retained with its latest premium';

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(130 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "EMITIDA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-04 00:00:00+00' AS updated_at
UNION ALL
SELECT
  "B" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(70 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "VENCIDA" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-02 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT (SELECT COUNT(*) FROM history) = 7 AS 'Replay does not duplicate policy history';

ASSERT (SELECT COUNT(*) FROM active) = 1 AS 'Replay preserves the current state';

CREATE OR REPLACE TEMP TABLE batch_polizas AS
SELECT
  "A" AS poliza_id,
  'TEST-CLIENT' AS cliente_id,
  'TEST-PRODUCT' AS producto_id,
  'TEST-AGENCY' AS agencia_id,
  'AR' AS pais_emision,
  'agencia' AS canal_origen,
  TIMESTAMP '2024-01-01 00:00:00+00' AS fecha_emision_utc,
  DATE '2024-01-10' AS inicio_vigencia,
  DATE '2024-01-20' AS fin_vigencia,
  CAST(200 AS NUMERIC) AS prima,
  'ARS' AS moneda,
  "VIGENTE" AS estado,
  "U" AS operacion,
  TIMESTAMP '2024-01-06 00:00:00+00' AS updated_at;

MERGE history t USING
  batch_polizas s
  ON t.poliza_id = s.poliza_id AND t.updated_at = s.updated_at AND t.operacion = s.operacion
WHEN NOT MATCHED THEN INSERT ROW;
INSERT INTO silver_mutations VALUES ('polizas', @@row_count);

CREATE OR REPLACE TEMP TABLE affected_latest AS
SELECT p.*
FROM history p
WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas) QUALIFY
  ROW_NUMBER() OVER (PARTITION BY poliza_id ORDER BY updated_at DESC) = 1;

ASSERT NOT EXISTS (
  SELECT poliza_id FROM history
  WHERE poliza_id IN (SELECT poliza_id FROM batch_polizas)
  GROUP BY poliza_id
  HAVING COUNTIF(operacion = 'I') != 1
) AS 'La historia de póliza requiere una única alta I';

MERGE active t USING affected_latest s
ON t.poliza_id = s.poliza_id
WHEN MATCHED AND s.operacion = 'D' THEN DELETE
WHEN MATCHED AND s.operacion != 'D'
AND TO_JSON_STRING(
  STRUCT(
    t.poliza_id AS poliza_id,
    t.cliente_id AS cliente_id,
    t.producto_id AS producto_id,
    t.agencia_id AS agencia_id,
    t.pais_emision AS pais_emision,
    t.canal_origen AS canal_origen,
    t.fecha_emision_utc AS fecha_emision_utc,
    t.inicio_vigencia AS inicio_vigencia,
    t.fin_vigencia AS fin_vigencia,
    t.prima AS prima,
    t.moneda AS moneda,
    t.estado AS estado,
    t.updated_at AS updated_at
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.poliza_id AS poliza_id,
    s.cliente_id AS cliente_id,
    s.producto_id AS producto_id,
    s.agencia_id AS agencia_id,
    s.pais_emision AS pais_emision,
    s.canal_origen AS canal_origen,
    s.fecha_emision_utc AS fecha_emision_utc,
    s.inicio_vigencia AS inicio_vigencia,
    s.fin_vigencia AS fin_vigencia,
    s.prima AS prima,
    s.moneda AS moneda,
    s.estado AS estado,
    s.updated_at AS updated_at
  )
) THEN
  UPDATE
    SET
      cliente_id = s.cliente_id,
      producto_id = s.producto_id,
      agencia_id = s.agencia_id,
      pais_emision = s.pais_emision,
      canal_origen = s.canal_origen,
      fecha_emision_utc = s.fecha_emision_utc,
      inicio_vigencia = s.inicio_vigencia,
      fin_vigencia = s.fin_vigencia,
      prima = s.prima,
      moneda = s.moneda,
      estado = s.estado,
      updated_at = s.updated_at
WHEN NOT MATCHED AND s.operacion
!= 'D' THEN
  INSERT (poliza_id, cliente_id, producto_id, agencia_id, pais_emision, canal_origen, fecha_emision_utc, inicio_vigencia, fin_vigencia, prima, moneda, estado, updated_at) VALUES (s.poliza_id, s.cliente_id, s.producto_id, s.agencia_id, s.pais_emision, s.canal_origen, s.fecha_emision_utc, s.inicio_vigencia, s.fin_vigencia, s.prima, s.moneda, s.estado, s.updated_at);
INSERT INTO silver_mutations VALUES ('polizas_activas', @@row_count);



ASSERT (
  SELECT prima = 200 FROM active
  WHERE poliza_id = 'A'
) AS 'A genuinely later U becomes the latest logical state';

CREATE TEMP TABLE batch_siniestros AS
SELECT
  "C1" AS siniestro_id,
  'A' AS poliza_id,
  DATE '2024-01-12' AS fecha_ocurrencia,
  DATE '2024-01-13' AS fecha_reporte,
  'MEDICO' AS tipo,
  'PAGADO' AS estado,
  CAST(100 AS NUMERIC) AS monto,
  'ARS' AS moneda,
  'TEST-CITY' AS ciudad,
  CAST(NULL AS STRING) AS diagnostico,
  'TEST-PROVIDER' AS proveedor
UNION ALL
SELECT
  "C2" AS siniestro_id,
  'A' AS poliza_id,
  DATE '2024-01-12' AS fecha_ocurrencia,
  DATE '2024-01-13' AS fecha_reporte,
  'MEDICO' AS tipo,
  'PAGADO' AS estado,
  CAST(50 AS NUMERIC) AS monto,
  'ARS' AS moneda,
  'TEST-CITY' AS ciudad,
  CAST(NULL AS STRING) AS diagnostico,
  'TEST-PROVIDER' AS proveedor;

MERGE claims t USING batch_siniestros s
ON t.siniestro_id = s.siniestro_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(
    t.siniestro_id AS siniestro_id,
    t.poliza_id AS poliza_id,
    t.fecha_ocurrencia AS fecha_ocurrencia,
    t.fecha_reporte AS fecha_reporte,
    t.tipo AS tipo,
    t.estado AS estado,
    t.monto AS monto,
    t.moneda AS moneda,
    t.ciudad AS ciudad,
    t.diagnostico AS diagnostico,
    t.proveedor AS proveedor
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.siniestro_id AS siniestro_id,
    s.poliza_id AS poliza_id,
    s.fecha_ocurrencia AS fecha_ocurrencia,
    s.fecha_reporte AS fecha_reporte,
    s.tipo AS tipo,
    s.estado AS estado,
    s.monto AS monto,
    s.moneda AS moneda,
    s.ciudad AS ciudad,
    s.diagnostico AS diagnostico,
    s.proveedor AS proveedor
  )
) THEN
  UPDATE
    SET
      poliza_id = s.poliza_id,
      fecha_ocurrencia = s.fecha_ocurrencia,
      fecha_reporte = s.fecha_reporte,
      tipo = s.tipo,
      estado = s.estado,
      monto = s.monto,
      moneda = s.moneda,
      ciudad = s.ciudad,
      diagnostico = s.diagnostico,
      proveedor = s.proveedor
WHEN NOT MATCHED THEN
  INSERT (siniestro_id, poliza_id, fecha_ocurrencia, fecha_reporte, tipo, estado, monto, moneda, ciudad, diagnostico, proveedor) VALUES (s.siniestro_id, s.poliza_id, s.fecha_ocurrencia, s.fecha_reporte, s.tipo, s.estado, s.monto, s.moneda, s.ciudad, s.diagnostico, s.proveedor);

CREATE OR REPLACE TEMP TABLE batch_siniestros AS
SELECT
  "C1" AS siniestro_id,
  'A' AS poliza_id,
  DATE '2024-01-12' AS fecha_ocurrencia,
  DATE '2024-01-13' AS fecha_reporte,
  'MEDICO' AS tipo,
  'PAGADO' AS estado,
  CAST(120 AS NUMERIC) AS monto,
  'ARS' AS moneda,
  'TEST-CITY' AS ciudad,
  CAST(NULL AS STRING) AS diagnostico,
  'TEST-PROVIDER' AS proveedor;

MERGE claims t USING batch_siniestros s
ON t.siniestro_id = s.siniestro_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(
    t.siniestro_id AS siniestro_id,
    t.poliza_id AS poliza_id,
    t.fecha_ocurrencia AS fecha_ocurrencia,
    t.fecha_reporte AS fecha_reporte,
    t.tipo AS tipo,
    t.estado AS estado,
    t.monto AS monto,
    t.moneda AS moneda,
    t.ciudad AS ciudad,
    t.diagnostico AS diagnostico,
    t.proveedor AS proveedor
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.siniestro_id AS siniestro_id,
    s.poliza_id AS poliza_id,
    s.fecha_ocurrencia AS fecha_ocurrencia,
    s.fecha_reporte AS fecha_reporte,
    s.tipo AS tipo,
    s.estado AS estado,
    s.monto AS monto,
    s.moneda AS moneda,
    s.ciudad AS ciudad,
    s.diagnostico AS diagnostico,
    s.proveedor AS proveedor
  )
) THEN
  UPDATE
    SET
      poliza_id = s.poliza_id,
      fecha_ocurrencia = s.fecha_ocurrencia,
      fecha_reporte = s.fecha_reporte,
      tipo = s.tipo,
      estado = s.estado,
      monto = s.monto,
      moneda = s.moneda,
      ciudad = s.ciudad,
      diagnostico = s.diagnostico,
      proveedor = s.proveedor
WHEN NOT MATCHED THEN
  INSERT (siniestro_id, poliza_id, fecha_ocurrencia, fecha_reporte, tipo, estado, monto, moneda, ciudad, diagnostico, proveedor) VALUES (s.siniestro_id, s.poliza_id, s.fecha_ocurrencia, s.fecha_reporte, s.tipo, s.estado, s.monto, s.moneda, s.ciudad, s.diagnostico, s.proveedor);

ASSERT (SELECT COUNT(*) FROM claims) = 2 AS 'Missing claims are not deleted';

ASSERT (
  SELECT monto FROM claims
  WHERE siniestro_id = 'C1'
) = 120 AS 'Claim correction updates the amount';

MERGE claims t USING batch_siniestros s
ON t.siniestro_id = s.siniestro_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(
    t.siniestro_id AS siniestro_id,
    t.poliza_id AS poliza_id,
    t.fecha_ocurrencia AS fecha_ocurrencia,
    t.fecha_reporte AS fecha_reporte,
    t.tipo AS tipo,
    t.estado AS estado,
    t.monto AS monto,
    t.moneda AS moneda,
    t.ciudad AS ciudad,
    t.diagnostico AS diagnostico,
    t.proveedor AS proveedor
  )
)
!= TO_JSON_STRING(
  STRUCT(
    s.siniestro_id AS siniestro_id,
    s.poliza_id AS poliza_id,
    s.fecha_ocurrencia AS fecha_ocurrencia,
    s.fecha_reporte AS fecha_reporte,
    s.tipo AS tipo,
    s.estado AS estado,
    s.monto AS monto,
    s.moneda AS moneda,
    s.ciudad AS ciudad,
    s.diagnostico AS diagnostico,
    s.proveedor AS proveedor
  )
) THEN
  UPDATE
    SET
      poliza_id = s.poliza_id,
      fecha_ocurrencia = s.fecha_ocurrencia,
      fecha_reporte = s.fecha_reporte,
      tipo = s.tipo,
      estado = s.estado,
      monto = s.monto,
      moneda = s.moneda,
      ciudad = s.ciudad,
      diagnostico = s.diagnostico,
      proveedor = s.proveedor
WHEN NOT MATCHED THEN
  INSERT (siniestro_id, poliza_id, fecha_ocurrencia, fecha_reporte, tipo, estado, monto, moneda, ciudad, diagnostico, proveedor) VALUES (s.siniestro_id, s.poliza_id, s.fecha_ocurrencia, s.fecha_reporte, s.tipo, s.estado, s.monto, s.moneda, s.ciudad, s.diagnostico, s.proveedor);

ASSERT (SELECT COUNT(*) FROM claims) = 2 AS 'Claim replay is idempotent';

CREATE TEMP TABLE batch_agencias AS
SELECT
  'G1' agencia_id,
  'First' nombre,
  'AR' pais,
  'ONLINE' canal
UNION ALL
SELECT
  'G2',
  'Second',
  'MX',
  'AGENCIA'
;

MERGE catalog t USING batch_agencias s
ON t.agencia_id = s.agencia_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)
)
!= TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)) THEN
  UPDATE SET nombre = s.nombre, pais = s.pais, canal = s.canal
WHEN NOT MATCHED THEN INSERT (agencia_id, nombre, pais, canal) VALUES (s.agencia_id, s.nombre, s.pais, s.canal)
WHEN NOT MATCHED BY SOURCE THEN DELETE;

CREATE OR REPLACE TEMP TABLE batch_agencias AS SELECT
  'G1' agencia_id,
  'Updated' nombre,
  'AR' pais,
  'ONLINE' canal;

MERGE catalog t USING batch_agencias s
ON t.agencia_id = s.agencia_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)
)
!= TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)) THEN
  UPDATE SET nombre = s.nombre, pais = s.pais, canal = s.canal
WHEN NOT MATCHED THEN INSERT (agencia_id, nombre, pais, canal) VALUES (s.agencia_id, s.nombre, s.pais, s.canal)
WHEN NOT MATCHED BY SOURCE THEN DELETE;

ASSERT (SELECT COUNT(*) FROM catalog) = 1 AS 'A complete catalog snapshot removes missing entries';

ASSERT (
  SELECT nombre FROM catalog
  WHERE agencia_id = 'G1'
) = 'Updated' AS 'Catalog corrections replace attributes';

CREATE TEMP TABLE test_checkpoint AS
SELECT TIMESTAMP '2024-02-01 00:00:00+00' source_snapshot_at;

CREATE OR REPLACE TEMP TABLE batch_agencias AS SELECT
  'G1' agencia_id,
  'STALE' nombre,
  'AR' pais,
  'ONLINE' canal;

IF TIMESTAMP '2024-01-01 00:00:00+00'
>= (SELECT source_snapshot_at FROM test_checkpoint) THEN
  MERGE catalog t USING batch_agencias s
ON t.agencia_id = s.agencia_id
  WHEN MATCHED AND TO_JSON_STRING(
    STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)
  )
  != TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)) THEN
    UPDATE SET nombre = s.nombre, pais = s.pais, canal = s.canal
  WHEN NOT MATCHED THEN INSERT (agencia_id, nombre, pais, canal) VALUES (s.agencia_id, s.nombre, s.pais, s.canal)
  WHEN NOT MATCHED BY SOURCE THEN DELETE;
END IF;

ASSERT (
  SELECT nombre FROM catalog
  WHERE agencia_id = 'G1'
)
= 'Updated' AS 'An older snapshot cannot regress the catalog';

CREATE OR REPLACE TEMP TABLE batch_agencias AS SELECT * FROM catalog
WHERE FALSE;
MERGE catalog t USING batch_agencias s
ON t.agencia_id = s.agencia_id
WHEN MATCHED AND TO_JSON_STRING(
  STRUCT(t.agencia_id AS agencia_id, t.nombre AS nombre, t.pais AS pais, t.canal AS canal)
)
!= TO_JSON_STRING(STRUCT(s.agencia_id AS agencia_id, s.nombre AS nombre, s.pais AS pais, s.canal AS canal)) THEN
  UPDATE SET nombre = s.nombre, pais = s.pais, canal = s.canal
WHEN NOT MATCHED THEN INSERT (agencia_id, nombre, pais, canal) VALUES (s.agencia_id, s.nombre, s.pais, s.canal)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
ASSERT (SELECT COUNT(*) FROM catalog) = 0 AS 'An empty complete catalog is applied';

CREATE TEMP TABLE atomic_data AS
SELECT 0 value;

CREATE TEMP TABLE atomic_checkpoint AS
SELECT 0 value;

BEGIN
  BEGIN TRANSACTION;
  UPDATE atomic_data SET value = 1
  WHERE TRUE;
  UPDATE atomic_checkpoint SET value = 1
  WHERE TRUE;
  ASSERT FALSE AS 'Controlled failure';
  COMMIT TRANSACTION;
EXCEPTION WHEN ERROR THEN
  ROLLBACK TRANSACTION;
END;

ASSERT (SELECT value FROM atomic_data) = 0
AND (SELECT value FROM atomic_checkpoint) = 0 AS 'Failure rolls back data and checkpoint together';

SELECT
  'PASS' status,
  16 checks_passed,
  'Temporary tables only' scope;
