"""Follow-ups 19, task 4b, fix round 1: the a2a-python event-queue spans per repetition, on this run's Python rows and
on the 2026-09-12 record's, from every committed spans.csv. It answers one question the entry's `_deliver_to_sink`
bullet raised: whether the 10-vs-12 split is a property of the moved pin or one this lab already had.

Per row it prints, over the row's repetitions, the distribution of the count of
`a2a.server.events.event_queue_v2.EventQueueSource.enqueue_event` and of `…_deliver_to_sink` in one repetition's
spans.csv, and the row's client result. Reads committed files of both run directories; touches no cluster, re-derives
no compared cell — every cell of comparison.csv comes from compare.py over the two summary.csv files.

  python3 event-spans.py
"""
import collections
import csv
import glob
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.dirname(HERE)
BASE = os.path.join(RUNS, "2026-09-12-current-versions")
PREFIX = "a2a.server.events.event_queue_v2.EventQueueSource."
PY_ROWS = ["a3-baseline-py", "a3-r1-py-http", "a3-r1-py-sdk", "a3-r2-py-ingress", "a3-r2-py-ingress-incluster",
           "a3-r3-py", "a3-r4-py", "a3-egress-py"]
NEW_ROWS = ["a3-baseline-py-service", "a3-r2-py-service", "a3-r4-py-service"]


def counts(d):
    enq, deliver = collections.Counter(), collections.Counter()
    for f in sorted(glob.glob(os.path.join(d, "a3m-*", "spans.csv"))):
        rows = list(csv.DictReader(open(f)))
        enq[sum(1 for r in rows if r["operation"] == PREFIX + "enqueue_event")] += 1
        deliver[sum(1 for r in rows if r["operation"] == PREFIX + "_deliver_to_sink")] += 1
    return enq, deliver


def result(d):
    p = os.path.join(d, "summary.csv")
    if not os.path.exists(p):
        return "-"
    with open(p) as f:
        rows = list(csv.DictReader(l for l in f if not l.startswith("#")))
    return "/".join(sorted({r["client_result"].replace("task/TASK_STATE_", "") for r in rows}))


def show(title, base, rows):
    print("## %s" % title)
    for r in rows:
        d = os.path.join(base, r)
        if not os.path.isdir(d):
            print("  %-28s (no such row)" % r)
            continue
        enq, deliver = counts(d)
        fmt = lambda c: ", ".join("%d in %d reps" % (k, n) for k, n in sorted(c.items()))
        print("  %-28s Task %-9s enqueue_event: %-22s _deliver_to_sink: %s" % (r, result(d), fmt(enq), fmt(deliver)))


def main():
    show("this run (a2a-sdk 1.1.4), the eight Python rows that exist on both dates", HERE, PY_ROWS)
    show("this run, the three Service-addressed rows (no committed side)", HERE, NEW_ROWS)
    show("the committed 2026-09-12 record (a2a-sdk 1.1.2)", BASE, PY_ROWS)


if __name__ == "__main__":
    main()
