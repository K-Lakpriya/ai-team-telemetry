set dotenv-load

# Default: list available recipes
default:
    @just --list

# ── Setup ────────────────────────────────────────────────────────────────────

# First-time setup: copy .env.example → .env (skips if already exists)
setup:
    #!/usr/bin/env bash
    if [ -f .env ]; then
        echo ".env already exists — skipping copy"
    else
        cp .env.example .env
        echo "Created .env from .env.example"
        echo ""
        echo "Edit .env and set:"
        echo "  VPS_DOMAIN    — use 'localhost' for local testing"
        echo "  OTEL_BEARER_TOKEN — run: just token"
        echo "  GF_SECURITY_ADMIN_PASSWORD"
    fi

# Generate a random bearer token (paste into .env)
token:
    @openssl rand -hex 32

# ── Stack lifecycle ──────────────────────────────────────────────────────────

# Start all services in the background
up:
    docker compose up -d

# Stop all services (keeps volumes)
down:
    docker compose down

# Stop all services and delete all data volumes (destructive!)
reset:
    docker compose down -v

# Restart one service, e.g.: just restart grafana
restart service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose restart
    else
        docker compose restart {{service}}
    fi

# Pull latest images
pull:
    docker compose pull

# Rebuild and restart (useful after config changes)
reload:
    docker compose up -d --force-recreate

# ── Observability ────────────────────────────────────────────────────────────

# Show running container status
ps:
    docker compose ps

# Follow logs for all services (or one: just logs grafana)
logs service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose logs -f --tail=50
    else
        docker compose logs -f --tail=100 {{service}}
    fi

# Run the smoke test (stack must be up)
smoke:
    @bash scripts/smoke-test.sh

# List Claude-related metric names in Prometheus
metrics:
    @curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
      | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)['data'] if 'claude' in x.lower()]"

# ── Local access ─────────────────────────────────────────────────────────────

# Open Grafana in the browser (direct, bypasses Caddy)
open:
    @open http://localhost:3001

# Open Prometheus UI (direct)
prom:
    @open http://localhost:9090

# ── Dev helpers ──────────────────────────────────────────────────────────────

# Send a synthetic OTEL metric to verify ingestion end-to-end
# Requires OTEL_BEARER_TOKEN to be set in .env
ping:
    #!/usr/bin/env bash
    TOKEN="${OTEL_BEARER_TOKEN:?OTEL_BEARER_TOKEN not set in .env}"
    curl -sf -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/x-protobuf" \
      http://localhost:4317 \
      && echo " — collector reachable" \
      || echo "collector unreachable (is the stack up?)"

# Validate all config files without starting services
validate:
    docker compose config --quiet && echo "docker-compose.yml OK"
    docker run --rm -v "$(pwd)/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
        otel/opentelemetry-collector-contrib:0.100.0 validate \
        --config=/etc/otelcol-contrib/config.yaml \
        && echo "otel-collector/config.yaml OK"
