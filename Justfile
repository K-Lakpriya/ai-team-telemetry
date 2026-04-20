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
        echo "  VPS_DOMAIN        — 'aimonitor.local' for local dev, your domain for prod"
        echo "  CADDY_EMAIL       — real email for prod Let's Encrypt (any value for local)"
        echo "  OTEL_BEARER_TOKEN — run: just token"
        echo "  GF_SECURITY_ADMIN_PASSWORD"
    fi
    echo ""
    just hosts-check

# Generate a random bearer token (paste into .env)
token:
    @openssl rand -hex 32

# Check /etc/hosts has aimonitor.local → 127.0.0.1 (local dev requirement)
hosts-check:
    #!/usr/bin/env bash
    if grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+aimonitor\.local([[:space:]]|$)' /etc/hosts; then
        echo "✓ /etc/hosts has aimonitor.local"
    else
        echo "⚠ /etc/hosts is missing aimonitor.local. Run:"
        echo "    echo '127.0.0.1   aimonitor.local' | sudo tee -a /etc/hosts"
        exit 0
    fi

# ── Stack lifecycle ──────────────────────────────────────────────────────────

# Start all services in the background
up:
    docker compose up -d

# Start the prod stack (base compose only, no local override)
# Intended for VPS deployment; aborts if VPS_DOMAIN looks like a local domain.
up-prod:
    #!/usr/bin/env bash
    set -e
    case "${VPS_DOMAIN:-}" in
        *.local|*.test|localhost)
            echo "ERROR: just up-prod refuses to run with VPS_DOMAIN='${VPS_DOMAIN}' (looks like a local domain)."
            echo "Use 'just up' for local dev."
            exit 1
            ;;
    esac
    docker compose up -d

# Stop all services (keeps volumes)
down:
    docker compose down

# Stop all services and delete all data volumes (destructive!)
reset:
    docker compose down -v

# Wipe Prometheus + Loki data volumes (keeps Grafana users/dashboards and Caddy CA)
clean-data:
    #!/usr/bin/env bash
    set -e
    docker compose -f docker-compose.yml -f docker-compose.local.yml stop prometheus loki
    docker volume rm aimonitor_prometheus_data aimonitor_loki_data
    docker compose -f docker-compose.yml -f docker-compose.local.yml start prometheus loki

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

# Extract Caddy's local root CA and install it into the macOS System keychain.
# Also prints the NODE_EXTRA_CA_CERTS snippet (Node.js does not read the keychain).
trust-cert:
    #!/usr/bin/env bash
    set -e
    if ! docker compose -f docker-compose.yml -f docker-compose.local.yml ps --services --filter status=running 2>/dev/null | grep -q '^caddy$'; then
        echo "ERROR: Caddy is not running. Run 'just up' first, then hit https://aimonitor.local once to trigger CA generation."
        exit 1
    fi
    CA_SRC=/data/caddy/pki/authorities/local/root.crt
    CA_DST="$(pwd)/caddy-local-root.crt"
    docker compose -f docker-compose.yml -f docker-compose.local.yml cp "caddy:$CA_SRC" "$CA_DST"
    if [ ! -s "$CA_DST" ]; then
        echo "ERROR: extracted CA file is empty. Has Caddy initialized its internal PKI yet?"
        echo "Try: curl -k https://aimonitor.local/api/health  (then rerun just trust-cert)"
        exit 1
    fi
    echo ""
    echo "Installing CA into macOS System keychain (sudo password required)..."
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_DST"
    echo ""
    echo "✓ Caddy local CA installed to system keychain."
    echo ""
    echo "Node.js does NOT use the macOS keychain. Add this to ~/.zshrc (or shell profile):"
    echo ""
    echo "    export NODE_EXTRA_CA_CERTS=\"$CA_DST\""
    echo ""
    echo "Open a new shell, then verify with:"
    echo "    node -e \"require('https').get('https://aimonitor.local/api/health', r => console.log(r.statusCode))\""

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
