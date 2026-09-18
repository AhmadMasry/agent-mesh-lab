#!/usr/bin/env bash
# Follow-ups 15, review round: the second rebuild driver. From a deleted cluster, at the final tree of commit 1, the
# commit whose subject is "fix(telemetry): the four nits from the follow-ups 14 review", after the review's I1 and
# M10 fixup was autosquashed into it: a port that is not a TCP server port leaves server.port unset in both agents.
# Runs from the repository root. Writes its log OUTSIDE the repository (the scratchpad) while it runs; the log and
# this script are copied into experiments/runs/2026-09-19-failed-model-call/rebuild-2/ afterwards, so the working
# tree stays clean for the whole build. No manual step: only the seven make targets, in order, each timed. Stops at
# the first non-zero exit. Copied from ../rebuild/rebuild.sh (the first rebuild of this task): header text, the
# scratch path, and the commit-1 identity lines, which name commit 1 by subject because the checkout is at the
# branch head, whose deployed subtrees are commit 1's.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>--superpowers-sdd/5c3152a9-15d6-4494-aa32-4dba2e81dbf4/scratchpad/rebuild2
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
DEPLOYED=(deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)

T0=$(now)
{
echo "# Follow-ups 15, review round -- rebuild 2, from a deleted cluster, at the final tree of commit 1: the four nits"
echo "# of the follow-ups 14 review, with the review fix for I1 and M10 squashed in. The first rebuild of this task is"
echo "# ../rebuild/build.txt, at the tree commit 1 had before the review."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm upgrade outside a make target."
echo "#"
C1=$(git log --format=%H --grep='^fix(telemetry): the four nits from the follow-ups 14 review$' -n 1)
echo "# Commit 1, named by subject: fix(telemetry): the four nits from the follow-ups 14 review"
echo "#   \$ git log --format=%H --grep=<that subject> -n 1   -> ${C1}"
echo "#   \$ git rev-parse <commit 1>^{tree}                   -> $(git rev-parse "${C1}^{tree}")"
echo "# The checkout is at the branch head. Its deployed subtrees are commit 1's, each compared below (same = equal)."
echo "# Started $(ts) (epoch $T0)."
echo "#"
echo "# \$ git rev-parse HEAD           -> $(git rev-parse HEAD)"
echo "# \$ git rev-parse HEAD^{tree}    -> $(git rev-parse 'HEAD^{tree}')"
echo "# \$ git log --oneline -1         -> $(git log --oneline -1)"
st=$(git status --short); echo "# \$ git status --short         -> ${st:-(empty)}"
echo "# (this log is written outside the repository while the build runs and copied in afterwards)"
echo "#"
echo "# deployed subtree and blob IDs at that commit (git rev-parse HEAD:<path>):"
for p in deploy Makefile agents fixtures experiments/lib .ko.yaml go.mod go.sum internal kind-config.yaml; do
	h=$(git rev-parse "HEAD:$p"); c=$(git rev-parse "${C1}:$p")
	printf '#   %-18s %s  commit 1: %s  %s\n' "$p" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo DIFFERENT)"
done
echo "#   experiments/*.sh blobs:"
for f in experiments/*.sh; do
	h=$(git rev-parse "HEAD:$f"); c=$(git rev-parse "${C1}:$f")
	printf '#     %-44s %s  %s\n' "$f" "$h" "$([ "$h" = "$c" ] && echo same || echo DIFFERENT)"
done
echo "#"
echo "# git status reads clean although the controller has a worktree-isolated agent under .claude/worktrees/: the"
echo "# controller excluded that path locally in .git/info/exclude (never committed). Recorded so the clean status"
echo "# is not read as the absence of that directory:"
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
echo "## the cluster being deleted: built by the first rebuild of this task, 2026-09-18T21:08:56Z, at the pre-review tree of commit 1"
kind get clusters 2>&1
} > "$LOG" 2>&1
echo "step,started_utc,started_epoch,finished_utc,finished_epoch,wall_s,exit" > "$TIM"
T1=$(now)
echo "## header reads: $(perl -e "printf '%.3f', $T1 - $T0") s" >> "$LOG"
echo >> "$LOG"

run() { # $1 = target
	local target="$1" s e rc dirty
	dirty=$(git status --short)
	echo "## git status --short (whole checkout) before make $target -> ${dirty:-(empty)}" >> "$LOG"
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
