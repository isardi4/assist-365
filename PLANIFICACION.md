# Planificación del caso práctico Assist-365

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

## Decisiones que hay que fijar antes de calcular

1. **Prima y conversión a USD.** Convertir `prima` con `factor_usd` usando moneda y fecha de referencia. Como la póliza contiene fecha de emisión y la tabla de cambio contiene fecha, la regla inicial recomendada es tomar el tipo de cambio de la fecha de emisión; documentar cómo se resuelve la ausencia de cotización exacta (última fecha disponible anterior, con alerta si no existe).
2. **Costo de siniestros.** El glosario define costo como monto efectivamente pagado. La API expone `status` y `amount`, pero no una fecha de pago. Para una primera versión, incluir solo `PAGADO`, convertir el monto con `factor_usd` de la fecha de ocurrencia y describirlo como aproximación. No sumar `EN_ANALISIS` ni `RECHAZADO` al costo pagado.
3. **Período de siniestralidad.** No hay una clave de cohorte que enlace directamente la fecha de prima con el período de los siniestros pagados. Para responder por trimestre, mostrar prima emitida por trimestre de emisión junto a costo pagado por trimestre de ocurrencia, por país y plan asociado a la póliza; denominarlo “siniestralidad operativa del período” y advertir que sus componentes no son la misma cohorte. Si se calcula el cociente, incluir esa limitación y proponer como mejora incorporar fecha de pago y seguimiento de maduración de cohortes.
4. **Anulados, borrados y cambios.** Aplicar la última operación conocida por póliza (`updated_at`) para obtener su estado actual, conservando todas las filas y estados en el hecho. Excluir `D` de la versión activa; mantener anuladas identificadas y definir explícitamente si su prima integra prima emitida o se netea como devolución. Vencida no significa anulada: no excluirla automáticamente de ventas históricas. Conservar todos los eventos crudos para auditoría.
5. **Incrementalidad.** Pólizas admiten `updated_since` y cursor; usar una ventana solapada para tolerar retrasos y deduplicar por `poliza_id` y `updated_at`. Siniestros no ofrecen filtro de cambios: obtener snapshot completo y hacer `MERGE` por `claim_id` (o recarga reemplazable de staging). Los catálogos son pequeños y se reemplazan completos.

Registrar estos supuestos y, si hay tiempo, consultar al contacto si tienen definición preferida para siniestralidad, fecha efectiva de conversión FX, estados de póliza y eventos pagados.

## Arquitectura propuesta

`API → extractor Python → raw local validado → (etapa posterior) GCS → tablas raw en BigQuery → modelo analítico en BigQuery → Looker Studio`

- Implementar un extractor Python con configuración por variables de entorno. La credencial de API se obtiene de Secret Manager en GCP o de una variable local ignorada por Git; nunca incluir el token en código, logs, README ni historial.
- Las primeras versiones y corridas de validación se conservan localmente en `.local_data/`, ignorada por Git. No crear todavía el bucket ni mover allí datos hasta cerrar la validación local.
- BigQuery se prepara por separado para recibir cargas batch desde los archivos locales validados; cuando se habilite GCS, mantenerlo como copia durable/reprocesable y cargar desde allí. Guardar fecha de extracción y recurso en ruta/metadata. Definir retención razonable de raw.
- Ejecutar el mismo contenedor como Cloud Run Job y dispararlo diariamente con Cloud Scheduler. El Job debe ser idempotente y dejar logs claros; configurar service account con permisos mínimos para Secret Manager, GCS y BigQuery.
- Datasets separados `assist365_raw`, `assist365_staging` y `assist365_mart` en `us-central1` (Iowa), elegida por costo de almacenamiento regional y por alinear BigQuery/GCS. Las tablas de staging/mart se diseñarán después de perfilar raw; se preparan los espacios, sin adelantar modelos.
- En raw, conservar respuestas/payloads originales, eventos CDC y snapshots con metadatos técnicos; añadir tablas de ejecuciones, errores, conciliaciones y watermarks para que cada carga diaria deje evidencia consultable.
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

### Fase 3 — Carga raw en BigQuery

1. Crear `assist365_raw`, `assist365_staging` y `assist365_mart` en `us-central1`; esta configuración ya está hecha. Mantener staging/mart sin tablas de negocio hasta perfilar raw.
2. Preparar una tabla raw flexible que retenga cada registro completo como JSON, más recurso, `run_id`, lote, página/offset, posición, hora de extracción, hash y referencia al archivo original. Añadir tablas de control de ejecuciones, errores/cuarentena, conciliaciones y watermarks. No limitar raw a las columnas enumeradas en el ejercicio.
3. Mientras la validación sea local, producir archivos load-ready localmente y probar el proceso de carga de forma acotada; no crear el bucket GCS todavía. Cuando se cierre esa etapa, mover los archivos validados a GCS y usar cargas batch desde GCS a BigQuery, no inserts fila a fila.
4. Particionar las tablas grandes por fecha de ingesta; clusterizar por identificadores disponibles que ayuden a rastrear/reprocesar. No depender de campos de negocio aún no confirmados para particionar raw.
5. Distinguir lote/snapshot de evento CDC. Para pólizas, guardar cada operación cruda `I/U/D` como evento inmutable y aplicar ABM a una vista/tabla de estado actual mediante clave `poliza_id`, `updated_at` y desempate determinista; nunca borrar el historial raw. Para siniestros, la API disponible no ofrece filtro incremental: guardar snapshots completos y detectar altas/cambios por hash. Una ausencia solo será candidata a baja si el snapshot terminó completo y concilió; mantenerla pendiente hasta descartar truncamiento/variación de paginación. Para catálogos, guardar snapshots completos pequeños y comparar claves/hash.
6. Verificar recuentos de archivos frente a filas cargadas, esquema, duplicados, claves repetidas dentro del lote, filas inválidas, campos obligatorios, tipos y rangos antes de marcar la etapa como exitosa.
7. Registrar rechazos de BigQuery con archivo y lote; corregir y volver a cargar desde GCS sin descargar otra vez.
8. Perfilar raw: inventariar campos por fuente, nulidad, tipos observados, valores distintos y cambios entre lotes; limitar el costo de perfiles amplios con lecturas particionadas/agregadas. Usar esos hallazgos para proponer staging/mart sin asumir que el contrato publicado enumera todo.
9. Documentar en README el método de carga elegido, por qué, estructura real preservada, perfilado, particionado, conciliaciones, errores y bytes/almacenamiento observados. Replanificar staging y mart con esta evidencia antes de implementarlos.

### Cargas diarias incrementales y ABM

- La primera carga completa local establece la base y no debe confundirse con un delta. Cada corrida posterior usa un `run_id` nuevo y es idempotente al reprocesar el mismo lote.
- **Pólizas:** iniciar `updated_since` con el último watermark confirmado menos una ventana de solapamiento configurable; recorrer todos los cursores. Preservar cada evento, incluidas operaciones `D`; deduplicar relecturas por clave de evento (clave de negocio, `updated_at`, `op` y hash del payload), sin perder dos eventos distintos con timestamp compartido. Avanzar watermark solo cuando todas las páginas y controles concluyan. Validar el orden/semántica de `updated_since` con datos antes de automatizar.
- **Siniestros:** al no existir filtro de cambios documentado, solo una extracción completa permite detectar ABM diarios. Comparar snapshot conciliado con el anterior por `claim_id` y hash de payload para clasificar alta/cambio/sin cambio. Una fila ausente no se borra de raw ni se marca como baja definitiva sin política confirmada; conservarla como candidata y revisar consistencia del snapshot.
- **Catálogos:** capturar snapshot diario/reemplazable y comparar clave/hash para altas, cambios y ausencias; preservar snapshots anteriores para auditoría. Revisar si el costo/volumen observado permite reducir frecuencia.
- **Puerta de éxito:** no adelantar watermark ni publicar estado actual cuando falten páginas, existan cursores/offsets repetidos, no coincida el total del proveedor, haya claves duplicadas incompatibles o fallen cargas/conciliaciones. Reintentar desde archivos raw locales, no desde la API, siempre que los archivos estén íntegros.
- **Reporte diario:** por recurso y `run_id`, informar filas/páginas, nuevos/modificados/borrados explícitos, candidatos ausentes, duplicados, errores, hashes/bytes, watermark anterior/nuevo y resultado de cada control. Las diferencias sin explicación quedan en ledger y bloquean la marca de ejecución completa.

### Recomendación al proveedor: cambios en siniestros

En el contrato y las muestras revisadas de `GET /siniestros` aparecen `occurred_at` y `reported_at`, pero no `created_at`, `updated_at`, operación de cambio ni filtro incremental. `reported_at` es fecha del reporte del evento; no se debe reinterpretar como fecha técnica de creación o actualización del registro. La extracción completa puede revelar campos adicionales; registrar la ausencia como hallazgo confirmado solo después de revisar todas las páginas.

Solicitar al proveedor `created_at` y `updated_at` en UTC, filtro `updated_since` con cursor estable y snapshot consistente, operación `I/U/D` o tombstone explícito, y `paid_at` para distinguir ocurrencia, reporte, actualización y pago. `created_at` sola no detecta modificaciones posteriores; `updated_at` y un filtro de cambios son los necesarios para evitar el snapshot completo diario. Hasta que estén disponibles, comparar snapshots completos por `claim_id`/hash; detectar altas y cambios, y dejar ausencias como candidatas a baja. El volumen observado implica unas 278 páginas por snapshot. Confirmar con el proveedor si existen campos o filtros adicionales antes de fijar esta estrategia como permanente.

### Fase 4 — Modelo dimensional

Declarar el grano en comentarios SQL y README. Evitar unir hechos entre sí directamente para que un siniestro no multiplique la prima.

- `dim_producto`: una fila por `producto_id`; atributos de plan, tipo, premium y cobertura.
- `dim_agencia`: una fila por `agencia_id`; atributos de país y canal de la agencia. Mantener separado `pais_emision` de póliza y `pais` de agencia.
- `dim_fecha`: una fila por día, con atributos de calendario/trimestre.
- `dim_pais` (opcional, seis países): una fila por código de país, para nombres/orden de presentación.
- `fact_ventas`: **una fila por póliza no borrada en su última versión conocida**; dimensiones de producto, país de emisión, agencia y fecha de emisión; prima original, moneda, factor FX aplicado y prima USD. Guardar también estado, fechas de vigencia, anticipación de compra y claves de trazabilidad. La métrica de prima emitida aplica una regla explícita para anuladas y no descarta vencidas.
- `fact_siniestros`: **una fila por claim (`claim_id`) en la versión actual del snapshot**; clave a póliza y dimensiones disponibles; fechas de ocurrencia/reporte, tipo, estado, monto original, moneda y costo USD. Indicar si integra al costo pagado.

Pasos SQL:

1. Normalizar fechas (incluidas fechas `DD/MM/YYYY`), decimales y códigos de moneda.
2. Construir la versión actual de pólizas ordenando por `updated_at` y desempate determinista; interpretar `U`/`D` y estado sin descartar el raw.
3. Construir claims deduplicados por identificador, priorizando el snapshot más reciente si el origen devuelve cambios.
4. Resolver FX sin multiplicar filas: una cotización única por fecha/moneda, aplicar la regla de fecha acordada y dejar auditable la cotización usada.
5. Resolver relaciones de claims a pólizas con `LEFT JOIN`; cuantificar huérfanos en vez de eliminarlos silenciosamente.
6. Crear vistas/tablas agregadas de consumo para el tablero, con periodo, país, plan, prima USD, costo pagado USD, cantidad de pólizas, cantidad de claims pagados, frecuencia y monto promedio.
7. Agregar controles SQL sencillos: unicidad de claves, no negatividad cuando corresponda, monedas/estados permitidos, cobertura FX y porcentaje de claims sin póliza.
8. Emitir resultados de controles a una tabla de auditoría; separar cuarentena de métricas y no convertir nulos/monedas desconocidas a cero.
9. Documentar en README el grano, linaje, reglas de conversión/estados, controles, errores/cuarentena y costo estimado/medido del mart.

### Fase 5 — Análisis de negocio

1. Elegir explícitamente el trimestre analizado (trimestre calendario completo más reciente con datos, salvo que el ejercicio indique otro); usar zona UTC o documentar la zona comercial elegida.
2. Calcular prima emitida USD, costo pagado USD y cociente de ambos por plan y país, con la advertencia de períodos no cohortes.
3. Mostrar denominadores y volúmenes junto al ratio; evitar conclusiones basadas en grupos pequeños.
4. Separar frecuencia (claims pagados / pólizas expuestas o emitidas, dejando claro cuál denominador se usa) de severidad (monto promedio pagado por claim). Si no existe exposición confiable para el período, usar claims por póliza emitida y llamarlo proxy.
5. Investigar un insight adicional con corte útil (por ejemplo canal, agencia, tipo de siniestro, anticipación o concentración de costo) y validar que no sea efecto de datos faltantes o pocos casos.
6. Validar agregados contra las sumas de hechos y rastrear casos extremos desde raw hasta la métrica.
7. Guardar consultas, parámetros, fecha/run_id y resultados para reproducibilidad.
8. Incorporar a README cifras, período, denominadores, conciliaciones, consultas/resultados, hallazgo adicional, errores abiertos y caveats.

### Fase 6 — Tablero con límite de 50 MB

1. Conectar Looker Studio a una tabla agregada del mart y no a los JSON/raw ni a hechos completos.
2. Preagregar a grano diario o trimestral por país y plan, según los filtros/series requeridos. Incluir dimensiones de fecha para permitir filtro de trimestre sin escanear todo.
3. Particionar por fecha y clusterizar país/plan. Configurar rango de fechas predeterminado acotado al trimestre actual o más reciente.
4. Diseñar una sola página con cuatro visualizaciones como máximo: (a) KPI/serie de siniestralidad del trimestre; (b) comparación por país; (c) comparación por plan; (d) frecuencia y monto promedio para diagnosticar el impulsor. Incluir filtros claros de trimestre, país y plan si el presupuesto de bytes lo permite.
5. Medir en BigQuery el tamaño estimado/procesado de las consultas representativas con el mismo filtro temporal; documentar los bytes por carga y margen bajo 50 MB. No afirmar un límite que no se haya medido. Revisar el comportamiento de consultas que emite el conector de Looker Studio y el efecto de filtros/componentes.
6. Compartir tablero con la dirección indicada en el ejercicio y comprobar acceso desde la cuenta correspondiente.
7. Incorporar estado de frescura/calidad (último run exitoso y filas en cuarentena) y revisar su comportamiento tras una carga fallida.
8. Incorporar a README el diseño, fuente agregada, consultas/bytes verificados, estado de calidad y límite del método de medición.

### Fase 7 — Ejecución diaria en GCP

1. Empaquetar extractor y SQL/modelado en una imagen reproducible.
2. Desplegar Cloud Run Job con variables no secretas por configuración y token desde Secret Manager.
3. Programar Cloud Scheduler para ejecución diaria, con zona horaria explícita y horario que no choque con cuotas.
4. Dar a la service account solo permisos necesarios; evitar credenciales de usuario permanentes.
5. Definir estados y alertas (fallo, falta de datos, caída abrupta de volumen, diferencias de conciliación y aumento de cuarentena). Evitar que un job parcial publique un mart incompleto.
6. Ejecutar dos corridas consecutivas: comprobar que la segunda no duplica pólizas ni claims y que recoge cambios. Para claims, documentar que reconsulta el snapshot completo mientras la API no ofrezca watermark.
7. Confirmar que errores/reintentos quedan consultables, una falla bloquea cifras completas y el reproceso cierra con conciliación.
8. Actualizar README con comandos, schedule, service account, permisos, consumo, monitoreo, política de errores y evidencia de idempotencia.

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
