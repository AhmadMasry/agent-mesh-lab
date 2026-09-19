"""Follow-ups 19, task 3, reading (h): what the trace says about a delivery the WORKER closed by its own injection.

From the work item's trace.json and ledgers, verbatim from the record and with nothing left out of a span's attributes:
  1. the worker's server spans (one per request it received): status, description, lab.injection and
     http.response.status_code -- a 200 on a request that got no response is printed if it is there;
  2. the proxy's entry spans on the agent route: http.status, reason, route, retry.attempt;
  3. the load client's spans for its sends;
  4. the three ledgers' counts.
Same parsing as mock-span/span-reading.py; another selection. Reads files and prints; touches no cluster.

  python3 worker-span-reading.py <work-item-dir> [agent-route]
"""
import json
import os
import sys

d = sys.argv[1]
AGENT_ROUTE = sys.argv[2] if len(sys.argv) > 2 else "lab/worker"
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
order = lambda xs: sorted(xs, key=lambda s: s["start"])
show("1. the worker's server span(s), in start order", order([s for s in spans if s["service"] == "worker" and s["kind"] == "server"]),
     ["lab.injection", "http.request.method", "http.response.status_code", "url.path", "lab.work_item"])
show("2. the proxy's entry span(s) on the agent route %s, in start order" % AGENT_ROUTE,
     order([s for s in spans if s["attrs"].get("route") == AGENT_ROUTE]), ["http.method", "http.status", "reason", "route", "retry.attempt"])
show("3. the load client's client span(s), in start order", order([s for s in spans if s["service"] == "loadgen" and s["kind"] == "client"]),
     ["http.request.method", "http.response.status_code", "error.type", "http.request.resend_count"])

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
