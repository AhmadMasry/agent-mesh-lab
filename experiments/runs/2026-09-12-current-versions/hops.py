"""Follow-ups 10 / the per-hop connection-security table from one reading of every
istio_tcp_connections_opened_total series (rebuild/tcp-connection-security-raw.txt), in the column
shape of experiments/runs/2026-09-12-helm-first/rebuild-2/hops-security.csv, and the comparison of
its legs with that table.

A leg is (reporter, source_workload, destination_workload, connection_security_policy); per-run
loadgen Job pod workloads are collapsed to `loadgen` as rebuild #2's table does. connections_opened is
a running total at the moment of the reading, so it is written out but not compared. Read-only apart
from the two files it writes beside this script's run directory: rebuild/hops-security.csv and
rebuild/hops-vs-rebuild-2.txt.

  python3 experiments/runs/2026-09-12-current-versions/hops.py
"""

import collections
import csv
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "rebuild", "tcp-connection-security-raw.txt")
OUT = os.path.join(HERE, "rebuild", "hops-security.csv")
CMP = os.path.join(HERE, "rebuild", "hops-vs-rebuild-2.txt")
REF = os.path.join(os.path.dirname(HERE), "2026-09-12-helm-first", "rebuild-2", "hops-security.csv")


def collapse(w):
    return "loadgen" if re.match(r"^loadgen(-|$)", w or "") else (w or "unknown")


def main():
    agg = collections.Counter()
    for line in open(RAW):
        line = line.strip()
        if not line.startswith("{"):
            continue
        # promfmt.py series format: <json label set> => <value>
        labels, _, value = line.rpartition(" => ")
        m = json.loads(labels)
        v = float(value)
        key = (m.get("reporter", ""), collapse(m.get("source_workload")), m.get("destination_service", "unknown"),
               m.get("destination_workload", "unknown"), m.get("connection_security_policy", ""))
        agg[key] += v
    with open(OUT, "w", newline="") as f:
        f.write("# Per-hop connection security on the follow-ups 10 rebuild, from rebuild/tcp-connection-security-raw.txt\n")
        f.write("# (one reading; connections_opened is a running total). Built by ../hops.py; legs compared with\n")
        f.write("# followups-9 rebuild #2 in rebuild/hops-vs-rebuild-2.txt.\n")
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["reporter", "source_workload", "destination_service", "destination_workload", "connection_security_policy", "connections_opened"])
        for k in sorted(agg):
            w.writerow(list(k) + [int(agg[k])])
    cur = {(k[0], k[1], k[3], k[4]) for k in agg}
    ref = set()
    for r in csv.DictReader(l for l in open(REF) if not l.startswith("#")):
        if r["reporter"] == "none":
            continue
        ref.add((r["reporter"], r["source_workload"], r["destination_workload"], r["connection_security_policy"]))
    with open(CMP, "w") as f:
        f.write("# Legs (reporter, source_workload, destination_workload, connection_security_policy) in this rebuild's\n")
        f.write("# reading against followups-9 rebuild #2's hops-security.csv (its reporter=none rows, which ztunnel cannot\n")
        f.write("# report, excluded). Counts are running totals and are not compared.\n\n")
        f.write("legs in both: %d\n" % len(cur & ref))
        f.write("\nlegs only in rebuild #2: %d\n" % len(ref - cur))
        for k in sorted(ref - cur):
            f.write("   " + " | ".join(k) + "\n")
        f.write("\nlegs only in this rebuild: %d\n" % len(cur - ref))
        for k in sorted(cur - ref):
            f.write("   " + " | ".join(k) + "\n")
        pol = collections.Counter(k[3] for k in cur)
        f.write("\nthis rebuild's legs by connection_security_policy: %s\n" % dict(pol))
    print(open(CMP).read())


if __name__ == "__main__":
    main()
