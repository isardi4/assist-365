# Análisis por cohortes de emisión

Dos queries de BigQuery devuelven resultados mensuales directamente desde staging:

| Archivo | Situación de ejemplo | Qué devuelve |
|---|---|---|
| [001_siniestralidad_pais_plan.sql](sql/001_siniestralidad_pais_plan.sql) | Se quiere identificar qué país o plan tiene mayor costo pagado respecto de su prima. | Una fila por mes de emisión, país y plan, con cantidades, importes USD, siniestralidad, frecuencia y severidad. |
| [002_siniestralidad_canal_pais.sql](sql/002_siniestralidad_canal_pais.sql) | Se quiere comparar ONLINE y CALL_CENTER dentro de un país. | Una fila por mes de emisión, país y canal de agencia, con los mismos indicadores y cantidades de pólizas y siniestros. |

## Definición de cohorte

Una cohorte reúne pólizas emitidas en el mismo mes. **Prima y siniestros elegibles se atribuyen a ese mes**, aunque el evento ocurra después. `mes_cohorte` es su primer día, no el inicio de vigencia ni la ocurrencia.

Ejemplo: emisión el 10 de enero y siniestro el 7 de febrero pertenecen a enero. La conversión del costo conserva la cotización del 7 de febrero.

## Ejecutar

Abrir cualquiera de los SQL en BigQuery, ajustar las tres fechas declaradas y ejecutar:

- `fecha_desde` / `fecha_hasta`: emisión de pólizas; por defecto, abril–junio de 2026.
- `fecha_corte`: límite de ocurrencia, por defecto 29/09/2026. Permite eventos posteriores al trimestre de emisión, hasta la captura disponible.

```bash
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --max_rows=10000 --maximum_bytes_billed=2147483648 \
  < scripts/parte_05_analisis/sql/001_siniestralidad_pais_plan.sql
bq --project_id=a365-de-ignacio --location=us-central1 query \
  --use_legacy_sql=false --max_rows=10000 --maximum_bytes_billed=2147483648 \
  < scripts/parte_05_analisis/sql/002_siniestralidad_canal_pais.sql
```

Solo se necesita acceso a staging y permiso para ejecutar jobs. No se consulta la API ni se requieren archivos de datos locales. [Requisitos de ejecución](../../docs/EJECUCION.md).

## Población y joins

Se usa `polizas_activas`, excluyendo D, referencias ausentes y última ANULADA junto con sus siniestros. Prima y costo pertenecen a la misma población; el historial queda disponible para otros análisis.

Los siniestros se agrupan por póliza antes del LEFT JOIN. `detalle_poliza` conserva una fila por póliza, incluso sin eventos. Así se suma cada prima una vez, sin confundir pólizas diferentes con igual importe.

## Indicadores y tratamiento de datos

- Cantidad de pólizas: pólizas distintas de la cohorte.
- Cantidad de siniestros: todos los estados monetariamente elegibles asociados, hasta el corte; PAGADO se cuenta también por separado.
- Prima USD: última prima de la póliza, convertida con la tasa de emisión.
- Costo USD: solo PAGADO, convertido con la tasa de ocurrencia.
- Siniestralidad: suma del costo PAGADO / suma de la prima.
- Frecuencia: PAGADO / pólizas; representa eventos pagados por póliza, no porcentaje de pólizas con siniestro.
- Severidad: costo PAGADO / cantidad PAGADO. Denominadores cero devuelven nulo.

USD usa factor 1; otras monedas, la última cotización positiva anterior o igual a la fecha. Inferidos válidos incluidos y negativos/no resolubles excluidos; la cobertura se clasifica aparte. [Fundamentos de calidad](../../README.md#anomalías-y-tratamiento). Canal de agencia proviene del catálogo, no del canal de origen de la póliza.

[Glosario, fundamento de frecuencia/severidad y ejemplo numérico](../../README.md#glosario-y-fundamento-de-las-métricas).

## Interpretación y límites

**Las cohortes recientes tienen menor maduración:** pueden acumular eventos o pagos. Una siniestralidad baja no demuestra mejora definitiva; comparar tiempos de desarrollo similares.

La prima es la última informada, no devengada ni cobro comprobado. PAGADO es el estado disponible; no hay fecha de pago ni historia de estados. El corte limita ocurrencia sin reconstruir snapshots pasados; el ratio no mide margen neto.

[Gold](../../README.md#capa-gold) usa la misma definición y población. Para comparar con el [dashboard](../parte_06_tablero/README.md), seleccionar meses completos y el mismo corte de ocurrencia.

## Ejemplo de análisis: tres trimestres de emisión

Resultados de ambas queries con emisión `2025-10-01`–`2026-06-30` y corte `2026-09-29`: los últimos tres trimestres completos al corte de la captura. Son cohortes de emisión, no pagos del trimestre.

Para reproducir, cambiar `fecha_desde` a `2025-10-01`. Agrupar el resultado mensual por `DATE_TRUNC(mes_cohorte, QUARTER)`, sumar cantidades/importes y recalcular ratios sobre esas sumas.

### Evolución general

Importes en USD, redondeados al dólar; porcentajes calculados antes del redondeo.

| Cohorte | Pólizas | Siniestros totales / pagados | Prima USD | Costo pagado USD | Siniestralidad |
|---|---:|---:|---:|---:|---:|
| Oct–dic 2025 | 69.355 | 12.548 / 9.744 | 8.846.383 | 3.548.496 | 40,11% |
| Ene–mar 2026 | 67.741 | 12.229 / 9.588 | 8.612.382 | 3.433.664 | 39,87% |
| Abr–jun 2026 | 68.551 | 12.001 / 9.395 | 8.612.927 | 3.287.485 | 38,17% |

La siniestralidad baja **1,94 puntos**. La frecuencia pasa de 14,05 a 13,71 eventos cada 100 pólizas y la severidad de USD 364,17 a USD 349,92. Ambos componentes acompañan la caída, condicionada por la menor maduración de cohortes recientes.

### País y plan: dónde revisar primero

| País | Oct–dic 2025 | Ene–mar 2026 | Abr–jun 2026 |
|---|---:|---:|---:|
| Argentina | 41,01% | 41,92% | 39,84% |
| Brasil | 40,41% | 37,92% | 34,32% |
| Chile | 40,78% | 44,21% | 41,82% |
| Colombia | 38,01% | 37,26% | 37,70% |
| México | 39,54% | 40,33% | 36,85% |
| Perú | 41,64% | 35,12% | 37,20% |

**Chile lidera el ratio en ambas cohortes de 2026** y supera la cartera en 3,65 puntos en abril–junio. La composición de planes y canales también influye.

| Plan | Oct–dic 2025 | Ene–mar 2026 | Abr–jun 2026 |
|---|---:|---:|---:|
| Equipaje Protegido | 141,71% | 161,24% | 144,63% |
| Estudiante Larga | 117,33% | 124,50% | 109,16% |

**Ambos planes superan el 100% en los tres trimestres.** En abril–junio, Equipaje Protegido reúne 4.143 pólizas, USD 126.737 de prima y USD 183.296 de costo. Su frecuencia (13,93%) y severidad (USD 317,67) no son especialmente altas, pero la prima media es USD 30,59 frente a USD 125,64 general. La señal orienta a revisar precio y cobertura; no equivale a rentabilidad neta.

### Canal y país: ejemplo en Chile

| Canal de agencia | Siniestralidad oct–dic 2025 | Ene–mar 2026 | Abr–jun 2026 | Pólizas abr–jun | Siniestros totales / pagados abr–jun |
|---|---:|---:|---:|---:|---:|
| CALL_CENTER | 47,66% | 36,01% | 32,40% | 2.011 | 305 / 230 |
| ONLINE | 57,07% | 61,95% | 65,15% | 2.243 | 475 / 382 |
| PARTNER | 27,10% | 36,41% | 31,45% | 2.034 | 314 / 239 |
| RETAIL | 29,79% | 39,29% | 35,20% | 2.023 | 326 / 255 |

**ONLINE en Chile aumenta 8,08 puntos y lidera el ratio del país en las tres cohortes**, mientras el total de la cartera baja. En abril–junio registra 17,03 pagos cada 100 pólizas y USD 464,33 por evento, frente a 11,44 y USD 334,05 en CALL_CENTER. Frecuencia y severidad acompañan la diferencia. Revisar la mezcla de planes y agencias antes de atribuirla al canal.

Los hallazgos son descriptivos al corte disponible y mantienen las reglas de población y calidad indicadas. No demuestran causalidad ni siniestralidad final de cohortes abiertas.
