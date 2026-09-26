#!/usr/bin/env python3
"""Follow-on D-3: the counts, from this run directory alone. Writes counts.csv (one row per send) and prints the
per-cell summary that counts.txt holds.

Per send (one directory under a phase):
  client       curl: the HTTP status; the load client: result_kind/state, or its error, and grpc_status on gRPC
  proxy        the ingress's access lines of the send's window: http.status and, where present, error and reason,
               in order (the card GET first on the Go path)
  extauthz     the fixture's decision lines of the send's window (extauthz-window.txt): how many, and for each the
               decision, reason, setting, binding, body_len and size
  receiver     at the receiver the send addressed (worker for go, orchestrator for py): arrivals on the pre-dispatch
               ingress ledger, SDK received lines and executes on the execution ledger, and model invocations
               (every invocation line of the work item). The batch probes carry no identity in their body and are
               read from ingress-by-body-hash.txt.
No figure is computed from an agentgateway access-line stamp.
"""
import csv
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

D = os.path.dirname(os.path.abspath(__file__))
PHASES = ["p0", "deny", "allow", "unavail", "shapes"]


def lines(p):
    out = []
    if not os.path.exists(p):
        return out
    with open(p) as f:
        for l in f:
            l = l.strip()
            if not l.startswith("{"):
                continue
            try:
                out.append(json.loads(l))
            except json.JSONDecodeError:
                pass
    return out


def access(p):
    out = []
    if not os.path.exists(p):
        return out
    for l in open(p):
        m = re.search(r"http\.status=(\d+)", l)
        if not m:
            continue
        e = re.search(r'error="([^"]*)"', l)
        r = re.search(r"reason=(\S+)", l)
        path = re.search(r"http\.path=(\S+)", l)
        out.append((m.group(1), e.group(1) if e else "", r.group(1) if r else "", path.group(1) if path else ""))
    return out


def client(w):
    cl = lines(os.path.join(w, "client.jsonl"))
    if not cl:
        return ""
    c = cl[-1]
    if c.get("client") == "curl":
        return "http=%s" % c.get("http_status")
    ends = [x for x in cl if x.get("line") == "end"] or cl
    c = ends[-1]
    s = c.get("error") or "%s/%s" % (c.get("result_kind", ""), c.get("state", ""))
    evs = [x.get("state") for x in cl if x.get("line") == "event" and x.get("state")]
    if evs:
        s += " last_event_state=%s" % evs[-1]
    if c.get("stream_end"):
        s += " stream_end=%s" % c["stream_end"]
    if c.get("grpc_status") is not None:
        s += " grpc=%s attempts=%s transparent=%s" % (c.get("grpc_status"), c.get("grpc_attempts"), c.get("grpc_transparent_attempts"))
    return s


rows = []
for ph in PHASES:
    pd = os.path.join(D, ph)
    if not os.path.isdir(pd):
        continue
    for name in sorted(os.listdir(pd)):
        w = os.path.join(pd, name)
        if not os.path.isdir(w):
            continue
        m = re.match(r"^(\w+)-(jsonrpc|rest|grpc)-(go|py)-(\w+)-d3a-(\d+)$", name)
        if not m:
            continue
        _, binding, recv, kind, n = m.groups()
        target = "worker" if recv == "go" else "orchestrator"
        ing = lines(os.path.join(w, "ingress.jsonl"))
        if kind == "batch":
            ing = lines(os.path.join(w, "ingress-by-body-hash.txt"))
        ex = lines(os.path.join(w, "execution.jsonl"))
        inv = lines(os.path.join(w, "invocation.jsonl"))
        dec = lines(os.path.join(w, "extauthz-window.txt"))
        acc = access(os.path.join(w, "ingress-access.txt"))
        arrivals = sum(1 for x in ing if x.get("source") == target and x.get("phase") == "arrival")
        received = sum(1 for x in ex if x.get("source") == target and x.get("event") == "received")
        executes = sum(1 for x in ex if x.get("source") == target and x.get("event") == "execute")
        # The task's last state on the execution ledger (its last "state" event); a SubscribeToTask the SDK answered
        # without a task has none. The "result" line's state is the first event a stream carried, not the last.
        st_ev = [x.get("state") for x in ex if x.get("source") == target and x.get("event") == "state"]
        states = st_ev[-1:]
        rows.append(OrderedDict(
            phase=ph, binding=binding, receiver=recv, kind=kind, n=int(n), work_item=name,
            client=client(w),
            proxy=" ".join("%s%s%s" % (s, ("/" + e) if e else "", ("/" + r) if r else "") for s, e, r, _ in acc),
            extauthz_lines=len(dec),
            extauthz=" ".join("%s:%s:%s:%s:len=%s:size=%s" % (x.get("decision"), x.get("reason"), x.get("undecidable_setting"),
                                                           x.get("binding"), x.get("body_len"), x.get("size")) for x in dec),
            extauthz_settings="|".join(sorted({x.get("undecidable_setting", "") for x in dec})),
            arrivals=arrivals, sdk_received=received, executes=executes,
            task_last_state="|".join(s or "" for s in states), invocations=len(inv),
        ))

with open(os.path.join(D, "counts.csv"), "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    wr.writeheader()
    wr.writerows(rows)

cells = defaultdict(list)
for r in rows:
    cells[(r["phase"], r["binding"], r["receiver"], r["kind"])].append(r)
print("# D-3 counts, from this directory alone (counts.py). One line per cell: phase binding receiver kind, sends,")
print("# then each distinct value with how many sends had it.")
for key in sorted(cells, key=lambda k: (PHASES.index(k[0]), k[1], k[2], k[3])):
    rs = cells[key]

    def tally(f):
        t = defaultdict(int)
        for r in rs:
            t[str(r[f])] += 1
        return ", ".join("%s x%d" % (k, v) for k, v in sorted(t.items()))
    print("%s %s %s %s: sends=%d" % (key + (len(rs),)))
    for f in ["client", "proxy", "extauthz_lines", "extauthz", "arrivals", "sdk_received", "executes", "task_last_state", "invocations"]:
        print("    %-14s %s" % (f, tally(f)))
tot = len(rows)
settings = defaultdict(int)
for r in rows:
    for x in lines(os.path.join(D, r["phase"], r["work_item"], "extauthz-window.txt")):
        settings[(r["phase"], x.get("undecidable_setting"))] += 1
print("# sends: %d; decision lines by phase and the setting each line carries: %s" % (
    tot, ", ".join("%s/%s=%d" % (k[0], k[1], v) for k, v in sorted(settings.items()))))
g = [r for r in rows if r["binding"] == "grpc"]
print("# gRPC sends: %d; with grpc attempts other than 1 or a transparent attempt: %d" % (
    len(g), sum(1 for r in g if "attempts=1 transparent=0" not in r["client"])))

# Every decision line of every send window, accounted for: by phase, the send's binding and kind, and whether the line is
# the send's card GET (path /.well-known/agent-card.json) or the operation itself; each joined to the send by the work
# item the line carries (from the body or the X-Logical-Work-Item-Id header). A line whose work item is not its send's
# is counted apart as unjoined.
acc = defaultdict(int)
unjoined = 0
for r in rows:
    for x in lines(os.path.join(D, r["phase"], r["work_item"], "extauthz-window.txt")):
        what = "card GET" if x.get("path") == "/.well-known/agent-card.json" else "operation"
        if x.get("logical_work_item_id") != r["work_item"]:
            unjoined += 1
        acc[(r["phase"], r["binding"], r["receiver"], r["kind"], what)] += 1
print("# decision lines by phase, binding, receiver, kind and what was checked (joined on work item):")
for ph in PHASES:
    keys = [k for k in acc if k[0] == ph]
    if not keys:
        continue
    sub = defaultdict(int)
    for k in keys:
        sub[k[4]] += acc[k]
    print("#   %s: %d lines (%s)" % (ph, sum(acc[k] for k in keys), ", ".join("%s %d" % kv for kv in sorted(sub.items()))))
    for k in sorted(keys):
        print("#     %-8s %-3s %-6s %-9s %d" % (k[1], k[2], k[3], k[4], acc[k]))
print("# decision lines not joined to their send's work item: %d" % unjoined)
allx = [x for r in rows for x in lines(os.path.join(D, r["phase"], r["work_item"], "extauthz-window.txt"))]
print("# decision lines with source_principal empty: %d of %d" % (sum(1 for x in allx if not x.get("source_principal")), len(allx)))

# The unavailable window's collection wait (review-d3 M7), from the driver's own stamps in each send's steps.txt, never from an
# access line: the Job's end to make ledgers' exit (which includes collect()'s 2 s pause), and the send's start to that exit.
import datetime
import statistics


def _t(s):
    return datetime.datetime.strptime(s[:26], "%Y-%m-%dT%H:%M:%S.%f")


waits, spans = [], []
for r in rows:
    if r["phase"] != "unavail":
        continue
    st = open(os.path.join(D, r["phase"], r["work_item"], "steps.txt")).read().splitlines()
    job = [l for l in st if " Job " in l][0].split()[0]
    led = [l for l in st if "make ledgers exit" in l][0].split()[0]
    waits.append((_t(led) - _t(job)).total_seconds())
    spans.append((_t(led) - _t(st[0].split()[0])).total_seconds())
if waits:
    print("# unavail: Job end -> make ledgers exit, %d sends: min %.1f s, median %.1f s, max %.1f s; send start -> make ledgers exit: median %.1f s" % (
        len(waits), min(waits), statistics.median(waits), max(waits), statistics.median(spans)))
