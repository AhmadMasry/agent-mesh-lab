#!/usr/bin/env bash
# Follow-ups 16: the clean check on the rebuilt cluster, stamped. The committed script only, unedited, and nothing
# edited, restarted or deleted by hand (the clean check creates and removes its own client pod and Jobs). Runs
# from the repository root after the rebuild; the log is written to $1 (outside the repository) and copied in
# afterwards. Adapted from experiments/runs/2026-09-19-failed-model-call/rebuild-2/checks.sh: the clean-check
# step alone, the output path and the nonce.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL="$2"
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
echo "# Follow-ups 16 clean check on the rebuilt cluster, started $(ts). HEAD $(git rev-parse HEAD); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures internal experiments/lib 'experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml | tr '\n' ' ')(empty if nothing precedes this)" > "$LOG"
step "clean check" env RUN_ID=fu16c RUN_ITEM=$RUNREL/rebuild/clean-check experiments/gate2-single-clean.sh
echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks done"
