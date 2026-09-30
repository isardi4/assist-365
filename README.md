# Assist-365 — pipeline y análisis de siniestralidad

Solución del challenge de Data Engineering: ingesta de cinco recursos, capas raw/staging/mart en BigQuery y análisis de siniestralidad en USD por cohortes de emisión.

**[Abrir el dashboard](https://datastudio.google.com/reporting/be1247ad-58d9-4ed1-ba70-ca4830505fb3/page/0eCAG)**. Inicia en abril–junio de 2026 y permite comparar países, planes y frecuencia/severidad, con filtros de país, producto y canal de agencia.

## Acceso y ejecución

- **Consultar resultados:** abrir el dashboard o ejecutar las [dos queries de análisis](scripts/parte_05_analisis/README.md) con acceso a BigQuery. No requieren token API ni archivos locales.
- **Reconstruir modelos:** seguir la [guía de ejecución](docs/EJECUCION.md). Staging consume raw y gold consume staging; recrear raw usa el snapshot conservado en GCS, sin volver a consultar la API.
- **Entorno:** Python 3.10+, Google Cloud CLI y permisos en `a365-de-ignacio`, región `us-central1`. Los destinos están vinculados a ese proyecto.
- **API:** el token del challenge está incluido en [config/assist365.json](config/assist365.json) y el extractor lo lee automáticamente. Las credenciales de Google Cloud se obtienen con `gcloud auth login`, no desde ese archivo.

## Arquitectura

`API → gzip y checkpoints en GCS → raw → staging → mart → Looker Studio`

| Dataset | Contenido |
|---|---|
| `assist365_raw` | Una tabla por recurso: pólizas, siniestros, agencias, productos y tipo de cambio. JSON original y trazabilidad de carga. |
| `assist365_staging` | Seis tablas físicas: historial y último estado de pólizas, siniestros únicos y tres catálogos. |
| `assist365_mart` | `dashboard_diario`: agregado **mensual** por cohorte de emisión y dimensiones comerciales. |
| `assist365_control` | Ejecuciones, checkpoints, conciliaciones y revisión de anomalías, separados de los datos de negocio. |

La captura de referencia es del **29/09/2026**. Sus archivos están en `gs://a365-de-ignacio-assist365-data`: `raw/` contiene páginas/checkpoints y `bigquery-load/` contiene NDJSON/manifiestos/recibos. Las evidencias nuevas de modelos se guardan en `silver/` y `gold/`. El bucket comparte región con BigQuery y requiere acceso autenticado.

## Decisiones del modelo

- **Pólizas:** la última U actualiza I; la última D retira la póliza del estado actual. Se conserva el historial. Gold excluye también la póliza completa si su último estado es ANULADA, junto con sus siniestros.
- **Cohortes:** prima y siniestros se atribuyen al mes de emisión de la póliza. Se acumulan ocurrencias hasta el corte de la captura, aunque sean posteriores al mes de emisión.
- **Conversión USD:** prima con FX de emisión; costo con FX de ocurrencia. Se usa la última cotización positiva anterior o igual a la fecha; USD tiene factor 1.
- **Calidad:** moneda inferida válida incluida y marcada; negativos y casos monetarios no resolubles excluidos de importes y conteos. La falta de coincidencia de cobertura tiene un flag independiente. [Anomalías y fundamentos](README.md#anomalías-y-tratamiento).
- **Cargas:** raw verifica archivos; staging aplica MERGE transaccional y checkpoints; gold se reconstruye para incorporar correcciones históricas.

## Capa gold

`assist365_mart.dashboard_diario` es una tabla física **mensual**, pese a su nombre. Su grano es mes de emisión, país, plan, modalidad premium, tipo de producto y canales de origen/agencia. Contiene **45.875 filas, 37 campos y 15.212.749 bytes (15,21 MB)**, sin IDs, JSON ni metadatos de carga.

`date` representa el primer día del mes de emisión; `year_month` y `year_quarter` permiten agregar cohortes. `producto` contiene el nombre del plan; `canal_agencia` viene del catálogo y es distinto de `canal_origen`, que pertenece a la póliza. `day` y `day_of_week` describen el primer día del mes, no eventos diarios. [Esquema completo](scripts/parte_03_modelo_bigquery/gold/schema.json).

| Métrica | Cálculo sobre gold |
|---|---|
| Siniestralidad | `SUM(costo_pagado_usd) / SUM(prima_usd)` |
| Frecuencia pagada | `SUM(siniestros_pagados_con_costo_usd) / SUM(polizas)` |
| Severidad USD | `SUM(costo_pagado_usd) / SUM(siniestros_pagados_con_costo_usd)` |

Se dividen sumas, sin promediar ratios; un denominador cero significa indicador sin valor. Los siniestros se agrupan por póliza antes del join para sumar la prima una vez y conservar pólizas sin eventos. Gold se particiona por mes de `date` y se clusteriza por país, plan y canal de origen. Se reconstruye después de staging, validando el agregado antes de publicarlo. [Ejecución del modelo](scripts/parte_03_modelo_bigquery/README.md#construcción-gold).

## Anomalías y tratamiento

Cantidades de staging completo al corte de referencia; las categorías pueden superponerse.

| Hallazgo | Decisión y fundamento |
|---|---|
| **411 monedas nulas** | Inferir desde la única moneda histórica de la póliza y marcar `INFERIDA_POLIZA`. En 137.170 pares comparables las monedas coinciden. La fuente permanece nula; 410 inferidos son monetariamente válidos y uno también es negativo. |
| **824 montos negativos** | Excluir de costo y conteos: no hay evidencia de reversa/reintegro ni un positivo equivalente en la misma póliza y moneda. No usar valor absoluto ni reemplazar por cero. |
| **829 duplicados exactos** | Deduplicar a un siniestro; un conflicto de contenido bloquea la carga. |
| **1.242 eventos fuera de vigencia** | Marcar `FUERA_PERIODO`: ocurren 1–58 días después del fin. No cambiar el estado comercial ni excluirlos automáticamente si el importe es válido. |
| **552 referencias sin póliza** | Marcar `POLIZA_AUSENTE`, sin inventar entidades o fechas. Fuera de gold. |
| **4.145 ocurrencias futuras** | Conservar la fecha original y excluir eventos posteriores al corte 29/09/2026 del costo observado. |
| **438 eventos de última ANULADA y 3.473 de última D** | Excluir la póliza completa y sus eventos de este análisis; conservarlos para auditoría e historia. |
| **3.703 factores FX no recíprocos, de 5.124** | Respetar `factor_usd` del contrato, sin invertirlo ni corregirlo silenciosamente. |

Los flags separan cobertura de validez monetaria. `excluir_calculos` retira también importes nulos, moneda irrecuperable o falta de cotización válida. **Una moneda inferida válida se incluye**. Para analizar solo cobertura coincidente, gold ofrece `*_con_periodo`; se conservan prima y pólizas como denominadores.

La publicación gold comprende **733.169 pólizas** y **128.890 siniestros elegibles**, incluidos 100.370 PAGADO. Dentro de su población/corte hay 774 eventos monetariamente excluidos (633 PAGADO), 384 inferidos elegibles (292 PAGADO) y 1.141 elegibles sin período coincidente. Difieren de los totales anteriores por las exclusiones de población y fecha; los motivos se registran en `assist365_control`. [Diagnóstico de vigencias](scripts/parte_03_modelo_bigquery/policy_period_diagnostic.md).

## Resultados y alcance

La siniestralidad operativa es `SUM(costo_pagado_usd) / SUM(prima_usd)`. En abril–junio de 2026, Chile presenta el mayor ratio observado (**41,82%**) y Equipaje Protegido alcanza **144,63%**. El [análisis](scripts/parte_05_analisis/README.md) explica la evolución de tres trimestres y el papel de frecuencia, severidad y prima media.

Las validaciones incluyen **13 conciliaciones staging, 24 gold, 21 pruebas funcionales gold y ocho pruebas de flags**. Las pruebas reproducibles y requisitos están en la guía de ejecución.

El ratio no mide margen neto ni prima devengada; las cohortes recientes pueden seguir acumulando costo. El flujo se ejecuta por CLI con snapshots y cargas raw→staging incrementales.

## Cobertura del ejercicio y prioridades

| Punto solicitado | Estado | Entrega y criterio |
|---|---|---|
| **1. Extracción** | Implementado | Pólizas, siniestros y tres catálogos completos, con paginación, reintentos y recuperación. Se priorizó conservar una captura verificable. |
| **2. Carga en BigQuery** | Implementado | Raw por recurso y controles separados. Carga de gzip desde GCS con `bq load`, checksums y conciliación de registros. |
| **3. Modelo** | Implementado | Hecho de ventas: `polizas_activas`, una fila por póliza; hecho de siniestros: `siniestros`, una fila por evento. Catálogos de producto/agencia y FX fecha/moneda, más historial de pólizas. Los granos y reglas I/U/D están documentados. |
| **4. Orquestación diaria** | Diseño, sin despliegue | CLI reproducible y recuperación implementadas. Cloud Run/Scheduler no desplegados: se priorizó cerrar datos y análisis antes de automatizar. La segunda extracción sería un snapshot completo; el mismo run_id reanuda una captura. |
| **5. Análisis** | Implementado | Dos queries mensuales con prima/costo USD y cantidades. Siniestralidad por país/plan e insight de canal por país, con evolución de tres trimestres. |
| **6. Tablero** | Parcial | Una página, cuatro gráficos y filtros sobre gold; enlace y captura incluidos. Se priorizaron preagregación y métricas: tabla de 15,21 MB y ratios visibles conciliados. **No se midió el escaneo real por carga**, por lo que el límite de 50 MB no se declara cumplido. |
| **7. README** | Implementado | Arquitectura, ejecución, decisiones, anomalías, resultados y límites por capa. |
| **Bonus 1. Capa semántica y MCP** | No implementado | Definiciones en documentación, sin SKILL.md ni cinco preguntas ejecutadas vía MCP. Se priorizaron SQL reproducibles y el tablero. |
| **Bonus 2. Tests de datos** | Implementado en SQL | Conciliaciones y pruebas con tablas temporales para I/U/D, transacciones, flags y agregación. Se usó SQL nativo sin sumar otro framework. |
| **Bonus 3. GitHub Actions** | No implementado | Pruebas ejecutables manualmente; CI quedó fuera para concentrar tiempo en validar el warehouse. |
| **Bonus 4. Video** | No realizado | La entrega se explica mediante código, documentación y dashboard; se priorizaron resultados reproducibles. |

El orden elegido fue **datos completos y trazables → reglas de negocio y calidad → métricas verificadas → dashboard**. Las anomalías de moneda, negativos y cobertura podían distorsionar las respuestas comerciales; resolver su tratamiento tuvo prioridad sobre despliegue diario y bonus. Se reutilizó la captura disponible para desarrollar el modelo y el análisis sin repetir consultas a la API.

Con más tiempo, las prioridades serían medir el consumo real de Looker y verificar el acceso del destinatario, desplegar la operación diaria y parametrizar el proyecto. Después incorporar extracción delta, CI y capa semántica. El [diseño de orquestación](scripts/parte_04_orquestacion/README.md) explica la automatización propuesta.

## Documentación

| Parte | Contenido |
|---|---|
| [Extracción](scripts/parte_01_extraccion/README.md) | Paginación, archivos y recuperación. |
| [Carga raw](scripts/parte_02_carga_bigquery/README.md) | Preparación, carga y conciliación. |
| [Modelo](scripts/parte_03_modelo_bigquery/README.md) | Staging, carga incremental y construcción gold. |
| [Orquestación](scripts/parte_04_orquestacion/README.md) | Operación CLI y alcance del diseño cloud. |
| [Análisis](scripts/parte_05_analisis/README.md) / [tablero](scripts/parte_06_tablero/README.md) | Queries, insights, fórmulas e interpretación. |
| [Documentación](scripts/parte_07_readme/README.md) / [bonus](scripts/bonus/README.md) | Guía de lectura, uso de IA y pruebas de datos. |

Se utilizó asistencia de IA para código, SQL y documentación, contrastados con ejecuciones, conciliaciones y pruebas. [Guía de documentación y uso de IA](scripts/parte_07_readme/README.md).
