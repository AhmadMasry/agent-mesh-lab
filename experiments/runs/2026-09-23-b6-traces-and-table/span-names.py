#!/usr/bin/env python3
"""B-6, added in the review round: what the twelve collected traces NAME and what they ATTRIBUTE.

The first version of this step's boundary statement said "no span anywhere says the operation is
SubscribeToTask". That is false, and the committed traces are what falsify it: the Python receiver's
zero-code instrumentation emits spans named after the handler method it is running. This tool is the
derivation, so the corrected statement is re-derivable rather than asserted:

  * every span name, per service, with its count;
  * every attribute KEY, with the count of spans carrying it, and whether any matches a2a.* or rpc.*;
  * which work items carry a span whose NAME holds an A2A operation, and which carry none;
  * which spans carry a task id under any key at all, and which leg each of those is on.

    python3 span-names.py <traces dir> > span-names.txt

Reads the committed trace.json files only. No cluster access, no stamp arithmetic.
"""
import json, glob, os, re, sys, collections

# Matched against the span name's FINAL dotted component, exactly: "on_message_send" is a prefix of
# "on_message_send_stream", and a substring test would report a send handler this lab never ran.
OPS = ("on_subscribe_to_task", "on_message_send_stream", "on_message_send", "on_get_task", "on_cancel_task")


def ops_in(name):
    return [o for o in OPS if name.rsplit(".", 1)[-1] == o]


def load(path):
    raw, dec, i, out = open(path).read(), json.JSONDecoder(), 0, []
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
                    svc = a["value"].get("stringValue", "")
            for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
                scope = (ss.get("scope") or {}).get("name", "")
                for sp in ss.get("spans", []):
                    out.append({
                        "svc": svc, "scope": scope, "name": sp.get("name", ""),
                        "id": sp.get("spanId", ""), "parent": sp.get("parentSpanId", ""),
                        "keys": [a["key"] for a in sp.get("attributes", [])],
                    })
    return out


def main(root):
    per = {}
    for p in sorted(glob.glob(os.path.join(root, "*", "trace.json"))):
        per[os.path.basename(os.path.dirname(p))] = load(p)
    allsp = [s for v in per.values() for s in v]
    print("# What the twelve collected traces NAME and what they ATTRIBUTE. Derived from the committed")
    print("# trace.json files alone.")
    print("total spans across the twelve traces: %d" % len(allsp))

    print("\n== attribute KEYS matching a2a.* or rpc.* ==")
    keys = collections.Counter(k for s in allsp for k in s["keys"])
    proto = sorted(k for k in keys if re.match(r"^(a2a|rpc)\.", k))
    print("  %s" % (", ".join(proto) if proto else "NONE — 0 keys in %d spans" % len(allsp)))
    print("  keys whose text merely CONTAINS 'a2a': %s"
          % (", ".join("%s (%d spans)" % (k, keys[k]) for k in sorted(keys) if "a2a" in k.lower()) or "none"))
    print("  protocol-shaped attributes that do exist: %s"
          % ", ".join("%s (%d)" % (k, keys[k]) for k in sorted(keys) if k.startswith("gen_ai.agent")))

    print("\n== span NAMES holding an A2A operation, per work item ==")
    for wi in sorted(per):
        ops = sorted({o for s in per[wi] for o in ops_in(s["name"])})
        print("  %-26s spans=%3d  %s" % (wi, len(per[wi]), "|".join(ops) if ops else "none"))
    withops = [wi for wi in per if any(ops_in(s["name"]) for s in per[wi])]
    py = [wi for wi in per if any(s["svc"] == "orchestrator" for s in per[wi])]
    go = [wi for wi in per if wi not in py]
    print("  work items whose spans name an operation: %d of %d — %s"
          % (len(withops), len(per), ", ".join(sorted(withops))))
    print("  Python work items %d, of which naming an operation %d; Go work items %d, of which %d"
          % (len(py), len([w for w in withops if w in py]), len(go), len([w for w in withops if w in go])))

    print("\n== the distinct span names each service emits ==")
    for svc in sorted({s["svc"] for s in allsp}):
        names = collections.Counter(s["name"] for s in allsp if s["svc"] == svc)
        print("  %s (%d spans, %d distinct names)" % (svc, sum(names.values()), len(names)))
        for n, c in sorted(names.items())[:8]:
            print("      %4d  %s" % (c, n))
        if len(names) > 8:
            print("      ... %d further names" % (len(names) - 8))

    print("\n== spans carrying a task id under ANY key, and which leg each is on ==")
    for wi in sorted(per):
        byid = {s["id"]: s for s in per[wi]}
        for s in per[wi]:
            hit = [k for k in s["keys"] if "task_id" in k.lower()]
            if hit:
                par = byid.get(s["parent"], {}).get("name", "<not in this trace>")
                print("  %-26s %-13s %-28s keys=%s  (parent: %s)"
                      % (wi, s["svc"], s["name"][:28], ",".join(sorted(hit)), par[:34]))


if __name__ == "__main__":
    main(sys.argv[1])
