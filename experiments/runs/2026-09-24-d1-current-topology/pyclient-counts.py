"""Follow-on D-1, the Python-client row: one CSV line per repetition, and a tally.

    python3 pyclient-counts.py <variant dir> [<sleep events csv>]   writes <variant dir>/summary.csv, prints a tally

Each repetition directory holds forward.jsonl (the orchestrator's own forward lines: the SendStreamingMessage it
sent to the worker and, if it sent one, its one SubscribeToTask), ingress.jsonl / execution.jsonl (both agents' ledgers,
make ledgers, each line tagged with its source), invocation.jsonl (the mock), client.jsonl (the load client that
started the work item), removal.txt and steps.txt (the driver's stamped steps), oldpod.log (the removed agw-central
pod's own log, captured from before the removal), oldpod-before.json and newpod-after.json.

The rules are B-5b's counts.py's: every stamp PARSED to integer nanoseconds; lines joined on identity (the forward's
stream by its messageId at the worker, the resubscription by its taskId), never on line order; the final state is
the executor's last state line by parsed stamp; every invocation line counted; each interval column names its clock
pair (_h2c a host stamp against a cluster stamp, _c2c both inside the cluster, _h2h both the driver's own); a
repetition a host power event touched is marked and its _h2c figures are not read. Reads files only.
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

VDIR = sys.argv[1]
SLEEPCSV = sys.argv[2] if len(sys.argv) > 2 else ""
TERMINAL = {"TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"}
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$")


def ns(s):
    m = STAMP.match(s or "")
    if not m:
        return None
    base = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    if m.group(3) != "Z":
        sign = 1 if m.group(3)[0] == "+" else -1
        base -= sign * timedelta(hours=int(m.group(3)[1:3]), minutes=int(m.group(3)[4:6]))
    return int(base.timestamp()) * 1_000_000_000 + int((m.group(2) or "").ljust(9, "0")[:9])


def ms(a, b):
    return f"{(b - a) / 1e6:.1f}" if a is not None and b is not None else "n-a"


def jl(path):
    out = []
    if os.path.exists(path):
        for raw in open(path):
            raw = raw.strip()
            if raw:
                try:
                    out.append(json.loads(raw))
                except json.JSONDecodeError:
                    pass
    return out


def stamped(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            head, _, rest = line.rstrip("\n").partition(" ")
            t = ns(head)
            if t is not None:
                out.append((t, rest))
    return out


def podlog(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            head, _, rest = line.rstrip("\n").partition("\t")
            t = ns(head)
            if t is not None:
                out.append((t, rest))
    return out


def sleeps():
    ev = []
    if SLEEPCSV and os.path.exists(SLEEPCSV):
        for line in open(SLEEPCSV):
            if line.startswith("#") or line.startswith("kind,"):
                continue
            k, _, u = line.strip().partition(",")
            if ns(u) is not None:
                ev.append((k, ns(u)))
    return ev


SLEEPS = sleeps()


def podip(path):
    try:
        return json.load(open(path))["status"].get("podIP", "")
    except (OSError, ValueError, KeyError):
        return ""


def rep(lwi, d):
    r = {"work_item": lwi}
    steps, rm = stamped(os.path.join(d, "steps.txt")), stamped(os.path.join(d, "removal.txt"))
    allstamps = [t for t, _ in steps + rm]
    lo, hi = (min(allstamps), max(allstamps)) if allstamps else (None, None)
    hit = [k for k, t in SLEEPS if lo is not None and lo <= t <= hi]
    r["sleep_affected"] = "yes:" + "+".join(hit) if hit else "no"
    clean = not hit
    h2c = (lambda a, b: ms(a, b)) if clean else (lambda a, b: "not-readable(sleep)")

    t_rm = next((t for t, x in rm if x.startswith("REMOVAL COMMAND START")), None)
    t_ready = next((t for t, x in rm if x.startswith("successor Ready")), None)
    t_gone = next((t for t, x in rm if x.startswith("old pod object gone")), None)
    r["removal_sent"] = "yes" if t_rm else "no"
    r["rm_to_successor_ready_ms_h2h"] = ms(t_rm, t_ready)
    r["rm_to_old_pod_gone_ms_h2h"] = ms(t_rm, t_gone)
    at_ready = next((x for _, x in rm if x.startswith("THE FORWARD AT THIS MOMENT")), "")
    r["forward_at_successor_ready"] = at_ready.split(":", 1)[1].split("<-")[0].strip() or "<no end line yet>" if at_ready else "n-a"

    # the removed pod's own log
    pl = podlog(os.path.join(d, "oldpod.log"))
    t_sig = next((t for t, x in pl if "received signal SIGTERM" in x), None)
    t_drain = next((t for t, x in pl if "drain started, waiting" in x), None)
    t_min = next((t for t, x in pl if "minimum drain completed" in x), None)
    r["rm_to_sigterm_ms_h2c"] = h2c(t_rm, t_sig)
    r["sigterm_to_drain_start_ms_c2c"] = ms(t_sig, t_drain)
    r["drain_start_to_min_drain_ms_c2c"] = ms(t_drain, t_min)
    r["hbone_drain_timeout_lines"] = str(sum(1 for _, x in pl if "hbone error: drain timeout" in x))
    r["span_processor_shutdown_timeout"] = "yes" if any("BatchSpanProcessor.Shutdown.Timeout" in x for _, x in pl) else "no"
    r["last_line"] = pl[-1][1].split("\t")[2] if pl and len(pl[-1][1].split("\t")) > 2 else (pl[-1][1][:60] if pl else "")
    old_ip, new_ip = podip(os.path.join(d, "oldpod-before.json")), podip(os.path.join(d, "newpod-after.json"))

    # the orchestrator's own forward lines
    fwd = jl(os.path.join(d, "forward.jsonl"))
    ends = [l for l in fwd if l.get("line") == "end"]
    f1 = next((l for l in ends if l["operation"] == "SendStreamingMessage"), {})
    f2 = next((l for l in ends if l["operation"] == "SubscribeToTask"), {})
    r["forward_streams"] = str(sum(1 for l in ends if l["operation"] == "SendStreamingMessage"))
    r["forward_subscriptions"] = str(sum(1 for l in ends if l["operation"] == "SubscribeToTask"))
    r["fwd1_events"] = str(f1.get("events", ""))
    r["fwd1_kinds"] = "|".join(f"{l['kind']}/{l['state']}" if l.get("state") else l["kind"]
                               for l in fwd if l.get("line") == "event" and l["operation"] == "SendStreamingMessage")
    r["fwd1_terminal_seen"] = str(f1.get("terminal_seen", ""))
    r["fwd1_stream_end"] = f1.get("stream_end", "")
    r["fwd1_error_type"] = f1.get("error_type", "")
    r["fwd1_error"] = f1.get("error", "")
    r["fwd1_resubscribe"] = f1.get("resubscribe", "")
    task = f1.get("taskId", "")
    t_f1_end = ns(f1.get("ts", ""))
    r["rm_to_fwd1_end_ms_h2c"] = h2c(t_rm, t_f1_end)
    r["fwd2_requested_task_matches"] = ("yes" if f2.get("requested_task_id") == task and task else "no") if f2 else "n-a"
    r["fwd2_first"] = f"{f2.get('first_kind', '')}/{f2.get('first_state', '')}" if f2 else "n-a"
    r["fwd2_first_task_matches"] = ("yes" if f2.get("first_task_id") == task and task else "no") if f2 else "n-a"
    r["fwd2_kinds"] = "|".join(f"{l['kind']}/{l['state']}" if l.get("state") else l["kind"]
                               for l in fwd if l.get("line") == "event" and l["operation"] == "SubscribeToTask") if f2 else "n-a"
    r["fwd2_terminal_seen"] = str(f2.get("terminal_seen", "")) if f2 else "n-a"
    r["fwd2_last_state"] = f2.get("last_state", "") if f2 else "n-a"
    r["fwd2_stream_end"] = f2.get("stream_end", "") if f2 else "n-a"
    r["fwd2_error_type"] = f2.get("error_type", "") if f2 else "n-a"
    r["fwd2_error"] = f2.get("error", "") if f2 else "n-a"

    # the worker's ledgers, joined on identity
    ing = [l for l in jl(os.path.join(d, "ingress.jsonl")) if l.get("source") == "worker"]
    exe = [l for l in jl(os.path.join(d, "execution.jsonl")) if l.get("source") == "worker"]
    mid = next((l["messageId"] for l in fwd if l.get("messageId")), "")
    s_arr = [l for l in ing if l["phase"] == "arrival" and l["method"] == "SendStreamingMessage" and l["messageId"] == mid]
    s_resp = [l for l in ing if l["phase"] == "response" and l["method"] == "SendStreamingMessage" and l["messageId"] == mid]
    sub_arr = [l for l in ing if l["phase"] == "arrival" and l["method"] == "SubscribeToTask"]
    sub_resp = [l for l in ing if l["phase"] == "response" and l["method"] == "SubscribeToTask"]
    r["worker_stream_arrivals"] = str(len(s_arr))
    r["worker_sub_arrivals"] = str(len(sub_arr))
    r["worker_sub_arrival_task_matches"] = ("yes" if all(l["taskId"] == task for l in sub_arr) else "no") if sub_arr else "n-a"
    ipname = lambda ip: "old-pod" if ip == old_ip else "successor" if ip == new_ip else f"other:{ip}"
    r["worker_stream_from"] = "|".join(ipname(l["remote"].rsplit(":", 1)[0]) for l in s_arr)
    r["worker_sub_from"] = "|".join(ipname(l["remote"].rsplit(":", 1)[0]) for l in sub_arr) or "n-a"
    r["worker_stream_end_ingress"] = "|".join(l.get("stream_end", "<unary>") for l in s_resp)
    r["worker_sub_end_ingress"] = "|".join(l.get("stream_end", "<unary>") + "/" + str(l.get("status")) for l in sub_resp) or "n-a"
    t_f1_worker_end = ns(s_resp[0]["ts_end"]) if s_resp and s_resp[0].get("ts_end") else None
    r["fwd1_end_to_worker_ingress_end_ms_c2c"] = ms(t_f1_end, t_f1_worker_end)
    results = [l for l in exe if l.get("event") == "result"]
    r["worker_stream_result"] = "|".join(f"{l.get('stream_end', '')}{'/err:' + l['error'] if l.get('error') else ''}"
                                         for l in results if l.get("method") == "SendStreamingMessage")
    r["worker_sub_result"] = "|".join(f"{l.get('stream_end', '')}{'/err:' + l['error'] if l.get('error') else ''}"
                                      for l in results if l.get("method") == "SubscribeToTask") or "n-a"
    first_sub_deliv = next((l for l in sorted(exe, key=lambda l: ns(l["ts"]) or 0)
                            if l.get("event") == "delivered" and l.get("method") == "SubscribeToTask"), None)
    r["worker_sub_first_delivered"] = f"{first_sub_deliv.get('result_kind')}/{first_sub_deliv.get('state', '')}" if first_sub_deliv else "n-a"
    r["worker_executes"] = str(sum(1 for l in exe if l.get("event") == "execute"))
    r["worker_tasks"] = str(len({l["taskId"] for l in exe if l.get("event") == "execute"}))
    states = sorted((l for l in exe if l.get("event") == "state" and l.get("taskId") == task), key=lambda l: ns(l["ts"]))
    r["worker_states"] = "|".join(l["state"].replace("TASK_STATE_", "") for l in states)
    fin = states[-1] if states else {}
    r["worker_final_state"] = fin.get("state", "")
    r["worker_final_error"] = fin.get("error", "")
    t_term = ns(fin["ts"]) if fin.get("state") in TERMINAL else None
    t_sub = ns(sub_arr[0]["ts_arrival"]) if sub_arr else None
    r["rm_to_worker_terminal_ms_h2c"] = h2c(t_rm, t_term)
    r["rm_to_sub_arrival_ms_h2c"] = h2c(t_rm, t_sub)
    r["sub_arrival_to_worker_terminal_ms_c2c"] = ms(t_sub, t_term)
    r["task_running_at_sub_arrival"] = ("yes" if t_term is None or t_sub < t_term else "no") if t_sub else "n-a"
    r["fwd1_end_to_worker_terminal_ms_c2c"] = ms(t_f1_end, t_term)
    r["fwd1_end_to_sub_arrival_ms_c2c"] = ms(t_f1_end, t_sub)

    inv = jl(os.path.join(d, "invocation.jsonl"))
    r["invocations"] = str(len(inv))
    r["invocation_outcomes"] = "|".join(l.get("outcome", "") for l in inv)
    r["invocation_latency_ms"] = "|".join(f"{l.get('latency_ms', 0):.1f}" for l in inv)
    r["invocation_task_matches"] = ("yes" if all(l.get("taskId") == task for l in inv) else "no") if inv else "n-a"
    r["stale_closed"] = str(sum(1 for l in inv if l.get("outcome") == "stale-closed"))

    # the orchestrator: its own Task, the one the load client started
    oexe = [l for l in jl(os.path.join(d, "execution.jsonl")) if l.get("source") == "orchestrator"]
    r["orch_executes"] = str(sum(1 for l in oexe if l.get("event") == "execute"))
    ost = sorted((l for l in oexe if l.get("event") == "state"), key=lambda l: ns(l["ts"]))
    r["orch_final_state"] = ost[-1]["state"] if ost else ""
    r["orch_final_error"] = ost[-1].get("error", "") if ost else ""
    cl = jl(os.path.join(d, "client.jsonl"))
    c = cl[-1] if cl else {}
    r["load_client"] = f"{c.get('result_kind', '')}/{c.get('state', '')}{'/err:' + c['error'] if c.get('error') else ''}"
    jobs = open(os.path.join(d, "jobs.txt")).read().strip() if os.path.exists(os.path.join(d, "jobs.txt")) else ""
    m = re.search(r"succeeded=(\S*) failed=(\S*) pod-exit=(\S*) pods=(\S*)", jobs)
    r["job"] = f"{'Complete' if m and m.group(1) == '1' else 'Failed' if m and m.group(2) == '1' else 'none'}/exit{m.group(3) if m else '?'}/pods{m.group(4) if m else '?'}"
    return r


reps = []
for lwi in sorted(os.listdir(VDIR)):
    d = os.path.join(VDIR, lwi)
    if os.path.isdir(d) and os.path.exists(os.path.join(d, "steps.txt")):
        reps.append(rep(lwi, d))
if not reps:
    sys.exit("no repetitions")
cols = list(reps[0].keys())
with open(os.path.join(VDIR, "summary.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
    w.writeheader()
    w.writerows(reps)
FIG = re.compile(r"_ms_(h2c|c2c|h2h)$|^invocation_latency_ms$")
print(f"# {len(reps)} repetitions under {VDIR}; sleep events read from {SLEEPCSV or '<none>'}")
for which in ("clean", "all"):
    rs = [r for r in reps if which == "all" or r["sleep_affected"] == "no"]
    print(f"## {which}: {len(rs)} repetitions")
    for c in cols:
        if c == "work_item":
            continue
        vals = [r[c] for r in rs]
        if FIG.search(c):
            nums = [float(x) for v in vals for x in v.split("|") if re.fullmatch(r"-?\d+(\.\d+)?", x)]
            other = sorted({v for v in vals if not re.fullmatch(r"-?\d+(\.\d+)?(\|-?\d+(\.\d+)?)*", v)})
            rng = f"{min(nums):.1f} .. {max(nums):.1f} (n={len(nums)})" if nums else "none"
            print(f"  {c}: {rng}{'; also ' + ', '.join(other) if other else ''}")
        else:
            counts = {}
            for v in vals:
                counts[v] = counts.get(v, 0) + 1
            print(f"  {c}: " + "; ".join(f"{k or '<empty>'} x{n}" for k, n in sorted(counts.items(), key=lambda kv: -kv[1])))
