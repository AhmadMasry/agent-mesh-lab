#!/usr/bin/env python3
"""C-7 counts, from this run directory alone (reads files only). Adapted from C-6's counts.py (the part-1 table is
its program with the glob, the refusal status and this docstring changed; the part-2 table is new).

Part 1: one row per send of c7h/ (overlay-c7-header in force: a Deny on Accept: text/event-stream on the two ingress
routes). Columns:
  kind, operation      sm SendMessage, st SubscribeToTask, ss SendStreamingMessage (the load client); cst
                       SubscribeToTask sent by curl with curl's own headers
  client_status        the caller's own record: the load client's end line http_status, or its unary line's result
                       (a unary client line carries the result, not the status: "ok:<state>"); curl's http status
  post_route, post_status, post_method, post_path, post_host
                       the ingress proxy's access line for the send's POST, found in the send's own window by
                       http.method=POST (one send ran at a time; the window's other line is the load client's card GET,
                       on the Go path only, since the Python path's card GET crosses agw-central)
  post_error           that line's error and reason, when it has one
  arrivals             pre-dispatch ingress ledger lines, phase arrival, at the receiver asked (worker for go, orchestrator
                       for py), and their JSON-RPC method
  executes, invocations  execution ledger execute lines at any receiver; the mock's invocation lines, every one
Joins: a send's ledgers are its work item's (make ledgers); its proxy line is in its own window. Nothing on order.
"""
import csv
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OPS = {"sm": "SendMessage", "st": "SubscribeToTask", "ss": "SendStreamingMessage", "cst": "SubscribeToTask"}


def jl(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def field(line, name):
    m = re.search(r"(?:^|\s)" + re.escape(name) + r'=("[^"]*"|\S+)', line)
    return m.group(1).strip('"') if m else ""


rows = []
for d in sorted(glob.glob(os.path.join(HERE, "c7h", "*"))):
    phase, recv, kind = os.path.basename(d).split("-")[:3]
    client = jl(os.path.join(d, "client.jsonl"))
    if kind == "cst":
        cs = client[0]["http_status"] if client else ""
    else:
        end = [c for c in client if c.get("line") == "end"]
        if end:
            cs = str(end[0].get("http_status", ""))
        else:
            cs = ("ok:" + client[0].get("state", "")) if client else ""
    posts = [l for l in open(os.path.join(d, "ingress-access.txt")) if "http.method=POST" in l] if os.path.exists(
        os.path.join(d, "ingress-access.txt")) else []
    p = posts[0] if posts else ""
    own = "worker" if recv == "go" else "orchestrator"
    ing = jl(os.path.join(d, "ingress.jsonl"))
    arr = [x for x in ing if x.get("phase") == "arrival" and x.get("source") == own]
    exe = [x for x in jl(os.path.join(d, "execution.jsonl")) if x.get("event") == "execute"]
    inv = jl(os.path.join(d, "invocation.jsonl"))
    rows.append({
        "phase": phase, "receiver": recv, "kind": kind, "operation": OPS[kind], "work_item": os.path.basename(d),
        "client_status": cs, "proxy_post_lines": len(posts),
        "post_route": field(p, "route"), "post_status": field(p, "http.status"), "post_method": field(p, "http.method"),
        "post_path": field(p, "http.path"), "post_host": field(p, "http.host"),
        "post_error": (field(p, "error") + " " + field(p, "reason")).strip(),
        "arrivals": len(arr), "arrival_methods": " ".join(sorted({x.get("method", "") for x in arr})),
        "arrival_a2a_version": " ".join(sorted({x.get("a2a_version", "") for x in arr})),
        "executes": len(exe), "invocations": len(inv),
    })

with open(os.path.join(HERE, "counts.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)

cells = {}
for r in rows:
    k = (r["phase"], r["receiver"], r["kind"])
    c = cells.setdefault(k, {"sends": 0, "post_status": set(), "post_route": set(), "method_path": set(),
                             "arrivals": 0, "executes": 0, "invocations": 0, "client": set()})
    c["sends"] += 1
    c["post_status"].add(r["post_status"])
    c["post_route"].add(r["post_route"])
    c["method_path"].add(r["post_method"] + " " + r["post_path"])
    c["arrivals"] += r["arrivals"]
    c["executes"] += r["executes"]
    c["invocations"] += r["invocations"]
    c["client"].add(r["client_status"])
print("# phase receiver kind -> sends; the ingress proxy's POST line (status, route, method and path); arrivals at the"
      " receiver asked; executes; invocations; the caller's status")
for k, c in cells.items():
    print(" ".join(k), "->", f"sends={c['sends']}", "post_status=" + "|".join(sorted(c["post_status"])),
          "route=" + "|".join(sorted(c["post_route"])), "method_path=" + "|".join(sorted(c["method_path"])),
          f"arrivals={c['arrivals']} executes={c['executes']} invocations={c['invocations']}",
          "client=" + "|".join(sorted(c["client"])))
print("sends:", len(rows), "refused by the proxy (403):", sum(r["post_status"] == "403" for r in rows),
      "of them with an arrival:", sum(r["post_status"] == "403" and r["arrivals"] > 0 for r in rows))

# Part 2: one row per identity probe (identity/): per proxy line carrying the probe's trace id, the route, the
# src.identity the proxy logged (absent when it logged none), the source address and the status.
prow = []
for d in sorted(glob.glob(os.path.join(HERE, "identity", "*"))):
    c = jl(os.path.join(d, "client.jsonl"))[0]
    t = c["trace_id"]
    own_arr = [x for x in jl(os.path.join(d, "ingress.jsonl")) if x.get("phase") == "arrival"]
    for proxy in ("ingress", "agw-central"):
        f = os.path.join(d, proxy + "-access.txt")
        for l in (open(f) if os.path.exists(f) else []):
            if "trace.id=" + t not in l:
                continue
            prow.append({"path": c["path"], "work_item": os.path.basename(d), "client_status": c["http_status"],
                         "arrivals": len(own_arr), "proxy": proxy, "route": field(l, "route"),
                         "src_identity": field(l, "src.identity") or "<absent>", "src_addr": field(l, "src.addr"),
                         "status": field(l, "http.status"), "reason": field(l, "reason")})
with open(os.path.join(HERE, "identity-counts.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(prow[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(prow)
agg = {}
for r in prow:
    k = (r["path"], r["proxy"], r["route"], r["src_identity"], r["status"], r["reason"])
    agg[k] = agg.get(k, 0) + 1
print("# part 2: path, proxy, route, the src.identity the proxy logged, status, reason -> lines")
for k in sorted(agg):
    print(" ".join(k), "->", agg[k])
probes = {}
for r in prow:
    probes[r["work_item"]] = (r["path"], r["client_status"], r["arrivals"])
per = {}
for p, s, a in probes.values():
    e = per.setdefault(p, [0, [], 0])
    e[0] += 1; e[1].append(s); e[2] += a > 0
for p in sorted(per):
    print(f"probe path {p}: probes={per[p][0]} client_status={'|'.join(sorted(set(per[p][1])))} with an arrival={per[p][2]}")
