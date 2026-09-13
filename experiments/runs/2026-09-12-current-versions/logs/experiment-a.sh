#!/usr/bin/env bash
# Follow-ups 10: the Experiment A re-run on the rebuilt step-3 cluster, with the committed scripts
# unedited, each item into its own directory under experiments/runs/2026-09-12-current-versions/.
# Usage: expa.sh <a1|a2|a3>   -- one invocation at a time, in the committed order. A failing item is
# recorded with its exit status and the driver moves on to the next (the brief: report, continue).
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-12-current-versions
SCR=<scratchpad>/5008ee34-eeb0-4d7c-a82b-45488493edbc/scratchpad
PHASE="$1"
LOG=$SCR/expa-$PHASE.txt
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
item() { # label, env assignments..., then -- script
	local label="$1"; shift; local s=$(date -u +%s)
	local st; st=$(git status --short -- deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)
	echo "## $label  started $(ts)  deployed-paths status: ${st:-(empty)}" >> "$LOG"
	echo "## \$ $*" >> "$LOG"
	env "$@" >> "$LOG" 2>&1; local rc=$?
	echo "## $label  finished $(ts)  exit=$rc  wall=$(( $(date -u +%s) - s ))s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc wall=$(( $(date -u +%s) - s ))s"
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
	item "A.3 egress py"     RUN=egress RECEIVER=py REPS=20 RUN_ITEM=$RUNREL/a3-egress-py experiments/gate3-matrix.sh ;;
*) echo "phase must be a1, a2 or a3" >&2; exit 2 ;;
esac
echo "# phase $PHASE finished $(ts)" >> "$LOG"
echo "$(ts) phase $PHASE done"
