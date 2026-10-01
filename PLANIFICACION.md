# Planificación del caso práctico Assist-365

## Estado de entrega al 2026-09-30

| Fase | Estado real |
|---|---|
| Extracción y raw | Snapshot completo migrado a GCS; carga por recurso y 29 conciliaciones remotas. |
| Staging | Seis tablas físicas; MERGE incremental raw→silver, 13 conciliaciones y flags de calidad. |
| Gold | Cohortes mensuales: 45.875 filas, 15,21 MB, 24 conciliaciones y 21 pruebas funcionales. |
| Análisis | Dos queries independientes desde staging: país/plan y país/canal de agencia, por cohorte mensual de emisión. |
| Operación diaria | Diseño documentado; Cloud Run/Scheduler y extracción delta no desplegados. |
| Looker | Tablero creado, abre sin sesión en abril–junio de 2026; ratios visibles de países/planes conciliados. Acceso de la cuenta de la empresa comprobado por IAM; carga inicial medida: 1.405.616 bytes procesados en ocho jobs sin caché BigQuery. |
| Accesos | Token del challenge versionado en config/assist365.json por instrucción explícita; Google Cloud usa identidad CLI y no versiona credenciales. |

La [guía de ejecución](docs/EJECUCION.md) permite ejecutar ambas queries desde un clon con acceso a BigQuery, sin token API ni archivos descargados. La [revisión general](docs/REVISION_PROYECTO.md) identifica límites de portabilidad, plan y tipo de producto, interpretación del ratio y pendientes de entrega. Los apartados de operación futura son diseño, no evidencia de despliegue.

Las cohortes seleccionadas por defecto son pólizas emitidas en abril–junio de 2026, con siniestros asociados hasta el corte de ocurrencia del 29/09/2026. Las tres fechas declaradas permiten cambiarlo. La captura contiene fechas posteriores: se reportan sin corregir y no se usan para elegir automáticamente un trimestre futuro.

## Objetivo y criterio de entrega

Construir un recorrido reproducible desde la API hasta BigQuery y una vista de negocio que permita evaluar prima, costos pagados y frecuencia de siniestros. El trabajo se prioriza para entregar un flujo que corra de punta a punta, con carga repetible y documentada, antes que sumar componentes incompletos.

La definición de métricas y sus limitaciones debe quedar visible en el README y en las descripciones del modelo. No presentar una aproximación como si fuera una medida actuarial de cohorte.

## Criterio transversal: austeridad de consumo

Aplicar presupuesto de llamadas, bytes, almacenamiento y cómputo en todas las fases. Antes de una operación costosa, estimar su alcance y definir un límite; registrar el consumo real. Preferir persistir resultados y reutilizarlos antes que repetir descargas o consultas. Los límites nunca deben convertir una extracción incompleta en una entrega aparentemente exitosa.

- **API:** llamadas secuenciales, gzip, sin sondeos repetidos innecesarios; persistir cada página y reanudar desde checkpoints. Usar una descarga completa inicial porque el caso requiere cobertura total; las corridas siguientes reutilizan watermark para pólizas, aunque claims requieren snapshot completo según la API documentada.
- **BigQuery:** en raw, preservar todos los campos que entregue la fuente y el payload original; no podar columnas basándose en que `EJERCICIO.md` sea exhaustivo. En staging/mart, una vez perfilados los datos reales, seleccionar y transformar conscientemente lo necesario. Filtrar por partición y preagregar lecturas de consumo. Antes de consultas exploratorias/modelado, revisar bytes estimados y establecer `maximum_bytes_billed` cuando sea viable; evitar reejecuciones amplias.
- **GCP:** elegir una sola ruta de orquestación (Cloud Run Job + Scheduler), usar `us-central1` para BigQuery y GCS, y mantener tamaños/concurrencia modestos. Vigilar logs y almacenamiento raw; eliminar duplicados operativos según retención definida sin perder trazabilidad necesaria.
- **Looker Studio:** fuente agregada y acotada, rango temporal predeterminado pequeño, evitar controles/componentes que disparen consultas amplias; medir antes de compartir.
- Llevar un registro breve por fase de coste/consumo observado, límites y verificaciones, sin convertirlo en trabajo administrativo pesado.

## Confiabilidad, logs y tratamiento de errores

El pipeline no debe declarar éxito solo porque el proceso terminó con código cero. Cada etapa debe producir evidencia verificable, reconciliar entradas y salidas y conservar un inventario de errores. No descartar ni corregir filas silenciosamente. Las filas problemáticas van a cuarentena con origen, clave, etapa y motivo; el mart no se publica como completo mientras existan fallas que afecten conteos o métricas.

### Evidencia por ejecución y por registro

- Asignar `run_id` y `batch_id` y propagarlos por logs, archivos, raw y tablas de control. Registrar servicio/etapa, timestamps UTC, estado, endpoint/archivo/consulta, páginas o particiones, filas leídas/escritas/aceptadas/rechazadas, reintentos, duración y consumo relevante.
- Mantener tablas de control de ejecuciones y errores (o archivos equivalentes). Para cada error: `run_id`, recurso, clave de negocio disponible, página/offset, etapa, código/clase, mensaje breve, fingerprint, timestamp, estado de resolución y referencia al payload raw. No duplicar payload completo en logs ni registrar secretos o headers de autenticación.
- Clasificar como transitorio (retry seguro), dato inválido (cuarentena), configuración/permisos (detener) o integridad/conciliación (detener publicación). Limitar reintentos y registrar intentos fallidos aunque luego se recuperen.
- Distinguir `SUCCESS`, `SUCCESS_WITH_QUARANTINE` y `FAILED`. Solo publicar cifras completas con conciliaciones aprobadas. Si se permite continuar con cuarentena, mostrar conteo e impacto potencial y marcar resultados como parciales.
- Mantener lineage de filas curadas hasta recurso/lote/clave raw. Para agregados, registrar versión SQL/commit y fecha de cálculo.
- Tratar el esquema documentado como mínimo conocido, no como lista exhaustiva. La carga raw conserva todos los campos observados y el objeto original; registrar campos nuevos y cambios de tipo/esquema para decidir después cómo modelarlos.

### Conciliaciones obligatorias

1. **API → archivos/raw:** comparar filas recibidas con conteos por página y total de fuente cuando exista; verificar cursores/offsets sin saltos o repetición, archivos cerrados y tamaño/checksum si aplica. En pólizas, detectar cursor repetido o falta de progreso. Anotar cuando la fuente no provee total autoritativo.
2. **Raw → staging:** conciliar filas por lote/recurso con parseadas, inválidas y duplicadas; explicar toda diferencia.
3. **Staging → dimensiones/hechos:** conciliar aceptadas, descartadas por regla explícita y cuarentena. Medir unicidad, huérfanos, nulos críticos, cobertura FX y estados/monedas desconocidos.
4. **Hechos → métricas:** validar el grano y las sumas antes/después de agregaciones; detectar joins que multiplican filas. Conciliar ventas y siniestros por separado antes de unir agregados compatibles.
5. **BigQuery → tablero:** comparar KPIs del tablero con consulta de referencia para el mismo período/filtros y registrar bytes procesados.

### Workflow para analizar y resolver errores

1. Registrar el error estructurado, preservar la fila original en raw y poner la fila no procesable en cuarentena.
2. Emitir un resumen de severidad, causa, volumen afectado, claves/fingerprints y métricas posiblemente impactadas. Detener ante pérdida de páginas, discrepancia no explicada, duplicados de grano, FX faltante que impida USD o error de acceso/configuración.
3. Analizar una muestra y agrupar el conjunto por causa; decidir si es problema de origen, contrato, parseo, join, regla de negocio o código. No resolver solo el primer ejemplo.
4. Documentar hipótesis/decisión en README y registro de anomalías. Si se normalizan datos, preservar valor original, normalizado y motivo.
5. Corregir y reprocesar lote o claves de forma idempotente; reconciliar de nuevo y cerrar cada error como `resuelto`, `aceptado con justificación` o `pendiente`.
6. Antes de reproceso amplio, estimar llamadas/bytes. Preferir reprocesar desde raw; consultar de nuevo la API solo si falta el dato o se confirmó un cambio.

Si quedan anomalías sin resolver, marcar el mart incompleto y describir impacto; no declarar cifras exhaustivas. El tablero debe mostrar la frescura/calidad o conservar la última carga exitosa ante una corrida fallida.

## Requisitos y herramientas

### Necesarios para la solución principal

- Python 3 y gestor de dependencias para el extractor; librerías HTTP y de cliente GCP/BigQuery que se decidan, con versiones fijadas.
- Acceso a la API descrita en `EJERCICIO.md` y conectividad saliente desde el entorno de ejecución.
- `gcloud` CLI autenticado con el proyecto del ejercicio, permisos para BigQuery, GCS, Cloud Run Jobs, Cloud Scheduler, Artifact Registry (si se construye/publica imagen), IAM de service accounts y Secret Manager. Confirmar cuotas y APIs habilitadas antes de crear recursos.
- Un bucket GCS y datasets BigQuery en una región compatible; presupuesto/cuota suficiente para la descarga inicial, almacenamiento raw, cargas y consultas.
- Docker o Cloud Build para empaquetar y desplegar el Job (elegir un camino, no ambos por defecto).
- Cuenta de Looker Studio con acceso a BigQuery para construir y validar el tablero y compartirlo con el destinatario.
- `.gitignore` para credenciales, archivos temporales y datos descargados; configuración local de secretos fuera del repositorio.

### No necesarios para el camino principal

- **MCP:** no hace falta para extraer, modelar, analizar ni construir el tablero. Solo sería requisito del bonus de preguntas de negocio vía MCP; en ese caso hay que elegir/proveer un servidor MCP conectado de forma segura a BigQuery y limitar sus permisos/consultas.
- **Skill:** no hace falta crear un skill de Codex para resolver el pipeline. El bonus pide un `SKILL.md` como capa semántica (glosario, métricas, tablas y cinco preguntas); es un artefacto de documentación de dominio y puede añadirse al final si el núcleo está estable.
- dbt tampoco es obligatorio: SQL versionado y consultas de control bastan para la primera entrega; dbt puede aportar tests si ya está disponible y no retrasa el flujo.

### Qué se puede verificar y qué acceso hace falta

Podemos verificar la paginación y los reintentos observando respuestas y logs, comparar filas extraídas con `meta.total`/conteos de ejecución, validar unicidad y relaciones con SQL, comprobar idempotencia corriendo una segunda ejecución, y estimar/medir bytes procesados de consultas en BigQuery. Para probar alertas de error, bastan fallos controlados en configuración local sin provocar carga innecesaria a la API.

La validación real en GCP requiere identidad y permisos activos en el proyecto, cuotas disponibles y acceso a los recursos creados. La validación del límite de Looker Studio requiere además su conector real: un dry run de BigQuery estima SQL equivalente, pero no demuestra por sí solo los bytes de cada interacción emitida por Looker. Se debe medir una carga representativa desde la consola/historial de BigQuery y dejar evidencia. Para comprobar el acceso compartido se necesita la cuenta destinataria o confirmación de que aceptó el acceso.

## Decisiones del modelo y evolución prevista

1. **Prima y conversión a USD.** Convertir `prima` con `factor_usd` usando moneda y fecha de referencia. Como la póliza contiene fecha de emisión y la tabla de cambio contiene fecha, se toma el tipo de cambio de la fecha de emisión o la última fecha válida anterior; no se utiliza una tasa futura.
2. **Costo de siniestros.** El glosario define costo como monto efectivamente pagado. La API expone `status` y `amount`, pero no una fecha de pago. Para una primera versión, incluir solo `PAGADO`, convertir el monto con `factor_usd` de la fecha de ocurrencia y describirlo como aproximación. No sumar `EN_ANALISIS` ni `RECHAZADO` al costo pagado.
3. **Atribución temporal.** Las dos queries de análisis agrupan por cohorte de emisión: prima y siniestros asociados al mes de emisión de cada póliza. El costo mantiene FX de ocurrencia. La selección de cohortes no recorta sus siniestros al rango de emisión; se aplica un corte de ocurrencia explícito. Gold aplica la misma definición de cohorte. Las cohortes abiertas requieren advertir menor maduración y no representan prima devengada ni margen neto.
4. **Anulados, borrados y cambios.** Usar la última prima de la póliza no borrada para gold, según el modelo documentado. Las emisiones históricas de I se conservan en el historial sin reescribirse por U/D. Staging resuelve el último evento por `updated_at`, marca las bajas D y expone estados no borrados; gold excluye las pólizas cuyo último estado es ANULADA. Vencida no significa anulada. Conservar todos los eventos crudos para auditoría.
5. **Incrementalidad futura de extracción.** Pólizas admiten `updated_since` y cursor; se prevé una ventana solapada para tolerar retrasos y deduplicar por `poliza_id` y `updated_at`. Siniestros no ofrecen filtro de cambios: obtener snapshot completo y hacer `MERGE` por `claim_id` (o recarga reemplazable de staging). Los catálogos son pequeños y se reemplazan completos.

La moneda faltante se infiere únicamente desde una moneda histórica única de póliza, preservando fuente y procedencia. Negativos y casos monetarios no resolubles se excluyen de importes y conteos analíticos. Las limitaciones de prima/costo y cobertura permanecen visibles en los resultados.

## Arquitectura propuesta

`API → extractor Python → raw local validado → (etapa posterior) GCS → tablas raw en BigQuery → modelo analítico en BigQuery → Looker Studio`

- Implementar un extractor Python con configuración por variables de entorno. La credencial de API se obtiene de Secret Manager en GCP o de una variable local ignorada por Git; nunca incluir el token en código, logs, README ni historial.
- Las primeras versiones y corridas de validación se conservan localmente en `.local_data/`, ignorada por Git. No crear todavía el bucket ni mover allí datos hasta cerrar la validación local.
- BigQuery se prepara por separado para recibir cargas batch desde los archivos locales validados; cuando se habilite GCS, mantenerlo como copia durable/reprocesable y cargar desde allí. Guardar fecha de extracción y recurso en ruta/metadata. Definir retención razonable de raw.
- Ejecutar el mismo contenedor como Cloud Run Job y dispararlo diariamente con Cloud Scheduler. El Job debe ser idempotente y dejar logs claros; configurar service account con permisos mínimos para Secret Manager, GCS y BigQuery.
- Datasets de datos separados `assist365_raw`, `assist365_staging` y `assist365_mart`, más `assist365_control` para operación y QA en `us-central1` (Iowa), elegida por costo de almacenamiento regional y por alinear BigQuery/GCS. Staging/mart están materializadas después de perfilar raw; el diseño diario cloud sigue pendiente.
- En raw, conservar cada recurso en su propia tabla con payload original, eventos CDC y snapshots con metadatos técnicos; ubicar tablas de ejecuciones, errores, conciliaciones y watermarks en `assist365_control` para que cada carga diaria deje evidencia consultable.
- Guardar SQL del modelo en el repositorio, evitando lógica escondida solo en la consola.

## Secuencia de trabajo

Este documento es un mapa inicial, no un contrato inmutable para implementar todas las fases por adelantado. Al cerrar cada fase, revisar evidencia, consumo, anomalías y riesgos; actualizar README y esta planificación; y replanificar la fase siguiente según lo aprendido. No cerrar el diseño de staging/mart antes de perfilar raw.

### Fase 1 — Reconocimiento y contrato de datos

1. Revisar el repositorio y confirmar herramientas disponibles, proyecto GCP, la región elegida `us-central1` y permisos. No volcar credenciales en comandos registrados.
2. Hacer llamadas pequeñas a cada endpoint para confirmar estructura real, headers, páginas, errores y tamaños. Verificar los 12 productos y observar campos opcionales o nulos.
3. Medir/estimar el volumen por endpoint y comprobar el comportamiento del cursor de pólizas y del `offset` fijo de siniestros.
4. Escribir un contrato de extracción: esquema raw flexible, timestamp UTC de ingesta, endpoint, página/cursor, número de filas, identificador de lote y checksum si es práctico.
5. Registrar cualquier diferencia entre documentación y datos reales en una lista de anomalías.
6. Anotar en README el inventario de accesos/cuotas, estimación inicial de consumo y contrato confirmado; actualizarlo con hallazgos en vez de esperar al cierre. Abrir un registro de anomalías con evidencia, hipótesis, impacto y estado.

### Fase 2 — Extracción confiable

1. Crear cliente HTTP con timeout, `Accept-Encoding: gzip`, autenticación fuera del código y límite de concurrencia bajo (inicialmente secuencial).
2. Implementar reintentos con backoff exponencial y jitter para `429` y errores `5xx`; respetar `Retry-After` cuando venga. No reintentar errores `4xx` permanentes. Limitar intentos y fallar con contexto útil.
3. Para `/polizas`, recorrer cursores hasta `has_more=false`; persistir cada página antes de pedir la siguiente. En modo inicial recorrer desde el comienzo; en incremental usar `updated_since` con solapamiento y deduplicación.
4. Para `/siniestros`, avanzar offsets en pasos de 500 hasta alcanzar `meta.total`; validar que el total y los offsets concuerden y tolerar páginas vacías solo si la respuesta lo justifica.
5. Para `/catalogos`, descargar todos los tipos documentados (productos, agencias, tipo de cambio) y validar que la respuesta no esté truncada.
6. Escribir páginas como NDJSON en almacenamiento durable. Si el proceso cae, conservar páginas completadas y poder reanudar o volver a ejecutar sin duplicar resultados finales.
7. Producir resumen por ejecución: inicio/fin, filas por endpoint, páginas, reintentos, fallas, watermark, run/batch IDs y conciliación contra totales de API. Nunca registrar el header de autorización.
8. Guardar errores por página y, cuando pueda identificarse, por registro; persistir la página cruda antes de parsearla para recuperar sin repetir la llamada.
9. Documentar en README la estrategia de reintentos, paginación, checkpoint, conciliación, errores observados, volumen y límites de consumo.

### Fase 3 — Carga raw en BigQuery (completada)

1. Carga ejecutada el 29/09/2026 (Argentina), en `a365-de-ignacio.assist365_raw`, región `us-central1`, desde los ocho archivos locales verificados del snapshot `smoke-20260929`.
2. Los cinco recursos se conservan en sus tablas `polizas`, `siniestros`, `agencias`, `productos` y `tipo_cambio`, con payload JSON completo y metadata de recurso, run/lote, página, posición, timestamp, hash y origen: 1.003.461 eventos de póliza, 138.962 siniestros, 300 agencias, 12 productos y 5.124 tasas; total 1.147.859 filas.
3. Tablas en `assist365_control`: una ejecución, 418 errores (414 valores no finitos y cuatro transportes resueltos), diez conciliaciones locales y 29 conciliaciones remotas. No se descartaron filas.
4. Los 29 controles remotos dieron `PASS`: filas por recurso y página, inventario de 1.285 páginas, unicidad técnica, metadata, conservación de 414 marcadores JSON y conteos de controles. Las tablas y sus campos conservan los mínimos de descripción.
5. Cargador corregido: gzip autodetectado, validación previa de todos los archivos, job ID por checksum/destino/esquema y reutilización de jobs exitosos. Los recibos y la evidencia remota permanecen en `.local_data/assist365/bigquery-load/smoke-20260929/`.
6. Consumo de conciliación: dry run previo, límite de 1 GiB, 403.548.981 bytes procesados y 403.701.760 facturados. Los registros raw ocupaban 427.644.793 bytes lógicos antes de la separación. Job `assist365_raw_verify_47c8461bc9c541d9ac88ec443120fd3d`.
7. Al cierre de la fase raw, staging/mart todavía estaban vacíos y el modelo ABM sin ejecutar. Las fases posteriores materializaron silver y dashboard_diario, como se documenta más abajo. `assist365_control.watermarks` y `assist365_control.snapshot_diffs` permanecen sin filas. GCS y retención operativa quedan para la etapa posterior, sin necesidad de bucket para esta carga local batch.

### Diseño futuro de cargas incrementales diarias (Fase 7)

La primera versión usa la captura completa existente y ya materializa el estado ABM por póliza a partir de `I/U/D`. Antes de cerrar el dashboard no se procesarán deltas diarios ni se moverán watermarks. La transformación incremental raw→silver ya está implementada; en Fase 7 quedarán extracción delta de API y despliegue diario; cada corrida usará un `run_id` nuevo y el reproceso de un mismo lote será idempotente.
- **Pólizas:** iniciar `updated_since` con el último watermark confirmado menos una ventana de solapamiento configurable; recorrer todos los cursores. Preservar cada evento, incluidas operaciones `D`; deduplicar relecturas por clave de evento (clave de negocio, `updated_at`, `op` y hash del payload), sin perder dos eventos distintos con timestamp compartido. Avanzar watermark solo cuando todas las páginas y controles concluyan. Validar el orden/semántica de `updated_since` con datos antes de automatizar.
- **Siniestros:** al no existir filtro de cambios documentado, solo una extracción completa permite detectar ABM diarios. Comparar snapshot conciliado con el anterior por `claim_id` y hash de payload para clasificar alta/cambio/sin cambio. Una fila ausente no se borra de raw ni se marca como baja definitiva sin política confirmada; conservarla como candidata y revisar consistencia del snapshot.
- **Catálogos:** capturar snapshot diario/reemplazable y comparar clave/hash para altas, cambios y ausencias; preservar snapshots anteriores para auditoría. Revisar si el costo/volumen observado permite reducir frecuencia.
- **Puerta de éxito:** no adelantar watermark ni publicar estado actual cuando falten páginas, existan cursores/offsets repetidos, no coincida el total del proveedor, haya claves duplicadas incompatibles o fallen cargas/conciliaciones. Reintentar desde archivos raw locales, no desde la API, siempre que los archivos estén íntegros.
- **Reporte diario:** por recurso y `run_id`, informar filas/páginas, nuevos/modificados/borrados explícitos, candidatos ausentes, duplicados, errores, hashes/bytes, watermark anterior/nuevo y resultado de cada control. Las diferencias sin explicación quedan en ledger y bloquean la marca de ejecución completa.

### Recomendación al proveedor: cambios en siniestros

En el contrato y las muestras revisadas de `GET /siniestros` aparecen `occurred_at` y `reported_at`, pero no `created_at`, `updated_at`, operación de cambio ni filtro incremental. `reported_at` es fecha del reporte del evento; no se debe reinterpretar como fecha técnica de creación o actualización del registro. La extracción completa puede revelar campos adicionales; registrar la ausencia como hallazgo confirmado solo después de revisar todas las páginas.

Solicitar al proveedor `created_at` y `updated_at` en UTC, filtro `updated_since` con cursor estable y snapshot consistente, operación `I/U/D` o tombstone explícito, y `paid_at` para distinguir ocurrencia, reporte, actualización y pago. `created_at` sola no detecta modificaciones posteriores; `updated_at` y un filtro de cambios son los necesarios para evitar el snapshot completo diario. Hasta que estén disponibles, comparar snapshots completos por `claim_id`/hash; detectar altas y cambios, y dejar ausencias como candidatas a baja. El volumen observado implica unas 278 páginas por snapshot. Confirmar con el proveedor si existen campos o filtros adicionales antes de fijar esta estrategia como permanente.

### Silver — cerrada antes de Fase 4

Seis tablas físicas de negocio: `polizas`, `polizas_activas`, `siniestros`, `agencias`, `productos` y `tipo_cambio`. Se retiraron las vistas y tablas redundantes anteriores. Los metadatos de carga permanecen en raw/control, y los campos de silver tienen descripciones precisas de al menos 40 caracteres.

La historia conserva todos los eventos I/U/D; la tabla de último estado excluye solo D y usa la última prima. Los siniestros conservan todos sus estados, con deduplicación de payloads idénticos. La transformación raw→silver admite deltas de pólizas, MERGE de snapshots de claims y refresco de catálogos completos, con protección contra capturas antiguas. Los checkpoints de transformación se confirman junto con las tablas en una transacción; no se adelantan watermarks de API.

Validación: 13 conciliaciones PASS, 16 comprobaciones funcionales con tablas temporales y reejecución real con cero cambios de negocio. La ejecución normal omite lotes idénticos confirmados según checksums y versión SQL. La extracción API incremental y el despliegue programado siguen siendo trabajo separado.

### Fase 4 — Gold construida y conciliada

Implementación en [modelo gold](README.md#capa-gold): `assist365_mart.dashboard_diario`, tabla física mensual por cohorte de emisión, país, nombre de plan, premium y canales de origen/agencia. Conserva campos temporales en inglés, sin IDs. Publicación actual: 45.875 filas, 15,21 MB, 37 campos, 24 conciliaciones PASS y 21 pruebas funcionales PASS. Usa `polizas_activas`; excluye D/ANULADA/ausentes y sus siniestros, con ocurrencia hasta el corte del 29/09/2026. La conversión de costo mantiene FX de ocurrencia. La moneda inferida válida se incluye; negativos/no resolubles quedan fuera de importes y conteos analíticos. Se conserva el historial y las exclusiones de población en staging/control. El tablero está creado; su validación de acceso y consumo queda pendiente.

1. Consumir exclusivamente las tablas físicas de silver, sin volver a parsear raw.
2. Definir las métricas con última prima por póliza no borrada y cuyo último estado no sea ANULADA. Resolver primero el último evento y después excluir: una U ANULADA excluye la póliza completa, sin recuperar su I ni una U anterior. VENCIDA permanece. Diferenciar foto de cartera de prima histórica efectivamente emitida/cobrada.
3. Conservar todos los siniestros en staging; gold usa solo la población común de pólizas no D/no ANULADA y sus siniestros hasta el corte. La frecuencia usa PAGADO elegibles/pólizas de la cohorte. Las referencias borradas/huérfanas se registran en control, fuera del agregado.
4. Definir fecha de conversión USD, tasa previa disponible y señales de cobertura FX sin imputar monedas/importes inválidos.
5. Materializar un agregado de consumo acotado en mart. Medir tamaño y bytes de las consultas que alimentarán cada carga de Looker, con objetivo de 50 MB o menos.
6. Conciliar sumas y conteos antes/después de joins y agregaciones; registrar controles en `assist365_control`.
7. Construir el dashboard de una página y medir su consumo real antes de compartirlo.

La construcción fue ejecutada. El refresco inicial reconstruye el agregado desde silver y publica transaccionalmente; se medirá la necesidad de optimización incremental más adelante.

### Fase 5 — Dos queries de análisis

[Análisis](scripts/parte_05_analisis/README.md): siniestralidad por país/plan y por país/canal de agencia. Cada SQL devuelve directamente una agrupación mensual, cantidades de pólizas/siniestros/PAGADO, prima USD y costo PAGADO USD. Fechas editables al inicio; no requiere ejecutor ni genera archivos.

Se usa `polizas_activas`, flags monetarios existentes, última prima y cotización previa. Las pólizas D y última ANULADA se excluyen junto con sus siniestros para usar una población común. Los siniestros se agregan por póliza y se unen con LEFT JOIN a la cohorte; se conserva una fila por póliza, incluidas las que no tienen siniestros. `mes_cohorte` es el mes de emisión. Siniestros posteriores se incluyen hasta `fecha_corte`; las cohortes recientes pueden seguir acumulando costo. Gold aplica el mismo alcance de población y corte.

### Fase 6 — Tablero con límite de 50 MB

Tablero creado: [abrir Looker Studio](https://datastudio.google.com/reporting/be1247ad-58d9-4ed1-ba70-ca4830505fb3/page/0eCAG). La [documentación del tablero](scripts/parte_06_tablero/README.md) describe gráficos, fórmulas, formato e interpretación. Verificado: apertura sin sesión, período abril–junio de 2026 y ratios visibles de países/planes. Pendientes: acceso del destinatario, interacciones de filtros y bytes por carga real.

1. Conectar Looker Studio a una tabla agregada del mart y no a los JSON/raw ni a hechos completos.
2. Preagregar a grano mensual por cohorte, país y plan, según los filtros/series requeridos. Incluir dimensiones de fecha para permitir filtro de trimestre sin escanear todo.
3. Particionar por fecha y clusterizar país/plan. Configurar rango de fechas predeterminado acotado al trimestre actual o más reciente.
4. Diseñar una sola página con cuatro visualizaciones como máximo: (a) KPI/serie de siniestralidad del trimestre; (b) comparación por país; (c) comparación por plan; (d) frecuencia y monto promedio para diagnosticar el impulsor. Incluir filtros claros de trimestre, país y plan si el presupuesto de bytes lo permite.
5. Medir en BigQuery el tamaño estimado/procesado de las consultas representativas con el mismo filtro temporal; documentar los bytes por carga y margen bajo 50 MB. No afirmar un límite que no se haya medido. Revisar el comportamiento de consultas que emite el conector de Looker Studio y el efecto de filtros/componentes.
6. Compartir tablero con la dirección indicada en el ejercicio y comprobar acceso desde la cuenta correspondiente.
7. Incorporar estado de frescura/calidad (último run exitoso y filas en cuarentena) y revisar su comportamiento tras una carga fallida.
8. Incorporar a README el diseño, fuente agregada, consultas/bytes verificados, estado de calidad y límite del método de medición.

#### Registro interno de validación del tablero — 30/09/2026

- Apertura del enlace con Chrome sin sesión: acceso correcto, período inicial 01/04/2026–30/06/2026 y un selector de fecha.
- Captura actualizada en `scripts/parte_06_tablero/assets/dashboard-preview.png`; cuatro gráficos completos y filtros de país, producto y canal de agencia.
- Los ratios visibles de los seis países y nueve planes individuales coinciden con las queries de referencia a dos decimales. Los puntos de frecuencia/severidad son visualmente consistentes; no se validaron tooltips ni todas las interacciones.
- Pendientes: verificar acceso de la cuenta destinataria, contrastar filtros y medir bytes de las consultas reales del conector por carga.
- Configuración de mantenimiento: período fijo 01/04/2026–30/06/2026 en el control; gráficos con rango automático. Para comprobar un cambio, abrir una ventana privada. Si cambia el esquema de gold, actualizar campos de la fuente; en SQL personalizado incluir las nuevas columnas en el SELECT.
- Criterio de documentación: los README describen el producto entregado, ejecución, decisiones y límites para el evaluador. Ediciones de interfaz, comprobaciones internas y seguimiento se registran únicamente aquí.

### Fase 7 — ABM, cargas incrementales y operación diaria

La implementación de esta fase se hará después de tener el dashboard de primera versión. Además del diseño de watermark/diffs descrito arriba, incluye la operación automatizada:

1. Definir comportamiento exacto de `updated_since`, solapamiento y clave de evento con evidencia del proveedor; reutilizar el ABM ya implementado para la carga completa.
2. Aplicar lotes delta con `MERGE` idempotente sobre el estado actual; registrar altas, modificaciones, tombstones y ausencias candidatas. No convertir ausencia de claim en baja sin snapshot completo y política confirmada.
3. Avanzar watermarks solo con páginas, carga, conciliaciones y controles aprobados; preservar eventos históricos y hacer reprocesos idempotentes.
4. Empaquetar extractor y SQL/modelado en una imagen reproducible; desplegar Cloud Run Job y Cloud Scheduler solo cuando se apruebe la conexión y el costo estimado.
5. Aplicar mínimos permisos mediante service account y Secret Manager; evitar credenciales de usuario permanentes.
6. Definir estados/alertas, thresholds de volumen, errores, divergencias y cuarentena; prevenir la publicación de marts parciales.
7. Probar dos corridas consecutivas y reproceso desde raw; demostrar no duplicación, cambios detectados, watermarks correctos y registros de error resolubles.
8. Actualizar README con comandos, calendario, permisos, consumo, monitoreo, ABM e idempotencia demostrada.

### Fase 8 — Documentación y entrega

Revisar y completar README con arquitectura, ejecución local, configuración segura, datasets/tablas, granos, decisiones de carga, incrementalidad, definiciones/supuestos, anomalías, análisis, bytes del tablero, despliegue y limitaciones. La información se fue agregando fase a fase; esta etapa solo comprueba consistencia, enlaces y que no haya secretos.

Incluir únicamente evidencia no sensible sobre uso de IA (prompts útiles, contexto creado o resumen del flujo); revisar archivos y commits para no filtrar tokens. Dejar comandos claros para ejecutar el entorno y hacer un cambio en vivo durante la revisión.

## Priorización para 6–8 horas

1. **Imprescindible:** contrato/decisiones, extracción paginada y reintentos, carga raw batch, modelo de hechos con granos declarados, SQL de análisis, README.
2. **Entrega completa si el acceso lo permite:** Cloud Run Job + Scheduler, tabla agregada y tablero de una página con medición de bytes.
3. **Si queda tiempo:** ampliar controles/alertas automatizados, CI, capa semántica `SKILL.md` y preguntas de negocio por MCP, video.

No sacrificar la confiabilidad de la extracción ni la trazabilidad de definiciones por intentar completar todos los bonus. Anotar claramente qué quedó ejecutado y qué quedó diseñado.

## Riesgos a vigilar

- Cuota/rate limit durante la descarga inicial: secuencialidad, backoff, persistencia por página y reanudación.
- Respuestas transitorias `500` y cursores inválidos/repetidos: detectar no progreso para evitar loops infinitos.
- Semántica insuficiente de fecha de pago y cohortes: mostrarlo como limitación en ratios y decisiones.
- FX faltante, duplicado o ambiguo: no multiplicar hechos y reportar filas no convertidas.
- CDC y deletes: raw inmutable y lógica determinista de estado actual.
- Siniestros sin incrementalidad: costo/tiempo de snapshot completo y deduplicación estable.
- Presupuesto de escaneo del tablero: preagregación, partición y filtros con medición verificable.
- Credenciales incluidas accidentalmente en archivos, logs o Git: Secret Manager/local env ignorado y revisión antes de publicar.

La migración final de Fase 3 se realizó exclusivamente desde BigQuery con `003_split_raw_resources.sql`: cinco tablas raw, cinco tablas operativas en `assist365_control`, igualdad de filas y contenido verificada y retirada de las tablas anteriores. QA futuro también va a control; raw/staging/mart contienen exclusivamente datos.


## Cierre vigente de silver

El layout anterior se retiró tras conciliar: quedan únicamente `polizas`, `polizas_activas`, `siniestros`, `agencias`, `productos` y `tipo_cambio`. Los SQL anteriores están archivados y no se ejecutan. Campos de carga y señales operativas permanecen en raw/control.

La transformación incremental raw→silver fue aplicada y verificada con 13 controles PASS. La reejecución real tuvo cero cambios en las seis tablas y la ejecución normal omitió el lote idéntico confirmado. Las 16 comprobaciones funcionales verificaron eventos fuera de orden, último importe, D, reactivación posterior, snapshots y rollback. La Fase 4 se ejecutó posteriormente y creó dashboard_diario en mart, documentado en el README de gold.

## Cierre de revisión

Se entregan únicamente dos queries de análisis, sin exportador, CSV ni tablas adicionales. Los resultados por cohorte mensual de emisión permiten comparar países/planes y países/canales. Las tablas productivas y el flujo de ingesta se mantuvieron.

La documentación incorpora decisiones finales y pasos reproducibles. La revisión no da por terminada la entrega: quedan la validación de Looker y su límite por carga, despliegue diario, portabilidad y cierre de seguridad. Se detectaron 4.145 ocurrencias posteriores a la extracción; se documentaron sin alterar fechas. No se consultó la API.

Gold fue reconstruida y publicada por cohortes mensuales con corte 29/09/2026. Tamaño real: 15.212.749 bytes. Incluye nombre de plan, tipo de producto y canal de agencia; conserva una fila por póliza antes de agregar. Las pruebas verificaron el caso enero/febrero y primas iguales sin perder importes. Prima total se conserva; los costos cambian al excluir población no elegible y ocurrencias futuras. El primer intento alcanzó la cuota de modificaciones de metadata antes de publicar; se corrigió agrupando la actualización de descripciones y la publicación posterior terminó SUCCESS.

La gold publicada concilió bidireccionalmente con las dos queries de análisis para abril–junio de 2026: mismos conteos e importes, frecuencia y severidad por país/plan y país/canal con corte 29/09/2026. Las dos comprobaciones terminaron PASS.

## Revisión interna de README — 30/09/2026

Se revisaron los 12 README con criterio de entrega: propósito, grano, ejecución, decisiones y límites. El README raíz enumera los siete puntos del ejercicio y cuatro bonus, sin declarar terminado el límite de Looker ni desplegada la orquestación. Prioridad: captura trazable, reglas/calidad, métricas verificadas y tablero; despliegue diario y bonus no esenciales quedaron fuera.

Detalles internos retirados de los README: evolución de layouts, recibo heredado de agencias y corrección del identificador de carga; resultados antiguos por calendario y referencias a versiones previas de las queries; edición de controles y seguimiento de acceso al tablero. Se conserva en documentación el uso de IDs deterministas y su límite por retención del historial, porque afecta la recuperación. La migración desde records y la retirada de vistas ya se aplicaron: no repetirlas sobre una reconstrucción nueva.

Evidencia del análisis trimestral: job `bqjob_r3b81c3cabd7f8a49_000001a0f37d8da8_1`; ambos SQL coinciden en las cinco medidas base por trimestre. Los README analíticos conservan cifras e interpretación, sin el diario de ejecución.

Pendientes de entrega: medir escaneo real por carga y filtros en Looker, verificar acceso del destinatario, cerrar gestión de secretos y revisión antes de compartir; desplegar operación diaria y parametrizar proyecto. MCP/capa semántica, CI y video no implementados. Las pruebas de datos sí están implementadas en SQL nativo.

Verificación de la revisión: enlaces y anclas locales de los 12 README válidos; opciones documentadas contrastadas con CLI --help sin llamadas a la API; diff sin errores de formato. Se modificó documentación, sin cambios en scripts, queries ni tablas durante esta revisión.

## Consolidación final de documentación — 9 README

Estructura acordada: README central, siete README de las partes y `scripts/bonus/README.md`. Gold y anomalías integradas como apartados del central; mapa SQL y ejecución gold integrados en Parte 3. Eliminados los cuatro README secundarios. Eliminado por solicitud explícita el directorio `scripts/parte_03_modelo_bigquery/sql/archive/`, que no participaba del ejecutor. Se conservan los scripts operativos y migraciones fuera de ese directorio.

Archivos históricos retirados: `scripts/parte_03_modelo_bigquery/sql/archive/004_quality_check_summary.sql`, `scripts/parte_03_modelo_bigquery/sql/archive/005_staging_facts_dimensions.sql`, `scripts/parte_03_modelo_bigquery/sql/archive/001_staging_views.sql`, `scripts/parte_03_modelo_bigquery/sql/archive/002_dashboard_mart.sql`, `scripts/parte_03_modelo_bigquery/sql/archive/README.md`, `scripts/parte_03_modelo_bigquery/sql/archive/003_model_record_issues.sql`, `scripts/parte_03_modelo_bigquery/sql/archive/006_business_staging.sql`.

Detalle de referencia conservado para seguimiento: gold prima USD 94.227.816,49 y costo PAGADO USD 36.317.864,64; 129.664 eventos dentro de alcance y 8.469 fuera (4.025 D/ausente, 438 ANULADA, 4.006 futuros por prioridad). Ledger con 3.029 motivos, no eventos: 1.794 cobertura, 824 negativos, 411 moneda. Inferidos monetariamente elegibles staging 410, incluidos 312 PAGADO por USD 114.823,19; 675 PAGADO negativos con moneda fuente conocida suman USD -244.862,47, sin reintegro validado.

## Configuración API versionada — decisión final

Secret Manager cancelado por solicitud del usuario. El intento de habilitación fue rechazado por IAM; no se creó ni migró ningún secreto. Se retiraron el lector, el configurador y sus pruebas. Se retiró también el archivo local de token generado durante la prueba.

El usuario autorizó explícitamente incluir el token del challenge en GitHub para ejecución desde un clon. La configuración final es `config/assist365.json`; lectura por defecto desde la raíz del repositorio, con override de `ASSIST365_API_TOKEN` o `ASSIST365_CONFIG_FILE`. EJERCICIO.md sigue ignorado y no es dependencia runtime. No se copian tokens OAuth, claves de cuentas de servicio ni credenciales de Google Cloud. Cargas BigQuery usan gcloud.

Siete pruebas unitarias verifican selección y errores de configuración sin red. La lectura del token se verificó localmente sin solicitudes a la API. La publicación en GitHub está autorizada para esta configuración y su integración.

## Migración del almacenamiento a GCS — 30/09/2026

- Bucket `gs://a365-de-ignacio-assist365-data`, STANDARD, `us-central1`, acceso uniforme y acceso público bloqueado.
- Snapshot existente copiado sin API: 1.316 archivos verificados por tamaño/MD5 y dos manifiestos rebajados a rutas GCS, conservando fingerprints, recibos y confirmación de migración raw.
- Extracción guarda páginas/checkpoints/errores en GCS; preparación publica NDJSON/manifiestos; raw carga URI GCS; staging lee el manifiesto cloud. Evidencias nuevas silver/gold también quedan en el bucket.
- Se conserva soporte explícito de rutas locales para pruebas/migraciones, pero el almacenamiento predeterminado es GCS. Preparación usa temporales efímeros y los elimina; no necesita snapshots locales.
- 14 pruebas offline aprobadas (7 almacenamiento y 7 configuración API). Validación real de los cinco recursos desde GCS aprobada: 1.147.859 filas idénticas a raw en tablas temporales de control, eliminadas al terminar. Cero filas agregadas a raw productiva y cero llamadas API. Repetición del cargador cloud omitió el snapshot migrado; 29 comprobaciones raw existentes aprobadas, con evidencia en GCS.
- Preparación real GCS→NDJSON GCS probada con productos: 12 filas y checksum comprimido idéntico al artefacto de referencia.
- Staging ejecutado desde el manifiesto GCS: job `assist365_silver_b74b6d23eb7346afb852c3fcb9c0e228`, SUCCESS; mismos conteos en las seis tablas y evidencia cloud en `silver/smoke-20260929/`.

## Revisión integral del README central — 30/09/2026

- Contrastado contra los siete puntos y cuatro bonus del ejercicio, código, README por capa y evidencias de la migración GCS. Sin llamadas a API ni nuevas cargas/verificaciones BigQuery.
- Central actualizado con inventario y volúmenes de capas, operación/segunda corrida, estado GCS, requisitos de acceso, métricas e insights y tabla de pendientes con criterios de cierre.
- Aclarados límites: proyecto fijo; clon no concede IAM; reproducción sobre entorno existente no es restauración automática sobre tablas borradas; raw depende del historial de jobs para reintentos; extracción sin updated_since.
- Prioridades de entrega: medir escaneo real del tablero y confirmar acceso del evaluador. Operación diaria diseñada sin despliegue. Premium disponible como dimensión, sin afirmar un insight adicional ya validado.
- Se mantienen nueve README y las decisiones comerciales/anomalías; no se sumaron archivos de documentación.

## Medición real de Data Studio — 30/09/2026

- Chrome aislado, sin sesión; apertura con fechas 01/04/2026–30/06/2026. Ventana inicial 21:08:13.362–21:09:00 UTC.
- Ocho jobs del reporte `be1247ad-58d9-4ed1-ba70-ca4830505fb3`, identificados por etiquetas oficiales requestor/report_id; cuatro gráficos, tres filtros y Otros. Cero aciertos de caché BigQuery y cero errores.
- Total procesado: 1.405.616 bytes = 1,405616 MB; total facturado: 83.886.080 bytes por mínimos de facturación. Comparar el límite de escaneo de 50 MB contra procesados, no facturados.
- SQL reproducible en parte_06_tablero/sql/001_medir_consumo.sql; evidencia con IDs, queries y metadatos en parte_06_tablero/evidence/consumo_20260930.json.
- Sin cambios al dashboard publicado ni consultas a la API; filtros probados solo en la sesión aislada. No se ejecutaron nuevas cargas ni reglas de conciliación.
- Interacciones por separado y sin caché BigQuery: CL. 7 jobs/1.440.024 bytes; ONLINE, 7 jobs/1.582.008 bytes; Equipaje Protegido, 6 jobs/1.305.208 bytes. Todas exitosas. Máximo observado 1,582008 MB (3,164016% de 50 MB).


## Ensayo de entrevista desde clon limpio — 30/09/2026

- Detectados y corregidos: import de emit en cliente API; import gzip del verificador; manejo de error_file ausente; preparación repetida que reemplazaba recibos; omisión de raw migrada sin comprobar destinos; extracción completa que reescribía el checkpoint. Perfil opcional actualizado para GCS.
- Nuevo scripts/run_pipeline.py: preparación → carga/verificación raw → staging → gold; --setup opcional; corte explícito; falla ante primer error y escribe reporte cloud. Sin API.
- Commit probado 5f6b5d7 desde /tmp/assist365-interview-final, sin .local_data ni EJERCICIO.md: 20 tests offline y 11 CLI --help PASS. Extractor reejecutado con cliente API bloqueado: checkpoint completo, cero solicitudes.
- Entorno creado/reutilizado por CLI; pipeline completo SUCCESS entre 21:46:39 y 21:50:46 UTC. Raw verificó conteos, sin nuevos inserts; silver omitió lote idéntico; gold recompuesta, 45.875 filas/15.212.749 bytes, mismos importes y fingerprint 260909553606909619339. Reporte cloud en pipeline/smoke-20260929/40041073e6d041b486527e0f7dd323f0/report.json.
- SQL incrementales, gold funcional, flags y frontera UTC PASS; análisis país/plan devolvió 216 filas y país/canal 72. Medición Looker reconsultada: PASS/1.405.616 bytes. Reporte cloud pipeline/smoke-20260929/interview-20260930/sql_checks.json.
- Se mantienen 9 README, enlaces locales revisados. Documentación de entrega distingue reproducción del entorno existente de restauración/instalación en otro proyecto. IAM del evaluador y automatización diaria siguen pendientes; API nueva no ejecutada por prohibición vigente.


## Auditoría del objetivo contra EJERCICIO.md — cierre de alcance

La continuación anterior produjo progreso verificable: correcciones publicadas, ensayo real desde clon y evidencia SUCCESS. El ejercicio permite diseño documentado en lugar de despliegue de orquestación; los cuatro bonus son opcionales. No se cambia la prohibición de consultas nuevas a la API.

| Requisito | Evidencia actual | Dictamen |
|---|---|---|
| 1. Extracción completa, paginación y errores | Captura smoke-20260929 en GCS, 1.285 páginas/1.147.859 registros; cliente con 429/5xx, backoff y checkpoints; fixture CLI cursor/offset PASS | Implementado; no se revalida disponibilidad de API en vivo |
| 2. Raw y elección de método | Cinco tablas raw; manifiestos/checksums GCS; verificación real PASS y explicación de bq load en Parte 2 | Verificado |
| 3. Modelo dimensional y granos | Seis tablas staging, catálogo y FX; grano explícito en Parte 3; SQL incremental/flags PASS | Verificado |
| 4. Orquestación o diseño README, segunda corrida | CLI única ejecutada; Parte 4 con calendario, identidades, bloqueo, etapas, alertas y segunda corrida | Diseño entregado bajo alternativa explícita; no desplegado |
| 5. Siniestralidad USD e insight | Dos queries staging ejecutadas: 216/72 filas; resultados trimestrales en Parte 5 | Verificado |
| 6. Una página, preguntas, BigQuery, <50 MB | Tablero/captura, cuatro gráficos; ocho jobs etiquetados reales, 1.405.616 bytes; medición SQL reconsultada PASS | Verificado para configuración/captura entregadas |
| 7. Arquitectura, decisiones, anomalías y mejoras | Nueve README, guía y evidencia; enlaces locales válidos | Verificado |
| Explicar uso de IA | Parte 7: contexto, instrucciones resumidas y forma de contrastar resultados | Documentado sin historial sensible |
| Entrega Git | main publicado, 1012588 antes de este cierre | Publicado; publicar también cambios de auditoría |
| Entrega dashboard compartido | Enlace público ya abierto sin sesión y captura/medición reales | Acceso público comprobado; identidad destinataria no informada |
| Entrega GCP consultable por empresa | Tablas/jobs/queries ejecutadas en proyecto asignado | Activo; falta comprobar IAM de la identidad evaluadora |
| Bonus | Tests implementados; MCP/CI/video ausentes y declarados | Fuera del alcance priorizado |

El despliegue diario, restauración en otro proyecto y delta/API son mejoras pendientes, no capacidades anunciadas. Para cerrar la validación de acceso del evaluador se pidió su identidad Google; no se conceden accesos ni se contacta a terceros sin una instrucción correspondiente. No se marca el objetivo completo mientras ese acceso permanezca sin verificar.


## Verificación de acceso y auditoría final — 30/09/2026

- El contacto de empresa figura en EJERCICIO.md. Consulta real get-iam-policy: roles/owner sin condición, etag BwZclg73nzY=. Los cuatro datasets tienen projectOwners/OWNER; bucket tiene projectOwner en legacyBucketOwner y legacyObjectOwner. No se cambió IAM ni se impersonó al contacto. Evidencia en docs/evidence/acceso_20260930.json. La consulta de identidad ya no es necesaria para esa cuenta.
- Superado el pendiente de acceso señalado por la auditoría anterior. La comprobación acredita permisos concedidos, no una sesión interactiva del destinatario. Otras identidades deberán revisar sus permisos.
- Requisitos principales del ejercicio cubiertos con la alternativa documentada de orquestación; snapshot completo, warehouse, modelo, análisis y tablero ejecutados; medición y ensayo publicados. Uso de IA documentado. Bonus tests entregado; MCP, CI y video opcionales no realizados.
- Diseño diario, delta, restauración genérica y mantenimiento del tablero permanecen como mejoras declaradas. No son servicios activos ni se afirma su despliegue. Se conserva la prohibición de API nueva.


## Descripciones Python en español — 30/09/2026

Revisadas las 142 funciones, métodos y clases del repositorio, incluidas funciones internas y pruebas. Se agregaron o tradujeron docstrings breves en español en 20 archivos, explicando su propósito y los controles relevantes. Verificación AST: misma lógica al quitar docstrings; ninguna definición sin descripción; sintaxis y diff válidos. Las 20 pruebas offline terminaron OK. No se ejecutaron API, cargas ni cambios en BigQuery/GCS.


## Legibilidad de SQL — 30/09/2026

Indentados los 26 archivos SQL y agregados comentarios breves en español. El incremental distingue lectura raw, tablas temporales, MERGE de historia/estado actual, catálogos/siniestros y controles finales. Verificada igualdad de tokens SQL y literales respecto del original; parser BigQuery sin errores en los 26 archivos; lector de descripción gold compatible. Sin llamadas API ni mutaciones de warehouse. El hash de versión SQL de silver cambia por el formato: la próxima corrida puede reaplicar el lote, conservando la idempotencia de sus MERGE. No se agregan dependencias de formato al repositorio.


## Límite gold y mapa de archivos Parte 3 — 30/09/2026

Retirado por solicitud el bloqueo por tamaño total de gold: ASSERT SQL de 50 MB, estimación logical_bytes_upper_bound y assert numBytes del ejecutor. La réplica de transformación en pruebas se ajustó igualmente; se conserva el registro de tamaño real, conciliaciones y presupuesto de consulta. El requisito de 50 MB se verifica con bytes procesados de jobs reales de Looker, no con tamaño de tabla. README Parte 3 actualizado: 20 SQL descritos individualmente, orden gold 000→002→001→003, diagnósticos/migraciones separados del flujo habitual y ejecutores/esquemas documentados. Enlaces locales y cobertura de SQL válidos; 21 pruebas funcionales gold y 24 controles de producción PASS en tablas temporales. No se reconstruyó el mart ni se consultó la API.


## Guía de corrida nueva y ensayo final para entrevista — 30/09/2026

README central incorpora Guía de Uso con primera ejecución, repetición, captura nueva y comprobaciones. docs/EJECUCION.md añade comandos encadenados extractor --full → run_pipeline con RUN_ID único compartido y corte UTC, más recuperación con mismo identificador. La carga desde raw antecede a staging; ABM por MERGE, snapshot raw append, gold reemplazada. CLI --help y enlaces/anclas locales verificados sin API.

Ensayo sobre commit 713111b: pipeline SUCCESS 22:43:26–22:49:53 UTC (6 min 27 s). Silver reaplicó por nueva versión SQL: 1.003.461 eventos, 780.000 actuales, 138.133 siniestros y catálogos iguales. Gold SUCCESS, 24 controles, 45.875 filas/15.212.749 bytes y fingerprint 260909553606909619339 sin cambios. Evidencia pipeline/smoke-20260929/6e1a7d91e6c042ee90bfb0af61ffd374/report.json; anexo al reporte de ensayo existente. Cero llamadas API nuevas.

El ejercicio indica vencimiento del acceso del proyecto 02/10/2026 02:35 UTC (01/10 23:35 Argentina). Se preguntó la fecha de entrevista para confirmar vigencia; no se asume disponibilidad después ni se contacta a la empresa. Para una demostración corta, reutilizar snapshot. Captura API nueva documentada, no ejecutada.


## Fundamentos y glosario para entrega — 30/09/2026

README central amplía frecuencia/severidad con elección de denominadores, población PAGADO común, proxy por póliza sin ajustar duración y promedio observado. Ejemplo ficticio 1.000 pólizas/100 eventos/USD 50.000 costo/USD 200.000 prima; identidad frecuencia×severidad/prima media con denominadores válidos. Glosario compacto: prima, siniestro, costo, elegibilidad, cohorte/vigencia/corte/maduración, exposición, devengada/margen, grano e idempotencia. Referencia CAS confirma distinción exposición/eventos; no se presenta el indicador como frecuencia actuarial anual ni probabilidad de pólizas afectadas. Partes 5 y 6 enlazan a definiciones únicas; fórmulas y datos sin cambios.


Aclarada la anomalía FX en el README central: control del producto factor_usd×unidades_por_usd con tolerancia absoluta 0,000001; conversión según contrato explícito monto×factor_usd. No se infiere cuál campo es incorrecto ni se reemplazan tasas. Cambio de explicación, sin cambios en datos o fórmulas.


## Skill semántica de análisis — 30/09/2026

Creado SKILL.md en la raíz como artefacto de entrega, usando skill-creator. Incluye esquema/granos y relaciones, glosario breve, cuatro métricas, población/corte/FX, límites operativos y cinco preguntas naturales de ejemplo. Referencias al código y documentación; sin instalación global ni configuración de credenciales. Las herramientas MCP disponibles en esta sesión no incluyen consultas BigQuery. No se crean servidores ni se declara cumplida la ejecución de cinco preguntas vía MCP: Bonus 1 pasa a parcial. Sin consultas API ni nuevas cargas; README y bonus actualizan el alcance real.


## CI offline — 30/09/2026

Implementado .github/workflows/ci-offline.yml: push, pull_request y workflow_dispatch; Ubuntu y matriz Python 3.10/3.13, permisos contents:read. Valida diff del evento, sintaxis de scripts y 20 unittest existentes. Sin dependencias externas, credenciales cloud ni consultas a API/GCS/BigQuery; SQL permanece manual. Bonus README explica simulaciones, alcance y reproducción; README central acredita Bonus 3 implementado offline y revisión/guía de ejecución actualizadas. Se conservan nueve README.

Verificación local: 20 pruebas PASS, compileall y diff correctos. Commit eedc95e publicado; ejecución real https://github.com/isardi4/assist-365/actions/runs/36792623622 SUCCESS en ambos jobs (Python 3.10/3.13), todos los pasos aprobados. Sin cambios en scripts de negocio ni datos.


## Detalle de pruebas offline para entrega — 30/09/2026

README de bonus ampliado con escenario y resultado esperado de las 20 pruebas (7 configuración, 2 extracción, 11 GCS/carga), identificadas por nombre del método. Aclara mocks, límites frente a conectividad y warehouse real, rechazo esperado de entradas inválidas y alcance de compileall/diff. Cambio solo documental; sin cambios en código, datos ni consultas API.


## Redacción simple del bonus — 30/09/2026

Reformulada la explicación de las 20 pruebas con situaciones de ejemplo y comportamiento esperado, sin detalles de mocks/generaciones; se conserva una columna con el nombre exacto de cada función de prueba para ubicarla en el código. Se conserva el alcance exacto y los límites de validación offline. Solo documentación.


## README de las siete partes con ejemplos — 30/09/2026

Aplicado el formato archivo/función, situación de uso y comportamiento esperado a las siete partes. Parte 3 conserva cobertura de sus 20 SQL y archivos de apoyo, con separación entre cargas, consultas, pruebas y migraciones; añade ejemplo I→U→D sobre historial y estado actual. Partes 1/2 describen los archivos principales; Parte 4 explica cada llamada del pipeline; Partes 5/6/7 presentan consultas, recursos del dashboard y mapa documental con el mismo formato. Se mantienen comandos, resultados y límites de entrega. Cambios solo documentales, sin API ni alteraciones del modelo.
