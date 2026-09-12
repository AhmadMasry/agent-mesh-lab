"""Follow-ups 7 / builds hops.csv from the three readings in metrics.txt.

metrics.txt holds every istio_tcp_connections_opened_total series at the moments that
attempt's apply.txt names. The last reading in the file supplies each hop's
connection_security_policy; the deltas between the readings supply the connections counted
for the runs between them. Attempt 1 has four readings (A before the policy, B under it,
C straight after the revert, D settled; C is not used for a delta, having raced the last
work item's scrape). Attempt 2 has two (A before mesh-wide STRICT, B under it and settled).

A hop with no series in any reading is written out with security_policy=not-reported and
connections=none: ztunnel never saw it. Those rows are named explicitly below rather
than inferred from an absence, so the table says which hops were looked for.

The counter counts connections *opened*: "This is a COUNTER incremented for every
opened connection" (https://istio.io/latest/docs/reference/config/metrics/). A refused
connection is still an opened one -- ztunnel accepts the TCP connection and then closes
it on the policy -- so the refused egress leg increments rather than staying flat.
"""

import collections
import csv
import json
import os
import re
import sys

ATTEMPT = os.environ.get("OUT", "attempt-2")
READING = "experiments/runs/2026-09-12-mtls-enforced/{}/metrics.txt".format(ATTEMPT)
OUT = "experiments/runs/2026-09-12-mtls-enforced/{}/hops.csv".format(ATTEMPT)

# Every hop of the two flows, in path order. Each entry is
#   (flow, hop, source_workload, destination_service, reporter)
# with source_workload "loadgen" standing for the per-run loadgen-<work item> names.
# A source of None means the hop is expected to have no series at all.
HOPS = [
    ("worker", "loadgen -> worker Service (via the worker's waypoint)",
     "loadgen", "worker.lab.svc.cluster.local", "source"),
    ("worker", "loadgen -> agentgateway-waypoint (the waypoint's own inbound)",
     None, None, "destination"),
    ("worker", "agentgateway-waypoint -> worker",
     "agentgateway-waypoint", "worker.lab.svc.cluster.local", "destination"),
    ("worker", "worker -> agw-egress (the model ServiceEntry host)",
     "worker", "model.lab.internal", "source"),
    ("worker", "worker -> agw-egress (the egress waypoint's own inbound)",
     None, None, "destination"),
    ("worker", "agw-egress -> mockllm",
     "agw-egress", "mockllm.lab.svc.cluster.local", "destination"),
    ("orchestrator", "loadgen -> orchestrator Service, card fetch (via the orchestrator's waypoint)",
     "loadgen", "orchestrator.lab.svc.cluster.local", "source"),
    ("orchestrator", "agentgateway-waypoint-orch -> orchestrator",
     "agentgateway-waypoint-orch", "orchestrator.lab.svc.cluster.local", "destination"),
    ("orchestrator", "loadgen -> agentgateway-ingress, SendMessage (source side)",
     "loadgen", "agentgateway-ingress.agentgateway-system.svc.cluster.local", "source"),
    ("orchestrator", "loadgen -> agentgateway-ingress, SendMessage (destination side)",
     "loadgen", "agentgateway-ingress.agentgateway-system.svc.cluster.local", "destination"),
    ("orchestrator", "agentgateway-ingress -> orchestrator",
     "agentgateway-ingress", "orchestrator.lab.svc.cluster.local", "destination"),
    ("orchestrator", "orchestrator -> worker Service, the forward (via the worker's waypoint)",
     "orchestrator", "worker.lab.svc.cluster.local", "source"),
    ("probe", "telemetry/mtls-probe -> worker, plaintext from outside the mesh",
     "mtls-probe", "worker.lab.svc.cluster.local", "destination"),
    ("probe", "telemetry/mtls-probe -> orchestrator, plaintext from outside the mesh",
     "mtls-probe", "orchestrator.lab.svc.cluster.local", "destination"),
]


def read_sections(path):
    """(section letter) -> {(source, destination, reporter, policy): value}."""
    sections = collections.defaultdict(lambda: collections.defaultdict(int))
    section = None
    for line in open(path):
        header = re.match(r"== ([ABCD])\. ", line)
        if header:
            section = header.group(1)
            continue
        if not line.startswith("{") or " => " not in line:
            continue
        labels, _, value = line.rpartition(" => ")
        d = json.loads(labels)
        source = d.get("source_workload", "-")
        if source.startswith("loadgen-"):
            source = "loadgen"          # one row per hop, not one per run
        key = (source, d.get("destination_service", "-"),
               d.get("reporter", "-"), d.get("connection_security_policy", "-"))
        sections[section][key] += int(float(value))
    return sections


def main():
    sections = read_sections(READING)
    rows = []
    for flow, hop, source, destination, reporter in HOPS:
        if source is None:
            rows.append([flow, hop, reporter, "not-reported", "none", "none", "none",
                         "no series in any reading: ztunnel does not see this hop"])
            continue
        last = max(sections)
        matches = [k for k in sections[last]
                   if k[0] == source and k[1] == destination and k[2] == reporter]
        if not matches:
            rows.append([flow, hop, reporter, "not-reported", "none", "none", "none",
                         "no series in any reading: ztunnel does not see this hop"])
            continue
        for key in sorted(matches):
            first = min(sections)
            a = sections[first].get(key, 0)
            b = sections["B"].get(key, 0)
            d = sections[last].get(key, 0)
            # A hop whose series exists but gained nothing while the flow ran is a hop
            # ztunnel no longer sees: the series is left over from an earlier reading and
            # the label on it describes that earlier connection, not this attempt's.
            note = ("series left from an earlier reading; no connection counted in this "
                    "attempt, so the policy shown is historical" if b - a == 0 else "")
            after = "n/a" if last == "B" else d - b
            rows.append([flow, hop, reporter, key[3], a, b - a, after, note])

    # lineterminator is set explicitly: csv.writer defaults to CRLF, and every other
    # run output in this repository is LF.
    with open(OUT, "w", newline="\n") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["flow", "hop", "reporter", "security_policy",
                    "connections_at_first_reading", "connections_added_under_strict",
                    "connections_added_after", "note"])
        w.writerows(rows)
    print("wrote {} with {} rows".format(OUT, len(rows)))
    print("{:13s} {:>9s} {:>9s}  {}".format("policy", "under", "after", "hop"))
    for r in rows:
        print("{:13s} {:>9s} {:>9s}  {} [{}]{}".format(
            r[3], str(r[5]), str(r[6]), r[1], r[2],
            "  <-- " + r[7] if r[7] else ""))


if __name__ == "__main__":
    sys.exit(main())
