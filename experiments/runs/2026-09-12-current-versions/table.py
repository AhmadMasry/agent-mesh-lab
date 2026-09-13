"""Follow-ups 10 / the findings entry's row-by-row table, rendered from comparison.csv (compare.py) and, for
the matrix trace columns, from the span multisets spans_diff.py reads.

One line per item and group with the count and outcome columns joined in the script's own order (a value
alone when all repetitions agree, the full distribution in brackets when they do not; a literal `|` inside a cell is escaped), committed against
current, and `same` only when every one of those columns is the same. A differing trace or notes cell gets a
line of its own whose verdict stays `differs`, with its explanation beside it. Read-only; prints markdown.

  python3 experiments/runs/2026-09-12-current-versions/table.py
"""

import collections
import csv
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.dirname(HERE)


def short(d):
    parts = d.split(" | ")
    v = re.sub(r" x\d+$", "", parts[0]) if len(parts) == 1 else "(" + d + ")"
    return v.replace("task/TASK_STATE_", "").replace("(empty)", "-").replace("|", "\\|")


def span_added(item, group):
    if item.startswith("Gate 3 gateway retry mechanics"):
        route = group
        cdir, ndir, pat = os.path.join(RUNS, "2026-09-09-a3-gateway-retry-mechanics"), os.path.join(HERE, "gateway-retry-mechanics"), "a3r-%s-*" % route
    else:
        name = item.replace("A.3 ", "")
        date = "2026-09-10" if name in ("r3-py", "r4-go", "r4-py", "egress-go", "egress-py") else "2026-09-09"
        cdir, ndir, pat = os.path.join(RUNS, "%s-a3-%s" % (date, name)), os.path.join(HERE, "a3-" + name), "a3m-*"

    def ms(d):
        out = []
        for f in sorted(glob.glob(os.path.join(d, pat, "spans.csv"))):
            out.append(frozenset(collections.Counter((r["service"], r["operation"]) for r in csv.DictReader(open(f))).items()))
        return out

    c, n = ms(cdir), ms(ndir)
    if len(set(c)) != 1 or len(set(n)) != 1:
        return "span multisets vary across repetitions; see spans-diff.txt"
    a, b = collections.Counter(dict(next(iter(set(c))))), collections.Counter(dict(next(iter(set(n)))))
    added, removed = b - a, a - b
    txt = "; ".join("+%d %s `%s`" % (k, s, o) for (s, o), k in sorted(added.items()))
    if removed:
        txt += "; " + "; ".join("-%d %s `%s`" % (k, s, o) for (s, o), k in sorted(removed.items()))
    return (txt or "identical span multisets") + " (one multiset on each side: %d current, %d committed repetitions)" % (len(n), len(c))


NOTE_WHY = {  # fix round 1: the cause of each differing notes cell, as the records show it
    "A.2": ("the committed rows' knob label does not print `CLIENT_RETRY_ON`, while `gate2-a2.sh` prints it at lines 127 and 145 "
            "both at HEAD and at the commits that committed those rows (09979c2, f4ed395), so the rows were counted by an "
            "uncommitted state of the label; the behaviour is the same, because an unset `CLIENT_RETRY_ON` parses to `transport` "
            "(fixtures/loadgen/main.go:109 through internal/httpclient/httpclient.go:82-87, tested at fixtures/loadgen/main_test.go:20-30; "
            "agents/orchestrator/orchestrator/forward.py:83)"),
    "A.3": ("the label `gateway` is the same; the evidence behind it changed branch in experiments/lib/derive-layer.sh, from the "
            "shared-parent rule (:329-331; the two worker server spans share one parent span id, which was dangling when these rows were "
            "committed) to the converging-grandparent rule (:333-336; distinct parents, both agentgateway-waypoint spans, under one "
            "waypoint span), because followups-6's waypoint spans now exist; dangling parents over the row's 20 repetitions 60 committed, 0 now"),
}


def main():
    rows = list(csv.DictReader(open(os.path.join(HERE, "comparison.csv"))))
    groups = collections.OrderedDict()
    for r in rows:
        groups.setdefault((r["item"], r["group"]), []).append(r)
    print("| item | group | repetitions | committed | current | verdict |")
    print("|---|---|---|---|---|---|")
    for (item, group), rs in groups.items():
        n = next(r for r in rs if r["column"] == "rows")
        counts = [r for r in rs if r["kind"] == "count" and r["column"] != "rows"]
        com = " ".join(short(r["committed"]) for r in counts)
        cur = " ".join(short(r["current"]) for r in counts)
        verdict = "same" if all(r["verdict"] == "same" for r in counts) and n["verdict"] == "same" else "**differs**"
        print("| %s | %s | %s / %s | %s | %s | %s |" % (item, group, n["committed"], n["current"], com, cur, verdict))
        trace = {r["column"]: r for r in rs if r["kind"] == "trace"}
        if trace:
            ts = trace["trace_spans"]
            if any(r["verdict"] == "differs" for r in trace.values()):
                print("| %s | %s (trace_spans) | | %s | %s | **differs**: %s |" % (item, group, short(ts["committed"]), short(ts["current"]), span_added(item, group)))
            else:
                print("| %s | %s (trace_spans) | | %s | %s | same |" % (item, group, short(ts["committed"]), short(ts["current"])))
        for r in rs:
            if r["kind"] == "timing":
                print("| %s | %s (%s, measured ms) | | %s | %s | %s |" % (item, group, r["column"], short(r["committed"]), short(r["current"]),
                      "same" if r["verdict"] == "same" else "**differs**: a wall-clock measurement of the mock's fixed 200 ms latency, "
                      "not a count; both runs inside 200-210 ms"))
            if r["kind"] == "notes" and r["verdict"] == "differs":
                print("| %s | %s (notes) | | `%s` | `%s` | **differs**: %s |" % (item, group, short(r["committed"]), short(r["current"]), NOTE_WHY[item.split(" ")[0]]))


if __name__ == "__main__":
    main()
