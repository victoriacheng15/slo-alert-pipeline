#!/usr/bin/env bash
# ==============================================================================
# verify-tenants.sh: Automated tenant traffic generator and metrics validator
# ==============================================================================
# Flags & Arguments:
#   None (runs automated end-to-end smoke verification against local cluster).
#   -h, --help    Display usage instructions and exit.
#
# Environment Overrides:
#   PROMETHEUS_PORT   Local port for Prometheus (default: 9090)
#   CHECKOUT_PORT     Local port for Checkout service (default: 18081)
#   INVENTORY_PORT    Local port for Inventory service (default: 18082)
#
# Usage:
#   bash scripts/verify-tenants.sh
# ==============================================================================
set -euo pipefail

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  grep '^#' "$0" | cut -c 3-
  exit 0
fi

PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
CHECKOUT_PORT="${CHECKOUT_PORT:-18081}"
INVENTORY_PORT="${INVENTORY_PORT:-18082}"

cleanup() {
  bash scripts/port-forward.sh stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

bash scripts/port-forward.sh start drill

echo "[+] Sending synthetic traffic to tenants..."
CHECKOUT_RESP=$(curl -s "http://localhost:${CHECKOUT_PORT}/api/checkout/process")
INVENTORY_RESP=$(curl -s "http://localhost:${INVENTORY_PORT}/api/inventory/items")

echo "    Checkout response:  ${CHECKOUT_RESP}"
echo "    Inventory response: ${INVENTORY_RESP}"

echo "[+] Waiting 10s for Prometheus scrape interval..."
sleep 10

echo "[+] Querying Prometheus active targets..."
curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" | python3 -c "
import json, sys
data = json.load(sys.stdin)
targets = [t for t in data['data']['activeTargets'] if 'checkout' in t['labels'].get('job', '') or 'inventory' in t['labels'].get('job', '')]
for t in targets:
    job = t['labels'].get('job', 'unknown')
    health = t.get('health', 'unknown')
    node = t['labels'].get('node', 'missing')
    tenant = t['labels'].get('tenant', 'missing')
    print(f'    [{health.upper()}] Job: {job:<20} Tenant: {tenant:<18} Node: {node}')
"

echo "[+] Querying Prometheus metric: http_requests_total..."
curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/query?query=http_requests_total" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if not results:
    print('    [-] No metrics returned yet.')
    sys.exit(1)
for r in results:
    m = r['metric']
    tenant = m.get('tenant', 'none')
    service = m.get('service', 'none')
    route = m.get('route', 'none')
    node = m.get('node', 'none')
    count = r['value'][1]
    print(f'    Tenant: {tenant:<18} Service: {service:<12} Route: {route:<24} Node: {node:<10} Value: {count}')
"

echo "[+] Verification completed successfully."
