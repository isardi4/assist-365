# Parte 1 — Extracción

- `api/`: cliente HTTP, token, TLS y primitivas compartidas.
- `extractor/`: paginación, checkpoints, raw local, manifiesto y ledger de errores.
- `run.py`: punto de entrada. Desde la raíz: `python3 -m scripts.parte_01_extraccion.run`.

La extracción local `smoke-20260929` terminó en `SUCCESS`: 1.003.461 pólizas en 1.004 páginas, 138.962 siniestros en 278 páginas, 300 agencias, 12 productos y 5.124 tipos de cambio. Las 1.147.859 filas se conservaron sin cuarentena en archivos gzip, con manifiesto y ledger bajo `.local_data/assist365/raw/smoke-20260929/`. No se cargaron datos a BigQuery. Los errores transitorios previos quedaron resueltos al reanudar la corrida. El perfil de siniestros encontró variaciones bilingües y 414 valores no finitos en campos anidados; están documentados en el README raíz para tratarlos al definir staging.
