-- Crear el control de ejecuciones gold y registrar el inicio del job.
CREATE TABLE IF NOT EXISTS `a365-de-ignacio.assist365_control.gold_runs` (
  job_id STRING OPTIONS (description = 'Identificador del trabajo que materializa la capa gold.'),
  started_at TIMESTAMP OPTIONS (description = 'Instante UTC de inicio del intento de publicación gold.'),
  finished_at TIMESTAMP OPTIONS (description = 'Instante UTC de cierre del intento de publicación gold.'),
  run_status STRING OPTIONS (description = 'Estado de ejecución: RUNNING, SUCCESS o FAILED en gold.'),
  model_sha256 STRING OPTIONS (description = 'Huella SHA256 del SQL usado para construir el agregado.'),
  summary JSON OPTIONS (description = 'Conciliaciones y cifras de negocio de la publicación gold.'),
  error_message STRING OPTIONS (description = 'Mensaje de error del intento fallido de publicación gold.')
) PARTITION BY DATE(started_at)
OPTIONS (
  description
  = 'Registro operativo de intentos de construcción y publicación de gold desde silver. Guarda versión SQL, conciliaciones, resumen de calidad y fallas. Sus campos técnicos permanecen fuera de los datasets de negocio y permiten rastrear publicaciones exitosas y mantener la última versión válida ante errores.'
);
INSERT INTO `a365-de-ignacio.assist365_control.gold_runs` (job_id, started_at, run_status, model_sha256)
VALUES (@job_id, CURRENT_TIMESTAMP(), 'RUNNING', @model_sha256);
