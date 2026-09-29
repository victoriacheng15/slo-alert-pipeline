#!/usr/bin/env bash
# ==============================================================================
# verify-tenants.sh: Automated tenant traffic generator and metrics validator
# ==============================================================================
set -euo pipefail

PROMETHEUS_PORT=9090
CHECKOUT_PORT=18081
INVENTORY_PORT=18082

cleanup() {
  # Kill any background port-forward processes started by this script
  local pids
  pids=$(jobs -p 2>/dev/null || true)
  if [[ -n "${pids}" ]]; then
    kill ${pids} 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

wait_for_port() {
  local port=$1
  local retries=15
  while ! nc -z localhost "${port}" 2>/dev/null && ! (echo > /dev/tcp/localhost/"${port}") 2>/dev/null; do
    retries=$((retries - 1))
    if [[ ${retries} -le 0 ]]; then
      echo "[-] Timed out waiting for localhost:${port}"
      return 1
    fi
    sleep 0.5
  done
}

echo "[+] Starting background port-forwards..."
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus "${PROMETHEUS_PORT}:9090" >/dev/null 2>&1 &
kubectl port-forward -n tenant-checkout svc/checkout-service "${CHECKOUT_PORT}:8080" >/dev/null 2>&1 &
kubectl port-forward -n tenant-inventory svc/inventory-service "${INVENTORY_PORT}:8080" >/dev/null 2>&1 &

wait_for_port "${PROMETHEUS_PORT}"
wait_for_port "${CHECKOUT_PORT}"
wait_for_port "${INVENTORY_PORT}"
echo "[+] Port-forwards established."

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
