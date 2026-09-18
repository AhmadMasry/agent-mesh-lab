#!/usr/bin/env bash
# Follow-ups 15: the standard proof's readings on the rebuilt cluster, in order, each step stamped. Committed
# scripts only, unedited, and nothing edited, restarted or deleted by hand (the clean check and the trace create
# and remove their own client pods and Jobs). Runs from the repository root after the rebuild; the log is written
# to $1 (outside the repository) and copied in afterwards. Adapted from
# experiments/runs/2026-09-16-genai-spans/checks.sh (follow-ups 14): the run directory and nonces, and the
# Prometheus target roster, which that task read in its second script.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-19-failed-model-call
D=experiments/runs/$RUNREL
F14=experiments/runs/2026-09-16-genai-spans
LOG="$1"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)  epoch $s" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
echo "# Follow-ups 15 proof readings, started $(ts). HEAD $(git rev-parse HEAD); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures internal experiments/lib 'experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml | tr '\n' ' ')" > "$LOG"
step "clean check" env RUN_ID=fu15c RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ID=fu15t RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents (follow-ups 14 dangling.py, unedited)" bash -c "python3 $F14/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "GenAI spans per operation (follow-ups 14 genai-spans.py, unedited)" bash -c "mkdir -p $D/trace/genai && python3 $F14/genai-spans.py $D/trace $D/trace/genai > $D/trace/genai/summary.csv && cat $D/trace/genai/summary.csv"
step "prometheus targets" bash -c "mkdir -p $D/rebuild && { echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; } > $D/rebuild/prometheus-targets.txt 2>&1; cat $D/rebuild/prometheus-targets.txt"
echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks done"
