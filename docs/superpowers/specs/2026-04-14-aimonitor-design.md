# AI Monitor — Design Spec

**Date:** 2026-04-14
**Status:** Approved
**Scope:** v1 — self-hosted Claude Code usage monitoring for a mid-sized team (6–20 devs)

---

## Objectives

- Full visibility into per-developer Claude Code usage and cost
- Cost optimization via model usage awareness and waste detection
- Efficiency measurement via token ratio and cache hit rate
- No external data dependencies — all data stays on your VPS

---

## Architecture & Data Flow

```
Dev Machine
  └─ Claude Code (OTEL enabled)
       ├─ Metrics → OTLP/gRPC → Caddy (:4317) → OTEL Collector → Prometheus
       └─ Logs   → OTLP/gRPC → Caddy (:4317) → OTEL Collector → Loki

VPS (existing, 2 vCPU / 8GB RAM / 100GB disk)
  ├─ Caddy          — TLS termination (Let's Encrypt) + bearer token auth
  ├─ OTEL Collector — receives, transforms, fans out telemetry
  ├─ Prometheus     — metrics store, 14-day retention, 80GB max
  ├─ Loki           — log store, 5-day retention
  └─ Grafana        — dashboards on HTTPS:443 via Caddy
```

All services run in a single `docker-compose.yml`. Caddy is the only externally exposed service (ports 443 and 4317).

---

## Developer Onboarding

Devs add 6 env vars to their shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT=https://YOUR_VPS_DOMAIN:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer YOUR_TOKEN"
export OTEL_RESOURCE_ATTRIBUTES="developer.name=<YOUR_NAME>,team=myteam"
```

`developer.name` is optional — if unset, the OTEL Collector falls back to `host.name` (machine hostname). Team leads should encourage setting it explicitly for clarity.

---

## Components

### Caddy

- Terminates TLS via Let's Encrypt on port 4317 (OTEL) and 443 (Grafana)
- Validates `Authorization: Bearer <token>` on all OTLP requests — returns 401 if missing or wrong
- Token stored in `caddy/.env`, referenced in `Caddyfile`

### OTEL Collector

Pipelines:

| Pipeline | Receiver | Processors | Exporter |
|----------|----------|------------|----------|
| metrics  | otlp/grpc | transform (hostname fallback), batch | prometheusremotewrite |
| logs     | otlp/grpc | transform (hostname fallback), batch | loki |

**Transform processor logic:**
```yaml
# resource_statements context — attributes[] refers to resource attributes
- 'set(attributes["developer.name"], attributes["host.name"]) where attributes["developer.name"] == nil'
```

Config lives in `otel-collector/config.yaml`.

### Prometheus

- Receives remote write from OTEL Collector
- Retention: `--storage.tsdb.retention.time=14d` + `--storage.tsdb.retention.size=80GB`
- Config in `prometheus/prometheus.yml`

**Key metrics:**

| Metric | Labels | Description |
|--------|--------|-------------|
| `claude_code_token_usage_tokens_total` | `developer_name`, `model`, `type` (input/output/cache_read/cache_creation) | Token counts |
| `claude_code_cost_usage_USD_total` | `developer_name`, `model` | Pre-calculated cost from Claude Code |
| `claude_code_active_time_seconds_total` | `developer_name`, `model` | Active session time |
| `claude_code_commit_count_total` | `developer_name` | Git commits created |
| `claude_code_lines_of_code_count_total` | `developer_name`, `type` | Lines of code modified |
| `claude_code_code_edit_tool_decision_total` | `developer_name`, `decision` | Tool permission decisions |

**Note:** Metric names carry the OTel `unit` attribute as a suffix (`_USD_`, `_tokens_`, `_seconds_`) because otelcol-contrib ≥0.119 sets `add_metric_suffixes: true` by default on `prometheusremotewrite`. Claude Code does **not** emit a `claude_code.api.usage` instrument — dashboards use `claude_code_token_usage_tokens_total` as the proxy for API activity.

**Also note:** Claude Code emits Sum metrics with **delta** aggregation temporality. The collector pipeline runs a `deltatocumulative` processor to convert them before writing to Prometheus; without it, delta sums are silently dropped by `prometheusremotewrite`.

### Loki

- Receives logs from OTEL Collector
- Labels indexed: `developer`, `model`, `session_id`
- Retention: 5 days
- Config in `loki/loki-config.yaml`

### Grafana

- Accessible at `https://YOUR_VPS_DOMAIN` (Caddy proxies port 443)
- Admin login for team leads; read-only viewer accounts for devs
- Data sources: Prometheus + Loki (provisioned via `grafana/provisioning/datasources/`)
- Dashboards: provisioned as JSON via `grafana/dashboards/`

---

## Dashboards

All dashboards include `developer` and `model` variable filters.

### 1. Cost Dashboard
- Total daily cost — time series (all devs combined)
- Cost per developer — ranked bar chart
- Cost by model (Sonnet vs Opus) — pie chart
- 7-day cost trend — line chart

### 2. Efficiency Dashboard
- Output/input token ratio per developer (higher = more efficient prompting)
- Cache hit rate per developer: `cache_read_tokens / (input_tokens + cache_read_tokens)` — gauge

### 3. Waste Detection
- Long sessions with low output ratio — table (session_id, duration, input tokens, output tokens)
- High input tokens with near-zero output — top-N table
- Opus usage % per developer — flag devs >20% of requests on Opus

### 4. Daily Summary
- Developer summary table: requests, tokens in/out, cost, cache hit rate
- Top cost drivers (developer + model breakdown)
- Efficiency ranking (output/input ratio, ranked ascending)

Dashboard JSON files live in `grafana/dashboards/`.

---

## Security

| Concern | Mitigation |
|---------|------------|
| Unauthenticated telemetry ingestion | Caddy bearer token validation |
| Plain-text transport | TLS via Let's Encrypt (auto-renewed) |
| Grafana admin exposure | HTTPS only; strong admin password in `.env` |
| Token compromise | Rotate in `caddy/.env` + redeploy Caddy; notify devs |

No secrets committed to git — all sensitive values in `.env` files (gitignored).

---

## Error Handling & Operations

**Telemetry gaps:** Dev machine offline → metrics stop. No alerting on missing devs in v1.

**Collector restart:** OTEL SDK buffers unsent data in memory. Acceptable loss window: ~5s restart time.

**Disk pressure:** Prometheus auto-evicts on 80GB limit. Grafana alert rule fires at 85% disk usage.

**Bearer token rotation:** Update `caddy/.env` → `docker compose up -d caddy` → notify devs to update `OTEL_EXPORTER_OTLP_HEADERS`.

**Grafana backup:** `grafana/data/` bind-mounted to host. Daily cron exports dashboard JSON + SQLite DB to `/backups/grafana/`.

---

## Validation / Smoke Test

1. `docker compose config` — validates compose syntax
2. `otelcol validate --config otel-collector/config.yaml` — validates collector config
3. Smoke test script (`scripts/smoke-test.sh`): sends synthetic OTLP metric via `grpcurl`, confirms metric appears in Prometheus within 30s

---

## Data Retention

| Store | Retention |
|-------|-----------|
| Prometheus | 14 days |
| Loki | 5 days |
| Grafana backups | 30 days |

---

## Project Structure

```
aimonitor/
├── docker-compose.yml
├── .env.example                        # template — copy to .env, never commit .env
├── caddy/
│   └── Caddyfile
├── otel-collector/
│   └── config.yaml
├── prometheus/
│   └── prometheus.yml
├── loki/
│   └── loki-config.yaml
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/datasources.yaml
│   │   └── dashboards/dashboards.yaml
│   └── dashboards/
│       ├── cost.json
│       ├── efficiency.json
│       ├── waste.json
│       └── daily-summary.json
└── scripts/
    └── smoke-test.sh
```

---

## Out of Scope (v1)

- Git integration (LOC / commit count metrics)
- Slack / email digest reports
- Governance: session limits, budget caps, per-dev alerts
- Claude Admin API billing reconciliation
- High availability / multi-node deployment
