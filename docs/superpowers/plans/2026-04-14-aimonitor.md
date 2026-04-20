# AI Monitor Implementation Plan

> **⚠ Historical record — post-implementation corrections apply.** Two things in this plan turned out wrong in practice and were fixed in the live repo:
> 1. **Metric names** in every PromQL block below are stale. Real Prometheus names (as of otelcol-contrib 0.119.0) are `claude_code_cost_usage_USD_total`, `claude_code_token_usage_tokens_total`, `claude_code_active_time_seconds_total`, etc. — the OTel `unit` attribute is appended as a suffix. Also, `claude_code_api_usage_total` **does not exist** — Claude Code never emitted it; dashboards use `claude_code_token_usage_tokens_total` as the proxy for API activity.
> 2. **Delta temporality**: Claude Code emits Sum metrics with delta aggregation temporality, which `prometheusremotewrite` silently drops. A `deltatocumulative` processor in the metrics pipeline is required (available in otelcol-contrib ≥0.107; we run 0.119.0).
>
> For the canonical live-state of metric names and pipeline, read `otel-collector/config.yaml` and `grafana/dashboards/*.json`, not this plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Claude Code usage monitoring stack on an existing VPS to give full visibility into per-developer cost, token usage, and efficiency for a team of 6–20 developers.

**Architecture:** Dev machines send Claude Code OTEL telemetry (metrics + logs) over gRPC/TLS to a Caddy reverse proxy. The OTEL Collector sits behind Caddy, validates bearer tokens, applies a hostname fallback for developer identity, and fans out to Prometheus (metrics, 14d) and Loki (logs, 5d). Grafana serves four provisioned dashboards over HTTPS. All services run in a single `docker-compose.yml` on the existing VPS.

**Tech Stack:** Docker Compose, Caddy 2 (Let's Encrypt TLS), OpenTelemetry Collector Contrib 0.100.0, Prometheus 2.51.0, Loki 2.9.5, Grafana 10.4.2

---

## File Map

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Orchestrates all 5 services with named volumes |
| `.env.example` | Template for secrets — copy to `.env`, never commit `.env` |
| `.gitignore` | Excludes `.env`, volumes, data dirs |
| `caddy/Caddyfile` | TLS termination via Let's Encrypt; gRPC proxy for OTEL (4317); HTTPS proxy for Grafana (443) |
| `otel-collector/config.yaml` | Bearer token auth on receiver; hostname fallback transform; metric + log pipelines to Prometheus and Loki |
| `prometheus/prometheus.yml` | Scrape config for self-monitoring; remote write receiver enabled via CLI flag |
| `loki/loki-config.yaml` | Filesystem storage, 5-day retention via compactor |
| `grafana/provisioning/datasources/datasources.yaml` | Auto-provisions Prometheus + Loki data sources |
| `grafana/provisioning/dashboards/dashboards.yaml` | Tells Grafana to load JSON files from `/var/lib/grafana/dashboards` |
| `grafana/dashboards/cost.json` | Cost Dashboard: daily cost, per-dev, per-model, 7-day trend |
| `grafana/dashboards/efficiency.json` | Efficiency Dashboard: output/input ratio, cache hit rate |
| `grafana/dashboards/waste.json` | Waste Detection: high input/low output, Opus % per dev |
| `grafana/dashboards/daily-summary.json` | Daily Summary: full table + cost ranking + efficiency ranking |
| `scripts/smoke-test.sh` | Validates stack is healthy; sends synthetic metric; confirms in Prometheus |

---

## Label Conventions

Claude Code OTEL resource attributes become Prometheus labels via `resource_to_telemetry_conversion`:
- `developer.name` → `developer_name`
- `host.name` → `host_name`

Metric data-point attributes stay as-is:
- `model` → `model`
- `type` → `type` (values: `input`, `output`, `cache_read`, `cache_creation`)

**Verify actual metric names on first run:**
```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)['data'] if 'claude' in x.lower()]"
```

---

## Task 1: Project Scaffold

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Create: `.gitignore`

- [ ] **Step 1: Initialize git repo**

```bash
cd /path/to/aimonitor
git init
```

Expected: `Initialized empty Git repository in .../aimonitor/.git/`

- [ ] **Step 2: Create `.gitignore`**

```
.env
grafana/data/
prometheus/data/
loki/data/
caddy/data/
caddy/config/
*.bak
```

- [ ] **Step 3: Create `.env.example`**

```bash
# Copy to .env and fill in real values. Never commit .env.

# Your VPS domain (must have A record pointing to this VPS)
VPS_DOMAIN=monitor.yourdomain.com

# Email for Let's Encrypt registration
CADDY_EMAIL=admin@yourdomain.com

# Shared secret for OTEL telemetry ingestion — generate with: openssl rand -hex 32
OTEL_BEARER_TOKEN=changeme-generate-with-openssl-rand-hex-32

# Grafana admin credentials
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=changeme-strong-password
```

- [ ] **Step 4: Create `docker-compose.yml`**

```yaml
version: '3.8'

services:
  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "443:443"
      - "4317:4317"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      - VPS_DOMAIN=${VPS_DOMAIN}
      - CADDY_EMAIL=${CADDY_EMAIL}
    restart: unless-stopped

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.100.0
    volumes:
      - ./otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro
    environment:
      - OTEL_BEARER_TOKEN=${OTEL_BEARER_TOKEN}
    ports:
      - "127.0.0.1:8888:8888"    # collector self-metrics (localhost only)
      - "127.0.0.1:13133:13133"  # health check endpoint (localhost only)
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.51.0
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=14d'
      - '--storage.tsdb.retention.size=80GB'
      - '--web.enable-remote-write-receiver'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
    ports:
      - "127.0.0.1:9090:9090"  # Prometheus UI + API (localhost only — not public)
    restart: unless-stopped

  loki:
    image: grafana/loki:2.9.5
    volumes:
      - ./loki/loki-config.yaml:/etc/loki/local-config.yaml:ro
      - loki_data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    user: "0"
    ports:
      - "127.0.0.1:3100:3100"  # Loki API (localhost only)
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.4.2
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_SECURITY_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_SECURITY_ADMIN_PASSWORD}
      - GF_SERVER_ROOT_URL=https://${VPS_DOMAIN}
      - GF_USERS_ALLOW_SIGN_UP=false
    ports:
      - "127.0.0.1:3000:3000"  # Grafana (localhost only — public access via Caddy/443)
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
  prometheus_data:
  loki_data:
  grafana_data:
```

- [ ] **Step 5: Validate compose syntax**

```bash
docker compose config --quiet && echo "OK"
```

Expected: `OK` (no errors)

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml .env.example .gitignore
git commit -m "feat: project scaffold — compose, env template, gitignore"
```

---

## Task 2: Caddy Configuration

**Files:**
- Create: `caddy/Caddyfile`

- [ ] **Step 1: Create `caddy/Caddyfile`**

```
{
    email {$CADDY_EMAIL}
}

# Grafana — HTTPS on port 443 (default)
{$VPS_DOMAIN} {
    reverse_proxy grafana:3000
}

# OTEL Collector — gRPC/TLS on port 4317
# h2c:// = cleartext HTTP/2 to internal collector (TLS terminated by Caddy)
{$VPS_DOMAIN}:4317 {
    reverse_proxy h2c://otel-collector:4317
}
```

- [ ] **Step 2: Validate Caddyfile**

```bash
docker run --rm \
  -e VPS_DOMAIN=test.example.com \
  -e CADDY_EMAIL=test@example.com \
  -v "$(pwd)/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

Expected: `Valid configuration`

- [ ] **Step 3: Commit**

```bash
git add caddy/Caddyfile
git commit -m "feat: caddy config — TLS termination + gRPC proxy for OTEL"
```

---

## Task 3: OTEL Collector Configuration

**Files:**
- Create: `otel-collector/config.yaml`

- [ ] **Step 1: Create `otel-collector/config.yaml`**

```yaml
extensions:
  # Server-side bearer token validation for all OTLP receivers
  bearertokenauth:
    token: "${OTEL_BEARER_TOKEN}"

  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        auth:
          authenticator: bearertokenauth

processors:
  memory_limiter:
    check_interval: 5s
    limit_percentage: 75
    spike_limit_percentage: 20

  # If developer.name resource attribute is absent, fall back to host.name
  transform/developer_fallback:
    metric_statements:
      - context: resource
        statements:
          - 'set(attributes["developer.name"], attributes["host.name"]) where attributes["developer.name"] == nil'
    log_statements:
      - context: resource
        statements:
          - 'set(attributes["developer.name"], attributes["host.name"]) where attributes["developer.name"] == nil'

  # Mark which resource attributes become Loki stream labels
  transform/loki_labels:
    log_statements:
      - context: resource
        statements:
          - 'set(attributes["loki.resource.labels"], "developer.name,model")'

  batch:
    timeout: 10s
    send_batch_size: 1000

exporters:
  prometheusremotewrite:
    endpoint: "http://prometheus:9090/api/v1/write"
    tls:
      insecure: true
    # Copies all OTEL resource attributes as Prometheus labels
    # developer.name → developer_name, host.name → host_name, etc.
    resource_to_telemetry_conversion:
      enabled: true

  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"
    tls:
      insecure: true

service:
  extensions: [bearertokenauth, health_check]
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, transform/developer_fallback, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, transform/developer_fallback, transform/loki_labels, batch]
      exporters: [loki]
```

- [ ] **Step 2: Validate collector config**

```bash
docker run --rm \
  -e OTEL_BEARER_TOKEN=testtoken \
  -v "$(pwd)/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  otel/opentelemetry-collector-contrib:0.100.0 \
  validate --config /etc/otelcol-contrib/config.yaml
```

Expected: `Everything is OK`

- [ ] **Step 3: Commit**

```bash
git add otel-collector/config.yaml
git commit -m "feat: otel collector config — bearer auth, hostname fallback, metrics+logs pipelines"
```

---

## Task 4: Prometheus Configuration

**Files:**
- Create: `prometheus/prometheus.yml`

- [ ] **Step 1: Create `prometheus/prometheus.yml`**

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # OTEL Collector internal metrics (pipeline health, queue sizes)
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:8888']
```

Note: Application metrics (claude_code_*) arrive via remote write from OTEL Collector — no scrape job needed for them.

- [ ] **Step 2: Validate Prometheus config**

```bash
docker run --rm \
  -v "$(pwd)/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v2.51.0 \
  promtool check config /etc/prometheus/prometheus.yml
```

Expected: `SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax`

- [ ] **Step 3: Commit**

```bash
git add prometheus/prometheus.yml
git commit -m "feat: prometheus config — 14d retention, remote write receiver, self + collector scraping"
```

---

## Task 5: Loki Configuration

**Files:**
- Create: `loki/loki-config.yaml`

- [ ] **Step 1: Create `loki/loki-config.yaml`**

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # 5-day retention (120 hours)
  retention_period: 120h

compactor:
  working_directory: /loki/retention
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem
```

- [ ] **Step 2: Validate Loki config**

```bash
docker run --rm \
  -v "$(pwd)/loki/loki-config.yaml:/etc/loki/local-config.yaml:ro" \
  grafana/loki:2.9.5 \
  -config.file=/etc/loki/local-config.yaml \
  -verify-config
```

Expected: `Starting Loki` followed by successful exit (no errors before exit)

- [ ] **Step 3: Commit**

```bash
git add loki/loki-config.yaml
git commit -m "feat: loki config — 5-day retention, filesystem storage, embedded cache"
```

---

## Task 6: Grafana Provisioning

**Files:**
- Create: `grafana/provisioning/datasources/datasources.yaml`
- Create: `grafana/provisioning/dashboards/dashboards.yaml`

- [ ] **Step 1: Create datasources provisioning**

```bash
mkdir -p grafana/provisioning/datasources
```

`grafana/provisioning/datasources/datasources.yaml`:
```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"

  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki:3100
    editable: false
```

- [ ] **Step 2: Create dashboards provisioning**

```bash
mkdir -p grafana/provisioning/dashboards grafana/dashboards
```

`grafana/provisioning/dashboards/dashboards.yaml`:
```yaml
apiVersion: 1

providers:
  - name: 'Claude Code'
    orgId: 1
    folder: 'Claude Code'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: Commit**

```bash
git add grafana/provisioning/
git commit -m "feat: grafana provisioning — prometheus + loki datasources, dashboard loader"
```

---

## Task 7: Cost Dashboard

**Files:**
- Create: `grafana/dashboards/cost.json`

- [ ] **Step 1: Create `grafana/dashboards/cost.json`**

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "refresh": "5m",
  "schemaVersion": 38,
  "tags": ["claude-code"],
  "time": { "from": "now-24h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Claude Code — Cost",
  "uid": "cc-cost",
  "version": 1,
  "templating": {
    "list": [
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "definition": "label_values(claude_code_api_usage_total, developer_name)",
        "hide": 0,
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "name": "developer",
        "label": "Developer",
        "query": {
          "query": "label_values(claude_code_api_usage_total, developer_name)",
          "refId": "StandardVariableQuery"
        },
        "refresh": 2,
        "sort": 1,
        "type": "query"
      },
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "definition": "label_values(claude_code_api_usage_total, model)",
        "hide": 0,
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "name": "model",
        "label": "Model",
        "query": {
          "query": "label_values(claude_code_api_usage_total, model)",
          "refId": "StandardVariableQuery"
        },
        "refresh": 2,
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "currencyUSD", "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "green", "value": null },
            { "color": "yellow", "value": 10 },
            { "color": "red", "value": 50 }
          ]}
        },
        "overrides": []
      },
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "id": 1,
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "orientation": "auto", "textMode": "auto", "colorMode": "background" },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum(increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range]))",
        "legendFormat": "Total Cost",
        "refId": "A",
        "instant": true
      }],
      "title": "Total Cost (Selected Range)",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "currencyUSD", "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "green", "value": null }, { "color": "yellow", "value": 5 }, { "color": "red", "value": 20 }
          ]}
        },
        "overrides": []
      },
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "id": 2,
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum(increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range])) / count(count by (developer_name) (claude_code_api_usage_total{developer_name=~\"$developer\"}))",
        "legendFormat": "Avg per Dev",
        "refId": "A",
        "instant": true
      }],
      "title": "Avg Cost per Developer",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "short", "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [{ "color": "blue", "value": null }]}
        },
        "overrides": []
      },
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "id": 3,
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum(increase(claude_code_api_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range]))",
        "legendFormat": "Requests",
        "refId": "A",
        "instant": true
      }],
      "title": "Total API Requests",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "currencyUSD", "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [{ "color": "purple", "value": null }]}
        },
        "overrides": []
      },
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "id": 4,
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "topk(1, sum by (developer_name) (increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range])))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Top Spender",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "currencyUSD",
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2, "fillOpacity": 10 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 },
      "id": 5,
      "options": {
        "legend": { "calcs": ["sum", "max"], "displayMode": "table", "placement": "right" },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[1h]))",
        "legendFormat": "{{developer_name}}",
        "refId": "A"
      }],
      "title": "Cost Over Time — Per Developer (hourly)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "currencyUSD",
          "color": { "mode": "palette-classic" },
          "custom": { "barAlignment": 0 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "id": 6,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["sum"] },
        "displayMode": "gradient",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sort_desc(sum by (developer_name) (increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range])))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Cost per Developer (Ranked)",
      "type": "bargauge"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "currencyUSD", "color": { "mode": "palette-classic" } },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "id": 7,
      "options": {
        "legend": { "displayMode": "table", "placement": "right", "values": ["percent", "value"] },
        "pieType": "pie"
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (model) (increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[$__range]))",
        "legendFormat": "{{model}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Cost by Model",
      "type": "piechart"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "currencyUSD",
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2, "fillOpacity": 5 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 },
      "id": 8,
      "options": {
        "legend": { "calcs": ["sum"], "displayMode": "table", "placement": "right" },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (increase(claude_code_cost_usage_total{developer_name=~\"$developer\",model=~\"$model\"}[1d]))",
        "legendFormat": "{{developer_name}}",
        "refId": "A"
      }],
      "title": "7-Day Cost Trend — Per Developer (daily)",
      "type": "timeseries",
      "timeFrom": "now-7d"
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -m json.tool grafana/dashboards/cost.json > /dev/null && echo "Valid JSON"
```

Expected: `Valid JSON`

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/cost.json
git commit -m "feat: cost dashboard — daily cost, per-dev, per-model, 7-day trend"
```

---

## Task 8: Efficiency Dashboard

**Files:**
- Create: `grafana/dashboards/efficiency.json`

- [ ] **Step 1: Create `grafana/dashboards/efficiency.json`**

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "refresh": "5m",
  "schemaVersion": 38,
  "tags": ["claude-code"],
  "time": { "from": "now-24h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Claude Code — Efficiency",
  "uid": "cc-efficiency",
  "version": 1,
  "templating": {
    "list": [
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "definition": "label_values(claude_code_api_usage_total, developer_name)",
        "hide": 0,
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "name": "developer",
        "label": "Developer",
        "query": { "query": "label_values(claude_code_api_usage_total, developer_name)", "refId": "StandardVariableQuery" },
        "refresh": 2,
        "sort": 1,
        "type": "query"
      },
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "definition": "label_values(claude_code_api_usage_total, model)",
        "hide": 0,
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "name": "model",
        "label": "Model",
        "query": { "query": "label_values(claude_code_api_usage_total, model)", "refId": "StandardVariableQuery" },
        "refresh": 2,
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "red", "value": null },
            { "color": "yellow", "value": 0.1 },
            { "color": "green", "value": 0.3 }
          ]},
          "min": 0, "max": 1
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "id": 1,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "displayMode": "lcd",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"output\"}[1h])) / sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"input\"}[1h]))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Output / Input Token Ratio (higher = more efficient)",
      "type": "bargauge"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "red", "value": null },
            { "color": "yellow", "value": 0.2 },
            { "color": "green", "value": 0.5 }
          ]},
          "min": 0, "max": 1
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "id": 2,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "displayMode": "lcd",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"cache_read\"}[1h])) / (sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"input\"}[1h])) + sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"cache_read\"}[1h])))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Cache Hit Rate (cache_read / (input + cache_read))",
      "type": "bargauge"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2, "fillOpacity": 10 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 8 },
      "id": 3,
      "options": {
        "legend": { "calcs": ["mean", "last"], "displayMode": "table", "placement": "right" },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"cache_read\"}[1h])) / (sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"input\"}[1h])) + sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"cache_read\"}[1h])))",
          "legendFormat": "{{developer_name}}",
          "refId": "A"
        }
      ],
      "title": "Cache Hit Rate Over Time",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2, "fillOpacity": 5 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "id": 4,
      "options": {
        "legend": { "calcs": ["mean", "last"], "displayMode": "table", "placement": "right" },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"output\"}[1h])) / sum by (developer_name) (rate(claude_code_token_usage_total{developer_name=~\"$developer\",model=~\"$model\",type=\"input\"}[1h]))",
          "legendFormat": "{{developer_name}}",
          "refId": "A"
        }
      ],
      "title": "Output / Input Token Ratio Over Time",
      "type": "timeseries"
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -m json.tool grafana/dashboards/efficiency.json > /dev/null && echo "Valid JSON"
```

Expected: `Valid JSON`

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/efficiency.json
git commit -m "feat: efficiency dashboard — output/input ratio, cache hit rate over time"
```

---

## Task 9: Waste Detection Dashboard

**Files:**
- Create: `grafana/dashboards/waste.json`

- [ ] **Step 1: Create `grafana/dashboards/waste.json`**

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "refresh": "5m",
  "schemaVersion": 38,
  "tags": ["claude-code"],
  "time": { "from": "now-24h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Claude Code — Waste Detection",
  "uid": "cc-waste",
  "version": 1,
  "templating": {
    "list": [
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "definition": "label_values(claude_code_api_usage_total, developer_name)",
        "hide": 0,
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "name": "developer",
        "label": "Developer",
        "query": { "query": "label_values(claude_code_api_usage_total, developer_name)", "refId": "StandardVariableQuery" },
        "refresh": 2,
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "green", "value": null },
            { "color": "yellow", "value": 5 },
            { "color": "red", "value": 20 }
          ]},
          "custom": { "align": "auto", "displayMode": "auto" }
        },
        "overrides": [
          { "matcher": { "id": "byName", "options": "Input Tokens" }, "properties": [{ "id": "unit", "value": "short" }] },
          { "matcher": { "id": "byName", "options": "Output Tokens" }, "properties": [{ "id": "unit", "value": "short" }] },
          { "matcher": { "id": "byName", "options": "Ratio" }, "properties": [
            { "id": "unit", "value": "short" },
            { "id": "custom.displayMode", "value": "color-background" },
            { "id": "thresholds", "value": { "mode": "absolute", "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 5 },
              { "color": "red", "value": 20 }
            ]}}
          ]}
        ]
      },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
      "id": 1,
      "options": { "sortBy": [{ "displayName": "Ratio", "desc": true }] },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{developer_name=~\"$developer\",type=\"input\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "A",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{developer_name=~\"$developer\",type=\"output\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "B",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{developer_name=~\"$developer\",type=\"input\"}[$__range])) / sum by (developer_name) (increase(claude_code_token_usage_total{developer_name=~\"$developer\",type=\"output\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "C",
          "instant": true,
          "format": "table"
        }
      ],
      "title": "Input / Output Ratio by Developer (high = wasteful)",
      "transformations": [
        { "id": "merge", "options": {} },
        { "id": "organize", "options": {
          "renameByName": { "Value #A": "Input Tokens", "Value #B": "Output Tokens", "Value #C": "Ratio", "developer_name": "Developer" },
          "excludeByName": { "Time": true }
        }}
      ],
      "type": "table"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": { "mode": "thresholds" },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "green", "value": null },
            { "color": "yellow", "value": 10 },
            { "color": "red", "value": 20 }
          ]},
          "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "id": 2,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "displayMode": "lcd",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (rate(claude_code_api_usage_total{developer_name=~\"$developer\",model=~\".*opus.*\"}[1h])) / sum by (developer_name) (rate(claude_code_api_usage_total{developer_name=~\"$developer\"}[1h])) * 100",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Opus Usage % (flag >20%)",
      "type": "bargauge"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": { "mode": "palette-classic" },
          "custom": { "lineWidth": 2 },
          "thresholds": { "mode": "absolute", "steps": [
            { "color": "green", "value": null }, { "color": "red", "value": 20 }
          ]}
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "id": 3,
      "options": {
        "legend": { "calcs": ["mean", "max"], "displayMode": "table", "placement": "right" },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sum by (developer_name) (rate(claude_code_api_usage_total{developer_name=~\"$developer\",model=~\".*opus.*\"}[1h])) / sum by (developer_name) (rate(claude_code_api_usage_total{developer_name=~\"$developer\"}[1h])) * 100",
        "legendFormat": "{{developer_name}}",
        "refId": "A"
      }],
      "title": "Opus Usage % Over Time",
      "type": "timeseries"
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -m json.tool grafana/dashboards/waste.json > /dev/null && echo "Valid JSON"
```

Expected: `Valid JSON`

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/waste.json
git commit -m "feat: waste detection dashboard — input/output ratio table, opus usage per dev"
```

---

## Task 10: Daily Summary Dashboard

**Files:**
- Create: `grafana/dashboards/daily-summary.json`

- [ ] **Step 1: Create `grafana/dashboards/daily-summary.json`**

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "refresh": "5m",
  "schemaVersion": 38,
  "tags": ["claude-code"],
  "time": { "from": "now-24h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Claude Code — Daily Summary",
  "uid": "cc-daily",
  "version": 1,
  "templating": { "list": [] },
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "custom": { "align": "auto", "displayMode": "auto" }
        },
        "overrides": [
          { "matcher": { "id": "byName", "options": "Cost (USD)" }, "properties": [
            { "id": "unit", "value": "currencyUSD" },
            { "id": "custom.displayMode", "value": "color-background" },
            { "id": "thresholds", "value": { "mode": "absolute", "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 5 },
              { "color": "red", "value": 20 }
            ]}}
          ]},
          { "matcher": { "id": "byName", "options": "Cache Hit %" }, "properties": [
            { "id": "unit", "value": "percent" },
            { "id": "custom.displayMode", "value": "color-background" },
            { "id": "thresholds", "value": { "mode": "absolute", "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 20 },
              { "color": "green", "value": 50 }
            ]}}
          ]},
          { "matcher": { "id": "byName", "options": "Output/Input Ratio" }, "properties": [
            { "id": "unit", "value": "short" },
            { "id": "decimals", "value": 2 }
          ]}
        ]
      },
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "id": 1,
      "options": { "sortBy": [{ "displayName": "Cost (USD)", "desc": true }] },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_api_usage_total[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "A",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{type=\"input\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "B",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{type=\"output\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "C",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_cost_usage_total[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "D",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{type=\"cache_read\"}[$__range])) / (sum by (developer_name) (increase(claude_code_token_usage_total{type=\"input\"}[$__range])) + sum by (developer_name) (increase(claude_code_token_usage_total{type=\"cache_read\"}[$__range]))) * 100",
          "legendFormat": "{{developer_name}}",
          "refId": "E",
          "instant": true,
          "format": "table"
        },
        {
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "expr": "sum by (developer_name) (increase(claude_code_token_usage_total{type=\"output\"}[$__range])) / sum by (developer_name) (increase(claude_code_token_usage_total{type=\"input\"}[$__range]))",
          "legendFormat": "{{developer_name}}",
          "refId": "F",
          "instant": true,
          "format": "table"
        }
      ],
      "title": "Developer Summary — Last 24h",
      "transformations": [
        { "id": "merge", "options": {} },
        { "id": "organize", "options": {
          "renameByName": {
            "developer_name": "Developer",
            "Value #A": "Requests",
            "Value #B": "Input Tokens",
            "Value #C": "Output Tokens",
            "Value #D": "Cost (USD)",
            "Value #E": "Cache Hit %",
            "Value #F": "Output/Input Ratio"
          },
          "excludeByName": { "Time": true }
        }}
      ],
      "type": "table"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "currencyUSD",
          "color": { "mode": "palette-classic" },
          "custom": { "barAlignment": 0 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 10 },
      "id": 2,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["sum"] },
        "displayMode": "gradient",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sort_desc(sum by (developer_name) (increase(claude_code_cost_usage_total[$__range])))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Cost Ranking",
      "type": "bargauge"
    },
    {
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "decimals": 2,
          "color": { "mode": "palette-classic" },
          "custom": { "barAlignment": 0 }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 10 },
      "id": 3,
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "displayMode": "gradient",
        "showUnfilled": true
      },
      "targets": [{
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "expr": "sort_desc(sum by (developer_name) (increase(claude_code_token_usage_total{type=\"output\"}[$__range])) / sum by (developer_name) (increase(claude_code_token_usage_total{type=\"input\"}[$__range])))",
        "legendFormat": "{{developer_name}}",
        "refId": "A",
        "instant": true
      }],
      "title": "Efficiency Ranking (Output/Input Ratio — higher is better)",
      "type": "bargauge"
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -m json.tool grafana/dashboards/daily-summary.json > /dev/null && echo "Valid JSON"
```

Expected: `Valid JSON`

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/daily-summary.json
git commit -m "feat: daily summary dashboard — full dev table, cost ranking, efficiency ranking"
```

---

## Task 11: Smoke Test Script

**Files:**
- Create: `scripts/smoke-test.sh`

- [ ] **Step 1: Create `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Smoke test: validates all services are healthy
# Usage: ./scripts/smoke-test.sh
# Requires: docker compose stack running, curl, jq, python3

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

check() {
  local name="$1"; local cmd="$2"; local expected="$3"
  local result
  result=$(eval "$cmd" 2>&1) || true
  if echo "$result" | grep -q "$expected"; then
    echo -e "${GREEN}PASS${NC} $name"
    ((PASS++))
  else
    echo -e "${RED}FAIL${NC} $name (got: $result)"
    ((FAIL++))
  fi
}

echo "=== AI Monitor Smoke Test ==="
echo ""

# 1. OTEL Collector health check
check "OTEL Collector health" \
  "curl -sf http://localhost:13133/" \
  "Server available"

# 2. Prometheus readiness
check "Prometheus ready" \
  "curl -sf http://localhost:9090/-/ready" \
  "Prometheus Server is Ready"

# 3. Loki readiness
check "Loki ready" \
  "curl -sf http://localhost:3100/ready" \
  "ready"

# 4. Grafana health
check "Grafana health" \
  "curl -sf http://localhost:3000/api/health" \
  "ok"

# 5. Prometheus can scrape otel-collector metrics
check "Prometheus scrapes OTEL Collector" \
  "curl -sf 'http://localhost:9090/api/v1/query?query=up{job=\"otel-collector\"}' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1])\"" \
  "1"

# 6. Grafana datasources provisioned
check "Grafana Prometheus datasource" \
  "curl -sf -u admin:\${GF_SECURITY_ADMIN_PASSWORD:-admin} http://localhost:3000/api/datasources/name/Prometheus" \
  "prometheus"

check "Grafana Loki datasource" \
  "curl -sf -u admin:\${GF_SECURITY_ADMIN_PASSWORD:-admin} http://localhost:3000/api/datasources/name/Loki" \
  "loki"

# 7. Grafana dashboards provisioned
check "Grafana dashboards loaded" \
  "curl -sf -u admin:\${GF_SECURITY_ADMIN_PASSWORD:-admin} 'http://localhost:3000/api/search?tag=claude-code' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(len(d))\"" \
  "4"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo -e "${YELLOW}Some checks failed. Check 'docker compose logs <service>' for details.${NC}"
  exit 1
fi
echo -e "${GREEN}All checks passed.${NC}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/smoke-test.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "feat: smoke test script — health checks for all 5 services + grafana datasources/dashboards"
```

---

## Task 12: Deploy and Validate

- [ ] **Step 1: Set up `.env` on VPS**

```bash
cp .env.example .env
# Edit .env with real values:
# - VPS_DOMAIN: your actual domain (must have DNS A record → this VPS IP)
# - CADDY_EMAIL: your email for Let's Encrypt
# - OTEL_BEARER_TOKEN: generate with: openssl rand -hex 32
# - GF_SECURITY_ADMIN_PASSWORD: strong password
```

- [ ] **Step 2: Open firewall ports on VPS**

```bash
# UFW example — adjust for your VPS firewall
sudo ufw allow 80/tcp    # Let's Encrypt HTTP challenge
sudo ufw allow 443/tcp   # Grafana HTTPS
sudo ufw allow 4317/tcp  # OTEL gRPC/TLS
sudo ufw reload
```

- [ ] **Step 3: Pull images**

```bash
docker compose pull
```

Expected: All 5 images downloaded without errors.

- [ ] **Step 4: Start stack**

```bash
docker compose up -d
```

Expected: All 5 containers start (`Started` status for each).

- [ ] **Step 5: Wait for Caddy to obtain TLS certificate**

```bash
# Watch Caddy logs — wait for "certificate obtained successfully"
docker compose logs -f caddy
```

Expected within ~30s: `certificate obtained successfully` for your domain. Press Ctrl+C once seen.

- [ ] **Step 6: Run smoke test**

```bash
export GF_SECURITY_ADMIN_PASSWORD=$(grep GF_SECURITY_ADMIN_PASSWORD .env | cut -d= -f2)
./scripts/smoke-test.sh
```

Expected: `8 passed, 0 failed`

- [ ] **Step 7: Verify actual metric names from Claude Code**

On a dev machine with Claude Code running and `CLAUDE_CODE_ENABLE_TELEMETRY=1` set, wait 5 minutes, then:

```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)['data'] if 'claude' in x.lower()]"
```

If metric names differ from `claude_code_cost_usage_total` / `claude_code_token_usage_total` / `claude_code_api_usage_total`, update the PromQL expressions in all 4 dashboard JSON files and reimport.

- [ ] **Step 8: Configure one dev machine and verify end-to-end**

Add to `~/.zshrc` (or `~/.bashrc`) on one dev machine:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT=https://YOUR_VPS_DOMAIN:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer YOUR_TOKEN"
export OTEL_RESOURCE_ATTRIBUTES="developer.name=yourname,team=myteam"
```

Reload shell (`source ~/.zshrc`), run Claude Code for a few minutes, then check:

```bash
# Confirm metrics are flowing
curl -s 'http://localhost:9090/api/v1/query?query=claude_code_api_usage_total' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('metrics flowing:', len(d['data']['result']) > 0)"
```

Expected: `metrics flowing: True`

- [ ] **Step 9: Open Grafana and verify dashboards**

Navigate to `https://YOUR_VPS_DOMAIN` → Log in → Dashboards → Claude Code folder.
All 4 dashboards should be visible and populated with data.

- [ ] **Step 10: Final commit**

```bash
git add -A
git commit -m "docs: deployment verified — all services healthy, metrics flowing"
```

---

## Developer Onboarding Reference

Share this snippet with all developers:

```bash
# Add to ~/.zshrc or ~/.bashrc
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT=https://YOUR_VPS_DOMAIN:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer YOUR_BEARER_TOKEN"
export OTEL_RESOURCE_ATTRIBUTES="developer.name=YOUR_NAME,team=myteam"
```

`developer.name` is optional — if omitted, your machine hostname is used. Setting it explicitly is recommended for clear attribution in dashboards.

---

## Operational Runbook

| Task | Command |
|------|---------|
| View logs | `docker compose logs -f <service>` |
| Restart a service | `docker compose restart <service>` |
| Redeploy after config change | `docker compose up -d --no-deps <service>` |
| Rotate bearer token | Edit `.env` → `docker compose up -d --no-deps caddy otel-collector` → notify devs |
| Backup Grafana | `docker exec aimonitor-grafana-1 tar czf - /var/lib/grafana > grafana-backup-$(date +%Y%m%d).tar.gz` |
| Check disk usage | `docker system df` |
