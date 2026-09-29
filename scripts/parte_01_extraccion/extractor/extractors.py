"""Resource-specific catalog, cursor, and offset extraction workflows."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ...shared.common import ExtractionError, emit
from .storage import (
    commit_page,
    fetch_and_save_page,
    finish_resource,
    persist_page,
    report_schema_changes,
    save_manifest,
)


def extract_catalog(
    resource: str, client: Any, run_dir: Path, manifest_path: Path,
    error_path: Path, manifest: dict[str, Any], max_pages: int | None,
) -> None:
    """Download and reconcile one complete, non-paginated catalog."""
    state = manifest["resources"][resource]
    if state["complete"]:
        return
    if state["pages"]:
        finish_resource(manifest_path, manifest, resource, True)
        return
    position = {"catalog_type": resource}
    body, raw_path = fetch_and_save_page(
        client, "catalogos", {"tipo": resource}, run_dir, manifest_path,
        manifest, resource, 1, position,
    )
    try:
        payload = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ExtractionError(f"JSON inválido en catálogo {resource}; respuesta cruda preservada.") from None
    page, invalid_rows = persist_page(body, payload, raw_path, run_dir, manifest,
                                      resource, 1, position)
    meta = payload.get("meta") if isinstance(payload, dict) else None
    total = meta.get("total") if isinstance(meta, dict) else None
    if total is not None and total != page["rows_received"]:
        raise ExtractionError(f"El total de {resource} no coincide con las filas recibidas.")
    state.pop("in_progress", None)
    commit_page(page, invalid_rows, error_path, manifest_path, manifest, resource)
    finish_resource(manifest_path, manifest, resource, True)
    emit("resource_complete", run_id=manifest["run_id"], resource=resource,
         pages=state["pages_saved"], rows=state["rows_received"])


def extract_policies(
    client: Any, run_dir: Path, manifest_path: Path, error_path: Path,
    manifest: dict[str, Any], max_pages: int | None,
) -> None:
    """Follow policy cursors until exhausted, detecting repeats and schema drift."""
    resource = "polizas"
    state = manifest["resources"][resource]
    if state["complete"]:
        return
    cursor = state.get("next_cursor")
    seen_cursors = {p.get("next_cursor") for p in state["pages"] if p.get("next_cursor")}
    page_number = state["pages_saved"] + 1
    pages_this_invocation = 0
    while True:
        if max_pages is not None and pages_this_invocation >= max_pages:
            finish_resource(manifest_path, manifest, resource, False)
            return
        if cursor and cursor in {p.get("request_cursor") for p in state["pages"]}:
            raise ExtractionError("El cursor de pólizas se repitió; se detiene para evitar un loop.")
        params = {"cursor": cursor} if cursor else {}
        position = {"request_cursor": cursor}
        body, raw_path = fetch_and_save_page(
            client, resource, params, run_dir, manifest_path, manifest,
            resource, page_number, position,
        )
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise ExtractionError(f"JSON inválido en pólizas, página {page_number}; raw preservado.") from None
        page, invalid_rows = persist_page(body, payload, raw_path, run_dir, manifest,
                                          resource, page_number, position)
        report_schema_changes(manifest, resource, page)
        pagination = payload.get("pagination") if isinstance(payload, dict) else None
        if not isinstance(pagination, dict) or not isinstance(pagination.get("has_more"), bool):
            raise ExtractionError(f"Falta paginación válida en pólizas, página {page_number}.")
        next_cursor = pagination.get("next_cursor")
        has_more = pagination["has_more"]
        if has_more and (not isinstance(next_cursor, str) or not next_cursor):
            raise ExtractionError(f"has_more=true sin next_cursor en pólizas, página {page_number}.")
        if has_more and page["rows_received"] == 0:
            raise ExtractionError(f"Página vacía con has_more=true en pólizas, página {page_number}.")
        if isinstance(next_cursor, str) and next_cursor in seen_cursors:
            raise ExtractionError("La API devolvió un next_cursor repetido; se detiene para evitar un loop.")
        page["next_cursor"] = next_cursor
        page["has_more"] = has_more
        state["next_cursor"] = next_cursor
        state.pop("in_progress", None)
        commit_page(page, invalid_rows, error_path, manifest_path, manifest, resource)
        pages_this_invocation += 1
        emit("page_saved", run_id=manifest["run_id"], resource=resource,
             page=page_number, rows=page["rows_received"], bytes=page["response_bytes"])
        if not has_more:
            finish_resource(manifest_path, manifest, resource, True)
            emit("resource_complete", run_id=manifest["run_id"], resource=resource,
                 pages=state["pages_saved"], rows=state["rows_received"])
            return
        seen_cursors.add(next_cursor)
        cursor = next_cursor
        page_number += 1


def extract_claims(
    client: Any, run_dir: Path, manifest_path: Path, error_path: Path,
    manifest: dict[str, Any], max_pages: int | None,
) -> None:
    """Read siniestros in fixed offsets and reconcile page counts to source total."""
    resource = "siniestros"
    state = manifest["resources"][resource]
    if state["complete"]:
        return
    offset = state.get("next_offset", 0)
    expected_total = state.get("expected_total")
    expected_limit = state.get("page_limit")
    page_number = state["pages_saved"] + 1
    pages_this_invocation = 0
    while True:
        if max_pages is not None and pages_this_invocation >= max_pages:
            finish_resource(manifest_path, manifest, resource, False)
            return
        position = {"request_offset": offset}
        body, raw_path = fetch_and_save_page(
            client, resource, {"offset": offset, "limit": 500}, run_dir,
            manifest_path, manifest, resource, page_number, position,
        )
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise ExtractionError(f"JSON inválido en siniestros, offset {offset}; raw preservado.") from None
        page, invalid_rows = persist_page(body, payload, raw_path, run_dir, manifest,
                                          resource, page_number, position)
        report_schema_changes(manifest, resource, page)
        meta = payload.get("meta") if isinstance(payload, dict) else None
        if not isinstance(meta, dict) or not all(k in meta for k in ("offset", "limit", "total")):
            raise ExtractionError(f"Meta incompleta en siniestros, offset {offset}.")
        if type(meta["offset"]) is not int or meta["offset"] != offset:
            raise ExtractionError(f"Offset inesperado en siniestros: pedido {offset}, recibido {meta['offset']}.")
        if type(meta["limit"]) is not int or meta["limit"] <= 0:
            raise ExtractionError(f"Limit inválido en siniestros, offset {offset}.")
        if type(meta["total"]) is not int or meta["total"] < 0:
            raise ExtractionError(f"Total inválido en siniestros, offset {offset}.")
        if expected_total is not None and meta["total"] != expected_total:
            raise ExtractionError("El total de siniestros cambió durante la extracción.")
        if expected_limit is not None and meta["limit"] != expected_limit:
            raise ExtractionError("El tamaño de página de siniestros cambió durante la extracción.")
        expected_total, expected_limit = meta["total"], meta["limit"]
        rows = page["rows_received"]
        if rows > expected_limit or (offset + rows < expected_total and rows != expected_limit):
            raise ExtractionError(f"Página incompleta o sobredimensionada de siniestros en offset {offset}.")
        page["source_total"] = expected_total
        page["source_limit"] = expected_limit
        next_offset = offset + rows
        if next_offset >= expected_total and state["rows_received"] + rows != expected_total:
            raise ExtractionError(
                "Conciliación de siniestros falló antes de confirmar la página: "
                f"recibidas {state['rows_received'] + rows}, esperadas {expected_total}."
            )
        state["expected_total"] = expected_total
        state["page_limit"] = expected_limit
        state["next_offset"] = next_offset
        state.pop("in_progress", None)
        commit_page(page, invalid_rows, error_path, manifest_path, manifest, resource)
        pages_this_invocation += 1
        emit("page_saved", run_id=manifest["run_id"], resource=resource,
             page=page_number, offset=offset, rows=rows,
             bytes=page["response_bytes"], total=expected_total)
        if next_offset >= expected_total:
            finish_resource(manifest_path, manifest, resource, True)
            emit("resource_complete", run_id=manifest["run_id"], resource=resource,
                 pages=state["pages_saved"], rows=state["rows_received"])
            return
        offset = next_offset
        page_number += 1
