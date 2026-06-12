# Model manifest

`manifest.yaml` maps every physical model and LoRA adapter the inference layer
serves: id → weights (S3) → quantization → instance class → replica policy.
`schema.json` is its JSON Schema; CI validates the manifest against it.

## Semantics

- **`models[].id`** — the physical model id. Gateway routes reference it via
  `model_info.manifest_id` in `gateway/config/config.yaml`.
- **`adapters[].id`** — LoRA adapters served on the parent base via vLLM
  multi-LoRA. Adapters are routable the same way: a logical gateway model may
  resolve to an adapter id (dozens of logical "models" per GPU, architecture.md §4.2).
- **`revision`** — immutable checksum/sha of the weights. Changing weights means
  changing the revision; deploys are content-addressed, never "latest".
- **`replicas.min >= 1` when `scale_to_zero: false`** — the warm-minimum rule
  (§4.3). Scale-to-zero is allowed only for low-traffic async-tier models.

## The atomic-PR rule

Adding/changing a model is **one PR** touching both:

1. `models/manifest.yaml` — the physical deployment definition.
2. `gateway/config/config.yaml` — the logical route(s) that resolve to it.

`scripts/validate_routes.py` (run by `.github/workflows/config-validation.yml`
and `make validate`) fails the PR if a route references a `manifest_id` that
does not exist here. Manifest entries with no route only produce a warning —
allowed during staged rollout.

Zero product code changes are required for any of this: products only know
logical model names.
