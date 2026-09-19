"""Follow-ups 18 / the per-hop connection-security table from one reading of every
istio_tcp_connections_opened_total series, and the named legs the STRICT reading asks for.

Adapted from experiments/runs/2026-09-16-genai-spans/hops.py (the lab's hops table): the paths come
from the command line instead of being fixed to one run directory; the two principals and the two
namespaces are columns, because on this topology the question is which identity each end sees when
one agentgateway-managed proxy outside ambient stands between two captured pods; and there is no
comparison with an earlier table, because the earlier tables name proxies that no longer exist.

Input is the text experiments/runs/2026-09-12-mtls-enforced/promq.sh security prints: one line per
series, `{labels json} => value`. A leg is (reporter, source_workload, source_namespace,
destination_service, destination_workload, destination_namespace, connection_security_policy,
source_principal, destination_principal); per-run Job pod workloads (loadgen-*) are collapsed to
`loadgen` as the lab's tables do. connections_opened is a running total at the moment of the
reading, which on a cluster rebuilt for this reading is everything since the build.

ztunnel reports a leg only when at least one of its two ends is ztunnel-captured, so a leg between
two uncaptured pods has no series at all; the named-legs file says `no-series` for it rather than
leaving it out. Reads and writes files; touches no cluster.

  python3 hops.py <raw.txt> <hops-security.csv> <legs.csv>
"""

import collections
import csv
import json
import re
import sys

# The legs the reading names: (label, reporter, source_workload, destination_service regex,
# destination_workload regex). None matches anything.
LEGS = [
    ("caller (loadgen) -> agw-central, to the worker Service", "source", "loadgen", r"^worker\.lab\.svc", r"^agw-central$"),
    ("caller (loadgen) -> agw-central, to the orchestrator Service (the card)", "source", "loadgen", r"^orchestrator\.lab\.svc", r"^agw-central$"),
    ("agw-central -> worker", "destination", "agw-central", None, r"^worker$"),
    ("agw-central -> orchestrator", "destination", "agw-central", None, r"^orchestrator$"),
    ("worker -> model host, via agw-central", "source", "worker", r"^model\.lab\.internal$", None),
    ("orchestrator -> worker Service (the forward), via agw-central", "source", "orchestrator", r"^worker\.lab\.svc", None),
    ("agw-central -> mockllm (neither end captured)", None, "agw-central", None, r"^mockllm$"),
    ("caller (loadgen) -> agentgateway-ingress, source side", "source", "loadgen", r"^agentgateway-ingress\.", None),
    ("caller (loadgen) -> agentgateway-ingress, destination side", "destination", "loadgen", None, r"^agentgateway-ingress$"),
    ("agentgateway-ingress -> orchestrator", "destination", "agentgateway-ingress", None, r"^orchestrator$"),
    ("agentgateway-ingress -> worker", "destination", "agentgateway-ingress", None, r"^worker$"),
    ("plaintext probe -> worker", "destination", "mtls-probe", None, r"^worker$"),
    ("plaintext probe -> orchestrator", "destination", "mtls-probe", None, r"^orchestrator$"),
]


def collapse(w):
    return "loadgen" if re.match(r"^loadgen(-|$)", w or "") else (w or "unknown")


def main():
    raw, out, legs_out = sys.argv[1], sys.argv[2], sys.argv[3]
    agg = collections.Counter()
    for line in open(raw):
        line = line.strip()
        if not line.startswith("{"):
            continue
        labels, _, value = line.rpartition(" => ")
        m = json.loads(labels)
        key = (
            m.get("reporter", ""),
            collapse(m.get("source_workload")),
            m.get("source_workload_namespace", "unknown"),
            m.get("destination_service", "unknown"),
            m.get("destination_workload", "unknown"),
            m.get("destination_workload_namespace", "unknown"),
            m.get("connection_security_policy", ""),
            m.get("source_principal", "unknown"),
            m.get("destination_principal", "unknown"),
        )
        agg[key] += float(value)

    with open(out, "w", newline="") as f:
        f.write("# Per-hop connection security, one reading of istio_tcp_connections_opened_total (ztunnel's own\n")
        f.write("# series: a leg appears only when at least one of its two ends is ztunnel-captured).\n")
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["reporter", "source_workload", "source_namespace", "destination_service", "destination_workload",
                    "destination_namespace", "connection_security_policy", "source_principal", "destination_principal",
                    "connections_opened"])
        for k in sorted(agg):
            w.writerow(list(k) + [int(agg[k])])

    with open(legs_out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["leg", "reporter_asked", "series", "connection_security_policy", "connections_opened",
                    "source_principal", "destination_principal"])
        for label, reporter, src, svc_re, wl_re in LEGS:
            rows = [k for k in sorted(agg)
                    if (reporter is None or k[0] == reporter) and k[1] == src
                    and (svc_re is None or re.search(svc_re, k[3]))
                    and (wl_re is None or re.search(wl_re, k[4]))]
            if not rows:
                w.writerow([label, reporter or "any", 0, "no-series", 0, "", ""])
                continue
            for k in rows:
                w.writerow([label, reporter or "any", len(rows), k[6], int(agg[k]), k[7], k[8]])

    policies = collections.Counter(k[6] for k in agg)
    print("%d legs from %s -> %s; by policy: %s" % (
        len(agg), raw, out, ", ".join("%s=%d" % (p or "(empty)", n) for p, n in sorted(policies.items()))))
    print("named legs -> %s" % legs_out)


if __name__ == "__main__":
    main()
