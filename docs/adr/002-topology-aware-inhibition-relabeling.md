# ADR 002: Topology-Aware Downward API Relabeling and Alert Inhibition

- **Status:** Accepted
- **Date:** 2026-09-29
- **Author:** Victoria Cheng

## Context and Problem Statement

While experimenting with node failure scenarios on Kubernetes, I observed a common operational problem: when a node crashes or enters a `NotReady` state, all tenant pods scheduled on that node immediately become unreachable. Standard Prometheus scraping reports request drops and elevated 5xx error rates, triggering multiple downstream `SLOErrorBudgetFastBurn` alerts across different tenants.

This creates cascading alert noise during infrastructure outages: multiple application-tier alerts fire across tenant namespaces when the actual root cause is a single failed node. I wanted to explore how Alertmanager could automatically suppress application-level SLO alerts when an underlying node failure alert is already active for the specific node running those workloads.

## Decision Outcome

Implement and evaluate topology-aware alert inhibition using Prometheus Operator target relabeling and root Alertmanager inhibition rules:

1. **Topology Label Injection:**
   - In each tenant `ServiceMonitor` (`manifests/tenants/*/service-monitor.yaml`), use Prometheus relabel configs to map `__meta_kubernetes_pod_node_name` directly to a standardized `node` label on all ingested time-series.
   - Map `__meta_kubernetes_namespace` to `tenant`.

2. **Cross-Namespace Matcher Strategy:**
   - By default, Prometheus Operator enforces `OnNamespace` matching, which prevents alerts generated in `monitoring` (`KubeNodeNotReady`) from matching or inhibiting tenant alerts generated in `tenant-checkout` or `tenant-inventory`.
   - Configure `alertmanagerConfigMatcherStrategy: { type: "OnNamespaceExceptForAlertmanagerNamespace" }` and `alertmanagerConfiguration: { name: alertmanager-root-config }` in `manifests/base/values.yaml`.

3. **Topology-Equal Inhibition Rules:**
   - Define top-level `inhibit_rules` in `manifests/base/alertmanager-root-config.yaml`.
   - The source alert `KubeNodeNotReady` suppresses target alerts (`SLOErrorBudgetFastBurn`, `SLOErrorBudgetFastBurnLocal`, `SLOErrorBudgetSlowBurn`) when their `node` label values match (`equal: ['node']`).

## Consequences

### Positive

- **Silences Cascading Noise:** When a node crashes, Alertmanager suppresses the application-tier error budget alerts and delivers only the node failure alert, keeping the focus on the root cause.
- **Node-Specific Isolation:** The `equal: ['node']` rule only silences pods that were actually scheduled on the failed node. Workloads running normally on other nodes continue alerting without interruption.
- **Zero Application Changes:** The application code (`workloads/mock-app`) does not need to know what node it is running on. Prometheus Operator automatically injects the node label via Kubernetes service discovery metadata.

### Negative

- **Extra Metric Data:** Adding the `node` label to all request metrics creates more label combinations for Prometheus to store in memory.
- **Depends on ServiceMonitor Configuration:** Any new tenant workload must include the Downward API relabeling block in its `ServiceMonitor`. If someone forgets it, the alert will lack the `node` label and will not be suppressed during an outage.

## Verification

- [x] **Relabeling Inspection:** Verified via `curl -s http://localhost:9090/api/v1/targets` that tenant scrape targets report `node="fedora"` and `tenant="tenant-*"`.
- [x] **Chaos Verification Drill:** In `scripts/drill-burn-budget.py` Phase 3, injected synthetic `KubeNodeNotReady` on node `fedora` and asserted Alertmanager REST API reports `state="suppressed"` and populated `inhibitedBy` IDs on the firing SLO alert.
