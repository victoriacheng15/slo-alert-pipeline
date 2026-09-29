#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "httpx>=0.27.0",
#     "rich>=13.7.0",
# ]
# ///
"""
Synthetic Drill Engine for Multi-Tenant SLO Alert Pipeline.
Executes phased chaos injection, verifies multi-window burn rate alerts,
tests topology-aware Alertmanager inhibition, and asserts clean recovery.

CLI Flags:
  --profile {local,homelab}
      Alert profile to evaluate: 'local' (2m/15m windows) or 'homelab' (5m/1h windows).
      Default: 'local'.
  --prometheus-url URL
      Prometheus base endpoint URL. Default: 'http://localhost:9090'.
  --alertmanager-url URL
      Alertmanager base endpoint URL. Default: 'http://localhost:9093'.
  --checkout-url URL
      Checkout tenant service endpoint URL. Default: 'http://localhost:18081'.
  --inventory-url URL
      Inventory tenant service endpoint URL. Default: 'http://localhost:18082'.
  --skip-port-forward
      Bypass automated background port-forwarding via scripts/port-forward.sh.
  -h, --help
      Display command-line help message and exit.

Usage:
  uv run scripts/drill-burn-budget.py --profile local
  uv run scripts/drill-burn-budget.py --profile homelab --skip-port-forward
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import subprocess
import sys
import time
from typing import Any, Dict, List

import httpx
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()


class PortForwardManager:
    """Delegates port-forwarding lifecycle to scripts/port-forward.sh."""

    @staticmethod
    def start(target: str = "drill") -> None:
        cmd = ["bash", "scripts/port-forward.sh", "start", target]
        subprocess.run(cmd, check=True)

    @staticmethod
    def stop() -> None:
        cmd = ["bash", "scripts/port-forward.sh", "stop"]
        subprocess.run(cmd, check=False)


class DrillEngine:
    """Executes verification drill phases against Prometheus, Alertmanager, and workloads."""

    def __init__(
        self,
        profile: str,
        prometheus_url: str,
        alertmanager_url: str,
        checkout_url: str,
        inventory_url: str,
    ) -> None:
        self.profile = profile
        self.prom_url = prometheus_url.rstrip("/")
        self.am_url = alertmanager_url.rstrip("/")
        self.checkout_url = checkout_url.rstrip("/")
        self.inventory_url = inventory_url.rstrip("/")
        self.target_alert = (
            "SLOErrorBudgetFastBurnLocal" if profile == "local" else "SLOErrorBudgetFastBurn"
        )
        self.client = httpx.AsyncClient(timeout=10.0)
        self.results: List[Dict[str, Any]] = []

    async def close(self) -> None:
        await self.client.aclose()

    async def send_traffic(
        self, url: str, count: int, concurrency: int = 5
    ) -> Dict[int, int]:
        """Sends concurrent HTTP traffic to generate RED metric volume."""
        semaphore = asyncio.Semaphore(concurrency)
        status_counts: Dict[int, int] = {}

        async def _fetch() -> None:
            async with semaphore:
                try:
                    resp = await self.client.get(url)
                    status = resp.status_code
                except Exception:
                    status = 0
                status_counts[status] = status_counts.get(status, 0) + 1

        tasks = [asyncio.create_task(_fetch()) for _ in range(count)]
        await asyncio.gather(*tasks)
        return status_counts

    async def configure_chaos(self, base_url: str, error_rate: float, latency_ms: int = 0) -> None:
        """Configures dynamic chaos injection via the mock app REST API."""
        payload = {"error_rate": error_rate, "latency_ms": latency_ms}
        resp = await self.client.post(f"{base_url}/chaos/configure", json=payload)
        resp.raise_for_status()

    async def query_prometheus(self, query: str) -> List[Dict[str, Any]]:
        """Queries Prometheus Instant Vector API."""
        resp = await self.client.get(f"{self.prom_url}/api/v1/query", params={"query": query})
        resp.raise_for_status()
        data = resp.json()
        return data.get("data", {}).get("result", [])

    async def get_alerts(self) -> List[Dict[str, Any]]:
        """Fetches active alerts from Alertmanager v2 API."""
        resp = await self.client.get(f"{self.am_url}/api/v2/alerts")
        resp.raise_for_status()
        return resp.json()

    async def post_synthetic_alert(
        self, alertname: str, labels: Dict[str, str], annotations: Dict[str, str], resolve: bool = False
    ) -> None:
        """Injects or resolves a synthetic alert in Alertmanager."""
        now = datetime.now(timezone.utc)
        starts_at = now.isoformat()
        ends_at = (
            now.isoformat()
            if resolve
            else datetime.fromtimestamp(now.timestamp() + 3600, timezone.utc).isoformat()
        )
        alert_payload = [
            {
                "labels": {"alertname": alertname, **labels},
                "annotations": annotations,
                "startsAt": starts_at,
                "endsAt": ends_at,
            }
        ]
        resp = await self.client.post(f"{self.am_url}/api/v2/alerts", json=alert_payload)
        resp.raise_for_status()

    async def run_baseline_phase(self) -> bool:
        """Phase 1: Baseline. Reset errors, generate healthy traffic, assert 0 burn alerts."""
        console.rule("[bold cyan]Phase 1: Baseline Healthy State[/bold cyan]")
        await self.configure_chaos(self.inventory_url, error_rate=0.0)

        console.log("Sending clean traffic (50 requests to checkout, 50 to inventory)...")
        c_stats = await self.send_traffic(f"{self.checkout_url}/api/checkout/process", count=50)
        i_stats = await self.send_traffic(f"{self.inventory_url}/api/inventory/items", count=50)
        console.log(f"Checkout Statuses: {c_stats} | Inventory Statuses: {i_stats}")

        console.log("Asserting 0 SLO burn alerts are active...")
        start = time.time()
        slo_alerts = []
        while time.time() - start < 30:
            alerts = await self.get_alerts()
            slo_alerts = [
                a for a in alerts
                if a.get("labels", {}).get("alertname") == self.target_alert
                and a.get("status", {}).get("state") == "active"
            ]
            if len(slo_alerts) == 0:
                break
            await asyncio.sleep(2)

        passed = len(slo_alerts) == 0
        self.results.append({
            "phase": "1. Baseline",
            "target": "tenant-inventory",
            "expected": f"0 active {self.target_alert}",
            "actual": f"{len(slo_alerts)} active",
            "passed": passed,
        })
        return passed

    async def run_burn_rate_phase(self) -> bool:
        """Phase 2: Burn Rate Injection. Inject 15% errors on tenant-inventory, assert alert fires."""
        console.rule(f"[bold cyan]Phase 2: Error Budget Burn ({self.target_alert})[/bold cyan]")
        console.log("Configuring 15% error rate on tenant-inventory (SLO threshold: >7.2%)...")
        await self.configure_chaos(self.inventory_url, error_rate=0.15)

        start_time = time.time()
        max_wait = 180 if self.profile == "local" else 600
        alert_detected = False
        discovered_node = "unknown"

        console.log(f"Generating continuous traffic and polling Alertmanager (timeout: {max_wait}s)...")
        while time.time() - start_time < max_wait:
            await self.send_traffic(f"{self.inventory_url}/api/inventory/items", count=25, concurrency=5)
            alerts = await self.get_alerts()
            for a in alerts:
                labels = a.get("labels", {})
                if labels.get("alertname") == self.target_alert and labels.get("tenant") == "tenant-inventory":
                    alert_detected = True
                    discovered_node = labels.get("node", "missing")
                    elapsed = round(time.time() - start_time, 1)
                    console.log(
                        f"[bold green]Alert {self.target_alert} fired in {elapsed}s on node: {discovered_node}[/bold green]"
                    )
                    break
            if alert_detected:
                break
            await asyncio.sleep(5)

        self.discovered_node = discovered_node
        self.results.append({
            "phase": f"2. Burn Rate ({self.target_alert})",
            "target": "tenant-inventory",
            "expected": "Alert Firing",
            "actual": f"Firing on node {discovered_node}" if alert_detected else "Did not fire",
            "passed": alert_detected,
        })
        return alert_detected

    async def run_inhibition_phase(self) -> bool:
        """Phase 3: Topology Inhibition. Inject KubeNodeNotReady on the node and assert alert is suppressed."""
        console.rule("[bold cyan]Phase 3: Topology-Aware Inhibition[/bold cyan]")
        node = getattr(self, "discovered_node", "fedora")
        console.log(f"Injecting synthetic KubeNodeNotReady alert for node: [bold yellow]{node}[/bold yellow]...")

        await self.post_synthetic_alert(
            alertname="KubeNodeNotReady",
            labels={"node": node, "severity": "critical", "condition": "Ready", "status": "False"},
            annotations={"summary": f"Simulated node {node} NotReady failure for inhibition test"},
            resolve=False,
        )

        console.log("Polling Alertmanager to confirm inhibition / suppression of SLO alert...")
        inhibited = False
        for _ in range(12):
            await asyncio.sleep(2)
            alerts = await self.get_alerts()
            for a in alerts:
                labels = a.get("labels", {})
                status = a.get("status", {})
                if labels.get("alertname") == self.target_alert and labels.get("node") == node:
                    state = status.get("state")
                    inhibited_by = status.get("inhibitedBy", [])
                    if state == "suppressed" or len(inhibited_by) > 0:
                        inhibited = True
                        console.log(f"[bold green]Alert successfully suppressed by inhibition rules! InhibitedBy: {inhibited_by}[/bold green]")
                        break
            if inhibited:
                break

        console.log("Resolving synthetic KubeNodeNotReady alert...")
        await self.post_synthetic_alert(
            alertname="KubeNodeNotReady",
            labels={"node": node, "severity": "critical", "condition": "Ready", "status": "False"},
            annotations={"summary": "Clearing simulated node failure"},
            resolve=True,
        )

        self.results.append({
            "phase": "3. Topology Inhibition",
            "target": f"node: {node}",
            "expected": "Alert Suppressed",
            "actual": "Suppressed" if inhibited else "Not Suppressed",
            "passed": inhibited,
        })
        return inhibited

    async def run_recovery_phase(self) -> bool:
        """Phase 4: Clean Recovery. Reset chaos, send clean traffic, assert alerts clear."""
        console.rule("[bold cyan]Phase 4: Recovery Verification[/bold cyan]")
        console.log("Resetting chaos error rate to 0.0 on tenant-inventory...")
        await self.configure_chaos(self.inventory_url, error_rate=0.0)

        console.log("Flushing pipeline with clean requests...")
        for _ in range(4):
            await self.send_traffic(f"{self.inventory_url}/api/inventory/items", count=25)
            await asyncio.sleep(2)

        console.log("Waiting for burn rate lookback window to clear...")
        recovered = False
        start_time = time.time()
        timeout = 180

        while time.time() - start_time < timeout:
            alerts = await self.get_alerts()
            target_firing = [
                a for a in alerts
                if a.get("labels", {}).get("alertname") == self.target_alert
                and a.get("labels", {}).get("tenant") == "tenant-inventory"
                and a.get("status", {}).get("state") == "active"
            ]
            if len(target_firing) == 0:
                recovered = True
                console.log("[bold green]Alert cleanly resolved and cleared from active alerts![/bold green]")
                break
            await self.send_traffic(f"{self.inventory_url}/api/inventory/items", count=15)
            await asyncio.sleep(5)

        self.results.append({
            "phase": "4. Clean Recovery",
            "target": "tenant-inventory",
            "expected": "Alert Cleared",
            "actual": "Resolved" if recovered else "Still Active",
            "passed": recovered,
        })
        return recovered

    def print_summary(self) -> bool:
        """Prints a rich summary report of all phase results."""
        console.rule("[bold green]Drill Execution Summary[/bold green]")
        table = Table(title="SLO Alert Pipeline Verification Results", show_lines=True)
        table.add_column("Phase", style="cyan", no_wrap=True)
        table.add_column("Target Scope", style="magenta")
        table.add_column("Expected Behavior", style="white")
        table.add_column("Actual Outcome", style="yellow")
        table.add_column("Status", justify="center")

        all_passed = True
        for r in self.results:
            status = "[bold green]PASS[/bold green]" if r["passed"] else "[bold red]FAIL[/bold red]"
            if not r["passed"]:
                all_passed = False
            table.add_row(
                r["phase"], r["target"], r["expected"], r["actual"], status
            )

        console.print(table)
        return all_passed


async def main_async() -> int:
    parser = argparse.ArgumentParser(description="Synthetic Drill Engine for SLO Alert Pipeline")
    parser.add_argument(
        "--profile", choices=["local", "homelab"], default="local",
        help="Alert profile to test: local (2m/15m) or homelab (5m/1h)"
    )
    parser.add_argument("--prometheus-url", default="http://localhost:9090", help="Prometheus endpoint")
    parser.add_argument("--alertmanager-url", default="http://localhost:9093", help="Alertmanager endpoint")
    parser.add_argument("--checkout-url", default="http://localhost:18081", help="Checkout service endpoint")
    parser.add_argument("--inventory-url", default="http://localhost:18082", help="Inventory service endpoint")
    parser.add_argument("--skip-port-forward", action="store_true", help="Skip automatic port-forwarding")
    args = parser.parse_args()

    if not args.skip_port_forward:
        console.log("[cyan]Configuring background port-forwards via scripts/port-forward.sh...[/cyan]")
        PortForwardManager.start("drill")

    engine = DrillEngine(
        profile=args.profile,
        prometheus_url=args.prometheus_url,
        alertmanager_url=args.alertmanager_url,
        checkout_url=args.checkout_url,
        inventory_url=args.inventory_url,
    )

    try:
        console.print(Panel(f"Starting SLO Verification Drill Profile: [bold yellow]{args.profile}[/bold yellow]"))
        await engine.run_baseline_phase()
        await engine.run_burn_rate_phase()
        await engine.run_inhibition_phase()
        await engine.run_recovery_phase()
        passed = engine.print_summary()
        return 0 if passed else 1
    finally:
        await engine.close()
        if not args.skip_port_forward:
            console.log("[cyan]Tearing down port-forwards...[/cyan]")
            PortForwardManager.stop()


def main() -> None:
    sys.exit(asyncio.run(main_async()))


if __name__ == "__main__":
    main()
