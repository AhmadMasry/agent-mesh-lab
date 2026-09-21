"""Experiment B, step B-3: the counts of one row, from the ledgers rows.sh collected, one CSV line per repetition.

    python3 counts.py <row dir> <row> <N_ms>      writes <row dir>/summary.csv and prints it with a tally

<row> is model-call | stream | subscribe-running | subscribe-terminal. Every repetition directory under
<row dir>/<go|py>/<work item>/ holds ingress.jsonl, execution.jsonl, invocation.jsonl and client.jsonl (make ledgers)
and, for the two subscribe rows, client-sub.jsonl (the second Job's lines).

The standing B rules, as this program keeps them:
  - every stamp is PARSED to integer nanoseconds (the Go ledger's RFC3339Nano drops trailing zeros, the Python
    ledger writes microseconds), never compared as text;
  - ingress and execution lines are joined on identity -- a send by its messageId, a subscription by its taskId,
    an ingress response line to its arrival by (method, JSON-RPC id, ts_arrival) -- never on line order;
  - the final state is the executor's last `state` line for the task by parsed stamp, not the execution result
    line's state (which on a streamed dispatch is the FIRST Task's);
  - a `delivered` line is what the SDK handed to its stream writer, not what reached the client: it is reported
    beside the client's own first event, never instead of it.
Counts are scoped to the receiver under test's own lines (source worker for go, orchestrator for py); model
invocations are counted for the work item as a whole. Reads files only.
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROWDIR, ROW, N_MS = sys.argv[1], sys.argv[2], int(sys.argv[3])
SOURCE = {"go": "worker", "py": "orchestrator"}
TERMINAL = {"TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"}
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$")


def ns(s):
    """RFC 3339 with any number of fraction digits -> integer nanoseconds since the epoch."""
    m = STAMP.match(s or "")
    if not m:
        raise ValueError(f"not an RFC 3339 stamp: {s!r}")
    base = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    if m.group(3) != "Z":
        sign = 1 if m.group(3)[0] == "+" else -1
        hh, mm = int(m.group(3)[1:3]), int(m.group(3)[4:6])
        base -= sign * timedelta(hours=hh, minutes=mm)
    frac = (m.group(2) or "").ljust(9, "0")[:9]
    return int(base.timestamp()) * 1_000_000_000 + int(frac)


def ms(a, b):
    return f"{(b - a) / 1e6:.1f}"


def lines(path):
    if not os.path.exists(path):
        return []
    out = []
    for raw in open(path):
        raw = raw.strip()
        if raw:
            out.append(json.loads(raw))
    return out


def jobs(d):
    p = os.path.join(d, "jobs.txt")
    return open(p).read().split("\n") if os.path.exists(p) else []


def job_word(d, name):
    for j in jobs(d):
        if j.startswith(name + " "):
            succ = re.search(r"succeeded=(\S*)", j).group(1)
            fail = re.search(r"failed=(\S*)", j).group(1)
            exit_ = re.search(r"pod-exit=(\S*)", j).group(1)
            return f"{'Complete' if succ == '1' else 'Failed' if fail == '1' else 'none'}/exit{exit_}"
    return "absent"


ACCESS = re.compile(r"route=(\S+).*?http\.method=(\S+).*?http\.status=(\S+).*?duration=(\S+)")


def access(d, name, proxy):
    """The proxy's access-log lines collected for the repetition: (proxy, route, method, status, duration)."""
    out = []
    p = os.path.join(d, name)
    if os.path.exists(p):
        for raw in open(p):
            m = ACCESS.search(raw)
            if m:
                out.append((proxy,) + m.groups())
    return out


def rep(recv, lwi, d):
    src = SOURCE[recv]
    ing = [x for x in lines(os.path.join(d, "ingress.jsonl"))]
    exe = [x for x in lines(os.path.join(d, "execution.jsonl"))]
    inv = [x for x in lines(os.path.join(d, "invocation.jsonl")) if x.get("outcome") != "stale-closed"]
    cli = lines(os.path.join(d, "client.jsonl"))
    sub = lines(os.path.join(d, "client-sub.jsonl"))
    notes = []

    mine = [x for x in ing if x.get("source") == src]
    other = [x for x in ing if x.get("source") != src and x.get("phase") == "arrival"]
    if other:
        notes.append(f"arrivals_at_the_other_agent={len(other)}")
    arrivals = [x for x in mine if x.get("phase") == "arrival"]
    responses = [x for x in mine if x.get("phase") == "response"]

    def arrivals_of(method):
        return sorted((x for x in arrivals if x.get("method") == method), key=lambda x: ns(x["ts_arrival"]))

    def response_of(a):
        m = [r for r in responses if r.get("method") == a.get("method") and r.get("id") == a.get("id")
             and ns(r["ts_arrival"]) == ns(a["ts_arrival"])]
        return m[0] if len(m) == 1 else None

    ex = [x for x in exe if x.get("source") == src]
    executes = [x for x in ex if x.get("event") == "execute"]
    tasks = sorted({x["taskId"] for x in ex if x.get("event") == "state" and x.get("state") == "TASK_STATE_SUBMITTED"})
    task = tasks[0] if len(tasks) == 1 else ""
    if len(tasks) != 1:
        notes.append(f"tasks={len(tasks)}")
    states = sorted((x for x in ex if x.get("event") == "state" and x.get("taskId") == task), key=lambda x: ns(x["ts"]))
    final_state = states[-1]["state"] if states else "none"
    t_state = {}
    for s in states:
        t_state.setdefault(s["state"], ns(s["ts"]))

    def received_for(a):
        if a.get("method") == "SubscribeToTask":
            return [x for x in ex if x.get("event") == "received" and x.get("method") == "SubscribeToTask" and x.get("taskId") == a.get("taskId")]
        return [x for x in ex if x.get("event") == "received" and x.get("method") == a.get("method") and x.get("messageId") == a.get("messageId")]

    def result_for(a):
        if a.get("method") == "SubscribeToTask":
            return [x for x in ex if x.get("event") == "result" and x.get("method") == "SubscribeToTask" and x.get("taskId") == a.get("taskId")]
        return [x for x in ex if x.get("event") == "result" and x.get("method") == a.get("method") and x.get("messageId") == a.get("messageId")]

    inv_w = [x for x in inv if x.get("logical_work_item_id") == lwi]
    row = {"receiver": recv, "work_item": lwi}

    def common(send_method):
        send = arrivals_of(send_method)
        row["arrivals_" + send_method] = len(send)
        row["received_joined"] = sum(len(received_for(a)) for a in send)
        row["executes"] = len(executes)
        row["tasks"] = len(tasks)
        row["invocations"] = len(inv_w)
        row["final_state"] = final_state
        row["a2a_version"] = "|".join(sorted({a.get("a2a_version", "") for a in send})) or "none"
        others = sorted({x.get("method") for x in arrivals} - {send_method, "SubscribeToTask"})
        if others:
            notes.append("other_methods=" + "|".join(others))
        return send

    if ROW == "model-call":
        send = common("SendMessage")
        row["invocation_outcomes"] = "|".join(x.get("outcome", "") for x in inv_w) or "none"
        row["latency_ms"] = "|".join(f"{x.get('latency_ms', 0):.1f}" for x in inv_w) or "none"
        row["latency_minus_N_ms"] = "|".join(f"{x.get('latency_ms', 0) - N_MS:.1f}" for x in inv_w) or "none"
        row["invocation_task_matches"] = "yes" if inv_w and all(x.get("taskId") == task for x in inv_w) else "no"
        c = [x for x in cli if x.get("attempt") == 1]
        row["client_result"] = f"{c[-1].get('result_kind') or 'none'}/{c[-1].get('state') or 'none'}" if c else "none"
        row["client_error"] = (c[-1].get("error", "") if c else "").replace(",", " ")
        row["job"] = job_word(d, f"loadgen-{lwi}")
    else:
        send = common("SendStreamingMessage")
        a1 = send[0] if len(send) == 1 else None
        r1 = response_of(a1) if a1 else None
        row["ingress_stream_end"] = (r1 or {}).get("stream_end", "none")
        res1 = result_for(a1) if a1 else []
        row["exec_stream_end"] = res1[0].get("stream_end", "none") if len(res1) == 1 else f"lines={len(res1)}"
        row["exec_result_state"] = res1[0].get("state", "none") if len(res1) == 1 else "n-a"
        end1 = [x for x in cli if x.get("line") == "end"]
        e1 = end1[-1] if end1 else {}
        row["client_events"] = e1.get("events", "none")
        row["client_first"] = f"{e1.get('first_kind', 'none')}/{e1.get('first_state') or 'none'}"
        row["client_last_state"] = e1.get("last_state") or "none"
        row["client_terminal_seen"] = e1.get("terminal_seen", "none")
        row["client_stream_end"] = e1.get("stream_end", "none")
        row["client_task_matches"] = "yes" if e1.get("taskId") == task and task else "no"
        row["card_streaming"] = e1.get("card_streaming", "none")
        row["job1"] = job_word(d, f"loadgen-{lwi}")
        if ROW in ("subscribe-running", "subscribe-terminal"):
            subs = arrivals_of("SubscribeToTask")
            row["arrivals_SubscribeToTask"] = len(subs)
            a2 = subs[-1] if subs else None
            row["sub_task_matches"] = "yes" if a2 and a2.get("taskId") == task and task else "no"
            row["received_sub_joined"] = len(received_for(a2)) if a2 else 0
            r2 = response_of(a2) if a2 else None
            row["ingress_sub_status"] = (r2 or {}).get("status", "none")
            row["ingress_sub_stream_end"] = (r2 or {}).get("stream_end", "none")
            res2 = result_for(a2) if a2 else []
            row["exec_sub_stream_end"] = res2[0].get("stream_end", "none") if len(res2) == 1 else f"lines={len(res2)}"
            row["exec_sub_error"] = (res2[0].get("error", "") if len(res2) == 1 else "").replace(",", " ")
            dl = sorted((x for x in ex if x.get("event") == "delivered" and x.get("method") == "SubscribeToTask" and x.get("taskId") == task),
                        key=lambda x: ns(x["ts"]))
            row["sub_first_delivered"] = f"{dl[0].get('result_kind')}/{dl[0].get('state') or 'none'}" if dl else "none"
            end2 = [x for x in sub if x.get("line") == "end"]
            e2 = end2[-1] if end2 else {}
            row["client2_first"] = f"{e2.get('first_kind') or 'none'}/{e2.get('first_state') or 'none'}"
            row["client2_first_task_matches"] = "yes" if e2.get("first_task_id") == task and task else "no"
            row["client2_events"] = e2.get("events", "none")
            row["client2_terminal_seen"] = e2.get("terminal_seen", "none")
            row["client2_stream_end"] = e2.get("stream_end", "none")
            row["client2_http"] = f"{e2.get('http_status', 'none')} {e2.get('content_type', '')}".strip()
            row["client2_wire_error"] = f"{e2.get('wire_error_code', 'none')}: {e2.get('wire_error_message', '')}".replace(",", " ")
            row["client2_sdk_error"] = (e2.get("error") or "").replace(",", " ")
            row["client2_posts"] = e2.get("posts", "none")
            row["job2"] = job_word(d, f"loadgen-{lwi}-s")
            t_arr = ns(a2["ts_arrival"]) if a2 else None
            t_work = t_state.get("TASK_STATE_WORKING")
            t_term = min((v for k, v in t_state.items() if k in TERMINAL), default=None)
            if ROW == "subscribe-running":
                row["invocation_outcomes"] = "|".join(x.get("outcome", "") for x in inv_w) or "none"
                row["latency_ms"] = "|".join(f"{x.get('latency_ms', 0):.1f}" for x in inv_w) or "none"
                row["working_to_sub_arrival_ms"] = ms(t_work, t_arr) if t_work and t_arr else "n-a"
                row["sub_arrival_to_terminal_ms"] = ms(t_arr, t_term) if t_arr and t_term else "n-a"
                row["running_at_arrival"] = ("yes" if t_work <= t_arr < t_term else "no") if t_work and t_arr and t_term else "n-a"
            else:
                row["terminal_to_sub_arrival_ms"] = ms(t_term, t_arr) if t_arr and t_term else "n-a"
                row["terminal_before_arrival"] = ("yes" if t_term < t_arr else "no") if t_arr and t_term else "n-a"
                row["prior_resubscriptions"] = sum(1 for x in subs if x.get("taskId") == task and ns(x["ts_arrival"]) < t_arr) if a2 else "n-a"
            extra = sorted({x.get("method") for x in arrivals} - {"SendStreamingMessage", "SubscribeToTask"})
            if extra:
                notes.append("extra_methods=" + "|".join(extra))
    acc = access(d, "agw-central-access.txt", "agw-central") + access(d, "ingress-access.txt", "ingress")
    model = [x for x in acc if x[1] == "agentgateway-waypoint/model-via-agw"]
    row["model_route"] = f"n={len(model)} " + (" ".join(f"{x[3]}/{x[4]}" for x in model) or "none")
    posts = [x for x in acc if x[2] == "POST" and x[1] != "agentgateway-waypoint/model-via-agw"]
    row["a2a_posts_at_proxies"] = " ".join(f"{x[0]}:{x[1]}:{x[3]}/{x[4]}" for x in posts) or "none"
    row["notes"] = ";".join(notes)
    return row


reps = []
for recv in ("go", "py"):
    base = os.path.join(ROWDIR, recv)
    if not os.path.isdir(base):
        continue
    for lwi in sorted(os.listdir(base)):
        d = os.path.join(base, lwi)
        if os.path.isdir(d):
            reps.append(rep(recv, lwi, d))
if not reps:
    sys.exit(f"no repetitions under {ROWDIR}")
cols = list(reps[0].keys())
with open(os.path.join(ROWDIR, "summary.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
    w.writeheader()
    for r in reps:
        w.writerow(r)
print(open(os.path.join(ROWDIR, "summary.csv")).read(), end="")
print("# tally, per receiver: column=value xN, for every column but work_item and the per-repetition figures")
skip = {"work_item", "model_route", "a2a_posts_at_proxies", "latency_ms", "latency_minus_N_ms", "working_to_sub_arrival_ms", "sub_arrival_to_terminal_ms",
        "terminal_to_sub_arrival_ms"}
for recv in ("go", "py"):
    rs = [r for r in reps if r["receiver"] == recv]
    if not rs:
        continue
    print(f"## {recv}: {len(rs)} repetitions")
    for c in cols:
        if c in skip or c == "receiver":
            continue
        vals = {}
        for r in rs:
            vals[str(r[c])] = vals.get(str(r[c]), 0) + 1
        print(f"  {c}: " + "; ".join(f"{k or '<empty>'} x{v}" for k, v in sorted(vals.items())))
    for c in ("latency_ms", "latency_minus_N_ms", "working_to_sub_arrival_ms", "sub_arrival_to_terminal_ms", "terminal_to_sub_arrival_ms"):
        if c in cols:
            xs = [float(v) for r in rs for v in str(r[c]).split("|") if re.match(r"^-?\d", v)]
            if xs:
                print(f"  {c}: min {min(xs):.1f} max {max(xs):.1f} mean {sum(xs) / len(xs):.1f} over {len(xs)}")
