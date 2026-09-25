#!/usr/bin/env bash
# Follow-on D-3: the rebuild driver. From a deleted cluster, at the tip of branch experiment-d3 as it stands before its
# record commit -- three code commits on top of c6c9f35e (D-2's carried test pinning grpc.WithDisableServiceConfig; the
# external-authorization fixture fixtures/extauthz with go-control-plane/envoy v1.39.0 pinned; the fixture's Deployment
# and Service standing from step 2b, make ledgers and make scan-images) -- whose deployed subtrees are compared below,
# path by path, with those of the tree D-2's second rebuild proved (named by subject as CMP_SUBJECT below).
# Runs with the working directory inside the repository and changes to its root through git, so no absolute path
# enters the record; the one line that would carry the checkout's absolute path (git worktree list) is written with
# the home directory replaced by <HOME>. Writes its log to a scratch path taken from the environment while it runs;
# the log and this script are copied into the run directory afterwards, so the working tree stays clean for the whole
# build. No manual step: only the seven make targets, in the last proof's order, each timed. Stops at the first
# non-zero exit. If a make target's own wait times out, the driver stops there and the task stops for the controller;
# nothing is pre-loaded or repaired.
# Keep-awake: this script starts none and changes no power setting, and neither do the commands of the task that
# runs it. Keep-awake is NOT claimed absent on the host: the agent harness holds its own; the sleep record carries
# counts only.
# Adapted from experiments/runs/2026-09-24-d2-bindings/rebuild.sh, changed in: this header, the scratch and tool
# paths (${TMPDIR}/d3/...), the subject of the tip and of the compared tree, the fixture's subtree added to the listed
# paths, and the description of the cluster being deleted. The targets, their order, the status checks, the stop rule
# and the timing are that script's.
#
# The tools: a lab-scoped istioctl 1.31.0 FIRST on PATH for this script's processes only -- extracted in this task from
# the tarball D-2 used, whose sha256 equals the release's published checksum file re-fetched 2026-09-24T23:15:18Z -- and
# a Helm environment of the lab's own (HELM_REPOSITORY_CONFIG an EMPTY file, HELM_REPOSITORY_CACHE and HELM_CACHE_HOME
# empty directories, under ${TMPDIR}/d3/tools/helm-scope). Nothing on the host changes: not Homebrew, not the host's
# istioctl, not the user's Helm configuration or cache, not a shell profile or a global PATH; helm repo update is not run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
LABTOOLS="${TMPDIR%/}/d3/tools/istioctl-1.31.0"
PATH="$LABTOOLS:$PATH"
export PATH
HELMSCOPE="${TMPDIR%/}/d3/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
SCR="${TMPDIR%/}/d3/proof"
mkdir -p "$SCR"
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
SUBJECT="feat(deploy): the extauthz fixture standing from step 2b in lab, enrolled, its port marked h2c, in make ledgers beside the three and in make scan-images"
CMP=e730fc47
CMP_SUBJECT="fix(orchestrator): the forward's invoke_agent span reads the card's one JSON-RPC interface, so a card listing three bindings no longer blanks its server address"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

T0=$(now)
{
echo "# Follow-on D-3 -- the rebuild from a deleted cluster at the tree of the commit named by subject below; its deployed paths are compared below with the tree D-2's second rebuild proved."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm or kubectl call outside a make target."
echo "#"
echo "# The commit, named by subject: ${SUBJECT}"
echo "# The run directory and the findings entries are added in D-3's record commit on top of it AFTER the build; they touch no"
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
echo "# proved (experiments/runs/2026-09-24-d2-bindings/, its second rebuild, built at the tree of that commit, which main carries), the commit whose subject is: ${CMP_SUBJECT}"
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
for f in agents agents/worker agents/orchestrator deploy/base deploy/base/worker.yaml deploy/base/orchestrator.yaml deploy/base/mockllm.yaml deploy/step-1-nomesh deploy/step-2-ambient-agw deploy/step-2b-agw-ingress-egress deploy/step-2c-gate2 deploy/step-3-stress deploy/step-2b-agw-ingress-egress/extauthz.yaml fixtures fixtures/extauthz internal; do
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
echo "#   the istioctl on PATH for this build: \${TMPDIR}/d3/tools/istioctl-1.31.0/istioctl -- $(command -v istioctl | sed "s#^${TMPDIR%/}#\${TMPDIR}#; s#//#/#g")"
echo "#   binary sha256 $(shasum -a 256 "$LABTOOLS/istioctl" | cut -d' ' -f1); from istioctl-1.31.0-osx-arm64.tar.gz, sha256 $(shasum -a 256 "${TMPDIR%/}/d3/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz" | cut -d' ' -f1)"
echo "#   the release's published checksum file (istioctl-1.31.0-osx-arm64.tar.gz.sha256, fetched in this task): $(cat "${TMPDIR%/}/d3/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz.sha256")"
echo "#   source https://github.com/istio/istio/releases/tag/1.31.0 (the tarball fetched 2026-09-21T20:58:42Z by B-3, copied from D-2's tool directory; the checksum file re-fetched in this task 2026-09-24T23:15:18Z and equal to the tarball's sha256)"
echo "#   the host's Homebrew istioctl is NOT used by this build"
echo "# helm environment for this build (the controller's second ruling):"
echo "#   HELM_REPOSITORY_CONFIG=\${TMPDIR}/d3/tools/helm-scope/config/repositories.yaml ($(wc -c < "$HELM_REPOSITORY_CONFIG" | tr -d ' ') bytes: an empty file)"
echo "#   HELM_REPOSITORY_CACHE=\${TMPDIR}/d3/tools/helm-scope/cache/repository ($(ls -A "$HELM_REPOSITORY_CACHE" | wc -l | tr -d ' ') entries at the start)"
echo "#   HELM_CACHE_HOME=\${TMPDIR}/d3/tools/helm-scope/cache"
echo "#   the host's repositories file and cache are neither read for the installs nor changed by this build"
echo "# kind:     $(kind version)"
echo "# ko:       $(ko version)"
echo "# docker:   $(docker version --format '{{.Client.Version}} (server {{.Server.Version}})')"
echo "# go:       $(go version)"
echo "# uv:       $(uv --version)"
echo
echo "## the cluster being deleted: the one D-2's second rebuild built and ran its rows on, at step 3 with every D-2 overlay removed."
echo "## make teardown of it is authorized by the controller's go of D-3's Step 3."
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
