"""Follow-ups 19, task 4b / a copy of experiments/runs/2026-09-12-current-versions/spans_diff.py, changed in its paths
only: the committed side of each matrix row is the 2026-09-12 record's own a3-<row>/ directory (its committed
spans.csv files), the current side this directory. Everything below this paragraph is follow-ups 10's text.

Follow-ups 10 / what the A.3 matrix rows' trace columns gained or lost, named from spans.csv.

For each matrix row, every repetition's spans.csv is reduced to a multiset of (service, operation). The
committed repetitions and the current ones are each summarised as the distribution of those multisets;
then, per row, the spans present in the current multiset and not in the committed one (and the reverse)
are listed, with how many repetitions of each side carry exactly that multiset. Operations that embed a
per-run value are not expected here: the matrix spans are named by method and route or host. Read-only;
writes spans-diff.txt beside this file.

  python3 experiments/runs/2026-09-12-current-versions/spans_diff.py
  (this copy: python3 experiments/runs/2026-09-20-experiment-a-agentgateway-only/spans_diff.py)
"""

import collections
import csv
import glob
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.dirname(HERE)

ROWS = [("baseline-go", "2026-09-09"), ("baseline-py", "2026-09-09"), ("r1-go-http", "2026-09-09"), ("r1-go-sdk", "2026-09-09"),
        ("r1-py-http", "2026-09-09"), ("r1-py-sdk", "2026-09-09"), ("r2-go-waypoint", "2026-09-09"), ("r2-go-ingress", "2026-09-09"),
        ("r2-py-ingress", "2026-09-09"), ("r2-py-ingress-incluster", "2026-09-09"), ("r3-go", "2026-09-09"), ("r3-py", "2026-09-10"),
        ("r4-go", "2026-09-10"), ("r4-py", "2026-09-10"), ("egress-go", "2026-09-10"), ("egress-py", "2026-09-10")]


def multisets(d):
    out = []
    for f in sorted(glob.glob(os.path.join(d, "a3m-*", "spans.csv"))):
        c = collections.Counter((r["service"], r["operation"]) for r in csv.DictReader(open(f)))
        out.append(frozenset(c.items()))
    return out


def show(ms):
    c = collections.Counter(ms)
    return c


def main():
    lines = []
    for name, date in ROWS:
        cdir = os.path.join(RUNS, "2026-09-12-current-versions", "a3-" + name)
        ndir = os.path.join(HERE, "a3-" + name)
        if not os.path.isdir(ndir):
            lines.append("== %s: not run" % name); continue
        cm, nm = multisets(cdir), multisets(ndir)
        lines.append("== A.3 %s: committed %d spans.csv (%d distinct span multisets), current %d (%d distinct)" % (
            name, len(cm), len(set(cm)), len(nm), len(set(nm))))
        cc, nc = collections.Counter(cm), collections.Counter(nm)
        # compare the most common multiset of each side, and list every distinct pairing
        for nset, nn in nc.most_common():
            for cset, cn in cc.most_common():
                a, b = collections.Counter(dict(cset)), collections.Counter(dict(nset))
                added, removed = b - a, a - b
                lines.append("   current x%d vs committed x%d: spans %d -> %d" % (nn, cn, sum(a.values()), sum(b.values())))
                for (svc, op), k in sorted(added.items()):
                    lines.append("      + %d  %-28s %s" % (k, svc, op))
                for (svc, op), k in sorted(removed.items()):
                    lines.append("      - %d  %-28s %s" % (k, svc, op))
                if not added and not removed:
                    lines.append("      (identical multisets)")
    open(os.path.join(HERE, "spans-diff.txt"), "w").write(
        "# A.3 matrix rows: spans gained (+) and lost (-) per repetition, current against committed, by (service, operation).\n"
        "# Built by spans_diff.py from every a3m-*/spans.csv of both run directories.\n\n" + "\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
