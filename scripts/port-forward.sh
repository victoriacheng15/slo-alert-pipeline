#!/usr/bin/env bash
# ==============================================================================
# port-forward.sh: Centralized port-forward management for SLO Alert Pipeline
# ==============================================================================
# Usage:
#   ./scripts/port-forward.sh [COMMAND] [TARGET]
#
# Commands:
#   start [TARGET]  Start port-forwards in the background and wait until ready.
#   stop            Stop background port-forwards tracked in the PID file.
#   run [TARGET]    Run port-forwards in the foreground (blocks until Ctrl+C / SIGINT).
#   status          Check and report whether target service ports are currently open.
#   help            Display usage instructions and exit.
#
# Targets:
#   ui              Prometheus (9090), Alertmanager (9093), Grafana (3000)
#   tenants         Checkout (18081), Inventory (18082)
#   drill           Prometheus (9090), Alertmanager (9093), Checkout (18081), Inventory (18082)
#   all             All services across monitoring and tenant namespaces (default for start)
#
# Flags:
#   -h, --help      Display usage information and exit.
# ==============================================================================
set -euo pipefail

PID_FILE="${TMPDIR:-/tmp}/slo-pipeline-pf.pid"

is_port_open() {
  local port=$1
  (echo > /dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
}

wait_for_port() {
  local port=$1
  local retries=20
  while ! is_port_open "${port}"; do
    retries=$((retries - 1))
    if [[ ${retries} -le 0 ]]; then
      echo "  [-] Timed out waiting for localhost:${port}" >&2
      return 1
    fi
    sleep 0.25
  done
}

forward_port() {
  local ns="$1"
  local svc="$2"
  local local_port="$3"
  local remote_port="$4"
  local label="$5"

  if is_port_open "${local_port}"; then
    echo "  [*] ${label} already accessible on localhost:${local_port}"
    return 0
  fi

  echo "  [+] Forwarding ${label} (localhost:${local_port} -> ${ns}/${svc}:${remote_port})..."
  kubectl port-forward -n "${ns}" "${svc}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  echo "${pid}" >> "${PID_FILE}"
  wait_for_port "${local_port}"
}

stop_forwards() {
  if [[ -f "${PID_FILE}" ]]; then
    echo "[+] Stopping managed port-forward processes..."
    while IFS= read -r pid; do
      if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
      fi
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
    echo "[+] Managed port-forwards stopped."
  else
    echo "[*] No active managed port-forwards found in ${PID_FILE}."
  fi
}

start_targets() {
  local target="${1:-all}"
  case "${target}" in
    ui)
      echo "[+] Starting UI port-forwards..."
      forward_port "monitoring" "svc/kube-prometheus-stack-prometheus" 9090 9090 "Prometheus"
      forward_port "monitoring" "svc/kube-prometheus-stack-alertmanager" 9093 9093 "Alertmanager"
      forward_port "monitoring" "svc/kube-prometheus-stack-grafana" 3000 80 "Grafana"
      ;;
    tenants)
      echo "[+] Starting Tenant port-forwards..."
      forward_port "tenant-checkout" "svc/checkout-service" 18081 8080 "Checkout Service"
      forward_port "tenant-inventory" "svc/inventory-service" 18082 8080 "Inventory Service"
      ;;
    drill)
      echo "[+] Starting Drill port-forwards (Observability + Tenants)..."
      forward_port "monitoring" "svc/kube-prometheus-stack-prometheus" 9090 9090 "Prometheus"
      forward_port "monitoring" "svc/kube-prometheus-stack-alertmanager" 9093 9093 "Alertmanager"
      forward_port "monitoring" "svc/kube-prometheus-stack-grafana" 3000 80 "Grafana"
      forward_port "tenant-checkout" "svc/checkout-service" 18081 8080 "Checkout Service"
      forward_port "tenant-inventory" "svc/inventory-service" 18082 8080 "Inventory Service"
      ;;
    all)
      echo "[+] Starting all port-forwards..."
      forward_port "monitoring" "svc/kube-prometheus-stack-prometheus" 9090 9090 "Prometheus"
      forward_port "monitoring" "svc/kube-prometheus-stack-alertmanager" 9093 9093 "Alertmanager"
      forward_port "monitoring" "svc/kube-prometheus-stack-grafana" 3000 80 "Grafana"
      forward_port "tenant-checkout" "svc/checkout-service" 18081 8080 "Checkout Service"
      forward_port "tenant-inventory" "svc/inventory-service" 18082 8080 "Inventory Service"
      ;;
    *)
      echo "Unknown target: ${target}. Options: ui, tenants, drill, all." >&2
      exit 1
      ;;
  esac
}

run_foreground() {
  local target="${1:-ui}"
  trap stop_forwards EXIT INT TERM

  start_targets "${target}"

  echo ""
  echo "Port-forward session active (Press Ctrl+C to terminate):"
  if [[ "${target}" =~ ^(ui|all|drill)$ ]]; then
    echo "  - Prometheus:   http://localhost:9090"
    echo "  - Alertmanager: http://localhost:9093"
  fi
  if [[ "${target}" =~ ^(ui|all)$ ]]; then
    echo "  - Grafana:      http://localhost:3000 (admin/admin)"
  fi
  if [[ "${target}" =~ ^(tenants|all|drill)$ ]]; then
    echo "  - Checkout:     http://localhost:18081"
    echo "  - Inventory:    http://localhost:18082"
  fi
  echo ""

  # Keep foreground process alive until signal
  while true; do
    sleep 1
  done
}

status_forwards() {
  echo "Checking endpoint statuses:"
  local ports=(
    "9090:Prometheus"
    "9093:Alertmanager"
    "3000:Grafana"
    "18081:Checkout"
    "18082:Inventory"
  )
  for entry in "${ports[@]}"; do
    local port="${entry%%:*}"
    local name="${entry##*:}"
    if is_port_open "${port}"; then
      printf "  [OPEN]   %-14s (localhost:%s)\n" "${name}" "${port}"
    else
      printf "  [CLOSED] %-14s (localhost:%s)\n" "${name}" "${port}"
    fi
  done
}

# Command dispatch
CMD="${1:-run}"
TARGET="${2:-ui}"

case "${CMD}" in
  start)
    start_targets "${TARGET}"
    ;;
  stop)
    stop_forwards
    ;;
  run)
    run_foreground "${TARGET}"
    ;;
  status)
    status_forwards
    ;;
  help|--help|-h)
    echo "Usage: $0 [start|stop|run|status] [ui|tenants|drill|all]"
    echo ""
    echo "Commands:"
    echo "  start [target]  Start port-forwards in the background and wait until ready"
    echo "  stop            Stop background port-forwards tracked by this script"
    echo "  run [target]    Run port-forwards in the foreground (Ctrl+C to stop)"
    echo "  status          Check if service ports are currently open"
    echo ""
    echo "Targets:"
    echo "  ui              Prometheus (9090), Alertmanager (9093), Grafana (3000)"
    echo "  tenants         Checkout (18081), Inventory (18082)"
    echo "  drill           Prometheus (9090), Alertmanager (9093), Checkout (18081), Inventory (18082)"
    echo "  all             All services (default for start)"
    ;;
  *)
    echo "Unknown command: ${CMD}. Run '$0 help' for usage." >&2
    exit 1
    ;;
esac
