# aimonitor

Self-hosted observability stack for monitoring Claude Code usage across a team: per-developer cost, tokens, and session activity, fed via OpenTelemetry into Prometheus + Loki and visualised in Grafana.

This repo is infrastructure and config — no application code. Everything is driven by `docker-compose.yml`, `docker-compose.local.yml`, and the `Justfile`. Local dev and production run the **same** compose file; only `.env` values and an optional local override distinguish them.

## Architecture

```
Dev machines (Claude Code + OTEL SDK)
        │ OTLP/gRPC :4317 (bearer-token auth, TLS)
        ▼
       Caddy  ──────► OTel Collector ──► Prometheus (metrics, 14d)
        │                              └─► Loki        (logs, 120h)
        │ HTTPS :443
        ▼
      Grafana (file-provisioned dashboards tagged `claude-code`)
```

Services: **caddy**, **otel-collector**, **prometheus**, **loki**, **grafana**.

## Prerequisites

- Docker + `docker compose` plugin
- [`just`](https://github.com/casey/just)
- `curl`, `jq`, `openssl`, `python3` (for `just smoke`)

---

## Local setup (macOS laptop)

1. Clone the repo and `cd` into it.
2. `just setup` — creates `.env` from `.env.example` and warns if `/etc/hosts` is missing the entry.
3. Edit `.env`:
   - `VPS_DOMAIN=aimonitor.local`
   - `CADDY_EMAIL=dev@localhost`
   - `OTEL_BEARER_TOKEN=` ← paste from `just token`
   - `GF_SECURITY_ADMIN_PASSWORD=admin`
4. Add hosts entry:
   ```bash
   echo '127.0.0.1   aimonitor.local' | sudo tee -a /etc/hosts
   ```
5. `just up` — starts the full stack with `tls internal`.
6. `curl -sk https://aimonitor.local/api/health` — triggers Caddy to generate its internal CA.
7. `just trust-cert` — installs the CA into the macOS System keychain (sudo prompt) and prints a `NODE_EXTRA_CA_CERTS` line.
8. Add the printed line to `~/.zshrc`, then `exec zsh`.
9. `just smoke` — expect **10/10 passed**.
10. Point Claude Code at it:
    ```bash
    export OTEL_EXPORTER_OTLP_ENDPOINT=https://aimonitor.local:4317
    ```
    Plus the other `CLAUDE_CODE_ENABLE_TELEMETRY=1` and bearer-auth headers — see [Client configuration](#client-configuration-claude-code) below.

**Access:** `just open` (Grafana via Caddy) or `http://localhost:3000` direct.

---

## Production setup (VPS)

1. Point DNS: `A` record `monitor.yourdomain.com` → VPS IP.
2. On the VPS: install Docker + `docker-compose` plugin + `just`, then `git clone` the repo.
3. `cd` in, then `just setup` — creates `.env`.
4. Edit `.env`:
   - `VPS_DOMAIN=monitor.yourdomain.com` (your real domain, must resolve to this VPS)
   - `CADDY_EMAIL=you@yourdomain.com` (real email — Let's Encrypt contacts you for cert issues)
   - `OTEL_BEARER_TOKEN=` ← paste from `just token` (use a strong token; share only with authorised clients)
   - `GF_SECURITY_ADMIN_PASSWORD=<strong password>`
5. Open firewall ports 80, 443, 4317 inbound:
   ```bash
   ufw allow 80,443,4317/tcp
   ```
6. `just up-prod` — starts base compose only; Caddy auto-requests Let's Encrypt certs for `:443` and `:4317`.
7. `just ps` — confirm all 5 services running.
8. `curl -sI https://monitor.yourdomain.com/api/health` — expect `HTTP/2 200` (cert valid, no `-k` needed).
9. Point Claude Code clients at `https://monitor.yourdomain.com:4317` with the bearer token in `OTEL_EXPORTER_OTLP_HEADERS`.

**Grafana UI:** `https://monitor.yourdomain.com` (Caddy-fronted).
**SSH-tunnel Grafana admin debug:** `ssh -L 3000:127.0.0.1:3000 vps` then `http://localhost:3000`.

---

## Client configuration (Claude Code)

Each developer exports these in their shell profile. Replace `<ENDPOINT>` with `https://aimonitor.local:4317` locally or `https://monitor.yourdomain.com:4317` in prod, and `<TOKEN>` with the value of `OTEL_BEARER_TOKEN`.

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=<ENDPOINT>
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <TOKEN>"
export OTEL_RESOURCE_ATTRIBUTES="developer.name=<your-name>,team=myteam"
```

Local only: also add the line printed by `just trust-cert`:

```bash
export NODE_EXTRA_CA_CERTS="/path/to/aimonitor/caddy-local-root.crt"
```

---

## Common commands

| Command | Purpose |
|---|---|
| `just` | List all recipes |
| `just up` / `just up-prod` | Start stack (local / prod) |
| `just down` | Stop stack (keep volumes) |
| `just reset` | Stop stack and delete all data (destructive) |
| `just reload` | Recreate containers after config changes |
| `just ps` | Container health/state |
| `just logs [service]` | Tail all logs, or one service |
| `just ping` | Verify Caddy routing + TLS on `:443` and `:4317` |
| `just smoke` | Full 10-check smoke test (local only) |
| `just validate` | Validate configs without starting anything |
| `just clean-data` | Wipe Prometheus + Loki data; keep Grafana users and Caddy CA |
| `just token` | Generate a random bearer token |
| `just trust-cert` | Install local Caddy CA into macOS keychain |
| `just metrics` | List `claude_*` metric names from Prometheus |

## Retention

- Prometheus: **14d** or **80GB** (in `docker-compose.yml`)
- Loki: **120h** (in `loki/loki-config.yaml`)

## Further reading

- `AGENTS.md` — repo conventions, telemetry path quirks, Grafana provisioning rules.
- `claude_code_monitoring_plan.md` — original monitoring goals and dashboard plan.
- `docs/superpowers/specs/2026-04-20-local-prod-parity-design.md` — design for local/prod parity.
