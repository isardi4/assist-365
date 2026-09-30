"""Profile a completed raw run from GCS or an explicit local path."""

from __future__ import annotations

import argparse
import bisect
import collections
import gzip
import hashlib
import json
import math
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterator

from scripts.shared.common import ExtractionError, emit
from scripts.shared.artifacts import artifact_path, gcs_root


def load_manifest(run_dir: Path) -> dict[str, Any]:
    """Lee el manifiesto raw y exige que la captura esté completa antes de analizarla."""
    path = run_dir / "manifest.json"
    if not path.is_file():
        raise ExtractionError(f"No existe el manifiesto de origen: {path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("run_status") not in {"SUCCESS", "SUCCESS_WITH_QUARANTINE"}:
        raise ExtractionError("El perfil requiere una corrida completa.")
    return manifest


def read_resource_rows(
    run_dir: Path, resource: str, pages: list[dict[str, Any]],
) -> Iterator[dict[str, Any]]:
    """Lee las filas del recurso tras verificar la huella y el conteo de cada página."""
    for page in pages:
        path = run_dir / page["raw_file"]
        if not path.is_file():
            raise ExtractionError(f"Falta una página raw: {path}")
        try:
            body = gzip.decompress(path.read_bytes())
            payload = json.loads(body)
        except (OSError, EOFError, gzip.BadGzipFile, json.JSONDecodeError):
            raise ExtractionError(f"No se pudo leer la página gzip: {path}") from None
        if hashlib.sha256(body).hexdigest() != page.get("response_sha256"):
            raise ExtractionError(f"El checksum raw no coincide: {path}")
        rows = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(rows, list) or len(rows) != page.get("rows_received"):
            raise ExtractionError(f"El conteo raw no coincide: {path}")
        if any(not isinstance(row, dict) for row in rows):
            raise ExtractionError(f"La página contiene registros que no son objetos: {path}")
        yield from rows


def normalized_date(value: Any) -> str | None:
    """Interpreta una fecha o timestamp de origen y devuelve su día calendario UTC."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone(timezone.utc)
        return parsed.date().isoformat()
    except ValueError:
        try:
            return date.fromisoformat(value).isoformat()
        except ValueError:
            try:
                return datetime.strptime(value, "%d/%m/%Y").date().isoformat()
            except ValueError:
                return None


def type_name(value: Any) -> str:
    """Clasifica el tipo de un valor JSON sin incluir su contenido en el informe."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, float) and not math.isfinite(value):
        return "non_finite_number"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return type(value).__name__


def profile_run(run_dir: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    """Resume claves, operaciones, calidad y relaciones entre los recursos de la captura."""
    resources = manifest["resources"]
    profiles: dict[str, Any] = {}
    raw_shape: dict[str, dict[str, Any]] = {}

    def observe_shape(resource: str, row: dict[str, Any]) -> None:
        """Cuenta campos presentes, nulos, anidados y valores no finitos de las filas raw."""
        stats = raw_shape.setdefault(resource, {
            "rows": 0,
            "present": collections.Counter(),
            "null": collections.Counter(),
            "nested_present": collections.Counter(),
            "nested_null": collections.Counter(),
            "non_finite": collections.Counter(),
        })
        stats["rows"] += 1
        for key, value in row.items():
            stats["present"][key] += 1
            if value is None:
                stats["null"][key] += 1
            if isinstance(value, float) and not math.isfinite(value):
                stats["non_finite"][key] += 1
            if isinstance(value, dict):
                for nested_key, nested_value in value.items():
                    path = f"{key}.{nested_key}"
                    stats["nested_present"][path] += 1
                    if nested_value is None:
                        stats["nested_null"][path] += 1
                    if isinstance(nested_value, float) and not math.isfinite(nested_value):
                        stats["non_finite"][path] += 1

    product_ids: set[str] = set()
    for row in read_resource_rows(run_dir, "productos", resources["productos"]["pages"]):
        observe_shape("productos", row)
        if row.get("producto_id") is not None:
            product_ids.add(str(row["producto_id"]))
    agency_ids: set[str] = set()
    for row in read_resource_rows(run_dir, "agencias", resources["agencias"]["pages"]):
        observe_shape("agencias", row)
        if row.get("agencia_id") is not None:
            agency_ids.add(str(row["agencia_id"]))
    fx_pairs: set[tuple[str, str]] = set()
    fx_pair_counts: collections.Counter[tuple[str, str]] = collections.Counter()
    fx_rate_pairs_consistent = 0
    fx_rate_pairs_checked = 0
    fx_rate_pairs_invalid = 0
    fx_relation_by_currency: collections.Counter[tuple[str, str]] = collections.Counter()
    fx_currencies: collections.Counter[str] = collections.Counter()
    fx_dates_by_currency: dict[str, set[str]] = collections.defaultdict(set)
    for row in read_resource_rows(run_dir, "tipo_cambio", resources["tipo_cambio"]["pages"]):
        observe_shape("tipo_cambio", row)
        fx_date = normalized_date(row.get("fecha"))
        currency = row.get("moneda")
        if fx_date and isinstance(currency, str):
            pair = (fx_date, currency)
            fx_pairs.add(pair)
            fx_pair_counts[pair] += 1
            fx_currencies[currency] += 1
            fx_dates_by_currency[currency].add(fx_date)
        try:
            factor = Decimal(str(row["factor_usd"]))
            units = Decimal(str(row["unidades_por_usd"]))
            if not factor.is_finite() or not units.is_finite() or factor <= 0 or units <= 0:
                fx_rate_pairs_invalid += 1
                continue
            fx_rate_pairs_checked += 1
            if abs(factor * units - Decimal(1)) <= Decimal("0.000001"):
                fx_rate_pairs_consistent += 1
                fx_relation_by_currency[(currency, "reciprocal")] += 1
            else:
                fx_relation_by_currency[(currency, "not_reciprocal")] += 1
        except (KeyError, InvalidOperation, TypeError, ValueError):
            pass

    policy_ids: set[str] = set()
    inserted_ids: set[str] = set()
    policy_ops: dict[str, set[str]] = collections.defaultdict(set)
    policy_ops_counts: collections.Counter[str] = collections.Counter()
    policy_status_by_op: collections.Counter[tuple[str, str]] = collections.Counter()
    policy_currencies: collections.Counter[str] = collections.Counter()
    policy_issue_dates: collections.Counter[str] = collections.Counter()
    policy_fx_coverage = collections.Counter()
    missing_products: set[str] = set()
    missing_agencies: set[str] = set()
    missing_product_rows = 0
    missing_agency_rows = 0
    policy_rows = 0
    latest_policy_event: dict[str, tuple[str, str, str, str]] = {}
    latest_event_ties: set[str] = set()
    policy_missing_updated_at = 0
    sorted_fx_dates = {currency: sorted(days) for currency, days in fx_dates_by_currency.items()}

    def rate_coverage(day: str | None, currency: Any) -> str:
        """Clasifica la disponibilidad de cotización en la fecha indicada o en días anteriores."""
        if not day:
            return "invalid_date"
        if not isinstance(currency, str):
            return "invalid_currency"
        dates = sorted_fx_dates.get(currency, [])
        position = bisect.bisect_right(dates, day) - 1
        if position < 0:
            return "no_prior_rate"
        gap = (date.fromisoformat(day) - date.fromisoformat(dates[position])).days
        if gap == 0:
            return "exact"
        if gap <= 7:
            return "previous_1_to_7_days"
        if gap <= 30:
            return "previous_8_to_30_days"
        return "previous_over_30_days"
    for row in read_resource_rows(run_dir, "polizas", resources["polizas"]["pages"]):
        observe_shape("polizas", row)
        policy_rows += 1
        policy_id = row.get("poliza_id")
        operation = str(row.get("op"))
        status = str(row.get("estado"))
        policy_ops_counts[operation] += 1
        policy_status_by_op[(operation, status)] += 1
        if policy_id is not None:
            key = str(policy_id)
            policy_ids.add(key)
            policy_ops[key].add(operation)
            if operation == "I":
                inserted_ids.add(key)
            updated_at = row.get("updated_at")
            if not isinstance(updated_at, str) or not updated_at:
                policy_missing_updated_at += 1
            else:
                row_hash = hashlib.sha256(json.dumps(
                    row, ensure_ascii=False, sort_keys=True,
                    separators=(",", ":"), allow_nan=True,
                ).encode("utf-8")).hexdigest()
                current = latest_policy_event.get(key)
                candidate = (updated_at, operation, status, row_hash)
                if current is None or updated_at > current[0]:
                    latest_policy_event[key] = candidate
                    latest_event_ties.discard(key)
                elif updated_at == current[0] and row_hash != current[3]:
                    latest_event_ties.add(key)
        currency = row.get("moneda")
        if isinstance(currency, str):
            policy_currencies[currency] += 1
        if operation == "I":
            issue_date = normalized_date(row.get("fecha_emision_utc"))
            if issue_date:
                policy_issue_dates[issue_date] += 1
            policy_fx_coverage[rate_coverage(issue_date, currency)] += 1
        product_id = row.get("producto_id")
        if product_id is None or str(product_id) not in product_ids:
            missing_products.add(str(product_id))
            missing_product_rows += 1
        agency_id = row.get("agencia_id")
        if agency_id is None or str(agency_id) not in agency_ids:
            missing_agencies.add(str(agency_id))
            missing_agency_rows += 1

    claim_rows = 0
    claim_hashes: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    claim_statuses: collections.Counter[str] = collections.Counter()
    claim_types: collections.Counter[str] = collections.Counter()
    claim_currencies: collections.Counter[str] = collections.Counter()
    amount_value_types: collections.Counter[str] = collections.Counter()
    amount_value_parseable = 0
    amount_value_invalid = 0
    amount_value_non_finite = 0
    claim_policy_refs: set[str] = set()
    claims_with_null_policy = 0
    detail_shapes: collections.Counter[str] = collections.Counter()
    detail_value_types: collections.Counter[str] = collections.Counter()
    paid_claim_fx_coverage: collections.Counter[str] = collections.Counter()
    paid_claim_quality: collections.Counter[str] = collections.Counter()
    for row in read_resource_rows(run_dir, "siniestros", resources["siniestros"]["pages"]):
        observe_shape("siniestros", row)
        claim_rows += 1
        claim_id = row.get("claim_id")
        if claim_id is not None:
            canonical = json.dumps(row, ensure_ascii=False, sort_keys=True,
                                   separators=(",", ":"), allow_nan=True)
            claim_hashes[str(claim_id)][hashlib.sha256(canonical.encode("utf-8")).hexdigest()] += 1
        status = str(row.get("status"))
        claim_statuses[status] += 1
        claim_types[str(row.get("type"))] += 1
        policy_id = row.get("policy_id")
        if policy_id is None:
            claims_with_null_policy += 1
        else:
            claim_policy_refs.add(str(policy_id))
        amount = row.get("amount")
        if isinstance(amount, dict):
            currency = amount.get("currency")
            claim_currencies[type_name(currency) + (":" + currency if isinstance(currency, str) else "")] += 1
            raw_value = amount.get("value")
            amount_value_types[type_name(raw_value)] += 1
            try:
                parsed_amount = Decimal(str(raw_value))
                if parsed_amount.is_finite():
                    amount_value_parseable += 1
                else:
                    amount_value_non_finite += 1
            except (InvalidOperation, TypeError, ValueError):
                amount_value_invalid += 1
            if status == "PAGADO":
                claim_date = normalized_date(row.get("occurred_at"))
                paid_claim_quality["rows"] += 1
                if not claim_date:
                    paid_claim_quality["missing_or_invalid_occurred_at"] += 1
                if not isinstance(currency, str):
                    paid_claim_quality["invalid_currency"] += 1
                    if isinstance(currency, float) and not math.isfinite(currency):
                        paid_claim_quality["non_finite_currency"] += 1
                if claim_date and isinstance(currency, str):
                    paid_claim_quality["valid_date_and_currency"] += 1
                paid_claim_fx_coverage[rate_coverage(claim_date, currency)] += 1
        detail = row.get("detail")
        if isinstance(detail, dict):
            detail_shapes["|".join(sorted(detail))] += 1
            for key, value in detail.items():
                detail_value_types[f"{key}:{type_name(value)}"] += 1
        else:
            detail_shapes[type_name(detail)] += 1

    claim_duplicate_rows = claim_rows - len(claim_hashes)
    claim_conflicting_ids = sum(1 for hashes in claim_hashes.values() if len(hashes) > 1)
    exact_duplicate_rows = sum(sum(count - 1 for count in hashes.values())
                               for hashes in claim_hashes.values())
    policy_op_sets = collections.Counter("|".join(sorted(ops)) for ops in policy_ops.values())
    latest_operation_counts: collections.Counter[str] = collections.Counter()
    latest_status_counts: collections.Counter[str] = collections.Counter()
    current_live_operation_counts: collections.Counter[str] = collections.Counter()
    current_live_status_counts: collections.Counter[str] = collections.Counter()
    for policy_id, (_, operation, status, _) in latest_policy_event.items():
        if policy_id in latest_event_ties:
            continue
        latest_operation_counts[operation] += 1
        latest_status_counts[status] += 1
        if operation != "D":
            current_live_operation_counts[operation] += 1
            current_live_status_counts[status] += 1
    fx_duplicates = sum(count - 1 for count in fx_pair_counts.values())
    profiles["catalogs"] = {
        "product_rows": resources["productos"]["rows_received"],
        "unique_product_ids": len(product_ids),
        "agency_rows": resources["agencias"]["rows_received"],
        "unique_agency_ids": len(agency_ids),
        "exchange_rate_rows": resources["tipo_cambio"]["rows_received"],
        "unique_date_currency_pairs": len(fx_pairs),
        "duplicate_date_currency_rows": fx_duplicates,
        "exchange_rate_currencies": dict(fx_currencies),
        "exchange_rate_date_range_by_currency": {
            currency: [min(days), max(days)] for currency, days in fx_dates_by_currency.items()
        },
        "reciprocal_rate_pairs_consistent": fx_rate_pairs_consistent,
        "reciprocal_rate_pairs_checked": fx_rate_pairs_checked,
        "invalid_or_nonpositive_rate_pairs": fx_rate_pairs_invalid,
        "factor_vs_units_reciprocal_check_by_currency": {
            f"{currency}:{result}": count
            for (currency, result), count in fx_relation_by_currency.items()
        },
    }
    profiles["polizas"] = {
        "event_rows": policy_rows,
        "unique_policy_ids": len(policy_ids),
        "insert_event_ids": len(inserted_ids),
        "operation_counts": dict(policy_ops_counts),
        "operation_combinations_per_policy_id": dict(policy_op_sets),
        "latest_event_operation_counts_excluding_timestamp_ties": dict(latest_operation_counts),
        "latest_event_status_counts_including_tombstones": dict(latest_status_counts),
        "live_policy_operation_counts_excluding_tombstones_and_ties": dict(current_live_operation_counts),
        "live_policy_business_status_counts_excluding_tombstones_and_ties": dict(current_live_status_counts),
        "latest_timestamp_tie_policy_ids": len(latest_event_ties),
        "rows_missing_updated_at": policy_missing_updated_at,
        "status_by_operation": {f"{op}:{status}": count
                                for (op, status), count in policy_status_by_op.items()},
        "currencies_by_event": dict(policy_currencies),
        "issue_event_date_range": [min(policy_issue_dates), max(policy_issue_dates)]
            if policy_issue_dates else None,
        "issue_event_exchange_rate_availability": dict(policy_fx_coverage),
        "event_rows_missing_product_reference": missing_product_rows,
        "distinct_missing_product_reference_values": len(missing_products),
        "event_rows_missing_agency_reference": missing_agency_rows,
        "distinct_missing_agency_reference_values": len(missing_agencies),
    }
    profiles["siniestros"] = {
        "source_rows": claim_rows,
        "unique_claim_ids": len(claim_hashes),
        "duplicate_rows_by_claim_id": claim_duplicate_rows,
        "exact_duplicate_rows": exact_duplicate_rows,
        "claim_ids_with_conflicting_payloads": claim_conflicting_ids,
        "status_counts": dict(claim_statuses),
        "type_counts": dict(claim_types),
        "amount_currency_types": dict(claim_currencies),
        "amount_value_types": dict(amount_value_types),
        "amount_values_decimal_parseable": amount_value_parseable,
        "amount_values_decimal_invalid": amount_value_invalid,
        "amount_values_non_finite": amount_value_non_finite,
        "detail_shapes": dict(detail_shapes),
        "detail_value_types": dict(detail_value_types),
        "null_policy_reference_rows": claims_with_null_policy,
        "unique_policy_references_not_found": len(claim_policy_refs - policy_ids),
        "paid_claim_quality": dict(paid_claim_quality),
        "paid_claim_exchange_rate_availability": dict(paid_claim_fx_coverage),
    }
    profiles["raw_field_quality"] = {
        resource: {
            "rows": stats["rows"],
            "top_level_fields_absent_from_some_rows": {
                field: stats["rows"] - count
                for field, count in stats["present"].items()
                if stats["rows"] != count
            },
            "top_level_explicit_null_counts": dict(stats["null"]),
            "nested_field_presence_counts": dict(stats["nested_present"]),
            "nested_explicit_null_counts": dict(stats["nested_null"]),
            "non_finite_number_counts": dict(stats["non_finite"]),
        }
        for resource, stats in raw_shape.items()
    }
    return {
        "run_id": manifest["run_id"],
        "profiled_at_utc": datetime.now(timezone.utc).isoformat(),
        "raw_run_status": manifest["run_status"],
        "local_only": True,
        "resources": profiles,
        "limitations": [
            "Profile counts describe this run_id only; they do not establish incremental behavior.",
            "The profile summarizes latest policy events but does not replace the SQL state view or apply daily ABM.",
            "Missing policy references are counted without dropping claim records.",
        ],
    }


def parse_args() -> argparse.Namespace:
    """Lee la ruta raw local o GCS y el destino opcional del informe."""
    parser = argparse.ArgumentParser(description="Profile verified raw files from GCS or a local directory.")
    parser.add_argument("run_dir", type=artifact_path, help="GCS prefix or local directory containing manifest.json")
    parser.add_argument("--output", type=artifact_path,
                        help="Profile JSON path; defaults under gcs_root/profiles/")
    return parser.parse_args()


def main() -> int:
    """Valida las páginas raw y genera un informe del contenido de la captura."""
    args = parse_args()
    try:
        manifest = load_manifest(args.run_dir)
        profile = profile_run(args.run_dir, manifest)
        output = args.output or artifact_path(gcs_root()) / "profiles" / manifest["run_id"] / "data_profile.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
        emit("local_data_profile_complete", run_id=manifest["run_id"],
             output=str(output), resources=len(profile["resources"]))
        return 0
    except Exception as exc:
        emit("local_data_profile_failed", error_class=type(exc).__name__,
             message=str(exc)[:300])
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
