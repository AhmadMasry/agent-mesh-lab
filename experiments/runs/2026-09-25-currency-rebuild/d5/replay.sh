#!/usr/bin/env bash
# The currency pass of 2026-09-25: D-5's connection count re-counted. Replays Step 2.1 of
# experiments/runs/2026-09-25-d5-a2a-backend/ (step21-driver.txt): conn unmarked; mark; conn marked; unmark;
# conn removed -- with that record's d5.sh, UNEDITED, run with RUNREL=2026-09-25-currency-rebuild/d5 (its output path
# is a setting), RUN_ID curs21. marking-add.json and marking-remove.json here are byte copies of that record's (cmp:
# identical). Then, as the record did, every ztunnel's lines since the step's start into conn-join/ztunnel-window.txt,
# each line prefixed with its pod's name, and that record's counts.py, run from this directory (it reads relative
# paths), into counts.txt. The step-2.2 trial (the A2A backend type) is not part of the approved row and is not run.
# No retry: d5.sh sends one curl --retry 0 per request. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/cur/tools/istioctl-1.31.1:$PATH"; export PATH
export RUNREL=2026-09-25-currency-rebuild/d5 RUN_ID=curs21
N=experiments/runs/$RUNREL
D5=experiments/runs/2026-09-25-d5-a2a-backend/d5.sh
ts() { date -u +%FT%TZ; }
S=$(ts)
echo "$S step 2.1 start (replay); d5.sh sha256 $(shasum -a 256 $D5 | cut -d' ' -f1); istioctl $(istioctl version --remote=false)"
bash "$D5" conn unmarked; echo "$(ts) conn unmarked exit=$?"
bash "$D5" mark; echo "$(ts) mark exit=$?"
bash "$D5" conn marked; echo "$(ts) conn marked exit=$?"
bash "$D5" unmark; echo "$(ts) unmark exit=$?"
bash "$D5" conn removed; echo "$(ts) conn removed exit=$?"
echo "$(ts) step 2.1 end (replay)"
mkdir -p "$N/conn-join"
{
	echo "# read $(ts): every ztunnel's lines since $S, the start of Step 2.1 (replay)"
	for z in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$z" --since-time="$S" | sed "s/^/$z /"
	done
} > "$N/conn-join/ztunnel-window.txt"
(cd "$N" && python3 ../../2026-09-25-d5-a2a-backend/counts.py > counts.txt 2> counts-stderr.txt; echo "$(date -u +%FT%TZ) counts.py exit=$?")
