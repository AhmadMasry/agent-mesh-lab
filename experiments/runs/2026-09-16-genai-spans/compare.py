"""Follow-ups 14 / the three re-run rows against the rows already committed.

Adapted from experiments/runs/2026-09-12-current-versions/compare.py (follow-ups 10). Two
changes, both because this task re-runs three rows at REPS=5 rather than the whole matrix at
REPS=20:

  1. Each row is compared against TWO committed runs: the run that first committed it
     (2026-09-09 / 2026-09-10) and the follow-ups 10 re-run of 2026-09-12, so a difference
     can be read against both.
  2. The verdict is on the SET of values a column took, not on the multiset. followups-10
     compared 20 repetitions against 20, where a multiset comparison is exact; here 5
     repetitions are compared against 20 and every column would read `differs` on the
     repetition count alone. Both distributions are still printed in full, as
     `value xN`, so a change in how often a value occurred is visible in the file even
     though the verdict does not turn on it.

Notes cells are compared in rows of their own, with identifiers masked and nothing else
removed, exactly as follow-ups 10 did. Read-only; writes comparison.csv beside this file.

    python3 experiments/runs/2026-09-16-genai-spans/compare.py
"""

import collections
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.dirname(HERE)

NOTE_MASK = [  # identifiers only, in this order so a longer id is never partly matched as a shorter one
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "<uuid>"),
    (re.compile(r"\b[0-9a-f]{32}\b"), "<trace-id>"),
    (re.compile(r"\b[0-9a-f]{16}\b"), "<span-id>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
]

A2_COUNTS = ["arrivals", "messageId_reused", "id_reused", "body_identical", "injection_fired", "executes", "invocations", "client_result"]
A3_COUNTS = ["deliveries", "dispatched", "distinct_messageIds", "tasks", "invocations", "client_result", "second_delivery_layer"]
A3_TRACE = ["trace_spans", "spans_by_service"]

ITEMS = []
for sub, first in (("go-http", "2026-09-09-a2-go-http"), ("py-http-retries", "2026-09-09-a2-py-http-retries")):
    ITEMS.append(("A.2 %s (vs the run that committed it)" % sub, first, "a2-" + sub, ["client", "layer"], A2_COUNTS, [], True))
    ITEMS.append(("A.2 %s (vs the followups-10 re-run)" % sub, "2026-09-12-current-versions/a2-" + sub, "a2-" + sub, ["client", "layer"], A2_COUNTS, [], True))
ITEMS.append(("A.3 r3-py (vs the run that committed it)", "2026-09-10-a3-r3-py", "a3-r3-py", ["receiver", "run", "sub"], A3_COUNTS, A3_TRACE, True))
ITEMS.append(("A.3 r3-py (vs the followups-10 re-run)", "2026-09-12-current-versions/a3-r3-py", "a3-r3-py", ["receiver", "run", "sub"], A3_COUNTS, A3_TRACE, True))


def read(path):
    with open(path) as f:
        lines = [l for l in f if not l.startswith("#")]
    return list(csv.DictReader(lines))


def dist(values):
    c = collections.Counter(values)
    return " | ".join("%s x%d" % (v if v != "" else "(empty)", n) for v, n in sorted(c.items()))


def values_of(values):
    return sorted(set(values))


def norm_note(s):
    s = s or ""
    for rx, rep in NOTE_MASK:
        s = rx.sub(rep, s)
    return s


def main():
    out = []
    missing = []
    for item, cdir, ndir, groups, counts, trace, notes in ITEMS:
        cpath = os.path.join(RUNS, cdir, "summary.csv")
        npath = os.path.join(HERE, ndir, "summary.csv")
        if not os.path.exists(npath):
            missing.append((item, npath)); continue
        crow, nrow = read(cpath), read(npath)
        keys = sorted({tuple(r.get(g, "") for g in groups) for r in crow + nrow})
        for k in keys:
            cg = [r for r in crow if tuple(r.get(g, "") for g in groups) == k]
            ng = [r for r in nrow if tuple(r.get(g, "") for g in groups) == k]
            gname = "/".join(k) or "(one request)"
            out.append((item, gname, "repetitions", str(len(cg)), str(len(ng)), "n-a", "count"))
            for col, kind in [(c, "count") for c in counts] + [(c, "trace") for c in trace]:
                cv = [r.get(col, "") for r in cg]
                nv = [r.get(col, "") for r in ng]
                verdict = "same" if values_of(cv) == values_of(nv) else "differs"
                out.append((item, gname, col, dist(cv), dist(nv), verdict, kind))
            if notes:
                cv = [norm_note(r.get("notes", "")) for r in cg]
                nv = [norm_note(r.get("notes", "")) for r in ng]
                verdict = "same" if values_of(cv) == values_of(nv) else "differs"
                out.append((item, gname, "notes (identifiers masked)", dist(cv), dist(nv), verdict, "notes"))
    with open(os.path.join(HERE, "comparison.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["item", "group", "column", "committed", "current", "verdict", "kind"])
        w.writerows(out)
    n = collections.Counter((r[6], r[5]) for r in out)
    print("rows compared:", len(out), dict(n))
    for r in out:
        if r[5] == "differs":
            print("DIFFERS", r[6], "|", r[0], "|", r[1], "|", r[2], "| committed:", r[3], "| current:", r[4])
    for item, p in missing:
        print("not yet run:", item, p)


if __name__ == "__main__":
    sys.exit(main())
