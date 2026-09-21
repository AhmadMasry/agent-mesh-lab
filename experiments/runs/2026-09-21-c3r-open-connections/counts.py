#!/usr/bin/env python3
"""C-3R counts, from this run directory alone: one row per repetition directory
(<scope>-<n>/), written to counts.csv and printed. Reads only the files rep.sh wrote:
readings.txt (every reading, parsed by its '# read' / '$' / '# exit' lines), events.txt,
nc-received.txt (via responses.py), nc-exit.txt, istiod.txt and ztunnel.txt.

Columns:
  client_port        the client's own port for the held connection (ztunnel's outbound record)
  ztunnel_inbound    ztunnel's inbound record for it on the server (the key its tracking uses)
  server_remote      the server's r.RemoteAddr on request 1 (its ingress ledger)
  push_apply         istiod's push to the worker node's ztunnel for the apply: WDS size / WADS size
  push_remove        the same for the removal
  zt_scope           the scope ztunnel holds the policy under
  wl_list_after      the server's policy list in ztunnel after the apply
  rbac_update        ztunnel's "handling RBAC update" stamp
  watcher_lines      ztunnel lines "closed because it's no longer allowed after a policy update"
  watcher_at         the stamp of the first such line
  late_close_lines   ztunnel inbound lines with error="connection closed due to policy change"
  sock_before_r2     the client socket's state in the last netstat read before request 2
  r2_on_held         what request 2 on the held connection got
  server_arrivals_held  arrivals at the server on server_remote (1 = request 1 only, 2 = both)
  held_responses     complete HTTP responses nc received on the held connection
  held_outbound_close  ztunnel's outbound close line for the held connection (error, if any)
  held_outbound_close_at  that line's stamp (cluster clock)
  r2_server_arrival  the server's arrival stamp of request 2 on the held connection, if it arrived
  r2_after_rbac_ms   r2_server_arrival (or, if it never arrived, held_outbound_close_at) minus
                     rbac_update, in ms, both on the cluster's clock
  new_conn           the new-connection control: curl exit code and ztunnel's inbound line
  server_arrivals_other  arrivals at the server on any other remote in the repetition
  ap_after_remove    `kubectl get authorizationpolicy -A` after the removal
"""
import csv
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def readings(path):
    out, cur = [], None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = re.match(r"^# read (\S+)$", line)
        if m:
            cur = {"stamp": m.group(1), "cmd": None, "out": [], "exit": None}
            out.append(cur)
            continue
        if cur is None:
            continue
        if cur["cmd"] is None and line.startswith("$ "):
            cur["cmd"] = line[2:]
            continue
        m = re.match(r"^# exit (\d+)$", line)
        if m:
            cur["exit"] = int(m.group(1))
            continue
        cur["out"].append(line)
    return out


def responses(path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "responses.py"), path], capture_output=True, text=True, check=True)
    return r.stdout.strip()


def field(line, name):
    m = re.search(name + r'=("([^"]*)"|(\S+))', line)
    return None if not m else (m.group(2) if m.group(2) is not None else m.group(3))


def row(d):
    scope, n = os.path.basename(d).rsplit("-", 1)
    rd = readings(os.path.join(d, "readings.txt"))
    conns = [r for r in rd if r["cmd"].startswith("istioctl ztunnel-config connections")]
    # the first connections read after request 1 holds the held connection
    held = None
    for r in conns:
        objs = [json.loads(l) for l in r["out"] if l.startswith("{")]
        cl = next((o for o in objs if o["pod"] == "c3r-client"), None)
        sv = next((o for o in objs if o["pod"].startswith("c3r-server")), None)
        if cl and cl["outbound"] and sv and sv["inbound"]:
            held = (cl["outbound"][0]["src"], sv["inbound"][0]["src"])
            break
    client_port = held[0] if held else ""
    zt_in = held[1] if held else ""

    ledger = []
    for r in rd:
        if r["cmd"].startswith("kubectl -n c3r logs"):
            ledger = [json.loads(l) for l in r["out"] if l.startswith("{")]
    arrivals = [l for l in ledger if l.get("phase") == "arrival"]
    server_remote = arrivals[0]["remote"] if arrivals else ""
    on_held = sum(1 for l in arrivals if l["remote"] == server_remote)
    other = sum(1 for l in arrivals if l["remote"] != server_remote)

    zt_scope = wl_after = ap_after = ""
    for r in rd:
        if r["cmd"].startswith("istioctl ztunnel-config policy") and "select(.namespace" in r["cmd"]:
            txt = "\n".join(r["out"])
            m = re.search(r'"scope": "(\w+)"', txt)
            zt_scope = m.group(1) if m else ""
        if r["cmd"].startswith("istioctl ztunnel-config workloads") and "uid" in r["cmd"]:
            for l in r["out"]:
                if l.startswith("{") and '"c3r-server' in l:
                    wl_after = "|".join(json.loads(l)["authorizationPolicies"])
    ap_reads = [r for r in rd if r["cmd"] == "kubectl get authorizationpolicy -A"]
    if len(ap_reads) > 1:
        ap_after = " ".join(ap_reads[-1]["out"])

    # the last netstat before request 2: the client socket for client_port. rec.sh stamps
    # are to the second, so the order is taken from the file, not the stamp: rep.sh writes
    # request 2 after its last pre-send netstat read and before the new-connection curl read.
    ev = open(os.path.join(d, "events.txt"), encoding="utf-8").read().splitlines()
    r2_not = next((l for l in ev if " r2 NOT written" in l), None)
    sock = ""
    port = client_port.split(":")[-1] if client_port else None
    curl_at = next(i for i, r in enumerate(rd) if " curl " in r["cmd"])
    for r in rd[:curl_at]:
        if r["cmd"].endswith("netstat -tn") and port:
            for l in r["out"]:
                parts = l.split()
                if len(parts) >= 6 and parts[3].endswith(":" + port) and parts[4].endswith(":8080"):
                    sock = parts[5]

    zt = open(os.path.join(d, "ztunnel.txt"), encoding="utf-8").read().splitlines()
    rbac = next((l.split("\t")[0] for l in zt if "handling RBAC update" in l), "")
    watcher = [l for l in zt if "no longer allowed after a policy update" in l]
    late = [l for l in zt if 'error="connection closed due to policy change"' in l and 'direction="inbound"' in l]
    out_close = out_close_at = ""
    for l in zt:
        if 'direction="outbound"' in l and client_port and field(l, "src.addr") == client_port:
            out_close = field(l, "error") or "no error"
            out_close_at = l.split("\t")[0]
    newc = next((r for r in rd if " curl " in r["cmd"]), None)
    new_port = ""
    if newc:
        m = re.search(r"local_port=(\d+)", "\n".join(newc["out"]))
        new_port = m.group(1) if m else ""
    new_zt = ""
    for l in zt:
        if 'direction="outbound"' in l and new_port and field(l, "src.addr", ).endswith(":" + new_port):
            new_zt = field(l, "error") or "no error"
    new_in = ""
    # the inbound line of the refused new connection is the rejection line in the window after r2
    rej = [l for l in zt if "connection closed due to policy rejection" in l and 'direction="inbound"' in l]
    if rej:
        new_in = "inbound: " + field(rej[-1], "error")
    new_conn = (f"curl exit {newc['exit']}" if newc else "") + (f"; ztunnel outbound: {new_zt}" if new_zt else "") + (f"; {new_in}" if new_in else "")

    held_arr = [l for l in arrivals if l["remote"] == server_remote]
    r2_arr = held_arr[1]["ts_arrival"] if len(held_arr) > 1 else ""

    def t(x):
        # RFC 3339 to seconds of the day, enough for differences inside one repetition
        m = re.search(r"T(\d\d):(\d\d):(\d\d(?:\.\d+)?)Z", x)
        return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    ref = r2_arr or out_close_at
    r2_after = f"{(t(ref) - t(rbac)) * 1000:.0f}" if (ref and rbac) else ""
    held_resp = responses(os.path.join(d, "nc-received.txt"))
    if r2_not:
        r2 = "not written: " + r2_not.split("r2 NOT written: ")[1]
    elif on_held >= 2:
        r2 = "delivered"
    else:
        r2 = "not delivered"

    push_apply = push_remove = ""
    ist = os.path.join(d, "istiod.txt")
    if os.path.exists(ist):
        pushes = []  # (debounce index, kind, size)
        idx = -1
        for l in open(ist, encoding="utf-8"):
            if "Push debounce stable" in l and "AuthorizationPolicy/c3r/" in l:
                idx += 1
            m = re.search(r"(WDS|WADS): PUSH for node:ztunnel-sdq6z\S* resources:(\d+) removed:(\d+) size:(\S+)", l)
            if m and idx >= 0:
                pushes.append((idx, m.group(1), m.group(4)))
        def fmt(i):
            wds = next((s for j, k, s in pushes if j == i and k == "WDS"), "none")
            wads = next((s for j, k, s in pushes if j == i and k == "WADS"), "none")
            return f"WDS {wds} / WADS {wads}"
        push_apply, push_remove = fmt(0), fmt(1)

    return {
        "scope": scope, "n": n,
        "client_port": client_port, "ztunnel_inbound": zt_in, "server_remote": server_remote,
        "push_apply": push_apply, "push_remove": push_remove,
        "zt_scope": zt_scope, "wl_list_after": wl_after,
        "rbac_update": rbac, "watcher_lines": len(watcher),
        "watcher_at": watcher[0].split("\t")[0] if watcher else "",
        "late_close_lines": len(late), "sock_before_r2": sock, "r2_on_held": r2,
        "server_arrivals_held": on_held, "held_responses": held_resp,
        "held_outbound_close": out_close, "held_outbound_close_at": out_close_at,
        "r2_server_arrival": r2_arr, "r2_after_rbac_ms": r2_after, "new_conn": new_conn,
        "server_arrivals_other": other, "ap_after_remove": ap_after,
    }


def key(d):
    s, n = os.path.basename(d).rsplit("-", 1)
    return ({"none": 0, "selector": 1, "namespace": 2}[s], int(n))


rows = [row(d) for d in sorted(glob.glob(os.path.join(HERE, "*-[0-9]")), key=key)]
with open(os.path.join(HERE, "counts.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()), lineterminator="\n")
w.writeheader()
w.writerows(rows)
