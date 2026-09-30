# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "diagrams>=0.25.1",
# ]
# ///
"""Generate architecture diagram PNG for the SLO Alert Pipeline using diagrams."""

import os
from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Pod
from diagrams.k8s.infra import Node
from diagrams.onprem.monitoring import Prometheus, Grafana
from diagrams.programming.language import Python

os.makedirs("docs/assets", exist_ok=True)

graph_attr = {
    "fontsize": "18",
    "bgcolor": "white",
    "pad": "0.5",
    "nodesep": "1.8",
    "ranksep": "2.0",
    "splines": "spline",
}

node_attr = {
    "fontsize": "14",
}

edge_attr = {
    "fontsize": "12",
}

box_attr = {"margin": "35.0"}

# Diagram 1: System Architecture Overview
with Diagram(
    "Multi-Tenant Kubernetes SLO Alert Pipeline",
    filename="docs/assets/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    with Cluster("Traffic & Verification", graph_attr=box_attr):
        chaos_drill = Python("\nChaos Drill Engine\n(drill-burn-budget.py)")

    with Cluster("Kubernetes Cluster", graph_attr=box_attr):
        with Cluster("Tenant: checkout", graph_attr=box_attr):
            checkout = Pod("\ncheckout\n(:18081)")

        with Cluster("Tenant: inventory", graph_attr=box_attr):
            inventory = Pod("\ninventory\n(:18082)")

        with Cluster("Monitoring (Prometheus Operator)", graph_attr=box_attr):
            prometheus = Prometheus("\nPrometheus\n(MWMBR Rules)")
            grafana = Grafana("\nGrafana\n(SLO Dashboard)")
            alertmanager = Pod("\nAlertmanager\n(Topology Inhibition)")
            webhook_sink = Pod("\nWebhook Sink\n(:8080)")

            prometheus >> Edge(label="\nmetrics\n") >> grafana
            prometheus >> Edge(label="\nalerts\n") >> alertmanager
            alertmanager >> Edge(label="\nroutes\n") >> webhook_sink

    # Flow connections
    chaos_drill >> Edge(label="\nHTTP /chaos\n") >> checkout
    chaos_drill >> Edge(label="\nHTTP /chaos\n") >> inventory

    checkout >> Edge(label="\nscrape (node label)\n", style="dashed") >> prometheus
    inventory >> Edge(label="\nscrape (node label)\n", style="dashed") >> prometheus

# Diagram 2: Topology-Aware Alert Inhibition Flow
with Diagram(
    "Topology-Aware Alert Inhibition",
    filename="docs/assets/topology-inhibition",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    with Cluster("Worker Node (node: fedora)", graph_attr=box_attr):
        node = Node("\nKubernetes Node\n(NotReady)")
        tenant_pod = Pod("\ntenant-inventory\n(on fedora)")

    with Cluster("Monitoring (Prometheus Operator)", graph_attr=box_attr):
        prom = Prometheus("\nPrometheus Server")
        am = Pod("\nAlertmanager\n(Inhibition Engine)")
        sink = Pod("\nWebhook Sink\n(:8080)")

    node >> Edge(label="\n1. fires KubeNodeNotReady\n{node='fedora'}\n") >> prom
    tenant_pod >> Edge(label="\n2. 500s spike\n") >> prom

    prom >> Edge(label="\nsource alert\n(KubeNodeNotReady)\n") >> am
    prom >> Edge(label="\ntarget alert\n(SLOErrorBudgetFastBurn)\n[inhibited]\n", style="dashed") >> am

    am >> Edge(label="\n3. dispatches root cause only\n") >> sink

# Diagram 3: Multi-Window Multi-Burn-Rate (MWMBR) Alerting Logic
with Diagram(
    "Multi-Window Multi-Burn-Rate Alerting Logic",
    filename="docs/assets/mwmbr-evaluation",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    with Cluster("Time-Series Ingestion", graph_attr=box_attr):
        requests = Pod("\nhttp_requests_total\n(status 2xx, 5xx)")

    with Cluster("Prometheus Recording Rules", graph_attr=box_attr):
        short_rate = Prometheus("\nShort Lookback (5m)\nrate5m > 14.4x (7.2%)")
        long_rate = Prometheus("\nLong Lookback (1h)\nrate1h > 14.4x (7.2%)")

    with Cluster("Alert Condition (Alertmanager)", graph_attr=box_attr):
        eval_rule = Pod("\nAND Condition\n(Both Windows Breached)")
        fast_burn = Pod("\nSLOErrorBudgetFastBurn\n(Severity: Page)")

    requests >> Edge(label="\nrate5m\n") >> short_rate
    requests >> Edge(label="\nrate1h\n") >> long_rate

    short_rate >> Edge(label="\n5m breach\n") >> eval_rule
    long_rate >> Edge(label="\n1h breach\n") >> eval_rule

    eval_rule >> Edge(label="\nfires page\n") >> fast_burn
