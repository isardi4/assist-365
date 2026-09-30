# Dashboard en Looker Studio — cohortes de emisión

[Abrir el dashboard](https://datastudio.google.com/reporting/be1247ad-58d9-4ed1-ba70-ca4830505fb3/page/0eCAG).

El tablero permite comparar países y planes por siniestralidad y analizar si las diferencias se relacionan con frecuencia de eventos pagados, costo promedio o prima media. Está construido sobre `a365-de-ignacio.assist365_mart.dashboard_diario`, una tabla física mensual de **45.875 filas y 15,21 MB**. [Esquema y reglas de gold](../../README.md#capa-gold).

[![Vista del dashboard Assist365](assets/dashboard-preview.png)](https://datastudio.google.com/reporting/be1247ad-58d9-4ed1-ba70-ca4830505fb3/page/0eCAG)

Vista del tablero para **abril–junio de 2026**. Abrir el enlace para cambiar el período o aplicar filtros; la imagen es una referencia estática.

## Período y filtros

La fecha `date` es el primer día del mes de emisión de las pólizas. Seleccionar una cohorte incluye su prima y sus siniestros elegibles posteriores, acumulados hasta el corte de ocurrencia **29/09/2026**. No representa pagos realizados durante el trimestre seleccionado.

El tablero abre en **01/04/2026–30/06/2026**. El selector de fechas permite cambiar el período y los filtros de país, producto y canal de agencia delimitan la población analizada. `producto` es el nombre del plan y `canal_agencia` proviene del catálogo de agencias.

Gold conserva además `tipo_producto`, `es_premium` y `canal_origen` para ampliar el análisis. El canal de origen pertenece a la póliza y no es intercambiable con el canal de agencia. `day` y `day_of_week` describen el primer día del mes, no días reales de emisión u ocurrencia.

## Preguntas y visualizaciones

| Pregunta | Visualización | Interpretación |
|---|---|---|
| ¿Qué país está peor este trimestre? | Columnas por `pais`. | Siniestralidad en orden descendente. El mayor ratio indica peor relación observada entre costo pagado y prima informada. |
| ¿Qué plan destruye margen? | Barras horizontales por `producto`. | Siniestralidad descendente. Un ratio superior al 100% indica que el costo pagado supera la prima; no demuestra margen neto porque faltan otros gastos y prima devengada. |
| ¿El problema es frecuencia o monto promedio? | Dispersión por país o plan. | Dos gráficos, uno por país y otro por plan. Eje X: frecuencia pagada; eje Y: severidad USD. A la derecha hay más eventos por póliza; arriba, eventos más caros; arriba y a la derecha, ambos componentes elevados. |

Los conteos de gold se agregan mediante **SUM**: COUNT contaría filas del mart, no pólizas ni siniestros.

## Indicadores

Las métricas dividen sumas para conservar la ponderación al cambiar filtros o agrupaciones.

**Siniestralidad**, tipo Porcentaje:

```text
SUM(costo_pagado_usd) / SUM(prima_usd)
```

**Frecuencia pagada**, tipo Porcentaje:

```text
SUM(siniestros_pagados_con_costo_usd) / SUM(polizas)
```

**Severidad USD**, tipo Moneda USD:

```text
SUM(costo_pagado_usd) / SUM(siniestros_pagados_con_costo_usd)
```

La frecuencia mide eventos, no pólizas afectadas: 15 pagos sobre 100 pólizas son 15 eventos cada 100 pólizas. Si cuestan USD 6.000, la severidad es USD 400 por evento. Ambas métricas usan los mismos eventos PAGADO con costo USD válido.

La **prima media USD** es `SUM(prima_usd) / SUM(polizas)`. La relación `siniestralidad = frecuencia × severidad / prima media` explica por qué una prima baja puede producir un ratio alto sin frecuencia ni severidad elevadas. Un denominador cero significa indicador sin valor.

Siniestralidad y frecuencia se muestran como **porcentajes** con dos decimales; severidad, como **USD por evento**. El ratio `0,3817` representa `38,17%`, sin multiplicar por 100 en la fórmula.

## Ejemplo de lectura — abril–junio de 2026

Los [resultados de las dos queries de análisis](../parte_05_analisis/README.md#ejemplo-de-análisis-tres-trimestres-de-emisión) dan ejemplos para el mismo período y corte:

- Chile presenta la mayor siniestralidad observada: **41,82%**, frente a **38,17%** de la cartera.
- Equipaje Protegido alcanza **144,63%**. Su prima media es USD 30,59 frente a USD 125,64 general; el ratio elevado no se explica por frecuencia o severidad especialmente altas.
- ONLINE en Chile llega a **65,15%**, con **17,03 eventos pagados cada 100 pólizas** y **USD 464,33 por evento**, frente a 11,44 y USD 334,05 en CALL_CENTER. En este segmento, frecuencia y severidad acompañan la diferencia.

La categoría “Otros” del gráfico de productos agrupa los planes restantes; no representa un plan individual. Las comparaciones son descriptivas y no demuestran causalidad: deben considerarse la mezcla de planes, los canales y el tamaño de cada población. Para comparar premium y no premium, utilizar productos del mismo `tipo_producto`.

## Tratamiento de datos y límites

Gold excluye pólizas D/ausentes/ANULADA y sus eventos, y retira negativos y casos monetarios no resolubles de importes y conteos. La moneda inferida válida se incluye. La falta de coincidencia de cobertura se clasifica aparte; existen medidas `*_con_periodo`. [Tratamiento y alcance](../../README.md#anomalías-y-tratamiento).

**Las cohortes recientes pueden seguir acumulando siniestros y pagos.** La prima es la última informada, no prima devengada ni cobro comprobado. El corte limita ocurrencia; no reconstruye estados históricos ni fechas de pago.

La tabla de consumo mide **15,21 MB**. Este tamaño no equivale al escaneo total de una carga del dashboard: el conector puede emitir varias consultas. El límite de **50 MB por carga** no se presenta como validado mediante una medición de las interacciones reales.
