"""Follow-ups 19, task 4b: the three Service-addressed Python rows of the proposal note of 2026-09-19, printed beside
the Python-receiver rows through the ingress they are reported beside (the note: "beside … not instead of them").
They have no committed side, so compare.py has no item for them; this prints each row's own summary.csv as that tool
prints a distribution — a value alone when all repetitions agree, `value xN | value xM` when they do not — and then,
from each row's own ingress.jsonl files, the identity fields rule 5 asks for, which no summary.csv column carries.
Reads this run directory only; touches no cluster.

  python3 new-rows.py    (prints markdown)
"""
import collections
import csv
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
COLS = ["deliveries", "dispatched", "distinct_messageIds", "tasks", "invocations", "client_result", "second_delivery_layer"]
ROWS = [("A.3 baseline py, Service-addressed (new)", "a3-baseline-py-service"),
        ("A.3 baseline py, through the ingress", "a3-baseline-py"),
        ("A.3 R2 py, Service-addressed (new)", "a3-r2-py-service"),
        ("A.3 R2 py, through the ingress, in-cluster stimulus", "a3-r2-py-ingress-incluster"),
        ("A.3 R2 py, through the ingress, stimulus from outside", "a3-r2-py-ingress"),
        ("A.3 R4 py, Service-addressed (new)", "a3-r4-py-service"),
        ("A.3 R4 py, through the ingress", "a3-r4-py")]


def dist(rows, col):
    c = collections.Counter(r[col] for r in rows)
    if len(c) == 1:
        return next(iter(c)).replace("task/TASK_STATE_", "")
    return " | ".join("%s x%d" % (v.replace("task/TASK_STATE_", ""), n) for v, n in sorted(c.items()))


def identity(d):
    """the ingress ledger's own identity fields over a row's repetitions: how many lines, and how many distinct
    JSON-RPC ids, messageIds and body hashes each repetition holds (rule 5's fields, which summary.csv does not carry)"""
    out = collections.Counter()
    for wi in sorted(glob.glob(os.path.join(HERE, d, "a3m-*"))):
        lines = [json.loads(l) for l in open(os.path.join(wi, "ingress.jsonl")) if l.strip()]
        out[(len(lines), len({l.get("id") for l in lines if l.get("id")}),
             len({l.get("messageId") for l in lines if l.get("messageId")}),
             len({l.get("body_sha256") for l in lines if l.get("body_sha256")}))] += 1
    return " | ".join("%d ingress lines, %d JSON-RPC id, %d messageId, %d body hash in %d reps" % (k + (n,))
                      for k, n in sorted(out.items()))


def main():
    print("| row | repetitions | " + " | ".join(COLS) + " | trace_spans | spans_by_service |")
    print("|" + "---|" * (len(COLS) + 4))
    for label, d in ROWS:
        with open(os.path.join(HERE, d, "summary.csv")) as f:
            rows = [r for r in csv.DictReader(l for l in f if not l.startswith("#"))]
        print("| %s | %d | %s | %s | %s |" % (label, len(rows), " | ".join(dist(rows, c) for c in COLS),
                                              dist(rows, "trace_spans"), "`" + dist(rows, "spans_by_service").replace("|", "\\|") + "`"))
    print()
    print("The ingress ledger's identity fields, per repetition (rule 5; no summary.csv column carries them):")
    for label, d in ROWS:
        print("  %-54s %s" % (label, identity(d)))


if __name__ == "__main__":
    main()
