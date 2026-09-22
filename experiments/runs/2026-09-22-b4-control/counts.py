"""Experiment B, step B-4: the counts of the control row, from the ledgers rows.sh collected, one CSV line per repetition.

    python3 counts.py <row dir> <N_ms> <K_ms> [<sleep events csv>]   writes <row dir>/summary.csv and prints it
                                                                    with a tally over the clean repetitions and
                                                                    another over all of them

Every repetition directory under <row dir>/<go|py>/<work item>/ holds ingress.jsonl, execution.jsonl, invocation.jsonl
and client.jsonl (make ledgers), client-sub.jsonl (Job 2's lines), steps.txt (the driver's stamped steps), jobs.txt,
and both proxies' access-log lines (agw-central-access.txt, ingress-access.txt). <row dir>/control.txt names the proxy
pods and their IPs, which is how the sender of every arrival is named.

Adapted from experiments/runs/2026-09-21-b3-streaming-client/counts.py (its subscribe-running row), changed in: the
cancel columns of Job 1's end line; the path columns (which proxy sent each arrival, by the receiver's ingress ledger's
remote address and by each proxy's access log); the timing columns, all from parsed stamps; and the invocation count,
which here counts EVERY invocation line, stale-closed included, and reports each line's outcome (the B-3 review's M-5).

The standing B rules, as this program keeps them:
  - every stamp is PARSED to integer nanoseconds (the Go ledger's RFC3339Nano drops trailing zeros, the Python
    ledger writes microseconds), never compared as text;
  - ingress and execution lines are joined on identity -- a send by its messageId, a subscription by its taskId,
    an ingress response line to its arrival by (method, JSON-RPC id, ts_arrival) -- never on line order;
  - the final state is the executor's last `state` line for the task by parsed stamp, not the execution result
    line's state (which on a streamed dispatch is the FIRST Task's);
  - a `delivered` line is what the SDK handed to its stream writer, not what reached the client: it is reported
    beside the client's own first event, never instead of it;
  - every invocation line is counted and reported, stale-closed included; none is filtered;
  - a repetition is marked sleep_affected when a host power event of the four kinds (sleep-events.csv, kinds and
    stamps only) falls inside that repetition's own window, from its first stamped step to its last. A
    sleep-affected repetition's wall-clock intervals are not the intervals a clean one measures, so every count is
    reported twice: over the clean repetitions, and over all of them.
The stamps compared across ledgers come from pods on the same kind node pair of one host, so one clock; the table
says which ledger each stamp is from. Counts are scoped to the receiver under test's own lines (source worker for go,
orchestrator for py); invocations are counted for the work item as a whole. Reads files only.
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROWDIR, N_MS, K_MS = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
SLEEPCSV = sys.argv[4] if len(sys.argv) > 4 else ""
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
    return f"{(b - a) / 1e6:.1f}" if a is not None and b is not None else "n-a"


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
            pods = re.search(r"pods=(\S*)", j)
            return f"{'Complete' if succ == '1' else 'Failed' if fail == '1' else 'none'}/exit{exit_}/pods{pods.group(1) if pods else '?'}"
    return "absent"


STEP = re.compile(r"^(\S+) (.*)$")


def steps(d):
    """The driver's stamped steps: [(ns, text)]."""
    p = os.path.join(d, "steps.txt")
    out = []
    if os.path.exists(p):
        for raw in open(p):
            m = STEP.match(raw.rstrip("\n"))
            if m:
                try:
                    out.append((ns(m.group(1)), m.group(2)))
                except ValueError:
                    pass
    return out


def step_at(st, prefix):
    for t, text in st:
        if text.startswith(prefix):
            return t
    return None


ACCESS = re.compile(r"^(\S+)\s.*?route=(\S+) endpoint=(\S+) src\.addr=(\S+) .*?http\.method=(\S+) http\.host=(\S+) http\.path=(\S+) .*?http\.status=(\S+).*?duration=(\S+)")


def access(d, name, proxy):
    """The proxy's access-log lines collected for the repetition: dicts with proxy, ts, route, endpoint, src, method,
    host, path, status, duration."""
    out = []
    p = os.path.join(d, name)
    if os.path.exists(p):
        for raw in open(p):
            m = ACCESS.search(raw)
            if m:
                ts, route, endpoint, src, method, host, path, status, duration = m.groups()
                out.append({"proxy": proxy, "ts": ts, "route": route, "endpoint": endpoint, "src": src, "method": method,
                            "host": host, "path": path, "status": status, "duration": duration})
    return out


def proxy_ips(rowdir):
    """Pod IP -> proxy name, from the driver's 'proxy pods:' line in control.txt."""
    out = {}
    p = os.path.join(rowdir, "control.txt")
    if os.path.exists(p):
        for raw in open(p):
            if "proxy pods:" in raw:
                for ns_name, ip in re.findall(r"(\S+/\S+) ip=(\S+)", raw):
                    out[ip] = "agw-central" if "agw-central" in ns_name else "ingress" if "agentgateway-ingress" in ns_name else ns_name
    return out


IPS = proxy_ips(ROWDIR)


def sleep_events(path):
    """[(ns, kind)] from the kind,utc csv sleep-events.sh writes."""
    out = []
    if path and os.path.exists(path):
        for raw in open(path):
            raw = raw.strip()
            if not raw or raw.startswith("#") or raw.startswith("kind,"):
                continue
            kind, _, utc = raw.partition(",")
            out.append((ns(utc), kind))
    return sorted(out)


SLEEP = sleep_events(SLEEPCSV)


def sender(remote):
    ip = (remote or "").rsplit(":", 1)[0]
    return IPS.get(ip, "other:" + ip)


def rep(recv, lwi, d):
    src = SOURCE[recv]
    ing = lines(os.path.join(d, "ingress.jsonl"))
    exe = lines(os.path.join(d, "execution.jsonl"))
    inv = lines(os.path.join(d, "invocation.jsonl"))
    cli = lines(os.path.join(d, "client.jsonl"))
    sub = lines(os.path.join(d, "client-sub.jsonl"))
    st = steps(d)
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

    # --- Job 1: the stream the client cancels ----------------------------------------------------------------
    send = arrivals_of("SendStreamingMessage")
    row["arrivals_SendStreamingMessage"] = len(send)
    row["received_joined"] = sum(len(received_for(a)) for a in send)
    row["executes"] = len(executes)
    row["tasks"] = len(tasks)
    row["a2a_version"] = "|".join(sorted({a.get("a2a_version", "") for a in arrivals})) or "none"
    others = sorted({x.get("method") for x in arrivals} - {"SendStreamingMessage", "SubscribeToTask"})
    if others:
        notes.append("other_methods=" + "|".join(others))
    a1 = send[0] if len(send) == 1 else None
    r1 = response_of(a1) if a1 else None
    res1 = result_for(a1) if a1 else []
    row["ingress_stream_end"] = (r1 or {}).get("stream_end", "none")
    row["exec_stream_end"] = res1[0].get("stream_end", "none") if len(res1) == 1 else f"lines={len(res1)}"
    end1 = [x for x in cli if x.get("line") == "end"]
    e1 = end1[-1] if end1 else {}
    row["client_cancel_after_ms"] = e1.get("cancel_after_ms", "absent")
    row["client_cancel_fired"] = e1.get("cancel_fired", "absent")
    row["client_ended_before_cancel"] = e1.get("ended_before_cancel", "absent")
    row["client_events_after_cancel"] = e1.get("events_after_cancel", "absent")
    row["client_kinds_after_cancel"] = "|".join(e1.get("kinds_after_cancel") or []) or "none"
    row["client_events"] = e1.get("events", "none")
    row["client_first"] = f"{e1.get('first_kind', 'none')}/{e1.get('first_state') or 'none'}"
    row["client_last"] = f"{e1.get('last_kind') or 'none'}/{e1.get('last_state') or 'none'}"
    row["client_terminal_seen"] = e1.get("terminal_seen", "none")
    row["client_stream_end"] = e1.get("stream_end", "none")
    row["client_error"] = (e1.get("error") or "").replace(",", " ")
    row["client_http"] = e1.get("http_status", "none")
    row["client_posts"] = e1.get("posts", "none")
    row["client_task_matches"] = "yes" if e1.get("taskId") == task and task else "no"
    row["client_dialled_host"] = f"{e1.get('dialled_url', 'none')} {e1.get('host', '<no host key>')}"
    row["job1"] = job_word(d, f"loadgen-{lwi}")

    # --- the Task, and the model --------------------------------------------------------------------------------
    row["final_state"] = final_state
    row["invocations"] = len(inv_w)
    row["invocation_outcomes"] = "|".join(x.get("outcome", "") for x in inv_w) or "none"
    row["invocation_latency_ms"] = "|".join(f"{x.get('latency_ms', 0):.1f}" for x in inv_w) or "none"
    row["invocation_task_matches"] = "yes" if inv_w and all(x.get("taskId") == task for x in inv_w) else "no"

    # --- Job 2: the one SubscribeToTask ---------------------------------------------------------------------------
    subs = arrivals_of("SubscribeToTask")
    row["arrivals_SubscribeToTask"] = len(subs)
    a2 = subs[-1] if subs else None
    row["sub_task_matches"] = "yes" if a2 and a2.get("taskId") == task and task else "no"
    row["received_sub_joined"] = len(received_for(a2)) if a2 else 0
    r2 = response_of(a2) if a2 else None
    row["ingress_sub_stream_end"] = (r2 or {}).get("stream_end", "none")
    res2 = result_for(a2) if a2 else []
    row["exec_sub_stream_end"] = res2[0].get("stream_end", "none") if len(res2) == 1 else f"lines={len(res2)}"
    dl = sorted((x for x in ex if x.get("event") == "delivered" and x.get("method") == "SubscribeToTask" and x.get("taskId") == task),
                key=lambda x: ns(x["ts"]))
    row["sub_first_delivered"] = f"{dl[0].get('result_kind')}/{dl[0].get('state') or 'none'}" if dl else "none"
    end2 = [x for x in sub if x.get("line") == "end"]
    e2 = end2[-1] if end2 else {}
    row["client2_first"] = f"{e2.get('first_kind') or 'none'}/{e2.get('first_state') or 'none'}"
    row["client2_first_task_matches"] = "yes" if e2.get("first_task_id") == task and task else "no"
    row["client2_events"] = e2.get("events", "none")
    row["client2_kinds"] = "|".join(f"{x.get('kind')}/{x.get('state') or ''}".rstrip("/") for x in sub if x.get("line") == "event") or "none"
    row["client2_terminal_seen"] = e2.get("terminal_seen", "none")
    row["client2_stream_end"] = e2.get("stream_end", "none")
    row["client2_http"] = f"{e2.get('http_status', 'none')} {e2.get('content_type', '')}".strip()
    row["client2_wire_error"] = f"{e2.get('wire_error_code', 'none')}: {e2.get('wire_error_message', '')}".replace(",", " ")
    row["client2_sdk_error"] = (e2.get("error") or "").replace(",", " ")
    row["client2_posts"] = e2.get("posts", "none")
    row["client2_dialled_host"] = f"{e2.get('dialled_url', 'none')} {e2.get('host', '<no host key>')}"
    row["job2"] = job_word(d, f"loadgen-{lwi}-s")

    # --- paths: which proxy sent every arrival, and what each proxy's access log holds for the A2A requests -----
    row["senders"] = "|".join(f"{x.get('method')}<-{sender(x.get('remote'))}" for x in sorted(arrivals, key=lambda x: ns(x["ts_arrival"]))) or "none"
    acc = access(d, "agw-central-access.txt", "agw-central") + access(d, "ingress-access.txt", "ingress")
    a2a = [x for x in acc if x["route"] != "agentgateway-waypoint/model-via-agw" and "/control/" not in x["path"]]
    row["a2a_at_ingress"] = " ".join(f"{x['route']}:{x['host']}:{x['method']}{'(card)' if 'agent-card' in x['path'] else ''}:{x['status']}/{x['duration']}"
                                     for x in a2a if x["proxy"] == "ingress") or "none"
    row["a2a_at_agw_central"] = " ".join(f"{x['route']}:{x['host']}:{x['method']}{'(card)' if 'agent-card' in x['path'] else ''}:{x['status']}/{x['duration']}"
                                         for x in a2a if x["proxy"] == "agw-central") or "none"
    row["arrivals_from_agw_central"] = sum(1 for x in arrivals if sender(x.get("remote")) == "agw-central")
    model = [x for x in acc if x["route"] == "agentgateway-waypoint/model-via-agw"]
    row["model_route"] = f"n={len(model)} " + (" ".join(f"{x['status']}/{x['duration']}" for x in model) or "none")

    # --- timing, parsed stamps joined on identity -------------------------------------------------------------------
    t_sent = ns(e1["ts_sent"]) if e1.get("ts_sent") else None
    t_cancel = ns(e1["ts_cancel"]) if e1.get("ts_cancel") else None
    t_work = t_state.get("TASK_STATE_WORKING")
    t_done = t_state.get("TASK_STATE_COMPLETED")
    t_term = min((v for k, v in t_state.items() if k in TERMINAL), default=None)
    t_ing_end = ns(r1["ts_end"]) if r1 and r1.get("ts_end") else None
    t_exec_end = ns(res1[0]["ts"]) if len(res1) == 1 else None
    t_arr2 = ns(a2["ts_arrival"]) if a2 else None
    t_endread = step_at(st, "Job 1's end line names task")
    t_apply2 = step_at(st, "apply Job 2")
    t_applied2 = step_at(st, "Job 2 applied")
    row["sent_to_cancel_ms"] = ms(t_sent, t_cancel)
    # working -> terminal, the executor's own two state lines: the interval a sleep inside a repetition spans, added
    # on 2026-09-22 after the B-4 review (I-1) found the entry comparing against a figure no file gave.
    row["working_to_terminal_ms"] = ms(t_work, t_term)
    row["working_to_cancel_ms"] = ms(t_work, t_cancel)
    row["cancel_while_working"] = ("yes" if t_work <= t_cancel < (t_term or 1 << 62) else "no") if t_work and t_cancel else "n-a"
    row["cancel_to_ingress_end_ms"] = ms(t_cancel, t_ing_end)
    row["cancel_to_exec_end_ms"] = ms(t_cancel, t_exec_end)
    row["endline_read_to_job2_apply_ms"] = ms(t_endread, t_apply2)
    row["job2_apply_ms"] = ms(t_apply2, t_applied2)
    row["job2_apply_to_arrival_ms"] = ms(t_apply2, t_arr2)
    row["cancel_to_sub_arrival_ms"] = ms(t_cancel, t_arr2)
    row["working_to_sub_arrival_ms"] = ms(t_work, t_arr2)
    row["sub_arrival_to_completed_ms"] = ms(t_arr2, t_done)
    row["cancel_to_completed_ms"] = ms(t_cancel, t_done)
    row["running_at_sub_arrival"] = ("yes" if t_work <= t_arr2 < t_term else "no") if t_work and t_arr2 and t_term else "n-a"
    row["sub_after_job1_end_line"] = ("yes" if t_endread is not None and t_apply2 is not None and t_endread <= t_apply2 else "no")
    # The repetition's own window, from its first stamped step to its last, against the host's power events.
    win = (st[0][0], st[-1][0]) if st else (None, None)
    inside = [k for t, k in SLEEP if win[0] is not None and win[0] <= t <= win[1]]
    row["sleep_affected"] = "yes" if inside else "no"
    row["sleep_kinds_in_window"] = "|".join(inside) or "none"
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
print(f"# tally, per receiver (N={N_MS} ms, K={K_MS} ms): column=value xN, for every column but work_item and the per-repetition figures.")
print(f"# Each receiver is tallied twice: over the CLEAN repetitions, and over ALL of them. Sleep events read from {SLEEPCSV or '<none given>'}.")
affected = [r["work_item"] for r in reps if r["sleep_affected"] == "yes"]
print("# sleep-affected repetitions: " + ("; ".join(affected) if affected else "none"))
figures = {"invocation_latency_ms", "sent_to_cancel_ms", "working_to_cancel_ms", "working_to_terminal_ms", "cancel_to_ingress_end_ms", "cancel_to_exec_end_ms",
           "endline_read_to_job2_apply_ms", "job2_apply_ms", "job2_apply_to_arrival_ms", "cancel_to_sub_arrival_ms",
           "working_to_sub_arrival_ms", "sub_arrival_to_completed_ms", "cancel_to_completed_ms"}
skip = {"work_item", "a2a_at_ingress", "a2a_at_agw_central", "model_route"} | figures
for recv, which in [(r, w) for r in ("go", "py") for w in ("clean", "all")]:
    rs = [r for r in reps if r["receiver"] == recv and (which == "all" or r["sleep_affected"] == "no")]
    if not rs:
        continue
    print(f"## {recv}, {which}: {len(rs)} repetitions")
    for c in cols:
        if c in skip or c == "receiver":
            continue
        vals = {}
        for r in rs:
            vals[str(r[c])] = vals.get(str(r[c]), 0) + 1
        print(f"  {c}: " + "; ".join(f"{k or '<empty>'} x{v}" for k, v in sorted(vals.items())))
    for c in ("a2a_at_ingress", "a2a_at_agw_central", "model_route"):
        shapes = {}
        for r in rs:
            shape = re.sub(r"\b(\d{3})/[0-9.]+(ms|s|µs)?", r"\1/<d>", str(r[c]))
            shapes[shape] = shapes.get(shape, 0) + 1
        print(f"  {c} (durations masked): " + "; ".join(f"{k} x{v}" for k, v in sorted(shapes.items())))
    for c in sorted(figures):
        if c in cols:
            xs = [float(v) for r in rs for v in str(r[c]).split("|") if re.match(r"^-?\d", v)]
            if xs:
                print(f"  {c}: min {min(xs):.1f} max {max(xs):.1f} mean {sum(xs) / len(xs):.1f} over {len(xs)}")
