CREATE TEMP TABLE policy_currencies AS
SELECT poliza_id,COUNT(DISTINCT moneda) currencies,ANY_VALUE(moneda) moneda FROM `a365-de-ignacio.assist365_staging.polizas` GROUP BY poliza_id;
CREATE TEMP TABLE rates AS SELECT moneda,fecha,factor_usd,LEAD(fecha,1,DATE '9999-12-31') OVER(PARTITION BY moneda ORDER BY fecha) next_date FROM `a365-de-ignacio.assist365_staging.tipo_cambio` WHERE factor_usd>0;
SELECT s.estado,COUNT(*) casos,COUNTIF(p.currencies=1) moneda_historica_unica,COUNTIF(p.currencies!=1 OR p.poliza_id IS NULL) ambiguos_o_sin_poliza,
 COUNTIF(s.monto<0) negativos,
 COUNTIF(s.monto>=0 AND (p.moneda='USD' OR r.factor_usd IS NOT NULL)) recuperables_no_negativos,
 SUM(IF(s.estado='PAGADO' AND s.monto>=0,SAFE_MULTIPLY(s.monto,IF(p.moneda='USD',NUMERIC '1',r.factor_usd)),NULL)) costo_usd_inferible
FROM `a365-de-ignacio.assist365_staging.siniestros` s LEFT JOIN policy_currencies p USING(poliza_id)
LEFT JOIN rates r ON r.moneda=p.moneda AND s.fecha_ocurrencia>=r.fecha AND s.fecha_ocurrencia<r.next_date
WHERE s.moneda IS NULL GROUP BY 1;
SELECT s.estado,COUNT(*) negativos_con_moneda,SUM(s.monto*r.factor_usd) importe_usd_con_signo FROM `a365-de-ignacio.assist365_staging.siniestros` s
JOIN rates r ON r.moneda=s.moneda AND s.fecha_ocurrencia>=r.fecha AND s.fecha_ocurrencia<r.next_date
WHERE s.monto<0 GROUP BY 1;
