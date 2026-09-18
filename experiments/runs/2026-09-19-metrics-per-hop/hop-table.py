#!/usr/bin/env python3
"""Follow-ups 15, commit 3: the per-hop table of the clean counted run -- each hop's counter delta against the
three ledgers' counts for the same twenty work items and against the span count per hop from the same traces.
Every number is read from a file of this run directory; nothing is typed in. Read-only; CSV on stdout.

  hop-table.py <delta-hops.csv> <ledgers.csv> [<trace summary.csv>]

Span counts per hop come from the ledgers file's spans_by_service column (each work item's exported trace). Each
agentgateway proxy writes two spans per request it handles in these traces (one for the listener, one for the
route/backend, as the committed walkthrough listing shows), so a proxy's requests-from-spans is its spans / 2.
"""
import csv, sys
from collections import Counter

hops = list(csv.DictReader(open(sys.argv[1])))
led = list(csv.DictReader(open(sys.argv[2])))

def metric(query, **want):
    total = 0
    for r in hops:
        if r["query"] != query:
            continue
        g = dict(kv.split("=", 1) for kv in r["group"].split(" ") if "=" in kv)
        if all(g.get(k) == v for k, v in want.items()):
            total += float(r["delta"])
    return int(total)

L = Counter()
S = Counter()
for r in led:
    for k, v in r.items():
        if k.endswith(("_arrivals", "_dispatches", "_tasks")) or k.startswith("invocations_by_"):
            L[k] += int(v)
    for kv in r["spans_by_service"].split("|"):
        if kv:
            k, v = kv.split("=")
            S[k] += int(v)

rows = []
def row(flow, hop, series, delta, ledger_name, ledger, spans_service, per_req, note):
    spans = S.get(spans_service, 0) if spans_service else ""
    from_spans = (spans // per_req) if (spans_service and per_req) else ""
    rows.append({"flow": flow, "hop": hop, "counter series": series, "counter delta": delta,
                 "ledger measure": ledger_name, "ledger count": ledger, "spans at hop": spans,
                 "requests from spans": from_spans, "note": note})

W = dict(gateway_name="agentgateway-waypoint", route="lab/worker")
WO = dict(gateway_name="agentgateway-waypoint-orch", route="lab/_waypoint-default")
IN = dict(gateway_name="agentgateway-ingress", route="lab/orchestrator-ingress")
EG = dict(gateway_name="agw-egress", route="agentgateway-egress/model-via-agw")
w_all = metric("requests", **W)
row("both", "-> worker waypoint (SendMessage to the worker)", "agentgateway_requests_total{gateway_name=agentgateway-waypoint,route=lab/worker,method=POST,status=200}",
    metric("requests", **W, method="POST", status="200"), "worker arrivals (ingress ledger, SendMessage)", L["worker_arrivals"], "", 0,
    "both flows' deliveries to the worker cross this waypoint; the counter has no label that says which flow")
row("worker", "load Job -> worker waypoint (agent card)", "agentgateway_requests_total{...agentgateway-waypoint...,method=GET,status=200}",
    metric("requests", **W, method="GET", status="200"), "(no ledger: a card fetch is not a SendMessage)", "", "", 0, "one per worker-flow work item")
row("both", "control pod -> worker waypoint (injector reset)", "agentgateway_requests_total{...agentgateway-waypoint...,method=POST,status=204}",
    metric("requests", **W, method="POST", status="204"), "(no ledger: /control/* is excluded from the ingress ledger)", "", "", 0,
    "the instrument's reset before each work item; told apart from SendMessage by status alone")
row("both", "worker waypoint, every request", "agentgateway_requests_total{gateway_name=agentgateway-waypoint} (all series)",
    w_all, "worker arrivals", L["worker_arrivals"], "agentgateway-waypoint", 2,
    "spans cover the POST and GET a work item's trace carries; the resets carry no work item and are in no exported trace")
row("orchestrator", "load Job -> orchestrator waypoint (agent card)", "agentgateway_requests_total{gateway_name=agentgateway-waypoint-orch,method=GET,status=200}",
    metric("requests", **WO, method="GET", status="200"), "(no ledger: a card fetch is not a SendMessage)", "", "agentgateway-waypoint-orch", 2,
    "the card is fetched from the orchestrator Service; the SendMessage goes to the ingress the card advertises")
row("orchestrator", "control pod -> orchestrator waypoint (injector reset)", "agentgateway_requests_total{...agentgateway-waypoint-orch...,method=POST,status=204}",
    metric("requests", **WO, method="POST", status="204"), "(no ledger)", "", "", 0, "")
row("orchestrator", "load Job -> ingress (SendMessage to the orchestrator)", "agentgateway_requests_total{gateway_name=agentgateway-ingress,route=lab/orchestrator-ingress,method=POST,status=200}",
    metric("requests", **IN, method="POST", status="200"), "orchestrator arrivals", L["orchestrator_arrivals"], "agentgateway-ingress", 2, "")
row("both", "worker -> egress (model call)", "agentgateway_requests_total{gateway_name=agw-egress,method=POST,status=200}",
    metric("requests", **EG, method="POST", status="200"), "model invocations (invocation ledger)", L["invocations_by_worker"] + L["invocations_by_orchestrator"], "agw-egress", 2, "")
row("both", "egress -> mock (upstream call)", "agentgateway_upstream_call_duration_seconds_count{gateway_name=agw-egress}",
    metric("upstream_call_duration_count", gateway_name="agw-egress"), "model invocations", L["invocations_by_worker"] + L["invocations_by_orchestrator"], "mockllm", 1,
    "the mock exports no metric; its own spans and its ledger are the only counts at that end")
row("both", "worker (receiver)", "(none: no metrics endpoint)", "", "worker dispatches (execution ledger)", L["worker_dispatches"], "", 0, "")
row("orchestrator", "orchestrator (receiver)", "(none: OTEL_METRICS_EXPORTER=none)", "", "orchestrator dispatches", L["orchestrator_dispatches"], "", 0, "")
row("both", "mock (model endpoint)", "(none: no metrics endpoint)", "", "model invocations", L["invocations_by_worker"] + L["invocations_by_orchestrator"], "mockllm", 1, "")
# L4: ztunnel on the node the lab runs on
for flow, hop, src, dst in (("worker", "load Job -> worker waypoint, TCP", "loadgen-*", "agentgateway-waypoint"),
                            ("orchestrator", "load Job -> orchestrator waypoint, TCP", "loadgen-*", "agentgateway-waypoint-orch"),
                            ("orchestrator", "load Job -> ingress, TCP", "loadgen-*", "agentgateway-ingress"),
                            ("orchestrator", "orchestrator -> worker waypoint, TCP", "orchestrator", "agentgateway-waypoint"),
                            ("both", "worker waypoint -> worker, TCP", "agentgateway-waypoint", "worker"),
                            ("orchestrator", "ingress -> orchestrator, TCP", "agentgateway-ingress", "orchestrator"),
                            ("orchestrator", "orchestrator waypoint -> orchestrator, TCP", "agentgateway-waypoint-orch", "orchestrator"),
                            ("both", "worker -> egress, TCP", "worker", "agw-egress")):
    per = Counter()
    for r in hops:
        g = r["group"] + " "
        if r["query"] == "tcp_opened" and f"source_workload={src} " in g and f"destination_workload={dst} " in g:
            rep = next(kv.split("=")[1] for kv in r["group"].split(" ") if kv.startswith("reporter="))
            per[rep] += int(float(r["delta"]))
    row(flow, hop, f"istio_tcp_connections_opened_total{{source_workload={src},destination_workload={dst}}} (ztunnel)",
        " ".join(f"{k}={v}" for k, v in sorted(per.items())) or "0", "(connections, not requests)", "", "", 0,
        "one connection reported once by each ztunnel end that is in the mesh; the two reports are the same connection")
w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]), lineterminator="\n")
w.writeheader()
w.writerows(rows)
