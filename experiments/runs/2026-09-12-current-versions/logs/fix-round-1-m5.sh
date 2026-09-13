#!/usr/bin/env bash
# Follow-ups 10 fix round 1 / M5: the curl-bumped scripts that had not run on 8.22.0, unedited, on the step-3 cluster.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-12-current-versions
SCR=<scratchpad>/5008ee34-eeb0-4d7c-a82b-45488493edbc/scratchpad
LOG=$SCR/m5.txt
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
item() {
	local label="$1"; shift; local s=$(date -u +%s)
	local st; st=$(git status --short -- deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)
	echo "## $label  started $(ts)  deployed-paths status: ${st:-(empty)}" >> "$LOG"
	echo "## \$ $*" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	echo "## $label  finished $(ts)  exit=$rc  wall=$(( $(date -u +%s) - s ))s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc wall=$(( $(date -u +%s) - s ))s"
}
retries() { echo "kubectl get httproute -A -o yaml | grep -c 'retry:' -> $(kubectl get httproute -A -o yaml | grep -c 'retry:')"; }
echo "# fix round 1 / M5, started $(ts), HEAD $(git rev-parse HEAD)" >> "$LOG"
item "retry stanzas before" retries
item "gateway retry mechanics waypoint" env ROUTE=waypoint REPS=5 RUN_ITEM=$RUNREL/gateway-retry-mechanics experiments/gate3-gateway-retry-mechanics.sh
item "retry stanzas after waypoint" retries
item "gateway retry mechanics ingress" env ROUTE=ingress REPS=5 RUN_ITEM=$RUNREL/gateway-retry-mechanics experiments/gate3-gateway-retry-mechanics.sh
item "retry stanzas after ingress" retries
item "gateway retry mechanics egress" env ROUTE=egress REPS=5 RUN_ITEM=$RUNREL/gateway-retry-mechanics experiments/gate3-gateway-retry-mechanics.sh
item "retry stanzas after egress" retries
item "three ledgers (worker Service, step 3 path)" env RUN_ITEM=$RUNREL/three-ledgers experiments/gate1-three-ledgers.sh
echo "# M5 finished $(ts)" >> "$LOG"
echo "$(ts) m5 done"
