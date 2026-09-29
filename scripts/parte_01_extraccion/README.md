# Parte 1 — Extracción

- `api/`: cliente HTTP, token, TLS y primitivas compartidas.
- `extractor/`: paginación, checkpoints, raw local, manifiesto y ledger de errores.
- `run.py`: punto de entrada. Desde la raíz: `python3 -m scripts.parte_01_extraccion.run`.

La prueba local acumuló 7 GET sin reintentos: catálogos completos (12 productos, 300 agencias y 5.124 tipos de cambio) y dos páginas cada una de pólizas (2.000 filas) y siniestros (1.000 de 138.962 informadas). El manifiesto `smoke-20260929` queda parcial y es reanudable; la descarga completa de siniestros supone unas 278 páginas.
