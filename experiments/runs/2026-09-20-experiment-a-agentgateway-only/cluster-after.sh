#!/usr/bin/env bash
# Follow-ups 19, task 4b: the state the cluster is left in after the Experiment A re-run. Reads only:
# kubectl get / logs, helm list and istioctl; nothing is created, changed or deleted. $1 = output file.
# experiments/runs/2026-09-19-worker-span-rebuild/cluster-after.sh (REBUILD-2's) with this header and the paragraph
# about the two receivers' injectors rewritten for this task's rows; every other line is that script's. That script
# was experiments/runs/2026-09-19-currency-rebuild/cluster-after.sh with its header and that paragraph rewritten, and
# the count of the worker's own log lines about a close-after-read that failed added.
set -uo pipefail
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
echo "# The cluster as this task leaves it, read $(ts). Reads only."
echo "== $(ts) Gateways and HTTPRoutes =="
echo "gateways: $(kubectl get gateway -A --no-headers | grep -c '') ; httproutes: $(kubectl get httproute -A --no-headers | grep -c '')"
echo "== $(ts) retry stanzas: across every HTTPRoute, and per route =="
echo "kubectl get httproute -A -o yaml | grep -c 'retry:' -> $(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)"
kubectl get httproute -A -o json | python3 -c 'import json,sys
for r in json.load(sys.stdin)["items"]:
    print("  %s/%s retry_stanzas=%d" % (r["metadata"]["namespace"], r["metadata"]["name"], sum(1 for rule in r["spec"].get("rules", []) if "retry" in rule)))'
echo "== $(ts) the mock's mode: its own control lines; an inject arms, a reset clears, the last line decides =="
CTRL=$(kubectl -n lab logs deploy/mockllm --tail=-1 | grep '"ledger":"control"' || true)
echo "control lines since the mock started: $(printf '%s\n' "$CTRL" | grep -c 'control'); injects: $(printf '%s\n' "$CTRL" | grep -c '/control/inject'); resets: $(printf '%s\n' "$CTRL" | grep -c '/control/reset')"
echo "the last inject: $(printf '%s\n' "$CTRL" | grep '/control/inject' | tail -1)"
echo "the last line:   $(printf '%s\n' "$CTRL" | tail -1)"
echo "resets after the last inject: $(printf '%s\n' "$CTRL" | awk '/\/control\/inject/{n=0} /\/control\/reset/{n++} END{print n+0}')"
echo "== $(ts) the two receivers' injectors =="
echo "  (a receiver writes no LEDGER line for a control call and holds its armed mode in process memory, so there is no mode to read"
echo "   back from it. What there is: the rows of this task that arm a receiver are A.2's and A.3's R1, R2 and R4 rows; each script"
echo "   resets the injectors it armed itself and records the 204s in its own run directory (control.txt / control-reset.txt), and"
echo "   the last invocation of this task, A.3 R4 py service, is one of them. The worker's process log, which is not a ledger, prints a"
echo "   line only for a close-after-read that could NOT take its connection or could not close it (agents/worker/ingress.go); a taken"
echo "   and closed connection prints none. Such lines:)"
echo "  worker log lines naming close-after-read: $(kubectl -n lab logs deploy/worker --tail=-1 | grep -v '^{' | grep -ci 'close-after-read' || true)"
echo "== $(ts) every Deployment in lab: env names starting MODEL_, CLIENT_, DOWNSTREAM_ or PLAN_; generation, ready =="
kubectl -n lab get deploy -o json | python3 -c 'import json,sys
for d in json.load(sys.stdin)["items"]:
    for c in d["spec"]["template"]["spec"]["containers"]:
        e = ["%s=%s" % (x["name"], x.get("value", "")) for x in c.get("env", []) if x["name"].startswith(("MODEL_", "CLIENT_", "DOWNSTREAM_", "PLAN_"))]
        print("  deploy/%s generation=%s ready=%s/%s: %s" % (d["metadata"]["name"], d["metadata"]["generation"], d["status"].get("readyReplicas", 0), d["spec"]["replicas"], " ".join(e) or "(none)"))'
echo "== $(ts) pods: every namespace, phase counts; pods neither Running nor Succeeded; control pods left =="
kubectl get pods -A --no-headers | awk '{c[$4]++} END{for (k in c) printf "  %s=%d\n", k, c[k]}' | sort
echo "pods neither Running nor Completed: $(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | grep -c '' || true)"
echo "pods of a curl image (the scripts' control and probe pods): $(kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c 'curlimages/curl' || true)"
echo "loadgen Jobs left in lab (each a finished single send, kept for its pod log): $(kubectl -n lab get jobs --no-headers | grep -c '^loadgen-' || true)"
kubectl -n lab get pods -o custom-columns=POD:.metadata.name,PHASE:.status.phase,RESTARTS:'.status.containerStatuses[0].restartCount',STARTED:.status.startTime --no-headers | grep -v '^loadgen-'
echo "== $(ts) helm releases =="
helm list -A -o json | python3 -c 'import json,sys; [print("  %-20s %-20s %-10s %s" % (r["name"], r["namespace"], r["status"], r["chart"])) for r in json.load(sys.stdin)]'
echo "== $(ts) ztunnel's certificates, worker node =="
istioctl ztunnel-config certificates --node agent-mesh-lab-worker
} > "$1" 2>&1
echo "wrote $1"
