#!/usr/bin/env bash
# Follow-ups 14 rebuild driver. From a deleted cluster, at commit 1's tree: the GenAI and agent semantic
# conventions on the trace -- every model call a `chat <model>` span, every A2A call an `invoke_agent <name>`
# span -- with the two comment corrections carried over from the follow-ups 12 review, which is why this build
# proves the Makefile as changed. Runs from the repository root. Writes its log OUTSIDE the repository (the
# scratchpad) while it runs; the log and this script are copied into
# experiments/runs/2026-09-16-genai-spans/rebuild/ afterwards, so the working tree stays clean for the whole
# build. No manual step: only the seven make targets, in order, each timed. Between two targets the only thing
# that runs is the deployed-paths status read and the log lines. Stops at the first non-zero exit.
# Adapted from experiments/runs/2026-09-15-ingress-namespace/rebuild/rebuild.sh (followups-12): header text and
# paths only.
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
SCR=<scratchpad>/ac11db11-eb1e-4bd8-aaaf-549495fad506/scratchpad/rebuild
LOG="$SCR/build.txt"
TIM="$SCR/timings.csv"
cd "$REPO"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
DEPLOYED=(deploy Makefile agents fixtures experiments/lib experiments/*.sh .ko.yaml go.mod go.sum internal kind-config.yaml)

T0=$(now)
{
echo "# Follow-ups 14 -- from a deleted cluster, at commit 1's tree: the GenAI and agent semantic conventions on the"
echo "# trace (every model call a chat span, every A2A call an invoke_agent span), and the two comment corrections"
echo "# carried over from the follow-ups 12 review, one of them in the Makefile this build runs."
echo "# No manual step is permitted: no pod deletion, no rollout restart, no helm upgrade outside a make target."
echo "#"
echo '#'
echo '# THIS BUILD SUPERSEDES A FIRST ONE, 2026-09-16. The first proof was taken at the tree commit 1 had before'
echo '# the review of this task, whose deployed subtrees were agents d38d1a0588b0186f43d2326e66c24dd8c42f8002,'
echo '# fixtures e7a19ac9dc6d09408302784d1914568e0ff178e6 and internal 92ef75f50c8593368e173e289c4811cf969f7b17'
echo '# (deploy, Makefile, experiments/lib, .ko.yaml, go.mod, go.sum and kind-config.yaml are the same objects in'
echo '# both). Two attributes were then added to the spans this lab writes -- gen_ai.agent.description on the'
echo '# invoke_agent spans, and gen_ai.response.model, gen_ai.response.finish_reasons and server.address/port on'
echo '# the chat span -- so the proof was re-taken at the tree below and this run directory had its records'
echo '# replaced in place. THE FIRST PROOF COUNTED THE SAME NUMBERS as this one wherever the two are comparable:'
echo '# the clean check 1/1/1/1/1 on both receivers, 14 and 69 spans with 0 dangling parents, and the three'
echo '# matrix rows at REPS=5 with 46 count columns matching the committed ones. What the added attributes'
echo '# changed is what each span carries, which is what the attribute checks in trace/genai/ now read, and no'
echo '# count.'
echo '#'
echo '# Three earlier builds of this round are not counted and rebuild/attempts.txt lists them all: one abandoned'
echo '# after step-1 because a run-directory file was edited while it ran and the checkout was not clean, one'
echo '# complete but with a garbled header because apostrophes broke this driver quoting, and one complete whose'
echo '# tree was superseded when a comment in internal/otel was corrected against what that build measured -- the'
echo '# model endpoint is model.lab.internal, not the mock behind the egress waypoint. Their counts were the same'
echo '# as this one throughout. The original note:'
echo '# An attempt at 00:22:58Z was abandoned 71 s in, after make step-1, and is not counted: a run-directory'
echo '# file was edited while it ran, so the checkout was not clean and ko stamped vcs.modified=true into the'
echo '# two Go binaries. No deployed path was touched and the deployed-paths guard passed, but a build whose'
echo '# record cannot say the tree was clean is not a proof. That log is kept outside the repository. This run'
echo '# started from the teardown again, with nothing in flight.'
echo '#'
echo '# The checkout is at commit 2, whose deployed subtrees ARE commit 1s -- commit 2 adds run records and'
echo '# findings.md and touches no deployed path. Check any of them with'
echo '#   git rev-parse <the commit whose subject starts feat(telemetry): GenAI and agent semantic conventions>:<path>'
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
echo "## the cluster being deleted (built by the followups-12 proof, 2026-09-15, at the deployed tree of the commit"
echo "## \"refactor(deploy): the agentgateway ingress in its own ambient namespace; the control-plane namespace left out of the mesh\")"
kind get clusters
helm list -A 2>&1
kubectl get ns -L istio.io/dataplane-mode 2>&1
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
