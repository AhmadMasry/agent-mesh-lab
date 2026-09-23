#!/usr/bin/env python3
"""C-10 counts, from this run directory alone (reads files only). Adapted from C-8's counts.py.

One row per send, in c10r/ (the row: REFUSE_OPERATION=SubscribeToTask on both agents, B-4's ingress paths, C-6's sends.sh)
and c10p/ (one padded SubscribeToTask per receiver, C-8's c8.sh probe). Columns:
  kind, operation      sm SendMessage, st SubscribeToTask naming no task, ss SendStreamingMessage (the load client);
                       cst SubscribeToTask by curl with curl's own headers; pad a curl SubscribeToTask of 2 200 000 bytes with a
                       top-level x_pad member (go); padt the same with the pad in params.tenant (py)
  client               the caller's own record. Load client, streamed modes: its end line's http_status, content_type,
                       wire_error_code and wire_error_message (the wire observer: the bytes of the answer as the SDK read
                       them), events, stream_end and error. Load client, unary: its line's result state or error. Curl: the
                       http status, the response's Content-Type and the JSON-RPC answer its body carries
  post_route, post_status  the ingress proxy's access line for the send's POST, in the send's own window
  arrivals, arrival_remote  pre-dispatch ingress ledger arrival lines at the receiver asked (worker for go, orchestrator
                       for py), their JSON-RPC methods, body lengths and remote addresses
  responses            the same ledger's response lines: status, and stream_end when the receiver sent text/event-stream
  exec_own             execution ledger lines at the receiver asked, in order: event and, on a result line, the error and
                       stream_end
  exec_worker_fwd      py only: the worker's execution lines for the orchestrator's forwarded SendMessage
  executes, invocations  execute lines at any receiver; the mock's invocation lines
Joins: a send's ledgers are its work item's (make ledgers); its proxy lines are its own window (one send ran at a time).
No figure is computed from an access-line timestamp.
"""
import csv
import glob
import json
import os
import re
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
OPS = {"sm": "SendMessage", "st": "SubscribeToTask", "ss": "SendStreamingMessage", "cst": "SubscribeToTask (curl)",
       "pad": "SubscribeToTask padded, x_pad", "padt": "SubscribeToTask padded, params.tenant"}


def jl(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def lines(path):
    return [l.rstrip("\n") for l in open(path)] if os.path.exists(path) else []


def field(line, name):
    m = re.search(r"(?:^|\s)" + re.escape(name) + r'=("[^"]*"|\S+)', line)
    return m.group(1).strip('"') if m else ""


def curl_answer(path):
    """HTTP status line, Content-Type and the JSON-RPC answer of a curl -i response.txt; 100 Continue blocks skipped."""
    txt = (open(path).read() if os.path.exists(path) else "").replace("\r\n", "\n")
    blocks = txt.split("\n\n")
    while len(blocks) > 1 and blocks[0].startswith("HTTP/1.1 100"):
        blocks = blocks[1:]
    head = blocks[0].split("\n") if blocks else []
    ctype = next((h.split(":", 1)[1].strip() for h in head if h.lower().startswith("content-type:")), "")
    body = "\n\n".join(blocks[1:]).strip() if len(blocks) > 1 else ""
    datas = [l[5:].strip() for l in body.split("\n") if l.startswith("data:")]
    if datas:
        body = datas[0]
    ans = ""
    if body:
        try:
            j = json.loads(body)
            if isinstance(j, dict) and "error" in j:
                e = j["error"] or {}
                ans = "error %s %s" % (e.get("code", ""), e.get("message", ""))
            elif isinstance(j, dict) and "result" in j:
                ans = "result"
            else:
                ans = "other"
        except ValueError:
            ans = "text:" + body[:80].replace("\n", " ")
    return ctype, ("sse:" if datas else "") + ans


rows = []
for phase in ("c10r", "c10p"):
    for d in sorted(glob.glob(os.path.join(HERE, phase, "*"))):
        base = os.path.basename(d)
        _, recv, kind = base.split("-")[:3]
        n = base.split("-")[-1]
        own = "worker" if recv == "go" else "orchestrator"
        client = jl(os.path.join(d, "client.jsonl"))
        if kind in ("cst", "pad", "padt"):
            ctype, ans = curl_answer(os.path.join(d, "response.txt"))
            c = client[0] if client else {}
            cl = "curl http=%s content_type=%s answer=%s" % (c.get("http_status", ""), ctype, ans)
        else:
            end = [x for x in client if x.get("line") == "end"]
            if end:
                e = end[0]
                cl = ("http=%s content_type=%s wire_error=%s %s events=%s stream_end=%s error=%s" % (
                    e.get("http_status"), e.get("content_type"), e.get("wire_error_code"), e.get("wire_error_message", ""),
                    e.get("events"), e.get("stream_end"), e.get("error", "")))
            elif client and client[0].get("state"):
                cl = "unary ok state=%s" % client[0].get("state")
            elif client:
                cl = "unary error=%s" % client[0].get("error", "")
            else:
                cl = "no client line"
        posts = [l for l in lines(os.path.join(d, "ingress-access.txt")) if "http.method=POST" in l]
        p = posts[0] if posts else ""
        ing = jl(os.path.join(d, "ingress.jsonl"))
        arr = [x for x in ing if x.get("phase") == "arrival" and x.get("source") == own]
        resp = [x for x in ing if x.get("phase") == "response" and x.get("source") == own]
        ex = jl(os.path.join(d, "execution.jsonl"))
        exo = [x for x in ex if x.get("source") == own]
        exw = [x for x in ex if x.get("source") == "worker"] if recv == "py" else []

        def exs(xs):
            out = []
            for x in xs:
                s = x.get("event", "")
                if x.get("event") == "received":
                    s += ":" + x.get("method", "")
                if x.get("event") == "result":
                    s += "[" + ";".join(filter(None, ["error=" + x["error"] if x.get("error") else "",
                                                      "stream_end=" + x["stream_end"] if x.get("stream_end") else "",
                                                      "state=" + x["state"] if x.get("state") else ""])) + "]"
                if x.get("event") == "state":
                    s += ":" + x.get("state", "")
                out.append(s)
            return " ".join(out)

        rows.append({
            "phase": phase, "receiver": recv, "kind": kind, "n": n, "operation": OPS[kind], "lwi": base,
            "client": cl,
            "post_route": field(p, "route"), "post_status": field(p, "http.status"), "post_lines": len(posts),
            "arrivals": len(arr), "arrival_methods": ",".join(x.get("method", "") for x in arr),
            "arrival_body_len": ",".join(str(x.get("body_len", "")) for x in arr),
            "arrival_remote": ",".join(x.get("remote", "").rsplit(":", 1)[0] for x in arr),
            "arrival_identity_keys": ",".join(sorted(k for x in arr for k in x
                                                     if re.search("ident|principal|spiffe|user|caller|auth|cert", k, re.I))),
            "responses": ",".join("%s%s" % (x.get("status", ""), "/stream_end=" + x["stream_end"] if x.get("stream_end") else "")
                                  for x in resp),
            "exec_own": exs(exo), "exec_worker_fwd": exs(exw),
            "executes": sum(1 for x in ex if x.get("event") == "execute"),
            "invocations": len(jl(os.path.join(d, "invocation.jsonl"))),
        })

with open(os.path.join(HERE, "counts.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)

out = []
for phase in ("c10r", "c10p"):
    for recv in ("go", "py"):
        for kind in ("sm", "st", "ss", "cst", "pad", "padt"):
            rs = [r for r in rows if r["phase"] == phase and r["receiver"] == recv and r["kind"] == kind]
            if not rs:
                continue
            out.append("== %s %s %s (%s): %d sends" % (phase, recv, kind, OPS[kind], len(rs)))
            for col in ("client", "post_route", "post_status", "arrivals", "arrival_methods", "arrival_remote",
                        "arrival_identity_keys", "responses", "exec_own", "exec_worker_fwd", "executes", "invocations"):
                c = Counter(str(r[col]) for r in rs)
                out.append("   %-22s %s" % (col, " | ".join("%s x%d" % (k if k != "" else "(empty)", v) for k, v in c.most_common())))
open(os.path.join(HERE, "counts.txt"), "w").write("\n".join(out) + "\n")
print("\n".join(out))
