CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.polizas` (
  poliza_id STRING OPTIONS(description="Identificador único de la póliza en la fuente."),
  cliente_id STRING OPTIONS(description="Identificador del cliente titular de la póliza."),
  producto_id STRING OPTIONS(description="Identificador del producto contratado por la póliza."),
  agencia_id STRING OPTIONS(description="Identificador de la agencia vinculada al registro."),
  pais_emision STRING OPTIONS(description="Código del país donde se emitió la póliza fuente."),
  canal_origen STRING OPTIONS(description="Canal por el que se originó la emisión de la póliza."),
  fecha_emision_utc TIMESTAMP OPTIONS(description="Fecha y hora UTC de emisión informada por la fuente."),
  inicio_vigencia DATE OPTIONS(description="Fecha de inicio de la cobertura de la póliza."),
  fin_vigencia DATE OPTIONS(description="Fecha de finalización de la cobertura de la póliza."),
  prima NUMERIC OPTIONS(description="Prima en moneda de origen de esta versión de póliza."),
  moneda STRING OPTIONS(description="Código de moneda del importe o cotización fuente."),
  estado STRING OPTIONS(description="Estado comercial informado en el registro fuente."),
  operacion STRING OPTIONS(description="Evento CDC: I alta, U modificación o D baja de póliza."),
  updated_at TIMESTAMP OPTIONS(description="Fecha UTC que ordena los eventos CDC de la póliza.")
)
PARTITION BY TIMESTAMP_TRUNC(fecha_emision_utc, MONTH)
CLUSTER BY poliza_id, pais_emision, producto_id
OPTIONS(description="Historial de todos los eventos I/U/D de póliza, tipado en columnas de negocio. Una fila corresponde a póliza, instante de actualización y operación. Conserva cada versión única aunque llegue nuevamente en otra captura raw; no contiene identificadores de carga. Se particiona por mes de emisión y agrupa por póliza para actualizar el estado desde las claves afectadas.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.polizas_activas` (
  poliza_id STRING OPTIONS(description="Identificador único de la póliza en la fuente."),
  cliente_id STRING OPTIONS(description="Identificador del cliente titular de la póliza."),
  producto_id STRING OPTIONS(description="Identificador del producto contratado por la póliza."),
  agencia_id STRING OPTIONS(description="Identificador de la agencia vinculada al registro."),
  pais_emision STRING OPTIONS(description="Código del país donde se emitió la póliza fuente."),
  canal_origen STRING OPTIONS(description="Canal por el que se originó la emisión de la póliza."),
  fecha_emision_utc TIMESTAMP OPTIONS(description="Fecha y hora UTC de emisión informada por la fuente."),
  inicio_vigencia DATE OPTIONS(description="Fecha de inicio de la cobertura de la póliza."),
  fin_vigencia DATE OPTIONS(description="Fecha de finalización de la cobertura de la póliza."),
  prima NUMERIC OPTIONS(description="Prima en moneda de origen de esta versión de póliza."),
  moneda STRING OPTIONS(description="Código de moneda del importe o cotización fuente."),
  estado STRING OPTIONS(description="Estado comercial informado en el registro fuente."),
  updated_at TIMESTAMP OPTIONS(description="Fecha UTC que ordena los eventos CDC de la póliza.")
)
PARTITION BY TIMESTAMP_TRUNC(fecha_emision_utc, MONTH)
CLUSTER BY poliza_id, pais_emision, producto_id
OPTIONS(description="Último estado lógico de cada póliza, con una fila por identificador y la prima más reciente informada por el core. Los eventos U reemplazan atributos y un último evento D elimina la póliza de esta tabla, manteniendo su historial en polizas. ANULADA y VENCIDA permanecen como estados comerciales. La transformación se materializa durante la carga, sin recalcularla al consultar.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.agencias` (
  agencia_id STRING OPTIONS(description="Identificador de la agencia vinculada al registro."),
  nombre STRING OPTIONS(description="Nombre de la agencia informado en el catálogo fuente."),
  pais STRING OPTIONS(description="Código del país de la agencia en el catálogo fuente."),
  canal STRING OPTIONS(description="Canal comercial de la agencia en el catálogo fuente.")
)

OPTIONS(description="Catálogo materializado de agencias con una fila por identificador y únicamente nombre, país y canal comercial. La captura completa más reciente actualiza los atributos y retira referencias ausentes del catálogo, tras validar integridad y orden de captura. Su pequeño volumen no requiere partición y los datos operativos de la carga permanecen en control.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.productos` (
  producto_id STRING OPTIONS(description="Identificador del producto contratado por la póliza."),
  nombre_plan STRING OPTIONS(description="Nombre del plan comercial definido para el producto."),
  tipo STRING OPTIONS(description="Categoría del producto o siniestro según la fuente."),
  cobertura_max_usd NUMERIC OPTIONS(description="Límite máximo de cobertura del producto en dólares."),
  es_premium BOOL OPTIONS(description="Indica si el producto pertenece a la categoría premium.")
)

OPTIONS(description="Catálogo materializado de planes con una fila por producto, cobertura máxima en dólares e indicador premium tipados. Se actualiza desde la captura completa más reciente y permite enriquecer pólizas y siniestros sin repetir extracción de JSON. No contiene metadatos de carga ni requiere partición por su reducido volumen; la integridad se valida antes de confirmar el lote.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.tipo_cambio` (
  fecha DATE OPTIONS(description="Fecha de referencia de la cotización de moneda."),
  moneda STRING OPTIONS(description="Código de moneda del importe o cotización fuente."),
  factor_usd NUMERIC OPTIONS(description="Factor para convertir el importe de origen a dólares."),
  unidades_por_usd NUMERIC OPTIONS(description="Unidades de moneda por dólar declaradas por la fuente.")
)
PARTITION BY DATE_TRUNC(fecha, MONTH)
CLUSTER BY moneda
OPTIONS(description="Cotizaciones materializadas con grano fecha y moneda, particionadas por mes de cotización. Mantiene factor_usd y unidades_por_usd tal como los declara la fuente, sin invertir ni corregir silenciosamente los valores. La captura completa más reciente actualiza el catálogo y los problemas de reciprocidad se registran en control para su revisión de negocio.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_staging.siniestros` (
  siniestro_id STRING OPTIONS(description="Identificador único del siniestro informado por la fuente."),
  poliza_id STRING OPTIONS(description="Identificador único de la póliza en la fuente."),
  fecha_ocurrencia DATE OPTIONS(description="Fecha del evento; nula si el valor fuente es inválido."),
  fecha_reporte DATE OPTIONS(description="Fecha de reporte; nula si el valor fuente es inválido."),
  tipo STRING OPTIONS(description="Categoría del producto o siniestro según la fuente."),
  estado STRING OPTIONS(description="Estado comercial informado en el registro fuente."),
  monto NUMERIC OPTIONS(description="Importe del siniestro convertido a tipo NUMERIC."),
  moneda STRING OPTIONS(description="Código de moneda del importe o cotización fuente."),
  ciudad STRING OPTIONS(description="Ciudad de atención normalizada desde city o ciudad_atencion."),
  diagnostico STRING OPTIONS(description="Diagnóstico normalizado desde diagnosis o diagnostico."),
  proveedor STRING OPTIONS(description="Proveedor de atención informado en el detalle fuente."),
  estado_cobertura STRING OPTIONS(description="Clasifica coincidencia de fecha con cobertura histórica."),
  estado_importe STRING OPTIONS(description="Clasifica monto negativo, moneda nula o importe válido."),
  moneda_analisis STRING OPTIONS(description="Moneda fuente o inferida de póliza para análisis USD."),
  origen_moneda_analisis STRING OPTIONS(description="Indica moneda de fuente, inferida o no disponible."),
  excluir_calculos BOOL OPTIONS(description="Excluye importes no aclarados de costos y conteos KPI.")
)
PARTITION BY DATE_TRUNC(fecha_ocurrencia, MONTH)
CLUSTER BY poliza_id, estado
OPTIONS(description="Siniestros materializados con una fila por identificador y todos los estados de negocio, no solo pagados. La captura completa más reciente inserta y actualiza registros, deduplicando repeticiones idénticas; una ausencia se registra en control y no se interpreta como baja. Fechas, importes y variantes bilingües se tipan durante la carga y los campos operativos quedan en raw.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.silver_resource_state` (
  resource STRING OPTIONS(description="Recurso de la API al que pertenece el registro."),
  source_snapshot_at TIMESTAMP OPTIONS(description="Fecha UTC de extracción de la última captura aplicada."),
  source_run_id STRING OPTIONS(description="Corrida raw que aportó la última captura aplicada."),
  applied_at TIMESTAMP OPTIONS(description="Fecha UTC en que se confirmó la transformación silver.")
)
CLUSTER BY resource
OPTIONS(description="Estado operativo de la última captura raw aplicada por recurso a silver. Permite evitar que una captura antigua reemplace catálogos o siniestros más recientes. Sus marcas se confirman en la misma transacción que actualiza las tablas de negocio y las conciliaciones, sin guardar datos comerciales ni avanzar el watermark de extracción de la API.");

CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.silver_runs` (
  run_id STRING OPTIONS(description="Identificador de la corrida de extracción de origen."),
  job_id STRING OPTIONS(description="Identificador del job BigQuery de esta transformación."),
  started_at TIMESTAMP OPTIONS(description="Fecha UTC en que comenzó la corrida de extracción."),
  finished_at TIMESTAMP OPTIONS(description="Fecha UTC en que terminó la corrida de extracción."),
  run_status STRING OPTIONS(description="Resultado de extracción; no representa la carga remota."),
  resources JSON OPTIONS(description="Recursos raw incluidos en la transformación de silver."),
  source_partitions JSON OPTIONS(description="Rango de particiones raw leídas por esta ejecución."),
  summary JSON OPTIONS(description="Resumen JSON de recursos y resultados de extracción."),
  error_message STRING OPTIONS(description="Mensaje del fallo de transformación registrado en control.")
)
PARTITION BY DATE(started_at)
CLUSTER BY run_id, run_status
OPTIONS(description="Registro operativo de cada intento de carga raw a silver, identificado por la corrida de origen y el job de BigQuery. Conserva recursos, particiones leídas, resultado y conciliaciones resumidas; los fallos quedan visibles y una reejecución no duplica los eventos de negocio. Se utiliza para demostrar atomicidad, consumo y puntos de avance sin introducir metadatos de carga en staging.");








ALTER TABLE `a365-de-ignacio.assist365_staging.siniestros`
 ADD COLUMN IF NOT EXISTS estado_cobertura STRING OPTIONS(description="Clasifica coincidencia de fecha con cobertura histórica."),
 ADD COLUMN IF NOT EXISTS estado_importe STRING OPTIONS(description="Clasifica monto negativo, moneda nula o importe válido."),
 ADD COLUMN IF NOT EXISTS moneda_analisis STRING OPTIONS(description="Moneda fuente o inferida de póliza para análisis USD."),
 ADD COLUMN IF NOT EXISTS origen_moneda_analisis STRING OPTIONS(description="Indica moneda de fuente, inferida o no disponible."),
 ADD COLUMN IF NOT EXISTS excluir_calculos BOOL OPTIONS(description="Excluye importes no aclarados de costos y conteos KPI.");
