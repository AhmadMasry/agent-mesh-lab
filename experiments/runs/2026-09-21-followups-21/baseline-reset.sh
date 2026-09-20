#!/usr/bin/env bash
# Follow-ups 21, reading 1: does experiments/gate1-baseline.sh leave the mock as it found it?
#
# The same reading twice on the rebuilt cluster, the before-side first: once with the script at the PARENT commit's
# blob (the version that resets before each repetition and not after the last) and once with the branch's version.
# Each side is, in order:
#   1. a watermark: how many lines the mock pod's log holds now, so the side reads only its own control lines;
#   2. the committed run type 3 as the record of 2026-09-19 ran it -- STEP=3 RUNS=3 REPS=1 -- which arms the mock by
#      work item (delay-then-close, 8 s, against MODEL_TIMEOUT_S=5, both set and unset by the script itself);
#   3. the mock's control log after the watermark: every line, the endpoint of the last one, and how many work items
#      stay armed, counted as the inject lines that follow the last reset;
#   4. one clean work item per receiver by experiments/gate2-single-clean.sh, unedited -- the 1/1/1/1/1 reading.
#      That script resets both control endpoints itself, before and after, so it is taken AFTER reading (3).
# The parent side runs the parent blob checked out over experiments/gate1-baseline.sh and restores the branch's
# version straight afterwards; the sha256 of the file is recorded at each point, and `git status --short` with it,
# so what ran and what the checkout held is on the record. No step target runs here and no image of the three lab
# Deployments is rebuilt by this script: what it runs are two committed scripts.
# No retry: every curl in the two scripts is theirs, one send per request, and this file adds none.
# Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
NS=lab
RUNREL=2026-09-21-followups-21
D=experiments/runs/$RUNREL
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mkdir -p "$D/baseline-reset"

mock_lines() { kubectl -n "$NS" logs deploy/mockllm --tail=-1 2>/dev/null | wc -l | tr -d ' '; }

side() { # $1 = parent|new, $2 = RUN_ID
	local name="$1" runid="$2" mark after rc
	echo "===== side: $name ====="
	echo "# experiments/gate1-baseline.sh sha256 $(shasum -a 256 experiments/gate1-baseline.sh | cut -d' ' -f1)"
	echo "# git status --short -> $(git status --short | tr '\n' ';')"
	mark=$(mock_lines)
	echo "# mock log watermark (lines before the run): $mark   $(ts)"
	env STEP=3 RUNS=3 REPS=1 RUN_ID="$runid" RUN_ITEM="$RUNREL/baseline-reset/$name" experiments/gate1-baseline.sh
	rc=$?
	echo "# gate1-baseline.sh exit=$rc $(ts)"
	after=$(mock_lines)
	echo "# mock log lines after the run: $after"
	kubectl -n "$NS" logs deploy/mockllm --tail=-1 2>/dev/null | tail -n "+$((mark + 1))" \
		| jq -c 'select(.ledger == "control")' > "$D/baseline-reset/$name-control.jsonl"
	echo "# control lines this side wrote -> $D/baseline-reset/$name-control.jsonl"
	cat "$D/baseline-reset/$name-control.jsonl"
	echo "# control lines: $(wc -l < "$D/baseline-reset/$name-control.jsonl" | tr -d ' ')"
	echo "# last control line endpoint: $(tail -1 "$D/baseline-reset/$name-control.jsonl" | jq -r '.endpoint')"
	echo "# work items still armed (inject lines after the last reset): $(awk '/\/control\/reset/{n=0;next} /\/control\/inject/{n++} END{print n+0}' "$D/baseline-reset/$name-control.jsonl")"
	echo "# one clean work item per receiver, gate2-single-clean.sh unedited  $(ts)"
	env RUN_ID="${runid}c" RUN_ITEM="$RUNREL/baseline-reset/$name-clean" experiments/gate2-single-clean.sh
	rc=$?
	echo "# gate2-single-clean.sh exit=$rc $(ts)"
	echo "# clean summary:"
	cat "$D/baseline-reset/$name-clean/summary.csv"
}

echo "# follow-ups 21, reading 1. start $(ts); HEAD $(git rev-parse HEAD); parent $(git rev-parse HEAD^)"
echo "# branch blob of experiments/gate1-baseline.sh: $(git rev-parse HEAD:experiments/gate1-baseline.sh)"
echo "# parent blob of experiments/gate1-baseline.sh: $(git rev-parse HEAD^:experiments/gate1-baseline.sh)"

git show HEAD^:experiments/gate1-baseline.sh > experiments/gate1-baseline.sh
side parent fu21p
git checkout -- experiments/gate1-baseline.sh
echo "# restored; sha256 $(shasum -a 256 experiments/gate1-baseline.sh | cut -d' ' -f1); git status --short -- experiments/gate1-baseline.sh -> $(git status --short -- experiments/gate1-baseline.sh | tr '\n' ';')"

side new fu21n
echo "# reading 1 done $(ts)"
