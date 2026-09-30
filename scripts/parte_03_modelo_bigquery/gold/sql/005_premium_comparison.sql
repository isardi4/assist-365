-- Comparar premium y no premium por tipo de producto y cohorte de emisión.
SELECT
  es_premium,
  tipo_producto,
  SUM(polizas) polizas,
  SUM(prima_usd) prima_usd_conocida,
  SUM(siniestros_excluidos) siniestros_excluidos,
  SUM(siniestros_pagados_excluidos) siniestros_pagados_excluidos,
  SUM(siniestros_pagados_moneda_inferida) siniestros_pagados_moneda_inferida,
  SUM(siniestros_pagados) siniestros_pagados,
  SUM(costo_pagado_usd) costo_pagado_usd_conocido,
  SAFE_DIVIDE(SUM(costo_pagado_usd), SUM(prima_usd)) siniestralidad_operativa_observada,
  SAFE_DIVIDE(SUM(costo_pagado_con_periodo_usd), SUM(prima_usd)) siniestralidad_operativa_observada_con_periodo,
  SAFE_DIVIDE(SUM(siniestros_pagados), SUM(polizas)) frecuencia_proxy,
  SAFE_DIVIDE(SUM(siniestros_pagados_con_costo_usd), SUM(siniestros_pagados)) cobertura_costo_usd
FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE `date` BETWEEN @from_date AND @to_date
GROUP BY es_premium, tipo_producto
ORDER BY siniestralidad_operativa_observada DESC;
