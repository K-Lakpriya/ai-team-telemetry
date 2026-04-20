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
# openssl on macOS does NOT read the system keychain, so we point it at the
# extracted CA file that 'just trust-cert' writes to the repo root.
CA_FILE="$(pwd)/caddy-local-root.crt"
check "Caddy OTLP :4317 TLS handshake" \
  "openssl s_client -CAfile '${CA_FILE}' -connect ${OTLP_HOST}:${OTLP_PORT} -servername ${OTLP_HOST} -verify_return_error </dev/null 2>&1" \
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
