#!/usr/bin/env bash
# Follow-ups 10 rebuild driver. Runs from the repository root. Writes its log OUTSIDE the
# repository (the scratchpad) and is copied into the run directory afterwards.
# Order: the step targets in sequence, with the Gate 1 baselines at the steps the checklist
# and the 2026-09-07/08 entries ran them. No manual step: only make targets and the committed
# baseline script (through make verify-baseline). Stops at the first non-zero exit.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>/5008ee34-eeb0-4d7c-a82b-45488493edbc/scratchpad/rebuild
RUNREL=2026-09-12-current-versions
mkdir -p "$SCR"
LOG="$SCR/build.txt"
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

{
echo "# Follow-ups 10 -- from a deleted cluster, on the Helm route, at commit 1's tree, with every"
echo "# component at the latest release read on 2026-09-12. No manual step is permitted: no pod"
echo "# deletion, no rollout restart, no helm upgrade outside a make target. The Gate 1 baselines run"
echo "# at the steps the checklist ran them (step 1 no mesh, step 2, step 2b), through the committed"
echo "# script, between the step targets; every second between two targets is one of those runs or"
echo "# a recorded read. Started $(ts)."
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
echo "# helm:     $(helm version --short)"
echo "# kubectl:  $(kubectl version --client 2>/dev/null | head -1)"
echo "# istioctl: $(istioctl version --remote=false 2>/dev/null)"
echo "# kind:     $(kind version)"
echo "# ko:       $(ko version)"
echo "# docker:   $(docker version --format '{{.Client.Version}} (server {{.Server.Version}})')"
echo "# go:       $(go version)"
echo "# uv:       $(uv --version)"
echo
echo "## the cluster being deleted"
kind get clusters
helm list -A 2>&1
} > "$LOG" 2>&1

run() { # $1 = label, rest = command
	local label="$1"; shift
	local s e rc
	s=$(date -u +%s)
	echo "## ${label}  started $(ts)" >> "$LOG"
	local dirty
	dirty=$(git status --short -- deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)
	echo "## git status --short over the deployed paths -> ${dirty:-(empty)}" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	e=$(date -u +%s)
	echo "## ${label}  finished $(ts)  exit=${rc}  wall=$((e - s))s" >> "$LOG"
	echo >> "$LOG"
	echo "$(ts) ${label} exit=${rc} wall=$((e - s))s"
	if [ "$rc" -ne 0 ]; then echo "STOP: ${label} exited ${rc}" | tee -a "$LOG"; exit "$rc"; fi
}

run "make teardown"      make teardown
run "make cluster-kind"  make cluster-kind
run "make step-1"        make step-1
run "make verify-baseline STEP=1 REPS=5 RUN_ITEM=${RUNREL}/baseline-step1" \
	make verify-baseline STEP=1 REPS=5 RUN_ITEM="${RUNREL}/baseline-step1"
run "make step-2"        make step-2
run "make verify-baseline STEP=2 REPS=5 RUNS=\"1 2 3 4\" RUN_ITEM=${RUNREL}/baseline-step2" \
	make verify-baseline STEP=2 REPS=5 RUNS="1 2 3 4" RUN_ITEM="${RUNREL}/baseline-step2"
run "make step-2b"       make step-2b
run "make verify-baseline STEP=2b REPS=5 RUNS=\"1 2 3 4\" RUN4_URL=http://agentgateway-ingress.agentgateway-system.svc.cluster.local RUN_ITEM=${RUNREL}/baseline-step2b" \
	make verify-baseline STEP=2b REPS=5 RUNS="1 2 3 4" RUN4_URL=http://agentgateway-ingress.agentgateway-system.svc.cluster.local RUN_ITEM="${RUNREL}/baseline-step2b"
run "make verify-baseline STEP=2b REPS=5 RUNS=\"5 6\" RUN_ITEM=${RUNREL}/openai-runs-5-6" \
	make verify-baseline STEP=2b REPS=5 RUNS="5 6" RUN_ITEM="${RUNREL}/openai-runs-5-6"
run "make step-2c"       make step-2c
run "make step-3"        make step-3
echo "# build finished $(ts)" >> "$LOG"
echo "$(ts) done"
