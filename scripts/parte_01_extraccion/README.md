# Parte 1 — Extracción

- `api/`: cliente HTTP, token, TLS y primitivas compartidas.
- `extractor/`: paginación, checkpoints, raw local, manifiesto y ledger de errores.
- `run.py`: punto de entrada. Sin opciones, usa una página por recurso, una espera mínima de 1 segundo y hasta 6 reintentos por solicitud; **no descarga todo el histórico**. Indicá siempre los límites y el `run_id` explícitamente.

El README raíz contiene los comandos completos para iniciar una extracción total desde cero, reanudar un checkpoint interrumpido y crear un snapshot nuevo diario. Una corrida diaria requiere un `run_id` distinto; repetir el ID anterior reanuda esa corrida o no hace nada si ya estaba completa. El extractor actual toma snapshots completos: el modo incremental por `updated_since` aún no está implementado.

La extracción local `smoke-20260929` terminó en `SUCCESS`: 1.003.461 pólizas en 1.004 páginas, 138.962 siniestros en 278 páginas, 300 agencias, 12 productos y 5.124 tipos de cambio. Las 1.147.859 filas se conservaron sin cuarentena en archivos gzip, con manifiesto y ledger bajo `.local_data/assist365/raw/smoke-20260929/`. No se cargaron datos a BigQuery. Los errores transitorios previos quedaron resueltos al reanudar la corrida. El perfil de siniestros encontró variaciones bilingües y 414 valores no finitos en campos anidados; están documentados en el README raíz para tratarlos al definir staging.
