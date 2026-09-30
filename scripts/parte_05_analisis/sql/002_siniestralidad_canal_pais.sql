-- BigQuery Standard SQL. Las fechas desde/hasta seleccionan pólizas por emisión.
DECLARE fecha_desde DATE DEFAULT DATE '2026-04-01';
DECLARE fecha_hasta DATE DEFAULT DATE '2026-06-30';
-- Límite de ocurrencia observado: evita contar eventos futuros respecto del snapshot.
DECLARE fecha_corte DATE DEFAULT DATE '2026-09-29';

WITH polizas AS (
  -- La misma población aporta prima y siniestros: no D, no última ANULADA.
  SELECT poliza_id, producto_id, agencia_id, pais_emision,
         DATE(fecha_emision_utc) fecha_emision, prima, moneda
  FROM `a365-de-ignacio.assist365_staging.polizas_activas`
  WHERE DATE(fecha_emision_utc) BETWEEN fecha_desde AND fecha_hasta
    AND DATE(fecha_emision_utc) <= fecha_corte
    AND UPPER(TRIM(COALESCE(estado, ''))) != 'ANULADA'
), cotizaciones AS (
  -- Cada tasa vale hasta la próxima; nunca se toma una cotización futura.
  SELECT moneda, fecha, factor_usd,
         LEAD(fecha, 1, DATE '9999-12-31') OVER (PARTITION BY moneda ORDER BY fecha) fecha_siguiente
  FROM `a365-de-ignacio.assist365_staging.tipo_cambio`
  WHERE factor_usd > 0
), primas_por_poliza AS (
  SELECT p.poliza_id,
         p.prima * IF(UPPER(TRIM(p.moneda)) = 'USD', NUMERIC '1', tc.factor_usd) prima_usd
  FROM polizas p
  LEFT JOIN cotizaciones tc ON UPPER(TRIM(p.moneda)) = tc.moneda
    AND p.fecha_emision >= tc.fecha AND p.fecha_emision < tc.fecha_siguiente
), siniestros_por_poliza AS (
  -- Incluye siniestros posteriores al mes de emisión, hasta la fecha de corte.
  SELECT s.poliza_id,
         COUNT(DISTINCT s.siniestro_id) cantidad_siniestros,
         COUNT(DISTINCT IF(s.estado = 'PAGADO', s.siniestro_id, NULL)) cantidad_siniestros_pagados,
         SUM(IF(s.estado = 'PAGADO',
             s.monto * IF(s.moneda_analisis = 'USD', NUMERIC '1', tc.factor_usd), NUMERIC '0')) costo_pagado_usd
  FROM `a365-de-ignacio.assist365_staging.siniestros` s
  INNER JOIN polizas p USING (poliza_id)
  LEFT JOIN cotizaciones tc ON s.moneda_analisis = tc.moneda
    AND s.fecha_ocurrencia >= tc.fecha AND s.fecha_ocurrencia < tc.fecha_siguiente
  WHERE s.fecha_ocurrencia <= fecha_corte
    AND NOT s.excluir_calculos
  GROUP BY s.poliza_id
), detalle_poliza AS (
  -- Una fila por póliza; prima y costo se atribuyen a su cohorte de emisión.
  SELECT DATE_TRUNC(p.fecha_emision, MONTH) mes_cohorte,
         p.poliza_id, COALESCE(p.pais_emision, 'DESCONOCIDO') pais,
         COALESCE(a.canal, 'DESCONOCIDO') canal_agencia,
         pr.prima_usd,
         COALESCE(s.cantidad_siniestros, 0) cantidad_siniestros,
         COALESCE(s.cantidad_siniestros_pagados, 0) cantidad_siniestros_pagados,
         COALESCE(s.costo_pagado_usd, NUMERIC '0') costo_pagado_usd
  FROM polizas p
  LEFT JOIN primas_por_poliza pr USING (poliza_id)
  LEFT JOIN siniestros_por_poliza s USING (poliza_id)
  LEFT JOIN `a365-de-ignacio.assist365_staging.agencias` a ON p.agencia_id = a.agencia_id
)
SELECT mes_cohorte, pais, canal_agencia,
       COUNT(DISTINCT poliza_id) cantidad_polizas,
       SUM(cantidad_siniestros) cantidad_siniestros,
       SUM(cantidad_siniestros_pagados) cantidad_siniestros_pagados,
       SUM(prima_usd) prima_usd,
       SUM(costo_pagado_usd) costo_pagado_usd,
       SAFE_DIVIDE(SUM(costo_pagado_usd), SUM(prima_usd)) siniestralidad,
       SAFE_DIVIDE(SUM(cantidad_siniestros_pagados), COUNT(DISTINCT poliza_id)) frecuencia_pagados,
       SAFE_DIVIDE(SUM(costo_pagado_usd), SUM(cantidad_siniestros_pagados)) severidad_usd
FROM detalle_poliza
GROUP BY mes_cohorte, pais, canal_agencia
ORDER BY mes_cohorte, pais, canal_agencia;
