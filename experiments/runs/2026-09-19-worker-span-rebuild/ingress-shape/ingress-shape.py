"""Follow-ups 19, task 3c, reading (d): the ingress ledger's line shape on the cluster, beside task 3's (rule 5).

For each pair of ingress.jsonl files (task 3's work item, this rebuild's work item for the same row) and for each
line, in file order: the phase, the source, the keys IN THE ORDER THE LINE CARRIES THEM (json parsed with an
order-keeping hook), whether the two key lists are equal in names and order, and every key whose value differs.
Nothing is masked: a differing value is printed with both sides. Keys whose value belongs to one run by
construction are labelled `per-run` (the stamp, the peer's address and port, the JSON-RPC id, the message id, the
work-item id, which carries the run's nonce, and the body hash, which covers those ids); a difference in any
other key is labelled DIFFERS.

A third optional argument per pair is a file of RAW lines, as `kubectl logs deploy/worker` printed them for the
work item, before `make ledgers` passed them through jq (which appends `source` and keeps key order): the raw
line's keys are compared with the collected line's keys minus `source`.

  python3 ingress-shape.py <label> <task-3 ingress.jsonl> <this ingress.jsonl> [<this raw lines>] [-- <label> ...]
"""
import json
import sys

PER_RUN = {"ts_arrival", "remote", "id", "messageId", "logical_work_item_id", "body_sha256"}


def lines(path):
    out = []
    for x in open(path):
        x = x.strip()
        if x:
            out.append(json.loads(x, object_pairs_hook=lambda pairs: pairs))
    return out


def groups(argv):
    g, cur = [], []
    for a in argv:
        if a == "--":
            g.append(cur)
            cur = []
        else:
            cur.append(a)
    if cur:
        g.append(cur)
    return g


total = same_shape = differs_other = 0
for grp in groups(sys.argv[1:]):
    label, a_path, b_path = grp[0], grp[1], grp[2]
    raw_path = grp[3] if len(grp) > 3 else None
    a, b = lines(a_path), lines(b_path)
    print("## %s" % label)
    print("   task 3: %s (%d lines)" % (a_path, len(a)))
    print("   here:   %s (%d lines)" % (b_path, len(b)))
    if len(a) != len(b):
        print("   LINE COUNT DIFFERS: %d against %d" % (len(a), len(b)))
    for i, (la, lb) in enumerate(zip(a, b), 1):
        ka, kb = [k for k, _ in la], [k for k, _ in lb]
        da, db = dict(la), dict(lb)
        total += 1
        ok = ka == kb
        same_shape += ok
        print("   line %d: phase=%s source=%s | phase=%s source=%s" % (i, da.get("phase"), da.get("source"), db.get("phase"), db.get("source")))
        print("     keys, task 3: %s" % ",".join(ka))
        print("     keys, here:   %s" % ",".join(kb))
        print("     key names and order equal: %s (%d keys | %d keys)" % ("yes" if ok else "NO", len(ka), len(kb)))
        for k in ka:
            if k in db and da[k] != db[k]:
                kind = "per-run" if k in PER_RUN else "DIFFERS"
                differs_other += kind == "DIFFERS"
                print("     value %-8s %s: %s | %s" % (kind, k, json.dumps(da[k]), json.dumps(db[k])))
        eq = [k for k in ka if k in db and da[k] == db[k]]
        print("     values equal on: %s" % ",".join(eq))
    if raw_path:
        raw = lines(raw_path)
        print("   raw lines from the worker pod's own log: %s (%d lines)" % (raw_path, len(raw)))
        coll = [l for l in b if dict(l).get("source") == "worker"]
        if len(raw) != len(coll):
            print("   RAW LINE COUNT DIFFERS from the collected worker lines: %d against %d" % (len(raw), len(coll)))
        for i, (lr, lc) in enumerate(zip(raw, coll), 1):
            kr, kc = [k for k, _ in lr], [k for k, _ in lc if k != "source"]
            print("     raw line %d: keys equal to the collected line's minus `source`, in order: %s; values equal: %s" % (
                i, "yes" if kr == kc else "NO", "yes" if dict(lr) == {k: v for k, v in lc if k != "source"} else "NO"))
    print()
print("# lines compared: %d; key names and order equal on: %d; values differing in a key that is not per-run: %d" % (total, same_shape, differs_other))
