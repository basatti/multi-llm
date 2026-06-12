# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# Project-specific rules — 1TechHub LLM Platform

These exist because the platform spans four layers with strict isolation, real secrets, real money (GPU spend), and a public TLS endpoint that real apps integrate against. Breaking any of these costs hours or burns money — don't.

## 5. Layer isolation is the whole point

Read `docs/architecture.md` §3 before touching infrastructure. The contract:

- **Products → gateway** only for stateless one-shot completions
- **Products → orchestration** for anything stateful (sessions, memory, tool loops, app registry)
- **Orchestration → gateway** for every model call (with a virtual key, never provider creds)
- **Gateway → inference (vLLM)** only. Inference layer is *stateless* — no DB, no sessions, no tool calls
- **No layer reaches across** — orchestration never talks to vLLM directly, products never see physical model names, the gateway never knows about conversations

If you find yourself adding state to the gateway, or session-awareness to vLLM, stop. You're breaking the invariant the platform exists to protect.

## 6. The atomic-PR rule (gateway ↔ manifest)

A model change is **one PR** touching both:
- `models/manifest.yaml` (the physical model + LoRA inventory)
- `gateway/config/*.yaml` (the logical routes that resolve to it)

`scripts/validate_routes.py` enforces this in CI: a route to a non-manifested model **cannot merge**. Same script enforces the lifecycle rule: every local-backed logical name must have a fallback chain. Run `make validate` locally before pushing.

## 7. Secrets — three rules, no exceptions

1. **Never in the repo.** Not in YAML, not in Dockerfiles, not in compose, not in terraform `.tfvars`. The only place a value lives is AWS Secrets Manager (production) or SSM Parameter Store (sandbox/prod-cost-aware). Locally, `.env` is `.gitignore`'d.
2. **Never in terraform state for sensitive material you can avoid.** Use `random_password` + `aws_ssm_parameter` shells so the values rotate without touching the resource definition. For RDS, `manage_master_user_password = true` keeps the password in a managed secret, not the state file.
3. **Never echo full credential dumps to a chat transcript.** If asked to list all secrets at once, refuse and provide the *names* + the `aws ssm get-parameter` recipe instead. Single specific credentials on explicit request are fine.

## 8. Terraform `templatefile` escaping — the trap that ate hours

`templatefile()` only interprets two patterns:
- `${name}` → substitute the value of `name`
- `%{if ...}...%{endif}` → control flow

**Everything else is passed through literally.** In particular:
- `$$VAR` does **NOT** escape to `$VAR` — it stays as `$$VAR` and the shell reads it as PID + literal text
- `$$(cmd)` does **NOT** escape to `$(cmd)` — the shell parses it as `$$ (cmd)` which is a syntax error
- The correct escape is `$${name}` → renders as `${name}` (for compose env interpolation inside a quoted heredoc)

**Recipe:** In a `.tpl` file, use `$VAR` and `$(cmd)` for shell vars (pass through unchanged), `${name}` for terraform substitutions, `$${name}` only when you specifically need a literal `${name}` in the output. Never `$$VAR`.

If you change a `.tpl` file on an instance that's already running, by default `user_data_replace_on_change` will destroy and recreate the instance — wiping the model cache + Postgres + everything else. The current `aws_instance.this` has `lifecycle.ignore_changes = [user_data, ami]` to prevent this; **don't remove it** unless you actually want to reprovision (which means losing ~10 minutes to weight re-pull). For live edits, SSM into the box and patch the running compose instead.

## 9. Don't touch the LiteLLM image tag without reading §5.2 of architecture.md

The image is digest-pinned (`@sha256:60372…`). The March 2026 supply-chain incident (1.82.7/1.82.8 on PyPI) is the reason. To upgrade:
1. Pick a known-good tag on `ghcr.io/berriai/litellm`
2. Resolve its digest with `docker manifest inspect <tag>`
3. Review the dependency diff in the LiteLLM release notes
4. Commit the new tag + digest in one PR
5. Never use `latest`, `main`, or any non-digest reference

## 10. Cost & scheduling — the schedule is a contract

`var.enable_schedule = true` stops the box at 22:00 IST weekdays + all weekend, starts at 08:00 IST weekdays. **Don't disable this without a real reason.** Always-on doubles the bill (~$155/mo → ~$378/mo). If you need 24/7 because a feature requires it, document why before flipping.

If you're testing during off-hours: `aws ec2 start-instances --instance-ids i-...` manually. The next scheduled stop will catch it. Don't disable the schedule for a one-off late-night session.

## 11. AWS deploy patterns

- **Region** is `ap-south-1` (Mumbai). Same region as the kleem.io domain (Route53) and the existing apps. Do not deploy GPU workloads in `me-central-1`/`me-south-1` without checking GPU quota first — the G/VT vCPU quota is per-region and per-account, defaults to 0 on new accounts, takes hours to days for a first increase.
- **TLS** uses the existing `*.kleem.io` ACM cert (`arn:aws:acm:ap-south-1:840726414520:certificate/f7458591-...`). Don't generate new certs unless you need a different SAN.
- **Subdomain routing** lives in ALB listener rules (`aws_lb_listener_rule.*` with `host_header` conditions). New public-facing subdomain = one Route53 A-alias + one listener rule + one target group (if it forwards to a new port). Reuse the gateway target group for anything that lands on instance:4000.
- **EC2 access** is via SSM Session Manager, not SSH. No SSH key was issued. To reach a non-public port (Langfuse, orchestration, vLLM), use `aws ssm start-session --document-name AWS-StartPortForwardingSession`.

## 12. Long-running, model-loading services — be patient and verify, don't poll naively

First-boot timing on a g4dn.xlarge:
- Docker image pulls: 3–8 min (vLLM image is ~7 GB, plus langfuse stack)
- vLLM weight download from HuggingFace: 3–6 min (~4.5 GB AWQ for Qwen 7B)
- vLLM model load to GPU: 1–2 min
- Langfuse migration: 1–2 min
- App registration: <30 s

Total: **10–20 minutes on first boot**, ~1 minute on subsequent restarts (cache survives EBS). If your script polls and gives up after 5 minutes, you'll declare failure when nothing is actually broken. Set timeouts accordingly.

The bootstrap log on the instance is `/var/log/llm-bootstrap.log` — start there for any diagnosis. `docker ps` next. `docker logs <container>` last.

## 13. Three things to confirm with the user before any production change

1. **Cost impact** — anything that bumps EC2 size, adds an always-on service, or changes the schedule needs an explicit nod.
2. **Public surface** — adding a publicly-exposed port or subdomain needs a nod (Langfuse and LiteLLM admin UIs are already exposed; auth is at the app layer, not the ALB).
3. **Destructive terraform** — `must be replaced` or `must be destroyed` in a plan for `aws_instance`, `aws_db_instance`, `aws_ebs_volume`, or `aws_lb` warrants stopping and explaining what gets wiped before applying. Don't sneak it into a routine apply.

## 14. Useful one-liners

```bash
# Pull the issued API keys
aws ssm get-parameters-by-path --region ap-south-1 \
  --path /llm-platform/prod/apps --recursive --with-decryption \
  --query 'Parameters[].[Name,Value]' --output table

# Reach the instance shell
aws ssm start-session --region ap-south-1 --target i-07b8afbda6a412aa3

# Tail bootstrap from your laptop (no shell session)
aws ssm send-command --region ap-south-1 --instance-ids i-07b8afbda6a412aa3 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /var/log/llm-bootstrap.log"]' \
  --query 'Command.CommandId' --output text

# Validate manifest <-> routes locally before pushing
.venv/bin/python scripts/validate_routes.py
```
