# Architectural Decision Records (ADR)

This directory contains the architectural decisions made during the evolution of the project.

| ID | Title | Description | Status |
| :--- | :--- | :--- | :--- |
| 001 | [Multi-Window Multi-Burn-Rate Alerting Strategy](./001-multi-window-burn-rate-strategy.md) | Standardizes dual-window burn-rate calculations (14.4x fast burn, 6x slow burn for 99.5% SLO) | Accepted |
| 002 | [Topology-Aware Downward API Relabeling and Alert Inhibition](./002-topology-aware-inhibition-relabeling.md) | Suppresses downstream application alerts during underlying Kubernetes node infrastructure outages | Accepted |
