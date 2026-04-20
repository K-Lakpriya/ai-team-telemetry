# Local/Prod Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support both local-dev and VPS production from the same git tree with zero code changes — the only delta is `.env` values and the presence or absence of `docker-compose.local.yml` being loaded.

**Architecture:** Base `docker-compose.yml` is prod-shaped (Caddy fronts `:80`/`:443`/`:4317`, no host-exposed debug ports). A committed `docker-compose.local.yml` override swaps to `caddy/Caddyfile.local` (which uses `tls internal`) and adds loopback debug ports. Justfile `just up` opts into the override and aborts if `$VPS_DOMAIN` isn't a local domain; `just up-prod` does the opposite. Local OTLP flows through Caddy on `aimonitor.local:4317` with an internally-signed cert, just like prod flows through Caddy with Let's Encrypt — identical path, different trust anchor.

**Tech Stack:** Docker Compose (profile-free, two files), Caddy 2 (`tls internal` vs Let's Encrypt), OTEL Collector (unchanged), Prometheus, Loki, Grafana, Justfile, bash smoke test.

**Reference spec:** `docs/superpowers/specs/2026-04-20-local-prod-parity-design.md`.

**Executor notes:**
- Between Task 5 and Task 6, the local stack (`just up`) will be in a transitional state — run verifications only, don't leave things half-done. Task 6 is the atomic flip.
- No unit tests exist or will be added; "tests" for this work are `docker compose config` validation and `just smoke`.
- Commits are small and focused; every task ends with a commit.

---

### Task 1: Add `caddy-local-root.crt` to `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Check current .gitignore**

Run: `cat .gitignore 2>/dev/null || echo "(file does not exist)"`
Expected: shows current ignore patterns, or indicates the file doesn't exist.

- [ ] **Step 2: Append the ignore rule**

If `.gitignore` does not exist, create it with this content; if it exists, append the `caddy-local-root.crt` line (avoid duplicating).

Add this line (or append if the file already exists):

```
/caddy-local-root.crt
```

- [ ] **Step 3: Verify**

Run: `grep -c '^/caddy-local-root.crt$' .gitignore`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore extracted Caddy local root CA

The Caddy internal root CA extracted by 'just trust-cert' is a
developer-local artifact; shouldn't be committed."
```

---

### Task 2: Create `caddy/Caddyfile.local`

**Files:**
- Create: `caddy/Caddyfile.local`

- [ ] **Step 1: Write the file**

Create `caddy/Caddyfile.local` with this content:

```caddy
{
    email {$CADDY_EMAIL}
}

# Grafana — HTTPS on port 443, Caddy-internal self-signed cert
{$VPS_DOMAIN} {
    tls internal
    reverse_proxy grafana:3000
}

# OTEL Collector — gRPC/TLS on port 4317, Caddy-internal self-signed cert
# h2c:// = cleartext HTTP/2 to internal collector (TLS terminated by Caddy)
{$VPS_DOMAIN}:4317 {
    tls internal
    reverse_proxy h2c://otel-collector:4317
}
```

- [ ] **Step 2: Verify Caddy accepts the syntax**

Run:
```bash
docker run --rm -v "$(pwd)/caddy/Caddyfile.local:/etc/caddy/Caddyfile:ro" \
    -e VPS_DOMAIN=aimonitor.local -e CADDY_EMAIL=dev@localhost \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

Expected: `Valid configuration` (possibly with warnings about `email` being unused under `tls internal`; warnings are fine, errors are not).

- [ ] **Step 3: Commit**

```bash
git add caddy/Caddyfile.local
git commit -m "feat: add caddy Caddyfile.local for local dev TLS

Mirrors Caddyfile structure with 'tls internal' on both :443
(Grafana) and :4317 (OTLP), so local dev exercises the same
Caddy-fronted TLS path as prod — only the trust anchor differs."
```

---

### Task 3: Create `docker-compose.local.yml`

**Files:**
- Create: `docker-compose.local.yml`

- [ ] **Step 1: Write the override file**

Create `docker-compose.local.yml` with this content:

```yaml
# Local-dev override. Loaded only by `just up` (never by `docker compose up`
# alone). On the VPS this file is present on disk but unreferenced, so prod
# deploys with `docker compose up -d` are unaffected.
#
# Additions only — no existing base ports are replaced, so Docker Compose's
# default list-concatenation merge is correct. Grafana's base :3000:3000
# binding is reused; user manages port-3000 conflicts on the laptop.

services:
  caddy:
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

  prometheus:
    ports:
      - "127.0.0.1:9090:9090"  # Prometheus UI/API (local debug only)

  loki:
    ports:
      - "127.0.0.1:3100:3100"  # Loki API (local debug only)

  otel-collector:
    ports:
      - "127.0.0.1:8888:8888"   # collector self-metrics (local debug only)
      - "127.0.0.1:13133:13133" # collector health check (local debug only)
```

Notes:
- The `caddy.volumes` block must re-list `caddy_data` and `caddy_config` because Compose's default merge for named volumes on a service is replacement, not append, when you specify `volumes` at all. Without them, the override would drop the persistent volumes.
- No entry for `grafana` — its base `127.0.0.1:3000:3000` binding carries over untouched.
- No entry for `otel-collector:4317` — local OTLP flows through Caddy on `aimonitor.local:4317`, same as prod.

- [ ] **Step 2: Verify the override file parses and merges cleanly against current base**

Run: `docker compose -f docker-compose.yml -f docker-compose.local.yml config --quiet && echo OK`
Expected: `OK`. (This may still show duplicate ports since base hasn't been reverted yet — that's fine for parse validation; the collision check happens at Task 6.)

- [ ] **Step 3: Commit**

```bash
git add docker-compose.local.yml
git commit -m "feat: add docker-compose.local.yml override

Swaps Caddyfile to Caddyfile.local and adds loopback host-port
bindings for Prometheus (9090), Loki (3100), and OTEL collector
debug endpoints (8888, 13133). Grafana :3000 is inherited from
base. Collector :4317 stays internal — local OTLP goes through
Caddy."
```

---

### Task 4: Restore the `:4317` reverse-proxy block in `caddy/Caddyfile`

**Files:**
- Modify: `caddy/Caddyfile`

- [ ] **Step 1: Read the current file**

Run: `cat caddy/Caddyfile`
Expected: file currently has only the `:443` Grafana block (the `:4317` block was removed during earlier local-dev work).

- [ ] **Step 2: Append the `:4317` block**

Replace the full contents of `caddy/Caddyfile` with:

```caddy
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

- [ ] **Step 3: Verify Caddy accepts it**

Run:
```bash
docker run --rm -v "$(pwd)/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -e VPS_DOMAIN=monitor.example.com -e CADDY_EMAIL=admin@example.com \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```
Expected: `Valid configuration`.

- [ ] **Step 4: Commit**

```bash
git add caddy/Caddyfile
git commit -m "fix: restore Caddyfile :4317 OTLP reverse-proxy block

The :4317 block was removed during local-dev workarounds. Local
dev now goes through Caddy on :4317 as well (via Caddyfile.local
+ tls internal), so prod and local share this block's structure."
```

---

### Task 5: Add new Justfile recipes (non-breaking additions)

**Files:**
- Modify: `Justfile`

This task ADDS recipes without touching existing ones, so `just up` continues to work as before. Task 6 flips `just up` to load the override.

- [ ] **Step 1: Read current Justfile**

Run: `cat Justfile`
Expected: current file with recipes `setup`, `token`, `up`, `down`, `reset`, `restart`, `pull`, `reload`, `ps`, `logs`, `smoke`, `metrics`, `open`, `prom`, `ping`, `validate`.

- [ ] **Step 2: Add `hosts-check` recipe**

Insert this recipe after the `token` recipe (keep it in the Setup section):

```just
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
```

- [ ] **Step 3: Update `setup` to also call `hosts-check` at the end**

Find the existing `setup` recipe:

```just
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
```

Replace with:

```just
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
```

- [ ] **Step 4: Add `up-prod` recipe**

Insert after the current `up` recipe:

```just
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
```

- [ ] **Step 5: Add `clean-data` recipe**

Insert after `reset`:

```just
# Wipe Prometheus + Loki data volumes (keeps Grafana users/dashboards and Caddy CA)
clean-data:
    #!/usr/bin/env bash
    set -e
    docker compose -f docker-compose.yml -f docker-compose.local.yml stop prometheus loki
    docker volume rm aimonitor_prometheus_data aimonitor_loki_data
    docker compose -f docker-compose.yml -f docker-compose.local.yml start prometheus loki
```

- [ ] **Step 6: Add `trust-cert` recipe**

Insert in the "Local access" section (near `open` and `prom`):

```just
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
```

- [ ] **Step 7: Verify Justfile parses and new recipes are visible**

Run: `just --list`
Expected output includes `hosts-check`, `up-prod`, `clean-data`, `trust-cert` alongside existing recipes.

Run: `just hosts-check`
Expected: either `✓ /etc/hosts has aimonitor.local` or a warning with the sudo tee instruction (either outcome is correct for this check).

- [ ] **Step 8: Commit**

```bash
git add Justfile
git commit -m "feat: add hosts-check, up-prod, clean-data, trust-cert recipes

Additive Justfile changes ahead of the local/prod split:
- hosts-check warns on missing /etc/hosts entry
- up-prod is the VPS recipe (refuses local-looking VPS_DOMAIN)
- clean-data wipes metric/log volumes without nuking Grafana/Caddy
- trust-cert extracts Caddy's internal root CA and installs it
  in the system keychain; prints NODE_EXTRA_CA_CERTS snippet
- setup now calls hosts-check and updated instructions"
```

---

### Task 6: Revert `docker-compose.yml` to prod shape AND rewire existing Justfile recipes to load the local override

**Files:**
- Modify: `docker-compose.yml`
- Modify: `Justfile`

This is the atomic transition: the base compose becomes prod-shaped (losing loopback debug ports), and the existing Justfile recipes learn to load the override file so local dev recovers those ports via the override.

- [ ] **Step 1: Update `docker-compose.yml`**

Replace the full file contents with:

```yaml
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
    networks:
      - monitor
    restart: unless-stopped

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.119.0
    volumes:
      - ./otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro
    environment:
      - OTEL_BEARER_TOKEN=${OTEL_BEARER_TOKEN}
    depends_on:
      - prometheus
      - loki
    networks:
      - monitor
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
    networks:
      - monitor
    restart: unless-stopped

  loki:
    image: grafana/loki:2.9.5
    volumes:
      - ./loki/loki-config.yaml:/etc/loki/local-config.yaml:ro
      - loki_data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    user: "0"
    networks:
      - monitor
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
      - "127.0.0.1:3000:3000"  # Grafana on loopback (SSH-tunnel admin access on VPS; direct debug on laptop)
    depends_on:
      - prometheus
      - loki
    networks:
      - monitor
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
  prometheus_data:
  loki_data:
  grafana_data:

networks:
  monitor:
    driver: bridge
```

Summary of changes vs. current state:
- Caddy: added `"4317:4317"` port.
- `otel-collector`: entire `ports:` block removed.
- `prometheus`: `ports:` block removed.
- `loki`: `ports:` block removed.
- `grafana`: port changed from `"127.0.0.1:3001:3000"` to `"127.0.0.1:3000:3000"`.

- [ ] **Step 2: Verify prod-only compose parses cleanly**

Run: `docker compose config --quiet && echo OK`
Expected: `OK`.

- [ ] **Step 3: Verify base + override merges without port collisions**

Run: `docker compose -f docker-compose.yml -f docker-compose.local.yml config | grep -E '^ +- (published|target):' | sort | uniq -c | sort -rn | head`
Expected: no port appears more than once per `published` value (i.e., no accidental duplicate host bindings).

Quick human check: run `docker compose -f docker-compose.yml -f docker-compose.local.yml config` and confirm:
- caddy has `80, 443, 4317` published.
- grafana has `3000` published (only once).
- prometheus has `9090`, loki has `3100`, otel-collector has `8888` and `13133` — each appearing only once.
- `otel-collector:4317` is **NOT** in any `published` mapping.

- [ ] **Step 4: Rewire Justfile existing recipes**

In `Justfile`, replace these recipes (keep all others unchanged):

Replace the existing `up` recipe:

```just
up:
    docker compose up -d
```

With:

```just
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
```

Replace `down`:

```just
down:
    docker compose down
```

With:

```just
down:
    docker compose -f docker-compose.yml -f docker-compose.local.yml down
```

Replace `reset`:

```just
reset:
    docker compose down -v
```

With:

```just
reset:
    docker compose -f docker-compose.yml -f docker-compose.local.yml down -v
```

Replace `restart`:

```just
restart service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose restart
    else
        docker compose restart {{service}}
    fi
```

With:

```just
restart service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose -f docker-compose.yml -f docker-compose.local.yml restart
    else
        docker compose -f docker-compose.yml -f docker-compose.local.yml restart {{service}}
    fi
```

Replace `pull`:

```just
pull:
    docker compose pull
```

With:

```just
pull:
    docker compose -f docker-compose.yml -f docker-compose.local.yml pull
```

Replace `reload`:

```just
reload:
    docker compose up -d --force-recreate
```

With:

```just
reload:
    docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate
```

Replace `ps`:

```just
ps:
    docker compose ps
```

With:

```just
ps:
    docker compose -f docker-compose.yml -f docker-compose.local.yml ps
```

Replace `logs`:

```just
logs service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose logs -f --tail=50
    else
        docker compose logs -f --tail=100 {{service}}
    fi
```

With:

```just
logs service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --tail=50
    else
        docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --tail=100 {{service}}
    fi
```

Replace `open`:

```just
open:
    @open http://localhost:3001
```

With:

```just
# Open Grafana via Caddy TLS (requires trust-cert + /etc/hosts entry)
open:
    @open https://aimonitor.local
```

Replace `ping`:

```just
ping:
    #!/usr/bin/env bash
    TOKEN="${OTEL_BEARER_TOKEN:?OTEL_BEARER_TOKEN not set in .env}"
    curl -sf -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/x-protobuf" \
      http://localhost:4317 \
      && echo " — collector reachable" \
      || echo "collector unreachable (is the stack up?)"
```

With:

```just
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
```

Replace `validate`:

```just
validate:
    docker compose config --quiet && echo "docker-compose.yml OK"
    docker run --rm -v "$(pwd)/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
        otel/opentelemetry-collector-contrib:0.100.0 validate \
        --config=/etc/otelcol-contrib/config.yaml \
        && echo "otel-collector/config.yaml OK"
```

With:

```just
validate:
    docker compose config --quiet && echo "docker-compose.yml (prod) OK"
    docker compose -f docker-compose.yml -f docker-compose.local.yml config --quiet && echo "docker-compose.yml + override (local) OK"
    docker run --rm -v "$(pwd)/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
        otel/opentelemetry-collector-contrib:0.100.0 validate \
        --config=/etc/otelcol-contrib/config.yaml \
        && echo "otel-collector/config.yaml OK"
```

(`metrics`, `prom`, `token`, `setup`, `hosts-check`, `up-prod`, `clean-data`, `trust-cert` are unchanged from Task 5.)

- [ ] **Step 5: Verify all recipes are syntactically valid**

Run: `just --list`
Expected: full recipe list renders without error.

Run: `just validate`
Expected: three `OK` lines (prod compose, local compose+override, otel config).

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml Justfile
git commit -m "refactor: prod-shape base compose; Justfile loads local override

Atomic flip:
- docker-compose.yml reverted to prod shape (Caddy fronts :4317,
  no host-exposed debug ports; Grafana back to :3000:3000).
- All Justfile recipes that touch docker compose now reference
  both docker-compose.yml and docker-compose.local.yml, so local
  dev recovers debug ports via the override.
- 'just up' now requires VPS_DOMAIN ending in .local or .test;
  'just up-prod' (added Task 5) handles the VPS case.
- 'just open' → https://aimonitor.local; 'just ping' verifies
  Caddy routing + TLS on both :443 and :4317."
```

---

### Task 7: Rewrite `scripts/smoke-test.sh`

**Files:**
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Read current smoke test**

Run: `cat scripts/smoke-test.sh`
Expected: existing checks hit `localhost:9090`, `localhost:3100`, `localhost:3001`, `localhost:13133`, `localhost:8888`.

- [ ] **Step 2: Replace the file entirely**

Overwrite `scripts/smoke-test.sh` with:

```bash
#!/usr/bin/env bash
# Local smoke test — assumes `just up` and `just trust-cert` have been run.

set -u
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

GRAFANA_HTTPS="https://aimonitor.local"
GRAFANA_HTTP="http://localhost:3000"
OTLP_HOST="aimonitor.local"
OTLP_PORT="4317"
GF_USER="admin"
GF_PASS="${GF_SECURITY_ADMIN_PASSWORD:-admin}"

check() {
  local name="$1" cmd="$2" expected="$3"
  local result
  result=$(eval "$cmd" 2>&1) || true
  if echo "$result" | grep -qE "$expected"; then
    echo -e "${GREEN}PASS${NC} $name"
    ((PASS++)) || true
  else
    echo -e "${RED}FAIL${NC} $name (got: $result)"
    ((FAIL++)) || true
  fi
}

echo "=== Aimonitor Local Smoke Test ==="
echo ""

# 0. TLS trust: curl without -k must succeed. This is the gate — if it fails,
#    the rest of the HTTPS checks will fail for the same reason, so exit early
#    with a helpful hint.
echo -n "TLS trust check ... "
if curl -sfo /dev/null "${GRAFANA_HTTPS}/api/health"; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAIL${NC}"
  echo ""
  echo -e "${YELLOW}The macOS system keychain does not trust Caddy's local root CA.${NC}"
  echo "Run 'just trust-cert' first, then retry."
  exit 1
fi
echo ""

# 1. Caddy-fronted Grafana health
check "Grafana health (via Caddy HTTPS)" \
  "curl -sf ${GRAFANA_HTTPS}/api/health" \
  "ok"

# 2. Grafana direct on loopback (debug access)
check "Grafana health (direct :3000)" \
  "curl -sf ${GRAFANA_HTTP}/api/health" \
  "ok"

# 3. OTLP Caddy :4317 TLS handshake
check "Caddy OTLP :4317 TLS handshake" \
  "echo '' | openssl s_client -connect ${OTLP_HOST}:${OTLP_PORT} -servername ${OTLP_HOST} -verify_return_error </dev/null 2>&1" \
  "Verify return code: 0"

# 4. Prometheus ready
check "Prometheus ready" \
  "curl -sf http://localhost:9090/-/ready" \
  "Prometheus Server is Ready"

# 5. Loki ready
check "Loki ready" \
  "curl -sf http://localhost:3100/ready" \
  "ready"

# 6. Collector health
check "OTEL Collector health" \
  "curl -sf http://localhost:13133/" \
  "Server available"

# 7. Prometheus scrapes OTEL Collector self-metrics
check "Prometheus scrapes OTEL Collector" \
  "curl -sf 'http://localhost:9090/api/v1/query?query=up{job=\"otel-collector\"}' | python3 -c \"import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'no-data')\"" \
  "1"

# 8. Grafana datasources provisioned (via Caddy)
check "Grafana Prometheus datasource" \
  "curl -sf -u ${GF_USER}:${GF_PASS} ${GRAFANA_HTTPS}/api/datasources/name/Prometheus" \
  "prometheus"

check "Grafana Loki datasource" \
  "curl -sf -u ${GF_USER}:${GF_PASS} ${GRAFANA_HTTPS}/api/datasources/name/Loki" \
  "loki"

# 9. Grafana dashboards provisioned
check "Grafana dashboards loaded" \
  "curl -sf -u ${GF_USER}:${GF_PASS} '${GRAFANA_HTTPS}/api/search?tag=claude-code' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(len(d))\"" \
  "4"

echo ""
echo "=================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 3: Make sure it's executable**

Run: `chmod +x scripts/smoke-test.sh && ls -l scripts/smoke-test.sh`
Expected: `-rwxr-xr-x` (or equivalent with x bit set).

- [ ] **Step 4: Do not run yet** — the stack isn't up / CA isn't trusted. The end-to-end smoke run happens in Task 10.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "feat: rewrite smoke test for local TLS via aimonitor.local

- Gates on TLS trust (curl without -k must succeed)
- Tests both Caddy-fronted HTTPS (:443) and direct :3000 Grafana
- Verifies Caddy OTLP TLS handshake on :4317
- Keeps Prom/Loki/collector loopback-debug checks (available
  only with the local override, as designed)."
```

---

### Task 8: Update `.env.example` with local-dev alternate values

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Read current .env.example**

Run: `cat .env.example`
Expected: shows the current template with `VPS_DOMAIN=monitor.yourdomain.com`.

- [ ] **Step 2: Replace with annotated version**

Overwrite `.env.example` with:

```
# Copy to .env and fill in real values. Never commit .env.

# Domain for the monitor.
# - Prod: your real VPS domain (must have A record pointing to this VPS).
# - Local: aimonitor.local  (also add '127.0.0.1 aimonitor.local' to /etc/hosts).
VPS_DOMAIN=monitor.yourdomain.com

# Email for Let's Encrypt registration.
# - Prod: a real email Let's Encrypt can reach.
# - Local: any non-empty value (unused by 'tls internal', but interpolated).
CADDY_EMAIL=admin@yourdomain.com

# Shared secret for OTEL telemetry ingestion — generate with: openssl rand -hex 32
OTEL_BEARER_TOKEN=changeme-generate-with-openssl-rand-hex-32

# Grafana admin credentials
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=changeme-strong-password
```

- [ ] **Step 3: Verify**

Run: `grep -c 'aimonitor.local' .env.example`
Expected: `1` (matching the local-dev comment).

- [ ] **Step 4: Commit**

```bash
git add .env.example
git commit -m "docs: annotate .env.example with local vs prod values

No structural change — existing variables stay; comments clarify
which values to use locally (VPS_DOMAIN=aimonitor.local) vs on
the VPS (real domain + real Let's Encrypt email)."
```

---

### Task 9: Update `AGENTS.md` with the new workflow

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Read current AGENTS.md**

Run: `cat AGENTS.md`

- [ ] **Step 2: Replace the Core Workflow and Local Access sections**

Overwrite `AGENTS.md` with:

```markdown
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
```

- [ ] **Step 3: Verify**

Run: `grep -c 'aimonitor.local' AGENTS.md`
Expected: at least `5` (multiple references in workflow sections).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md for local/prod parity workflow

Reflects the compose override architecture, trust-cert + Node
trust requirement, and the new Justfile recipes (up-prod,
hosts-check, trust-cert, clean-data)."
```

---

### Task 10: End-to-end local verification

This task is **not a code change** — it's the final acceptance test. Run it on the developer laptop; no commit at the end.

**Files:**
- Modify (local, not committed): `.env`
- Modify (host): `/etc/hosts`

- [ ] **Step 1: Update `/etc/hosts`**

Run:
```bash
grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+aimonitor\.local' /etc/hosts || \
    echo '127.0.0.1   aimonitor.local' | sudo tee -a /etc/hosts
```
Expected: either no-op (already present) or one line appended after sudo prompt.

Verify:
```bash
just hosts-check
```
Expected: `✓ /etc/hosts has aimonitor.local`.

- [ ] **Step 2: Update local `.env`**

Open `.env` and ensure these values:
- `VPS_DOMAIN=aimonitor.local`
- `CADDY_EMAIL=dev@localhost` (or any non-empty value)
- `OTEL_BEARER_TOKEN=<existing value, or run `just token`>`
- `GF_SECURITY_ADMIN_USER=admin`
- `GF_SECURITY_ADMIN_PASSWORD=<any value>`

Verify:
```bash
grep -E '^(VPS_DOMAIN|CADDY_EMAIL|OTEL_BEARER_TOKEN|GF_SECURITY_ADMIN_PASSWORD)=' .env
```
Expected: all four variables have non-empty values and `VPS_DOMAIN` is `aimonitor.local`.

- [ ] **Step 3: Bring the stack down (if running) to start clean**

Run: `just down`
Expected: all containers stopped.

- [ ] **Step 4: Bring the stack up**

Run: `just up`
Expected: guard check passes (`VPS_DOMAIN=aimonitor.local` matches `.local`); all containers start with `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d`.

Verify:
```bash
just ps
```
Expected: all 5 services (caddy, otel-collector, prometheus, loki, grafana) are `running` (or `Up` / healthy).

- [ ] **Step 5: Trigger Caddy CA generation**

Hit the Grafana endpoint once (accept the untrusted cert for now) so Caddy issues its internal cert and populates `/data/caddy/pki/authorities/local/`:

```bash
curl -sk https://aimonitor.local/api/health
```
Expected: `{"database":"ok","version":...}`-style JSON response.

- [ ] **Step 6: Install the Caddy local CA**

Run: `just trust-cert`
Expected: sudo prompt, then:
- "✓ Caddy local CA installed to system keychain."
- A `NODE_EXTRA_CA_CERTS` snippet line.

Verify the extracted CA:
```bash
test -s caddy-local-root.crt && echo "CA file present ($(wc -c < caddy-local-root.crt) bytes)"
```
Expected: non-zero byte count.

- [ ] **Step 7: Verify system-trust (no -k) works**

Run:
```bash
curl -sI https://aimonitor.local/api/health | head -1
```
Expected: `HTTP/2 200` (or `HTTP/1.1 200`). If this fails, the keychain install didn't take — rerun Task 10 Step 6.

- [ ] **Step 8: Verify Node.js trust status**

Run:
```bash
node -e "require('https').get('https://aimonitor.local/api/health', r => console.log('OK', r.statusCode)).on('error', e => console.error('FAIL', e.code))"
```

- If output is `OK 200` → Node trusts the cert (rare — some newer Node versions with system-trust flags set). Skip Step 9.
- If output is `FAIL UNABLE_TO_VERIFY_LEAF_SIGNATURE` (or similar `FAIL ...`) → proceed to Step 9.

- [ ] **Step 9: Add `NODE_EXTRA_CA_CERTS` to shell profile**

Append this to `~/.zshrc` (adjust path as needed):

```bash
export NODE_EXTRA_CA_CERTS="$HOME/Developer/personal/aimonitor/caddy-local-root.crt"
```

Open a new shell (or `source ~/.zshrc` in the current one), then re-run Step 8:

```bash
node -e "require('https').get('https://aimonitor.local/api/health', r => console.log('OK', r.statusCode)).on('error', e => console.error('FAIL', e.code))"
```
Expected: `OK 200`.

- [ ] **Step 10: Run smoke test**

Run: `just smoke`
Expected: all checks `PASS`; final line `Results: N passed, 0 failed`.

- [ ] **Step 11: (Optional) Verify Claude Code OTLP end-to-end**

In one terminal, tail the collector:
```bash
just logs otel-collector
```

In another terminal:
```bash
CLAUDE_CODE_ENABLE_TELEMETRY=1 \
OTEL_METRICS_EXPORTER=otlp \
OTEL_LOGS_EXPORTER=otlp \
OTEL_EXPORTER_OTLP_ENDPOINT=https://aimonitor.local:4317 \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${OTEL_BEARER_TOKEN}" \
OTEL_RESOURCE_ATTRIBUTES="developer.name=$(whoami),team=myteam" \
claude -p "hello"
```
(`OTEL_BEARER_TOKEN` must be in your shell env; source `.env` if needed: `set -a && . ./.env && set +a`.)

Expected in collector logs: metrics or logs batches arriving from this developer; no TLS errors.

- [ ] **Step 12: (No commit)** — this task validates the implementation; it does not modify tracked files.

---

## Post-implementation: prod deploy smoke (optional, runbook)

Not part of this plan, but documented here so the reviewer can sanity-check before a real VPS deploy:

```bash
# On the VPS, in the repo root:
ls docker-compose.local.yml caddy/Caddyfile.local  # both exist but inert
grep '^VPS_DOMAIN=' .env                            # should be the real domain, not .local/.test
docker compose config --quiet && echo "prod config OK"
docker compose up -d                                 # or: just up-prod
docker compose ps                                    # all services running
curl -sI https://YOUR_DOMAIN/api/health              # HTTP/2 200 via Let's Encrypt
```
