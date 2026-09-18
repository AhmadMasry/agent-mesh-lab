#!/usr/bin/env bash
# Follow-ups 15 rebuild driver. From no cluster at all, at commit 1's tree: the four review nits of follow-ups 14
# (the server.port branch in internal/otel, the .hostname guard in the orchestrator's forward.py, a dated
# correction line in a committed record script's comment). Runs from the repository root. Writes its log OUTSIDE
# the repository (the scratchpad) while it runs; the log and this script are copied into
# experiments/runs/2026-09-19-failed-model-call/rebuild/ afterwards, so the working tree stays clean for the whole
# build. No manual step: only the seven make targets, in order, each timed. Between two targets the only thing
# that runs is the deployed-paths status read and the log lines. Stops at the first non-zero exit.
# Adapted from experiments/runs/2026-09-16-genai-spans/rebuild/rebuild.sh (follow-ups 14): header text and paths
# only. Every line this script echoes is double-quoted or free of apostrophes, which is what garbled a header
# in follow-ups 14.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>--superpowers-sdd/5c3152a9-15d6-4494-aa32-4dba2e81dbf4/scratchpad/rebuild
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
DEPLOYED=(deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)

T0=$(now)
{
echo "# Follow-ups 15 -- from no cluster, at commit 1 tree: the four nits of the follow-ups 14 review. Two of them"
echo "# change deployed code (internal/otel/otel.go, agents/orchestrator/orchestrator/forward.py), so both images"
echo "# that carry them, the worker and the orchestrator, are built from this tree; the third is a comment line"
echo "# in a committed run record, which no target reads; the fourth is evidence and has no code."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm upgrade outside a make target."
echo "#"
echo "# The checkout is at commit 1, the commit whose subject is"
echo "#   fix(telemetry): the four nits from the follow-ups 14 review"
echo "# Check any ID below with  git rev-parse <that commit>:<path>"
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
	printf '#   %-18s %s\n' "$p" "$(git rev-parse "HEAD:$p")"
done
echo "#   experiments/*.sh blobs:"
for f in experiments/*.sh; do printf '#     %-44s %s\n' "$f" "$(git rev-parse "HEAD:$f")"; done
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
echo "## the clusters that exist before the teardown (none is expected: the controller reported no cluster)"
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
