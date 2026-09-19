#!/usr/bin/env python3
"""DRY_RUN simulator for driver.sh: canned readings for every cluster and power command.

It is a test fixture, not a measurement. It models hypothesis H so the driver's branches and the
derive script can be exercised with a known answer:

  - the guest is frozen during every applied gap (DRY_DIR/gaps-applied: "<start> <end>" host epochs);
  - the guest's wall clock is stepped to the host's STEP_LAG seconds after a gap ends;
  - ztunnel's refresh of a leaf issued at wall time w by a process anchored at time a needs
    ttl/2 - 60 + D(w) seconds of guest running time after w, where D(w) is the frozen time
    accumulated between a and w  (t - D(t) = R, research.md 1b);
  - SIM_LATE seconds are added to every refresh (the p1fail scenario: the model is wrong awake).

State lives in DRY_DIR/sim.json. The fake host clock is DRY_DIR/now, advanced by driver.sh.
Scenarios (DRY_SCENARIO) that change the simulator's behaviour: restorefail, p1fail.
"""
import hashlib
import json
import os
import sys
import time

DRY = os.environ["DRY_DIR"]
SCEN = os.environ.get("DRY_SCENARIO", "normal")
STATE = os.path.join(DRY, "sim.json")
STEP_LAG = 12
BACKDATE = 120
BOOT_AGE = 86400 * 3          # the VM booted three days before the fake start
NODES = {
    "agent-mesh-lab-worker": [
        "spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress",
        "spiffe://cluster.local/ns/lab/sa/default",
    ],
    # as in the lab's committed readings: no captured workload runs on the control-plane node, so its
    # ztunnel holds no certificate and istioctl prints the header line only
    "agent-mesh-lab-control-plane": [],
}
COMMITTED = {"env": {"SECRET_TTL": "168h"}, "profile": "ambient"}
OVERRIDE = {"env": {"SECRET_TTL": "10m"}, "logLevel": "info,ztunnel::identity=debug", "profile": "ambient"}
STANDARD_RUST_LOG = "info"      # the chart renders RUST_LOG from its logLevel value, "info" by default


def now():
    return int(open(os.path.join(DRY, "now")).read().strip())


def gaps():
    out = []
    p = os.path.join(DRY, "gaps-applied")
    if os.path.exists(p):
        for line in open(p):
            if line.strip():
                s, e = line.split()
                out.append((int(s), int(e)))
    return sorted(out)


def frozen(t, g):
    """Guest-frozen seconds accumulated by host time t."""
    return sum(min(e, t) - s for s, e in g if s < t)


def lag(t, g):
    """How far the guest's wall clock is behind the host's at host time t (before the step)."""
    for s, e in g:
        if e <= t < e + STEP_LAG:
            return e - s
    return 0


def fire_time(issued, run_needed, g):
    """Host time at which `run_needed` seconds of guest running time have passed since `issued`."""
    t, need = issued, run_needed
    for s, e in g:
        if e <= t:
            continue
        if s > t:
            if need <= s - t:
                return t + need
            need -= s - t
        t = max(t, e)
    return t + need


def ttl_seconds(v):
    n, u = int(v[:-1]), v[-1]
    return n * {"h": 3600, "m": 60, "s": 1}[u]


def serial(*parts):
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()[:32]


def load():
    return json.load(open(STATE))


def save(st):
    tmp = STATE + ".tmp"
    json.dump(st, open(tmp, "w"), indent=1)
    os.replace(tmp, STATE)


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def issue(st, node, ident, t, g):
    gw = t - lag(t, g)                      # istiod stamps with the guest's wall clock
    st["leaves"][node][ident].append({"serial": serial(node, ident, t, st["gen"]), "issued": t,
                                      "nb": gw - BACKDATE, "na": gw + st["ttl"]})
    st["csr"] += 1
    st["issues"].append([t, node, ident, st["debug"]])


def restart(st, t, g):
    st["gen"] += 1
    st["anchor"] = t
    st["pods"] = {n: "ztunnel-" + serial(n, st["gen"])[:5] for n in NODES}
    st["pod_started"] = iso(t - lag(t, g))
    for node, ids in NODES.items():
        for ident in ids:
            st["leaves"][node][ident] = []
            issue(st, node, ident, t, g)


def catch_up(st):
    t, g = now(), gaps()
    late = int(os.environ.get("SIM_LATE", "20" if SCEN == "p1fail" else "0"))
    for node, ids in st["leaves"].items():
        for ident, leaves in ids.items():
            while True:
                last = leaves[-1]
                d_at_issue = frozen(last["issued"], g) - frozen(st["anchor"], g)
                need = st["ttl"] // 2 - 60 + d_at_issue + late
                ft = fire_time(last["issued"], need, g)
                if ft > t:
                    break
                issue(st, node, ident, ft, g)
    return t, g


def main():
    cmd = sys.argv[1]
    if cmd == "init":
        if not os.path.exists(STATE):
            t = now()
            st = {"ttl": ttl_seconds("168h"), "debug": False, "values": COMMITTED, "env_rust_log": None,
                  "gen": 0, "anchor": t, "boot": t - BOOT_AGE, "csr": 40, "issues": [], "helm_rev": 2, "probe_pod": False,
                  "leaves": {n: {} for n in NODES}, "pods": {}, "pod_started": ""}
            restart(st, t - 3600, [])
            save(st)
        return 0
    st = load()
    t, g = catch_up(st)
    rc = 0
    if cmd == "certs":
        node = sys.argv[2]
        print("CERTIFICATE NAME                                                          TYPE     STATUS        VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE")
        for ident in sorted(st["leaves"].get(node, {})):
            lf = st["leaves"][node][ident][-1]
            valid = "true" if lf["nb"] < t < lf["na"] else "false"
            print(f"{ident:<73} Leaf     Available     {valid:<14} {lf['serial']}     {iso(lf['na'])}     {iso(lf['nb'])}")
            print(f"{ident:<73} Root     Available     true           8a11b9ae6a8150b4780be9481f3b07f5     2036-09-09T17:53:50Z     2026-09-12T17:53:50Z")
    elif cmd == "clock":
        boot = st["boot"]
        wall = t - lag(t, g)
        mono = t - boot - frozen(t, g)
        print(f"{wall}.101000000,{mono * 10**9 + 102000000},{mono}.10,{wall}.104000000")
    elif cmd == "metrics":
        print("# HELP citadel_server_csr_count The number of CSRs received by Citadel server.")
        print("# TYPE citadel_server_csr_count counter")
        print(f"citadel_server_csr_count {st['csr']}")
        print("citadel_server_root_cert_expiry_timestamp 2.1046e+09")
        print(f"citadel_server_success_cert_issuance_count {st['csr']}")
        print("pilot_xds 7")
    elif cmd == "probe":
        lf = st["leaves"]["agent-mesh-lab-worker"]["spiffe://cluster.local/ns/lab/sa/default"][-1]
        if not st["probe_pod"]:
            print("Error from server (NotFound): pods \"zt-probe\" not found", file=sys.stderr)
            rc = 1
        elif lf["nb"] < t < lf["na"]:
            print("200,0.011482")
        else:
            print("000,0.004101")
            rc = 56
    elif cmd == "ztunnel-pods":
        for node in sorted(NODES):
            print(f"{node} {st['pods'][node]} {st['pod_started']} 0")
    elif cmd == "istiod-pod":
        print("istiod-7c9d8b6f5d-x2k4q 0")
    elif cmd == "ds-env":
        print("CA_ADDRESS=istiod.istio-system.svc:15012")
        print("ISTIO_META_ENABLE_HBONE=true")
        print(f"SECRET_TTL={st['values']['env']['SECRET_TTL']}")
        print(f"RUST_LOG={st['env_rust_log'] or STANDARD_RUST_LOG}")
        print("RUST_BACKTRACE=1")
    elif cmd == "pods-env":
        for node in sorted(NODES):
            env = f"CA_ADDRESS=istiod.istio-system.svc:15012;RUST_LOG={st['env_rust_log'] or STANDARD_RUST_LOG};SECRET_TTL={st['values']['env']['SECRET_TTL']};"
            print(f"{st['pods'][node]} {env}")
    elif cmd == "ds-status":
        print(f"2 2 2 2 {st['helm_rev']} {st['helm_rev']}")
    elif cmd == "log-filter":
        for node in sorted(NODES):
            f = "hickory_server::server=off," + (st["env_rust_log"] or "info")
            print(f"{st['pods'][node]}.istio-system:\ncurrent log level is {f}\n")
    elif cmd == "logs":
        which = sys.argv[2]
        if "istiod" in which:
            print(f"{iso(t)} info\tRootCertRotator\tRoot cert is not about to expire, skipping root cert rotation.")
        else:
            node = next((n for n in NODES if st["pods"][n] in which), None)
            print(f"{st['pod_started']} info ztunnel version fixture")
            for ts, n, ident, dbg in st["issues"]:
                if n == node and dbg and ts >= st["anchor"]:
                    print(f"{iso(ts)} {iso(ts)}\tdebug\tidentity::manager\tcertificate fetch succeeded id={ident}")
    elif cmd == "helm-upgrade":
        what = sys.argv[2]
        st["helm_rev"] += 1
        if what == "override":
            st["values"], st["ttl"], st["debug"], st["env_rust_log"] = OVERRIDE, 600, True, OVERRIDE["logLevel"]
        else:
            st["values"], st["ttl"], st["debug"], st["env_rust_log"] = COMMITTED, ttl_seconds("168h"), False, None
            if SCEN == "restorefail":           # the release says restored, the workload does not
                st["debug"], st["env_rust_log"] = True, OVERRIDE["logLevel"]
        restart(st, t, g)
        print(f"Release \"ztunnel\" has been upgraded. Happy Helming!\nREVISION: {st['helm_rev']}")
    elif cmd == "restart":
        restart(st, t, g)
        print("daemonset.apps/ztunnel restarted")
    elif cmd == "helm-values":
        print(json.dumps(st["values"]))
    elif cmd == "helm-history":
        print("REVISION\tUPDATED\tSTATUS\tCHART\tAPP VERSION\tDESCRIPTION")
        for r in range(1, st["helm_rev"] + 1):
            print(f"{r}\tfixture\t{'deployed' if r == st['helm_rev'] else 'superseded'}\tztunnel-1.31.0\t1.31.0\tUpgrade complete")
    elif cmd == "helm-pull":
        os.makedirs(sys.argv[2], exist_ok=True)
        open(os.path.join(sys.argv[2], "ztunnel-1.31.0.tgz"), "w").write("fixture\n")
    elif cmd == "probe-pod-phase":
        print("Running" if st["probe_pod"] else "", end="")
    elif cmd == "probe-pod-create":
        st["probe_pod"] = True
        print("pod/zt-probe created")
    elif cmd == "probe-pod-delete":
        st["probe_pod"] = False
        print("pod \"zt-probe\" deleted")
    else:
        print(f"sim: unknown subcommand {cmd}", file=sys.stderr)
        rc = 98
    save(st)
    return rc


if __name__ == "__main__":
    sys.exit(main())
