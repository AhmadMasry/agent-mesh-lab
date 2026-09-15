"""Follow-ups 12 / the per-hop connection-security table from one reading of every
istio_tcp_connections_opened_total series (rebuild/tcp-connection-security-raw.txt), in the column shape of
experiments/runs/2026-09-12-current-versions/rebuild/hops-security.csv (followups-10), and the comparison of its
legs with that table.

Adapted from experiments/runs/2026-09-12-current-versions/hops.py: the paths; the reference is followups-10's table
(followups-11 committed none); and the comparison adds (a) the legs that touch the agentgateway control plane or the
ingress proxy with their destination_service and the namespaces ztunnel reports, and (b) the destination_service
values that differ on a leg present in both, which is where the ingress's move shows. A leg is (reporter,
source_workload, destination_workload, connection_security_policy); per-run loadgen Job pod workloads are collapsed
to `loadgen` as the earlier tables do. connections_opened is a running total at the moment of the reading, so it is
written out but not compared. Read-only apart from the files it writes into rebuild/.

  python3 experiments/runs/2026-09-15-ingress-namespace/hops.py
"""

import collections
import csv
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "rebuild", "tcp-connection-security-raw.txt")
OUT = os.path.join(HERE, "rebuild", "hops-security.csv")
CMP = os.path.join(HERE, "rebuild", "hops-vs-followups-10.txt")
REF = os.path.join(os.path.dirname(HERE), "2026-09-12-current-versions", "rebuild", "hops-security.csv")


def collapse(w):
    return "loadgen" if re.match(r"^loadgen(-|$)", w or "") else (w or "unknown")


def main():
    agg = collections.Counter()
    ns = {}
    for line in open(RAW):
        line = line.strip()
        if not line.startswith("{"):
            continue
        labels, _, value = line.rpartition(" => ")
        m = json.loads(labels)
        key = (m.get("reporter", ""), collapse(m.get("source_workload")), m.get("destination_service", "unknown"),
               m.get("destination_workload", "unknown"), m.get("connection_security_policy", ""))
        agg[key] += float(value)
        ns.setdefault(key, set()).add((m.get("source_workload_namespace", ""), m.get("destination_workload_namespace", "")))
    with open(OUT, "w", newline="") as f:
        f.write("# Per-hop connection security on the follow-ups 12 rebuild, from rebuild/tcp-connection-security-raw.txt\n")
        f.write("# (one reading; connections_opened is a running total). Built by ../hops.py; legs compared with\n")
        f.write("# followups-10's rebuild table in rebuild/hops-vs-followups-10.txt.\n")
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["reporter", "source_workload", "destination_service", "destination_workload", "connection_security_policy", "connections_opened"])
        for k in sorted(agg):
            w.writerow(list(k) + [int(agg[k])])
    cur = {(k[0], k[1], k[3], k[4]) for k in agg}
    cur_svc = collections.defaultdict(set)
    for k in agg:
        cur_svc[(k[0], k[1], k[3], k[4])].add(k[2])
    ref = set()
    ref_svc = collections.defaultdict(set)
    for r in csv.DictReader(l for l in open(REF) if not l.startswith("#")):
        if r["reporter"] == "none":
            continue
        leg = (r["reporter"], r["source_workload"], r["destination_workload"], r["connection_security_policy"])
        ref.add(leg)
        ref_svc[leg].add(r["destination_service"])
    with open(CMP, "w") as f:
        f.write("# Legs (reporter, source_workload, destination_workload, connection_security_policy) in this rebuild's reading\n")
        f.write("# against followups-10's rebuild table (experiments/runs/2026-09-12-current-versions/rebuild/hops-security.csv).\n")
        f.write("# Counts are running totals and are not compared. The two runs did not send the same traffic: followups-10's\n")
        f.write("# reading followed the Gate 1 baselines, the wire-version capture and the rest of its instruments, this one\n")
        f.write("# only the clean check, the trace, the card read and the two probes, so a client that ran in only one of them is\n")
        f.write("# expected in only one list.\n\n")
        f.write("legs in both: %d\n" % len(cur & ref))
        f.write("\nlegs only in followups-10: %d\n" % len(ref - cur))
        for k in sorted(ref - cur):
            f.write("   " + " | ".join(k) + "\n")
        f.write("\nlegs only in this rebuild: %d\n" % len(cur - ref))
        for k in sorted(cur - ref):
            f.write("   " + " | ".join(k) + "\n")
        f.write("\nlegs in both whose destination_service differs:\n")
        n = 0
        for k in sorted(cur & ref):
            if cur_svc[k] != ref_svc[k]:
                n += 1
                f.write("   %s\n      followups-10: %s\n      this rebuild: %s\n" % (" | ".join(k), sorted(ref_svc[k]), sorted(cur_svc[k])))
        f.write("   (%d)\n" % n)
        f.write("\nthis rebuild's legs that touch the agentgateway control plane (workload `agentgateway`) or the ingress proxy,\n")
        f.write("with destination_service and the (source, destination) workload namespaces the series carry:\n")
        for k in sorted(agg):
            if "agentgateway" in (k[1], k[3]) or "agentgateway-ingress" in (k[1], k[3]):
                f.write("   %s | %s | %s | %s | %s  ns=%s\n" % (k[0], k[1], k[2], k[3], k[4], sorted(ns[k])))
        pol = collections.Counter(k[3] for k in cur)
        f.write("\nthis rebuild's legs by connection_security_policy: %s\n" % dict(pol))
    print(open(CMP).read())


if __name__ == "__main__":
    main()
