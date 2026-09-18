#!/usr/bin/env python3
"""Follow-ups 15, commit 2: is the error text the Go worker records for a failed model call byte-identical to the
text it recorded before follow-ups 14 made the status failure a typed error?

The worker writes that text in one place, the `error` field of its execution ledger's TASK_STATE_FAILED line (its
pod log holds no other line naming the work item). Follow-ups 14 changed the status failure from an fmt error to
a typed `statusError` whose Error() is `fmt.Sprintf("model call: status %d", e.status)`, and said the text was
unchanged. This reads the text out of this task's ledgers and out of the two rows committed before that change
that fail the worker's model call with a status -- the A.3 baseline of 2026-09-09 (a 503) and the egress row of
2026-09-10 (a 500) -- and compares them as bytes. Read-only.
"""
import glob, hashlib, json, sys

def texts(pattern):
    out = {}
    for path in sorted(glob.glob(pattern)):
        for line in open(path, "rb"):
            rec = json.loads(line)
            if rec.get("source") == "worker" and rec.get("error"):
                raw = rec["error"].encode("utf-8")
                out.setdefault(raw, []).append(rec["logical_work_item_id"])
    return out

sets = [
    ("this task, (a) A.3 baseline go", "experiments/runs/2026-09-19-failed-model-call/a3-baseline-go/*/execution.jsonl"),
    ("this task, (b) mock http500 go", "experiments/runs/2026-09-19-failed-model-call/mock-http500-go/*/execution.jsonl"),
    ("before, 2026-09-09 A.3 baseline go", "experiments/runs/2026-09-09-a3-baseline-go/*/execution.jsonl"),
    ("before, 2026-09-10 egress go", "experiments/runs/2026-09-10-a3-egress-go/*/execution.jsonl"),
]
seen = {}
for label, pattern in sets:
    got = texts(pattern)
    print(f"# {label}: {pattern}")
    for raw, items in got.items():
        print(f"  {len(items):>3} line(s)  bytes={len(raw)}  sha256={hashlib.sha256(raw).hexdigest()}  hex={raw.hex()}  text={raw.decode()!r}")
        seen.setdefault(raw, []).append(label)
    print()
print("# each distinct text and the sets it appears in:")
for raw, labels in seen.items():
    print(f"  {raw.decode()!r}: {' | '.join(labels)}")
now_503 = texts(sets[0][1]); before_503 = texts(sets[2][1])
now_500 = texts(sets[1][1]); before_500 = texts(sets[3][1])
ok = set(now_503) == set(before_503) and set(now_500) == set(before_500) and len(now_503) == 1 and len(now_500) == 1
print()
print(f"byte-identical: 503 text {'yes' if set(now_503) == set(before_503) else 'NO'}; 500 text {'yes' if set(now_500) == set(before_500) else 'NO'}")
sys.exit(0 if ok else 1)
