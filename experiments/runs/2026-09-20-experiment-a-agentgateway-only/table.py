"""Follow-ups 19, task 4b / a copy of experiments/runs/2026-09-12-current-versions/table.py, changed in: the paths
(the committed side of a matrix row is that record's own a3-<row>/ directory, the committed side of the retry
mechanics item is gone with the item), and NOTE_WHY, which is this task's causes for the notes cells that differ here
and is keyed by the whole item name, with the first word as a fallback key as in follow-ups 10's version. The rendering is that program's. Everything below this paragraph is follow-ups 10's text.

Follow-ups 10 / the findings entry's row-by-row table, rendered from comparison.csv (compare.py) and, for
the matrix trace columns, from the span multisets spans_diff.py reads.

One line per item and group with the count and outcome columns joined in the script's own order (a value
alone when all repetitions agree, the full distribution in brackets when they do not; a literal `|` inside a cell is escaped), committed against
current, and `same` only when every one of those columns is the same. A differing trace or notes cell gets a
line of its own whose verdict stays `differs`, with its explanation beside it. Read-only; prints markdown.

  python3 experiments/runs/2026-09-12-current-versions/table.py
  (this copy: python3 experiments/runs/2026-09-20-experiment-a-agentgateway-only/table.py)
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
    name = item.replace("A.3 ", "")
    cdir, ndir, pat = os.path.join(RUNS, "2026-09-12-current-versions", "a3-" + name), os.path.join(HERE, "a3-" + name), "a3m-*"

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


# The cause of each differing notes cell, as this run's records show it. Keyed by the item; a key that is only the
# item's first word is the fallback, as follow-ups 10's version was. Every cell below is a `layer_reason` whose LABEL
# (`second_delivery_layer`, a count column) is the same on both sides in 20 of 20 repetitions.
RENAMED = ("the label and every count are the same, in 20 of 20 repetitions on both sides. What differs is the text of the "
           "evidence `experiments/lib/derive-layer.sh` prints with it")
NOTE_WHY = {
    "A.3 r1-go-http": (RENAMED + ": the branch is the same one (each attempt crossed the proxy separately), and its sentence about the "
                       "istiod-driven waypoint it was measured on now says that waypoint was retired on 2026-09-19 (`(retired 2026-09-19)`, "
                       "the only difference between the two masked strings)"),
    "A.3 r2-go-waypoint": (RENAMED + ": the branch is the same one (the converging-grandparent rule), and the proxy it names is "
                           "`agw-central` where it was `agentgateway-waypoint` — the topology of 2026-09-19 (docs/proposal-notes.md), where "
                           "one agentgateway-managed proxy is the waypoint for both agents and the egress for the model host"),
    "A.3 r4-go": (RENAMED + ": the branch is the same one (the converging-grandparent rule), and the proxy it names is `agw-central` "
                  "where it was `agentgateway-waypoint` — the topology of 2026-09-19"),
    "A.3 r1-py-http": (RENAMED + ": the rule now names the route it read (`route lab/orchestrator-ingress on the agentgateway-ingress in "
                       "front of orchestrator`), because since the topology change one proxy carries several routes and the rule keys on the "
                       "span's `route` (follow-ups 19 task 2)"),
    "A.3 r2-py-ingress": (RENAMED + ": the rule now names the route it read (`route lab/orchestrator-ingress on the agentgateway-ingress in "
                          "front of orchestrator`), because the rule keys on the span's `route` since the topology change"),
    "A.3 r2-py-ingress-incluster": (RENAMED + ": the rule now names the route it read (`route lab/orchestrator-ingress on the "
                                    "agentgateway-ingress in front of orchestrator`), because the rule keys on the span's `route` since the "
                                    "topology change"),
    "A.3 r4-py": (RENAMED + ": the rule now names the route it read (`route lab/orchestrator-ingress on the agentgateway-ingress in front of "
                  "orchestrator`), because the rule keys on the span's `route` since the topology change"),
    "A.3 r3-go": (RENAMED + ": the model leg is a route on the central proxy now, so the reason names `route "
                  "agentgateway-waypoint/model-via-agw` where it said `the egress waypoint`"),
    "A.3 r3-py": (RENAMED + ": the model leg is a route on the central proxy now, so the reason names `route "
                  "agentgateway-waypoint/model-via-agw` where it said `the egress waypoint`"),
    "A.3 egress-go": (RENAMED + ": the model leg is a route on the central proxy now, so the reason names `route "
                      "agentgateway-waypoint/model-via-agw` and says the proxy made 2 upstream attempts under that entry, where it said "
                      "`the egress waypoint`"),
    "A.3 egress-py": (RENAMED + ": the model leg is a route on the central proxy now, so the reason names `route "
                      "agentgateway-waypoint/model-via-agw` and says the proxy made 2 upstream attempts under that entry, where it said "
                      "`the egress waypoint`"),
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
                print("| %s | %s (notes) | | `%s` | `%s` | **differs**: %s |" % (item, group, short(r["committed"]), short(r["current"]), NOTE_WHY.get(item, NOTE_WHY.get(item.split(" ")[0], "cause not established"))))


if __name__ == "__main__":
    main()
