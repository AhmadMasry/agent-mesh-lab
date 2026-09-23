#!/usr/bin/env bash
# Experiment C, step C-10: the row driver, kept in the run directory. The application layer: both agents refuse
# SubscribeToTask by REFUSE_OPERATION (agents/worker/refuse.go, agents/orchestrator/orchestrator/refuse.py), set on both
# Deployments together by kubectl set env for the row and restored empty by an EXIT trap, whatever ends the script.
#
#   bash c10.sh        RUNREL (the run directory's name) and N (sends per kind per receiver, at least 10) in the environment
#
# In order:
#   1. readings "before": both agents' pods (name, uid, restartCount, IP), the proxies' pod IPs, the setting on each
#      Deployment and in each running pod's spec, the ReplicaSets.
#   2. set: kubectl set env deployment/worker deployment/orchestrator REFUSE_OPERATION=SubscribeToTask, both rollouts
#      waited for; readings "set", including the worker's own start line, which names the value it read.
#   3. the row, on B-4's ingress paths, by C-6's sends.sh run from C-6's run directory, unedited (as C-7 and C-8 ran
#      it): per receiver, N rounds of the four kinds in turn -- load-client SendMessage (sm), load-client
#      SubscribeToTask naming no task (st), load-client SendStreamingMessage (ss), curl SubscribeToTask (cst).
#   4. the pads, by C-8's c8.sh probe run from C-8's run directory, unedited: ONE SubscribeToTask of 2 200 000 bytes per
#      receiver, the Go one with the pad in a top-level x_pad member (pad) and the Python one in params.tenant (padt),
#      as C-8 sent them (the controller's ruling: the Python x_pad form is refused by a2a-python's own validation).
#   5. the EXIT trap: REFUSE_OPERATION= on both Deployments, both rollouts waited for, readings "restored".
# The clean check after the restore is run by the caller, not here.
# One send at a time; nothing is re-sent; every curl --retry 0; no retry logic anywhere. A2A-Version 1.0 on every
# stimulus (the load client's own header; the curl sends set it).
# Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL="${RUNREL:?RUNREL is required}"
N="${N:?N is required}"
D="experiments/runs/$RUNREL"
C6=experiments/runs/2026-09-23-c6-httproute
C8=experiments/runs/2026-09-23-c8-body-rule
NS=lab
VALUE=SubscribeToTask
mkdir -p "$D" "${TMPDIR%/}/c8"
ts() { date -u +%FT%TZ; }
rec() {
	local f="$1"; shift
	{ printf '\n# read %s\n$ %s\n' "$(ts)" "$*"; bash -c "$*" 2>&1; printf '# exit %s\n' "$?"; } >> "$f"
}
readings() { # readings <label>
	local f="$D/readings-$1.txt"
	rec "$f" "kubectl -n $NS get pods -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[0].restartCount,IP:.status.podIP,READY:.status.containerStatuses[0].ready,START:.status.startTime --sort-by=.metadata.name"
	rec "$f" "kubectl -n agentgateway-ingress get pods -o wide --no-headers | awk '{print \$1, \$6}'"
	rec "$f" "kubectl -n agentgateway-waypoint get pods -o wide --no-headers | awk '{print \$1, \$6}'"
	rec "$f" "for d in worker orchestrator; do printf '%s deployment REFUSE_OPERATION=[%s] generation=%s\n' \$d \"\$(kubectl -n $NS get deploy \$d -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"REFUSE_OPERATION\")].value}')\" \"\$(kubectl -n $NS get deploy \$d -o jsonpath='{.metadata.generation}')\"; done"
	rec "$f" "for p in \$(kubectl -n $NS get pods -l 'app in (worker,orchestrator)' -o name); do printf '%s pod REFUSE_OPERATION=[%s] uid=%s restarts=%s\n' \$p \"\$(kubectl -n $NS get \$p -o jsonpath='{.spec.containers[0].env[?(@.name==\"REFUSE_OPERATION\")].value}')\" \"\$(kubectl -n $NS get \$p -o jsonpath='{.metadata.uid}')\" \"\$(kubectl -n $NS get \$p -o jsonpath='{.status.containerStatuses[0].restartCount}')\"; done"
	rec "$f" "kubectl -n $NS get rs -l 'app in (worker,orchestrator)' -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,REVISION:.metadata.annotations.deployment\\.kubernetes\\.io/revision"
	rec "$f" "kubectl -n $NS logs deploy/worker | grep 'listening on'"
	echo "$(ts) readings $1 -> $f" | tee -a "$D/phases.txt"
}
setting() { # setting <value>
	local v="$1" f="$D/setting.txt"
	echo "$(ts) set REFUSE_OPERATION=[$v] on deployment/worker and deployment/orchestrator" | tee -a "$D/phases.txt"
	rec "$f" "kubectl -n $NS set env deployment/worker deployment/orchestrator REFUSE_OPERATION=$v"
	rec "$f" "kubectl -n $NS rollout status deployment/worker --timeout=180s"
	rec "$f" "kubectl -n $NS rollout status deployment/orchestrator --timeout=180s"
	echo "$(ts) rollouts done for REFUSE_OPERATION=[$v]" | tee -a "$D/phases.txt"
}
restore() {
	trap - EXIT
	setting ""
	readings restored
	echo "$(ts) restored" | tee -a "$D/phases.txt"
}

echo "$(ts) c10 row driver start; HEAD $(git rev-parse HEAD); N=$N; sends.sh sha256 $(shasum -a 256 $C6/sends.sh | cut -d' ' -f1); c8.sh sha256 $(shasum -a 256 $C8/c8.sh | cut -d' ' -f1)" | tee -a "$D/phases.txt"
readings before
trap restore EXIT
trap 'exit 130' INT TERM
setting "$VALUE"
readings set

IMAGE=$(RUNREL="$RUNREL" bash "$C6/sends.sh" image | sed -n 's/.* image=\([^ ]*\) .*/\1/p')
[ -n "$IMAGE" ] || { echo "$(ts) no load client image; stopping" | tee -a "$D/phases.txt"; exit 1; }
export IMAGE
RUNREL="$RUNREL" bash "$C6/sends.sh" pod-up || { echo "$(ts) curl pod not up; stopping" | tee -a "$D/phases.txt"; exit 1; }

export RUNREL RUN_ID=c10
for recv in go py; do
	for n in $(seq 1 "$N"); do
		for kind in sm st ss cst; do
			bash "$C6/sends.sh" c10r "$kind" "$recv" "$n"
		done
	done
done
RUN_ID=c10 PAD_LEN=2200000 bash "$C8/c8.sh" probe c10p pad go 1
RUN_ID=c10 PAD_LEN=2200000 bash "$C8/c8.sh" probe c10p padt py 1
RUNREL="$RUNREL" bash "$C6/sends.sh" pod-down
echo "$(ts) sends done" | tee -a "$D/phases.txt"
# the EXIT trap restores the setting
