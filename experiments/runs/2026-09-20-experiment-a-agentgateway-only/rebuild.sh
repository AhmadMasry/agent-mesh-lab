#!/usr/bin/env bash
# Follow-ups 19, task 4b: the rebuild driver before the Experiment A re-run. From a deleted cluster, at the tree of
# the branch's tip, the commit whose subject is "feat(experiments): a retry route set for lab/orchestrator and the
# matrix's Service-addressed Python rows". Runs from the repository root. Writes its log OUTSIDE the repository (the
# scratchpad) while it runs; the log and this script are copied into
# experiments/runs/<local date at the rebuild's start>-experiment-a-agentgateway-only/ afterwards, so the working
# tree stays clean for the whole build. No manual step: only the seven make targets, in the last proof's order, each
# timed. Stops at the first non-zero exit.
# Keep-awake: this script starts none and changes no power setting, and neither do the commands of the task that
# runs it. Keep-awake is NOT claimed absent on the host: the agent harness holds its own rolling `caffeinate` per
# session, which this task neither starts nor stops; host-sleep.txt carries the counts.
# experiments/runs/2026-09-19-worker-span-rebuild/rebuild.sh (REBUILD-2), changed in: the header text, the scratch
# path, the subject of the tip, the comparison column -- here the commit REBUILD-2 proved (subject below), so the log
# shows exactly which deployed subtree and blob ids moved between the two rebuilt trees -- the task named in the
# log's first line and in the section heads, and the files named inside the deployed subtrees: the ones the commits
# between the two trees touch, beside the orchestrator's build inputs. The targets, their order, the status checks,
# the stop rule and the timing are that script's.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>/2965f467-038d-4709-a812-d7d51f83c94f/scratchpad/proof
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
SUBJECT="feat(experiments): a retry route set for lab/orchestrator and the matrix's Service-addressed Python rows"
CMP=2c08205357a554f0035453f9c5e487a898b54e16
CMP_SUBJECT="fix(worker): mark the server span of an injected close-after-read"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

T0=$(now)
{
echo "# Follow-ups 19, task 4b -- the rebuild before the Experiment A re-run, from a deleted cluster, at the tree of the commit named by subject below."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm or kubectl call outside a make target."
echo "#"
echo "# The commit, named by subject: ${SUBJECT}"
echo "# It is the branch's pushed tip at the time of the build. The commit that carries this record and the findings"
echo "# entry comes AFTER the build, on top of it, and touches no deployed path; so what identifies the built tree is"
echo "# the deployed subtree and script blob ids below, which that later commit leaves as they are."
echo "# Started $(ts) (epoch $T0). Local date at the start: $(date +%F)."
echo "#"
echo "# \$ git rev-parse --abbrev-ref HEAD -> $(git rev-parse --abbrev-ref HEAD)"
echo "# \$ git rev-parse HEAD           -> $(git rev-parse HEAD)"
echo "# \$ git rev-parse HEAD^{tree}    -> $(git rev-parse 'HEAD^{tree}')"
echo "# \$ git log --format=%s -1       -> $(git log --format=%s -1)"
st=$(git status --short); echo "# \$ git status --short         -> ${st:-(empty)}"
echo "# (this log is written outside the repository while the build runs and copied in afterwards)"
echo "#"
echo "# deployed subtree and blob IDs at that commit (git rev-parse HEAD:<path>), beside the tree REBUILD-2"
echo "# proved (experiments/runs/2026-09-19-worker-span-rebuild/), the commit whose subject is: ${CMP_SUBJECT}"
echo "# (git rev-parse of it -> $(git rev-parse "${CMP}"), tree $(git rev-parse "${CMP}^{tree}"); commits on it up to HEAD: $(git rev-list --count "${CMP}..HEAD")):"
for p in deploy Makefile agents fixtures experiments/lib .ko.yaml go.mod go.sum internal kind-config.yaml; do
	h=$(git rev-parse "HEAD:$p"); c=$(git rev-parse "${CMP}:$p")
	printf '#   %-18s %s  REBUILD-2: %s  %s\n' "$p" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   experiments/*.sh blobs:"
for f in experiments/*.sh; do
	h=$(git rev-parse "HEAD:$f"); c=$(git rev-parse "${CMP}:$f" 2>/dev/null || echo none)
	printf '#     %-44s %s  %s\n' "$f" "$h" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   inside the deployed subtrees: the files the commits between the two trees touch, and the worker's and the"
echo "#   orchestrator's subtrees and the orchestrator's build inputs:"
for f in fixtures/loadgen fixtures/loadgen/main.go fixtures/loadgen/dial_test.go deploy/base/loadgen-a2-job.yaml deploy/step-3-stress/retry/waypoint/off/kustomization.yaml deploy/step-3-stress/retry/waypoint-orchestrator/off/kustomization.yaml deploy/step-3-stress/retry/waypoint-orchestrator/on/kustomization.yaml experiments/lib/derive-layer.sh agents/worker agents/orchestrator agents/orchestrator/pyproject.toml agents/orchestrator/uv.lock agents/orchestrator/Dockerfile; do
	h=$(git rev-parse -q --verify "HEAD:$f" 2>/dev/null || echo "(absent)"); c=$(git rev-parse -q --verify "${CMP}:$f" 2>/dev/null || echo "(absent at REBUILD-2's tree)")
	printf '#     %-44s %s  REBUILD-2: %s  %s\n' "$f" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   \$ git diff --stat <REBUILD-2's tree> HEAD -- <the deployed paths>"
git diff --stat "${CMP}" HEAD -- "${DEPLOYED[@]}" | sed 's/^/#     /'
echo "#   \$ git diff --name-status <REBUILD-2's tree> HEAD -- <the deployed paths>"
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
echo "# kind:     $(kind version)"
echo "# ko:       $(ko version)"
echo "# docker:   $(docker version --format '{{.Client.Version}} (server {{.Server.Version}})')"
echo "# go:       $(go version)"
echo "# uv:       $(uv --version)"
echo
echo "## the cluster being deleted: REBUILD-2's cluster, built at the tree of the comparison commit above"
echo "## (experiments/runs/2026-09-19-worker-span-rebuild/), on which task 4a's one-repetition dry runs and the task-4"
echo "## spike also ran; it was not built at the tip. Its deletion through make teardown is this task's first cluster action."
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
