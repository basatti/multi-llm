# Self-hosted GPU deployment

Bring the whole platform up on any Linux host with an NVIDIA GPU — bare metal,
on-prem server, internal lab box reachable over a VPN (e.g. Tailscale), or any
cloud VM you provision yourself. No AWS, no ALB, no managed secrets.

The compose stack here mirrors the AWS deployment minus the AWS-specific glue
(ECR login, SSM secret fetch, Route53/ACM TLS). Everything else — Ollama,
LiteLLM gateway, Langfuse, orchestration, the same model set — is identical.

---

## 1. Host requirements

| Item | Minimum |
|---|---|
| OS | Ubuntu 22.04 / 24.04 (any modern Linux with NVIDIA support) |
| GPU | 16 GB VRAM (e.g. T4, A10, RTX 4080+). 24 GB+ lets you raise `OLLAMA_MAX_LOADED_MODELS`. |
| Disk | 60 GB free (~25 GB for model weights + room for Postgres / ClickHouse / MinIO volumes) |
| RAM | 16 GB |
| Network | Outbound HTTPS for image pulls + Ollama model downloads |

### Verify drivers + container runtime

```bash
nvidia-smi                            # driver loaded, GPU visible
docker --version                      # 24+
docker compose version                # 2+
docker run --rm --gpus all \
  nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi    # NVIDIA container toolkit working
```

If the last command fails: install the NVIDIA Container Toolkit
(<https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>),
then `sudo systemctl restart docker`.

---

## 2. Clone the repo

```bash
git clone https://github.com/<owner>/<repo>.git ~/llm-platform
cd ~/llm-platform/compose/self-hosted
```

---

## 3. Configure secrets

```bash
cp .env.example .env
chmod 600 .env
```

Generate strong values for every `CHANGE-ME` in `.env`:

```bash
# Master key + passwords (any random string is fine; hex is convenient)
openssl rand -hex 32

# Langfuse encryption key must be exactly 64 hex chars (32 bytes)
openssl rand -hex 32
```

Open `.env` and replace each placeholder. Keep this file out of git — it is
already in the repo's `.gitignore`.

### Optional: change Langfuse login URL

If you reach the Langfuse UI by hostname (Tailscale machine name, internal
DNS, reverse proxy), set:

```
LANGFUSE_NEXTAUTH_URL=http://gpu-box.tailnet-name.ts.net:3000
```

Otherwise leave it unset; the default `http://localhost:3000` works for SSH
port-forwards.

---

## 4. Start the stack

```bash
docker compose up -d
docker compose ps
```

First start pulls images (~5 min) and builds the gateway + orchestration
images locally. Watch the gateway come up:

```bash
docker compose logs -f litellm
```

When you see `Server started`, the gateway is listening on `:4000`.

---

## 5. Pull the models

The Ollama container starts with an empty model cache. Pull the three default
models (~25 GB total, 10–15 min on a reasonable connection):

```bash
docker compose exec ollama ollama pull llama3.1:8b
docker compose exec ollama ollama pull gemma4:latest
docker compose exec ollama ollama pull qwen2.5-coder:7b
docker compose exec ollama ollama list
```

Weights live on the `ollama-data` volume and survive `docker compose down`.
You only re-download if you delete that volume.

---

## 6. Smoke test

```bash
# 1. Gateway listens and demands auth (expected 401)
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:4000/health
# → 401

# 2. List models with the master key (replace with your real master key)
curl -sS http://localhost:4000/v1/models \
  -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)" | jq

# 3. Issue a chat completion. First call cold-loads the model — expect
#    60–120 s. Warm calls are 1–3 s.
curl -sS http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1",
    "messages": [{"role": "user", "content": "Say hi in one sentence."}]
  }' | jq -r '.choices[0].message.content'
```

Langfuse UI: `http://<host>:3000` — log in with
`LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD` from `.env`.
The first chat completion should appear under the `llm-platform` project's
traces within a few seconds.

LiteLLM admin UI: `http://<host>:4000/ui` — log in with the master key.

---

## 7. Issue per-application virtual keys

The master key is for ops only. Each application that calls the gateway gets
its own scoped virtual key with a budget and an allowed-models list.

```bash
MASTER=$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)

curl -sS -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "my-app",
    "models": ["llama3.1", "gemma4"],
    "max_budget": 50,
    "budget_duration": "30d",
    "metadata": {"tenant_id": "my-app"}
  }' | jq
```

The response `key` field (looks like `sk-…`) is what the application sends in
`Authorization: Bearer <key>`. Store it in the application's secret manager —
**never commit it**.

To revoke: `POST /key/delete` with the key. To inspect spend: the LiteLLM
admin UI shows per-key budget and usage.

---

## 8. Expose it to your network

The compose binds only loopback by default for two ports:

| Port | Service | Public-safe? |
|---|---|---|
| 4000 | LiteLLM gateway (OpenAI-compatible API) | Yes — auth at the API key layer |
| 3000 | Langfuse web UI | Has password login; fine behind a VPN, prefer not on the public Internet |

Pick one:

- **Tailscale / WireGuard / VPN** — leave the ports as-is and reach the box
  by its tailnet/VPN hostname. Simplest, recommended for internal use.
- **Reverse proxy with TLS** — Caddy or Traefik in front of `:4000` (and
  optionally `:3000`) with a real domain + ACME cert. The gateway already
  speaks HTTP behind a TLS terminator — no changes needed inside.
- **SSH port-forward** — for solo testing:
  `ssh -L 4000:localhost:4000 -L 3000:localhost:3000 gpu-host`.

If you put the gateway on the public Internet, lock down the master key, set
budgets on every virtual key, and enable Langfuse audit logging.

---

## 9. Operations

```bash
# Tail every service
docker compose logs -f

# Tail a specific one
docker compose logs -f litellm

# Restart a single service after a config change
docker compose restart litellm

# Stop everything (keeps volumes)
docker compose down

# Stop and wipe ALL data (model cache, Postgres, Langfuse traces, MinIO)
docker compose down -v
```

### Updating

```bash
git pull
docker compose pull           # pulls newer Ollama / Langfuse / Postgres etc.
docker compose build          # rebuilds gateway + orchestration locally
docker compose up -d
```

**Never** change the LiteLLM image tag to `latest` or `main`. The gateway
Dockerfile pins by digest because LiteLLM has been a supply-chain target —
read `docs/architecture.md §5.2` before bumping.

### Idle stop

Self-hosted boxes don't auto-stop. If the GPU host is a cloud VM you're
paying by the hour, wire up your own systemd timer or cloud scheduler to
`sudo shutdown` outside business hours. The Ollama model cache is on a
named volume, so a clean restart only re-loads into VRAM (~60 s for the
first call) — it does not re-download weights.

---

## 10. Troubleshooting

**`docker compose up` fails with `could not select device driver "nvidia"`**
The NVIDIA Container Toolkit is missing or Docker wasn't restarted after
installing it. Re-run the `nvidia-smi` test in §1.

**First `/v1/chat/completions` hangs for 90+ s**
Expected. Ollama is loading the requested model into VRAM. Subsequent calls
to the same model are fast. To pre-warm at boot, add an `ollama run <model>`
step in §5 or a startup script.

**`/v1/chat/completions` returns `model_not_found`**
The model isn't in `gateway/config/config.cloud.yaml` *or* it isn't in the
allowed-models list of your virtual key. Check both.

**Langfuse login redirects to `localhost` on a remote browser**
Set `LANGFUSE_NEXTAUTH_URL` in `.env` to the URL users actually load (§3),
then `docker compose up -d langfuse-web`.

**Out of VRAM when switching models**
Lower `OLLAMA_KEEP_ALIVE` (e.g. `30s`) in the compose file so the previous
model unloads sooner, or upgrade to a larger GPU and raise
`OLLAMA_MAX_LOADED_MODELS`.

**Where do the logs live?**
`docker compose logs <service>`. There is no host-side log file equivalent
to the AWS instance's `/var/log/llm-bootstrap.log` — compose logs are the
canonical source.
