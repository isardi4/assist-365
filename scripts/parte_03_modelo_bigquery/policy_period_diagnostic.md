# Diagnóstico de versiones por período de cobertura

Ejecutado el 2026-09-30 en BigQuery sobre los datos existentes de staging,
sin consultar la API ni modificar tablas de negocio.

SQL: `sql/015_policy_period_diagnostic.sql`.
Job: `bqjob_r64159a12cb221d93_000001a0f062c21d_1`.

| Medición | Cantidad |
| --- | ---: |
| Eventos I | 800.000 |
| Eventos U | 183.461 |
| Eventos D | 20.000 |
| U con la misma vigencia que el evento anterior | 183.461 |
| U que cambia la vigencia | 0 |
| U sin evento anterior | 0 |
| U con la misma vigencia y cambio de prima o moneda | 50.408 |
| Eventos con período nulo o invertido | 0 |
| Períodos distintos por póliza, excluyendo eventos D | 800.000 |
| Pólizas con más de un período | 0 |
| Pares de períodos superpuestos | 0 |
| Siniestros con exactamente un período coincidente | 136.339 |
| Siniestros sin período coincidente | 1.794 |
| Siniestros con múltiples períodos coincidentes | 0 |

La comparación de U usa el evento inmediatamente anterior por `updated_at`.
Los períodos se deduplican por `(poliza_id, inicio_vigencia, fin_vigencia)`.
El diagnóstico de siniestros usa fechas inclusivas (`BETWEEN`) y conserva
los períodos históricos de pólizas eliminadas; no usa solo pólizas activas.
Los casos sin coincidencia requieren distinguir falta de póliza de fechas
fuera de cobertura antes de incorporarlos a análisis de siniestralidad.

## Conclusión

En este conjunto no hace falta una tabla adicional `poliza_versiones`:
`polizas_activas` ya reemplaza la I por la última U y excluye la última D.
`polizas` conserva todos los eventos para auditoría e historia de eliminadas.
No se modificó el modelo ni se generó una tabla duplicada.

Si llegan períodos distintos para el mismo ID, la clave de la tabla de
versiones puede ser `(poliza_id, inicio_vigencia, fin_vigencia)`, con la
última actualización por clave. Antes de implementarla debe definirse
cómo una D identifica o cierra períodos, y qué hacer con coberturas
superpuestas o correcciones de fechas. Un período distinto no demuestra
por sí solo una renovación válida.

Este modelo aplica la regla solicitada de reemplazar correcciones dentro
de una misma cobertura. No reconstruye las condiciones conocidas en cada
instante: para esa pregunta se necesitaría vigencia temporal de versiones,
que no debe confundirse con las fechas de cobertura.
