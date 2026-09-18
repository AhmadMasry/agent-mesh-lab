#!/usr/bin/env python3
"""Follow-ups 15, commit 3: the two retry rows -- the retrying proxy's request, retry and upstream-attempt deltas
against the ledgers' deliveries (R2, at the worker) and invocations (egress, at the mock) for the same work items,
the dry-run repetition included, because its traffic is inside the window. Read-only; CSV on stdout.

  retry-table.py <row> <delta-hops.csv> <ledgers.csv>    row = r2-waypoint | egress
"""
import csv, sys
from collections import Counter

row, hops_path, led_path = sys.argv[1:4]
hops = list(csv.DictReader(open(hops_path)))
led = list(csv.DictReader(open(led_path)))

def m(query, gw, **want):
    t = 0
    for r in hops:
        if r["query"] != query:
            continue
        g = dict(kv.split("=", 1) for kv in r["group"].split(" ") if "=" in kv)
        if g.get("gateway_name") == gw and all(g.get(k) == v for k, v in want.items()):
            t += float(r["delta"])
    return int(t)

L = Counter()
for r in led:
    for k in ("worker_arrivals", "worker_dispatches", "worker_tasks", "invocations_by_worker"):
        L[k] += int(r[k])
n = len(led)
if row == "r2-waypoint":
    gw, route, sel = "agentgateway-waypoint", "lab/worker", dict(method="POST", status="200")
    ledger_name, ledger = "deliveries at the worker (ingress ledger arrivals)", L["worker_arrivals"]
else:
    gw, route, sel = "agw-egress", "agentgateway-egress/model-via-agw", dict(method="POST")
    ledger_name, ledger = "model invocations (invocation ledger)", L["invocations_by_worker"]
req = m("requests", gw, **sel)
# Every other request the same proxy counted in the window, read from the same delta: its whole request count
# less the selected series (on the waypoint, card GETs and control POSTs; on the egress, none).
other = m("requests", gw) - req
ret = m("retries", gw)
att = m("upstream_call_duration_count", gw)
out = [
    ("work items in the window (dry run included)", n),
    (f"agentgateway_requests_total {{gateway_name={gw}, {', '.join(f'{k}={v}' for k, v in sel.items())}}}", req),
    (f"agentgateway_retries_total {{gateway_name={gw}}}", ret),
    (f"agentgateway_requests_total + agentgateway_retries_total", req + ret),
    (f"agentgateway_upstream_call_duration_seconds_count {{gateway_name={gw}}}", att),
    ("other requests the same proxy handled in the window (card GETs, control POSTs)", other),
    ("upstream attempts for the work items' requests (upstream calls minus the other requests)", att - other),
    (ledger_name, ledger),
    ("worker dispatches (execution ledger)", L["worker_dispatches"]),
    ("Tasks", L["worker_tasks"]),
]
if row == "r2-waypoint":
    out.append(("model invocations (invocation ledger)", L["invocations_by_worker"]))
else:
    out.append(("deliveries at the worker (ingress ledger arrivals)", L["worker_arrivals"]))
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(["row", "measure", "value"])
for k, v in out:
    w.writerow([row, k, v])
