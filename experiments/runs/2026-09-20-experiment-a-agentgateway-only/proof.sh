#!/usr/bin/env bash
# Follow-ups 19, task 4b, step 2: the standard proof on the rebuilt cluster, ONE background driver. It runs
#   checks.sh (experiments/runs/2026-09-19-worker-span-rebuild/checks.sh, copied here byte for byte) with ONLY=part1,
#   versions-readback.sh (reads only; the Versions line of the entry),
#   checks.sh with ONLY=knobs (the retry knobs, last, ending at zero stanzas),
# in that order, each once, and stops at the first non-zero exit. Part two of checks.sh -- readings (a)-(d) of
# REBUILD-2, the commit-specific readings of that task -- is not run (the brief of task 4b allows dropping it): the
# script's own switch selects part1 and knobs, so the file itself is unedited. Its only run-directory paths are its
# arguments ($2 = this run directory's name); its log is written outside the repository and copied in afterwards.
# Keep-awake: this driver starts none and changes no power setting. No retry: each step runs once.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-20-experiment-a-agentgateway-only
D=experiments/runs/$RUNREL
SCR=<scratchpad>/2965f467-038d-4709-a812-d7d51f83c94f/scratchpad/proof
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) proof driver start; HEAD $(git rev-parse HEAD); checks.sh sha256 $(shasum -a 256 $D/checks.sh | awk '{print $1}')"
bash "$D/checks.sh" "$SCR/checks.txt" "$RUNREL" part1; rc=$?
echo "$(ts) checks part1 driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$D/versions-readback.sh" "$D/versions-readback.txt"; rc=$?
echo "$(ts) versions-readback exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$D/checks.sh" "$SCR/checks.txt" "$RUNREL" knobs; rc=$?
echo "$(ts) checks knobs driver exit=$rc"
echo "proof driver exit=$rc"
