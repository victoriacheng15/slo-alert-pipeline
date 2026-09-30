# Multi-Tenant Kubernetes SLO Alert Pipeline

An observability and alerting pipeline for Kubernetes running on local clusters (such as k3s or kind). It demonstrates multi-window multi-burn-rate alerting for a 99.5% SLO, routes alerts independently per tenant namespace, suppresses cascade noise during node outages using topology-aware inhibition, and provides a Python-based synthetic chaos drill to verify the entire alerting lifecycle.

---

## Architectural Overview

![Architecture](docs/assets/architecture.png)

Full architecture specifications, MWMBR mathematics, and inhibition flows are documented in [System Architecture](docs/architecture.md).

---

## Local Quickstart

### Prerequisites

- Container runtime: `podman` or `docker`
- Kubernetes cluster: Local `k3s` or `kind`
- Developer toolchain: [mise](https://mise.jdx.dev) (pins `promtool`, `yamllint`, `kubeconform`, `actionlint`) and [uv](https://docs.astral.sh/uv/)

### Install Tools & Lint

```bash
make tools-install
make validate
```

### Bootstrap Cluster

Provisions namespaces, deploys `kube-prometheus-stack` via Helm, applies recording rules, webhook sink, and tenant workloads:

```bash
make bootstrap
```

### Start Observability Port-Forwards

```bash
# Forward Grafana (3000), Prometheus (9090), and Alertmanager (9093)
make port-forward

# Or forward all observability UIs plus tenant services (18081, 18082):
make port-forward-all
```

- **Grafana Dashboard:** `http://localhost:3000` (User: `admin`, Pass: `admin`)
- **Prometheus UI:** `http://localhost:9090`
- **Alertmanager UI:** `http://localhost:9093`
- **Checkout Service:** `http://localhost:18081`
- **Inventory Service:** `http://localhost:18082`

---

## End-to-End Verification Chaos Drill

The automated verification engine (`scripts/drill-burn-budget.py`) executes a 4-phase chaos lifecycle against the live cluster:

```bash
make drill
```

```text
Phase 1: Baseline Healthy State
  - Injects 0% errors, sends clean traffic, asserts 0 active burn-rate alerts.

Phase 2: Error Budget Burn Injection
  - Injects 15% error rate on tenant-inventory (>7.2% threshold for 99.5% SLO).
  - Continuously polls Alertmanager until SLOErrorBudgetFastBurnLocal transitions to firing.

Phase 3: Topology-Aware Inhibition
  - Injects synthetic KubeNodeNotReady on the specific node running tenant-inventory.
  - Polls Alertmanager v2 API and asserts alert state transitions to "suppressed" (inhibitedBy).

Phase 4: Clean Recovery
  - Resets chaos error rate to 0.0, flushes clean requests, asserts alert clears completely.
```

---

## Troubleshooting & Diagnostics

Diagnostic workflows, queries, and triage steps are documented in [Troubleshooting Guide](docs/troubleshooting.md).
