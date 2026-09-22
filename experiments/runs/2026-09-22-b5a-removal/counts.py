"""Experiment B, step B-5a: the counts of the removal variants, from what rows.sh collected, one CSV line per repetition.

    python3 counts.py <removal dir> <N_ms> [<sleep events csv>]    writes <removal dir>/summary.csv and prints it
                                                                   with a tally per variant over the clean
                                                                   repetitions and another over all of them

Every repetition directory under <removal dir>/<variant>/<work item>/ holds ingress.jsonl, execution.jsonl,
invocation.jsonl and client.jsonl (make ledgers), steps.txt and removal.txt (the driver's stamped steps and its
removal record), jobs.txt, oldpod.log (the removed pod's own log, captured from before the removal), newpod.log (the
successor's), otherproxy-access.txt (the proxy that stayed up), successor.txt, and probe/ (the probe's ledgers).
<variant>/control.txt names the proxy pods and their IPs, which is how the sender of every arrival is named.

Adapted from experiments/runs/2026-09-22-b4-control/counts.py (the control row), which this step's stimulus is set
beside. What is new here: the removal columns (the command, the old pod's deletionTimestamp, the successor's
creationTimestamp and Ready condition, when the old pod object went); the drain columns read from the removed pod's
own log, with the `hbone error: drain timeout` line of the preparation's 6.2 as its own column; the successor
columns (the probe of the row's own kind and the first request the new pod answered); and the seconds from the
removal command to every one of those, each named with the clock it is on. The cancel columns are gone: B-5a
cancels nothing.

THE CLOCKS. The brief asks for seconds per clock, saying which clock each belongs to, so every interval column's
name ends in the pair it joins:
  _h2h  both stamps the driver's own, on the HOST clock (the removal command, its own observations);
  _h2c  one HOST stamp joined to one cluster-side stamp: the removal command or one of the driver's own
        observations, against a client pod, a receiver pod, the mock, a proxy pod or the API server. These are the
        only figures a host/VM clock difference or a host sleep can reach, and a repetition a sleep touched reports
        them as not readable;
  _c2c  both stamps from inside the cluster, which no host clock jump can reach.
The API-server stamps (deletionTimestamp, creationTimestamp, Ready lastTransitionTime) have SECOND resolution and
are marked so in their column names (_s1).

The standing B rules, as this program keeps them, unchanged from B-4:
  - every stamp is PARSED to integer nanoseconds, never compared as text;
  - ingress and execution lines are joined on identity -- a send by its messageId, an ingress response line to its
    arrival by (method, JSON-RPC id, ts_arrival) -- never on line order;
  - the final state is the executor's last `state` line for the task by parsed stamp, not the execution result
    line's state (which on a streamed dispatch is the FIRST Task's);
  - a `delivered` line is what the SDK handed to its stream writer, not what reached the client: it is reported
    beside the client's own events, never instead of them;
  - every invocation line is counted and reported, stale-closed included; none is filtered;
  - a repetition is marked sleep-affected when a host power event of the four kinds (sleep-events.csv, kinds and
    stamps only) falls inside that repetition's own window, from its first stamped step to its last.
THE REDIRECT CHECK (the B-4 review's carry). internal/httpclient.New leaves CheckRedirect at Go's default, so a 3xx
would be followed and CLIENT_HOST re-applied to the next request, and no test pins that at this tree. A removed
proxy is when a gateway is likeliest to answer non-2xx, so every repetition reports what its client actually saw --
the status, the content type, the JSON-RPC error on the wire, the SDK's error text -- the POST round trips the
client's own outermost transport carried (a followed redirect is a second round trip), and every non-2xx status in
either proxy's access lines. Reads files only.
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROWDIR, N_MS = sys.argv[1], int(sys.argv[2])
SLEEPCSV = sys.argv[3] if len(sys.argv) > 3 else ""
SOURCE = "worker"  # B-5a's receiver; the driver's header says why this step has no receiver dimension
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


def nsq(s):
    """ns() for a stamp that may be absent or unparsable; None then."""
    try:
        return ns(s)
    except ValueError:
        return None


def ms(a, b):
    return f"{(b - a) / 1e6:.1f}" if a is not None and b is not None else "n-a"


def lines(path):
    if not os.path.exists(path):
        return []
    out = []
    for raw in open(path):
        raw = raw.strip()
        if raw:
            try:
                out.append(json.loads(raw))
            except json.JSONDecodeError:
                pass
    return out


def job_word(d, name):
    p = os.path.join(d, "jobs.txt")
    if not os.path.exists(p):
        return "absent"
    for j in open(p).read().split("\n"):
        if j.startswith(name + " "):
            succ = re.search(r"succeeded=(\S*)", j).group(1)
            fail = re.search(r"failed=(\S*)", j).group(1)
            exit_ = re.search(r"pod-exit=(\S*)", j).group(1)
            pods = re.search(r"pods=(\S*)", j)
            return f"{'Complete' if succ == '1' else 'Failed' if fail == '1' else 'none'}/exit{exit_}/pods{pods.group(1) if pods else '?'}"
    return "absent"


STEP = re.compile(r"^(\S+) (.*)$")


def stamped(d, name):
    """A driver file's stamped lines: [(ns, text)]. Lines it could not stamp are dropped."""
    out = []
    p = os.path.join(d, name)
    if os.path.exists(p):
        for raw in open(p):
            m = STEP.match(raw.rstrip("\n"))
            if m:
                t = nsq(m.group(1))
                if t is not None:
                    out.append((t, m.group(2)))
    return out


def at(st, prefix):
    for t, text in st:
        if text.startswith(prefix):
            return t
    return None


def text_at(st, prefix):
    for _, text in st:
        if text.startswith(prefix):
            return text
    return ""


def field(text, key):
    """`key=value` out of one of the driver's own lines; '' when absent."""
    m = re.search(re.escape(key) + r"=(\S*)", text or "")
    return m.group(1) if m else ""


# A proxy log line: an RFC3339 stamp, a tab, the level, a tab, then the message. Access lines carry `request
# gateway=`; everything else the proxy logged is kept as it stands, which is where the drain lines are.
PLINE = re.compile(r"^(\S+)\t(\S+)\t(.*)$")
# http.status is OPTIONAL, and that is a reading rather than a convenience: when a removal cuts a request before
# any response head exists, the proxy still writes the request's access line and that line carries NO http.status
# field at all (measured on agw-central, 10 of 10 graceful and rollout repetitions). A regex that required the field
# dropped exactly the line that says what the removal cut, so the field is optional here and an absent one is
# reported as "<no-status>".
ACCESS = re.compile(r"route=(\S+) endpoint=(\S+) src\.addr=(\S+) .*?http\.method=(\S+) http\.host=(\S+) http\.path=(\S+)(?: .*?http\.status=(\S+))?.*?duration=(\S+)")


def proxy_log(d, name):
    """[(ns, level, message, access-dict-or-None)] for one proxy pod's own log."""
    out = []
    p = os.path.join(d, name)
    if not os.path.exists(p):
        return out
    for raw in open(p):
        m = PLINE.match(raw.rstrip("\n"))
        if not m:
            continue
        t = nsq(m.group(1))
        if t is None:
            continue
        msg = m.group(3)
        a = None
        am = ACCESS.search(msg)
        if am:
            route, endpoint, src, method, host, path, status, duration = am.groups()
            a = {"route": route, "endpoint": endpoint, "src": src, "method": method, "host": host,
                 "path": path, "status": status or "<no-status>", "duration": duration}
        out.append((t, m.group(2), msg, a))
    return sorted(out)


def access_file(d, name):
    """The other proxy's collected access lines, same shape as proxy_log's access entries."""
    out = []
    p = os.path.join(d, name)
    if os.path.exists(p):
        for raw in open(p):
            m = PLINE.match(raw.rstrip("\n"))
            if not m:
                continue
            t = nsq(m.group(1))
            am = ACCESS.search(m.group(3))
            if t is not None and am:
                route, endpoint, src, method, host, path, status, duration = am.groups()
                out.append((t, {"route": route, "endpoint": endpoint, "src": src, "method": method, "host": host,
                                "path": path, "status": status or "<no-status>", "duration": duration}))
    return sorted(out)


def shape(a):
    return f"{a['route']}:{a['host']}:{a['method']}{'(card)' if 'agent-card' in a['path'] else ''}:{a['status']}"


def proxy_ips(vardir):
    """Pod IP -> proxy name, from the driver's between-variant 'proxy pods:' lines in control.txt."""
    out = {}
    p = os.path.join(vardir, "control.txt")
    if os.path.exists(p):
        for raw in open(p):
            if "proxy pods:" in raw:
                for ns_name, ip in re.findall(r"(\S+/\S+) ip=(\S+)", raw):
                    out[ip] = "agw-central" if "agw-central" in ns_name else "ingress" if "agentgateway-ingress" in ns_name else ns_name
    return out


def sleep_events(path):
    """[(ns, kind)] from the kind,utc csv sleep-events.sh writes."""
    out = []
    if path and os.path.exists(path):
        for raw in open(path):
            raw = raw.strip()
            if not raw or raw.startswith("#") or raw.startswith("kind,"):
                continue
            kind, _, utc = raw.partition(",")
            t = nsq(utc)
            if t is not None:
                out.append((t, kind))
    return sorted(out)


SLEEP = sleep_events(SLEEPCSV)


PODIP = re.compile(r"(\S+) uid=\S+ ip=(\S+)")


def rep(variant, lwi, d, ips0):
    proxy, method = variant.split("-", 1)
    # The variant's own proxy pods change under it, one successor per repetition, so the IP map is the
    # between-variant readings PLUS this repetition's own "proxy pods before/after" lines.
    ips = dict(ips0)
    name = "ingress" if proxy == "ingress" else "agw-central"
    p = os.path.join(d, "steps.txt")
    if os.path.exists(p):
        for raw in open(p):
            if "proxy pods before:" in raw or "proxy pods after:" in raw:
                for _pod, ip in PODIP.findall(raw):
                    ips.setdefault(ip, name)
    ing = lines(os.path.join(d, "ingress.jsonl"))
    exe = lines(os.path.join(d, "execution.jsonl"))
    inv = lines(os.path.join(d, "invocation.jsonl"))
    cli = lines(os.path.join(d, "client.jsonl"))
    pcli = lines(os.path.join(d, "probe", "client.jsonl"))
    pinv = lines(os.path.join(d, "probe", "invocation.jsonl"))
    st = stamped(d, "steps.txt")
    rm = stamped(d, "removal.txt")
    notes = []

    def sender(remote):
        ip = (remote or "").rsplit(":", 1)[0]
        return ips.get(ip, "other:" + ip)

    mine = [x for x in ing if x.get("source") == SOURCE]
    other = [x for x in ing if x.get("source") != SOURCE and x.get("phase") == "arrival"]
    if other:
        notes.append(f"arrivals_at_the_other_agent={len(other)}")
    arrivals = sorted((x for x in mine if x.get("phase") == "arrival"), key=lambda x: ns(x["ts_arrival"]))
    responses = [x for x in mine if x.get("phase") == "response"]

    ex = [x for x in exe if x.get("source") == SOURCE]
    executes = [x for x in ex if x.get("event") == "execute"]
    tasks = sorted({x["taskId"] for x in ex if x.get("event") == "state" and x.get("state") == "TASK_STATE_SUBMITTED"})
    task = tasks[0] if len(tasks) == 1 else ""
    if len(tasks) != 1:
        notes.append(f"tasks={len(tasks)}")
    states = sorted((x for x in ex if x.get("event") == "state" and x.get("taskId") == task), key=lambda x: ns(x["ts"]))
    t_state, e_state = {}, {}
    for s in states:
        t_state.setdefault(s["state"], ns(s["ts"]))
        e_state.setdefault(s["state"], s.get("error", ""))
    final_state = states[-1]["state"] if states else "none"

    row = {"variant": variant, "proxy": proxy, "method": method, "work_item": lwi}

    # --- Job 1: the one open stream -------------------------------------------------------------------------
    send = [a for a in arrivals if a.get("method") == "SendStreamingMessage"]
    row["arrivals_SendStreamingMessage"] = len(send)
    row["arrivals_other_methods"] = "|".join(sorted({a.get("method") for a in arrivals} - {"SendStreamingMessage"})) or "none"
    a1 = send[0] if len(send) == 1 else None
    row["received_joined"] = len([x for x in ex if x.get("event") == "received" and a1 and x.get("messageId") == a1.get("messageId")])
    row["executes"] = len(executes)
    row["tasks"] = len(tasks)
    row["a2a_version"] = "|".join(sorted({a.get("a2a_version", "") for a in arrivals})) or "none"
    r1 = None
    if a1:
        m = [r for r in responses if r.get("method") == a1.get("method") and r.get("id") == a1.get("id")
             and ns(r["ts_arrival"]) == ns(a1["ts_arrival"])]
        r1 = m[0] if len(m) == 1 else None
    row["ingress_status"] = (r1 or {}).get("status", "none")
    row["ingress_stream_end"] = (r1 or {}).get("stream_end", "none")
    res1 = [x for x in ex if x.get("event") == "result" and a1 and x.get("messageId") == a1.get("messageId")]
    row["exec_stream_end"] = res1[0].get("stream_end", "none") if len(res1) == 1 else f"lines={len(res1)}"
    row["exec_result_error"] = (res1[0].get("error", "") if len(res1) == 1 else "").replace(",", " ") or "<no error key>"
    dl = [x for x in ex if x.get("event") == "delivered" and a1 and x.get("messageId") == a1.get("messageId")]
    row["delivered_lines"] = "|".join(f"{x.get('result_kind')}/{x.get('state') or ''}".rstrip("/") for x in
                                      sorted(dl, key=lambda x: ns(x["ts"]))) or "none"

    ev = sorted((x for x in cli if x.get("line") == "event"), key=lambda x: ns(x["ts"]))
    end1 = [x for x in cli if x.get("line") == "end"]
    e1 = end1[-1] if end1 else {}
    row["client_events"] = e1.get("events", "none")
    row["client_kinds"] = "|".join(f"{x.get('kind')}/{x.get('state') or ''}".rstrip("/") for x in ev) or "none"
    row["client_first"] = f"{e1.get('first_kind', 'none')}/{e1.get('first_state') or 'none'}"
    row["client_last"] = f"{e1.get('last_kind') or 'none'}/{e1.get('last_state') or 'none'}"
    row["client_terminal_seen"] = e1.get("terminal_seen", "none")
    row["client_stream_end"] = e1.get("stream_end", "none")
    row["client_error"] = (e1.get("error") or "").replace(",", " ") or "<none>"
    row["client_http"] = e1.get("http_status", "none")
    row["client_content_type"] = e1.get("content_type", "none")
    row["client_wire_error"] = f"{e1.get('wire_error_code', 'none')}: {e1.get('wire_error_message', '')}".replace(",", " ")
    row["client_posts"] = e1.get("posts", "none")
    row["client_dialled_host"] = f"{e1.get('dialled_url', 'none')} {e1.get('host', '<no host key>')}"
    row["client_task_matches"] = "yes" if e1.get("taskId") == task and task else "no"
    row["job1"] = job_word(d, f"loadgen-{lwi}")

    # --- the Task and the model call ------------------------------------------------------------------------
    row["final_state"] = final_state
    row["final_state_error"] = (e_state.get(final_state, "") or "<none>").replace(",", " ")[:160]
    row["states"] = "|".join(s["state"] for s in states) or "none"
    inv_w = [x for x in inv if x.get("logical_work_item_id") == lwi]
    row["invocations"] = len(inv_w)
    row["invocation_outcomes"] = "|".join(x.get("outcome", "") for x in inv_w) or "none"
    row["invocation_latency_ms"] = "|".join(f"{x.get('latency_ms', 0):.1f}" for x in inv_w) or "none"
    row["invocation_task_matches"] = "yes" if inv_w and all(x.get("taskId") == task for x in inv_w) else "no"

    # --- the removal ------------------------------------------------------------------------------------------
    oldline = text_at(st, "old pod:")
    row["old_pod"] = oldline.split()[2] if len(oldline.split()) > 2 else "none"
    row["old_pod_grace_s"] = field(oldline, "grace")
    newf = os.path.join(d, "successor.txt")
    row["new_pod"] = (open(newf).read().strip() if os.path.exists(newf) else "") or "none"
    t_rm = at(rm, "REMOVAL COMMAND START")
    t_rm_done = at(rm, "REMOVAL COMMAND DONE")
    row["removal_issued"] = "yes" if t_rm is not None else "no"
    row["removal_cmd_ms_h2h"] = ms(t_rm, t_rm_done)
    del_ts = nsq(field(text_at(rm, "old pod deletionTimestamp="), "old pod deletionTimestamp"))
    created = nsq(field(text_at(rm, "successor pod appeared:"), "created"))
    ready_lt = nsq(field(text_at(rm, "successor Ready ("), "lastTransitionTime"))
    t_oldgone = at(rm, "old pod object gone")
    t_ready_seen = at(rm, "successor Ready (")
    t_newseen = at(rm, "successor pod appeared:")
    row["rm_to_deletionTimestamp_ms_h2c_s1"] = ms(t_rm, del_ts)
    row["rm_to_successor_created_ms_h2c_s1"] = ms(t_rm, created)
    row["rm_to_successor_ready_lt_ms_h2c_s1"] = ms(t_rm, ready_lt)
    row["rm_to_successor_seen_ms_h2h"] = ms(t_rm, t_newseen)
    row["rm_to_successor_ready_seen_ms_h2h"] = ms(t_rm, t_ready_seen)
    row["rm_to_old_pod_gone_ms_h2h"] = ms(t_rm, t_oldgone)
    # The rollout's derived maxSurge reading (the preparation's 6.4): was a successor serving before the old pod was
    # asked to stop? Two independent answers, because neither stamp is available in every method.
    #   (a) the API server's own pair. The deletionTimestamp is read ONCE, the moment the removal command returns:
    #       a delete sets it there and then, a `rollout restart` does not set it until the controller scales the old
    #       ReplicaSet down, and a forced delete leaves no object to read. So an empty cell here is itself the
    #       reading -- at the moment the command returned, the old pod had not been asked to stop.
    #   (b) the old pod's OWN log: the moment it was told, `received signal SIGTERM`, on the proxy's clock, against
    #       the successor's Ready lastTransitionTime. This one exists for every method, and it is the stamp the
    #       drain decomposition below is measured from.
    if ready_lt is not None and del_ts is not None:
        row["successor_ready_before_old_deleted"] = "yes" if ready_lt <= del_ts else "no"
    else:
        row["successor_ready_before_old_deleted"] = "n-a"

    # --- the removed pod's own log: its access lines and its drain lines ---------------------------------------
    plog = proxy_log(d, "oldpod.log")
    oacc = [(t, a) for t, _, _, a in plog if a]
    oother = [(t, lvl, msg) for t, lvl, msg, a in plog if not a]
    after = [(t, lvl, msg) for t, lvl, msg in oother if t_rm is None or t >= t_rm]
    row["old_pod_access_lines"] = len(oacc)
    # Did the removed pod write an access line for the request it was CARRYING when it was cut? On the ingress that
    # request is the streamed POST (the card GET is the only GET); on agw-central it is the model POST. An operator's
    # record of what a removal cut is incomplete when this is no.
    row["old_pod_post_access_lines"] = sum(1 for _, a in oacc if a["method"] == "POST")
    row["old_pod_access_lines_without_status"] = sum(1 for _, a in oacc if a["status"] == "<no-status>")
    row["old_pod_inflight_access_duration"] = "|".join(a["duration"] for _, a in oacc if a["status"] == "<no-status>") or "none"
    row["old_pod_get_access_lines"] = sum(1 for _, a in oacc if a["method"] == "GET")
    row["inflight_request_logged_by_old_pod"] = "yes" if any(a["method"] == "POST" for _, a in oacc) else "no"
    row["old_pod_access_shapes"] = " ".join(sorted({shape(a) for _, a in oacc})) or "none"
    t_sigterm = next((t for t, _, msg in oother if "received signal SIGTERM" in msg), None)
    row["rm_to_old_pod_sigterm_ms_h2c"] = ms(t_rm, t_sigterm)
    # The successor's Ready lastTransitionTime against the old pod's SIGTERM. It carries its clock suffix like
    # every other figure here: `_c2c` because both stamps are cluster-side, `_s1` because the API server's is at
    # ONE-SECOND resolution. That resolution is why the comparison is reported WITH its margin and is NOT read as
    # deciding the order: a second-resolution stamp is the floor of the true instant, so the true transition lies
    # anywhere in [lastTransitionTime, lastTransitionTime + 1 s), and whenever the margin below is under 1 000 ms
    # the SIGTERM falls inside that window and the pair resolves nothing. The half that IS decided is
    # `rm_to_deletionTimestamp_ms_h2c_s1` being absent for a rollout: the old pod had not been asked to stop when
    # the command returned.
    # WHAT `ready_lt_margin_resolves_the_order` DOES AND DOES NOT TEST (found in the B-5a review's second pass,
    # recorded and deliberately NOT fixed, so that the committed outputs still reproduce from this program).
    # It tests the SIGNED margin `t_sigterm - ready_lt` against one second, not its MAGNITUDE. That is right when
    # the SIGTERM is after the Ready stamp, which is the rollout case the entry cites it for: a margin of
    # 114.9-989.2 ms there is under the API stamp's one-second resolution and the order really is unresolved.
    # It is WRONG the other way: when the Ready stamp is more than a second AFTER the SIGTERM the margin is
    # negative, the column still reads "no", and yet the order IS resolved -- Ready came later, beyond any
    # resolution doubt. That happens in 16 of the 30 rows, all of them with margins of -2 221.3 to -1 061.2 ms,
    # and every one of the 16 is a graceful or a forced removal, none of them a rollout. The column is therefore
    # CONSERVATIVE: it never claims an order that the stamps do not carry, and it withholds one they do. The entry
    # cites it only for the ten rollout rows, where it is right. A corrected column would test abs(margin).
    if ready_lt is not None and t_sigterm is not None:
        row["successor_ready_lt_at_or_before_old_sigterm_c2c_s1"] = "yes" if ready_lt <= t_sigterm else "no"
        row["successor_ready_lt_to_old_sigterm_margin_ms_c2c_s1"] = ms(ready_lt, t_sigterm)
        row["ready_lt_margin_resolves_the_order"] = "no (margin under the 1 s stamp resolution)" if (t_sigterm - ready_lt) < 1_000_000_000 else "yes"
    else:
        row["successor_ready_lt_at_or_before_old_sigterm_c2c_s1"] = "n-a"
        row["successor_ready_lt_to_old_sigterm_margin_ms_c2c_s1"] = "n-a"
        row["ready_lt_margin_resolves_the_order"] = "n-a"
    # The drain decomposition, from the removed pod's own clock: SIGTERM to the line that says the drain began, to
    # the line that says the minimum drain is over, to the last line the pod wrote. The preparation's 6.2 is about
    # exactly these gaps.
    def firstmsg(sub):
        return next((t for t, _, msg in oother if sub in msg), None)
    t_drain = firstmsg("drain started, waiting")
    t_min = firstmsg("minimum drain completed")
    t_last = plog[-1][0] if plog else None
    row["sigterm_to_drain_started_ms_c2c"] = ms(t_sigterm, t_drain)
    row["drain_started_to_min_done_ms_c2c"] = ms(t_drain, t_min)
    row["min_done_to_last_log_ms_c2c"] = ms(t_min, t_last)
    row["sigterm_to_last_log_ms_c2c"] = ms(t_sigterm, t_last)
    row["old_pod_last_log"] = (plog[-1][2] if plog else "none").replace(",", ";")[:120]
    row["old_pod_log_lines_after_removal"] = len(after)
    row["old_pod_drain_lines"] = " | ".join(f"{lvl}:{msg}" for _, lvl, msg in after).replace(",", ";")[:900] or "none"
    row["drain_timeout_line"] = "yes" if any("drain timeout" in msg for _, _, msg in oother) else "no"
    row["rm_to_old_pod_first_log_after_ms_h2c"] = ms(t_rm, after[0][0] if after else None)
    row["rm_to_old_pod_last_log_ms_h2c"] = ms(t_rm, t_last)
    # The removed pod's own lifetime, which is what keeps a repetition informative when the cut itself was not
    # observable at this N: from the API server's deletionTimestamp to the last line the pod wrote (proxy clock) and
    # to the moment its object left the API (the driver's own observation, host clock); and the same from SIGTERM.
    row["deletion_to_old_pod_last_log_ms_c2c_s1"] = ms(del_ts, t_last)
    row["deletion_to_old_pod_gone_ms_h2c_s1"] = ms(del_ts, t_oldgone)
    row["sigterm_to_old_pod_gone_ms_h2c"] = ms(t_sigterm, t_oldgone)

    # --- the successor, and the ONE probe of the row's own kind -------------------------------------------------
    nlog = proxy_log(d, "newpod.log")
    nacc = [(t, a) for t, _, _, a in nlog if a]
    row["new_pod_first_served"] = shape(nacc[0][1]) if nacc else "none"
    row["rm_to_new_pod_first_served_ms_h2c"] = ms(t_rm, nacc[0][0] if nacc else None)
    row["new_pod_access_lines"] = len(nacc)
    t_probe_apply = at(st, "apply probe Job")
    row["probe_sent"] = "yes" if t_probe_apply is not None else "no"
    row["rm_to_probe_apply_ms_h2h"] = ms(t_rm, t_probe_apply)
    pend = [x for x in pcli if x.get("line") == "end"]
    p1 = pend[-1] if pend else {}
    row["probe_stream_end"] = p1.get("stream_end", "none")
    row["probe_terminal_seen"] = p1.get("terminal_seen", "none")
    row["probe_http"] = f"{p1.get('http_status', 'none')} {p1.get('content_type', '')}".strip()
    row["probe_error"] = (p1.get("error") or "").replace(",", " ") or "<none>"
    row["probe_wire_error"] = f"{p1.get('wire_error_code', 'none')}: {p1.get('wire_error_message', '')}".replace(",", " ")
    row["probe_posts"] = p1.get("posts", "none")
    row["probe_events"] = p1.get("events", "none")
    row["probe_invocations"] = len(pinv)
    row["probe_invocation_outcomes"] = "|".join(x.get("outcome", "") for x in pinv) or "none"
    row["probe_job"] = job_word(d, f"loadgen-{lwi}-p")
    # The probe is its own logical work item and is counted apart, so a probe arrival can never be read as Job 1's.
    row["probe_work_item"] = f"{lwi}-p"
    ping = [x for x in lines(os.path.join(d, "probe", "ingress.jsonl")) if x.get("source") == SOURCE]
    pexe = [x for x in lines(os.path.join(d, "probe", "execution.jsonl")) if x.get("source") == SOURCE]
    row["probe_arrivals"] = len([x for x in ping if x.get("phase") == "arrival"])
    row["probe_executes"] = len([x for x in pexe if x.get("event") == "execute"])
    pstates = sorted((x for x in pexe if x.get("event") == "state"), key=lambda x: ns(x["ts"]))
    row["probe_final_state"] = pstates[-1]["state"] if pstates else "none"
    row["probe_work_item_matches"] = "yes" if all(x.get("logical_work_item_id") in ("", f"{lwi}-p") for x in ping + pexe) else "no"
    t_probe_sent = nsq(p1.get("ts_sent"))
    row["rm_to_probe_sent_ms_h2c"] = ms(t_rm, t_probe_sent)
    row["rm_to_probe_end_ms_h2c"] = ms(t_rm, nsq(p1.get("ts")))

    # --- seconds from the removal command to what the stream did, per clock ------------------------------------
    t_sent = nsq(e1.get("ts_sent"))
    t_cend = nsq(e1.get("ts"))
    t_work = t_state.get("TASK_STATE_WORKING")
    t_term = min((v for k, v in t_state.items() if k in TERMINAL), default=None)
    t_ing_end = nsq((r1 or {}).get("ts_end"))
    t_exec_end = nsq(res1[0]["ts"]) if len(res1) == 1 else None
    t_inv = min((nsq(x.get("ts")) for x in inv_w if nsq(x.get("ts")) is not None), default=None)
    t_lastev = ns(ev[-1]["ts"]) if ev else None
    row["rm_to_client_stream_end_ms_h2c"] = ms(t_rm, t_cend)
    row["rm_to_client_last_event_ms_h2c"] = ms(t_rm, t_lastev)
    row["rm_to_ingress_ts_end_ms_h2c"] = ms(t_rm, t_ing_end)
    row["rm_to_exec_result_ms_h2c"] = ms(t_rm, t_exec_end)
    row["rm_to_terminal_state_ms_h2c"] = ms(t_rm, t_term)
    row["rm_to_invocation_line_ms_h2c"] = ms(t_rm, t_inv)
    row["sent_to_client_stream_end_ms_c2c"] = ms(t_sent, t_cend)
    row["working_to_terminal_ms_c2c"] = ms(t_work, t_term)
    row["client_end_to_ingress_end_ms_c2c"] = ms(t_cend, t_ing_end)
    row["client_end_to_exec_end_ms_c2c"] = ms(t_cend, t_exec_end)
    row["stream_open_at_removal"] = ("yes" if t_rm is not None and t_cend is not None and t_rm < t_cend else "no")

    # --- paths, and the redirect check --------------------------------------------------------------------------
    row["senders"] = "|".join(f"{a.get('method')}<-{sender(a.get('remote'))}" for a in arrivals) or "none"
    oth = access_file(d, "otherproxy-access.txt")
    row["other_proxy_lines"] = " ".join(f"{shape(a)}" for _, a in oth) or "none"
    non2xx = [shape(a) for _, a in oacc + nacc + oth if not a["status"].startswith("2")]
    row["non_2xx_access_lines"] = " ".join(non2xx) or "none"
    row["status_3xx_access_lines"] = " ".join(s for s in non2xx if s.rsplit(":", 1)[-1].startswith("3")) or "none"

    # --- agent pods, and the host's power events over this repetition's own window ------------------------------
    before = text_at(st, "agent pods before:")
    after_l = text_at(st, "agent pods after:")
    row["agent_pods_unchanged"] = "yes" if before and after_l and before.split("agent pods before:")[-1].strip() == after_l.split("agent pods after:")[-1].strip() else "no"
    row["agent_restarts"] = "|".join(sorted(set(re.findall(r"restarts=(\d+)", after_l)))) or "none"
    win = (st[0][0], st[-1][0]) if st else (None, None)
    inside = [k for t, k in SLEEP if win[0] is not None and win[0] <= t <= win[1]]
    row["sleep_affected"] = "yes" if inside else "no"
    # Every _h2c figure of this repetition joins a host stamp to a cluster stamp, so a host sleep inside the window
    # makes it not a number. The _c2c figures stay readable, and the tallies below are printed twice for this.
    row["h2c_figures_readable"] = "no" if inside else "yes"
    row["sleep_kinds_in_window"] = "|".join(inside) or "none"
    row["notes"] = ";".join(notes)
    return row


reps = []
for variant in sorted(os.listdir(ROWDIR)):
    vd = os.path.join(ROWDIR, variant)
    if not os.path.isdir(vd):
        continue
    ips = proxy_ips(vd)
    for lwi in sorted(os.listdir(vd)):
        d = os.path.join(vd, lwi)
        if os.path.isdir(d):
            reps.append(rep(variant, lwi, d, ips))
if not reps:
    sys.exit(f"no repetitions under {ROWDIR}")
cols = list(reps[0].keys())
with open(os.path.join(ROWDIR, "summary.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
    w.writeheader()
    for r in reps:
        w.writerow(r)
print(open(os.path.join(ROWDIR, "summary.csv")).read(), end="")
print(f"# tally, per variant (N={N_MS} ms): column=value xN, for every column but work_item and the per-repetition figures.")
print(f"# Each variant is tallied twice: over the CLEAN repetitions, and over ALL of them. Sleep events read from {SLEEPCSV or '<none given>'}.")
affected = [r["work_item"] for r in reps if r["sleep_affected"] == "yes"]
print("# sleep-affected repetitions: " + ("; ".join(affected) if affected else "none"))
print("# An _h2c figure of a sleep-affected repetition is NOT readable: it joins a host stamp to a cluster stamp.")
figures = {c for c in cols if c.endswith(("_h2h", "_h2c", "_c2c", "_h2c_s1"))} | {"invocation_latency_ms"}
freetext = {"old_pod_drain_lines", "old_pod_access_shapes", "other_proxy_lines", "non_2xx_access_lines",
            "client_error", "final_state_error", "probe_error", "new_pod_first_served", "old_pod_last_log"}
skip = {"work_item", "variant", "proxy", "method", "old_pod", "new_pod"} | figures | freetext
for variant in sorted({r["variant"] for r in reps}):
    for which in ("clean", "all"):
        rs = [r for r in reps if r["variant"] == variant and (which == "all" or r["sleep_affected"] == "no")]
        if not rs:
            continue
        print(f"## {variant}, {which}: {len(rs)} repetitions")
        for c in cols:
            if c in skip:
                continue
            vals = {}
            for r in rs:
                vals[str(r[c])] = vals.get(str(r[c]), 0) + 1
            print(f"  {c}: " + "; ".join(f"{k or '<empty>'} x{v}" for k, v in sorted(vals.items())))
        for c in sorted(freetext):
            vals = {}
            for r in rs:
                vals[str(r[c])[:300]] = vals.get(str(r[c])[:300], 0) + 1
            print(f"  {c}: " + " ;; ".join(f"{k} x{v}" for k, v in sorted(vals.items())))
        for c in sorted(figures):
            xs = [float(v) for r in rs for v in str(r[c]).split("|") if re.match(r"^-?\d", v)]
            if xs:
                print(f"  {c}: min {min(xs):.1f} max {max(xs):.1f} mean {sum(xs) / len(xs):.1f} over {len(xs)}")
            else:
                print(f"  {c}: no readable figure in {len(rs)} repetitions")
