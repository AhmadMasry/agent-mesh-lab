#!/usr/bin/env bash
# Follow-ups 24: the standard proof on the cluster the walkthrough's run built, ONE driver, run after the walk. It runs
#   checks.sh with ONLY=part1,
#   versions-readback.sh (reads only; the Versions line of the entry),
#   checks.sh with ONLY=knobs (the retry knobs, last, ending at zero stanzas),
#   standard-counts-vs-rebuild-2.py against the last proof's directory (follow-ups 22's) -- reads files only,
# in that order, each once, and stops at the first non-zero exit. The three scripts are the last proof's own files, run
# FROM the records that hold them, unedited. Its log is written to a scratch path and copied in afterwards.
# Adapted from experiments/runs/2026-09-25-walkthrough/drivers/proof.sh, changed in: this header and LASTPROOF, which is
# follow-ups 23's directory (the tool paths, the scratch path and the checks script are that driver's).
#
# Keep-awake: this driver starts none and changes no power setting. No retry: each step runs once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
LAB_TOOLS="${TMPDIR:-/tmp}/agent-mesh-lab-tools"
PATH="$LAB_TOOLS:$PATH"
export PATH
HELM_REPOSITORY_CONFIG="$LAB_TOOLS/helm/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$LAB_TOOLS/helm/cache/repository"
HELM_CACHE_HOME="$LAB_TOOLS/helm/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
RUNREL="${RUNREL:?RUNREL, the name of the proof directory under experiments/runs/, is required}"
D=experiments/runs/$RUNREL
LAST=experiments/runs/2026-09-20-experiment-a-agentgateway-only
CMPPROG=experiments/runs/2026-09-21-followups-21/standard-counts-vs-rebuild-2.py
LASTPROOF=experiments/runs/2026-09-25-walkthrough/proof
SCR="${PROOF_SCRATCH:?}"
mkdir -p "$SCR" "$D"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) proof driver start; HEAD $(git rev-parse HEAD); checks.sh sha256 $(shasum -a 256 $LAST/checks.sh | awk '{print $1}'); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null), \${TMPDIR:-/tmp}/agent-mesh-lab-tools/istioctl"
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" part1; rc=$?
echo "$(ts) checks part1 driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/versions-readback.sh" "$D/versions-readback.txt"; rc=$?
echo "$(ts) versions-readback exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" knobs; rc=$?
echo "$(ts) checks knobs driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
python3 "$CMPPROG" "$LASTPROOF" "$D" > "$D/standard-counts-vs-last-proof.txt" 2>&1; rc=$?
echo "$(ts) standard counts vs the last proof ($LASTPROOF, by $CMPPROG, unedited) exit=$rc; $(tail -1 "$D/standard-counts-vs-last-proof.txt")"
echo "proof driver exit=$rc"
