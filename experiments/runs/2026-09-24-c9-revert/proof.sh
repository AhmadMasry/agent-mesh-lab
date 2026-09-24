#!/usr/bin/env bash
# Experiment C, after C-9 (the revert): the standard proof on the rebuilt cluster, ONE background driver. It runs
#   checks.sh with ONLY=part1,
#   versions-readback.sh (reads only; the Versions line of the entry),
#   checks.sh with ONLY=knobs (the retry knobs, last, ending at zero stanzas),
#   standard-counts-vs-rebuild-2.py against the last proof's directory (C-10's) -- reads files only,
# in that order, each once, and stops at the first non-zero exit. Part two of checks.sh is not run: the script's own
# switch selects part1 and knobs, so the file itself is unedited. The three scripts are the last proof's own files,
# the ones experiments/runs/2026-09-24-c10-application/proof.sh ran, and are run FROM the records that hold them
# (experiments/runs/2026-09-20-experiment-a-agentgateway-only/ and experiments/runs/2026-09-21-followups-21/), not
# copied into this one; checks.sh keeps its own byte copy of itself under this run directory's checks-as-run/, which
# is its behaviour and is left as it writes it. Its log is written to a scratch path taken from the environment and
# copied in afterwards.
# Adapted from experiments/runs/2026-09-24-c9-a2a-marking/proof.sh, changed in: this header and the scratch and tool
# paths. LASTPROOF stays C-10's directory: C-10's proof was taken on the same deployed tree.
# Keep-awake: this driver starts none and changes no power setting. No retry: each step runs once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c9r/tools/istioctl-1.31.0:$PATH"
export PATH
HELMSCOPE="${TMPDIR%/}/c9r/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
RUNREL="${RUNREL:?RUNREL, the name of the run directory, is required}"
D=experiments/runs/$RUNREL
LAST=experiments/runs/2026-09-20-experiment-a-agentgateway-only
CMPPROG=experiments/runs/2026-09-21-followups-21/standard-counts-vs-rebuild-2.py
LASTPROOF=experiments/runs/2026-09-24-c10-application
SCR="${TMPDIR%/}/c9r/proof"
mkdir -p "$SCR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) proof driver start; HEAD $(git rev-parse HEAD); checks.sh sha256 $(shasum -a 256 $LAST/checks.sh | awk '{print $1}'); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null), \${TMPDIR}/c9r/tools/istioctl-1.31.0/istioctl"
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" part1; rc=$?
echo "$(ts) checks part1 driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/versions-readback.sh" "$D/versions-readback.txt"; rc=$?
echo "$(ts) versions-readback exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" knobs; rc=$?
echo "$(ts) checks knobs driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
python3 "$CMPPROG" "$LASTPROOF" "$D" > "$D/standard-counts-vs-last-proof.txt" 2>&1; rc=$?
echo "$(ts) standard counts vs the last proof ($LASTPROOF, by $CMPPROG, unedited) exit=$rc; $(tail -1 "$D/standard-counts-vs-last-proof.txt")"
echo "proof driver exit=$rc"
