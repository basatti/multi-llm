#!/bin/bash
# First-boot bootstrap. DLAMI ships docker + nvidia drivers; we configure the
# runtime, write compose + env, bring it up, register the apps, and write
# their virtual keys to SSM.
#
# Escaping rule: terraform's templatefile substitutes $${name} blocks (which
# render to dollar-curly-name) at render time. Plain $VAR and $(cmd) pass
# through to the shell unchanged. To produce a literal dollar-curly in the
# rendered output (for compose interpolation), use $$$${name}.
#
# Logs: /var/log/llm-bootstrap.log on the instance.
set -euo pipefail
exec > >(tee /var/log/llm-bootstrap.log) 2>&1

REGION="${region}"
ENV_NAME="${env_name}"
ACCOUNT_ID="${account_id}"
ORCH_IMAGE="${orchestration_image}"
PUBLIC_DNS_NAME="${public_dns_name}"
APPS_JSON='${apps}'

echo "[boot] region=$REGION env=$ENV_NAME instance=$(hostname) public=$PUBLIC_DNS_NAME"

# ── docker + nvidia runtime ─────────────────────────────────────────────────
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF
systemctl restart docker
systemctl enable docker

if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker-compose-plugin jq
fi
apt-get install -y jq >/dev/null 2>&1 || true

# ── ECR login ────────────────────────────────────────────────────────────────
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# ── secrets from SSM ────────────────────────────────────────────────────────
fetch_param() {
  aws ssm get-parameter --region "$REGION" --with-decryption \
    --name "/llm-platform/$ENV_NAME/$1" --query 'Parameter.Value' --output text
}
LITELLM_MASTER_KEY=$(fetch_param litellm-master-key)
POSTGRES_PASSWORD=$(fetch_param postgres-password)
LANGFUSE_PUBLIC_KEY=$(fetch_param langfuse-public-key)
LANGFUSE_SECRET_KEY=$(fetch_param langfuse-secret-key)
LANGFUSE_SALT=$(fetch_param langfuse-salt)
LANGFUSE_ENCRYPTION_KEY_RAW=$(fetch_param langfuse-encryption-key)
# Langfuse expects 64 hex chars — hex-encode the random 32-char value.
LANGFUSE_ENCRYPTION_KEY=$(printf '%s' "$LANGFUSE_ENCRYPTION_KEY_RAW" | od -An -tx1 -v | tr -d ' \n' | cut -c1-64)
LANGFUSE_NEXTAUTH_SECRET=$(fetch_param langfuse-nextauth-secret)
LANGFUSE_INIT_USER_PASSWORD=$(fetch_param langfuse-init-user-password)
CLICKHOUSE_PASSWORD=$(fetch_param clickhouse-password)
MINIO_ROOT_PASSWORD=$(fetch_param minio-root-password)

# ── lay down configs ────────────────────────────────────────────────────────
install -d -m 0755 /opt/llm-platform/gateway/config /opt/llm-platform/postgres-init

cat >/opt/llm-platform/postgres-init/00-databases.sql <<'EOF'
CREATE DATABASE langfuse;
CREATE DATABASE orchestration;
EOF

cat >/opt/llm-platform/gateway/config/config.cloud.yaml <<'GW_EOF'
# Three real-named models served by Ollama on the same T4. Apps pass these
# names in the OpenAI `model` field; virtual keys are scoped to one (or more)
# at the LiteLLM admin layer. Each route falls back to a peer so requests
# during a model-swap or warmup don't fail.
model_list:
  - model_name: llama3.1
    litellm_params:
      model: openai/llama3.1:8b
      api_base: http://ollama:11434/v1
      api_key: ollama
      timeout: 300
    model_info:
      source: local
      manifest_id: llama3.1-8b

  - model_name: gemma4
    litellm_params:
      model: openai/gemma4:latest
      api_base: http://ollama:11434/v1
      api_key: ollama
      timeout: 300
    model_info:
      source: local
      manifest_id: gemma4-latest

  - model_name: qwen2.5-coder
    litellm_params:
      model: openai/qwen2.5-coder:7b
      api_base: http://ollama:11434/v1
      api_key: ollama
      timeout: 300
    model_info:
      source: local
      manifest_id: qwen2.5-coder-7b

router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  num_retries: 1
  fallbacks:
    - llama3.1: ["gemma4"]
    - gemma4: ["llama3.1"]
    - qwen2.5-coder: ["llama3.1"]

litellm_settings:
  drop_params: true
  request_timeout: 300

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: false
GW_EOF

# Compose file: written with a quoted heredoc so shell does NOT expand $${VAR};
# compose expands them from /opt/llm-platform/.env at `docker compose up`.
cat >/opt/llm-platform/docker-compose.yml <<'COMPOSE_EOF'
services:
  ollama:
    image: ollama/ollama:latest
    runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    environment:
      # Keep a model in VRAM for 5 min after last use; only one model loaded at
      # a time on a T4 (16 GB). Adjust if upgrading to a bigger GPU.
      OLLAMA_KEEP_ALIVE: 5m
      OLLAMA_NUM_PARALLEL: 1
      OLLAMA_MAX_LOADED_MODELS: 1
    volumes:
      - ollama-data:/root/.ollama
    healthcheck:
      test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s
    restart: unless-stopped

  litellm:
    image: ghcr.io/berriai/litellm:main-stable@sha256:60372ab3075280b4b58c16b0f9c711eb1ff23a746df2add9b85ec2a559e9a1ef
    command: ["--config", "/etc/litellm/config.cloud.yaml", "--port", "4000"]
    ports:
      - "4000:4000"
    environment:
      LITELLM_MASTER_KEY: $${LITELLM_MASTER_KEY}
      DATABASE_URL: postgresql://platform:$${POSTGRES_PASSWORD}@postgres:5432/litellm
      REDIS_HOST: redis
      REDIS_PORT: "6379"
    volumes:
      - /opt/llm-platform/gateway/config:/etc/litellm:ro
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
      ollama:
        condition: service_started
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: platform
      POSTGRES_PASSWORD: $${POSTGRES_PASSWORD}
      POSTGRES_DB: litellm
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - /opt/llm-platform/postgres-init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U platform"]
      interval: 2s
      timeout: 3s
      retries: 30
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    restart: unless-stopped

  clickhouse:
    image: clickhouse/clickhouse-server:24.3
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: $${CLICKHOUSE_PASSWORD}
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    volumes:
      - clickhouse-data:/var/lib/clickhouse
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:8123/ping || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 30
    mem_limit: 3g
    restart: unless-stopped

  minio:
    image: minio/minio:RELEASE.2024-08-29T01-40-52Z
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: langfuse-minio
      MINIO_ROOT_PASSWORD: $${MINIO_ROOT_PASSWORD}
    volumes:
      - minio-data:/data
    healthcheck:
      test: ["CMD-SHELL", "mc ready local || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 30
    restart: unless-stopped

  langfuse-worker:
    image: langfuse/langfuse-worker:3
    depends_on:
      postgres:
        condition: service_healthy
      clickhouse:
        condition: service_healthy
      minio:
        condition: service_healthy
      redis:
        condition: service_started
    environment: &langfuse-env
      DATABASE_URL: postgresql://platform:$${POSTGRES_PASSWORD}@postgres:5432/langfuse
      SALT: $${LANGFUSE_SALT}
      ENCRYPTION_KEY: $${LANGFUSE_ENCRYPTION_KEY}
      TELEMETRY_ENABLED: "false"
      LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES: "false"
      CLICKHOUSE_URL: http://clickhouse:8123
      CLICKHOUSE_MIGRATION_URL: clickhouse://clickhouse:9000
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: $${CLICKHOUSE_PASSWORD}
      CLICKHOUSE_CLUSTER_ENABLED: "false"
      LANGFUSE_S3_EVENT_UPLOAD_BUCKET: langfuse
      LANGFUSE_S3_EVENT_UPLOAD_REGION: auto
      LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: langfuse-minio
      LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: $${MINIO_ROOT_PASSWORD}
      LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: http://minio:9000
      LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_S3_EVENT_UPLOAD_PREFIX: events/
      REDIS_HOST: redis
      REDIS_PORT: "6379"
    mem_limit: 2g
    restart: unless-stopped

  langfuse-web:
    image: langfuse/langfuse:3
    depends_on:
      langfuse-worker:
        condition: service_started
    ports:
      - "3000:3000"
    environment:
      <<: *langfuse-env
      NEXTAUTH_URL: http://localhost:3000
      NEXTAUTH_SECRET: $${LANGFUSE_NEXTAUTH_SECRET}
      LANGFUSE_INIT_ORG_ID: onetechhub
      LANGFUSE_INIT_ORG_NAME: 1TechHub
      LANGFUSE_INIT_PROJECT_ID: llm-platform
      LANGFUSE_INIT_PROJECT_NAME: llm-platform
      LANGFUSE_INIT_PROJECT_PUBLIC_KEY: $${LANGFUSE_PUBLIC_KEY}
      LANGFUSE_INIT_PROJECT_SECRET_KEY: $${LANGFUSE_SECRET_KEY}
      LANGFUSE_INIT_USER_EMAIL: admin@onetechhub.local
      LANGFUSE_INIT_USER_NAME: admin
      LANGFUSE_INIT_USER_PASSWORD: $${LANGFUSE_INIT_USER_PASSWORD}
    mem_limit: 2g
    restart: unless-stopped

  orchestration:
    image: $${ORCH_IMAGE}
    ports:
      - "8000:8000"
    environment:
      ORCH_GATEWAY_BASE_URL: http://litellm:4000
      ORCH_GATEWAY_VIRTUAL_KEY: $${LITELLM_MASTER_KEY}
      ORCH_GATEWAY_ADMIN_KEY: $${LITELLM_MASTER_KEY}
      ORCH_REDIS_URL: redis://redis:6379/0
      ORCH_DATABASE_URL: postgresql://platform:$${POSTGRES_PASSWORD}@postgres:5432/orchestration
      ORCH_LANGFUSE_HOST: http://langfuse-web:3000
      ORCH_LANGFUSE_PUBLIC_KEY: $${LANGFUSE_PUBLIC_KEY}
      ORCH_LANGFUSE_SECRET_KEY: $${LANGFUSE_SECRET_KEY}
    depends_on:
      litellm:
        condition: service_started
      langfuse-web:
        condition: service_started
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    restart: unless-stopped

volumes:
  ollama-data:
  postgres-data:
  clickhouse-data:
  minio-data:
COMPOSE_EOF

cat >/opt/llm-platform/.env <<EOF
ORCH_IMAGE=$ORCH_IMAGE
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
LANGFUSE_PUBLIC_KEY=$LANGFUSE_PUBLIC_KEY
LANGFUSE_SECRET_KEY=$LANGFUSE_SECRET_KEY
LANGFUSE_SALT=$LANGFUSE_SALT
LANGFUSE_ENCRYPTION_KEY=$LANGFUSE_ENCRYPTION_KEY
LANGFUSE_NEXTAUTH_SECRET=$LANGFUSE_NEXTAUTH_SECRET
LANGFUSE_INIT_USER_PASSWORD=$LANGFUSE_INIT_USER_PASSWORD
CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
EOF
chmod 0600 /opt/llm-platform/.env

# ── pull + up ───────────────────────────────────────────────────────────────
cd /opt/llm-platform
docker compose pull
docker compose up -d

# Pre-pull Ollama models so the first app request doesn't trigger a slow
# initial download. Three models, ~5–10 GB each — total ~25 GB / ~10–15 min
# on first boot. Idempotent across reboots (cache lives on the ollama-data
# volume).
echo "[ollama] waiting for service before pulling models"
for i in $(seq 1 30); do
  if docker exec llm-platform-ollama-1 ollama list >/dev/null 2>&1; then break; fi
  sleep 5
done
echo "[ollama] pulling models"
docker exec llm-platform-ollama-1 ollama pull llama3.1:8b
docker exec llm-platform-ollama-1 ollama pull gemma4:latest
docker exec llm-platform-ollama-1 ollama pull qwen2.5-coder:7b
docker exec llm-platform-ollama-1 ollama list

# ── wait for orchestration ──────────────────────────────────────────────────
echo "[wait] orchestration /healthz"
for i in $(seq 1 60); do
  if curl -sf http://localhost:8000/healthz >/dev/null 2>&1; then break; fi
  sleep 5
done

echo "[wait] orchestration /readyz (gateway must be up, which requires vllm)"
for i in $(seq 1 180); do
  body=$(curl -s http://localhost:8000/readyz || echo "{}")
  echo "  $i: $body"
  if echo "$body" | grep -q '"gateway":"ok"'; then break; fi
  sleep 10
done

# ── register apps + emit virtual keys to SSM ────────────────────────────────
echo "[register] apps"
echo "$APPS_JSON" | jq -c '.[]' | while read -r app; do
  app_id=$(echo "$app" | jq -r '.id')
  echo "  $app_id"
  payload=$(echo "$app" | jq '{app_id: .id, owner, cost_center, models, max_budget: 200, budget_duration: "30d", agent_config: {logical_model: .primary_model}}')
  resp=$(curl -sf -X POST http://localhost:8000/v1/apps -H "Content-Type: application/json" -d "$payload" || echo "")
  if [ -z "$resp" ]; then
    echo "    register failed"
    continue
  fi
  vk=$(echo "$resp" | jq -r '.virtual_key')
  aws ssm put-parameter --region "$REGION" \
    --name "/llm-platform/$ENV_NAME/apps/$app_id/api_key" \
    --type SecureString --value "$vk" --overwrite >/dev/null
  echo "    OK key in SSM"
done

echo "[boot] done. gateway: https://$PUBLIC_DNS_NAME"
