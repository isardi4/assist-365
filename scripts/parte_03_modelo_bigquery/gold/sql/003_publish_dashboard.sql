-- Reemplazar gold y confirmar el estado del job en una misma transacción.
BEGIN TRANSACTION;
-- Reemplazar el contenido publicado con el candidato ya validado.
DELETE FROM `a365-de-ignacio.assist365_mart.dashboard_diario`
WHERE TRUE;
INSERT INTO `a365-de-ignacio.assist365_mart.dashboard_diario` SELECT * FROM candidate;
-- Registrar el resultado del job junto con la publicación.
UPDATE `a365-de-ignacio.assist365_control.gold_runs` SET
  finished_at = CURRENT_TIMESTAMP(), run_status = 'SUCCESS', summary = (SELECT TO_JSON(v) FROM validation v)
WHERE job_id = @job_id AND DATE(started_at) >= DATE '1970-01-01';
COMMIT TRANSACTION;
SELECT * FROM validation;
SELECT * FROM checks;
