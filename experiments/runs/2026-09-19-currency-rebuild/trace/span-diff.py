"""Follow-ups 19, task 3: which spans appeared or went between two exported work items.

Groups every span of each trace.json by (service, instrumentation scope, scope version, kind, name) and prints
the groups whose count differs, then, for the groups that appeared, where they sit (the name and scope of each
one's parent) and what they carry. Reads committed files; touches no cluster.

  python3 span-diff.py <old-work-item-dir> <new-work-item-dir> [<groups.csv>]

With a third argument, every group of both records is also written as one CSV row: service, scope, kind, name,
the count in each record, and `equal` or `differs`.
"""
import collections
import json
import os
import sys

KIND = {0: "unspecified", 1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"}


def anyval(v):
    for k in ("stringValue", "intValue", "boolValue", "doubleValue"):
        if k in v:
            return v[k]
    return ""


def load(d):
    text, dec, i, spans = open(os.path.join(d, "trace.json")).read(), json.JSONDecoder(), 0, []
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        obj, i = dec.raw_decode(text, i)
        for rs in obj.get("result", obj).get("resourceSpans", []):
            res = {a["key"]: anyval(a["value"]) for a in rs.get("resource", {}).get("attributes", [])}
            for ss in rs.get("scopeSpans", []):
                sc = ss.get("scope", {})
                for s in ss.get("spans", []):
                    k = s.get("kind", 0)
                    k = k.replace("SPAN_KIND_", "").lower() if isinstance(k, str) else KIND.get(k, k)
                    spans.append({"service": res.get("service.name", ""), "scope": sc.get("name", ""), "scope_version": sc.get("version", ""),
                                  "kind": k, "name": s.get("name", ""), "id": s.get("spanId", ""), "parent": s.get("parentSpanId", ""),
                                  "attrs": {a["key"]: anyval(a["value"]) for a in s.get("attributes", [])},
                                  "res": res})
    return spans


old, new = load(sys.argv[1]), load(sys.argv[2])
key = lambda s: (s["service"], s["scope"], s["kind"], s["name"])
co, cn = collections.Counter(map(key, old)), collections.Counter(map(key, new))
print("# old %s: %d spans; new %s: %d spans" % (sys.argv[1], len(old), sys.argv[2], len(new)))
print("## groups (service | scope | kind | name) whose count differs: old -> new")
for k in sorted(set(co) | set(cn)):
    if co[k] != cn[k]:
        print("  %-13s | %-58s | %-8s | %-44s %d -> %d" % (k[0], k[1], k[2], k[3], co[k], cn[k]))
print("## groups unchanged: %d of %d" % (sum(1 for k in set(co) | set(cn) if co[k] == cn[k]), len(set(co) | set(cn))))
if len(sys.argv) > 3:
    import csv
    with open(sys.argv[3], "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["service", "instrumentation_scope", "kind", "name", "spans_old", "spans_new", "verdict"])
        for k in sorted(set(co) | set(cn)):
            w.writerow(list(k) + [co[k], cn[k], "equal" if co[k] == cn[k] else "differs"])
print("## scope versions, per service and scope: old -> new")
vo = collections.defaultdict(set); vn = collections.defaultdict(set)
for s in old: vo[(s["service"], s["scope"])].add(s["scope_version"])
for s in new: vn[(s["service"], s["scope"])].add(s["scope_version"])
for k in sorted(set(vo) | set(vn)):
    print("  %-13s | %-58s | %s -> %s" % (k[0], k[1], "|".join(sorted(vo.get(k, {"<absent>"}))), "|".join(sorted(vn.get(k, {"<absent>"})))))
byid = {s["id"]: s for s in new}
print("## in the new record, each span of a group that grew or appeared: its parent, and its own attributes")
for s in new:
    k = key(s)
    if cn[k] > co[k]:
        p = byid.get(s["parent"])
        print("  %s | %s | %s | %s" % (s["service"], s["scope"], s["kind"], s["name"]))
        print("      parent: %s" % ("%s | %s | %s" % (p["scope"], p["kind"], p["name"]) if p else "<none or not in this export>"))
        print("      attrs: %s" % json.dumps(s["attrs"], sort_keys=True)[:700])
print("## resource attributes of the orchestrator's spans that name a version: old -> new")
for label, spans in (("old", old), ("new", new)):
    r = next((s["res"] for s in spans if s["service"] == "orchestrator"), {})
    print("  %s: %s" % (label, {k: v for k, v in r.items() if "version" in k or "sdk" in k or k == "service.name"}))
