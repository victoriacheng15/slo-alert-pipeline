#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# bootstrap.sh: Idempotent local cluster bootstrap and base stack provisioning
# ==============================================================================
# Flags & Arguments:
#   None (runs idempotent provisioning against current kubectl context).
#   -h, --help    Display usage instructions and exit.
#
# Environment Overrides:
#   HELM_RELEASE_NAME   Helm release name (default: "kube-prometheus-stack")
#   MONITORING_NS       Monitoring namespace (default: "monitoring")
#   CHECKOUT_NS         Checkout tenant namespace (default: "tenant-checkout")
#   INVENTORY_NS        Inventory tenant namespace (default: "tenant-inventory")
#
# Usage:
#   bash scripts/bootstrap.sh
# ==============================================================================

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  grep '^#' "$0" | cut -c 3-
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-kube-prometheus-stack}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
CHECKOUT_NS="${CHECKOUT_NS:-tenant-checkout}"
INVENTORY_NS="${INVENTORY_NS:-tenant-inventory}"

echo "=== [1/7] Preflight Checks ==="
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl is required but not installed." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Error: helm is required but not installed." >&2; exit 1; }

echo "Kubernetes context: $(kubectl config current-context)"

echo "=== [2/7] Provisioning Namespaces ==="
for ns in "${MONITORING_NS}" "${CHECKOUT_NS}" "${INVENTORY_NS}"; do
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    echo "Creating namespace: ${ns}"
    kubectl create namespace "${ns}"
  else
    echo "Namespace ${ns} already exists."
  fi
done

echo "=== [3/7] Setting Up Helm Repositories ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community

echo "=== [4/7] Deploying Base Observability Stack ==="
helm upgrade --install "${HELM_RELEASE_NAME}" prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NS}" \
  --values "${REPO_ROOT}/manifests/base/values.yaml" \
  --wait --timeout 5m

echo "=== [5/7] Deploying Webhook Sink, Root Alertmanager Routing & Dashboards ==="
kubectl apply -f "${REPO_ROOT}/manifests/base/webhook-sink.yaml"
kubectl apply -f "${REPO_ROOT}/manifests/base/alertmanager-root-config.yaml"
if [[ -f "${REPO_ROOT}/dashboards/slo-overview.json" ]]; then
  echo "Importing Grafana dashboard (slo-overview.json)..."
  kubectl create configmap grafana-dashboard-slo-overview \
    --from-file=slo-overview.json="${REPO_ROOT}/dashboards/slo-overview.json" \
    --namespace="${MONITORING_NS}" \
    --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard="1" app.kubernetes.io/part-of="slo-alert-pipeline" -o yaml | \
  kubectl apply -f -
fi

echo "=== [6/7] Applying Core Prometheus Rules ==="
kubectl apply -f "${REPO_ROOT}/manifests/rules/"

echo "=== [7/7] Deploying Tenant Workloads & ServiceMonitors ==="
kubectl apply -R -f "${REPO_ROOT}/manifests/tenants/"

echo "Waiting for monitoring and tenant components to reach ready state..."
kubectl rollout status deployment/"${HELM_RELEASE_NAME}"-operator -n "${MONITORING_NS}" --timeout=120s
kubectl rollout status deployment/webhook-sink -n "${MONITORING_NS}" --timeout=120s
kubectl rollout status deployment/checkout-service -n "${CHECKOUT_NS}" --timeout=120s
kubectl rollout status deployment/inventory-service -n "${INVENTORY_NS}" --timeout=120s

echo ""
echo "================================================================="
echo " Bootstrap Complete! Pipeline and Tenant Workloads are Healthy."
echo "================================================================="
echo "Active Pods in ${MONITORING_NS}:"
kubectl get pods -n "${MONITORING_NS}"
echo ""
echo "Active Pods in ${CHECKOUT_NS} & ${INVENTORY_NS}:"
kubectl get pods -n "${CHECKOUT_NS}"
kubectl get pods -n "${INVENTORY_NS}"
echo ""
echo "Access Services via Port-Forwarding:"
echo "  Prometheus:   kubectl port-forward -n ${MONITORING_NS} svc/${HELM_RELEASE_NAME}-prometheus 9090:9090"
echo "  Alertmanager: kubectl port-forward -n ${MONITORING_NS} svc/${HELM_RELEASE_NAME}-alertmanager 9093:9093"
echo "  Grafana:      kubectl port-forward -n ${MONITORING_NS} svc/${HELM_RELEASE_NAME}-grafana 3000:80"
echo "  Checkout:     kubectl port-forward -n ${CHECKOUT_NS} svc/checkout-service 18081:8080"
echo "  Inventory:    kubectl port-forward -n ${INVENTORY_NS} svc/inventory-service 18082:8080"
echo "  Webhook Sink: kubectl logs -n ${MONITORING_NS} -l app=webhook-sink -f"
echo "================================================================="
