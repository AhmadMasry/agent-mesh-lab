#!/usr/bin/env python3
"""entry-routes.py <rows dir> -- per recorded work item: every proxy span that carries a route,
by (service, route, method), and which services set `route` / `retry_attempt` at all.
Reads spans.csv only."""
import collections, csv, pathlib, sys

base = pathlib.Path(sys.argv[1])
setters_route, setters_retry = collections.Counter(), collections.Counter()
print("row,work_item,service,route,method,spans,retry_attempt_values")
for spans in sorted(base.glob("*/a3m-*/spans.csv")):
    rows = list(csv.DictReader(spans.open()))
    table = collections.defaultdict(list)
    for r in rows:
        if r.get("route"):
            setters_route[r["service"]] += 1
            table[(r["service"], r["route"], r["operation"].split()[0])].append(r.get("retry_attempt") or "-")
        if r.get("retry_attempt"):
            setters_retry[r["service"]] += 1
    for (service, route, method), vals in sorted(table.items()):
        print(",".join([spans.parent.parent.name, spans.parent.name, service, route, method, str(len(vals)), "|".join(vals)]))
print()
print("# spans carrying a route, by service:", dict(setters_route))
print("# spans carrying retry_attempt, by service:", dict(setters_retry))
