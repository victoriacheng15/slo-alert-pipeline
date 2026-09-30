# Troubleshooting & Operational Guide

This document outlines diagnostic workflows and queries for triaging SLO alerts and alert routing issues within the cluster.

---

## Quick Diagnostic Overview

When an alert fires, triage typically follows these steps:

1. **Verify Alert Scope:** Identify the `tenant` (`tenant-checkout`, `tenant-inventory`) and `service` from alert labels.
2. **Check Node Status:** Check if an underlying node issue exists (`kubectl get nodes`). Alertmanager topology inhibition automatically suppresses tenant alerts if `KubeNodeNotReady` is firing for that node.
3. **Inspect Pods & Logs:** Verify pod health and container restart counts in the tenant namespace.
4. **Run PromQL Diagnostics:** Inspect error rate percentages and burn rates in Grafana or the Prometheus UI.

---

## Fast Burn Troubleshooting (`SLOErrorBudgetFastBurn`)

### Symptoms
- Multiplier exceeds 14.4x across short (5m) and long (1h) windows (or 2m / 15m in the local drill profile).
- Error rate exceeds 7.2% against the 99.5% SLO target.

### Diagnostic Steps

1. **Inspect Tenant Pods:**
   ```bash
   # Example: tenant-inventory (or tenant-checkout)
   kubectl get pods -n tenant-inventory -o wide
   kubectl describe pod -l app=inventory-service -n tenant-inventory
   ```

2. **Check Application Logs:**
   ```bash
   kubectl logs -n tenant-inventory -l app=inventory-service --tail=50 -f
   ```

3. **Query Error Rates in Prometheus (`http://localhost:9090`):**
   ```promql
   100 * (
     sum by (tenant, service, route, status) (
       rate(http_requests_total{status=~"5.."}[5m])
     )
     /
     sum by (tenant, service, route, status) (
       rate(http_requests_total[5m])
     )
   )
   ```

4. **Reset Chaos Injection (if running local drills):**
   ```bash
   # Reset checkout service chaos
   curl -X POST http://localhost:18081/chaos/configure \
     -H "Content-Type: application/json" \
     -d '{"error_rate": 0.0, "latency_ms": 0}'

   # Reset inventory service chaos
   curl -X POST http://localhost:18082/chaos/configure \
     -H "Content-Type: application/json" \
     -d '{"error_rate": 0.0, "latency_ms": 0}'
   ```

5. **Verify Alert Resolution:**
   Confirm that the burn rate drops below 1.0 and the alert clears from Alertmanager (`http://localhost:9093`).

---

## Slow Burn Troubleshooting (`SLOErrorBudgetSlowBurn`)

### Symptoms
- Multiplier exceeds 6.0x across 30m and 6h windows.
- Error rate exceeds 3.0%, indicating gradual budget erosion.

### Diagnostic Steps

1. **Open Grafana Overview (`http://localhost:3000/d/slo-overview`):**
   Select the affected `$tenant` from the dashboard dropdown and examine the 6h error rate trend.

2. **Identify Failing Endpoints:**
   ```promql
   100 * (
     sum by (route, status) (
       rate(http_requests_total{tenant="tenant-inventory", status=~"5.."}[30m])
     )
     /
     sum by (route) (
       rate(http_requests_total{tenant="tenant-inventory"}[30m])
     )
   )
   ```

3. **Check Resource Limits & Restarts:**
   ```bash
   kubectl top pods -n tenant-inventory
   kubectl get pods -n tenant-inventory -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount
   ```

---

## Tenant Alert Routing Diagnostics

Tenant alerts route through `AlertmanagerConfig` CRDs located in tenant namespaces to the in-cluster `webhook-sink`.

### Verify CRD Discovery
```bash
kubectl get alertmanagerconfig -A
kubectl describe alertmanagerconfig -n tenant-checkout
kubectl describe alertmanagerconfig -n tenant-inventory
```

### Check Alertmanager Dispatch Logs
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager -c alertmanager --tail=100 | grep -iE "error|notify|webhook"
```

### Verify Webhook Sink Logs
Incoming alert payloads are logged directly by the sink pod:
```bash
kubectl logs -n monitoring -l app=webhook-sink --tail=30 -f
```

### Send a Synthetic Test Alert
Test route delivery through Alertmanager:
```bash
curl -X POST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "SyntheticRoutingTest",
      "tenant": "tenant-checkout",
      "namespace": "tenant-checkout",
      "severity": "ticket"
    },
    "annotations": {
      "summary": "Verifying AlertmanagerConfig routing pipeline"
    }
  }]'
```
Check `kubectl logs -n monitoring -l app=webhook-sink --tail=10` to confirm payload delivery.
