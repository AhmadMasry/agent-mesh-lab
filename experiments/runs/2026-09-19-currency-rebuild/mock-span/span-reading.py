"""Follow-ups 19, task 3, reading (e): what three spans of one work item say about a model call the mock closed.

From the work item's trace.json (the trace backend's /api/v3/traces response as `make export-trace` wrote it)
and its ledgers, prints, verbatim from the record and with nothing left out of a span's attributes:
  1. the mock's server span for the chat-completions call: status, description, lab.injection and
     http.response.status_code -- the 200 is printed if it is there;
  2. the agent's chat span for the same call: status, description, error.type, beside the execution ledger's
     error text for the Task;
  3. the proxy's entry span on the model route: http.status, route, retry.attempt;
  4. the three ledgers' counts.
Reads files and prints; touches no cluster.

  python3 span-reading.py <work-item-dir> [model-route]
"""
import json
import os
import sys

d = sys.argv[1]
MODEL_ROUTE = sys.argv[2] if len(sys.argv) > 2 else "agentgateway-waypoint/model-via-agw"
KIND = {0: "unspecified", 1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"}
STATUS = {0: "Unset", 1: "Ok", 2: "Error"}


def anyval(v):
    for k in ("stringValue", "intValue", "boolValue", "doubleValue", "bytesValue"):
        if k in v:
            return v[k]
    if "arrayValue" in v:
        return "|".join(str(anyval(x)) for x in v["arrayValue"].get("values", []))
    return ""


def chunks(text):  # the binding streams: a sequence of JSON objects, not one
    dec, i = json.JSONDecoder(), 0
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        obj, i = dec.raw_decode(text, i)
        yield obj


spans = []
for c in chunks(open(os.path.join(d, "trace.json")).read()):
    body = c.get("result", c)
    for rs in body.get("resourceSpans", []):
        res = {a["key"]: anyval(a["value"]) for a in rs.get("resource", {}).get("attributes", [])}
        for ss in rs.get("scopeSpans", []):
            for s in ss.get("spans", []):
                kind = s.get("kind", 0)
                if isinstance(kind, str):
                    kind = kind.replace("SPAN_KIND_", "").lower()
                else:
                    kind = KIND.get(kind, kind)
                st = s.get("status", {}) or {}
                code = st.get("code", 0)
                if isinstance(code, str):
                    code = {"STATUS_CODE_UNSET": "Unset", "STATUS_CODE_OK": "Ok", "STATUS_CODE_ERROR": "Error"}.get(code, code)
                else:
                    code = STATUS.get(code, code)
                spans.append({
                    "service": res.get("service.name", ""), "scope": ss.get("scope", {}).get("name", ""),
                    "name": s.get("name", ""), "kind": kind, "span_id": s.get("spanId", ""),
                    "parent": s.get("parentSpanId", ""), "status": code, "description": st.get("message", ""),
                    "attrs": {a["key"]: anyval(a["value"]) for a in s.get("attributes", [])},
                    "events": len(s.get("events", []) or []),
                    "start": int(s.get("startTimeUnixNano", 0)), "end": int(s.get("endTimeUnixNano", 0)),
                })


def show(title, picked, named):
    print("## %s: %d span(s)" % (title, len(picked)))
    for s in picked:
        print("  service=%s scope=%s" % (s["service"], s["scope"]))
        print("    name=%s" % s["name"])
        print("    kind=%s" % s["kind"])
        print("    status.code=%s" % s["status"])
        print('    status.description="%s"' % s["description"])
        for k in named:
            print("    %s=%s" % (k, s["attrs"].get(k, "<absent>")))
        print("    duration_ms=%.1f events=%d span_id=%s parent=%s" % ((s["end"] - s["start"]) / 1e6, s["events"], s["span_id"], s["parent"] or "<none>"))
        print("    every attribute:")
        for k in sorted(s["attrs"]):
            print("      %s=%s" % (k, s["attrs"][k]))


print("# %s: %d spans; by service: %s" % (d, len(spans), "|".join(
    "%s=%d" % (k, sum(1 for s in spans if s["service"] == k)) for k in sorted({s["service"] for s in spans}))))
show("1. the mock's server span(s)", [s for s in spans if s["service"] == "mockllm"],
     ["lab.injection", "http.response.status_code", "lab.work_item"])
show("2. the agent's chat span(s)", [s for s in spans if s["attrs"].get("gen_ai.operation.name") == "chat"],
     ["error.type", "gen_ai.operation.name", "server.address", "server.port"])
show("3. the proxy's entry span(s) on the model route %s" % MODEL_ROUTE,
     [s for s in spans if s["attrs"].get("route") == MODEL_ROUTE], ["http.status", "route", "retry.attempt"])


def lines(name):
    p = os.path.join(d, name)
    return [json.loads(x) for x in open(p) if x.strip()] if os.path.exists(p) else []


ing, exe, inv, cli = lines("ingress.jsonl"), lines("execution.jsonl"), lines("invocation.jsonl"), lines("client.jsonl")
arrivals = [x for x in ing if x.get("phase") == "arrival" and x.get("method") and " " not in x.get("method", "")]
print("## 4. the ledgers")
print("  ingress: deliveries (JSON-RPC arrivals) = %d (%s)" % (len(arrivals), ", ".join("%s@%s" % (x.get("method"), x.get("source")) for x in arrivals)))
print("  execution: received = %d, execute = %d, tasks (distinct taskId) = %d" % (
    sum(1 for x in exe if x.get("event") == "received"), sum(1 for x in exe if x.get("event") == "execute"),
    len({x.get("taskId") for x in exe if x.get("taskId")})))
for x in exe:
    if x.get("error") or x.get("state"):
        print("    execution line: event=%s state=%s error=%s" % (x.get("event"), x.get("state", ""), json.dumps(x.get("error", ""))))
print("  invocation: lines = %d; by outcome: %s" % (len(inv), ", ".join("%s=%d" % (o, sum(1 for x in inv if x.get("outcome") == o)) for o in sorted({x.get("outcome") for x in inv}))))
for x in inv:
    print("    invocation line: caller=%s injection=%s outcome=%s latency_ms=%s" % (x.get("caller"), x.get("injection"), x.get("outcome"), x.get("latency_ms")))
for x in cli:
    print("  client line: attempt=%s result_kind=%s state=%s error=%s" % (x.get("attempt"), x.get("result_kind"), x.get("state"), json.dumps(x.get("error", ""))))
