#!/usr/bin/env bash
# Follow-ups 11 rebuild driver. From a deleted cluster, at commit 1's tree, with Istio installed by Helm only.
# Runs from the repository root. Writes its log OUTSIDE the repository (the scratchpad) while it runs; the log
# and this script are copied into experiments/runs/2026-09-15-helm-only/rebuild/ afterwards, so the working
# tree stays clean for the whole build. No manual step: only the seven make targets, in order, each timed.
# Between two targets the only thing that runs is the deployed-paths status read and the log lines.
# Stops at the first non-zero exit.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>/66d7e8b2-1689-4b6c-8c8f-fe5fd39c2cad/scratchpad/rebuild
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
DEPLOYED=(deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)

T0=$(now)
{
echo "# Follow-ups 11 -- from a deleted cluster, at commit 1's tree, with Istio installed by Helm only and the"
echo "# istioctl installation route retired. No manual step is permitted: no pod deletion, no rollout restart, no"
echo "# helm upgrade outside a make target. Started $(ts) (epoch $T0)."
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
echo
echo "## the cluster being deleted (built by the author's walkthrough on main at 896917a through step 3)"
kind get clusters
helm list -A 2>&1
} > "$LOG" 2>&1
echo "step,started_utc,started_epoch,finished_utc,finished_epoch,wall_s,exit" > "$TIM"
T1=$(now)
echo "## header and cluster-being-deleted reads: $(perl -e "printf '%.3f', $T1 - $T0") s" >> "$LOG"
echo >> "$LOG"

run() { # $1 = target
	local target="$1" s e rc dirty
	dirty=$(git status --short -- "${DEPLOYED[@]}")
	echo "## git status --short over the deployed paths before make $target -> ${dirty:-(empty)}" >> "$LOG"
	if [ -n "$dirty" ]; then echo "STOP: deployed paths not clean before make $target" | tee -a "$LOG"; exit 1; fi
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
TE=$(now)
echo "# build finished $(ts) (epoch $TE); from the first line of this log $(perl -e "printf '%.3f', $TE - $T0") s" >> "$LOG"
echo "$(ts) done"
