---
name: assist365-analisis
description: Responder preguntas de negocio sobre siniestralidad, frecuencia, severidad, planes y canales de Assist-365 consultando su warehouse BigQuery con las definiciones del challenge.
---

# Análisis de Assist-365

Usar esta skill para traducir preguntas de negocio a consultas del proyecto `a365-de-ignacio`, región `us-central1`. Consultar el warehouse existente; no descargar datos de la API ni ejecutar cargas/modelos como parte del análisis.

## Elegir período y fuente

- Fijar meses de emisión y corte de ocurrencia. Para reproducir la entrega, usar **01/04/2026–30/06/2026**, con corte **29/09/2026**. Si la pregunta dice “este trimestre” sin referencia clara, aclarar el período antes de comparar.
- Preferir `assist365_mart.dashboard_diario` para agregados. Es **mensual**, pese al nombre: `date` es el primer día del mes de emisión. No permite analizar días reales de emisión o pago.
- Comprobar el corte de la publicación en `assist365_control.gold_runs`, tomando el último SUCCESS por `finished_at` y su `summary.fecha_corte`; filtrar también la partición `DATE(started_at)`. Una gold publicada no permite reconstruir estados históricos a otro corte.
- Usar staging para detalle por entidad o diagnósticos. Si se necesita otro corte, informar que requiere construir o consultar el agregado adecuado; no modificar el warehouse automáticamente.

## Tablas y relaciones

| Tabla | Grano y uso |
|---|---|
| `assist365_mart.dashboard_diario` | Mes de emisión, país, plan, premium, tipo de producto y canales. Medidas aditivas para análisis; dimensiones `pais`, `producto`, `es_premium`, `tipo_producto`, `canal_origen`, `canal_agencia`. |
| `assist365_staging.polizas_activas` | Una fila por `poliza_id`, último estado no D. Incluye ANULADA/VENCIDA; excluir ANULADA en este análisis. |
| `assist365_staging.polizas` | Historial por póliza, `updated_at` y operación I/U/D. Sirve para auditoría; no sumar su prima como cartera actual. |
| `assist365_staging.siniestros` | Una fila por `siniestro_id`, relacionada por `poliza_id`. Contiene monto original y flags monetarios/cobertura. |
| `assist365_staging.productos` | Una fila por `producto_id`; nombre del plan, tipo y modalidad premium. |
| `assist365_staging.agencias` | Una fila por `agencia_id`; nombre, país y canal de agencia. El nombre no es una clave única. |
| `assist365_staging.tipo_cambio` | Fecha y moneda; `factor_usd` convierte monto local a USD. |
| `assist365_raw.*` | Capturas por recurso con JSON original y metadatos de carga; para trazabilidad, no fuente habitual del dashboard. |
| `assist365_control.*` | Ejecuciones, conciliaciones y revisión de anomalías; separado de las entidades de negocio. |

En staging, agregar siniestros por póliza **antes** del LEFT JOIN con pólizas, para sumar cada prima una vez y conservar pólizas sin eventos. No usar `SUM(DISTINCT prima)`: dos pólizas diferentes pueden tener el mismo importe. Mostrar nombres de plan y canales, no IDs, en resultados comerciales.

## Glosario y métricas

| Término | Definición aplicada |
|---|---|
| Prima | Último importe informado de la póliza; no es indemnización, cobro comprobado ni prima devengada. |
| Cohorte | Pólizas emitidas en el mismo mes y sus siniestros observados hasta el corte, aunque ocurran después de ese mes. |
| Póliza elegible | Último estado no D ni ANULADA; conservar vencidas de cohortes históricas. |
| Siniestro pagado válido | Estado PAGADO, monto monetariamente válido y conversión USD disponible. Una póliza puede tener varios. |
| Exposición / maduración | Aquí la exposición se aproxima por cantidad de pólizas, sin ajustar duración. Cohortes recientes tienen menos tiempo para acumular eventos y costo. |
| Margen | Requiere gastos y otras obligaciones; el ratio entregado no demuestra margen neto. |

Sobre gold, calcular ratios **dividiendo sumas** y usando `SAFE_DIVIDE`:

| Métrica | Expresión |
|---|---|
| Siniestralidad operativa | `SAFE_DIVIDE(SUM(costo_pagado_usd), SUM(prima_usd))` |
| Frecuencia pagada | `SAFE_DIVIDE(SUM(siniestros_pagados_con_costo_usd), SUM(polizas))` |
| Severidad USD | `SAFE_DIVIDE(SUM(costo_pagado_usd), SUM(siniestros_pagados_con_costo_usd))` |
| Prima media USD | `SAFE_DIVIDE(SUM(prima_usd), SUM(polizas))` |

Frecuencia mide eventos por póliza, no porcentaje de pólizas afectadas. Severidad mide USD por evento pagado válido. Con denominadores no cero, `siniestralidad = frecuencia × severidad / prima media`. Formatear los ratios como porcentaje sin multiplicarlos por 100 en la fórmula; informar NULL si falta denominador.

## Reglas de población y moneda

- Gold excluye pólizas D, ausentes y última ANULADA, junto con sus siniestros. En staging, construir la misma población antes de calcular indicadores.
- Excluir ocurrencias posteriores al corte y eventos con `excluir_calculos = TRUE`. Contar otros estados por separado; costo, frecuencia y severidad operativos usan PAGADO válido. El estado PAGADO es el disponible en la captura: no hay fecha ni historia de pago.
- Incluir moneda inferida válida, marcada `INFERIDA_POLIZA`. Excluir negativos y casos monetarios no resolubles. Cobertura no coincidente es un flag independiente, no una exclusión automática; las medidas `*_con_periodo` permiten analizar solo coincidencias.
- Convertir prima con FX de emisión y costo con FX de ocurrencia: `monto × factor_usd`, última cotización positiva anterior o igual a la fecha; USD usa 1. No invertir automáticamente `unidades_por_usd` ni tomar una tasa futura.
- Comparar premium/no premium dentro de `tipo_producto`. Considerar volumen, duración, maduración y mezcla de planes antes de atribuir diferencias a país o canal. Una severidad media alta no demuestra que todos los eventos sean caros.

## Consultar y responder

Usar un MCP BigQuery disponible y autorizado para ejecutar consultas de lectura. Si no está disponible, informar esa limitación y usar `bq` como alternativa cuando haya acceso; registrar el mecanismo real y nunca presentar una ejecución CLI como evidencia MCP.

Seleccionar columnas necesarias y filtrar `date` por meses completos en gold, o las particiones de negocio pertinentes en staging. Usar parámetros para fechas/filtros y límites de bytes cuando el cliente lo permita. El límite del dashboard es **50 MB escaneados por carga**, no tamaño almacenado ni bytes facturados.

Entregar período, corte, números, definición y una interpretación breve, con consulta o job verificable. Revisar conteos y denominadores; si faltan primas/costos USD, explicitar el alcance parcial mediante las medidas de completitud. No inventar resultados ni dar una conclusión causal a partir de una comparación descriptiva.

## Cinco preguntas de ejemplo

Son ejemplos de uso de la skill, no evidencia de cinco ejecuciones MCP.

| Pregunta | Cómo resolverla |
|---|---|
| ¿Qué país está peor en abril–junio de 2026? | Agrupar gold por `pais`; comparar siniestralidad descendente con prima, pólizas y eventos válidos. |
| ¿Qué plan tiene costo pagado superior a su prima? | Agrupar por `producto`; buscar ratio mayor que 1 y mostrar volúmenes. Describir desequilibrio observado, no margen neto. |
| ¿La diferencia de Chile frente al resto viene de frecuencia o severidad? | Calcular ambos componentes y prima media por país; comparar Chile con el agregado del resto recalculando ratios sobre sumas. |
| ¿Los planes premium funcionan mejor que los no premium? | Agrupar por `tipo_producto`, `es_premium`; comparar siniestralidad/componentes y tamaños dentro del mismo tipo. |
| ¿Qué canal de agencia funciona peor en cada país? | Agrupar por `pais`, `canal_agencia`; mostrar ratio, pólizas, eventos, frecuencia y severidad. No sustituir por `canal_origen`. |

## Referencias del repositorio

- [Glosario y fundamentos](README.md#glosario-y-fundamento-de-las-métricas): consultar para explicar el porqué y los límites.
- [Esquema gold](scripts/parte_03_modelo_bigquery/gold/schema.json) y [esquema staging](scripts/parte_03_modelo_bigquery/silver_schema.json): comprobar campos antes de consultar.
- [Queries e insights](scripts/parte_05_analisis/README.md): dos SQL desde staging con población y conversión de referencia.
- [Tablero](scripts/parte_06_tablero/README.md): fórmulas y medición real del conector.
- [Acceso al proyecto](docs/EJECUCION.md#requisitos): autenticación CLI y permisos necesarios.
