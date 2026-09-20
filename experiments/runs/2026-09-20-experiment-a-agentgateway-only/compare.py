"""Follow-ups 19, task 4b / the row-by-row comparison of the Experiment A re-run on the topology of 2026-09-19 against
the committed run outputs of follow-ups 10's re-run, experiments/runs/2026-09-12-current-versions/.

A copy of that record's compare.py, changed in its paths and nowhere else in its method: the committed side of every
item is now the 2026-09-12 record's own output directory for that item (its committed summary.csv, read as committed,
never re-derived or re-exported), and the current side is this directory. Two items were labelled
"(vs followups-9 rebuild #2)": the clean-check one is left out, because with that change its committed side is the
same file as the item above it and every row would be printed twice; the trace one, the only trace item, keeps its
place with its label cut to "Gate 3 trace per work item". Items whose output this task does not produce (the Gate 1
baselines, the openai runs 5-6, the wire version, the three ledgers, the mock's determinism check, the gateway retry
mechanics) print "not yet run", as the tool always has for a missing file. Everything below this paragraph is
follow-ups 10's text.

Follow-ups 10 / the row-by-row comparison of the re-run against the committed run outputs.

For every item: read the committed summary.csv and the current one, blank the work-item id, group the
rows by the item's group columns (run type, mode x path, client x layer, receiver, ...), and for every
compared column write the distribution of values in each file as `value x n`, then `same` when the two
distributions are equal and `differs` when they are not. Nothing is smoothed: a column differs if any
one repetition differs. Read-only; writes comparison.csv beside this file.

Compared columns are the count columns and the outcome columns each script writes. Free-text notes are
compared too, in rows of their own so a notes difference is never mistaken for a count one, after masking
identifiers only (NOTE_MASK): uuids, 32-hex trace ids, 16-hex span ids and IPv4 addresses are replaced by a
placeholder and nothing else is removed, so a change in the wording of a derivation (derive-layer.sh's
layer_reason) or of an error (client_errors) is a difference.

Fix round 1 (2026-09-13): the first version removed the whole layer_reason and client_errors fields, not
only their identifiers, which hid two differing notes cells (A.3 R2 go waypoint and A.3 R4 go).

  python3 experiments/runs/2026-09-12-current-versions/compare.py
  (this copy: python3 experiments/runs/2026-09-20-experiment-a-agentgateway-only/compare.py)
"""

import collections
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.dirname(HERE)
BASE = "2026-09-12-current-versions"  # the committed side of every item (follow-ups 19 task 4b)

NOTE_MASK = [  # identifiers only, in this order so a longer id is never partly matched as a shorter one
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "<uuid>"),
    (re.compile(r"\b[0-9a-f]{32}\b"), "<trace-id>"),
    (re.compile(r"\b[0-9a-f]{16}\b"), "<span-id>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
]

B_COUNTS = ["deliveries_worker", "deliveries_orchestrator", "dispatches_worker", "invocations", "invocations_by_caller", "client_result"]
A1_COUNTS = ["deliveries", "executes", "distinct_message_ids", "tasks_created", "invocations", "resp1", "resp2", "same_task"]
A2_COUNTS = ["arrivals", "messageId_reused", "id_reused", "body_identical", "injection_fired", "executes", "invocations", "client_result"]
A3_COUNTS = ["deliveries", "dispatched", "distinct_messageIds", "tasks", "invocations", "client_result", "second_delivery_layer"]
A3_TRACE = ["trace_spans", "spans_by_service"]

ITEMS = []  # (item, committed dir, current dir, group columns, count columns, trace columns, compare notes)
for step, committed in (("step1", BASE + "/baseline-step1"), ("step2", BASE + "/baseline-step2"), ("step2b", BASE + "/baseline-step2b")):
    ITEMS.append(("Gate 1 baseline " + step, committed, "baseline-" + step, ["run"], B_COUNTS, [], True))
ITEMS.append(("Gate 1 runs 5-6 (openai)", BASE + "/openai-runs-5-6", "openai-runs-5-6", ["run"], B_COUNTS, [], True))
ITEMS.append(("Gate 1 wire version", BASE + "/wire-version", "wire-version", ["client_sdk", "captured_at"], ["deliveries", "a2a_version", "method", "status", "dispatches", "invocations", "client_result"], [], False))
ITEMS.append(("Gate 2 clean check", BASE + "/clean-check", "clean-check", ["receiver"], ["deliveries", "received", "executes", "tasks_created", "invocations", "client_result"], [], False))
for m in ("m1", "m2", "m3"):
    for r in ("go", "py"):
        ITEMS.append(("A.1 %s %s" % (m.upper(), r), BASE + "/a1-%s-%s" % (m, r), "a1-%s-%s" % (m, r), ["mode", "receiver", "path"], A1_COUNTS, [], True))
for sub in ("go-http", "go-http-503", "go-sdk", "py-http-retries", "py-http-resend", "py-http-resend503", "py-sdk"):
    ITEMS.append(("A.2 " + sub, BASE + "/a2-" + sub, "a2-" + sub, ["client", "layer"], A2_COUNTS, [], True))
A3 = [("baseline-go", "2026-09-09"), ("baseline-py", "2026-09-09"), ("r1-go-http", "2026-09-09"), ("r1-go-sdk", "2026-09-09"),
      ("r1-py-http", "2026-09-09"), ("r1-py-sdk", "2026-09-09"), ("r2-go-waypoint", "2026-09-09"), ("r2-go-ingress", "2026-09-09"),
      ("r2-py-ingress", "2026-09-09"), ("r2-py-ingress-incluster", "2026-09-09"), ("r3-go", "2026-09-09"), ("r3-py", "2026-09-10"),
      ("r4-go", "2026-09-10"), ("r4-py", "2026-09-10"), ("egress-go", "2026-09-10"), ("egress-py", "2026-09-10")]
for name, date in A3:
    ITEMS.append(("A.3 " + name, BASE + "/a3-" + name, "a3-" + name, ["receiver", "run", "sub"], A3_COUNTS, A3_TRACE, True))
# Fix round 1 (M5): the three curl-bumped scripts the first pass had not run.
ITEMS.append(("Gate 1 three ledgers", BASE + "/three-ledgers", "three-ledgers", [], ["deliveries_ingress_jsonrpc", "ingress_arrivals_for_work_item", "dispatches", "distinct_message_ids", "tasks_created", "task_final_state", "invocations", "a2a_version_seen", "client_result_kind"], [], False))
ITEMS.append(("Gate 1 mockllm deterministic", BASE + "/mockllm-deterministic", "mockllm-deterministic", [], ["identical_hashes", "count_injection_fired_at", "lwi_injection_hits_det003", "lwi_injection_hits_det004"], [], False, ["latency_min_ms", "latency_max_ms"]))
ITEMS.append(("Gate 3 gateway retry mechanics", BASE + "/gateway-retry-mechanics", "gateway-retry-mechanics", ["route"], ["arrivals_at_worker", "invocations_at_mock", "retried", "identity_source", "messageId_same", "rpc_id_same", "taskId_same", "caller_same", "body_sha256_same", "body_len_same", "executes", "client_result"], ["trace_spans"], True))
ITEMS.append(("Gate 3 trace per work item", BASE + "/trace", "trace", ["receiver"], ["trace_ids", "spans", "spans_by_service", "hops_without_span", "lab_work_item_on_all"], [], False))


def read(path):
    with open(path) as f:
        lines = [l for l in f if not l.startswith("#")]
    return list(csv.DictReader(lines))


def dist(values):
    c = collections.Counter(values)
    return " | ".join("%s x%d" % (v if v != "" else "(empty)", n) for v, n in sorted(c.items()))


def norm_note(s):
    s = s or ""
    for rx, rep in NOTE_MASK:
        s = rx.sub(rep, s)
    return s


def main():
    out = []
    missing = []
    for entry in ITEMS:
        item, cdir, ndir, groups, counts, trace, notes = entry[:7]
        timing = entry[7] if len(entry) > 7 else []  # measured durations, compared and reported as their own kind
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
            out.append((item, gname, "rows", str(len(cg)), str(len(ng)), "same" if len(cg) == len(ng) else "differs", "count"))
            for col in counts:
                a, b = dist(r.get(col, "") for r in cg), dist(r.get(col, "") for r in ng)
                out.append((item, gname, col, a, b, "same" if a == b else "differs", "count"))
            for col in trace:
                a, b = dist(r.get(col, "") for r in cg), dist(r.get(col, "") for r in ng)
                out.append((item, gname, col, a, b, "same" if a == b else "differs", "trace"))
            for col in timing:
                a, b = dist(r.get(col, "") for r in cg), dist(r.get(col, "") for r in ng)
                out.append((item, gname, col, a, b, "same" if a == b else "differs", "timing"))
            if notes:
                a, b = dist(norm_note(r.get("notes", "")) for r in cg), dist(norm_note(r.get("notes", "")) for r in ng)
                out.append((item, gname, "notes (identifiers masked)", a, b, "same" if a == b else "differs", "notes"))
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
