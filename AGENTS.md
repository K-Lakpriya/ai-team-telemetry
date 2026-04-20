# AI Monitor Repo Notes

## What This Repo Is
- This repo is infrastructure/config, not an application codebase. The main entrypoints are `Justfile`, `docker-compose.yml`, and the service configs under `caddy/`, `otel-collector/`, `prometheus/`, `loki/`, and `grafana/`.
- `docker-compose.yml` defines the whole stack: Caddy, OTEL Collector, Prometheus, Loki, and Grafana.

## Core Workflow
- First-time setup: `just setup` creates `.env` from `.env.example`; it does not overwrite an existing `.env`.
- Local token generation: `just token`
- Start/stop stack: `just up`, `just down`, `just reset`
- Recreate containers after config changes: `just reload`
- Validate config without starting services: `just validate`
- Smoke test after changes: `just smoke`

## Verification Shortcuts
- `just smoke` assumes the stack is already up and requires `curl`, `jq`, and `python3` on the host.
- `just ping` is only a reachability/auth check against OTEL gRPC on `localhost:4317`; it requires `OTEL_BEARER_TOKEN` from `.env`.
- `just logs <service>` is the fastest focused debug path; `just logs` tails all services.
- `just ps` shows container health/state.

## Telemetry Path Quirks
- External OTLP traffic terminates at Caddy on `:4317` and is proxied as `h2c://otel-collector:4317`. If ingestion breaks, check both `caddy/Caddyfile` and `otel-collector/config.yaml`.
- The collector only exposes OTLP gRPC; there is no OTLP HTTP receiver configured.
- The collector enforces bearer-token auth on OTLP ingest via `bearertokenauth`.
- Metrics are sent from the collector to Prometheus via `prometheusremotewrite`; Prometheus is not scraping app metrics directly. Do not try to add Claude/OpenTelemetry app metrics under `prometheus/prometheus.yml` unless the ingest architecture changes.
- Logs are exported from the collector to Loki. `developer.name` falls back to `host.name` when absent, and Loki stream labels come from `developer.name,model`.
- Prometheus labels are derived from OTEL resource attributes via `resource_to_telemetry_conversion`; dotted OTEL attributes become underscored labels in Prometheus.

## Grafana Conventions
- Datasources and dashboards are file-provisioned from `grafana/provisioning/**` and `grafana/dashboards/**`.
- `grafana/provisioning/dashboards/dashboards.yaml` points Grafana at `/var/lib/grafana/dashboards`, which is the mounted `grafana/dashboards/` directory in this repo.
- The smoke test currently expects exactly 4 dashboards tagged `claude-code`. If you add/remove dashboards or change tagging, update `scripts/smoke-test.sh` too.

## Local Access And Env
- For local testing, `Justfile` explicitly says `VPS_DOMAIN` can be `localhost`.
- Direct local UIs: Grafana `http://localhost:3000`, Prometheus `http://localhost:9090`. Public Grafana access is meant to go through Caddy on `https://${VPS_DOMAIN}`.
- Sensitive values live in `.env`; never commit `.env`.

## Retention And Important Defaults
- Prometheus retention is set in `docker-compose.yml` (`14d`, `80GB`).
- Loki retention is set in `loki/loki-config.yaml` (`120h`).
- Collector and image versions are pinned in repo config; preserve existing version pinning unless intentionally upgrading.
