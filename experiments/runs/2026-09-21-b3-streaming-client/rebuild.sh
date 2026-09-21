#!/usr/bin/env bash
# Experiment B, step B-3: the rebuild driver. From a deleted cluster, at the tree of branch experiment-b3's tip -- the
# commit whose subject is "feat(deploy,experiments): the knobs Job template carries MODE and TASK_ID, rendered empty on
# every existing row". The four commits between the last rebuild's tree and that tip are what this rebuild proves: B-2's
# two (the mock's delay mode; the callers' ceilings, comments only) and B-3's two (the load client's stream and
# subscribe modes; the Job template's MODE and TASK_ID). The run directory and the findings entries are added in a
# later commit, so the built tree is identified below by its deployed subtree and script blob ids, which that addition
# leaves as they are.
# Runs with the working directory inside the repository and changes to its root through git, so no absolute path
# enters the record. Writes its log to a scratch path taken from the environment while it runs; the log and this
# script are copied into experiments/runs/2026-09-21-b3-streaming-client/ afterwards, so the working tree stays clean
# for the whole build. No manual step: only the seven make targets, in the last proof's order, each timed. Stops at
# the first non-zero exit.
# Keep-awake: this script starts none and changes no power setting, and neither do the commands of the task that
# runs it. Keep-awake is NOT claimed absent on the host: the agent harness holds its own rolling caffeinate per
# session, which this task neither starts nor stops; host-sleep.txt carries the counts.
# Adapted from experiments/runs/2026-09-21-followups-21/rebuild.sh, changed in: the header text, the scratch path, the
# subject of the tip, the comparison commit -- here the commit the last rebuild proved, now on main -- and the files
# named inside the deployed subtrees. The targets, their order, the status checks, the stop rule and the timing are
# that script's.
#
# ATTEMPT 2. Attempt 1 (attempt-1/ beside this file) stopped at `make step-2`: the Makefile's guard refused the istioctl
# on PATH, the host's Homebrew istioctl, which Homebrew had moved to 1.31.1 at 2026-09-21T18:55:13Z, before this task
# began; the pin is 1.31.0 (versions.yaml). By the controller's ruling this attempt puts a lab-scoped istioctl 1.31.0
# FIRST on PATH for its own processes only -- the binary from the official release that pin names, fetched and
# checked against the SHA-256 the release publishes (tools.txt beside this file) -- and changes nothing on the host:
# not Homebrew, not /opt/homebrew/bin/istioctl, not a shell profile, not any global PATH. The build log records the
# binary's path as ${TMPDIR}/..., its version output and its checksum.
#
# ATTEMPT 3. Attempt 2 (attempt-2/) passed the istioctl guard and stopped at step-2's first Helm install: "no cached repo
# found (try 'helm repo update')". The host's Helm cache directory had been removed before this run by something outside
# the lab, and helm 4.3.0 refuses a --repo install while the host's repositories file lists repositories with no cached
# index. By the controller's second ruling this attempt gives Helm an environment of the lab's own for its processes:
# HELM_REPOSITORY_CONFIG an EMPTY file, HELM_REPOSITORY_CACHE and HELM_CACHE_HOME directories, all under
# ${TMPDIR}/b3/tools/helm-scope. The lab's installs name their chart repositories by --repo URL and need nothing from the
# user's Helm configuration. Nothing writes the user's Helm config or cache; `helm repo update` is not run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
LABTOOLS="${TMPDIR%/}/b3/tools/istioctl-1.31.0"
PATH="$LABTOOLS:$PATH"
export PATH
HELMSCOPE="${TMPDIR%/}/b3/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME
SCR="${TMPDIR%/}/b3/proof"
mkdir -p "$SCR"
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
SUBJECT="feat(deploy,experiments): the knobs Job template carries MODE and TASK_ID, rendered empty on every existing row"
CMP=ffae4b6d2ae46855f10a7af6d7aeecc1f66dbac8
CMP_SUBJECT="fix(experiments,Makefile): the baseline script leaves the mock as it found it, the ledgers target collects a resubscription, and the ko-digest comment says what the lab measured"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

T0=$(now)
{
echo "# Experiment B, step B-3, ATTEMPT 3 -- the rebuild that proves B-2's two commits and B-3's two, from a deleted cluster, at the tree of the commit named by subject below."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm or kubectl call outside a make target."
echo "#"
echo "# The commit, named by subject: ${SUBJECT}"
echo "# The run directory and the findings entry are added to that same commit AFTER the build; they touch no"
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
echo "# proved (experiments/runs/2026-09-21-followups-21/, built at that commit's tree before it reached main), the commit whose subject is: ${CMP_SUBJECT}"
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
for f in fixtures/loadgen fixtures/loadgen/main.go fixtures/loadgen/stream.go fixtures/mockllm fixtures/mockllm/server.go fixtures/mockllm/injection.go fixtures/mockllm/main.go internal internal/otel/otel.go agents/worker agents/worker/main.go agents/orchestrator agents/orchestrator/orchestrator/model.py deploy/base/loadgen-a2-job.yaml experiments/gate2-a2.sh experiments/gate3-matrix.sh; do
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
git worktree list | sed 's/^/#     /'
echo "#   \$ tail -2 .git/info/exclude"
tail -2 .git/info/exclude | sed 's/^/#     /'
echo "#"
echo "# host:     $(uname -sm)"
echo "# make:     $(make --version | head -1)"
echo "# helm:     $(helm version --short)"
echo "# kubectl:  $(kubectl version --client 2>/dev/null | head -1)"
echo "# istioctl: $(istioctl version --remote=false 2>/dev/null)"
echo "#   the istioctl on PATH for this build: \${TMPDIR}/b3/tools/istioctl-1.31.0/istioctl -- $(command -v istioctl | sed "s#^${TMPDIR%/}#\${TMPDIR}#; s#//#/#g")"
echo "#   binary sha256 $(shasum -a 256 "$LABTOOLS/istioctl" | cut -d' ' -f1); from istioctl-1.31.0-osx-arm64.tar.gz, sha256 $(shasum -a 256 "${TMPDIR%/}/b3/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz" | cut -d' ' -f1)"
echo "#   the release's published checksum file (istioctl-1.31.0-osx-arm64.tar.gz.sha256): $(cat "${TMPDIR%/}/b3/tools/dl/istioctl-1.31.0-osx-arm64.tar.gz.sha256")"
echo "#   source https://github.com/istio/istio/releases/tag/1.31.0 (assets fetched 2026-09-21T20:58:42Z and 20:58:48Z; see tools.txt)"
echo "#   the host's Homebrew istioctl had moved to 1.31.1 at 2026-09-21T18:55:13Z, before this task began, and is NOT used by this build (attempt 1 stopped on it)"
echo "# helm environment for this build (the controller's second ruling):"
echo "#   HELM_REPOSITORY_CONFIG=\${TMPDIR}/b3/tools/helm-scope/config/repositories.yaml ($(wc -c < "$HELM_REPOSITORY_CONFIG" | tr -d ' ') bytes: an empty file)"
echo "#   HELM_REPOSITORY_CACHE=\${TMPDIR}/b3/tools/helm-scope/cache/repository ($(ls -A "$HELM_REPOSITORY_CACHE" | wc -l | tr -d ' ') entries at the start)"
echo "#   HELM_CACHE_HOME=\${TMPDIR}/b3/tools/helm-scope/cache"
echo "#   the host's Helm cache directory had been removed before this run by something outside the lab; Helm recreated it empty at"
echo "#   2026-09-21T21:02:03Z (attempt 2); the host's repositories file is neither read for the installs nor changed by this build"
echo "# kind:     $(kind version)"
echo "# ko:       $(ko version)"
echo "# docker:   $(docker version --format '{{.Client.Version}} (server {{.Server.Version}})')"
echo "# go:       $(go version)"
echo "# uv:       $(uv --version)"
echo
echo "## the cluster being deleted: the standing one at step 3 (0 retry stanzas, 0 AuthorizationPolicy, nothing armed, as"
echo "## the dispatch states it), on which the Experiment C readings of 2026-09-21 ran. Its deletion through make teardown"
echo "## is this task's first cluster action."
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
