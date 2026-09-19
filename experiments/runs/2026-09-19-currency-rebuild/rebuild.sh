#!/usr/bin/env bash
# Follow-ups 19, task 3: the rebuild driver. From a deleted cluster, at the tree of the branch's tip, the commit
# whose subject is "docs(comments): six comments that went stale with the topology, and two notes on the currency
# record" -- the fifth of the five commits follow-ups 19 put on main: the pins of 2026-09-19 and the carried code
# items. Runs from the repository root. Writes its log OUTSIDE the repository (the scratchpad) while it runs; the
# log and this script are copied into experiments/runs/<local date at the rebuild's start>-currency-rebuild/
# afterwards, so the working tree stays clean for the whole build. No manual step: only the seven make targets,
# in the last proof's order, each timed. Stops at the first non-zero exit. No keep-awake of any form is started
# by this script or by the task that runs it.
# Adapted from experiments/runs/2026-09-19-agentgateway-only/rebuild.sh: the header text, the scratch path, the
# subject, the comparison column -- here main's tip, so the log shows which deployed subtree and blob ids this
# branch moved -- and the pathspec of the deployed-paths status read, which is now ':(glob)experiments/*.sh' so it
# does not cross into run directories (that record's reading note 5).
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>/28065019-615a-4218-9378-ec09c0314ff2/scratchpad/proof
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
SUBJECT="docs(comments): six comments that went stale with the topology, and two notes on the currency record"
CMP=2ef870700a9e6b38ef8722709f62ee982ed4d634
CMP_SUBJECT="refactor(experiments): layer attribution keyed on the span's route — one proxy now carries the agent leg and the model leg"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

T0=$(now)
{
echo "# Follow-ups 19, task 3 -- the rebuild, from a deleted cluster, at the tree of the commit named by subject below."
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
echo "# deployed subtree and blob IDs at that commit (git rev-parse HEAD:<path>), beside main's tip, the commit whose"
echo "# subject is: ${CMP_SUBJECT}"
echo "# (git rev-parse main -> $(git rev-parse main); commits on it up to HEAD: $(git rev-list --count "${CMP}..HEAD")):"
for p in deploy Makefile agents fixtures experiments/lib .ko.yaml go.mod go.sum internal kind-config.yaml; do
	h=$(git rev-parse "HEAD:$p"); c=$(git rev-parse "${CMP}:$p")
	printf '#   %-18s %s  main: %s  %s\n' "$p" "$h" "$c" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   experiments/*.sh blobs:"
for f in experiments/*.sh; do
	h=$(git rev-parse "HEAD:$f"); c=$(git rev-parse "${CMP}:$f" 2>/dev/null || echo none)
	printf '#     %-44s %s  %s\n' "$f" "$h" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#   the orchestrator's build inputs (inside agents/, named because the pins of 2026-09-19 moved two of them):"
for f in agents/orchestrator/pyproject.toml agents/orchestrator/uv.lock agents/orchestrator/Dockerfile; do
	h=$(git rev-parse "HEAD:$f"); c=$(git rev-parse "${CMP}:$f")
	printf '#     %-44s %s  %s\n' "$f" "$h" "$([ "$h" = "$c" ] && echo same || echo CHANGED)"
done
echo "#"
echo "# git status reads clean although a worktree of the controller's lives under .claude/worktrees/: that path is"
echo "# excluded locally in .git/info/exclude (never committed). Recorded so the clean status is not read as its absence:"
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
echo "## the cluster being deleted: follow-ups 18's proof cluster, built at the pins before 2026-09-19's currency pass"
echo "## (experiments/runs/2026-09-19-agentgateway-only/) and used since by that branch's attribution task. Its deletion"
echo "## through make teardown is this task's first cluster action."
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
