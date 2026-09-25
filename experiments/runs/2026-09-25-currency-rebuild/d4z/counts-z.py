#!/usr/bin/env python3
# COPY for the currency pass of 2026-09-25 of experiments/runs/2026-09-25-d4-serviceaccounts/counts.py. One change: the
# work-item prefixes of Row Z name this run's RUN_ID (d4z-cur4z-) where the original names its own (d4z-z1-). Row A is
# not part of the approved rows, so this copy stops at its absent a/ directory after printing Row Z whole.
"""Follow-on D-4: every count the entries cite, from this run directory's files alone.

usage: python3 counts.py (from the checkout's top, or with the run directory as its argument) > counts.txt
Per work item: the client's own lines, and the three ledgers make ledgers collected by the work item's id (arrival
lines at each receiver, SDK received and executes, Tasks created, the last task state, model invocations). Per phase:
the enforcing layer's own record (ztunnel's connection lines, agentgateway's access lines, the authorizer's decision
lines), joined to the sends by the probe's pod address, the trace id or the window, as each phase names. No figure is
computed from an agentgateway access-line timestamp.
"""
import collections
import json
import os
import re
import sys

R = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))


def jl(p):
    if not os.path.exists(p):
        return None
    out = []
    for line in open(p):
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def ledgers(d):
    """The three ledgers of one work item; None where make ledgers found no line of any kind."""
    ing, exe, inv = jl(f"{d}/ingress.jsonl"), jl(f"{d}/execution.jsonl"), jl(f"{d}/invocation.jsonl")
    if ing is None and exe is None and inv is None:
        st = open(f"{d}/ledgers-stderr.txt").read() if os.path.exists(f"{d}/ledgers-stderr.txt") else ""
        return {"none": "no ledger lines of any kind" in st}
    ing, exe, inv = ing or [], exe or [], inv or []
    r = {}
    for src in ("worker", "orchestrator"):
        r[f"{src}_arrivals"] = sum(1 for x in ing if x.get("source") == src and x.get("phase") == "arrival")
        r[f"{src}_received"] = sum(1 for x in exe if x.get("source") == src and x.get("event") == "received")
        r[f"{src}_executes"] = sum(1 for x in exe if x.get("source") == src and x.get("event") == "execute")
        r[f"{src}_tasks"] = len({x.get("taskId") for x in exe if x.get("source") == src and x.get("event") == "state" and x.get("state") == "TASK_STATE_SUBMITTED"})
        st = [x.get("state") for x in exe if x.get("source") == src and x.get("event") == "state"]
        r[f"{src}_last_state"] = st[-1] if st else ""
    r["invocations"] = sum(1 for x in inv if x.get("outcome") != "stale-closed")
    r["remotes"] = sorted({re.sub(r":\d+$", "", x.get("remote", "")) for x in ing if x.get("phase") == "arrival"})
    return r


def line_fields(line, keys):
    out = {}
    for k in keys:
        m = re.search(r"(?:^|[\s\t])" + re.escape(k) + r'="?([^"\s\t]*)', line)
        out[k] = m.group(1) if m else ""
    return out


def items(phase, prefix):
    d = f"{R}/{phase}"
    return sorted(x for x in os.listdir(d) if x.startswith(prefix) and os.path.isdir(f"{d}/{x}"))


def show(label, rows):
    print(f"  {label}: {len(rows)} work items")
    c = collections.Counter(json.dumps(r, sort_keys=True) for r in rows)
    for k, v in sorted(c.items()):
        print(f"    {v} x {k}")


def curl_item(phase, lwi):
    d = f"{R}/{phase}/{lwi}"
    cl = jl(f"{d}/client.jsonl") or []
    r = {"client": [f"{x['op']}={x['http_status']}/exit{x['exit_code']}" for x in cl]}
    r.update(ledgers(d))
    return r


def job_item(phase, lwi):
    d = f"{R}/{phase}/{lwi}"
    cl = jl(f"{d}/client.jsonl") or []
    end = [x for x in cl if x.get("result_kind") is not None or x.get("error") is not None]
    e = end[-1] if end else {}
    r = {"client": f"{e.get('result_kind') or ''}/{e.get('state') or ''}" + (f" error={e['error']}" if e.get("error") else "")}
    r.update(ledgers(d))
    return r


print("# D-4 counts, from", os.path.basename(R))

# ---- Row Z ------------------------------------------------------------------------------------------------------
print("\n## Row Z: ztunnel ALLOW on principals at the worker (agw-central's and the orchestrator's identities)")
ph = open(f"{R}/z/phases.txt").read()
ips = dict(re.findall(r"probe up: (d4-as-\w+) sa=\w+ automount=\w+ ip=([\d.]+)", ph))
print(f"  probe pods: {ips}")
for label, pre in (("direct, as the orchestrator's account, policy in force", "d4z-cur4z-orch-"),
                   ("direct, as the load client's account, policy in force", "d4z-cur4z-lg-"),
                   ("the forward control (a load-client Job to the orchestrator's Service), policy in force", "d4z-cur4z-fwd-"),
                   ("direct, as the orchestrator's account, after removal", "d4z-cur4z-after-orch"),
                   ("direct, as the load client's account, after removal", "d4z-cur4z-after-lg")):
    show(label, [curl_item("z", x) if "fwd" not in pre else job_item("z", x) for x in items("z", pre)])
zl = [l for l in open(f"{R}/z/ztunnel-z-in-force.txt") if "connection complete" in l]
print("  ztunnel connection lines in the window, inbound to the worker's pod on its port 8080, by source address:")
rej = collections.Counter()
for l in zl:
    f = line_fields(l, ["src.addr", "src.identity", "dst.hbone_addr", "dst.identity", "direction", "error"])
    if f["direction"] != "inbound" or not f["dst.hbone_addr"].endswith(":8080"):
        continue
    src_ip = f["src.addr"].rsplit(":", 1)[0]
    who = {v: k for k, v in ips.items()}.get(src_ip, "other")
    kind = "policy-rejection" if "policy rejection" in l else ("error" if f["error"] else "ok")
    rej[(who, f["src.identity"], f["dst.identity"], kind)] += 1
for k, v in sorted(rej.items()):
    print(f"    {v} x {k}")
print(f"  every policy-rejection line in the window: {sum(1 for l in zl if 'policy rejection' in l)}, naming "
      f"{dict(collections.Counter(line_fields(l, ['src.identity'])['src.identity'] for l in zl if 'policy rejection' in l))}")
ac = collections.Counter()
for l in open(f"{R}/z/agw-central-access-z-in-force.txt"):
    f = line_fields(l, ["route", "src.identity", "http.path", "http.status"])
    ac[(f["route"], f["src.identity"], f["http.path"], f["http.status"])] += 1
print("  agw-central's access lines in the window (route, src.identity, path, status):")
for k, v in sorted(ac.items()):
    print(f"    {v} x {k}")

# ---- Row A ------------------------------------------------------------------------------------------------------
print("\n## Row A: agentgateway Allow on source.identity (lab/orchestrator) on agw-central's route lab/worker")
show("the load client's account to the worker Service", [job_item("a", x) for x in items("a", "d4a-a1-lg-")])
show("the load client's account to the orchestrator Service, forwarded by the orchestrator", [job_item("a", x) for x in items("a", "d4a-a1-fwd-")])
ac = collections.Counter()
for l in open(f"{R}/a/agw-central-access-a-in-force.txt"):
    f = line_fields(l, ["route", "src.identity", "http.method", "http.path", "http.status", "reason"])
    ac[(f["route"], f["src.identity"], f["http.method"], f["http.path"], f["http.status"], f["reason"])] += 1
print("  agw-central's access lines in the window (route, src.identity, method, path, status, reason):")
for k, v in sorted(ac.items()):
    print(f"    {v} x {k}")
ic = collections.Counter()
for l in open(f"{R}/a/ingress-access-a-in-force.txt"):
    f = line_fields(l, ["route", "http.path", "http.status"])
    ic[(f["route"], f["http.path"], f["http.status"])] += 1
print(f"  the ingress's access lines in the window: {dict(ic)}")

# ---- R2 ---------------------------------------------------------------------------------------------------------
print("\n## R2: the ingress's source.identity and source.unverifiedWorkload (NOT cryptographically authenticated)")
ph = open(f"{R}/r2/phases.txt").read()
ips = dict(re.findall(r"probe up: (d4-as-\w+) sa=\w+ automount=\w+ ip=([\d.]+)", ph))
print(f"  probe pods: {ips}")
for label, pre in (("load client's account, x-d4-probe: verified, worker-ingress", "d4r-r1-lg-verified-go-"),
                   ("load client's account, x-d4-probe: verified, orchestrator-ingress", "d4r-r1-lg-verified-py-"),
                   ("load client's account, x-d4-probe: unverified, worker-ingress", "d4r-r1-lg-unverified-go-"),
                   ("load client's account, x-d4-probe: unverified, orchestrator-ingress", "d4r-r1-lg-unverified-py-"),
                   ("orchestrator's account, x-d4-probe: unverified, worker-ingress", "d4r-r1-orch-unverified-go-")):
    show(label, [curl_item("r2", x) for x in items("r2", pre)])
ic = collections.Counter()
for l in open(f"{R}/r2/ingress-access-r2-in-force.txt"):
    f = line_fields(l, ["route", "src.addr", "src.identity", "http.status", "reason"])
    ip = f["src.addr"].rsplit(":", 1)[0]
    ic[(f["route"], {v: k for k, v in ips.items()}.get(ip, ip), f["src.identity"] or "<no src.identity>", f["http.status"], f["reason"])] += 1
print("  the ingress's access lines in the window (route, source address as the probe pod it is, src.identity, status, reason):")
for k, v in sorted(ic.items()):
    print(f"    {v} x {k}")

# ---- the authorizer's source principal ----------------------------------------------------------------------------
print("\n## the ingress's ext-authz source principal, D-3's overlay re-applied from its record")
show("go path (the ingress, Host worker.lab.internal)", [job_item("xa", x) for x in items("xa", "d4x-x1-go-")])
show("py path (the orchestrator's Service, the card through agw-central, the POST through the ingress)", [job_item("xa", x) for x in items("xa", "d4x-x1-py-")])
dl = jl(f"{R}/xa/extauthz-decisions.jsonl") or []
print(f"  decision lines: {len(dl)}; (binding, http_method, decision, source_principal): "
      f"{dict(collections.Counter((x.get('binding'), x.get('http_method'), x.get('decision'), x.get('source_principal') or '<empty>') for x in dl))}")

# ---- the header reading ---------------------------------------------------------------------------------------------
print("\n## the header reading (D-1's headers.sh, unedited, from its record)")
for app in ("worker", "orchestrator"):
    a = [x for x in (jl(f"{R}/headers/{app}-ingress.jsonl") or []) if x.get("phase") == "arrival" and x.get("headers")]
    names = collections.Counter(n for x in a for n in x["headers"]["names"])
    vals = collections.Counter(f"{k}={v}" for x in a for k, v in x["headers"].get("values", {}).items())
    print(f"  {app}: {len(a)} arrivals carrying the reading; names {dict(sorted(names.items()))}")
    print(f"    values {dict(sorted(vals.items()))}")
    print(f"    authorization_present {dict(collections.Counter(x['headers'].get('authorization_present') for x in a))}; "
          f"remote {dict(collections.Counter(re.sub(r':[0-9]+$', '', x.get('remote', '')) for x in a))}")

# ---- the clean checks ------------------------------------------------------------------------------------------------
print("\n## the clean checks")
for d in ("clean-check", "after"):
    print(f"  {d}/summary.csv:")
    for line in open(f"{R}/{d}/summary.csv"):
        print("    " + line.rstrip())
print("  after/hop-lines, the closing clean check's window:")
zc = collections.Counter()
for l in open(f"{R}/after/hop-lines/ztunnel-connections.txt"):
    f = line_fields(l, ["direction", "src.workload", "src.identity", "dst.service", "dst.identity"])
    zc[(f["direction"], re.sub(r"-[a-z0-9]{5}$", "", f["src.workload"]), f["src.identity"] or "-", f["dst.service"], f["dst.identity"] or "-")] += 1
print("    ztunnel connection lines (direction, source workload, src.identity, dst.service, dst.identity):")
for k, v in sorted(zc.items()):
    print(f"      {v} x {k}")
for f_, keys in (("agw-central-access.txt", ["route", "src.identity", "http.path", "http.status"]),
                 ("ingress-access.txt", ["route", "src.identity", "http.path", "http.status"])):
    c = collections.Counter(tuple(line_fields(l, keys)[k] or "-" for k in keys) for l in open(f"{R}/after/hop-lines/{f_}"))
    print(f"    {f_} ({', '.join(keys)}):")
    for k, v in sorted(c.items()):
        print(f"      {v} x {k}")
