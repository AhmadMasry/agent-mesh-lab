#!/usr/bin/env bash
# Experiment B, step B-3: the standard proof on the rebuilt cluster, ONE background driver. It runs
#   checks.sh with ONLY=part1,
#   versions-readback.sh (reads only; the Versions line of the entries),
#   checks.sh with ONLY=knobs (the retry knobs, last, ending at zero stanzas),
# in that order, each once, and stops at the first non-zero exit. Part two of checks.sh -- the commit-specific
# readings of follow-ups 19's task 4b -- is not run: the script's own switch selects part1 and knobs, so the file
# itself is unedited. Its only run-directory paths are its arguments ($2 = this run directory's name); its log is
# written to a scratch path taken from the environment and copied in afterwards.
# Both scripts are the last proof's own files -- the ones experiments/runs/2026-09-21-followups-21/proof.sh ran -- and
# are run FROM the record that holds them (experiments/runs/2026-09-20-experiment-a-agentgateway-only/), not copied
# into this one; checks.sh keeps its own byte copy of itself under this run directory's checks-as-run/, which is its
# behaviour and is left as it writes it. Both cd to the repository root themselves.
# Adapted from experiments/runs/2026-09-21-followups-21/proof.sh, changed in: this header, RUNREL, the scratch path and
# the lab-scoped istioctl put first on PATH and the lab-scoped Helm environment.
# Keep-awake: this driver starts none and changes no power setting. No retry: each step runs once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
# The istioctl the checks call: the lab-scoped copy of the pinned 1.31.0 (tools.txt), first on PATH for this driver's
# processes only, by the controller's ruling; the host's Homebrew istioctl is not used and not touched.
PATH="${TMPDIR%/}/b3/tools/istioctl-1.31.0:$PATH"
export PATH
# Helm: the lab-scoped empty repository config and cache of the rebuild (the controller's second ruling).
HELMSCOPE="${TMPDIR%/}/b3/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
RUNREL=2026-09-21-b3-streaming-client
D=experiments/runs/$RUNREL
LAST=experiments/runs/2026-09-20-experiment-a-agentgateway-only
SCR="${TMPDIR%/}/b3/proof"
mkdir -p "$SCR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) proof driver start; HEAD $(git rev-parse HEAD); checks.sh sha256 $(shasum -a 256 $LAST/checks.sh | awk '{print $1}'); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null), \${TMPDIR}/b3/tools/istioctl-1.31.0/istioctl"
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" part1; rc=$?
echo "$(ts) checks part1 driver exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/versions-readback.sh" "$D/versions-readback.txt"; rc=$?
echo "$(ts) versions-readback exit=$rc"; [ "$rc" -eq 0 ] || { echo "proof driver exit=$rc"; exit "$rc"; }
bash "$LAST/checks.sh" "$SCR/checks.txt" "$RUNREL" knobs; rc=$?
echo "$(ts) checks knobs driver exit=$rc"
echo "proof driver exit=$rc"
