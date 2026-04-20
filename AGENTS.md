# AI Monitor Repo Notes

## What This Repo Is
- This repo is infrastructure/config, not an application codebase. The main entrypoints are `Justfile`, `docker-compose.yml`, `docker-compose.local.yml`, and the service configs under `caddy/`, `otel-collector/`, `prometheus/`, `loki/`, and `grafana/`.
- `docker-compose.yml` is prod-shaped (Caddy fronts `:80`/`:443`/`:4317`, no host-exposed debug ports). `docker-compose.local.yml` is an explicit local-dev override (loaded only via `just up`) that swaps `caddy/Caddyfile` → `caddy/Caddyfile.local` (`tls internal`) and adds loopback debug ports.
- No code changes between environments. Only `.env` values and the presence of the local override distinguish them. See `docs/superpowers/specs/2026-04-20-local-prod-parity-design.md` for the full design.

## Core Workflow
- First-time local setup: `just setup` creates `.env` from `.env.example`; it does not overwrite an existing `.env`. It also runs `just hosts-check` to warn if `/etc/hosts` is missing the `aimonitor.local` entry.
- Local token generation: `just token`
- Start/stop the local stack: `just up` (refuses non-`.local`/`.test` domains), `just down`, `just reset`
- Start on the VPS: `just up-prod` (or plain `docker compose up -d`) — refuses local-looking `VPS_DOMAIN`
- Recreate containers after config changes: `just reload`
- Validate config without starting services: `just validate`
- Smoke test (local only, after trust-cert): `just smoke`
- Wipe only metric/log data (keep Grafana users + Caddy CA): `just clean-data`

## TLS Trust (Local Only)
- After `just up` on the laptop, run `just trust-cert` once per Caddy CA regeneration. It installs Caddy's local root CA into the macOS System keychain (requires sudo) and prints a `NODE_EXTRA_CA_CERTS` snippet to add to your shell profile — Node.js does not read the system keychain, so Claude Code needs the env var.
- If `just smoke` fails at the TLS-trust gate, rerun `just trust-cert`.

## Verification Shortcuts
- `just smoke` assumes the stack is already up and the local CA is trusted. Requires `curl`, `jq`, `python3`, and `openssl` on the host.
- `just ping` checks Caddy routing + TLS handshake on both `:443` and `:4317`.
- `just logs <service>` is the fastest focused debug path; `just logs` tails all services.
- `just ps` shows container health/state.

## Telemetry Path Quirks
- External OTLP traffic terminates at Caddy on `:4317` and is proxied as `h2c://otel-collector:4317`. Local dev uses `tls internal`; prod uses Let's Encrypt. The collector only exposes OTLP gRPC — no HTTP receiver.
- If ingestion breaks, check both `caddy/Caddyfile`/`caddy/Caddyfile.local` (depending on env) and `otel-collector/config.yaml`.
- The collector enforces bearer-token auth on OTLP ingest via `bearertokenauth`.
- Metrics go from collector to Prometheus via `prometheusremotewrite`; Prometheus is not scraping app metrics directly. Do not add Claude/OpenTelemetry app metrics under `prometheus/prometheus.yml` unless the ingest architecture changes.
- Logs are exported to Loki. `developer.name` falls back to `host.name` when absent; Loki stream labels come from `developer.name,model`.
- Prometheus labels derive from OTEL resource attributes via `resource_to_telemetry_conversion`; dotted OTEL attributes become underscored labels.

## Grafana Conventions
- Datasources and dashboards are file-provisioned from `grafana/provisioning/**` and `grafana/dashboards/**`.
- `grafana/provisioning/dashboards/dashboards.yaml` points Grafana at `/var/lib/grafana/dashboards`, the mounted `grafana/dashboards/` directory.
- The smoke test expects exactly 4 dashboards tagged `claude-code`. If you add/remove dashboards or change tagging, update `scripts/smoke-test.sh`.

## Local Access And Env
- Grafana via Caddy: `https://aimonitor.local` (requires /etc/hosts + trust-cert). `just open` opens this.
- Grafana direct (debug): `http://localhost:3000` (works in both envs, loopback only).
- Prometheus direct (local only, via override): `http://localhost:9090` (`just prom`).
- Loki API (local only): `http://localhost:3100`.
- Collector self-metrics (local only): `http://localhost:8888/metrics`; health at `:13133`.
- Sensitive values live in `.env`; never commit `.env`.

## Retention And Important Defaults
- Prometheus retention is set in `docker-compose.yml` (`14d`, `80GB`).
- Loki retention is set in `loki/loki-config.yaml` (`120h`).
- Collector and image versions are pinned in repo config; preserve existing version pinning unless intentionally upgrading.
