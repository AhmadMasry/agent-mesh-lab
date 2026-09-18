#!/usr/bin/env bash
# Follow-ups 15, review round: the standard proof's readings on the second rebuild, in order, each step stamped. Committed
# scripts only, unedited, and nothing edited, restarted or deleted by hand (the clean check and the trace create
# and remove their own client pods and Jobs). Runs from the repository root after the rebuild; the log is written
# to $1 (outside the repository) and copied in afterwards. Adapted from
# ../rebuild/checks.sh (the first rebuild of this task): the output paths, under rebuild-2/, and the nonces.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-19-failed-model-call
D=experiments/runs/$RUNREL
R2=$D/rebuild-2
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
echo "# Follow-ups 15 rebuild-2 proof readings, started $(ts). HEAD $(git rev-parse HEAD); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures internal experiments/lib 'experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml | tr '\n' ' ')" > "$LOG"
step "clean check" env RUN_ID=fu15c2 RUN_ITEM=$RUNREL/rebuild-2/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ID=fu15t2 RUN_ITEM=$RUNREL/rebuild-2/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents (follow-ups 14 dangling.py, unedited)" bash -c "python3 $F14/trace/dangling.py $R2/trace > $R2/trace/dangling.csv && cat $R2/trace/dangling.csv"
step "GenAI spans per operation (follow-ups 14 genai-spans.py, unedited)" bash -c "mkdir -p $R2/trace/genai && python3 $F14/genai-spans.py $R2/trace $R2/trace/genai > $R2/trace/genai/summary.csv && cat $R2/trace/genai/summary.csv"
step "prometheus targets" bash -c "mkdir -p $R2 && { echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; } > $R2/prometheus-targets.txt 2>&1; cat $R2/prometheus-targets.txt"
echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks done"
