"""Experiment B, step B-5b: the counts of the removal-and-resubscription rows, one CSV line per repetition.

    python3 counts.py <rows dir> <N_ms> [<sleep events csv>]   writes <rows dir>/summary.csv and prints it with a
                                                               tally per variant over the clean repetitions and
                                                               another over all of them

Every repetition directory under <rows dir>/<variant>/<work item>/ holds ingress.jsonl, execution.jsonl,
invocation.jsonl and client.jsonl (make ledgers, Job 1's client lines), client-sub.jsonl (Job 2's own client lines),
steps.txt and removal.txt (the driver's stamped steps and its removal record), jobs.txt, oldpod.log (the removed
pod's own log, captured from before the removal), newpod.log (the successor's), otherproxy-access.txt (the proxy that
stayed up), successor.txt. <variant>/control.txt names the proxy pods and their IPs.

This program is B-5a's counts.py (the removal, drain, successor and clock columns) with B-4's Job 2 columns
(the one SubscribeToTask) put back beside them, which is exactly what this step is: B-5a's stimulus with B-4's
resubscription after it. What is new against both: a receiver dimension (B-5a had one receiver); the proxy POD that
answered each request, old or successor, rather than only which proxy; and whether the Task was still running when
Job 2's request ARRIVED, from parsed stamps joined on identity.

THE CLOCKS, as B-5a named them -- every interval column's name ends in the pair it joins:
  _h2h  both stamps the driver's own, on the HOST clock (the removal command, its own observations);
  _h2c  one HOST stamp joined to one cluster-side stamp: the removal command or one of the driver's own
        observations against a client pod, a receiver pod, the mock, a proxy pod or the API server. These are the
        only figures a host/VM clock difference or a host sleep can reach, and a repetition a sleep touched reports
        them as not readable;
  _c2c  both stamps from inside the cluster, which no host clock jump can reach.
The API-server stamps (deletionTimestamp, creationTimestamp, Ready lastTransitionTime) have SECOND resolution and
are marked _s1.

The standing B rules, as this program keeps them, unchanged from B-4 and B-5a:
  - every stamp is PARSED to integer nanoseconds, never compared as text;
  - ingress and execution lines are joined on identity -- a send by its messageId, a subscription by its taskId, an
    ingress response line to its arrival by (method, JSON-RPC id, ts_arrival) -- never on line order;
  - the final state is the executor's last `state` line for the task by parsed stamp, not the execution result
    line's state (which on a streamed dispatch is the FIRST Task's);
  - a `delivered` line is what the SDK handed to its stream writer, not what reached the client: it is reported
    beside the client's own events, never instead of them;
  - every invocation line is counted and reported, stale-closed included; none is filtered;
  - a repetition is marked sleep-affected when a host power event of the four kinds (sleep-events.csv, kinds and
    stamps only) falls inside that repetition's own window, from its first stamped step to its last.

THE REDIRECT CHECK (the B-4 review's carry, which B-5a carried and this step carries again). internal/httpclient.New
leaves CheckRedirect at Go's default, so a 3xx would be followed and CLIENT_HOST re-applied to the next request, and
no test pins that at this tree. A removed proxy is when a gateway is likeliest to answer non-2xx, so every
repetition reports what BOTH of its clients actually saw -- the status, the content type, the JSON-RPC error on the
wire, the SDK's error text -- the POST round trips each client's own outermost transport carried (a followed
redirect is a second round trip), and every non-2xx status in any access line collected. Reads files only.
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROWDIR, N_MS = sys.argv[1], int(sys.argv[2])
SLEEPCSV = sys.argv[3] if len(sys.argv) > 3 else ""
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


def nsq(s):
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
    m = re.search(re.escape(key) + r"=(\S*)", text or "")
    return m.group(1) if m else ""


PLINE = re.compile(r"^(\S+)\t(\S+)\t(.*)$")
# http.status is OPTIONAL, and that is a reading rather than a convenience (B-5a): when a removal cuts a request
# before any response head exists, the proxy still writes that request's access line and the line carries NO
# http.status field at all. A regex that required the field dropped exactly the line that says what the removal cut,
# so it is optional here and an absent one is reported as "<no-status>".
ACCESS = re.compile(r"route=(\S+) endpoint=(\S+) src\.addr=(\S+) .*?http\.method=(\S+) http\.host=(\S+) http\.path=(\S+)(?: .*?http\.status=(\S+))?.*?duration=(\S+)")


def _acc(am):
    route, endpoint, src, method, host, path, status, duration = am.groups()
    return {"route": route, "endpoint": endpoint, "src": src, "method": method, "host": host,
            "path": path, "status": status or "<no-status>", "duration": duration}


# A PROXY-LOG STAMP THIS LAB HAS ALREADY FILED AGAINST, AND WHAT IT DOES TO A FIGURE HERE.
# agentgateway at the pinned v1.5.0 renders the sub-second part of a log timestamp with its leading zeros REMOVED,
# so 21:03:04.066706Z is written 21:03:04.66706Z and reads, as written, 600 ms later than it was.
# docs/upstream/agentgateway-access-log-timestamp-leading-zeros.md: filed as agentgateway#3369, fixed by #3370, and
# the first release containing the fix is the v1.6.0-alpha.1 prerelease -- v1.5.0, the release this lab pins, carries
# the defect. Measured, it falls ONLY on the access line's own stamp, and the figures below are the FINAL corpus,
# named by scope. Over the 80 COUNTED repetitions: 47 of 400 access lines (11.75 %, which is the 1/10 + 1/100 + ...
# a uniform microsecond field gives) against 0 of 1 986 other proxy lines, with 240 of the 2 339 six-digit
# fractions ending in a zero. Over the WHOLE committed run directory, the two dry repetitions included: 47 of 410
# against 0 of 2 036, with 242 of 2 399 ending in a zero. The numerators are identical in both scopes, so naming
# the population moves no reading. Trailing zeros are therefore NOT dropped and a fraction shorter than six digits
# means leading zeros were.
# (An earlier version of this comment carried the mid-run reading -- 25 of 222, 0 of 1 103 and 132 -- taken when the
# defect was found, half way through the Go ingress row, under words that claimed the whole corpus. The figures
# above replace it. This is a COMMENT-ONLY change: the four committed outputs reproduce byte-identically from this
# program before and after it, which the record commit's report shows.)
# TWO CONSEQUENCES, both taken here rather than papered over:
#   (1) the lines are kept in the order the proxy WROTE them -- file order, which is what `kubectl logs` gives --
#       and not sorted by a stamp that can be wrong by up to 900 ms;
#   (2) a figure whose endpoint is such a stamp is reported as "n-a", never as a number, the way a sleep-affected
#       interval is. The raw stamps are kept verbatim in `dropped_zero_stamps` so the record holds what the proxy
#       actually wrote, and NOTHING is corrected here: correcting it would be this program deciding what the proxy
#       meant.
# It reaches only figures that END at an access line: the successor's first access line, and the removed pod's last
# log line when that last line is an access line. Every other figure in this program comes from a cluster ledger
# stamp (Go RFC3339Nano or Python isoformat) or from a non-access proxy line, none of which carries the defect.
SHORTFRAC = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.(\d+)Z$")


def short_fraction(stamp):
    m = SHORTFRAC.match(stamp or "")
    return bool(m) and len(m.group(1)) < 6


def proxy_log(d, name):
    """[(ns, level, message, access-dict-or-None, short, raw-stamp)] for one proxy pod's own log, in FILE ORDER."""
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
        am = ACCESS.search(m.group(3))
        out.append((t, m.group(2), m.group(3), _acc(am) if am else None, short_fraction(m.group(1)), m.group(1)))
    return out


def access_file(d, name):
    """The other proxy's collected access lines, same shape as proxy_log's access entries, in FILE ORDER."""
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
                out.append((t, _acc(am), short_fraction(m.group(1)), m.group(1)))
    return out


def figt(entry):
    """The stamp of a proxy log entry when it can be read as written, None when its leading zeros were dropped."""
    if entry is None:
        return None
    return None if entry[4] else entry[0]


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
    recv, proxy, method = variant.split("-", 2)
    src = SOURCE[recv]
    ips = dict(ips0)
    pods = {}  # ip -> pod name, from this repetition's own readings
    name = "ingress" if proxy == "ingress" else "agw-central"
    p = os.path.join(d, "steps.txt")
    if os.path.exists(p):
        for raw in open(p):
            if "proxy pods before:" in raw or "proxy pods after:" in raw:
                for pod, ip in PODIP.findall(raw):
                    ips.setdefault(ip, name)
                    pods[ip] = pod
            elif "other proxy pods:" in raw:
                for pod, ip in PODIP.findall(raw):
                    pods.setdefault(ip, pod)
                    ips.setdefault(ip, "agw-central" if pod.startswith("agw-central") else "ingress")
    ing = lines(os.path.join(d, "ingress.jsonl"))
    exe = lines(os.path.join(d, "execution.jsonl"))
    inv = lines(os.path.join(d, "invocation.jsonl"))
    cli = lines(os.path.join(d, "client.jsonl"))
    sub = lines(os.path.join(d, "client-sub.jsonl"))
    st = stamped(d, "steps.txt")
    rm = stamped(d, "removal.txt")
    notes = []

    oldline = text_at(st, "old pod:")
    old_pod = oldline.split()[2] if len(oldline.split()) > 2 else ""
    newf = os.path.join(d, "successor.txt")
    new_pod = (open(newf).read().strip() if os.path.exists(newf) else "")

    def sender(remote):
        """Which proxy POD sent this arrival: the one that was removed, its successor, or the other proxy."""
        ip = (remote or "").rsplit(":", 1)[0]
        pod = pods.get(ip)
        if pod and old_pod and pod == old_pod:
            return f"{ips.get(ip, '?')}-OLD"
        if pod and new_pod and pod == new_pod:
            return f"{ips.get(ip, '?')}-SUCCESSOR"
        return ips.get(ip, "other:" + ip)

    mine = [x for x in ing if x.get("source") == src]
    other = [x for x in ing if x.get("source") != src and x.get("phase") == "arrival"]
    if other:
        notes.append(f"arrivals_at_the_other_agent={len(other)}")
    arrivals = sorted((x for x in mine if x.get("phase") == "arrival"), key=lambda x: ns(x["ts_arrival"]))
    responses = [x for x in mine if x.get("phase") == "response"]

    def arrivals_of(m):
        return [x for x in arrivals if x.get("method") == m]

    def response_of(a):
        m = [r for r in responses if a and r.get("method") == a.get("method") and r.get("id") == a.get("id")
             and ns(r["ts_arrival"]) == ns(a["ts_arrival"])]
        return m[0] if len(m) == 1 else None

    ex = [x for x in exe if x.get("source") == src]
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

    row = {"variant": variant, "receiver": recv, "proxy": proxy, "method": method, "work_item": lwi}

    # --- Job 1: the one open stream ---------------------------------------------------------------------------
    send = arrivals_of("SendStreamingMessage")
    row["arrivals_SendStreamingMessage"] = len(send)
    row["arrivals_other_methods"] = "|".join(sorted({a.get("method") for a in arrivals} - {"SendStreamingMessage", "SubscribeToTask"})) or "none"
    a1 = send[0] if len(send) == 1 else None
    row["received_joined"] = len([x for x in ex if x.get("event") == "received" and a1 and x.get("messageId") == a1.get("messageId")])
    row["executes"] = len(executes)
    row["tasks"] = len(tasks)
    row["a2a_version"] = "|".join(sorted({a.get("a2a_version", "") for a in arrivals})) or "none"
    r1 = response_of(a1)
    row["ingress_status"] = (r1 or {}).get("status", "none")
    row["ingress_stream_end"] = (r1 or {}).get("stream_end", "none")
    res1 = [x for x in ex if x.get("event") == "result" and a1 and x.get("messageId") == a1.get("messageId")]
    row["exec_stream_end"] = res1[0].get("stream_end", "none") if len(res1) == 1 else f"lines={len(res1)}"
    row["exec_result_error"] = (res1[0].get("error", "") if len(res1) == 1 else "").replace(",", " ") or "<no error key>"

    ev = sorted((x for x in cli if x.get("line") == "event"), key=lambda x: ns(x["ts"]))
    end1 = [x for x in cli if x.get("line") == "end"]
    e1 = end1[-1] if end1 else {}
    row["client_events"] = e1.get("events", "none")
    row["client_kinds"] = "|".join(f"{x.get('kind')}/{x.get('state') or ''}".rstrip("/") for x in ev) or "none"
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

    # --- the Task and the model call --------------------------------------------------------------------------
    row["final_state"] = final_state
    row["final_state_error"] = (e_state.get(final_state, "") or "<none>").replace(",", " ")[:160]
    row["states"] = "|".join(s["state"] for s in states) or "none"
    inv_w = [x for x in inv if x.get("logical_work_item_id") == lwi]
    row["invocations"] = len(inv_w)
    row["invocation_outcomes"] = "|".join(x.get("outcome", "") for x in inv_w) or "none"
    row["invocation_latency_ms"] = "|".join(f"{x.get('latency_ms', 0):.1f}" for x in inv_w) or "none"
    row["invocation_task_matches"] = "yes" if inv_w and all(x.get("taskId") == task for x in inv_w) else "no"

    # --- Job 2: the ONE SubscribeToTask, and what it reattached to ---------------------------------------------
    subs = arrivals_of("SubscribeToTask")
    row["arrivals_SubscribeToTask"] = len(subs)
    a2 = subs[-1] if subs else None
    row["sub_requested_task"] = (sub[-1].get("requested_task_id") if sub else "") or "none"
    row["sub_arrival_task_matches_job1"] = "yes" if a2 and a2.get("taskId") == task and task else "no"
    row["received_sub_joined"] = len([x for x in ex if x.get("event") == "received" and a2 and x.get("taskId") == a2.get("taskId")
                                      and x.get("method") == "SubscribeToTask"])
    r2 = response_of(a2)
    row["ingress_sub_status"] = (r2 or {}).get("status", "none")
    row["ingress_sub_stream_end"] = (r2 or {}).get("stream_end", "none")
    res2 = [x for x in ex if x.get("event") == "result" and x.get("method") == "SubscribeToTask" and x.get("taskId") == task]
    row["exec_sub_stream_end"] = res2[0].get("stream_end", "none") if len(res2) == 1 else f"lines={len(res2)}"
    dl2 = sorted((x for x in ex if x.get("event") == "delivered" and x.get("method") == "SubscribeToTask" and x.get("taskId") == task),
                 key=lambda x: ns(x["ts"]))
    row["sub_first_delivered"] = f"{dl2[0].get('result_kind')}/{dl2[0].get('state') or 'none'}" if dl2 else "none"
    ev2 = sorted((x for x in sub if x.get("line") == "event"), key=lambda x: ns(x["ts"]))
    end2 = [x for x in sub if x.get("line") == "end"]
    e2 = end2[-1] if end2 else {}
    row["sub_sent"] = "yes" if sub else "no"
    row["client2_first"] = f"{e2.get('first_kind') or 'none'}/{e2.get('first_state') or 'none'}"
    row["client2_first_task_matches_job1"] = "yes" if e2.get("first_task_id") == task and task else "no"
    row["client2_reattached_task"] = e2.get("first_task_id") or "none"
    row["client2_events"] = e2.get("events", "none")
    row["client2_kinds"] = "|".join(f"{x.get('kind')}/{x.get('state') or ''}".rstrip("/") for x in ev2) or "none"
    row["client2_terminal_seen"] = e2.get("terminal_seen", "none")
    row["client2_stream_end"] = e2.get("stream_end", "none")
    row["client2_http"] = e2.get("http_status", "none")
    row["client2_content_type"] = e2.get("content_type", "none")
    row["client2_wire_error"] = f"{e2.get('wire_error_code', 'none')}: {e2.get('wire_error_message', '')}".replace(",", " ")
    row["client2_sdk_error"] = (e2.get("error") or "").replace(",", " ") or "<none>"
    row["client2_posts"] = e2.get("posts", "none")
    row["client2_dialled_host"] = f"{e2.get('dialled_url', 'none')} {e2.get('host', '<no host key>')}"
    row["job2"] = job_word(d, f"loadgen-{lwi}-s")

    # --- the removal ------------------------------------------------------------------------------------------
    row["old_pod"] = old_pod or "none"
    row["old_pod_grace_s"] = field(oldline, "grace")
    row["new_pod"] = new_pod or "none"
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
    # What the driver read of Job 1's stream at the instant it applied Job 2. It differs between the two rows BY
    # DESIGN and is the reason this step uses a different removal on each: on the ingress row the forced delete has
    # already ended Job 1's stream (B-5a: 35.6-43.3 ms after the command) long before the successor is Ready, while
    # on the agw-central row the graceful delete leaves that stream open and carrying events until the Task fails.
    row["job1_stream_at_job2_apply"] = text_at(rm, "JOB 1 STREAM AT THIS MOMENT:").replace("JOB 1 STREAM AT THIS MOMENT: ", "") or "n-a"

    # --- the removed pod's own log: its access lines and its drain lines ---------------------------------------
    plog = proxy_log(d, "oldpod.log")
    oacc = [(t, a) for t, _, _, a, _sh, _rs in plog if a]
    oother = [(t, lvl, msg) for t, lvl, msg, a, _sh, _rs in plog if not a]
    after = [(t, lvl, msg) for t, lvl, msg in oother if t_rm is None or t >= t_rm]
    row["old_pod_access_lines"] = len(oacc)
    # Did the removed pod write an access line for the request it was CARRYING when it was cut? On the ingress that
    # request is Job 1's streamed POST; on agw-central it is the model POST. B-5a found an operator's record of the
    # cut request incomplete in three different ways -- no line at all, a line with no status, or a line reading 200
    # for a stream the client saw fail -- so all three readings are columns here.
    row["old_pod_post_access_lines"] = sum(1 for _, a in oacc if a["method"] == "POST")
    row["old_pod_get_access_lines"] = sum(1 for _, a in oacc if a["method"] == "GET")
    row["inflight_request_logged_by_old_pod"] = "yes" if any(a["method"] == "POST" for _, a in oacc) else "no"
    row["old_pod_access_lines_without_status"] = sum(1 for _, a in oacc if a["status"] == "<no-status>")
    row["old_pod_inflight_access_duration"] = "|".join(a["duration"] for _, a in oacc if a["status"] == "<no-status>") or "none"
    row["old_pod_post_access_statuses"] = "|".join(a["status"] for _, a in oacc if a["method"] == "POST") or "none"
    row["old_pod_access_shapes"] = " ".join(sorted({shape(a) for _, a in oacc})) or "none"
    t_sigterm = next((t for t, _, msg in oother if "received signal SIGTERM" in msg), None)
    row["rm_to_old_pod_sigterm_ms_h2c"] = ms(t_rm, t_sigterm)

    def firstmsg(subm):
        return next((t for t, _, msg in oother if subm in msg), None)
    t_drain = firstmsg("drain started, waiting")
    t_min = firstmsg("minimum drain completed")
    t_last = figt(plog[-1]) if plog else None
    row["sigterm_to_drain_started_ms_c2c"] = ms(t_sigterm, t_drain)
    row["drain_started_to_min_done_ms_c2c"] = ms(t_drain, t_min)
    row["min_done_to_last_log_ms_c2c"] = ms(t_min, t_last)
    row["sigterm_to_last_log_ms_c2c"] = ms(t_sigterm, t_last)
    row["old_pod_last_log"] = (plog[-1][2] if plog else "none").replace(",", ";")[:120]
    row["old_pod_log_lines_after_removal"] = len(after)
    row["drain_timeout_line"] = "yes" if any("drain timeout" in msg for _, _, msg in oother) else "no"
    row["rm_to_old_pod_last_log_ms_h2c"] = ms(t_rm, t_last)
    row["deletion_to_old_pod_gone_ms_h2c_s1"] = ms(del_ts, t_oldgone)
    row["sigterm_to_old_pod_gone_ms_h2c"] = ms(t_sigterm, t_oldgone)

    # --- the successor, and which request it answered -----------------------------------------------------------
    nlog = proxy_log(d, "newpod.log")
    nacc = [(t, a, sh) for t, _, _, a, sh, _rs in nlog if a]
    # WHAT THIS FIGURE IS, AND WHAT IT IS NOT, read off the first dry repetition. A proxy writes a request's access
    # line when the request ENDS, not when it begins, and Job 2 is a subscription that stays open until the Task
    # reaches a terminal state. So on this step `rm_to_new_pod_first_served_ms_h2c` is the moment the successor
    # FINISHED carrying Job 2, about 43 s on the ingress row -- it is NOT "seconds until the successor serves", which
    # is what the same column meant in B-5a, where the probe was a short stream of its own. The figure that answers
    # "when did the successor first carry a request" on this step is `rm_to_sub_arrival_ms_h2c`: the arrival's own
    # ts_arrival on the receiver's ingress ledger, which the successor had to forward for it to exist. The entry
    # cites that one, and this column is kept beside it as the proxy's own record of the same request.
    row["new_pod_first_served"] = shape(nacc[0][1]) if nacc else "none"
    row["rm_to_new_pod_first_served_ms_h2c"] = ms(t_rm, (None if nacc[0][2] else nacc[0][0]) if nacc else None)
    row["new_pod_access_lines"] = len(nacc)
    row["new_pod_access_shapes"] = " ".join(shape(a) for _t, a, _sh in nacc) or "none"
    t_apply2 = at(st, "apply Job 2")
    t_applied2 = at(st, "Job 2 applied")
    row["rm_to_job2_apply_ms_h2h"] = ms(t_rm, t_apply2)
    row["job2_apply_ms_h2h"] = ms(t_apply2, t_applied2)

    # --- seconds from the removal command to what each stream did, per clock ------------------------------------
    t_sent = nsq(e1.get("ts_sent"))
    t_cend = nsq(e1.get("ts"))
    t_work = t_state.get("TASK_STATE_WORKING")
    t_term = min((v for k, v in t_state.items() if k in TERMINAL), default=None)
    t_ing_end = nsq((r1 or {}).get("ts_end"))
    t_exec_end = nsq(res1[0]["ts"]) if len(res1) == 1 else None
    t_inv = min((nsq(x.get("ts")) for x in inv_w if nsq(x.get("ts")) is not None), default=None)
    t_lastev = ns(ev[-1]["ts"]) if ev else None
    t_arr2 = ns(a2["ts_arrival"]) if a2 else None
    t_cend2 = nsq(e2.get("ts"))
    t_sent2 = nsq(e2.get("ts_sent"))
    row["rm_to_client_stream_end_ms_h2c"] = ms(t_rm, t_cend)
    row["rm_to_client_last_event_ms_h2c"] = ms(t_rm, t_lastev)
    row["rm_to_ingress_ts_end_ms_h2c"] = ms(t_rm, t_ing_end)
    row["rm_to_exec_result_ms_h2c"] = ms(t_rm, t_exec_end)
    row["rm_to_terminal_state_ms_h2c"] = ms(t_rm, t_term)
    row["rm_to_invocation_line_ms_h2c"] = ms(t_rm, t_inv)
    row["rm_to_sub_arrival_ms_h2c"] = ms(t_rm, t_arr2)
    row["rm_to_sub_stream_end_ms_h2c"] = ms(t_rm, t_cend2)
    row["sent_to_client_stream_end_ms_c2c"] = ms(t_sent, t_cend)
    row["working_to_terminal_ms_c2c"] = ms(t_work, t_term)
    row["client_end_to_ingress_end_ms_c2c"] = ms(t_cend, t_ing_end)
    row["client_end_to_exec_end_ms_c2c"] = ms(t_cend, t_exec_end)
    row["job1_end_to_sub_arrival_ms_c2c"] = ms(t_cend, t_arr2)
    row["job2_sent_to_sub_arrival_ms_c2c"] = ms(t_sent2, t_arr2)
    row["working_to_sub_arrival_ms_c2c"] = ms(t_work, t_arr2)
    row["sub_arrival_to_terminal_ms_c2c"] = ms(t_arr2, t_term)
    row["stream_open_at_removal"] = ("yes" if t_rm is not None and t_cend is not None and t_rm < t_cend else "no")
    # The question the row exists to answer, from PARSED stamps joined on identity and never from order: was the
    # Task still running when Job 2's request ARRIVED at the receiver? Both stamps are cluster-side (_c2c): the
    # arrival's own ts_arrival on the receiver's ingress ledger, and the executor's terminal state line.
    row["task_running_at_sub_arrival"] = (
        "yes" if t_work is not None and t_arr2 is not None and t_term is not None and t_work <= t_arr2 < t_term
        else "no" if t_arr2 is not None and t_term is not None else "n-a")
    row["sub_arrival_after_job1_stream_end"] = ("yes" if t_cend is not None and t_arr2 is not None and t_cend <= t_arr2
                                                else "no" if t_cend is not None and t_arr2 is not None else "n-a")

    # --- paths, and the redirect check --------------------------------------------------------------------------
    row["senders"] = "|".join(f"{a.get('method')}<-{sender(a.get('remote'))}" for a in arrivals) or "none"
    oth = access_file(d, "otherproxy-access.txt")
    row["other_proxy_lines"] = " ".join(shape(a) for _t, a, _sh, _rs in oth) or "none"
    allacc = [a for _t, a in oacc] + [a for _t, a, _sh in nacc] + [a for _t, a, _sh, _rs in oth]
    non2xx = [shape(a) for a in allacc if not a["status"].startswith("2")]
    row["access_lines_collected"] = len(allacc)
    row["non_2xx_access_lines"] = " ".join(non2xx) or "none"
    row["status_3xx_access_lines"] = " ".join(s for s in non2xx if s.rsplit(":", 1)[-1].startswith("3")) or "none"
    # The access-line stamps of THIS repetition that agentgateway#3369 makes unreadable as written, counted and kept
    # verbatim. A figure that ends at one of them reads "n-a" above; nothing is corrected.
    dropped = [rs for _t, _l, _m, a, sh, rs in plog if sh] + [rs for _t, _l, _m, a, sh, rs in nlog if sh] \
        + [rs for _t, _a, sh, rs in oth if sh]
    row["access_stamps_with_dropped_leading_zero"] = len(dropped)
    row["dropped_zero_stamps"] = "|".join(dropped) or "none"

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
figures = {c for c in cols if c.endswith(("_h2h", "_h2c", "_c2c", "_h2c_s1", "_c2c_s1"))} | {"invocation_latency_ms"}
freetext = {"old_pod_access_shapes", "new_pod_access_shapes", "other_proxy_lines", "non_2xx_access_lines",
            "client_error", "client2_sdk_error", "final_state_error", "new_pod_first_served", "old_pod_last_log",
            "client2_reattached_task", "sub_requested_task", "dropped_zero_stamps"}
skip = {"work_item", "variant", "receiver", "proxy", "method", "old_pod", "new_pod"} | figures | freetext
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
