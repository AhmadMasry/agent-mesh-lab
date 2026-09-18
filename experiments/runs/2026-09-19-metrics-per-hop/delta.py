#!/usr/bin/env python3
"""Follow-ups 15, commit 3: after minus before, for every series read-hops.sh stored, and the same deltas grouped
by the labels that name a hop. Read-only.

  delta.py <before.json> <after.json> <out-prefix>
writes <out-prefix>-series.csv (every series whose value moved, or that exists in one reading only) and
<out-prefix>-hops.csv (those deltas summed by hop labels). A series absent from the "before" reading counts from 0:
a counter's series appears in the exposition only after its first event (agentgateway's data-plane page: "Counter
and histogram metrics only appear after the first request of that type"), so absent means none had happened. A
value that fell is a counter reset and is flagged, not subtracted.
"""
import csv, json, re, sys
from collections import defaultdict

before, after, prefix = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
SKIP = {"last_scrape", "up", "tcp_opened_series"}
GROUP = {
    "requests": ["gateway_name", "route", "backend", "method", "status", "reason"],
    "retries": None,  # every label, since the family has not been seen before
    "request_duration_count": ["gateway_name", "route", "method", "status", "reason"],
    "upstream_call_duration_count": ["gateway_name", "kind", "subtype"],
    "upstream_connect_duration_count": ["gateway_name", "transport"],
    "downstream_connections": ["gateway_name", "listener", "protocol"],
    "downstream_received_bytes": ["gateway_name"],
    "downstream_sent_bytes": ["gateway_name"],
    "response_bytes": ["gateway_name", "route", "method", "status"],
    "tcp_opened": ["instance", "reporter", "source_workload", "destination_workload", "destination_service", "connection_security_policy"],
    "tcp_closed": ["instance", "reporter", "source_workload", "destination_workload", "destination_service", "connection_security_policy"],
}

def norm_workload(v):
    # One Job, and so one workload name, per work item: loadgen-<work item>. Grouped as one hop.
    return re.sub(r"^loadgen-.*$", "loadgen-*", v or "")

def key(metric):
    return tuple(sorted((k, v) for k, v in metric.items() if k != "__name__"))

series_rows, hops = [], defaultdict(float)
for q in sorted(set(before["queries"]) | set(after["queries"])):
    if q in SKIP:
        continue
    b = {key(r["metric"]): float(r["value"][1]) for r in before["queries"].get(q, {}).get("result", [])}
    a = {key(r["metric"]): float(r["value"][1]) for r in after["queries"].get(q, {}).get("result", [])}
    for k in sorted(set(a) | set(b)):
        bv, av = b.get(k), a.get(k)
        note = ""
        if bv is None:
            note, bv = "absent before (counts from 0)", 0.0
        if av is None:
            note, av = "absent after", bv
        d = av - bv
        if d < 0:
            note = "fell: counter reset"
        if d == 0 and not note:
            continue
        labels = dict(k)
        series_rows.append({"query": q, "labels": " ".join(f"{x}={y}" for x, y in k), "before": f"{bv:g}", "after": f"{av:g}", "delta": f"{d:g}", "note": note})
        if d > 0:
            g = GROUP.get(q)
            gk = tuple((x, norm_workload(labels.get(x, "")) if x.endswith("_workload") else labels.get(x, "")) for x in (g or sorted(labels)))
            hops[(q, gk)] += d
with open(prefix + "-series.csv", "w") as f:
    w = csv.DictWriter(f, fieldnames=["query", "labels", "before", "after", "delta", "note"], lineterminator="\n")
    w.writeheader()
    w.writerows(series_rows)
with open(prefix + "-hops.csv", "w") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["query", "group", "delta"])
    for (q, gk), d in sorted(hops.items()):
        w.writerow([q, " ".join(f"{x}={y}" for x, y in gk), f"{d:g}"])
print(f"{prefix}: {len(series_rows)} series moved, {len(hops)} hop groups; before eval {before['eval_time_utc']}, after eval {after['eval_time_utc']}")
