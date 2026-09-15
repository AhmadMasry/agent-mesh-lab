#!/usr/bin/env bash
# Follow-ups 14: the readings on the rebuilt cluster, in order, each step stamped. Committed scripts and this run's
# tools only; nothing is edited, restarted or deleted by hand (the probes and the card read create and remove their
# own client pods, as the clean check and the trace do). Runs from the repository root after the rebuild; the log is
# written to $1 (outside the repository) and copied in afterwards. Adapted from
# experiments/runs/2026-09-15-ingress-namespace/checks.sh (followups-12): the run directory, and the two steps this
# task adds -- the per-operation span table with the GenAI attribute checks, and the image scan.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-16-genai-spans
D=experiments/runs/$RUNREL
LOG="$1"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
echo "# Follow-ups 14 readings, started $(ts). HEAD $(git rev-parse HEAD); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures experiments/lib 'experiments/*.sh' | tr '\n' ' ')" > "$LOG"
step "ztunnel rejections before" "$D/rebuild/rejections.sh" "$D/rebuild/ztunnel-rejections-before.txt" "before the readings, the card read, the clean check, the trace, the A.2 and A.3 rows and the probes"
step "readback (helm, istio, certificates, mesh shape, attachment, egress first stream)" "$D/rebuild/readback.sh" "$D/rebuild"
step "agent card read" "$D/rebuild/card.sh" "$D/rebuild/agent-card.txt"
step "clean check" env RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents" bash -c "python3 $D/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "GenAI spans per operation, with the attribute checks" bash -c "mkdir -p $D/trace/genai && python3 $D/genai-spans.py $D/trace $D/trace/genai > $D/trace/genai/summary.csv && cat $D/trace/genai/summary.csv && for f in per-operation chat-spans invoke-agent; do echo; echo \"## \$f.csv\"; cat $D/trace/genai/\$f.csv; done"
echo "# readings part 1 finished $(ts)" >> "$LOG"
echo "$(ts) checks done"
