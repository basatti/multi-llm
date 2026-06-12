#!/usr/bin/env python3
"""Manifest <-> gateway route consistency check.

Enforces the atomic-PR rule (models/README.md): a gateway route pointing at a
local model that is not defined in models/manifest.yaml cannot merge.

Checks:
  1. models/manifest.yaml validates against models/schema.json.
  2. Every model_list entry in every gateway config has model_info.source
     (local | frontier).
  3. Entries with source: local have a manifest_id resolving to a model or
     adapter id in the manifest.
  4. Manifest ids routed nowhere produce a warning only (staged rollout).
  5. Lifecycle rule (architecture.md section 5.1): every logical name backed by
     a local model must have a fallback chain — soft-disabling a local backend
     with no fallback is an outage. Frontier-primary names are exempt (the
     frontier already is the fallback tier). Fallback targets must exist.

Exit 0 on success, 1 on any error. Deps: pyyaml, jsonschema.
"""

import sys
from pathlib import Path

import jsonschema
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "models" / "manifest.yaml"
SCHEMA = REPO_ROOT / "models" / "schema.json"
GATEWAY_CONFIGS = sorted((REPO_ROOT / "gateway" / "config").glob("*.yaml"))

VALID_SOURCES = {"local", "frontier"}


def load_yaml(path: Path):
    with path.open() as f:
        return yaml.safe_load(f)


def manifest_ids(manifest: dict) -> set[str]:
    ids = set()
    for model in manifest.get("models", []):
        ids.add(model["id"])
        for adapter in model.get("adapters", []):
            ids.add(adapter["id"])
    return ids


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    manifest = load_yaml(MANIFEST)
    schema = yaml.safe_load(SCHEMA.read_text())
    try:
        jsonschema.validate(manifest, schema)
    except jsonschema.ValidationError as e:
        print(f"ERROR: {MANIFEST.relative_to(REPO_ROOT)} fails schema: {e.message}")
        return 1

    known_ids = manifest_ids(manifest)
    routed_ids: set[str] = set()

    if not GATEWAY_CONFIGS:
        print("ERROR: no gateway configs found under gateway/config/")
        return 1

    for config_path in GATEWAY_CONFIGS:
        rel = config_path.relative_to(REPO_ROOT)
        config = load_yaml(config_path)
        local_names: set[str] = set()
        all_names: set[str] = set()

        for entry in config.get("model_list", []):
            name = entry.get("model_name", "<unnamed>")
            all_names.add(name)
            info = entry.get("model_info") or {}
            source = info.get("source")
            if source not in VALID_SOURCES:
                errors.append(
                    f"{rel}: '{name}' missing model_info.source "
                    f"(must be one of {sorted(VALID_SOURCES)})"
                )
                continue
            if source == "local":
                local_names.add(name)
                manifest_id = info.get("manifest_id")
                if not manifest_id:
                    errors.append(f"{rel}: local route '{name}' missing model_info.manifest_id")
                elif manifest_id not in known_ids:
                    errors.append(
                        f"{rel}: local route '{name}' references manifest_id "
                        f"'{manifest_id}' not present in models/manifest.yaml"
                    )
                else:
                    routed_ids.add(manifest_id)

        fallbacks: dict[str, list[str]] = {}
        for item in (config.get("router_settings") or {}).get("fallbacks", []):
            for logical, targets in item.items():
                fallbacks[logical] = targets or []

        for name in sorted(local_names):
            if not fallbacks.get(name):
                errors.append(
                    f"{rel}: local-backed logical name '{name}' has no fallback chain "
                    f"(soft-disable would be an outage — architecture.md section 5.1)"
                )

        for logical, targets in sorted(fallbacks.items()):
            if logical not in all_names:
                errors.append(f"{rel}: fallback source '{logical}' is not a defined model_name")
            for target in targets:
                if target not in all_names:
                    errors.append(
                        f"{rel}: fallback target '{target}' (for '{logical}') "
                        f"is not a defined model_name"
                    )

    for unrouted in sorted(known_ids - routed_ids):
        warnings.append(f"manifest id '{unrouted}' has no gateway route (ok during staged rollout)")

    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors:
        print(f"ERROR: {e}")

    if errors:
        return 1
    print(f"OK: {len(GATEWAY_CONFIGS)} gateway config(s) consistent with manifest ({len(known_ids)} ids)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
