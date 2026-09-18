#!/usr/bin/env python3
"""Follow-ups 15, review fix I2: pair the receivers' ingress-ledger lines (JSON on the pod log) arrival to response,
per receiver, method and work item, for the lines whose ts_arrival falls between two stamps. Reads the log lines on
stdin, each prefixed by the receiver whose log it came from and a tab (the raw log lines carry no source field;
`make ledgers` adds one when it collects them); prints a CSV table, then the totals. Read-only."""
import collections, json, sys
frm, to = sys.argv[1], sys.argv[2]
rows = {}
for raw in sys.stdin:
    src_label, _, line = raw.rstrip("\n").partition("\t")
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("ledger") != "ingress":
        continue
    ts = r.get("ts_arrival", "")
    if not (frm <= ts[:19] + "Z" <= to):
        continue
    k = (src_label, r.get("method", "") or "(none)", r.get("logical_work_item_id", "") or "(none)")
    rows.setdefault(k, collections.Counter())[r.get("phase", "")] += 1
print("source,method,logical_work_item_id,arrivals,responses,paired")
tot = collections.Counter()
for (src, m, lwi), c in sorted(rows.items()):
    a, rsp = c["arrival"], c["response"]
    print(",".join([src, m, lwi, str(a), str(rsp), "yes" if a == rsp else "NO"]))
    tot[(src, m, "arrival")] += a
    tot[(src, m, "response")] += rsp
print()
for (src, m, ph), n in sorted(tot.items()):
    print(f"# total {src} {m} {ph}: {n}")
sm_a = sum(n for (s, m, ph), n in tot.items() if m == "SendMessage" and ph == "arrival")
sm_r = sum(n for (s, m, ph), n in tot.items() if m == "SendMessage" and ph == "response")
unpaired = sum(1 for c in rows.values() if c["arrival"] != c["response"])
print(f"# SendMessage, both receivers: {sm_a} arrivals, {sm_r} responses; rows with an unpaired line: {unpaired}")
