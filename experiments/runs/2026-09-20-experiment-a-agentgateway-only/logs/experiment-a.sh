#!/usr/bin/env bash
# Follow-ups 19, task 4b: the Experiment A re-run on the rebuilt step-3 cluster of the topology of 2026-09-19, with the
# committed scripts unedited, each item into its own directory under
# experiments/runs/2026-09-20-experiment-a-agentgateway-only/.
# Usage: experiment-a.sh <a1|a2|a3>   -- one invocation at a time, in the committed order.
# experiments/runs/2026-09-12-current-versions/logs/experiment-a.sh (follow-ups 10), changed in: this header; RUNREL
# and SCR; the three Service-addressed Python rows of the proposal note of 2026-09-19 appended to phase a3 after the
# sixteen rows of 2026-09-12, in that order; and the rule on a failing item. That driver recorded a failing item and
# moved on; this one records it and STOPS the phase (the brief of task 4b: keep its log, tell the controller, a whole
# invocation may be re-run by its script once, as attempt 2) -- so no later invocation runs on a cluster a failure may
# have left changed. When the phase ends, for any reason, its last line is "# phase <p> finished <stamp> exit=<rc>".
# No retry anywhere here: every invocation runs once. Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-20-experiment-a-agentgateway-only
SCR=<scratchpad>/2965f467-038d-4709-a812-d7d51f83c94f/scratchpad/proof
PHASE="$1"
LOG=$SCR/logs/experiment-a-$PHASE.txt
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
finish() { echo "# phase $PHASE finished $(ts) exit=$1" >> "$LOG"; echo "$(ts) phase $PHASE done exit=$1"; exit "$1"; }
item() { # label, env assignments..., then -- script
	local label="$1"; shift; local s=$(date -u +%s)
	local st; st=$(git status --short -- deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)
	echo "## $label  started $(ts)  deployed-paths status: ${st:-(empty)}" >> "$LOG"
	echo "## \$ $*" >> "$LOG"
	env "$@" >> "$LOG" 2>&1; local rc=$?
	echo "## $label  finished $(ts)  exit=$rc  wall=$(( $(date -u +%s) - s ))s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc wall=$(( $(date -u +%s) - s ))s"
	if [ "$rc" -ne 0 ]; then echo "## STOP: $label exited $rc; no later invocation of this phase runs" >> "$LOG"; finish "$rc"; fi
}
echo "# Experiment A re-run, phase $PHASE, started $(ts), HEAD $(git rev-parse HEAD)" >> "$LOG"
case "$PHASE" in
a1)
	for m in M1 M2 M3; do for r in go py; do
		lm=$(echo "$m" | tr 'M' 'm')
		item "A.1 $m $r" MODE=$m RECEIVER=$r REPS=20 RUN_ITEM=$RUNREL/a1-$lm-$r experiments/gate2-a1.sh
	done; done ;;
a2)
	item "A.2 go http"            CLIENT=go LAYER=http REPS=20 RUN_ITEM=$RUNREL/a2-go-http experiments/gate2-a2.sh
	item "A.2 go sdk"             CLIENT=go LAYER=sdk REPS=20 RUN_ITEM=$RUNREL/a2-go-sdk experiments/gate2-a2.sh
	item "A.2 py http retries"    CLIENT=py LAYER=http PY_HTTP_KNOB=retries REPS=20 RUN_ITEM=$RUNREL/a2-py-http-retries experiments/gate2-a2.sh
	item "A.2 py http resend"     CLIENT=py LAYER=http PY_HTTP_KNOB=resend REPS=20 RUN_ITEM=$RUNREL/a2-py-http-resend experiments/gate2-a2.sh
	item "A.2 py sdk"             CLIENT=py LAYER=sdk REPS=20 RUN_ITEM=$RUNREL/a2-py-sdk experiments/gate2-a2.sh
	item "A.2 go http 503"        CLIENT=go LAYER=http RETRY_ON=transport+503 REPS=20 RUN_ITEM=$RUNREL/a2-go-http-503 experiments/gate2-a2.sh
	item "A.2 py http resend 503" CLIENT=py LAYER=http PY_HTTP_KNOB=resend RETRY_ON=transport+503 REPS=20 RUN_ITEM=$RUNREL/a2-py-http-resend503 experiments/gate2-a2.sh ;;
a3)
	item "A.3 baseline go"   RUN=baseline RECEIVER=go REPS=20 RUN_ITEM=$RUNREL/a3-baseline-go experiments/gate3-matrix.sh
	item "A.3 baseline py"   RUN=baseline RECEIVER=py REPS=20 RUN_ITEM=$RUNREL/a3-baseline-py experiments/gate3-matrix.sh
	item "A.3 R1 go http"    RUN=R1 RECEIVER=go SUB=http REPS=20 RUN_ITEM=$RUNREL/a3-r1-go-http experiments/gate3-matrix.sh
	item "A.3 R1 go sdk"     RUN=R1 RECEIVER=go SUB=sdk REPS=20 RUN_ITEM=$RUNREL/a3-r1-go-sdk experiments/gate3-matrix.sh
	item "A.3 R1 py http"    RUN=R1 RECEIVER=py SUB=http REPS=20 RUN_ITEM=$RUNREL/a3-r1-py-http experiments/gate3-matrix.sh
	item "A.3 R1 py sdk"     RUN=R1 RECEIVER=py SUB=sdk REPS=20 RUN_ITEM=$RUNREL/a3-r1-py-sdk experiments/gate3-matrix.sh
	item "A.3 R2 go waypoint" RUN=R2 RECEIVER=go SUB=waypoint REPS=20 RUN_ITEM=$RUNREL/a3-r2-go-waypoint experiments/gate3-matrix.sh
	item "A.3 R2 go ingress" RUN=R2 RECEIVER=go SUB=ingress REPS=20 RUN_ITEM=$RUNREL/a3-r2-go-ingress experiments/gate3-matrix.sh
	item "A.3 R2 py ingress" RUN=R2 RECEIVER=py SUB=ingress REPS=20 RUN_ITEM=$RUNREL/a3-r2-py-ingress experiments/gate3-matrix.sh
	item "A.3 R2 py ingress-incluster" RUN=R2 RECEIVER=py SUB=ingress-incluster REPS=20 RUN_ITEM=$RUNREL/a3-r2-py-ingress-incluster experiments/gate3-matrix.sh
	item "A.3 R3 go"         RUN=R3 RECEIVER=go REPS=20 RUN_ITEM=$RUNREL/a3-r3-go experiments/gate3-matrix.sh
	item "A.3 R3 py"         RUN=R3 RECEIVER=py REPS=20 RUN_ITEM=$RUNREL/a3-r3-py experiments/gate3-matrix.sh
	item "A.3 R4 go"         RUN=R4 RECEIVER=go REPS=20 RUN_ITEM=$RUNREL/a3-r4-go experiments/gate3-matrix.sh
	item "A.3 R4 py"         RUN=R4 RECEIVER=py REPS=20 RUN_ITEM=$RUNREL/a3-r4-py experiments/gate3-matrix.sh
	item "A.3 egress go"     RUN=egress RECEIVER=go REPS=20 RUN_ITEM=$RUNREL/a3-egress-go experiments/gate3-matrix.sh
	item "A.3 egress py"     RUN=egress RECEIVER=py REPS=20 RUN_ITEM=$RUNREL/a3-egress-py experiments/gate3-matrix.sh
	# the three rows the proposal note of 2026-09-19 adds (task 4a's run-item names)
	item "A.3 baseline py service" RUN=baseline RECEIVER=py SUB=service REPS=20 RUN_ITEM=$RUNREL/a3-baseline-py-service experiments/gate3-matrix.sh
	item "A.3 R2 py service"       RUN=R2 RECEIVER=py SUB=service REPS=20 RUN_ITEM=$RUNREL/a3-r2-py-service experiments/gate3-matrix.sh
	item "A.3 R4 py service"       RUN=R4 RECEIVER=py SUB=service REPS=20 RUN_ITEM=$RUNREL/a3-r4-py-service experiments/gate3-matrix.sh ;;
*) echo "phase must be a1, a2 or a3" >&2; exit 2 ;;
esac
finish 0
