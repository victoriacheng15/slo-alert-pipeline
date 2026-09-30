# ADR 001: Multi-Window Multi-Burn-Rate Alerting Strategy

- **Status:** Accepted
- **Date:** 2026-09-29
- **Author:** Victoria Cheng

## Context and Problem Statement

While exploring SRE reliability patterns, I became curious about how teams solve alert fatigue in practice. Single-window threshold alerting suffers from a severe trade-off between detection speed and reset latency. If an alert evaluates over a short window (e.g., 5 minutes), brief transient traffic spikes or network hiccups trigger spurious wake-up pages. Conversely, if an alert evaluates over a long window (e.g., 6 hours) to smooth noise, catastrophic outages take hours to trigger, and once resolved, the alert remains active for hours while the historical window drains.

I wanted to explore how the Multi-Window Multi-Burn-Rate (MWMBR) pattern works in practice by building a hands-on Kubernetes lab enforcing a 99.5% Service Level Objective (0.5% allowed error budget over 30 days) across mock tenant workloads.

## Decision Outcome

Implement and evaluate the Google Site Reliability Engineering (SRE) Multi-Window Multi-Burn-Rate (MWMBR) alerting pattern. An alert only fires when consumption rates exceed predefined burn-rate thresholds across both a short detection window and a long verification window simultaneously:

1. **Burn Rate Mathematics (Deriving 14.4x and 7.2%):**
   - **Universal Formulas:**
     $$\text{Burn Rate Multiplier} = \left(\frac{\text{Budget Fraction Consumed}}{\text{Lookback Window Hours}}\right) \times 720\text{ hours}$$
     $$\text{Error Rate Threshold} = \text{Burn Rate Multiplier} \times (1 - \text{SLO})$$
   - **Baseline Inputs:**
     - Evaluation Period: 30 days = $30 \times 24 = 720\text{ hours}$.
     - Allowed Error Budget ($1 - \text{SLO}$): $1 - 0.995 = 0.005$ ($0.5\%$).
   - **Fast Burn (Page):** Targets 2% ($0.02$) budget consumed in 1 hour:
     - Burn Rate Multiplier: $\left(\frac{0.02}{1\text{ hour}}\right) \times 720 = \mathbf{14.4x}$
     - Error Rate Threshold: $14.4 \times (1 - 0.995) = 14.4 \times 0.005 = \mathbf{0.072} \ (7.2\%)$
     - Dual-window pair: 5-minute short window AND 1-hour long window (or 2m / 15m in the local drill profile).
   - **Slow Burn (Ticket):** Targets 5% ($0.05$) budget consumed in 6 hours:
     - Burn Rate Multiplier: $\left(\frac{0.05}{6\text{ hours}}\right) \times 720 = \mathbf{6.0x}$
     - Error Rate Threshold: $6.0 \times (1 - 0.995) = 6.0 \times 0.005 = \mathbf{0.030} \ (3.0\%)$
     - Dual-window pair: 30-minute short window AND 6-hour long window.

2. **Precomputed Rates via Prometheus Recording Rules:**
   - Calculate rates in `manifests/rules/recording-rules.yaml` (`tenant_job:http_requests:rate*` and `tenant_job:http_requests_errors:rate*`) at 10-second intervals to minimize PromQL query load during alert evaluation.

## Consequences

### Positive

- **Filters Out Short Spikes:** During testing, 1-minute to 2-minute error blips did not trigger false alarms because the longer window remained well below the threshold.
- **Resets Fast After Fixing:** As soon as errors stopped in the chaos drill, the alert cleared within minutes because the short window dropped immediately, rather than waiting hours for the 1-hour average to drain.
- **Reduces Query Load:** Precomputing rates with Prometheus recording rules keeps Alertmanager evaluation fast and lightweight, rather than scanning 1 hour of raw request history on every check.

### Negative

- **More Metrics in Prometheus:** Precomputing rates across multiple windows (2m, 5m, 15m, 30m, 1h, 6h) means Prometheus creates and stores additional time-series in memory.
- **Impractical to Test Long Windows Locally:** Waiting 6 hours on a local machine to test a slow-burn alert is not feasible. I had to build a compressed 2m/15m drill profile specifically for fast local testing.

## Verification

- [x] **Automated Tests:** PromQL unit tests in `tests/promtool/recording-rules-test.yaml` and `tests/promtool/burn-rates-test.yaml` pass via `promtool`.
- [x] **Live Chaos Drill:** Synthetic drill engine (`scripts/drill-burn-budget.py --profile local`) successfully detects and triggers `SLOErrorBudgetFastBurnLocal` within 15 to 70 seconds.

## References

- [Google SRE Workbook: Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
