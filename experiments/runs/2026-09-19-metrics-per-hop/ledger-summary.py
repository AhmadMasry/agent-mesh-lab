#!/usr/bin/env python3
"""Follow-ups 15, commit 3: the three ledgers' counts for every work item in the given directories, and the
per-hop span counts of the same work items' traces. Read-only; CSV on stdout, totals on stderr.

Counted the way gate3-matrix.sh counts, per work item:
  arrivals    ingress-ledger lines with phase=arrival and method=SendMessage, per receiver (source worker or
              orchestrator) -- one per SendMessage delivery that reached that receiver's pre-dispatch middleware
  dispatches  execution-ledger lines with event=execute, per receiver
  tasks       distinct taskId on those execute lines, per receiver
  invocations invocation-ledger lines whose outcome is not stale-closed, per caller (the model endpoint's count)
  client      the load client's lines
Span counts: spans.csv of each work item (the exported trace), per service.name.
"""
import csv, glob, json, os, sys
from collections import Counter

def jl(p):
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []

rows = []
for base in sys.argv[1:]:
    for d in sorted(glob.glob(os.path.join(base, "*/"))):
        if not os.path.exists(os.path.join(d, "ingress.jsonl")):
            continue
        lwi = os.path.basename(d.rstrip("/"))
        ing, exe, inv, cli = (jl(os.path.join(d, f + ".jsonl")) for f in ("ingress", "execution", "invocation", "client"))
        r = {"dir": base, "work_item": lwi}
        for rcv in ("worker", "orchestrator"):
            r[f"{rcv}_arrivals"] = sum(1 for l in ing if l.get("source") == rcv and l.get("phase") == "arrival" and l.get("method") == "SendMessage")
            r[f"{rcv}_dispatches"] = sum(1 for l in exe if l.get("source") == rcv and l.get("event") == "execute")
            r[f"{rcv}_tasks"] = len({l.get("taskId") for l in exe if l.get("source") == rcv and l.get("event") == "execute" and l.get("taskId")})
            r[f"invocations_by_{rcv}"] = sum(1 for l in inv if l.get("caller") == rcv and l.get("outcome") != "stale-closed")
        r["invocation_outcomes"] = "|".join(f'{l.get("injection", "")}/{l.get("outcome", "")}' for l in inv)
        r["client_lines"] = len(cli)
        r["client_result"] = "|".join(f'{l.get("result_kind", "")}/{l.get("state", "")}' for l in cli)
        sp = os.path.join(d, "spans.csv")
        by = Counter()
        if os.path.exists(sp):
            for s in csv.DictReader(open(sp)):
                by[s["service"]] += 1
        r["spans"] = sum(by.values()) if os.path.exists(sp) else "n-a"
        r["spans_by_service"] = "|".join(f"{k}={v}" for k, v in sorted(by.items()))
        rows.append(r)
cols = list(rows[0].keys()) if rows else []
w = csv.DictWriter(sys.stdout, fieldnames=cols, lineterminator="\n")
w.writeheader()
for r in rows:
    w.writerow(r)
tot = Counter()
spans = Counter()
for r in rows:
    for k, v in r.items():
        if isinstance(v, int):
            tot[k] += v
    for kv in r["spans_by_service"].split("|"):
        if kv:
            k, v = kv.split("=")
            spans[k] += int(v)
print(f"# {len(rows)} work items; totals: " + " ".join(f"{k}={v}" for k, v in tot.items()), file=sys.stderr)
print("# spans by service: " + " ".join(f"{k}={v}" for k, v in sorted(spans.items())), file=sys.stderr)
