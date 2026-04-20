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

# Start the local dev stack (base + local override). Refuses non-local VPS_DOMAIN.
up:
    #!/usr/bin/env bash
    set -e
    case "${VPS_DOMAIN:-}" in
        *.local|*.test) ;;
        *)
            echo "ERROR: just up is for local dev only (VPS_DOMAIN='${VPS_DOMAIN}' must end in .local or .test)."
            echo "Use 'just up-prod' on the VPS."
            exit 1
            ;;
    esac
    docker compose -f docker-compose.yml -f docker-compose.local.yml up -d

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
    docker compose -f docker-compose.yml -f docker-compose.local.yml down

# Stop all services and delete all data volumes (destructive!)
reset:
    docker compose -f docker-compose.yml -f docker-compose.local.yml down -v

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
        docker compose -f docker-compose.yml -f docker-compose.local.yml restart
    else
        docker compose -f docker-compose.yml -f docker-compose.local.yml restart {{service}}
    fi

# Pull latest images
pull:
    docker compose -f docker-compose.yml -f docker-compose.local.yml pull

# Rebuild and restart (useful after config changes)
reload:
    docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate

# ── Observability ────────────────────────────────────────────────────────────

# Show running container status
ps:
    docker compose -f docker-compose.yml -f docker-compose.local.yml ps

# Follow logs for all services (or one: just logs grafana)
logs service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --tail=50
    else
        docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --tail=100 {{service}}
    fi

# Run the smoke test (stack must be up)
smoke:
    @bash scripts/smoke-test.sh

# List Claude-related metric names in Prometheus
metrics:
    @curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
      | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)['data'] if 'claude' in x.lower()]"

# ── Local access ─────────────────────────────────────────────────────────────

# Open Grafana via Caddy TLS (requires trust-cert + /etc/hosts entry)
open:
    @open https://aimonitor.local

# Open Prometheus UI (direct)
prom:
    @open http://localhost:9090

# Extract Caddy's local root CA, install it into macOS System keychain, print NODE_EXTRA_CA_CERTS snippet
trust-cert:
    #!/usr/bin/env bash
    set -e
    if ! docker compose -f docker-compose.yml -f docker-compose.local.yml ps --services --filter status=running 2>/dev/null | grep -q '^caddy$'; then
        echo "ERROR: Caddy is not running. Run 'just up' first, then hit https://aimonitor.local once to trigger CA generation."
        exit 1
    fi
    CA_SRC=/data/caddy/pki/authorities/local/root.crt
    CA_DST="$(pwd)/caddy-local-root.crt"
    if ! docker compose -f docker-compose.yml -f docker-compose.local.yml exec -T caddy test -s "$CA_SRC"; then
        echo "ERROR: Caddy has not generated its internal PKI yet."
        echo "Try: curl -k https://aimonitor.local/api/health  (then rerun just trust-cert)"
        exit 1
    fi
    docker compose -f docker-compose.yml -f docker-compose.local.yml cp "caddy:$CA_SRC" "$CA_DST"
    if [ ! -s "$CA_DST" ]; then
        echo "ERROR: extracted CA file is empty. Has Caddy initialized its internal PKI yet?"
        echo "Try: curl -k https://aimonitor.local/api/health  (then rerun just trust-cert)"
        exit 1
    fi
    echo ""
    echo "Installing CA into macOS System keychain (sudo password required)..."
    if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_DST" 2>/dev/null; then
        echo "✓ Caddy local CA installed to system keychain."
    else
        echo "ℹ CA already installed (or install skipped); continuing."
    fi
    echo ""
    echo "Node.js does NOT use the macOS keychain. Add this to ~/.zshrc (or shell profile):"
    echo ""
    echo "    export NODE_EXTRA_CA_CERTS=\"$CA_DST\""
    echo ""
    echo "Open a new shell, then verify with:"
    echo "    node -e \"require('https').get('https://aimonitor.local/api/health', r => console.log(r.statusCode))\""

# ── Dev helpers ──────────────────────────────────────────────────────────────

# Verify Caddy is routing + TLS handshake succeeds on both :443 and :4317
ping:
    #!/usr/bin/env bash
    set -e
    echo -n "Caddy HTTPS (:443) ... "
    if curl -sfo /dev/null https://aimonitor.local/api/health; then
        echo "OK"
    else
        echo "FAIL (check: stack up? /etc/hosts? CA trusted via 'just trust-cert'?)"
        exit 1
    fi
    echo -n "Caddy OTLP TLS handshake (:4317) ... "
    if echo "" | openssl s_client -connect aimonitor.local:4317 -servername aimonitor.local -verify_return_error </dev/null >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL (Caddy :4317 listener or TLS trust)"
        exit 1
    fi

# Validate all config files without starting services
validate:
    docker compose config --quiet && echo "docker-compose.yml (prod) OK"
    docker compose -f docker-compose.yml -f docker-compose.local.yml config --quiet && echo "docker-compose.yml + override (local) OK"
    docker run --rm -v "$(pwd)/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
        otel/opentelemetry-collector-contrib:0.100.0 validate \
        --config=/etc/otelcol-contrib/config.yaml \
        && echo "otel-collector/config.yaml OK"
