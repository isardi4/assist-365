# Revisión de entrega — 2026-09-30

Revisión de código, contratos, documentación y consistencia de resultados. Se verificaron comandos desde un clon limpio y se ejecutó el flujo desde GCS hasta gold sobre el snapshot disponible. Se corrigieron los puntos que impedían arrancar o repetir etapas; no se consultó la API ni se cambiaron las reglas de negocio.

| Punto revisado | Resultado / decisión |
|---|---|
| Separación de capas | Raw por recurso, staging física de negocio, mart agregado y controles en dataset aparte. |
| Grano de hechos | Historial de pólizas: póliza/timestamp/operación; estado actual: una póliza; siniestros: un siniestro. Catálogos de productos/agencias y FX fecha/moneda. |
| I/U/D | Último evento primero, exclusión posterior; no recuperar I cuando termina ANULADA o D. Historia conservada. |
| Moneda e importes | Inferida incluida con procedencia; negativos/no resolubles excluidos de importe y conteo analítico. |
| Joins analíticos | Prima y costo agregados por separado; siniestros agrupados por póliza antes del join; prima/costo atribuidos a su cohorte sin multiplicar pólizas. |
| Agencia | Nombre no único: el análisis agrupa por canal de catálogo y país, sin combinar agencias por nombre. |
| Canales | Canal de origen de póliza y canal de catálogo de agencia son atributos diferentes; el análisis solicitado usa el canal de agencia sin reemplazar el canal de origen. |
| Reproducibilidad | CLI única desde GCS probada en un clon limpio; dos SQL analíticos ejecutados, con fechas y corte explícitos. No dependen de snapshots locales ni del Markdown del ejercicio. |
| Documentación | Comandos corregidos, estado actual separado de diseño futuro y decisiones fundamentadas en datos. |

## Ensayo de ejecución

El 30/09/2026, sobre el commit `5f6b5d7`, finalizaron preparación, verificación raw, staging y reconstrucción gold. Gold conservó 45.875 filas y 15.212.749 bytes; pasaron 20 pruebas offline, pruebas SQL incrementales/gold/flags/UTC y las dos consultas analíticas. Los 11 comandos CLI probados arrancan. La extracción se verificó con fixtures y con el checkpoint completo; no se prueba aquí disponibilidad ni una captura nueva de la API. [Evidencia y referencias cloud](evidence/ensayo_20260930.json).

## Pendientes que afectan la entrega

1. **Acceso y mantenimiento de Looker.** Falta confirmar acceso con la identidad destinataria. El escaneo de la carga inicial abril–junio ya se midió: **1.405.616 bytes procesados**, ocho jobs reales sin caché BigQuery, por debajo de 50 MB. Revalidar si cambia la configuración, el volumen o el período. [Medición y evidencia](../scripts/parte_06_tablero/README.md#medición-de-consumo).
2. **Programación diaria.** Cloud Run Job/Scheduler no están desplegados. Se entrega el diseño y la conducta de segunda corrida; no un servicio operativo diario.
3. **Portabilidad del pipeline.** Raw/silver/gold contienen referencias al proyecto del challenge. Las dos queries también referencian explícitamente ese proyecto. El snapshot está en GCS, fuera de Git; reconstruir raw requiere permisos sobre el bucket.
4. **Accesos.** El token del challenge está versionado en `config/assist365.json` por decisión de entrega. El extractor lo lee por defecto; el análisis no lo utiliza. Las credenciales de Google Cloud no se versionan: cada ejecutor requiere identidad y permisos propios.

## Límites de interpretación

- Gold y análisis usan la misma población no D/no ANULADA, atribuyendo prima y siniestros a la cohorte de emisión. Las referencias ausentes y ocurrencias posteriores al corte quedan fuera; sus cantidades permanecen en control. Las cohortes recientes tienen menor desarrollo. La fecha de corte no reconstruye estados históricos ni prueba cobros/pagos fechados, prima devengada o margen neto.
- Fechas futuras de origen se reportan y se evitan mediante el período explícito; no se corrigen silenciosamente. El catálogo representa el estado disponible, sin historia dimensional para atribuir cambios pasados de agencia/producto.
## Mejoras posteriores

Parametrizar proyecto y datasets; desplegar identidad de servicio; integrar métricas y alertas diarias; decidir FX contractual ante factores no recíprocos; resolver negativos/cobertura con la fuente; incorporar historia dimensional y exposición para análisis actuarial. Los bonus de MCP, CI y video no se consideran implementados.

Gold incorpora nombre de plan, tipo de producto y canal de agencia con grano mensual. Las queries de análisis sirven como referencia para conciliar meses de emisión completos con el mismo corte. Los campos heredados de siniestros de pólizas D/ANULADA/ausentes quedan en cero; la exclusión de población se registra en control.
