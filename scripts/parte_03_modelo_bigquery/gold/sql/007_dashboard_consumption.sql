-- Fechas de cohorte inclusivas: usar meses completos y cocientes de sumas.
SELECT pais,SUM(polizas) polizas,SUM(prima_usd) prima_usd_conocida,
 SUM(siniestros_excluidos) siniestros_excluidos,
 SUM(siniestros_pagados_excluidos) siniestros_pagados_excluidos,
 SUM(siniestros_pagados_moneda_inferida) siniestros_pagados_moneda_inferida,
 SUM(siniestros_pagados) siniestros_pagados,SUM(costo_pagado_usd) costo_pagado_usd_conocido,
 SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(prima_usd)) siniestralidad_operativa_observada,
 SAFE_DIVIDE(SUM(costo_pagado_con_periodo_usd),SUM(prima_usd)) siniestralidad_operativa_observada_con_periodo,
 IF(SUM(polizas)=SUM(polizas_con_prima_usd) AND SUM(siniestros_pagados)=SUM(siniestros_pagados_con_costo_usd),
    SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(prima_usd)),NULL) siniestralidad_operativa_completa,
 SAFE_DIVIDE(SUM(siniestros_pagados),SUM(polizas)) frecuencia_proxy,
 IF(SUM(siniestros_pagados)=SUM(siniestros_pagados_con_costo_usd),
    SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(siniestros_pagados)),NULL) severidad_completa_usd,
 SAFE_DIVIDE(SUM(polizas_con_prima_usd),SUM(polizas)) cobertura_prima_usd,
 SAFE_DIVIDE(SUM(siniestros_pagados_con_costo_usd),SUM(siniestros_pagados)) cobertura_costo_usd,
 SUM(siniestros_sin_periodo) siniestros_sin_periodo,
 SUM(siniestros_poliza_anulada) siniestros_poliza_anulada,
 SUM(siniestros_poliza_borrada) siniestros_poliza_borrada
FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE `date` BETWEEN @from_date AND @to_date
GROUP BY pais
ORDER BY siniestralidad_operativa_observada DESC;

-- Comparar premium por tipo de producto; fechas filtran cohortes de emisión.
SELECT es_premium,tipo_producto,SUM(polizas) polizas,SUM(prima_usd) prima_usd_conocida,
 SUM(siniestros_excluidos) siniestros_excluidos,
 SUM(siniestros_pagados_excluidos) siniestros_pagados_excluidos,
 SUM(siniestros_pagados_moneda_inferida) siniestros_pagados_moneda_inferida,
 SUM(siniestros_pagados) siniestros_pagados,SUM(costo_pagado_usd) costo_pagado_usd_conocido,
 SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(prima_usd)) siniestralidad_operativa_observada,
 SAFE_DIVIDE(SUM(costo_pagado_con_periodo_usd),SUM(prima_usd)) siniestralidad_operativa_observada_con_periodo,
 SAFE_DIVIDE(SUM(siniestros_pagados),SUM(polizas)) frecuencia_proxy,
 SAFE_DIVIDE(SUM(siniestros_pagados_con_costo_usd),SUM(siniestros_pagados)) cobertura_costo_usd
FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE `date` BETWEEN @from_date AND @to_date
GROUP BY es_premium,tipo_producto
ORDER BY siniestralidad_operativa_observada DESC;

SELECT SUM(polizas) polizas,SUM(prima_usd) prima_usd_conocida,
 SUM(siniestros_pagados) siniestros_pagados,SUM(costo_pagado_usd) costo_pagado_usd_conocido,
 SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(prima_usd)) siniestralidad_operativa_observada,
 SUM(polizas)-SUM(polizas_con_prima_usd) polizas_sin_usd,
 SUM(siniestros_pagados)-SUM(siniestros_pagados_con_costo_usd) pagados_sin_usd
FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE `date` BETWEEN @from_date AND @to_date;
SELECT year_month,SUM(prima_usd) prima_usd_conocida,SUM(costo_pagado_usd) costo_pagado_usd_conocido,
 SAFE_DIVIDE(SUM(costo_pagado_usd),SUM(prima_usd)) siniestralidad_operativa_observada
FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE `date` BETWEEN @from_date AND @to_date GROUP BY year_month ORDER BY year_month;
