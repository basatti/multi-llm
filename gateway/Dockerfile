# Gateway image: pinned LiteLLM proxy.
#
# SUPPLY-CHAIN POLICY (architecture.md §5.2/§10):
# A supply-chain attack compromised LiteLLM releases 1.82.7/1.82.8 on PyPI in
# March 2026 (first clean release: 1.83.0). The gateway holds all real provider
# credentials — it is the highest-value target in the platform. Therefore:
#
#   1. Pin an exact, audited tag — never `main`, never `latest`.
#   2. Pin the image DIGEST after first verified pull. Resolve it with:
#        docker buildx imagetools inspect ghcr.io/berriai/litellm:v1.83.0-stable
#      then append `@sha256:<digest>` to the FROM line below and commit.
#   3. On every upgrade: review the dependency diff (release notes + lockfile
#      diff) before bumping the tag, then re-pin the new digest.
#
# TODO(pin-digest): append @sha256:<digest> after the first verified pull.
FROM ghcr.io/berriai/litellm:v1.83.0-stable

COPY config/ /etc/litellm/

# Config file is selected at runtime: /etc/litellm/config.yaml (AWS) or
# /etc/litellm/config.local.yaml (compose harness) via the --config arg.
CMD ["--config", "/etc/litellm/config.yaml", "--port", "4000"]
