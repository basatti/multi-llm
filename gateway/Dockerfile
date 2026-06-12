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
# Pinned by digest below — the human-readable tag (BerriAI publishes `main-stable`
# from the LiteLLM repo's stable channel) is recorded for readability, but the
# digest is the actual immutable pin. Re-resolve the digest on every upgrade with:
#   docker manifest inspect ghcr.io/berriai/litellm:main-stable | grep digest
# then commit the new value.
FROM ghcr.io/berriai/litellm:main-stable@sha256:60372ab3075280b4b58c16b0f9c711eb1ff23a746df2add9b85ec2a559e9a1ef

COPY config/ /etc/litellm/

# Config file is selected at runtime: /etc/litellm/config.yaml (AWS) or
# /etc/litellm/config.local.yaml (compose harness) via the --config arg.
CMD ["--config", "/etc/litellm/config.yaml", "--port", "4000"]
