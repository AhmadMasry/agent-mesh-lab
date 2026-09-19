"""Follow-ups 19, task 3, reading (f): which rows of an exported spans.csv carry http_status, route and retry_attempt.

Per work item and service: the spans, how many have each of the three columns filled, and the values seen.
Run over this proof's trace work items and over the last proof's (experiments/runs/2026-09-19-agentgateway-only/
trace), whose export was taken before the exporter read agentgateway's `http.status`. Reads committed files by
column name; re-exports nothing; touches no cluster.

  python3 exporter-columns.py <out.csv> <label>=<trace-dir> [<label>=<trace-dir> ...]
"""
import collections
import csv
import glob
import os
import sys

out = sys.argv[1]
rows = []
for arg in sys.argv[2:]:
    label, _, tdir = arg.partition("=")
    for path in sorted(glob.glob(os.path.join(tdir, "*", "spans.csv"))):
        wi = os.path.basename(os.path.dirname(path))
        per = collections.defaultdict(list)
        reader = csv.DictReader(open(path))
        header = reader.fieldnames or []
        for r in reader:
            per[r["service"]].append(r)
        for svc in sorted(per):
            rs = per[svc]

            def filled(col):
                return [r[col] for r in rs if r.get(col, "") != ""]

            def n(col):  # a column the export does not have is said so, not counted as empty
                return len(filled(col)) if col in header else "column absent"

            def values(col):
                c = collections.Counter(filled(col))
                return "|".join("%s x%d" % (v, n) for v, n in sorted(c.items()))

            rows.append([label, wi, svc, len(rs), n("http_status"), values("http_status"),
                         n("route"), values("route"), n("retry_attempt"), values("retry_attempt")])
with open(out, "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["record", "work_item", "service", "spans", "http_status_filled", "http_status_values",
                "route_filled", "route_values", "retry_attempt_filled", "retry_attempt_values"])
    w.writerows(rows)
proxies = ("agw-central", "agentgateway-ingress")
for label in dict.fromkeys(r[0] for r in rows):
    mine = [r for r in rows if r[0] == label]
    px = [r for r in mine if r[2] in proxies]
    print("%s: %d work items, %d spans; proxy rows %d with http_status filled on %d; every other service's rows %d with http_status filled on %d" % (
        label, len({r[1] for r in mine}), sum(r[3] for r in mine), sum(r[3] for r in px), sum(r[4] for r in px),
        sum(r[3] for r in mine if r[2] not in proxies), sum(r[4] for r in mine if r[2] not in proxies))
        + "; route column: %s" % ("absent from this export" if any(r[6] == "column absent" for r in mine) else "filled on %d rows, all of them proxy rows: %s" % (
            sum(r[6] for r in mine), all(r[6] == 0 for r in mine if r[2] not in proxies))))
