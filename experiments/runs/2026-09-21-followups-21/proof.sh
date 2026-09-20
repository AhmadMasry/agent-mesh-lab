#!/usr/bin/env bash
# Follow-ups 21: the standard proof on the rebuilt cluster, ONE background driver. It runs
#   checks.sh with ONLY=part1,
#   versions-readback.sh (reads only; the Versions line of the entry),
#   checks.sh with ONLY=knobs (the retry knobs, last, ending at zero stanzas),
# in that order, each once, and stops at the first non-zero exit. Part two of checks.sh -- the commit-specific
# readings of follow-ups 19's task 4b -- is not run: the script's own switch selects part1 and knobs, so the file
# itself is unedited. Its only run-directory paths are its arguments ($2 = this run directory's name); its log is
# written to a scratch path taken from the environment and copied in afterwards.
# Both scripts are the last proof's own files and are run FROM the record that holds them
# (experiments/runs/2026-09-20-experiment-a-agentgateway-only/), not copied into this one, so no further copy of a
# file carrying an absolute path enters the repository; checks.sh keeps its own byte copy of itself under this run
# directory's checks-as-run/, which is its behaviour and is left as it writes it. Both cd to the repository root
# themselves.
# Keep-awake: this driver starts none and changes no power setting. No retry: each step runs once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL=2026-09-21-followups-21
D=experiments/runs/$RUNREL
LAST=experiments/runs/2026-09-20-experiment-a-agentgateway-only
SCR="${TMPDIR%/}/fu21/proof"
mkdir -p "$SCR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) proof driver start; HEAD $(git rev-parse HEAD); checks.sh sha256 $(shasum -a 256 $LAST/checks.sh | awk '{print $1}')"
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" part1; rc=$?
echo "$(ts) checks part1 driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/versions-readback.sh" "$D/versions-readback.txt"; rc=$?
echo "$(ts) versions-readback exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" knobs; rc=$?
echo "$(ts) checks knobs driver exit=$rc"
echo "proof driver exit=$rc"
