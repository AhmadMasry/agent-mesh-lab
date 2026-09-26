#!/usr/bin/env python3
"""C-8 counts, from this run directory alone (reads files only). Adapted from C-7's counts.py (its part-1 table),
with the phases, the probe kinds, the card GET line and the proxy's non-request lines added.

One row per send, in c8d/ (overlay-c8-deny in force: Deny on json(request.body).method == "SubscribeToTask" on the two
ingress routes), c8r/ (overlay-c8-require: Require on json(request.body).method != "SubscribeToTask"), c8p/ (overlay-c8-deny
re-applied for one probe) and c8s/ (overlay-c8-require-scoped: Require on request.method == "GET" ||
json(request.body).method != "SubscribeToTask"); c8p and c8s were added after the controller's rulings. Columns:
  kind, operation      sm SendMessage, st SubscribeToTask (naming no task), ss SendStreamingMessage (the load client);
                       cst SubscribeToTask by curl with curl's own headers (Accept: */*); pad a curl SubscribeToTask
                       padded past maxBufferSize; padt the same with the pad inside params.tenant; batch a curl JSON-RPC batch holding one SubscribeToTask; dup one curl
                       object with the method key twice, SendMessage then SubscribeToTask
  client_status        the caller's own record: the load client's end line http_status and stream_end (and its error
                       when stream_end is not-sent), or its unary line's result ("ok:<state>"), or its error line's
                       error; curl's http status
  body_len             curl sends: the bytes sent
  get_lines, get_status  the ingress proxy's access lines with http.method=GET in the send's own window (the load
                       client's card GET, on the Go path only) and their statuses
  agw_card_get_lines, agw_card_get_status  agw-central's access lines for a card GET in the send's window (the load
                       client's card GET on the Python path, route lab/orchestrator, where no rule is applied)
  post_route, post_status, post_error  the ingress proxy's access line for the send's POST, in the send's own window
  proxy_other_lines    the ingress proxy's non-request log lines in the send's window (curl probes only: c8.sh keeps
                       the whole window as ingress-log-window.txt)
  arrivals             pre-dispatch ingress ledger lines, phase arrival, at the receiver asked (worker for go,
                       orchestrator for py), their JSON-RPC methods and body lengths
  responses            the same ledger's response lines and their status
  sdk_received         execution ledger received lines at any receiver (what the SDK dispatched) and their methods; a
                       SubscribeToTask is dispatched without an execute line
  executes, invocations  execution ledger execute lines at any receiver; the mock's invocation lines, every one
  receiver_answer      curl sends: the JSON-RPC result or error the receiver's response body carries, if any
Joins: a send's ledgers are its work item's (make ledgers); its proxy lines are in its own window (one send ran at a
time). Nothing on order. No figure is computed from an access-line timestamp.
"""
import csv
import glob
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OPS = {"sm": "SendMessage", "st": "SubscribeToTask", "ss": "SendStreamingMessage", "cst": "SubscribeToTask",
       "pad": "SubscribeToTask (padded)", "padt": "SubscribeToTask (padded in params.tenant)", "batch": "[SubscribeToTask] (batch)", "dup": "method twice: SendMessage, SubscribeToTask"}
RULE = {"c8d": "Deny", "c8r": "Require", "c8p": "Deny (re-applied)", "c8s": "Require (scoped)"}


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


def lines(path):
    return [l.rstrip("\n") for l in open(path)] if os.path.exists(path) else []


def field(line, name):
    m = re.search(r"(?:^|\s)" + re.escape(name) + r'=("[^"]*"|\S+)', line)
    return m.group(1).strip('"') if m else ""


def answer(path):
    """The JSON-RPC body of a curl response.txt, if it has one: result kind or error code and message. Interim
    100 Continue blocks are skipped; an event-stream body is read from its data: lines."""
    txt = (open(path).read() if os.path.exists(path) else "").replace("\r\n", "\n")
    blocks = txt.split("\n\n")
    while len(blocks) > 1 and blocks[0].startswith("HTTP/1.1 100"):
        blocks = blocks[1:]
    body = "\n\n".join(blocks[1:]).strip() if len(blocks) > 1 else ""
    if not body:
        return ""
    datas = [l[5:].strip() for l in body.split("\n") if l.startswith("data:")]
    if datas:
        body = datas[0]
    try:
        j = json.loads(body)
    except ValueError:
        return "text:" + body[:80].replace("\n", " ")
    items = j if isinstance(j, list) else [j]
    out = []
    for it in items:
        if not isinstance(it, dict):
            out.append(type(it).__name__)
        elif "error" in it:
            e = it["error"] or {}
            out.append("error %s %s" % (e.get("code", ""), str(e.get("message", ""))[:60]))
        elif "result" in it:
            out.append("result")
        else:
            out.append("other")
    return ("sse:" if datas else "") + ("batch:" if isinstance(j, list) else "") + "; ".join(out)


rows = []
for phase in ("c8d", "c8r", "c8p", "c8s"):
    for d in sorted(glob.glob(os.path.join(HERE, phase, "*"))):
        ph, recv, kind = os.path.basename(d).split("-")[:3]
        client = jl(os.path.join(d, "client.jsonl"))
        blen = ""
        if kind in ("cst", "pad", "padt", "batch", "dup"):
            cs = client[0]["http_status"] if client else ""
            blen = str(client[0].get("body_len", "")) if client else ""
        else:
            end = [c for c in client if c.get("line") == "end"]
            if end:
                cs = str(end[0].get("http_status", "")) + "/stream_end=" + str(end[0].get("stream_end", ""))
                if end[0].get("stream_end") == "not-sent":
                    cs += "/err:" + str(end[0].get("error", ""))[:60]
            elif client and client[0].get("state"):
                cs = "ok:" + client[0].get("state", "")
            elif client:
                cs = "err:" + str(client[0].get("error", ""))[:80]
            else:
                cs = ""
        acc = lines(os.path.join(d, "ingress-access.txt"))
        posts = [l for l in acc if "http.method=POST" in l]
        gets = [l for l in acc if "http.method=GET" in l]
        agw_gets = [l for l in lines(os.path.join(d, "agw-central-access.txt"))
                    if "http.method=GET" in l and "agent-card" in field(l, "http.path")]
        p = posts[0] if posts else ""
        win = lines(os.path.join(d, "ingress-log-window.txt"))
        other = [l for l in win if "request gateway=" not in l]
        own = "worker" if recv == "go" else "orchestrator"
        ing = jl(os.path.join(d, "ingress.jsonl"))
        # A batch body carries no identity, so make ledgers finds none of its lines; c8.sh's caller joined them on the
        # body hash the client recorded (ingress-by-body-hash.txt). Its lines carry no source field: the file names
        # the receiver read.
        byhash = [x for x in jl(os.path.join(d, "ingress-by-body-hash.txt")) if x.get("ledger") == "ingress"]
        for x in byhash:
            x.setdefault("source", own)
        ing = ing + byhash
        arr = [x for x in ing if x.get("phase") == "arrival" and x.get("source") == own]
        resp = [x for x in ing if x.get("phase") == "response" and x.get("source") == own]
        exl = jl(os.path.join(d, "execution.jsonl"))
        exe = [x for x in exl if x.get("event") == "execute"]
        recd = [x for x in exl if x.get("event") == "received"]
        inv = jl(os.path.join(d, "invocation.jsonl"))
        rows.append({
            "phase": ph, "rule": RULE[ph], "receiver": recv, "kind": kind, "operation": OPS[kind],
            "work_item": os.path.basename(d), "client_status": cs, "body_len": blen,
            "get_lines": len(gets), "get_status": " ".join(field(l, "http.status") for l in gets),
            "agw_card_get_lines": len(agw_gets), "agw_card_get_status": " ".join(field(l, "http.status") for l in agw_gets),
            "proxy_post_lines": len(posts), "post_route": field(p, "route"), "post_status": field(p, "http.status"),
            "post_error": (field(p, "error") + " " + field(p, "reason")).strip(),
            "proxy_other_lines": len(other),
            "arrivals": len(arr), "arrival_methods": " ".join(sorted({x.get("method", "") for x in arr})),
            "arrival_body_len": " ".join(sorted({str(x.get("body_len", "")) for x in arr})),
            "arrival_a2a_version": " ".join(sorted({x.get("a2a_version", "") for x in arr})),
            "responses": len(resp), "response_status": " ".join(str(x.get("status", "")) for x in resp),
            "sdk_received": len(recd), "sdk_received_methods": " ".join(sorted({x.get("method", "") for x in recd})),
            "executes": len(exe), "invocations": len(inv),
            "receiver_answer": answer(os.path.join(d, "response.txt")) if kind in ("cst", "pad", "padt", "batch", "dup") else "",
        })

with open(os.path.join(HERE, "counts.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)

cells = {}
for r in rows:
    k = (r["rule"], r["receiver"], r["kind"])
    c = cells.setdefault(k, {"sends": 0, "post_status": set(), "post_route": set(), "post_error": set(), "get": set(),
                             "arrivals": 0, "arr_methods": set(), "executes": 0, "invocations": 0, "client": set(),
                             "answer": set(), "other": 0, "agw_get": set(), "recd": 0, "recd_m": set()})
    c["sends"] += 1
    c["post_status"].add(r["post_status"] or "<no POST line>")
    c["post_route"].add(r["post_route"])
    c["post_error"].add(r["post_error"])
    c["get"].add(r["get_status"] or "-")
    c["agw_get"].add(r["agw_card_get_status"] or "-")
    c["arrivals"] += r["arrivals"]
    if r["arrival_methods"]:
        c["arr_methods"].add(r["arrival_methods"])
    c["executes"] += r["executes"]
    c["recd"] += r["sdk_received"]
    if r["sdk_received_methods"]:
        c["recd_m"].add(r["sdk_received_methods"])
    c["invocations"] += r["invocations"]
    c["client"].add(r["client_status"])
    c["answer"].add(r["receiver_answer"])
    c["other"] += r["proxy_other_lines"]
print("# rule receiver kind -> sends; the ingress proxy's GET (card) statuses and POST line (status, route, error);"
      " arrivals at the receiver asked and their methods; executes; invocations; the caller's status; the receiver's"
      " JSON-RPC answer (curl sends); the proxy's non-request lines in the windows (curl probes only)")
for k, c in cells.items():
    print(" ".join(k), "->", f"sends={c['sends']}", "get=" + "|".join(sorted(c["get"])), "agw_card_get=" + "|".join(sorted(c["agw_get"])),
          "post_status=" + "|".join(sorted(c["post_status"])), "route=" + "|".join(sorted(c["post_route"])),
          "post_error=" + "|".join(sorted(x or "-" for x in c["post_error"])),
          f"arrivals={c['arrivals']}", "arrival_methods=" + ("|".join(sorted(c["arr_methods"])) or "-"),
          f"sdk_received={c['recd']}", "received_methods=" + ("|".join(sorted(c["recd_m"])) or "-"),
          f"executes={c['executes']} invocations={c['invocations']}",
          "client=" + "|".join(sorted(c["client"])), "answer=" + ("|".join(sorted(x for x in c["answer"] if x)) or "-"),
          f"proxy_other_lines={c['other']}")
for rule in ("Deny", "Require", "Deny (re-applied)", "Require (scoped)"):
    rr = [r for r in rows if r["rule"] == rule]
    ref = [r for r in rr if r["post_status"] == "403"]
    print(f"{rule}: sends={len(rr)} POST refused by the proxy (403)={len(ref)} of them with an arrival="
          f"{sum(r['arrivals'] > 0 for r in ref)}; card GET lines={sum(r['get_lines'] for r in rr)} of them 403="
          f"{sum(r['get_status'].split().count('403') for r in rr)}")
