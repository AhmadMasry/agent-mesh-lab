#!/usr/bin/env python3
"""B-6: one mechanical record per collected trace.

Reads each <traces>/<name>/trace.json -- the raw body of the trace backend's
GET /api/v3/traces binding, the same bytes experiments/lib/jaeger-spans.jq reads
and the same file `make export-trace` wrote -- and prints, per work item:

  * the span count, the trace ids, the roots and the dangling parents, by the
    same definition follow-ups 14 dangling.py uses (a non-empty parentSpanId
    that is no spanId in the same file);
  * every span in start order, as a tree under its parent, with its service,
    operation, span kind, offset from the work item's first span, duration,
    HTTP status, agentgateway route, OpenTelemetry status and error.type;
  * the GenAI attributes on the `chat` span.

Offsets and durations are computed from the OTLP nanosecond fields, in integers.
No agentgateway access-line stamp is read here and none could be: this reads the
trace backend, not a proxy log.

    python3 trace-records.py <traces dir> > trace-records.txt
"""
import json, os, sys, glob

KIND = {0: "UNSPEC", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}
STATUS = {0: "UNSET", 1: "OK", 2: "ERROR"}


def anyval(v):
    if v is None:
        return ""
    for k in ("stringValue", "boolValue"):
        if k in v:
            return str(v[k])
    for k in ("intValue", "doubleValue"):
        if k in v:
            return str(v[k])
    if "arrayValue" in v:
        return "|".join(anyval(x) for x in v["arrayValue"].get("values", []))
    return ""


def attrs(sp):
    return {a["key"]: anyval(a.get("value")) for a in sp.get("attributes", [])}


def load(path):
    raw = open(path).read()
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
                scope = (ss.get("scope") or {}).get("name", "")
                for sp in ss.get("spans", []):
                    st = sp.get("status") or {}
                    a = attrs(sp)
                    spans.append({
                        "trace": sp.get("traceId", ""),
                        "id": sp.get("spanId", ""),
                        "parent": sp.get("parentSpanId", ""),
                        "svc": svc,
                        "scope": scope,
                        "op": sp.get("name", ""),
                        "kind": KIND.get(sp.get("kind", 0), str(sp.get("kind"))),
                        "start": int(sp["startTimeUnixNano"]),
                        "end": int(sp["endTimeUnixNano"]),
                        "status": STATUS.get(st.get("code", 0), str(st.get("code"))),
                        "msg": st.get("message", ""),
                        "attrs": a,
                    })
    return spans


def http_status(a):
    for k in ("http.response.status_code", "http.status_code", "http.status"):
        if a.get(k):
            return a[k]
    return ""


def ms(ns):
    return "%.3f" % (ns / 1e6)


def main(root):
    for d in sorted(glob.glob(os.path.join(root, "*", "trace.json"))):
        name = os.path.basename(os.path.dirname(d))
        spans = load(d)
        if not spans:
            print("== %s == no span\n" % name)
            continue
        ids = {s["id"] for s in spans}
        roots = [s for s in spans if not s["parent"]]
        dang = [s for s in spans if s["parent"] and s["parent"] not in ids]
        t0 = min(s["start"] for s in spans)
        lwis = sorted({s["attrs"].get("lab.work_item") for s in spans if s["attrs"].get("lab.work_item")})
        bysvc = {}
        for s in spans:
            bysvc[s["svc"]] = bysvc.get(s["svc"], 0) + 1

        print("== %s ==" % name)
        print("work item(s) carried on a span: %s" % ",".join(lwis))
        print("spans %d | trace ids %d | roots %d | dangling parents %d"
              % (len(spans), len({s["trace"] for s in spans}), len(roots), len(dang)))
        print("spans by service: %s" % "|".join("%s=%d" % kv for kv in sorted(bysvc.items())))
        for s in dang:
            print("DANGLING PARENT: %s %s (%s) has parent %s, which is no span in this trace"
                  % (s["svc"], s["op"], s["kind"], s["parent"][:16]))

        # one tree per trace id, trace ids in the order their first span starts
        order = sorted({s["trace"] for s in spans}, key=lambda t: min(x["start"] for x in spans if x["trace"] == t))
        for ti, tid in enumerate(order, 1):
            sub = [s for s in spans if s["trace"] == tid]
            kids = {}
            for s in sub:
                kids.setdefault(s["parent"], []).append(s)
            tops = sorted([s for s in sub if s["parent"] not in ids], key=lambda s: s["start"])
            print("  [trace %d/%d %s] %d span(s)" % (ti, len(order), tid[:16], len(sub)))

            def walk(s, depth):
                a = s["attrs"]
                bits = []
                hs = http_status(a)
                if hs:
                    bits.append("http=%s" % hs)
                if a.get("route"):
                    bits.append("route=%s" % a["route"])
                if s["status"] != "UNSET":
                    bits.append("otel=%s%s" % (s["status"], (" %r" % s["msg"]) if s["msg"] else ""))
                if a.get("error.type"):
                    bits.append("error.type=%s" % a["error.type"])
                mark = "  <- DANGLING PARENT %s" % s["parent"][:16] if (s["parent"] and s["parent"] not in ids) else ""
                print("    %s+%9s ms  %-22s %-42s %-8s dur=%12s ms  %s%s"
                      % ("  " * depth, ms(s["start"] - t0), s["svc"], s["op"], s["kind"],
                         ms(s["end"] - s["start"]), " ".join(bits), mark))
                for k in sorted(kids.get(s["id"], []), key=lambda x: x["start"]):
                    walk(k, depth + 1)

            for s in tops:
                walk(s, 0)

        for s in spans:
            if s["attrs"].get("gen_ai.operation.name") == "chat":
                a = s["attrs"]
                print("  GenAI chat span: service=%s op=%s kind=%s otel=%s%s"
                      % (s["svc"], s["op"], s["kind"], s["status"], (" %r" % s["msg"]) if s["msg"] else ""))
                for k in sorted(a):
                    if k.startswith("gen_ai.") or k in ("server.address", "server.port", "error.type",
                                                        "lab.work_item", "lab.message_id", "lab.task_id", "lab.caller"):
                        print("    %s = %s" % (k, a[k]))
        print()


if __name__ == "__main__":
    main(sys.argv[1])
