# Assist-365 — pipeline y análisis de siniestralidad

Solución del challenge de Data Engineering: cinco recursos de API conservados en GCS, capas raw/staging/mart en BigQuery y análisis de siniestralidad en USD por cohortes de emisión. **Estado revisado al 30/09/2026:** flujo ejecutado desde un clon limpio con archivos en GCS, pruebas aprobadas y dashboard disponible; automatización diaria pendiente.

**[Abrir el dashboard](https://datastudio.google.com/reporting/be1247ad-58d9-4ed1-ba70-ca4830505fb3/page/0eCAG)**. Inicia en abril–junio de 2026 y permite comparar países, planes y frecuencia/severidad, con filtros de país, producto y canal de agencia.

## Acceso y ejecución

- **Consultar resultados:** abrir el dashboard o ejecutar las [dos queries de análisis](scripts/parte_05_analisis/README.md) con acceso a BigQuery. No requieren token API ni archivos locales.
- **Reejecutar el flujo:** seguir la [guía de ejecución](docs/EJECUCION.md). El snapshot `smoke-20260929` está en GCS; las cargas y los modelos no necesitan consultar nuevamente la API. Su manifiesto conserva la confirmación de carga; se comprueban archivos y conteos antes de omitirlo.
- **Entorno:** Python 3.10+, Google Cloud CLI y permisos en `a365-de-ignacio`, región `us-central1`. No requiere dependencias pip. Clonar el repositorio no concede permisos: la identidad debe poder leer GCS y crear jobs BigQuery; para ejecutar cargas/modelos también necesita escritura en sus destinos. Los scripts y SQL están vinculados al proyecto entregado.
- **API:** el token del challenge está incluido en [config/assist365.json](config/assist365.json) y el extractor lo lee automáticamente. Las credenciales de Google Cloud se obtienen con `gcloud auth login`, no desde ese archivo.

Para ejecutar las capas desde GCS con un único comando:

```bash
python3 -m scripts.run_pipeline --run-id smoke-20260929 --fecha-corte 2026-09-29
```

Se detiene ante errores y conserva evidencia en GCS. `--setup` crea/reutiliza el entorno; no activa una descarga nueva ni una programación diaria. [Comandos individuales y pruebas](docs/EJECUCION.md).

**Ensayo de entrega:** ejecutado desde un clon sin archivos de datos locales ni el Markdown del ejercicio. Preparación reutilizó GCS, raw verificó sus conteos sin duplicar el snapshot, staging reconoció el lote procesado y gold se reconstruyó correctamente. Pasaron 20 pruebas offline y las pruebas SQL de incrementales, gold, flags y fechas UTC; ambas queries analíticas devolvieron resultados. La extracción nueva se probó con fixtures, sin consultar la API. [Evidencia del ensayo](docs/evidence/ensayo_20260930.json).

## Guía de Uso

Ejecutar desde la raíz del repositorio, con Python 3.10+, Google Cloud CLI y acceso al proyecto/bucket entregados.

1. **Preparar la terminal:** `gcloud auth login`, `gcloud config set project a365-de-ignacio` y `bq version`. Ejecutar también `python3 -m unittest discover -s scripts/bonus -p 'test_*.py'` para verificar las pruebas offline.
2. **Primera ejecución con la captura entregada:** `python3 -m scripts.run_pipeline --run-id smoke-20260929 --fecha-corte 2026-09-29 --setup`. Crea/reutiliza el entorno y procesa GCS → raw → staging → gold.
3. **Repetición o demostración:** ejecutar el mismo comando sin `--setup`. Raw verifica el lote ya cargado; staging omite la versión confirmada o la reaplica si cambió el SQL; gold se reconstruye. Los MERGE conservan la unicidad de las entidades.
4. **Captura nueva, primera vez o al día siguiente:** seguir los [dos comandos API → pipeline](docs/EJECUCION.md#captura-nueva-api--gcs--raw--staging--gold). Asignar un identificador nuevo, descargar con `--full` y usar el mismo identificador en `run_pipeline`. Raw agrega el snapshot; staging aplica los cambios; gold reemplaza su agregado. Para reanudar una falla se conserva el identificador.
5. **Revisar la ejecución:** comprobar `pipeline_finished` con `SUCCESS`, consultar el estado de staging y el inventario de gold, ejecutar las [dos queries analíticas](docs/EJECUCION.md#camino-rápido-análisis-desde-staging) y abrir el dashboard. [Comandos de verificación y recuperación](docs/EJECUCION.md#captura-nueva-api--gcs--raw--staging--gold).

La guía reproduce el proyecto entregado; la instalación en otro proyecto y la restauración de tablas eliminadas requieren adaptación. El acceso del challenge tiene vencimiento indicado en el ejercicio: **02/10/2026, 02:35 UTC (01/10, 23:35 de Argentina)**. Una demostración posterior requiere confirmar la continuidad de ese acceso.

## Arquitectura

`API → gzip y checkpoints en GCS → raw → staging → mart → Looker Studio`

| Capa | Tablas y contenido | Volumen de referencia |
|---|---|---|
| `assist365_raw` | `polizas`, `siniestros`, `agencias`, `productos`, `tipo_cambio`: JSON original y trazabilidad de carga. | 1.147.859 registros en cinco tablas. |
| `assist365_staging` | `polizas`: historial; `polizas_activas`: último estado no D; `siniestros`: eventos únicos; catálogos de agencias, productos y FX. Todas son tablas físicas. | 1.003.461 eventos de pólizas; 780.000 pólizas actuales; 138.133 siniestros; 300 agencias; 12 productos; 5.124 cotizaciones. |
| `assist365_mart` | `dashboard_diario`: agregado **mensual** por cohorte de emisión y dimensiones comerciales. | 45.875 filas; 37 campos; 15,21 MB. |
| `assist365_control` | Ejecuciones, checkpoints, conciliaciones y revisión de anomalías, separados de los datos de negocio. | Evidencia operativa; no se usa como fuente del dashboard. |

La captura de referencia es del **29/09/2026**. Sus archivos están en `gs://a365-de-ignacio-assist365-data`: `raw/` contiene páginas/checkpoints y `bigquery-load/` contiene NDJSON/manifiestos/recibos. Las evidencias nuevas de modelos se guardan en `silver/` y `gold/`. El bucket comparte región con BigQuery, usa acceso uniforme y tiene acceso público bloqueado. La migración verificó 1.316 archivos más dos manifiestos actualizados. Los cinco recursos se cargaron desde GCS en tablas de prueba y coincidieron con raw; las tablas de prueba se eliminaron. La preparación usa temporales efímeros para compresión, sin requerir un snapshot local persistente.

## Operación y segunda corrida

| Etapa | Comportamiento implementado |
|---|---|
| Extracción | Una captura nueva descarga el snapshot completo. Repetir `run_id` reanuda páginas/checkpoints en GCS. El parámetro API `updated_since` todavía no está integrado. |
| Raw | Carga NDJSON gzip mediante URI GCS y valida integridad antes de enviar archivos. Reutiliza jobs confirmados mientras BigQuery conserve su historial; el snapshot de referencia verifica archivos y conteos antes de omitir la migración confirmada. |
| Staging | MERGE transaccional para I/U/D, eventos tardíos y correcciones; checkpoints por lote y versión SQL. Lotes idénticos confirmados se omiten. Los catálogos se procesan como snapshots completos. |
| Gold | Reconstrucción del agregado para un corte explícito después de staging, con validación antes de publicar. |

La ejecución es manual por CLI: no hay un servicio diario programado. La guía reutiliza el entorno entregado; no constituye un instalador genérico para otro proyecto ni una restauración automática de tablas eliminadas. Los reintentos de raw no sustituyen una deduplicación permanente entre snapshots diferentes.

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

## Glosario y fundamento de las métricas

Las métricas separan **cuántos eventos generan costo**, **cuánto cuesta cada evento** y **cuánta prima respalda ese costo**. Se calculan para la misma población de pólizas elegibles y el mismo corte, contando cada siniestro una vez.

**Frecuencia pagada = siniestros PAGADO con costo USD válido / pólizas elegibles.** Se divide por todas las pólizas de la población, incluidas las que no tuvieron eventos, para comparar carteras de distinto tamaño. Contar eventos sin ese denominador confundiría volumen de ventas con incidencia; dividir solo por pólizas con siniestro quitaría del análisis a quienes no generaron costo. Es una frecuencia operativa por póliza: no ajusta duración de viaje ni días de cobertura observados. Una evolución actuarial debería incorporar esa exposición.

**Severidad USD = costo PAGADO válido en USD / cantidad de esos mismos siniestros.** Mide el costo medio por evento. Dividir por pólizas daría costo por póliza, una medida diferente; incluir eventos pendientes o rechazados en el denominador diluiría el promedio de los pagados. Es un promedio observado: no estima el costo futuro ni describe por sí solo los casos extremos.

Se eligió **PAGADO** para mantener costo y conteo sobre los mismos eventos con estado de pago informado. Los demás estados permanecen disponibles y tienen conteos separados, pero este indicador no representa toda la obligación pendiente. La inferencia monetaria válida se incluye; negativos y casos no resolubles se excluyen de costo y conteo.

La distinción entre exposición para frecuencia y cantidad de eventos para severidad es consistente con el [material de modelos de tarifas de la Casualty Actuarial Society, página 27](https://www.casact.org/sites/default/files/2022-07/RP4_RateModels.pdf#page=27). Aquí se adopta expresamente la póliza como unidad operativa de exposición.

**Ejemplo ilustrativo, no resultado del dataset:** 1.000 pólizas, 100 siniestros pagados válidos, USD 50.000 de costo y USD 200.000 de prima.

| Indicador | Resultado | Lectura |
|---|---|---|
| Frecuencia | 100 / 1.000 = 0,10 | 10 eventos pagados cada 100 pólizas; no significa 10% de pólizas afectadas. |
| Severidad | 50.000 / 100 = USD 500 | Costo promedio de cada evento pagado. |
| Prima media | 200.000 / 1.000 = USD 200 | Prima promedio por póliza de la población. |
| Siniestralidad | 50.000 / 200.000 = 25% | El costo pagado representa un cuarto de la prima informada. |

Con denominadores distintos de cero, **siniestralidad = frecuencia × severidad / prima media**: `0,10 × 500 / 200 = 25%`. Por eso un ratio alto puede venir de más eventos, eventos más caros o una prima baja. No prueba causalidad ni margen neto. Una frecuencia puede superar 100% si hay varios eventos por póliza; si no hay eventos, frecuencia es cero y severidad queda sin valor. Siempre se dividen sumas al agregar meses/países, para conservar la ponderación por pólizas o eventos.

| Término | Definición aplicada |
|---|---|
| Prima | Importe de la póliza, usando su último estado disponible. No es el monto a pagar ante un siniestro ni prueba de cobro. |
| Siniestro | Evento identificado por `siniestro_id`; una póliza puede tener varios. |
| Costo pagado | Monto del evento con estado PAGADO y validez monetaria. No se reconstruyen pagos por fecha porque no hay fecha/historia de pago. |
| Siniestralidad operativa | Costo pagado USD dividido por prima USD. Usa prima informada, sin devengar, y no incluye gastos ni reservas pendientes. |
| Póliza elegible | Último estado no D ni ANULADA. Incluye pólizas vencidas; elegibilidad analítica no equivale a cobertura vigente hoy. |
| Cohorte de emisión | Pólizas emitidas en el mismo mes, junto con sus siniestros posteriores observados hasta el corte. |
| Vigencia | Intervalo de cobertura de la póliza; se usa para clasificar coincidencia, no para asignar la cohorte. |
| Corte y maduración | Corte limita ocurrencias incluidas. Maduración es el tiempo de observación de la cohorte; cohortes recientes pueden acumular más costo. |
| Exposición | Base sobre la que ocurren eventos. Aquí se cuenta una unidad por póliza, sin ajustar días de viaje o cobertura. |
| Prima devengada y margen | Devengada es la prima atribuida a la cobertura ya transcurrida. Margen requiere además gastos y otras obligaciones; ninguno se calcula aquí. |
| Grano | Qué representa una fila: un evento en el historial, una póliza actual, un siniestro o un grupo mensual en gold. |
| ABM / I-U-D e idempotencia | Alta, modificación y baja según la fuente. Idempotencia permite repetir un lote sin duplicar entidades ni revertir estados más recientes. |

Las fechas de FX y las exclusiones se fundamentan en [decisiones del modelo](#decisiones-del-modelo) y [anomalías](#anomalías-y-tratamiento). Las fórmulas para Looker están en la [guía del tablero](scripts/parte_06_tablero/README.md#indicadores).

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

Las dos queries desde staging responden por **mes de emisión, país/plan** y **mes de emisión, país/canal de agencia**, con cantidades de pólizas y siniestros, prima y costo USD. El dashboard usa el mismo criterio sobre gold y abre en abril–junio de 2026.

- **País a revisar:** Chile tiene el mayor ratio observado del trimestre, **41,82%**, frente a **38,17%** de la cartera.
- **Plan a revisar:** Equipaje Protegido alcanza **144,63%**; el costo pagado supera la prima. Su prima media baja ayuda a explicar el ratio, sin demostrar margen neto.
- **Insight adicional:** ONLINE en Chile pasa de **57,07% a 65,15%** entre oct–dic 2025 y abr–jun 2026, mientras la cartera baja de **40,11% a 38,17%**. En el último trimestre, sus frecuencia y severidad superan las de CALL_CENTER; corresponde revisar mezcla de planes/agencias antes de atribuir causalidad al canal.

El [análisis completo](scripts/parte_05_analisis/README.md) incluye los tres trimestres y los componentes del ratio. Premium/no premium está disponible en gold; no se presenta una conclusión específica validada sobre esa comparación.

La evidencia incluye **29 comprobaciones raw, 13 staging y 24 gold**, más 21 pruebas funcionales gold, ocho pruebas de flags y 20 pruebas offline de configuración, extracción y almacenamiento. Las comprobaciones raw son cinco por recurso —filas, páginas, posiciones duplicadas, metadatos y marcadores no finitos—, una de inventario de páginas y tres de tablas de control. Son un conjunto fijo de controles: cada ejecución registra sus resultados, sin implicar nuevas cargas de datos. Staging también se ejecutó correctamente desde el manifiesto GCS, conservando los conteos indicados. [Pruebas y comandos](scripts/bonus/README.md).

El ratio no mide margen neto ni prima devengada; las cohortes recientes pueden seguir acumulando costo. El flujo se ejecuta por CLI con snapshots y cargas raw→staging incrementales.

## Consumo real del dashboard

El 30/09/2026 se abrió el tablero en una sesión aislada, con rango **01/04/2026–30/06/2026**. Se identificaron los jobs en `INFORMATION_SCHEMA.JOBS_BY_PROJECT` mediante las etiquetas `requestor=looker_studio` y el ID del reporte, dentro de la ventana de prueba. Se sumó `total_bytes_processed` de **todas** las consultas del conector, excluyendo las consultas manuales de auditoría.

La carga generó **ocho consultas**: cuatro gráficos, tres controles de filtro y una adicional para “Otros”. Procesó **1.405.616 bytes = 1,405616 MB**, el **2,81% del límite de 50 MB**, sin aciertos de caché BigQuery. El SQL real incluye las fechas y consume solo las columnas necesarias del agregado mensual; no lee raw ni staging. Las pruebas individuales de país CL, canal ONLINE y Equipaje Protegido también quedaron debajo del límite; el mayor escaneo observado fue **1.582.008 bytes (1,58 MB)**.

La facturación registró **83.886.080 bytes (83,89 MB)** por los mínimos por consulta. Es distinta del escaneo solicitado por el ejercicio; el indicador para ese requisito es **bytes procesados**, no tamaño almacenado ni bytes facturados. [Criterio de facturación de BigQuery](https://cloud.google.com/bigquery/pricing). [Desglose, filtros y reproducción de la medición](scripts/parte_06_tablero/README.md#medición-de-consumo).

## Cobertura del ejercicio y prioridades

| Punto solicitado | Estado | Entrega y criterio |
|---|---|---|
| **1. Extracción** | Implementado | Pólizas, siniestros y tres catálogos completos, con paginación, reintentos y recuperación. Se priorizó conservar una captura verificable. |
| **2. Carga en BigQuery** | Implementado | Raw por recurso y controles separados. Carga de gzip desde GCS con `bq load`, checksums y conciliación de registros. |
| **3. Modelo** | Implementado | Hecho de ventas: `polizas_activas`, una fila por póliza; hecho de siniestros: `siniestros`, una fila por evento. Catálogos de producto/agencia y FX fecha/moneda, más historial de pólizas. Los granos y reglas I/U/D están documentados. |
| **4. Orquestación diaria** | Diseño, sin despliegue | CLI reproducible y recuperación implementadas. Cloud Run/Scheduler no desplegados: se priorizó cerrar datos y análisis antes de automatizar. La segunda extracción sería un snapshot completo; el mismo run_id reanuda una captura. |
| **5. Análisis** | Implementado | Dos queries mensuales con prima/costo USD y cantidades. Siniestralidad por país/plan e insight de canal por país, con evolución de tres trimestres. |
| **6. Tablero** | Implementado; consumo medido | Una página, cuatro gráficos y tres filtros sobre gold. Carga inicial abril–junio: **1.405.616 bytes procesados (1,41 MB)** en ocho jobs reales, sin caché BigQuery, por debajo de 50 MB. Enlace, captura, SQL de medición y evidencia incluidos. |
| **7. README** | Implementado | Arquitectura, ejecución, decisiones, anomalías, resultados y límites por capa. |
| **Bonus 1. Capa semántica y MCP** | No implementado | Definiciones en documentación, sin SKILL.md ni cinco preguntas ejecutadas vía MCP. Se priorizaron SQL reproducibles y el tablero. |
| **Bonus 2. Tests de datos** | Implementado en SQL | Conciliaciones y pruebas con tablas temporales para I/U/D, transacciones, flags y agregación. Se usó SQL nativo sin sumar otro framework. |
| **Bonus 3. GitHub Actions** | No implementado | Pruebas ejecutables manualmente; CI quedó fuera para concentrar tiempo en validar el warehouse. |
| **Bonus 4. Video** | No realizado | La entrega se explica mediante código, documentación y dashboard; se priorizaron resultados reproducibles. |

El orden elegido fue **datos completos y trazables → reglas de negocio y calidad → métricas verificadas → dashboard**. Las anomalías de moneda, negativos y cobertura podían distorsionar las respuestas comerciales; resolver su tratamiento tuvo prioridad sobre despliegue diario y bonus. Se reutilizó la captura disponible para desarrollar el modelo y el análisis sin repetir consultas a la API.

## Pendientes y mejoras

| Prioridad | Pendiente | Criterio de cierre |
|---|---|---|
| Mantenimiento | Revalidar el consumo al cambiar datos, gráficos o rango temporal. | Repetir la medición de una carga aislada y sus filtros; la validación actual corresponde a la configuración y captura entregadas. |
| Accesos | Revisar permisos si se incorporan otros evaluadores. | La cuenta de la empresa indicada en el ejercicio es Owner del proyecto; los cuatro datasets y GCS reconocen a sus propietarios. Dashboard público. [Comprobación IAM](docs/evidence/acceso_20260930.json). |
| Operación | Desplegar Cloud Run Job + Scheduler. | Ejecución diaria con identidad de servicio, etapas secuenciales y registro/alerta de fallas. El diseño está documentado. |
| Portabilidad | Parametrizar proyecto/datasets y definir restauración y retención de artefactos. | Poder instalar en otro proyecto y recuperar un entorno vacío sin editar referencias ni depender de confirmaciones anteriores. |
| Evolución | Extracción delta, CI, capa semántica y evolución del modelo. | Incorporar watermark para pólizas; automatizar pruebas; resolver negativos/cobertura con la fuente y evaluar historia dimensional y exposición. |

El [diseño de orquestación](scripts/parte_04_orquestacion/README.md) detalla el alcance cloud. El video y los bonus no implementados permanecen fuera de la entrega actual.

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
