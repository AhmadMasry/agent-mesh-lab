#!/usr/bin/env bash
# Experiment C, step C-10: the rebuild driver. From a deleted cluster, at the tip of branch experiment-c10 as it stands
# before C-10's record commit -- the three code commits of C-10 (the worker's and the orchestrator's REFUSE_OPERATION and
# the Deployments that carry it empty) on top of main -- whose deployed subtrees are compared below, path by path,
# with those of the commit C-5 rebuilt (named by subject as CMP_SUBJECT below). C-10 changes agents/ and deploy/,
# deployed paths, so this rebuild is the proof of those commits.
# Runs with the working directory inside the repository and changes to its root through git, so no absolute path
# enters the record; the one line that would carry the checkout's absolute path (git worktree list) is written with
# the home directory replaced by <HOME>. Writes its log to a scratch path taken from the environment while it runs;
# the log and this script are copied into the run directory afterwards, so the working tree stays clean for the whole
# build. No manual step: only the seven make targets, in the last proof's order, each timed. Stops at the first
# non-zero exit. If a make target's own wait times out (an image pull on a slow network, as in C-5's attempt 1), the
# driver stops there and the task stops for the controller; nothing is pre-loaded or repaired.
# Keep-awake: this script starts none and changes no power setting, and neither do the commands of the task that
# runs it. Keep-awake is NOT claimed absent on the host: the agent harness holds its own; the sleep record carries
# counts only.
# Adapted from experiments/runs/2026-09-23-c5-istio-policy-agw-central/attempt-1/rebuild.sh, changed in: this header,
# the scratch and tool paths (${TMPDIR}/c10/...), the subject of the tip, the comparison commit -- the commit C-5 built
# -- the list of files read inside the deployed subtrees, and the description of the cluster being deleted. The
# targets, their order, the status checks, the stop rule and the timing are that script's.
#
# The tools, as B-3, B-4 and C-5 ran them: a lab-scoped istioctl 1.31.0 FIRST on PATH for this script's processes only --
# the binary of the release the pin names, re-verified in this task against the SHA-256 the release publishes
# (tools.txt) -- and a Helm environment of the lab's own (HELM_REPOSITORY_CONFIG an EMPTY file, HELM_REPOSITORY_CACHE
# and HELM_CACHE_HOME empty directories, under ${TMPDIR}/c10/tools/helm-scope). Nothing on the host changes: not
# Homebrew, not the host's istioctl (1.31.1), not the user's Helm configuration or cache, not a shell profile or a
# global PATH; helm repo update is not run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
LABTOOLS="${TMPDIR%/}/c10/tools/istioctl-1.31.0"
PATH="$LABTOOLS:$PATH"
export PATH
HELMSCOPE="${TMPDIR%/}/c10/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
SCR="${TMPDIR%/}/c10/proof"
mkdir -p "$SCR"
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
SUBJECT="feat(deploy): both agent Deployments carry REFUSE_OPERATION, rendered empty on every step"
CMP=511fb1454cde42b30055371ce802f589b9750757
CMP_SUBJECT="docs(proposal-notes): the author's decision of 2026-09-23 — Experiment C's second operation, one identity, and the A2A marking"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

T0=$(now)
{
echo "# Experiment C, step C-10 -- the rebuild from a deleted cluster at the tree of the commit named by subject below; its deployed paths are compared below with the tree C-5 proved."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm or kubectl call outside a make target."
echo "#"
echo "# The commit, named by subject: ${SUBJECT}"
echo "# The run directory and the findings entry are added in C-10's record commit on top of it AFTER the build; they touch no"
echo "# deployed path, so what identifies the built tree is the deployed subtree and script blob ids below."
echo "# Started $(ts) (epoch $T0). Local date at the start: $(date +%F)."
echo "#"
echo "# \$ git rev-parse --abbrev-ref HEAD -> $(git rev-parse --abbrev-ref HEAD)"
echo "# \$ git rev-parse HEAD           -> $(git rev-parse HEAD)"
echo "# \$ git rev-parse HEAD^{tree}    -> $(git rev-parse 'HEAD^{tree}')"
echo "# \$ git log --format=%s -1       -> $(git log --format=%s -1)"
st=$(git status --short); echo "# \$ git status --short         -> ${st:-(empty)}"
echo "# (this log is written outside the repository while the build runs and copied in afterwards)"
echo "#"
echo "# deployed subtree and blob IDs at that commit (git rev-parse HEAD:<path>), beside the tree the last rebuild"
echo "# proved (experiments/runs/2026-09-23-c5-istio-policy-agw-central/, built at the tree of that commit; main carries it with the same deployed subtrees), the commit whose subject is: ${CMP_SUBJECT}"
echo "# (git rev-parse of it -> $(git rev-parse "${CMP}"), tree $(git rev-parse "${CMP}^{tree}"); commits on it up to HEAD: $(git rev-list --count "${CMP}..HEAD")):"
for p in deploy Makefile agents fixtures experiments/lib .ko.yaml go.mod go.sum internal kind-config.yaml; do
	h=$(git rev-parse "HEAD:$p"); c=$(git rev-parse "${CMP}:$p")
	printf '#   %-18s %s  LAST: %s  %s\n' "$p" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   experiments/*.sh blobs:"
for f in experiments/*.sh; do
	h=$(git rev-parse "HEAD:$f"); c=$(git rev-parse "${CMP}:$f" 2>/dev/null || echo none)
	printf '#     %-44s %s  %s\n' "$f" "$h" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   inside the deployed subtrees: the files the commits between the two trees touch, and the worker's and the"
echo "#   orchestrator's subtrees and the orchestrator's build inputs:"
for f in agents/worker agents/worker/main.go agents/worker/refuse.go agents/worker/refuse_test.go agents/orchestrator agents/orchestrator/orchestrator agents/orchestrator/orchestrator/agent.py agents/orchestrator/orchestrator/server.py agents/orchestrator/orchestrator/refuse.py agents/orchestrator/tests agents/orchestrator/Dockerfile agents/orchestrator/uv.lock agents/orchestrator/pyproject.toml deploy/base deploy/base/worker.yaml deploy/base/orchestrator.yaml fixtures internal; do
	h=$(git rev-parse -q --verify "HEAD:$f" 2>/dev/null || echo "(absent)"); c=$(git rev-parse -q --verify "${CMP}:$f" 2>/dev/null || echo "(absent at the last rebuild's tree)")
	printf '#     %-44s %s  LAST: %s  %s\n' "$f" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   \$ git diff --stat <the last rebuild's tree> HEAD -- <the deployed paths>"
git diff --stat "${CMP}" HEAD -- "${DEPLOYED[@]}" | sed 's/^/#     /'
echo "#   \$ git diff --name-status <the last rebuild's tree> HEAD -- <the deployed paths>"
git diff --name-status "${CMP}" HEAD -- "${DEPLOYED[@]}" | sed 's/^/#     /'
echo "#"
echo "# git status reads clean although worktrees of the controller's live under .claude/worktrees/: that path is"
echo "# excluded locally in .git/info/exclude (never committed). Recorded so the clean status is not read as their absence:"
echo "#   \$ git worktree list"
git worktree list | sed "s#${HOME}#<HOME>#g" | sed 's/^/#     /'
echo "#   \$ tail -2 .git/info/exclude"
tail -2 .git/info/exclude | sed 's/^/#     /'
echo "#"
echo "# host:     $(uname -sm)"
echo "# make:     $(make --version | head -1)"
echo "# helm:     $(helm version --short)"
echo "# kubectl:  $(kubectl version --client 2>/dev/null | head -1)"
echo "# istioctl: $(istioctl version --remote=false 2>/dev/null)"
echo "#   the istioctl on PATH for this build: \${TMPDIR}/c10/tools/istioctl-1.31.0/istioctl -- $(command -v istioctl | sed "s#^${TMPDIR%/}#\${TMPDIR}#; s#//#/#g")"
echo "#   binary sha256 $(shasum -a 256 "$LABTOOLS/istioctl" | cut -d' ' -f1); from istioctl-1.31.0-osx-arm64.tar.gz, sha256 $(shasum -a 256 "${TMPDIR%/}/c10/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz" | cut -d' ' -f1)"
echo "#   the release's published checksum file (istioctl-1.31.0-osx-arm64.tar.gz.sha256, fetched in this task): $(cat "${TMPDIR%/}/c10/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz.sha256")"
echo "#   source https://github.com/istio/istio/releases/tag/1.31.0 (the tarball fetched 2026-09-21T20:58:42Z by B-3; the checksum file and the release record re-fetched in this task 2026-09-23T22:17:42Z and 22:17:45Z; see tools.txt)"
echo "#   the host's Homebrew istioctl is 1.31.1 (since 2026-09-21T18:55:13Z) and is NOT used by this build"
echo "# helm environment for this build (the controller's second ruling):"
echo "#   HELM_REPOSITORY_CONFIG=\${TMPDIR}/c10/tools/helm-scope/config/repositories.yaml ($(wc -c < "$HELM_REPOSITORY_CONFIG" | tr -d ' ') bytes: an empty file)"
echo "#   HELM_REPOSITORY_CACHE=\${TMPDIR}/c10/tools/helm-scope/cache/repository ($(ls -A "$HELM_REPOSITORY_CACHE" | wc -l | tr -d ' ') entries at the start)"
echo "#   HELM_CACHE_HOME=\${TMPDIR}/c10/tools/helm-scope/cache"
echo "#   the host's repositories file and cache are neither read for the installs nor changed by this build"
echo "# kind:     $(kind version)"
echo "# ko:       $(ko version)"
echo "# docker:   $(docker version --format '{{.Client.Version}} (server {{.Server.Version}})')"
echo "# go:       $(go version)"
echo "# uv:       $(uv --version)"
echo
echo "## the cluster being deleted: the one C-5 built (experiments/runs/2026-09-23-c5-istio-policy-agw-central/), after C-5, C-6, C-7"
echo "## and C-8's rows, at step 3 with nothing applied. make teardown of it is authorized by the brief; nothing on it was repaired."
kind get clusters 2>&1
} > "$LOG" 2>&1
echo "step,started_utc,started_epoch,finished_utc,finished_epoch,wall_s,exit" > "$TIM"
T1=$(now)
echo "## header reads: $(perl -e "printf '%.3f', $T1 - $T0") s" >> "$LOG"
echo >> "$LOG"

run() { # $1 = target
	local target="$1" s e rc dirty deployed
	dirty=$(git status --short)
	deployed=$(git status --short -- "${DEPLOYED[@]}")
	echo "## git status --short (whole checkout) before make $target -> ${dirty:-(empty)}" >> "$LOG"
	echo "## git status --short (deployed paths)  before make $target -> ${deployed:-(empty)}" >> "$LOG"
	if [ -n "$dirty" ]; then echo "STOP: checkout not clean before make $target" | tee -a "$LOG"; exit 1; fi
	s=$(now); local su; su=$(ts)
	echo "## make ${target}  started ${su}  epoch ${s}" >> "$LOG"
	make "$target" >> "$LOG" 2>&1
	rc=$?
	e=$(now); local eu; eu=$(ts)
	local w; w=$(perl -e "printf '%.3f', $e - $s")
	echo "## make ${target}  finished ${eu}  epoch ${e}  exit=${rc}  wall=${w}s" >> "$LOG"
	echo >> "$LOG"
	echo "make ${target},${su},${s},${eu},${e},${w},${rc}" >> "$TIM"
	echo "$(ts) make ${target} exit=${rc} wall=${w}s"
	if [ "$rc" -ne 0 ]; then echo "STOP: make ${target} exited ${rc}" | tee -a "$LOG"; exit "$rc"; fi
}

run teardown
run cluster-kind
run step-1
run step-2
run step-2b
run step-2c
run step-3
dirty=$(git status --short)
echo "## git status --short (whole checkout) after make step-3 -> ${dirty:-(empty)}" >> "$LOG"
TE=$(now)
echo "# build finished $(ts) (epoch $TE); from the first line of this log $(perl -e "printf '%.3f', $TE - $T0") s" >> "$LOG"
echo "$(ts) done"
