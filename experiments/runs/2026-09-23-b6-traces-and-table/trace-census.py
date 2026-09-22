#!/usr/bin/env python3
"""B-6: the same reading as trace-records.py, taken over EVERY counted work item of
B-4, B-5a and B-5b that the standing backend still holds, so that what one trace
shows is stated as a count and not as an anecdote.

Reads only. It queries the trace backend's documented GET /api/v3/traces binding
once per work item, with the same query `make export-trace` uses, over a base URL
a caller supplies (trace-census.sh starts and stops the port-forward).

    python3 trace-census.py <base-url> <out-csv>

One row per work item:

  row,work_item,spans,trace_ids,roots,dangling_parents,dangling_on,
  services_present,job1_root_op,job1_root_status,job1_root_message,job1_root_ms,
  job1_receiver_server_ms,chat_status,chat_message,chat_ms,chat_response_attrs,
  chat_transport_status,chat_transport_message,job2_present,job2_root_ms,
  job2_proxy_span,job2_route

`chat_response_attrs` is yes when the `chat` span carries the five answer
attributes the GenAI conventions ask of it at the pinned revision
(gen_ai.response.id, gen_ai.response.model, gen_ai.response.finish_reasons and the
two token counts) and no when it carries none of them.

A trace tells the two Jobs apart by the loadgen root span's own operation, not by
order or by any stamp: `invoke_agent <agent>` is Job 1's send, `HTTP POST` on its
own is Job 2's `SubscribeToTask`, and `HTTP GET` is a card read. A row with no
Job 2 (every B-5a variant) leaves the job2 columns empty.
"""
import csv, json, os, sys, urllib.parse, urllib.request

STATUS = {0: "UNSET", 1: "OK", 2: "ERROR"}
RESP = ("gen_ai.response.id", "gen_ai.response.model", "gen_ai.response.finish_reasons",
        "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens")


def anyval(v):
    if v is None:
        return ""
    for k in ("stringValue", "boolValue", "intValue", "doubleValue"):
        if k in v:
            return str(v[k])
    if "arrayValue" in v:
        return "|".join(anyval(x) for x in v["arrayValue"].get("values", []))
    return ""


def fetch(base, lwi):
    q = urllib.parse.urlencode({
        "query.attributes": json.dumps({"lab.work_item": lwi}),
        "query.start_time_min": "2026-09-20T00:00:00Z",
        "query.start_time_max": "2026-09-24T00:00:00Z",
        "query.search_depth": "100",
    })
    with urllib.request.urlopen(base + "/api/v3/traces?" + q, timeout=30) as r:
        raw = r.read().decode()
    dec, i, spans = json.JSONDecoder(), 0, []
    while i < len(raw):
        while i < len(raw) and raw[i].isspace():
            i += 1
        if i >= len(raw):
            break
        obj, i = dec.raw_decode(raw, i)
        res = obj.get("result", obj)
        for rs in res.get("resourceSpans", []):
            svc = ""
            for a in rs.get("resource", {}).get("attributes", []):
                if a["key"] == "service.name":
                    svc = anyval(a.get("value"))
            for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
                for sp in ss.get("spans", []):
                    st = sp.get("status") or {}
                    spans.append({
                        "trace": sp.get("traceId", ""), "id": sp.get("spanId", ""),
                        "parent": sp.get("parentSpanId", ""), "svc": svc,
                        "op": sp.get("name", ""),
                        "start": int(sp["startTimeUnixNano"]), "end": int(sp["endTimeUnixNano"]),
                        "status": STATUS.get(st.get("code", 0), str(st.get("code"))),
                        "msg": st.get("message", ""),
                        "attrs": {a["key"]: anyval(a.get("value")) for a in sp.get("attributes", [])},
                    })
    return spans


def ms(ns):
    return "%.3f" % (ns / 1e6)


def read_one(base, row, lwi):
    sp = fetch(base, lwi)
    out = {"row": row, "work_item": lwi, "spans": len(sp)}
    if not sp:
        return out
    ids = {s["id"] for s in sp}
    dang = [s for s in sp if s["parent"] and s["parent"] not in ids]
    out["trace_ids"] = len({s["trace"] for s in sp})
    out["roots"] = sum(1 for s in sp if not s["parent"])
    out["dangling_parents"] = len(dang)
    out["dangling_on"] = "|".join(sorted("%s %s" % (d["svc"], d["op"]) for d in dang))
    out["services_present"] = "|".join(sorted({s["svc"] for s in sp}))

    # Job 1 and Job 2 by the loadgen root span's own operation, never by order.
    roots = [s for s in sp if not s["parent"] and s["svc"] == "loadgen"]
    j1 = [r for r in roots if r["op"].startswith("invoke_agent")]
    j2 = [r for r in roots if r["op"] == "HTTP POST"]
    if j1:
        r = j1[0]
        out["job1_root_op"], out["job1_root_status"] = r["op"], r["status"]
        out["job1_root_message"], out["job1_root_ms"] = r["msg"], ms(r["end"] - r["start"])
        recv = [s for s in sp if s["trace"] == r["trace"] and s["op"] == "POST /"
                and s["svc"] in ("worker", "orchestrator")]
        if recv:
            out["job1_receiver_server_ms"] = ms(recv[0]["end"] - recv[0]["start"])
    chat = [s for s in sp if s["attrs"].get("gen_ai.operation.name") == "chat"]
    if chat:
        c = chat[0]
        out["chat_status"], out["chat_message"] = c["status"], c["msg"]
        out["chat_ms"] = ms(c["end"] - c["start"])
        out["chat_response_attrs"] = "yes" if all(k in c["attrs"] for k in RESP) else (
            "no" if not any(k in c["attrs"] for k in RESP) else "partial")
        kid = [s for s in sp if s["parent"] == c["id"]]
        if kid:
            out["chat_transport_status"], out["chat_transport_message"] = kid[0]["status"], kid[0]["msg"]
    if j2:
        r = j2[0]
        out["job2_present"] = "yes"
        out["job2_root_ms"] = ms(r["end"] - r["start"])
        prox = [s for s in sp if s["trace"] == r["trace"] and s["attrs"].get("route")]
        if prox:
            out["job2_proxy_span"] = "%s %s" % (prox[0]["svc"], prox[0]["op"])
            out["job2_route"] = prox[0]["attrs"]["route"]
    else:
        out["job2_present"] = "no"
    return out


COLS = ["row", "work_item", "spans", "trace_ids", "roots", "dangling_parents", "dangling_on",
        "services_present", "job1_root_op", "job1_root_status", "job1_root_message", "job1_root_ms",
        "job1_receiver_server_ms", "chat_status", "chat_message", "chat_ms", "chat_response_attrs",
        "chat_transport_status", "chat_transport_message", "job2_present", "job2_root_ms",
        "job2_proxy_span", "job2_route"]


def main(base, out):
    here = os.path.dirname(os.path.abspath(__file__))
    runs = os.path.abspath(os.path.join(here, ".."))
    src = [
        ("B-4 control go", os.path.join(runs, "2026-09-22-b4-control/control/summary.csv"), "work_item", "receiver", "go"),
        ("B-4 control py", os.path.join(runs, "2026-09-22-b4-control/control/summary.csv"), "work_item", "receiver", "py"),
        ("B-5a", os.path.join(runs, "2026-09-22-b5a-removal/removal/summary.csv"), "work_item", "variant", None),
        ("B-5b", os.path.join(runs, "2026-09-22-b5b-removal-resubscribe/rows/summary.csv"), "work_item", "variant", None),
    ]
    rows = []
    for label, path, wcol, vcol, want in src:
        for r in csv.DictReader(open(path)):
            if want is not None and r[vcol] != want:
                continue
            name = label if want is not None else "%s %s" % (label, r[vcol])
            rows.append(read_one(base, name, r[wcol]))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore", lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print("trace-census: %d work item(s) -> %s" % (len(rows), out))


if __name__ == "__main__":
    main(sys.argv[1].rstrip("/"), sys.argv[2])
