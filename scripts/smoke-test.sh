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
  "curl -sf 'http://localhost:9090/api/v1/query?query=up{job=\"otel-collector\"}' | python3 -c \"import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else 'no_data')\"" \
  "1"

# 6. Grafana datasources provisioned
check "Grafana Prometheus datasource" \
  "curl -sf -u admin:${GF_SECURITY_ADMIN_PASSWORD:-admin} http://localhost:3000/api/datasources/name/Prometheus" \
  "prometheus"

check "Grafana Loki datasource" \
  "curl -sf -u admin:${GF_SECURITY_ADMIN_PASSWORD:-admin} http://localhost:3000/api/datasources/name/Loki" \
  "loki"

# 7. Grafana dashboards provisioned
check "Grafana dashboards loaded" \
  "curl -sf -u admin:${GF_SECURITY_ADMIN_PASSWORD:-admin} 'http://localhost:3000/api/search?tag=claude-code' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(len(d))\"" \
  "4"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo -e "${YELLOW}Some checks failed. Check 'docker compose logs <service>' for details.${NC}"
  exit 1
fi
echo -e "${GREEN}All checks passed.${NC}"
