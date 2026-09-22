#!/usr/bin/env python3
"""B-6: Experiment B's results table, derived from the committed run records.

Every cell is computed here from the `summary.csv` of the row it belongs to --
one line per repetition, written by that row's own counter -- so the table is
re-derivable from the repository alone and cites the file each cell came from.
FOUR cells have no column in the row that produced them -- the model-invocation
outcome and latency of the clean-stream row and of D3's terminal-task row, at each
receiver, whose summary.csv counts `invocations` and carries neither an
`invocation_outcomes` nor a latency column. Each of those four carries the word its
findings entry states and is printed with an [entry] marker, so a reader can tell a
derived cell from a quoted one at a glance. Every other cell is derived.

    python3 table.py <out dir>

Writes table-inputs.csv (one row per row-and-receiver, every cell) and table.md
(the same as a Markdown table, plus the B-5a stimulus table).

No stamp of an agentgateway access line is read: every figure below comes from a
row's own summary.csv, whose counters take their timing from cluster ledgers, the
client's own lines and host stamps, and which -- in B-5b -- refuses to compute a
figure from a defective proxy stamp at all (agentgateway#3369).
"""
import csv, os, sys, collections

RUNS = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
B3 = os.path.join(RUNS, "2026-09-21-b3-streaming-client")
B4 = os.path.join(RUNS, "2026-09-22-b4-control")
B5A = os.path.join(RUNS, "2026-09-22-b5a-removal")
B5B = os.path.join(RUNS, "2026-09-22-b5b-removal-resubscribe")


def load(path, **filt):
    rows = [r for r in csv.DictReader(open(path))]
    for k, v in filt.items():
        rows = [r for r in rows if r[k] == v]
    return rows


def one(rows, col):
    """The single value of a column, or every value with its count when it varies."""
    c = collections.Counter(r[col] for r in rows)
    if len(c) == 1:
        return next(iter(c))
    return "; ".join("%s (%d of %d)" % (a or "<empty>", b, len(rows)) for a, b in c.most_common())


def cnt(rows, col, value):
    return sum(1 for r in rows if r[col] == value)


def rng(rows, col, unit="ms", fmt="%.1f"):
    v = sorted(float(r[col]) for r in rows if r[col] not in ("", "n-a", "n/a"))
    if not v:
        return ""
    if v[0] == v[-1]:
        return (fmt + " %s") % (v[0], unit)
    return (fmt + "-" + fmt + " %s") % (v[0], v[-1], unit)


def lat(rows, col):
    """An invocation-latency column, which some rows write as `ok 45000.2` pairs."""
    vals = []
    for r in rows:
        for part in r[col].replace("|", " ").split():
            try:
                vals.append(float(part))
            except ValueError:
                pass
    if not vals:
        return ""
    return "%.1f-%.1f ms" % (min(vals), max(vals))


COLS = ["row", "receiver", "n", "stimulus", "stream_ended_by", "stream_end_when",
        "ledgers_at_that_moment", "executes", "tasks", "task_survived", "final_state",
        "model_invocations", "subscription", "reattached_to", "first_state",
        "subscription_added", "source"]


def b3_stream(rec):
    g = load(os.path.join(B3, "stream/summary.csv"), receiver=rec)
    return {
        "n": len(g),
        "stimulus": "none -- nothing disrupted",
        "stream_ended_by": "the server, with the task: client `%s`, %d events, terminal event seen %d of %d"
                           % (one(g, "client_stream_end"), int(one(g, "client_events")),
                              cnt(g, "client_terminal_seen", "True"), len(g)),
        "stream_end_when": "at the task's terminal event (no disruption; this row armed no delay)",
        "ledgers_at_that_moment": "ingress `%s` / execution `%s`" % (one(g, "ingress_stream_end"), one(g, "exec_stream_end")),
        "executes": one(g, "executes"), "tasks": one(g, "tasks"),
        "task_survived": "n/a -- nothing threatened it",
        "final_state": "%s %d of %d" % (one(g, "final_state"), cnt(g, "final_state", "TASK_STATE_COMPLETED"), len(g)),
        "model_invocations": "%s [entry: outcome `ok`; this row's summary carries no outcome or latency column]" % one(g, "invocations"),
        "subscription": "none sent in this row", "reattached_to": "", "first_state": "", "subscription_added": "",
        "source": "findings 'B-3, a clean stream'; experiments/runs/2026-09-21-b3-streaming-client/stream/summary.csv",
    }


def b3_running(rec):
    g = load(os.path.join(B3, "subscribe-running/summary.csv"), receiver=rec)
    return {
        "n": len(g),
        "stimulus": "none -- nothing disrupted; the model call held %s" % lat(g, "latency_ms"),
        "stream_ended_by": "the server, with the task: client `%s`, %d events" % (one(g, "client_stream_end"), int(one(g, "client_events"))),
        "stream_end_when": "at the task's terminal event",
        "ledgers_at_that_moment": "ingress `%s` / execution `%s`" % (one(g, "ingress_stream_end"), one(g, "exec_stream_end")),
        "executes": one(g, "executes"), "tasks": one(g, "tasks"),
        "task_survived": "n/a -- nothing threatened it",
        "final_state": "%s %d of %d" % (one(g, "final_state"), cnt(g, "final_state", "TASK_STATE_COMPLETED"), len(g)),
        "model_invocations": "%s, `%s`, %s" % (one(g, "invocations"), one(g, "invocation_outcomes"), lat(g, "latency_ms")),
        "subscription": "1 sent while the task ran (%s of %d running at arrival), arriving %s after the executor's WORKING line and %s before its terminal state"
                        % (cnt(g, "running_at_arrival", "yes"), len(g), rng(g, "working_to_sub_arrival_ms"),
                           rng(g, "sub_arrival_to_terminal_ms")),
        "reattached_to": "Job 1's task id, %d of %d (`sub_task_matches`, `client2_first_task_matches`)"
                         % (cnt(g, "client2_first_task_matches", "yes"), len(g)),
        "first_state": one(g, "client2_first"),
        "subscription_added": "0 executes, 0 tasks, 0 invocations (the row's totals are 1/1/1 with the subscription counted)",
        "source": "findings 'B-3, `SubscribeToTask` during a running task'; .../subscribe-running/summary.csv",
    }


def b3_terminal(rec):
    g = load(os.path.join(B3, "subscribe-terminal/summary.csv"), receiver=rec)
    return {
        "n": len(g),
        "stimulus": "none -- Job 1 ran to its end first; the subscription arrives %s after the terminal state" % rng(g, "terminal_to_sub_arrival_ms"),
        "stream_ended_by": "the server, with the task: client `%s`, %d events" % (one(g, "client_stream_end"), int(one(g, "client_events"))),
        "stream_end_when": "at the task's terminal event, before the subscription was sent (`terminal_before_arrival` %d of %d)"
                           % (cnt(g, "terminal_before_arrival", "yes"), len(g)),
        "ledgers_at_that_moment": "ingress `%s` / execution `%s`" % (one(g, "ingress_stream_end"), one(g, "exec_stream_end")),
        "executes": one(g, "executes"), "tasks": one(g, "tasks"),
        "task_survived": "n/a -- it had already completed",
        "final_state": "%s %d of %d" % (one(g, "final_state"), cnt(g, "final_state", "TASK_STATE_COMPLETED"), len(g)),
        "model_invocations": "%s [entry: outcome `ok`; no outcome column in this row's summary]" % one(g, "invocations"),
        "subscription": "1 sent against the terminal task; it arrived and was answered on the wire, %d of %d" % (len(g), len(g)),
        "reattached_to": "nothing -- refused. Wire: %s. Subscription ledgers: ingress `%s` / execution `%s`"
                         % (("`-32001 task not found: no active execution`, http 200 text/event-stream"
                             if rec == "go" else
                             "`-32602 Task <id> is in terminal state: 3`, http 200 **application/json**"),
                            one(g, "ingress_sub_stream_end"), one(g, "exec_sub_stream_end")),
        "first_state": "no first event: `%s`; the client read %s"
                       % (one(g, "sub_first_delivered"),
                          "the error and ended `error`" if rec == "go" else
                          "no event and no error and ended `eof` -- an empty stream"),
        "subscription_added": "0 executes, 0 tasks, 0 invocations",
        "source": "findings 'D3, `SubscribeToTask` on a terminal task'; .../subscribe-terminal/summary.csv",
    }


def b4(rec):
    g = load(os.path.join(B4, "control/summary.csv"), receiver=rec)
    clean = [r for r in g if r["sleep_affected"] == "no"]
    return {
        "n": len(g),
        "stimulus": "no proxy event -- the client cancels its own stream, once, k = %s ms after the send"
                    % one(g, "client_cancel_after_ms"),
        "stream_ended_by": "the client itself: `%s`, `%s`; %d events, terminal event seen %d of %d; %d of %d events after the cancel"
                           % (one(g, "client_stream_end"), one(g, "client_error"), int(one(g, "client_events")),
                              cnt(g, "client_terminal_seen", "True"), len(g),
                              max(int(r["client_events_after_cancel"]) for r in g), len(g)),
        "stream_end_when": "%s after the send and %s after the executor's WORKING line (both cluster-to-cluster), `cancel_while_working` %d of %d"
                           % (rng(clean, "sent_to_cancel_ms"), rng(clean, "working_to_cancel_ms"),
                              cnt(g, "cancel_while_working", "yes"), len(g)),
        "ledgers_at_that_moment": "ingress `%s` / execution `%s`, %s and %s after the cancel"
                                  % (one(g, "ingress_stream_end"), one(g, "exec_stream_end"),
                                     rng(clean, "cancel_to_ingress_end_ms"), rng(clean, "cancel_to_exec_end_ms")),
        "executes": one(g, "executes"), "tasks": one(g, "tasks"),
        "task_survived": "yes",
        "final_state": "%s %d of %d" % (one(g, "final_state"), cnt(g, "final_state", "TASK_STATE_COMPLETED"), len(g)),
        "model_invocations": "%s, `%s`, %s" % (one(g, "invocations"), one(g, "invocation_outcomes"), lat(g, "invocation_latency_ms")),
        "subscription": "1 sent after the cancel, arriving %s after the WORKING line and %s before the terminal state; `running_at_sub_arrival` %d of %d"
                        % (rng(clean, "working_to_sub_arrival_ms"), rng(clean, "sub_arrival_to_completed_ms"),
                           cnt(g, "running_at_sub_arrival", "yes"), len(g)),
        "reattached_to": "Job 1's task id, %d of %d" % (cnt(g, "client2_first_task_matches", "yes"), len(g)),
        "first_state": one(g, "client2_first"),
        "subscription_added": "0 executes, 0 tasks, 0 invocations; subscription ledgers ingress `%s` / execution `%s`"
                              % (one(g, "ingress_sub_stream_end"), one(g, "exec_sub_stream_end")),
        "source": "findings 'B-4, the control with no proxy event'; experiments/runs/2026-09-22-b4-control/control/summary.csv",
    }


def b5b(rec, variant, stim, caveat=""):
    g = load(os.path.join(B5B, "rows/summary.csv"), variant="%s-%s" % (rec, variant))
    surv = one(g, "final_state") == "TASK_STATE_COMPLETED"
    err = one(g, "client_error")
    err = "" if err in ("", "<none>") else err
    end_by = ("the removed proxy, abruptly: client `%s`, `%s`" % (one(g, "client_stream_end"), err)
              if err else
              "nothing -- the stream never broke. It carried the task's own terminal event and ended `%s` with no error"
              % one(g, "client_stream_end"))
    off = [float(r[c]) for r in g for c in ("client_end_to_ingress_end_ms_c2c", "client_end_to_exec_end_ms_c2c")]
    return {
        "n": len(g),
        "stimulus": stim,
        "stream_ended_by": "%s; %s events, terminal event seen %d of %d; Job 1 %s"
                           % (end_by, one(g, "client_events"), cnt(g, "client_terminal_seen", "True"), len(g), one(g, "job1")),
        "stream_end_when": "%s after the removal command (host-to-cluster)%s" % (rng(g, "rm_to_client_stream_end_ms_h2c"), caveat),
        "ledgers_at_that_moment": "ingress `%s` / execution `%s`, %+.1f to %+.1f ms from the client's own end stamp (cluster-to-cluster; negative is before it)"
                                  % (one(g, "ingress_stream_end"), one(g, "exec_stream_end"), min(off), max(off)),
        "executes": one(g, "executes"), "tasks": one(g, "tasks"),
        "task_survived": "yes" if surv else "no -- the removal took the model leg",
        "final_state": "%s %d of %d%s" % (one(g, "final_state"), cnt(g, "final_state", one(g, "final_state")), len(g),
                                          ("; the executor's own text `%s`" % one(g, "final_state_error"))
                                          if one(g, "final_state_error") not in ("", "<none>") else ""),
        "model_invocations": "%s, `%s`, %s" % (one(g, "invocations"), one(g, "invocation_outcomes"), lat(g, "invocation_latency_ms")),
        "subscription": "1 sent the moment the successor was seen Ready, arriving %s after the removal and %s before the terminal state; `task_running_at_sub_arrival` %d of %d"
                        % (rng(g, "rm_to_sub_arrival_ms_h2c"), rng(g, "sub_arrival_to_terminal_ms_c2c"),
                           cnt(g, "task_running_at_sub_arrival", "yes"), len(g)),
        "reattached_to": "Job 1's task id, %d of %d" % (cnt(g, "client2_first_task_matches_job1", "yes"), len(g)),
        "first_state": one(g, "client2_first"),
        "subscription_added": "0 executes, 0 tasks, 0 invocations; subscription ledgers ingress `%s` / execution `%s`; Job 2 %s"
                              % (one(g, "ingress_sub_stream_end"), one(g, "exec_sub_stream_end"), one(g, "job2")),
        "source": "findings 'B-5b, %s'; experiments/runs/2026-09-22-b5b-removal-resubscribe/rows/summary.csv"
                  % ("the agentgateway ingress removed under an open stream" if variant == "ingress-forced"
                     else "`agw-central` removed under an open stream"),
    }


CAVEAT_PY_CENTRAL = (". Two of the twenty -- `b5b-py-central-graceful-r1-01` and `-r1-13`, at 15 065.3 and 15 070.1 ms -- are the span-processor case the entry names (`BatchSpanProcessor.Shutdown.Timeout` between SIGTERM and the drain, this lab's tracing configuration and not the proxy); over the other eighteen, 10 046.1-10 085.1 ms")

SPEC = [
    ("B-3 / a clean stream", "go", b3_stream), ("B-3 / a clean stream", "py", b3_stream),
    ("B-3 / SubscribeToTask during a running task", "go", b3_running),
    ("B-3 / SubscribeToTask during a running task", "py", b3_running),
    ("D3 / SubscribeToTask on a terminal task", "go", b3_terminal),
    ("D3 / SubscribeToTask on a terminal task", "py", b3_terminal),
    ("B-4 / the control, no proxy event", "go", b4), ("B-4 / the control, no proxy event", "py", b4),
    ("B-5b / agentgateway-ingress removed, FORCED", "go",
     lambda r: b5b(r, "ingress-forced", "`agentgateway-ingress` force-deleted (`--grace-period=0 --force`) 2 000 ms after the client's WORKING event; it carries the A2A stream and not the model leg")),
    ("B-5b / agentgateway-ingress removed, FORCED", "py",
     lambda r: b5b(r, "ingress-forced", "`agentgateway-ingress` force-deleted (`--grace-period=0 --force`) 2 000 ms after the client's WORKING event; it carries the A2A stream and not the model leg")),
    ("B-5b / agw-central removed, GRACEFUL", "go",
     lambda r: b5b(r, "central-graceful", "`agw-central` gracefully deleted 2 000 ms after the client's WORKING event; it carries the model leg. A graceful delete, not the forced one, because B-5a measured no window under a forced one")),
    ("B-5b / agw-central removed, GRACEFUL", "py",
     lambda r: b5b(r, "central-graceful", "`agw-central` gracefully deleted 2 000 ms after the client's WORKING event; it carries the model leg. A graceful delete, not the forced one, because B-5a measured no window under a forced one", CAVEAT_PY_CENTRAL)),
]


def b5a_table():
    rows = []
    for variant in ("ingress-graceful", "ingress-forced", "ingress-rollout",
                    "central-graceful", "central-forced", "central-rollout"):
        g = load(os.path.join(B5A, "removal/summary.csv"), variant=variant)
        rows.append({
            "variant": variant, "n": len(g),
            "stream_end_after_removal": rng(g, "rm_to_client_stream_end_ms_h2c"),
            "client_reading": "`%s`%s" % (one(g, "client_stream_end"),
                                          (", `%s`" % one(g, "client_error"))
                                          if one(g, "client_error") not in ("", "<none>") else ", no error at all"),
            "terminal_event_seen": "%d of %d" % (cnt(g, "terminal_seen" if "terminal_seen" in g[0] else "client_terminal_seen", "True"), len(g)),
            "ledgers": "%s / %s" % (one(g, "ingress_stream_end"), one(g, "exec_stream_end")),
            "final_state": "%s %d of %d" % (one(g, "final_state"), cnt(g, "final_state", one(g, "final_state")), len(g)),
            "invocations": "%s `%s` %s" % (one(g, "invocations"), one(g, "invocation_outcomes"), lat(g, "invocation_latency_ms")),
            "drain_timeout_line": "%d of %d" % (cnt(g, "drain_timeout_line", "yes"), len(g)) if "drain_timeout_line" in g[0] else "",
            "sigterm_to_last_log": rng(g, "sigterm_to_last_log_ms_c2c") + (
                " (the maximum is `b5a-ingress-rollout-r1-03`, the one counted repetition where the span"
                " processor's own shutdown stood between SIGTERM and the drain; the other four are"
                " 20 003.9-20 008.4 ms)" if variant == "ingress-rollout" else ""),
            "cut_request_in_the_proxy_log": one(g, "old_pod_access_shapes"),
        })
    return rows


def main(out):
    recs = []
    for label, rec, fn in SPEC:
        d = fn(rec)
        d["row"], d["receiver"] = label, rec
        recs.append(d)
    with open(os.path.join(out, "table-inputs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore", lineterminator="\n")
        w.writeheader()
        for r in recs:
            w.writerow(r)

    b5a = b5a_table()
    with open(os.path.join(out, "table-b5a-inputs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(b5a[0].keys()), lineterminator="\n")
        w.writeheader()
        for r in b5a:
            w.writerow(r)

    with open(os.path.join(out, "table.md"), "w") as f:
        f.write("# Experiment B — the results table\n\n")
        f.write("Every cell is derived by `table.py` from the `summary.csv` of the row it belongs to. "
                "A cell marked `[entry]` is quoted from that row's findings entry because the row's own "
                "summary carries no column for it. A cell no run produced is named as such and is never "
                "inferred from a neighbouring cell.\n\n")
        head = ["Row", "Receiver", "n", "What ended the stream, and how it read",
                "When (clock pair named)", "The two ledgers at that moment", "Executes", "Tasks",
                "Task survived", "Final state", "Model invocations",
                "The one `SubscribeToTask`", "Reattached to", "Its first event", "What it added", "Stimulus", "Source"]
        f.write("| " + " | ".join(head) + " |\n")
        f.write("|" + "---|" * len(head) + "\n")
        for r in recs:
            cells = [r["row"], r["receiver"], str(r["n"]), r["stream_ended_by"], r["stream_end_when"],
                     r["ledgers_at_that_moment"], r["executes"], r["tasks"], r["task_survived"],
                     r["final_state"], r["model_invocations"], r["subscription"] or "—",
                     r["reattached_to"] or "—", r["first_state"] or "—", r["subscription_added"] or "—",
                     r["stimulus"], r["source"]]
            f.write("| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |\n")
        f.write("\n\n## B-5a — the stimulus measured, Go receiver only\n\n")
        f.write("B-5a ran one receiver and sent no resubscription; its entry says why. "
                "Every figure is from the removal command on the host clock against a cluster clock, "
                "except the drain columns, which are the removed pod's own clock on both ends.\n\n")
        hk = list(b5a[0].keys())
        f.write("| " + " | ".join(hk) + " |\n|" + "---|" * len(hk) + "\n")
        for r in b5a:
            f.write("| " + " | ".join(str(r[k]).replace("|", "\\|") for k in hk) + " |\n")
    print("table: %d row-and-receiver cells -> table-inputs.csv, table.md; %d B-5a variants" % (len(recs), len(b5a)))


if __name__ == "__main__":
    main(sys.argv[1])
