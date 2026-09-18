#!/usr/bin/env python3
"""Follow-ups 15, commit 2: the `chat <model>` span of a failed model call, read from a work item's trace.json,
beside that work item's ledgers.

For every work-item directory given (each holding trace.json and the ledgers `make ledgers` wrote), one row:
the chat span's name, kind, status code and description, error.type, which gen_ai.* attributes it carries and
which of the response-side ones it does not, its server.* attributes; its child HTTP client span's status and
attributes; the egress and mock spans under that; and the ledgers' counts for the work item (ingress arrivals at
the worker, executor entries, Tasks, model invocations with their injection and outcome, the Task's final state
and the execution ledger's error text). Read-only; writes CSV on stdout.

trace.json is the trace backend's /api/v3/traces answer (OTLP JSON): result.resourceSpans[].scopeSpans[].spans[].
Span kind and status code are the OTLP enums, printed by name: kind 3 = SPAN_KIND_CLIENT, status 2 =
STATUS_CODE_ERROR (opentelemetry-proto trace.proto).
"""
import csv, json, os, sys

KIND = {0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}
STATUS = {0: "UNSET", 1: "OK", 2: "ERROR"}
RESPONSE_SIDE = ["gen_ai.response.id", "gen_ai.response.model", "gen_ai.response.finish_reasons",
                 "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens"]


def value(v):
    for k in ("stringValue", "intValue", "boolValue", "doubleValue"):
        if k in v:
            return str(v[k])
    if "arrayValue" in v:
        return "[" + ",".join(value(x) for x in v["arrayValue"].get("values", [])) + "]"
    return json.dumps(v)


def spans_of(path):
    doc = json.load(open(path))
    out = []
    for rs in doc.get("result", doc).get("resourceSpans", []):
        svc = next((value(a["value"]) for a in rs["resource"]["attributes"] if a["key"] == "service.name"), "")
        for ss in rs.get("scopeSpans", []):
            for s in ss.get("spans", []):
                s = dict(s)
                s["service"] = svc
                s["scope"] = ss.get("scope", {}).get("name", "")
                s["attrs"] = {a["key"]: value(a["value"]) for a in s.get("attributes", [])}
                out.append(s)
    return out


def jsonl(path):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path) if l.strip()]


def child(spans, parent, service=None):
    kids = [s for s in spans if s.get("parentSpanId") == parent["spanId"] and (service is None or s["service"] == service)]
    return sorted(kids, key=lambda s: int(s["startTimeUnixNano"]))


def row(d):
    lwi = os.path.basename(d.rstrip("/"))
    spans = spans_of(os.path.join(d, "trace.json"))
    chats = [s for s in spans if s["name"].startswith("chat") and s["service"] == "worker"]
    r = {"work_item": lwi, "chat_spans": len(chats)}
    if len(chats) == 1:
        c = chats[0]
        st = c.get("status", {})
        r.update({
            "chat_name": c["name"], "chat_kind": KIND.get(c.get("kind"), c.get("kind")),
            "chat_status_code": STATUS.get(st.get("code", 0)), "chat_status_description": st.get("message", ""),
            "chat_error_type": c["attrs"].get("error.type", "<absent>"),
            "chat_gen_ai_present": "|".join(sorted(f"{k}={v}" for k, v in c["attrs"].items() if k.startswith("gen_ai."))),
            "chat_response_side_absent": "|".join(k for k in RESPONSE_SIDE if k not in c["attrs"]),
            "chat_response_side_present": "|".join(k for k in RESPONSE_SIDE if k in c["attrs"]) or "none",
            "chat_server": f'{c["attrs"].get("server.address", "")}:{c["attrs"].get("server.port", "")}',
            "chat_lab": "|".join(sorted(f"{k}={v}" for k, v in c["attrs"].items() if k.startswith("lab."))),
            "chat_lab_message_id": c["attrs"].get("lab.message_id", "<absent>"),
            "chat_lab_task_id": c["attrs"].get("lab.task_id", "<absent>"),
        })
        http = child(spans, c)
        r["chat_children"] = "|".join(f'{s["service"]}:{s["name"]}' for s in http)
        if len(http) == 1:
            h = http[0]
            hs = h.get("status", {})
            r.update({
                "http_name": h["name"], "http_kind": KIND.get(h.get("kind")), "http_status_code": STATUS.get(hs.get("code", 0)),
                "http_status_description": hs.get("message", ""),
                "http_response_status_code": h["attrs"].get("http.response.status_code", "<absent>"),
                "http_error_type": h["attrs"].get("error.type", "<absent>"),
            })
            below = []
            frontier = [h]
            while frontier:
                nxt = []
                for p in frontier:
                    for k in child(spans, p):
                        code = k["attrs"].get("http.response.status_code", k["attrs"].get("http.status_code", ""))
                        below.append(f'{k["service"]}:{k["name"]}:{STATUS.get(k.get("status", {}).get("code", 0))}:{code}')
                        nxt.append(k)
                frontier = nxt
            r["below_http"] = " > ".join(below)
    # An arrival is the ingress ledger's phase=arrival line for SendMessage, which is how gate3-matrix.sh counts
    # deliveries; the ledger writes a phase=response line for the same request as well.
    ing = [l for l in jsonl(os.path.join(d, "ingress.jsonl"))
           if l.get("source") == "worker" and l.get("phase") == "arrival" and l.get("method") == "SendMessage"]
    exe = [l for l in jsonl(os.path.join(d, "execution.jsonl")) if l.get("source") == "worker"]
    inv = jsonl(os.path.join(d, "invocation.jsonl"))
    cli = jsonl(os.path.join(d, "client.jsonl"))
    states = [l for l in exe if l.get("event") == "state"]
    r.update({
        "worker_arrivals": len(ing),
        "worker_dispatches": sum(1 for l in exe if l.get("event") == "execute"),
        "tasks": len({l.get("taskId") for l in exe if l.get("event") == "execute" and l.get("taskId")}),
        "invocations": sum(1 for l in inv if l.get("outcome") != "stale-closed"),
        "invocation_injection_outcome": "|".join(f'{l.get("injection", "")}/{l.get("outcome", "")}' for l in inv),
        "task_final_state": states[-1].get("state", "") if states else "",
        "ledger_error_text": "|".join(l["error"] for l in exe if l.get("error")),
        "client_result": "|".join(f'{l.get("result_kind", "")}/{l.get("state", "")}' for l in cli),
        "invocation_messageIds": "|".join(sorted({l.get("messageId", "") for l in inv})),
        "invocation_taskIds": "|".join(sorted({l.get("taskId", "") for l in inv})),
        "execute_taskIds": "|".join(sorted({l.get("taskId", "") for l in exe if l.get("event") == "execute"})),
    })
    if "chat_lab_message_id" in r:
        r["span_ids_equal_ledgers"] = "yes" if (
            r["invocation_messageIds"] == r["chat_lab_message_id"]
            and r["invocation_taskIds"] == r["chat_lab_task_id"] == r["execute_taskIds"]) else "NO"
    return r


rows = [row(d) for d in sys.argv[1:]]
cols = []
for r in rows:
    for k in r:
        if k not in cols:
            cols.append(k)
w = csv.DictWriter(sys.stdout, fieldnames=cols, lineterminator="\n")
w.writeheader()
for r in rows:
    w.writerow(r)
