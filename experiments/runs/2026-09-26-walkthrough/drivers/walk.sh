#!/usr/bin/env bash
# Follow-ups 24: the walkthrough's run, extended to every row of Experiments B and C. From a deleted cluster, every
# command the three walkthrough files show (docs/walkthrough.md, then docs/walkthrough-b.md, then docs/walkthrough-c.md),
# in their order, each once, each logged whole to logs/NN-<label>.txt as "$ <the command as run>", its stdout and
# stderr, and a last line "wall <s>s exit <n>"; the second line of every log names the istioctl on PATH at the step's
# start (the controller's ruling of 2026-09-26). The make targets and every experiment driver also get a timings.csv row.
# The commands are the reader's, with one difference the walkthrough states: every path that names the reader's
# directory experiments/runs/my-walkthrough names this record's directory, experiments/runs/@D@, where @D@ is this
# run's name; the token @D@ in the command strings below is replaced by $D before the command runs, and the log's
# "$ " header shows the command as it ran. Adapted from experiments/runs/2026-09-25-walkthrough/drivers/walk.sh (the
# steps of the existing walkthrough, 00 to 24, are that driver's, unchanged but for the token); everything from step
# 30 on is new.
# The tools: the walkthrough's own "Before you start" block (setup-tools.sh beside this file, sourced once, logged as
# 00a), which fetches istioctl 1.31.1 and its published checksum, verifies it, puts it first on PATH for this shell,
# and sets an empty Helm scope. Nothing on the host changes.
# Stop rule: the first exit code a step does not allow stops the driver (most steps allow 0 only; a step that shows a
# diff of a copy against its original allows 1, and C-9's clean check under the A2A marking, which its entry records
# as failing, allows 1). No retry: each command runs once. Keep-awake: this driver starts none and changes no power
# setting; keep-awake is not claimed absent on the host.
# $WALK_SCRATCH: where the logs and timings are written while it runs (outside the repository). $D: the run
# directory's name under experiments/runs/.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
: "${WALK_SCRATCH:?}" "${D:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L="$WALK_SCRATCH/logs"; mkdir -p "$L"
TIM="$WALK_SCRATCH/timings.csv"; echo "label,started_utc,finished_utc,wall_s,exit" > "$TIM"
WIN="$WALK_SCRATCH/windows.csv"
R="experiments/runs/$D"
mkdir -p "$R"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
# run <file> <timed label or -> <allowed exit codes, space-separated> <command string>
run() {
	local f="$1" label="$2" ok="$3" cmd="$4" s e rc st
	cmd="${cmd//@D@/$D}"
	st=$(ts); s=$(now)
	printf '$ %s\n' "$cmd" > "$L/$f.txt"
	echo "# istioctl on PATH at this step's start: $(istioctl version --remote=false 2>/dev/null)" >> "$L/$f.txt"
	bash -c "$cmd" >> "$L/$f.txt" 2>&1
	rc=$?
	e=$(now)
	local w; w=$(perl -e "printf '%.3f', $e - $s")
	echo "wall ${w}s exit $rc" >> "$L/$f.txt"
	[ "$label" = "-" ] || echo "$label,$st,$(ts),$w,$rc" >> "$TIM"
	echo "$(ts) $f exit=$rc wall=${w}s"
	case " $ok " in *" $rc "*) ;; *) echo "walk driver: $f exited $rc (allowed: $ok); stopping"; echo "run,$T0UTC,$(ts)" > "$WIN"; exit "$rc" ;; esac
}
# step <file> <label> <allowed exits>  -- the command string on stdin (a heredoc), so that any quoting inside it is the reader's
step() { local cmd; cmd=$(cat); run "$1" "$2" "$3" "$cmd"; }

T0UTC=$(ts)
echo "$T0UTC walk start; HEAD $(git rev-parse HEAD); tree $(git rev-parse 'HEAD^{tree}'); status: $(git status --short | tr '\n' ' ')"

# --- Before you start: the reader's tools --------------------------------------------------------------------
{ printf '$ %s\n' "$(cat "$HERE/setup-tools.sh")"; } > "$L/00a-lab-tools.txt"
s=$(now)
# shellcheck disable=SC1091
source "$HERE/setup-tools.sh" >> "$L/00a-lab-tools.txt" 2>&1
rc=0; istioctl version --remote=false 2>/dev/null | grep -qx 'client version: 1.31.1' || rc=1
[ -x "$LAB_TOOLS/istioctl" ] || rc=1
echo "wall $(perl -e "printf '%.3f', $(now) - $s")s exit $rc" >> "$L/00a-lab-tools.txt"
echo "$(ts) 00a-lab-tools exit=$rc"
[ "$rc" = "0" ] || { echo "walk driver: the lab-scoped istioctl is not in place; stopping"; exit 1; }

# --- Step 0 ----------------------------------------------------------------------------------------------------
run 00-teardown teardown 0 'make teardown'
run 01-cluster-kind cluster-kind 0 'make cluster-kind'
run 01b-nodes-ready - 0 'kubectl wait --for=condition=Ready nodes --all --timeout=180s'
run 01c-get-nodes - 0 'kubectl get nodes'

# --- Step 1 ----------------------------------------------------------------------------------------------------
run 02-step-1 step-1 0 'make step-1'
run 02b-after-step-1 - 0 'kubectl -n lab get deploy,svc,pods -o wide; echo; kubectl -n lab get serviceaccounts'
run 03-mockllm-deterministic mockllm-deterministic 0 'experiments/gate1-mockllm-deterministic.sh'
mkdir -p "$R/step-1/mockllm-deterministic"
cp experiments/runs/2026-09-05-mockllm-deterministic/summary.csv experiments/runs/2026-09-05-mockllm-deterministic/invocation.jsonl "$R/step-1/mockllm-deterministic/"
run 03b-restore-deterministic - 0 'git checkout -- experiments/runs/2026-09-05-mockllm-deterministic/; git status --short -- experiments/runs/2026-09-05-mockllm-deterministic/'
run 04-step-1-clean step-1-clean 0 'RUN_ID=wt1 RUN_ITEM=@D@/step-1/clean experiments/gate2-single-clean.sh'
run 05-ledgers-worker - 0 'make ledgers LWI=g2c-wt1-worker'

# --- Step 2 ----------------------------------------------------------------------------------------------------
run 06-step-2 step-2 0 'make step-2'
run 06b-helm-list - 0 'helm list -A'
run 06c-ztunnel-workloads - 0 'istioctl ztunnel-config workloads'
run 06d-svc-labels - 0 "kubectl -n lab get svc worker -o jsonpath='{.metadata.labels}'; echo"
run 06e-certificates - 0 'istioctl ztunnel-config certificates --node agent-mesh-lab-worker'
run 07-step-2-clean step-2-clean 0 'RUN_ID=wt2 RUN_ITEM=@D@/step-2/clean experiments/gate2-single-clean.sh'
run 07b-access-logs - 0 "echo '## agw-central request line'; kubectl -n agentgateway-waypoint logs deploy/agw-central | grep 'http.path=/ ' | head -1; echo; echo '## ztunnel access line'; kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep 'loadgen-g2c-wt2-worker' | grep access"
step 07c-plaintext-probe - 0 <<'EOF'
kubectl -n default run mtls-probe --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 300
kubectl -n default wait --for=condition=Ready pod/mtls-probe --timeout=90s
for h in worker orchestrator; do
  echo "## $h"
  kubectl -n default exec mtls-probe -- curl -sS -o /dev/null -w "http=%{http_code} exit=%{exitcode}\n" --retry 0 \
    --connect-timeout 5 --max-time 10 "http://$h.lab.svc.cluster.local:8080/.well-known/agent-card.json"; echo "exit=$?"
done
echo "## ztunnel policy rejections"
kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep "policy rejection" | tail -2
kubectl -n default delete pod mtls-probe
EOF

# --- Step 2b ---------------------------------------------------------------------------------------------------
run 08-step-2b step-2b 0 'make step-2b'
run 08b-gateways-ns - 0 'kubectl get gateway -A; echo; kubectl get ns -L istio.io/dataplane-mode'
step 08c-model-url - 0 <<'EOF'
kubectl -n lab get deploy orchestrator worker -o json | jq -r '.items[] | .metadata.name + ": " +
  ([.spec.template.spec.containers[0].env[]? | select(.name=="MODEL_BASE_URL" or .name=="PUBLIC_URL") |
  "\(.name)=\(.value)"] | join(" "))'
EOF
run 08d-extauthz - 0 'kubectl -n lab get deploy,svc extauthz -o wide'
run 09-step-2b-clean step-2b-clean 0 'RUN_ID=wt2b RUN_ITEM=@D@/step-2b/clean experiments/gate2-single-clean.sh'
run 09b-model-leg - 0 "echo '## agw-central model-route lines'; kubectl -n agentgateway-waypoint logs deploy/agw-central | grep chat/completions | tail -2; echo; echo '## mockllm invocation ledger, both clean work items'; kubectl -n lab logs deploy/mockllm | grep -E 'g2c-wt2b-(worker|orchestrator)'"
step 09c-ingress-card-and-send - 0 <<'EOF'
S="${TMPDIR:-/tmp}"
kubectl -n agentgateway-ingress port-forward svc/agentgateway-ingress 18080:80 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 30); do
  curl -sS -o /dev/null --max-time 2 http://127.0.0.1:18080/.well-known/agent-card.json 2>/dev/null && break
  python3 -c "import time;time.sleep(1)"
done
echo "## the card the ingress serves"
curl -s http://127.0.0.1:18080/.well-known/agent-card.json | jq -c "{name, supportedInterfaces}"
echo
echo "## the advertised address, resolved from this host"
curl -sS -o /dev/null --max-time 5 http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local/ ; echo "exit=$?"
echo
echo "## the send, by hand"
LWI=wt2b-ingress
OUT="${TMPDIR:-/tmp}/ingress-resp.json"
curl -s -o "$OUT" -w "http=%{http_code}\n" -X POST http://127.0.0.1:18080/ \
  -H "Host: orchestrator.lab.internal" -H "Content-Type: application/json" -H "A2A-Version: 1.0" \
  -H "X-Logical-Work-Item-Id: $LWI" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"$(uuidgen)\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(uuidgen)\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"lwi:$LWI hello\"}],\"metadata\":{\"logical_work_item_id\":\"$LWI\"}}}}"
echo
echo "## the answer"
jq -c "{taskId: .result.task.id, contextId: .result.task.contextId, state: .result.task.status.state}" "$OUT"
kill "$PF" >/dev/null 2>&1 || true
wait "$PF" >/dev/null 2>&1 || true
echo "## port-forward closed"
EOF
run 09d-ingress-ledgers - 0 'make ledgers LWI=wt2b-ingress OUT=experiments/runs/@D@/step-2b/ingress'

# --- Step 2c ---------------------------------------------------------------------------------------------------
run 10-step-2c step-2c 0 'make step-2c'
step 10b-step-2c-reads - 0 <<'EOF'
kubectl get httproute -A; echo; kubectl get grpcroute -A; echo; kubectl -n lab get svc -o json | jq -r '.items[] |
  "\(.metadata.name)  istio.io/use-waypoint=\(.metadata.labels["istio.io/use-waypoint"] // "-")"'
EOF

# --- Step 3 ----------------------------------------------------------------------------------------------------
run 11-step-3 step-3 0 'make step-3'
run 12-step-3-clean step-3-clean 0 'RUN_ID=wt3 RUN_ITEM=@D@/step-3/clean experiments/gate2-single-clean.sh'
run 13-step-3-trace step-3-trace 0 'REPS=2 RUN_ID=wt3 RUN_ITEM=@D@/step-3/trace experiments/gate3-trace-per-work-item.sh'
step 13b-dangling - 0 <<'EOF'
python3 experiments/runs/2026-09-16-genai-spans/trace/dangling.py \
  experiments/runs/@D@/step-3/trace
EOF
step 13c-worker-spans - 0 <<'EOF'
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    "experiments/runs/@D@/step-3/trace/a3t-wt3-r1-worker/spans.csv")))
for r in sorted(rows, key=lambda r: (r["trace_id"], int(r["start_us"]))):
    print("%-24s %-44s %s" % (r["service"], r["operation"], r["http_status"]))
PY
EOF
run 13d-spans-header - 0 'head -1 experiments/runs/@D@/step-3/trace/a3t-wt3-r1-worker/spans.csv'
step 13c2-agw-central-routes - 0 <<'EOF'
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    "experiments/runs/@D@/step-3/trace/a3t-wt3-r1-worker/spans.csv")))
for r in sorted(rows, key=lambda r: (r["trace_id"], int(r["start_us"]))):
    if r["service"] == "agw-central" and r["route"]:
        print("%-10s %-38s %s" % (r["operation"], r["route"], r["retry_attempt"] or "-"))
PY
EOF
step 13e-genai-spans - 0 <<'EOF'
mkdir -p experiments/runs/@D@/step-3/trace/genai
python3 experiments/runs/2026-09-16-genai-spans/genai-spans.py \
  experiments/runs/@D@/step-3/trace \
  experiments/runs/@D@/step-3/trace/genai
EOF
step 14-restart-orchestrator - 0 <<'EOF'
kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s
EOF
step 14b-step-3-trace-first-forward step-3-trace-first-forward 0 <<'EOF'
REPS=1 RECEIVERS=orchestrator RUN_ID=wt3f RUN_ITEM=@D@/step-3/trace-first-forward \
  experiments/gate3-trace-per-work-item.sh
EOF
run 15-prometheus-targets - 0 'experiments/runs/2026-09-12-mtls-enforced/promq.sh targets'
step 15b-jaeger-services - 0 <<'EOF'
kubectl -n telemetry port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 30); do curl -sS -o /dev/null --max-time 2 http://127.0.0.1:16686/api/v3/services >/dev/null 2>&1 && break; python3 -c "import time;time.sleep(1)"; done
curl -s http://127.0.0.1:16686/api/v3/services | jq -r ".services[]" | sort
kill "$PF" >/dev/null 2>&1 || true
wait "$PF" >/dev/null 2>&1 || true
exit 0
EOF

# --- Experiment A, six rows ------------------------------------------------------------------------------------
run 16-a1-m1-go a1-m1-go 0 'MODE=M1 RECEIVER=go REPS=2 RUN_ID=wta1 RUN_ITEM=@D@/a1-m1-go experiments/gate2-a1.sh'
step 17-a2-go-http-503 a2-go-http-503 0 <<'EOF'
CLIENT=go LAYER=http RETRY_ON=transport+503 REPS=2 RUN_ID=wta2 \
  RUN_ITEM=@D@/a2-go-http-503 experiments/gate2-a2.sh
EOF
step 18-a3-baseline-go a3-baseline-go 0 <<'EOF'
RUN=baseline RECEIVER=go REPS=2 RUN_ID=wta3b RUN_ITEM=@D@/a3-baseline-go \
  experiments/gate3-matrix.sh
EOF
step 19-a3-r1-go-http a3-r1-go-http 0 <<'EOF'
RUN=R1 RECEIVER=go SUB=http REPS=2 RUN_ID=wta3r1 RUN_ITEM=@D@/a3-r1-go-http \
  experiments/gate3-matrix.sh
EOF
step 19b-worker-span - 0 <<'EOF'
python3 experiments/runs/2026-09-19-currency-rebuild/worker-span/worker-span-reading.py \
  experiments/runs/@D@/a3-r1-go-http/a3m-r1-go-http-wta3r1-01
EOF
step 20-a3-egress-go a3-egress-go 0 <<'EOF'
RUN=egress RECEIVER=go REPS=1 RUN_ID=wta3e RUN_ITEM=@D@/a3-egress-go \
  experiments/gate3-matrix.sh
EOF
step 21-a3-r2-py-service a3-r2-py-service 0 <<'EOF'
RUN=R2 RECEIVER=py SUB=service REPS=2 RUN_ID=wta3s RUN_ITEM=@D@/a3-r2-py-service \
  experiments/gate3-matrix.sh
EOF

# --- The existing walkthrough's cleanup, as its text gives it -------------------------------------------------
step 22-cleanup-state - 0 <<'EOF'
echo "## retry stanzas across every HTTPRoute"
kubectl get httproute -A -o yaml | grep -c "retry:"
echo
echo "## client and model retry knobs on the lab Deployments"
kubectl -n lab get deploy -o json | jq -r '.items[] | .metadata.name as $n |
  ((.spec.template.spec.containers[0].env // [])[] |
  select(.name | startswith("CLIENT_") or . == "MODEL_RETRIES" or . == "MODEL_MAX_RETRIES") |
  "\($n): \(.name)=\(.value)")'
echo
echo "## the orchestrator downstream URL"
kubectl -n lab get deploy orchestrator -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="DOWNSTREAM_A2A_URL") | "\(.name)=\(.value)"'
echo
echo "## Jobs and finished pods left in lab"
kubectl -n lab get jobs --no-headers | wc -l | tr -d " " | sed "s/^/jobs: /"
kubectl -n lab get pods --no-headers | awk '{print $3}' | sort | uniq -c
echo
echo "## the Deployments standing in lab"
kubectl -n lab get deploy
EOF
step 23-cleanup-reset - 0 <<'EOF'
kubectl -n lab run wt-cleanup --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 60
kubectl -n lab wait --for=condition=Ready pod/wt-cleanup --timeout=60s
for u in mockllm worker orchestrator; do
  kubectl -n lab exec wt-cleanup -- curl -s -o /dev/null -w "$u/control/reset -> %{http_code}\n" \
    -X POST "http://$u.lab.svc.cluster.local:8080/control/reset"
done
kubectl -n lab delete pod wt-cleanup
EOF
run 24-my-walkthrough-size - 0 'du -sh experiments/runs/@D@ | cut -f1'
echo "$(ts) the existing walkthrough's steps are done"

# =============================================================================================================
# Experiment B (docs/walkthrough-b.md)
# =============================================================================================================
step 30-b-prerequisites - "0 1" <<'EOF'
mkdir -p "${TMPDIR:-/tmp}"/b4 "${TMPDIR:-/tmp}"/d1/work
mkdir -p experiments/runs/@D@/drivers
sed -e 's#^RUNREL=2026-09-21-b3-streaming-client$#RUNREL=@D@/b3#' \
    -e 's#-e "s/\\${TASK_ID}/${task}/g" \\$#-e "s/\\${TASK_ID}/${task}/g" -e "s/\\${CANCEL_AFTER_MS}//g" -e "s/\\${CLIENT_HOST}//g" \\#' \
    experiments/runs/2026-09-21-b3-streaming-client/rows.sh > experiments/runs/@D@/drivers/b3-rows.sh
diff experiments/runs/2026-09-21-b3-streaming-client/rows.sh experiments/runs/@D@/drivers/b3-rows.sh
EOF
step 30b-proxy-generations-before - 0 <<'EOF'
for g in agentgateway-ingress/agentgateway-ingress agentgateway-waypoint/agw-central; do
  kubectl -n "${g%%/*}" get deploy "${g##*/}" -o jsonpath='{.metadata.namespace}/{.metadata.name} generation={.metadata.generation} restartedAt=[{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}]{"\n"}'
done
EOF
run 31-b3-model-call b3-model-call 0 'RUN_ID=wtb3mc bash experiments/runs/@D@/drivers/b3-rows.sh model-call 2'
run 31b-b3-model-call-counts - 0 'python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/@D@/b3/model-call model-call 45000'
run 32-b3-stream b3-stream 0 'RUN_ID=wtb3st bash experiments/runs/@D@/drivers/b3-rows.sh stream 2'
run 32b-b3-stream-counts - 0 'python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/@D@/b3/stream stream 45000'
run 33-b3-subscribe-running b3-subscribe-running 0 'RUN_ID=wtb3sr bash experiments/runs/@D@/drivers/b3-rows.sh subscribe-running 2'
run 33b-b3-subscribe-running-counts - 0 'python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/@D@/b3/subscribe-running subscribe-running 45000'
run 34-b3-subscribe-terminal b3-subscribe-terminal 0 'RUN_ID=wtb3sx bash experiments/runs/@D@/drivers/b3-rows.sh subscribe-terminal 2'
run 34b-b3-subscribe-terminal-counts - 0 'python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/@D@/b3/subscribe-terminal subscribe-terminal 45000'
run 35-b4-control b4-control 0 'RUN_ID=wtb4 RUNREL=@D@/b4 bash experiments/runs/2026-09-22-b4-control/rows.sh 2'
run 35b-b4-counts - 0 'python3 experiments/runs/2026-09-22-b4-control/counts.py experiments/runs/@D@/b4/control 45000 5000'
run 36a-b5a-ingress-graceful b5a-ingress-graceful 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh ingress graceful 2'
run 36b-b5a-ingress-forced b5a-ingress-forced 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh ingress forced 2'
run 36c-b5a-ingress-rollout b5a-ingress-rollout 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh ingress rollout 2'
run 36d-b5a-central-graceful b5a-central-graceful 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh central graceful 2'
run 36e-b5a-central-forced b5a-central-forced 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh central forced 2'
run 36f-b5a-central-rollout b5a-central-rollout 0 'RUN_ID=wtb5a RUNREL=@D@/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh central rollout 2'
run 36g-b5a-counts - 0 'python3 experiments/runs/2026-09-22-b5a-removal/counts.py experiments/runs/@D@/b5a/removal 45000'
run 37a-b5b-py-ingress-forced b5b-py-ingress-forced 0 'RUN_ID=wtb5b RUNREL=@D@/b5b bash experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh py ingress forced 2'
run 37b-b5b-py-central-graceful b5b-py-central-graceful 0 'RUN_ID=wtb5b RUNREL=@D@/b5b bash experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh py central graceful 2'
run 37c-b5b-go-ingress-forced b5b-go-ingress-forced 0 'RUN_ID=wtb5b RUNREL=@D@/b5b bash experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh go ingress forced 2'
run 37d-b5b-go-central-graceful b5b-go-central-graceful 0 'RUN_ID=wtb5b RUNREL=@D@/b5b bash experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh go central graceful 2'
run 37e-b5b-counts - 0 'python3 experiments/runs/2026-09-22-b5b-removal-resubscribe/counts.py experiments/runs/@D@/b5b/rows 45000'
run 38a-d1-go-ingress-rollout d1-go-ingress-rollout 0 'RUN_ID=wtd1r RUNREL=@D@/d1-rollout bash experiments/runs/2026-09-24-d1-current-topology/rows.sh go ingress rollout 2'
run 38b-d1-py-ingress-rollout d1-py-ingress-rollout 0 'RUN_ID=wtd1r RUNREL=@D@/d1-rollout bash experiments/runs/2026-09-24-d1-current-topology/rows.sh py ingress rollout 2'
run 38c-d1-rollout-counts - 0 'python3 experiments/runs/2026-09-22-b5b-removal-resubscribe/counts.py experiments/runs/@D@/d1-rollout/rows 45000'
run 39-d1-pyclient d1-pyclient 0 'RUN_ID=wtd1p RUNREL=@D@/d1-pyclient bash experiments/runs/2026-09-24-d1-current-topology/pyclient.sh 2'
run 39b-d1-pyclient-counts - 0 'python3 experiments/runs/2026-09-24-d1-current-topology/pyclient-counts.py experiments/runs/@D@/d1-pyclient/rows/pyclient-central-graceful'
step 39c-proxy-generations-after - 0 <<'EOF'
for g in agentgateway-ingress/agentgateway-ingress agentgateway-waypoint/agw-central; do
  kubectl -n "${g%%/*}" get deploy "${g##*/}" -o jsonpath='{.metadata.namespace}/{.metadata.name} generation={.metadata.generation} restartedAt=[{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}]{"\n"}'
done
EOF
echo "$(ts) Experiment B's rows are done"

# =============================================================================================================
# Experiment C, the standing configuration (docs/walkthrough-c.md)
# =============================================================================================================
step 50-c-prerequisites - "0 1" <<'EOF'
mkdir -p "${TMPDIR:-/tmp}"/c5/ko-build-@D@ "${TMPDIR:-/tmp}"/d2/ko-build-@D@ "${TMPDIR:-/tmp}"/d3 "${TMPDIR:-/tmp}"/d3b "${TMPDIR:-/tmp}"/c8 "${TMPDIR:-/tmp}"/c9
mkdir -p experiments/runs/@D@/drivers experiments/runs/@D@/c3c4 experiments/runs/@D@/c3r experiments/runs/@D@/c3r2
for f in send-one.sh counts.sh proxy-spans.sh; do
  sed -e 's#^R="experiments/runs/2026-09-21-c3-c4-ztunnel"$#R="experiments/runs/@D@/c3c4"#' \
    experiments/runs/2026-09-21-c3-c4-ztunnel/$f > experiments/runs/@D@/drivers/c3c4-$f
done
sed -e 's#^R="experiments/runs/2026-09-21-c3r-open-connections"$#R="experiments/runs/@D@/c3r"#' \
  experiments/runs/2026-09-21-c3r-open-connections/rep.sh > experiments/runs/@D@/drivers/c3r-rep.sh
sed -e 's#^R="experiments/runs/2026-09-21-c3r2-public-server"$#R="experiments/runs/@D@/c3r2"#' \
  experiments/runs/2026-09-21-c3r2-public-server/rep.sh > experiments/runs/@D@/drivers/c3r2-rep.sh
for f in send-one.sh counts.sh proxy-spans.sh; do diff experiments/runs/2026-09-21-c3-c4-ztunnel/$f experiments/runs/@D@/drivers/c3c4-$f; done
diff experiments/runs/2026-09-21-c3r-open-connections/rep.sh experiments/runs/@D@/drivers/c3r-rep.sh
diff experiments/runs/2026-09-21-c3r2-public-server/rep.sh experiments/runs/@D@/drivers/c3r2-rep.sh
cp -R experiments/runs/2026-09-21-c3-c4-ztunnel/overlay-c3 experiments/runs/2026-09-21-c3-c4-ztunnel/overlay-c4 experiments/runs/2026-09-21-c3-c4-ztunnel/rec.sh experiments/runs/@D@/c3c4/
cp -R experiments/runs/2026-09-21-c3r-open-connections/objects experiments/runs/2026-09-21-c3r-open-connections/rec.sh experiments/runs/2026-09-21-c3r-open-connections/responses.py experiments/runs/2026-09-21-c3r-open-connections/counts.py experiments/runs/@D@/c3r/
WORKER_IMAGE=$(kubectl -n lab get deploy worker -o jsonpath='{.spec.template.spec.containers[0].image}')
sed -e "s#^\(          image: \).*#\1$WORKER_IMAGE#" experiments/runs/2026-09-21-c3r-open-connections/objects/server.yaml > experiments/runs/@D@/c3r/objects/server.yaml
diff experiments/runs/2026-09-21-c3r-open-connections/objects/server.yaml experiments/runs/@D@/c3r/objects/server.yaml
cp -R experiments/runs/2026-09-21-c3r2-public-server/objects experiments/runs/2026-09-21-c3r2-public-server/rec.sh experiments/runs/2026-09-21-c3r2-public-server/responses.py experiments/runs/2026-09-21-c3r2-public-server/counts.py experiments/runs/@D@/c3r2/
EOF

# --- C-1, the observation ---------------------------------------------------------------------------------------
step 51-c1-observation c1-observation 0 <<'EOF'
S=$(date -u +%FT%TZ)
RUN_ID=wtc1 RUN_ITEM=@D@/c1 experiments/gate2-single-clean.sh
for w in worker orchestrator; do make export-trace LWI=g2c-wtc1-$w OUT=experiments/runs/@D@/c1/g2c-wtc1-$w; done
echo "$S" > experiments/runs/@D@/c1/window-start.txt
EOF
step 51b-c1-layers - 0 <<'EOF'
C=experiments/runs/@D@/c1; S=$(cat $C/window-start.txt)
echo "## the routes, as they stand"
while read -r ns name; do kubectl -n "$ns" get httproute "$name" -o json \
    | jq -c '{parents:[.spec.parentRefs[]|"\(.namespace // "-")/\(.name)"], hostnames:(.spec.hostnames // []),
             rules:[.spec.rules[]|{matches:(.matches // []), filters:([(.filters//[])[].type]),
                                   backends:[(.backendRefs//[])[]|"\(.name):\(.port // "-")"], retry:(.retry // null)}]}'
  done < <(kubectl get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}') | tee $C/routes.txt
kubectl -n lab get svc worker orchestrator mockllm -o json \
    | jq -r '.items[] | "\(.metadata.name): " + ([.spec.ports[] | "name=\(.name // "-") port=\(.port) appProtocol=\(.appProtocol // "<none>")"] | join("; "))' | tee -a $C/routes.txt
echo "## every policy each proxy holds, and the strings a2a, authorization, jwt, extAuth, rateLimit in its config_dump"
for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
  set -- $pair
  bash experiments/runs/2026-09-19-waypoint-policy-recheck/config-dump.sh "$1" "$2" $C/config-dump-$2.json | head -4
  for s in a2a authorization jwt extAuth rateLimit; do printf '%s "%s"=%s ' "$2" "$s" "$(grep -o "\"$s\"" $C/config-dump-$2.json | wc -l | tr -d ' ')"; done; echo
done | tee $C/config-dump-policies.txt
kubectl get agentgatewaypolicy -A --no-headers | wc -l | tr -d ' ' | sed 's/^/AgentgatewayPolicy objects: /' | tee -a $C/config-dump-policies.txt
kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/AuthorizationPolicy objects: /' | tee -a $C/config-dump-policies.txt
echo "## both proxies' request lines of the window"
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$S | grep 'request gateway=' > $C/agw-central-access.txt
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$S | grep 'request gateway=' > $C/ingress-access.txt
echo "agw-central request lines: $(wc -l < $C/agw-central-access.txt | tr -d ' '), carrying src.identity: $(grep -c 'src.identity=' $C/agw-central-access.txt); distinct path/method pairs on route=lab/worker: $(grep 'route=lab/worker ' $C/agw-central-access.txt | grep -o 'http.method=[A-Z]* http.host=[^ ]* http.path=[^ ]*' | sed 's/http.host=[^ ]* //' | sort -u | wc -l | tr -d ' ')"
echo "ingress request lines: $(wc -l < $C/ingress-access.txt | tr -d ' '), carrying src.identity: $(grep -c 'src.identity=' $C/ingress-access.txt)"
echo "## every attribute on every proxy SERVER span of the two work items"
for w in worker orchestrator; do
  jq -r --arg w "$w" '.result.resourceSpans[]? | (.resource.attributes[]? | select(.key=="service.name") | .value.stringValue) as $svc
    | select($svc == "agw-central" or $svc == "agentgateway-ingress") | .scopeSpans[]?.spans[]? | select(.kind == 2 or .kind == "SPAN_KIND_SERVER")
    | "\($w) \($svc) \(.name) attrs=\(.attributes | length) src.identity=\([.attributes[] | select(.key=="src.identity")] | length) a2a_keys=\([.attributes[] | select(.key | startswith("a2a."))] | length) protocol=\([.attributes[] | select(.key=="protocol") | .value.stringValue] | join(","))"' \
    $C/g2c-wtc1-$w/trace.json
done | tee $C/proxy-span-attributes.txt
echo "## ztunnel, the node that runs every lab pod: what its lines carry"
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-system logs "$ZT" --since-time=$S > $C/ztunnel-window.txt
echo "lines in the window: $(wc -l < $C/ztunnel-window.txt | tr -d ' ')"
for s in messageId taskId SendMessage http.method http.path agent-card; do printf 'lines naming %-12s %s\n' "$s" "$(grep -c "$s" $C/ztunnel-window.txt)"; done
echo "lines naming the work item g2c-wtc1: $(grep -c 'g2c-wtc1' $C/ztunnel-window.txt); of them outside a src.workload= or dst.workload= token: $(grep 'g2c-wtc1' $C/ztunnel-window.txt | sed 's/src.workload="[^"]*"//; s/dst.workload="[^"]*"//' | grep -c 'g2c-wtc1')"
echo "## the proxy-to-receiver legs at ztunnel's inbound side (source identity, connection security)"
grep 'connection complete' $C/ztunnel-window.txt | grep 'direction="inbound"' | grep -E 'dst.workload="(worker|orchestrator)-' | grep -o 'src.identity="[^"]*"' | sort | uniq -c
experiments/runs/2026-09-12-mtls-enforced/promq.sh security > $C/ztunnel-series.txt 2>&1
grep -E '"destination_workload": "(worker|orchestrator)"' $C/ztunnel-series.txt | jq -r '[.reporter, .connection_security_policy, .source_workload, .source_principal, .destination_workload] | @tsv' | sort | uniq -c
echo "## the ledgers: what the application recorded before the SDK"
cat $C/g2c-wtc1-worker/ingress.jsonl $C/g2c-wtc1-orchestrator/ingress.jsonl | jq -r 'select(.phase=="arrival") | "\(.source) method=\(.method) a2a_version=\(.a2a_version) remote=\(.remote) messageId=\(.messageId | .[0:8]) taskId=[\(.taskId)] body_sha256=\(.body_sha256 | .[0:8]) keys=\(keys | join(","))"'
cat $C/g2c-wtc1-worker/execution.jsonl $C/g2c-wtc1-orchestrator/execution.jsonl | jq -r 'select(.event=="execute") | "\(.source) execute taskId=\(.taskId | .[0:8])"'
cat $C/g2c-wtc1-worker/invocation.jsonl $C/g2c-wtc1-orchestrator/invocation.jsonl | jq -r '"invocation caller=\(.caller) lwi=\(.logical_work_item_id) messageId=\(.messageId | .[0:8]) taskId=\(.taskId | .[0:8])"'
EOF

# --- C-3 and C-4, ztunnel's ALLOW on the worker -------------------------------------------------------------------
step 52-c3-c4 c3-c4 0 <<'EOF'
C=experiments/runs/@D@/c3c4; REC=$C/rec.sh; SO=experiments/runs/@D@/drivers/c3c4-send-one.sh
node=agent-mesh-lab-worker
bash $REC $C/start-state.txt "kubectl get authorizationpolicy -A; kubectl get peerauthentication -A; kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
echo "== P0, no policy =="
bash $SO p0-nopolicy direct c34-p0-direct
bash $SO p0-nopolicy ingress c34-p0-ingress
A=$(date -u +%FT%TZ)
echo "== C-3: the waypoint page's ALLOW on the worker, applied at $A =="
bash $REC $C/c3-policy.txt "kubectl apply -k $C/overlay-c3"
for i in $(seq 1 60); do n=$(istioctl ztunnel-config policy --node $node -o json 2>/dev/null | jq '[.[] | select(.name=="require-agw-central")] | length'); [ "${n:-0}" -ge 1 ] && { echo "ztunnel holds the policy after ${i}s"; break; }; sleep 1; done
bash $REC $C/c3-policy.txt "kubectl get authorizationpolicy -A"
bash $REC $C/c3-policy.txt "istioctl ztunnel-config policy --node $node -o json"
bash $REC $C/c3-policy.txt "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
RUN_ID=c3 RUN_ITEM=@D@/c3c4 experiments/gate2-single-clean.sh
bash $SO c3-l4 direct c34-c3-direct || echo "send-one exit=$? (a refused send leaves no ledger line, and make ledgers exits 1)"
bash $SO c3-l4 ingress c34-c3-ingress || echo "send-one exit=$?"
bash $REC $C/c3-istiod.txt "kubectl -n istio-system logs deploy/istiod --since-time=$A"
bash $REC $C/c3-ztunnel.txt "kubectl -n istio-system get pods -l app=ztunnel -o wide"
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/c3-ztunnel.txt "kubectl -n istio-system logs $ZT --since-time=$A"
bash $REC $C/c3-ztunnel-connections.txt "istioctl ztunnel-config connections --node $node -o json"
bash $REC $C/c3-proxies.txt "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$A | grep 'route=lab/worker'"
bash $REC $C/c3-proxies.txt "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$A | grep 'route=lab/worker-ingress'"
echo "== waiting on ztunnel's own close line for the held ingress-to-worker connection (300 s bound) =="
WIP=$(kubectl -n lab get pod -l app=worker -o jsonpath='{.items[0].status.podIP}')
closed=""
for i in $(seq 1 300); do
  l=$(kubectl -n istio-system logs "$ZT" --since-time=$A | grep 'connection complete' | grep 'src.workload="agentgateway-ingress-' | grep "$WIP:8080" | head -1)
  [ -n "$l" ] && { closed=$i; echo "closed after ${i}s: $l"; break; }
  sleep 1
done
[ -n "$closed" ] || echo "the held connection's close line was NOT observed within 300 s; sending anyway"
bash $SO c3-l4 ingress c34-c3-ingress-2 || echo "send-one exit=$?"
B=$(date -u +%FT%TZ)
bash $REC $C/c3-proxies.txt "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$A | grep 'route=lab/worker-ingress'"
echo "== C-4: the same policy given to.operation.methods GET, applied at $B =="
bash $REC $C/c4-policy.txt "kubectl apply -k $C/overlay-c4"
for i in $(seq 1 60); do g=$(kubectl -n lab get authorizationpolicy require-agw-central -o jsonpath='{.status.conditions[0].observedGeneration}' 2>/dev/null); [ "$g" = 2 ] && { echo "observedGeneration=2 after ${i}s"; break; }; sleep 1; done
bash $REC $C/c4-policy.txt "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
bash $REC $C/c4-policy.txt "istioctl ztunnel-config policy --node $node -o json | jq '.[] | select(.name==\"require-agw-central\")'"
bash $SO c4-l7rule service c34-c4-service || echo "send-one exit=$?"
bash $SO c4-l7rule direct c34-c4-direct || echo "send-one exit=$?"
bash $SO c4-l7rule ingress c34-c4-ingress || echo "send-one exit=$?"
bash $REC $C/c4-istiod.txt "kubectl -n istio-system logs deploy/istiod --since-time=$B"
bash $REC $C/c4-ztunnel.txt "kubectl -n istio-system logs $ZT --since-time=$B"
bash $REC $C/c4-proxies.txt "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$B | grep 'route=lab/worker'"
bash $REC $C/c4-proxies.txt "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$B | grep 'route=lab/worker-ingress'"
echo "== removal =="
bash $REC $C/removal.txt "kubectl delete -k $C/overlay-c4"
for i in $(seq 1 60); do n=$(istioctl ztunnel-config policy --node $node -o json 2>/dev/null | jq '[.[] | select(.name=="require-agw-central")] | length'); [ "${n:-0}" = 0 ] && { echo "ztunnel dropped the policy after ${i}s"; break; }; sleep 1; done
bash $REC $C/removal.txt "kubectl get authorizationpolicy -A"
bash $REC $C/removal.txt "istioctl ztunnel-config policy --node $node -o json | jq -c '.[] | {name,namespace,action}'"
bash $REC $C/removal.txt "kubectl get peerauthentication -A"
bash $REC $C/removal.txt "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
echo "== after =="
bash $SO after-removal direct c34-after-direct
bash $SO after-removal ingress c34-after-ingress
RUN_ID=c34after RUN_ITEM=@D@/c3c4/after experiments/gate2-single-clean.sh
bash experiments/runs/@D@/drivers/c3c4-counts.sh > $C/counts.csv && cat $C/counts.csv
bash experiments/runs/@D@/drivers/c3c4-proxy-spans.sh | tee $C/proxy-spans.txt
EOF

# --- C-3R, the open connection under a selector-scoped and a namespace-scoped ALLOW ---------------------------------
step 53-c3r c3r 0 <<'EOF'
C=experiments/runs/@D@/c3r; REC=$C/rec.sh
for c in "kubectl get authorizationpolicy -A" "kubectl -n istio-system get pods -l app=ztunnel -o wide" "kubectl -n lab get pods -o wide"; do bash $REC $C/start-state.txt "$c"; done
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/namespace.yaml"
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/server.yaml -f $C/objects/client.yaml"
bash $REC $C/objects-created.txt "kubectl -n c3r wait --for=condition=Available deploy/c3r-server --timeout=120s && kubectl -n c3r wait --for=condition=Ready pod/c3r-client --timeout=120s"
bash $REC $C/objects-created.txt "kubectl -n c3r get pods -o wide"
W=$(date -u +%FT%TZ)
for r in none-1 selector-1 namespace-1 selector-2 namespace-2; do
  sleep 5
  bash experiments/runs/@D@/drivers/c3r-rep.sh "${r%-*}" "${r##*-}"
done
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/window.txt "kubectl -n c3r logs deploy/c3r-server"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | awk -F'\t' '\$2 == \"warn\"' | wc -l"
bash $REC $C/window.txt "kubectl -n istio-system logs deploy/istiod --since-time=$W | grep -E 'PUSH for node:$ZT' | grep -E 'WDS|WADS'"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/client.yaml -f $C/objects/server.yaml --wait=true"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/namespace.yaml --wait=true --timeout=180s"
bash $REC $C/objects-deleted.txt "kubectl get authorizationpolicy -A; istioctl ztunnel-config workloads --node agent-mesh-lab-worker -o json | jq '[.[] | select(.namespace == \"c3r\")] | length'"
RUN_ID=c3rafter RUN_ITEM=@D@/c3r/after experiments/gate2-single-clean.sh
python3 $C/counts.py
EOF

# --- C-3R2, the same with the public server -----------------------------------------------------------------------
step 54-c3r2 c3r2 0 <<'EOF'
C=experiments/runs/@D@/c3r2; REC=$C/rec.sh
for c in "kubectl get authorizationpolicy -A" "kubectl -n istio-system get pods -l app=ztunnel -o wide"; do bash $REC $C/start-state.txt "$c"; done
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/setup.yaml"
bash $REC $C/objects-created.txt "kubectl -n repro wait --for=condition=Available deploy/server --timeout=180s && kubectl -n repro wait --for=condition=Ready pod/client --timeout=180s"
bash $REC $C/objects-created.txt "kubectl -n repro get pods -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.serviceAccountName}{\" \"}{.status.containerStatuses[0].imageID}{\"\\n\"}{end}'"
bash $REC $C/server-and-client.txt "kubectl -n repro exec deploy/server -- sh -c 'nginx -v 2>&1; id; nginx -T 2>&1 | grep -n -E \"listen|keepalive\"'"
W=$(date -u +%FT%TZ)
for r in none-1 selector-1 namespace-1 selector-2 namespace-2; do
  sleep 5
  bash experiments/runs/@D@/drivers/c3r2-rep.sh "${r%-*}" "${r##*-}"
done
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/window.txt "kubectl -n repro logs deploy/server --timestamps --since-time=$W"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
bash $REC $C/window.txt "kubectl -n istio-system logs deploy/istiod --since-time=$W | grep -E 'PUSH for node:$ZT' | grep -E 'WDS|WADS'"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/setup.yaml --wait=true --timeout=180s"
bash $REC $C/objects-deleted.txt "kubectl get authorizationpolicy -A; kubectl get ns repro"
bash $REC $C/objects-deleted.txt "docker exec agent-mesh-lab-worker crictl rmi docker.io/nginxinc/nginx-unprivileged@sha256:0918d093d6088225655ddf602fdf00679c1c0c9a89c01c6dcdce5ee5e6c2f3f3"
RUN_ID=c3r2after RUN_ITEM=@D@/c3r2/after experiments/gate2-single-clean.sh
python3 $C/counts.py
EOF

# --- C-5, Istio's AuthorizationPolicy aimed at agw-central --------------------------------------------------------
step 55-c5 c5 0 <<'EOF'
mkdir -p experiments/runs/@D@/c5
cp -R experiments/runs/2026-09-23-c5-istio-policy-agw-central/overlay-c5 experiments/runs/2026-09-23-c5-istio-policy-agw-central/counts.sh experiments/runs/@D@/c5/
export RUNREL=@D@/c5 RUN_ID=wtc5
C5="bash experiments/runs/2026-09-23-c5-istio-policy-agw-central/c5.sh"
S=$(date -u +%FT%TZ)
$C5 read before "$S"
$C5 pod-up
for r in go py; do $C5 probe p0 $r SendMessage yes 1; $C5 probe p0 $r SubscribeToTask yes 1; done
A=$(date -u +%FT%TZ); $C5 apply
$C5 read applied "$A"
for r in go py; do for n in 1 2; do
  $C5 probe p1 $r SendMessage yes $n; $C5 probe p1 $r SubscribeToTask yes $n; $C5 probe p1 $r SendMessage no $n
done; done
$C5 read p1-after "$A"
B=$(date -u +%FT%TZ); $C5 remove
$C5 read removed "$B"
$C5 pod-down
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$S" > experiments/runs/@D@/c5/agw-central-access.txt
(cd experiments/runs/@D@/c5 && bash counts.sh) | tee experiments/runs/@D@/c5/counts.txt
EOF

# --- C-6, the route layer's header match -----------------------------------------------------------------------------
step 56-c6 c6 0 <<'EOF'
mkdir -p experiments/runs/@D@/c6
cp -R experiments/runs/2026-09-23-c6-httproute/overlay-c6 experiments/runs/2026-09-23-c6-httproute/counts.py experiments/runs/@D@/c6/
export RUNREL=@D@/c6 RUN_ID=wtc6
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C6="bash experiments/runs/2026-09-23-c6-httproute/c6.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
S=$(date -u +%FT%TZ)
$C6 read before "$S"
$SENDS pod-up
for n in 1 2; do for r in go py; do $SENDS c6pa sm $r $n; $SENDS c6pa st $r $n; done; done
A=$(date -u +%FT%TZ); $C6 apply
$C6 read applied "$A"
for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS c6pb $k $r $n; done; done; done
B=$(date -u +%FT%TZ); $C6 remove
$C6 read removed "$B"
$SENDS pod-down
RUN_ID=c6after RUN_ITEM=@D@/c6/after experiments/gate2-single-clean.sh
python3 experiments/runs/@D@/c6/counts.py | tee experiments/runs/@D@/c6/counts.txt
EOF

# --- C-7, agentgateway's authorization on a header and on identity ---------------------------------------------------
step 57-c7 c7 0 <<'EOF'
mkdir -p experiments/runs/@D@/c7
cp -R experiments/runs/2026-09-23-c7-agw-authorization/overlay-c7-header experiments/runs/2026-09-23-c7-agw-authorization/overlay-c7-identity experiments/runs/2026-09-23-c7-agw-authorization/counts.py experiments/runs/@D@/c7/
export RUNREL=@D@/c7 RUN_ID=wtc7
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C7="bash experiments/runs/2026-09-23-c7-agw-authorization/c7.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
S=$(date -u +%FT%TZ)
$C7 read before "$S"
A=$(date -u +%FT%TZ); $C7 apply overlay-c7-header
$C7 read header-applied "$A"
$SENDS pod-up
for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS c7h $k $r $n; done; done; done
$SENDS pod-down
B=$(date -u +%FT%TZ); $C7 remove overlay-c7-header
$C7 read header-removed "$B"
I=$(date -u +%FT%TZ); $C7 apply overlay-c7-identity
$C7 read identity-applied "$I"
RUN_ID=c7id RUN_ITEM=@D@/c7/identity-in-force-clean experiments/gate2-single-clean.sh
$C7 pod-up
for n in 1 2; do for p in ingress-go ingress-py agw-go agw-py pf-go; do $C7 probe $p $n; done; done
$C7 pod-down
J=$(date -u +%FT%TZ); $C7 remove overlay-c7-identity
$C7 read identity-removed "$J"
RUN_ID=c7after RUN_ITEM=@D@/c7/after experiments/gate2-single-clean.sh
python3 experiments/runs/@D@/c7/counts.py | tee experiments/runs/@D@/c7/counts.txt
EOF

# --- C-8, agentgateway's authorization on the request body -----------------------------------------------------------
step 58-c8 c8 0 <<'EOF'
mkdir -p experiments/runs/@D@/c8
cp -R experiments/runs/2026-09-23-c8-body-rule/overlay-c8-deny experiments/runs/2026-09-23-c8-body-rule/overlay-c8-require experiments/runs/2026-09-23-c8-body-rule/overlay-c8-require-scoped experiments/runs/2026-09-23-c8-body-rule/counts.py experiments/runs/@D@/c8/
export RUNREL=@D@/c8 RUN_ID=wtc8
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C8="bash experiments/runs/2026-09-23-c8-body-rule/c8.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
rows() { for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS "$1" $k $r $n; done; done; done; }
S=$(date -u +%FT%TZ)
$C8 read before "$S"
$SENDS pod-up
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-deny; sleep 10; $C8 read deny-applied "$T"
rows c8d
for r in go py; do $C8 probe c8d pad $r 1; done
for r in go py; do $C8 probe c8d batch $r 1; $C8 probe c8d dup $r 1; done
U=$(date -u +%FT%TZ); $C8 read deny-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny-removed "$U"
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-require; sleep 10; $C8 read require-applied "$T"
rows c8r
for r in go py; do $C8 probe c8r pad $r 1; done
U=$(date -u +%FT%TZ); $C8 read require-end "$T"; $C8 remove overlay-c8-require; sleep 10; $C8 read require-removed "$U"
$SENDS pod-down
RUN_ID=c8after RUN_ITEM=@D@/c8/after experiments/gate2-single-clean.sh
$C8 read after "$U"
$SENDS pod-up
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-deny; sleep 10; $C8 read deny2-applied "$T"
$C8 probe c8p padt py 1
U=$(date -u +%FT%TZ); $C8 read deny2-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny2-removed "$U"
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-require-scoped; sleep 10; $C8 read scoped-applied "$T"
rows c8s
for r in go py; do $C8 probe c8s pad $r 1; done
U=$(date -u +%FT%TZ); $C8 read scoped-end "$T"; $C8 remove overlay-c8-require-scoped; sleep 10; $C8 read scoped-removed "$U"
$SENDS pod-down
RUN_ID=c8after2 RUN_ITEM=@D@/c8/after-2 experiments/gate2-single-clean.sh
$C8 read after-2 "$U"
python3 experiments/runs/@D@/c8/counts.py | tee experiments/runs/@D@/c8/counts.txt
EOF

# --- C-10, the application refuses the operation -----------------------------------------------------------------------
step 59-c10 c10 0 <<'EOF'
mkdir -p experiments/runs/@D@/c10
cp experiments/runs/2026-09-24-c10-application/counts.py experiments/runs/@D@/c10/
RUNREL=@D@/c10 N=2 bash experiments/runs/2026-09-24-c10-application/c10.sh
RUN_ID=c10after RUN_ITEM=@D@/c10/after experiments/gate2-single-clean.sh
python3 experiments/runs/@D@/c10/counts.py; cat experiments/runs/@D@/c10/counts.txt
EOF

# --- D-1, the header reading ------------------------------------------------------------------------------------------
step 60-d1-headers d1-headers 0 <<'EOF'
RUN_ID=wtd1h RUNREL=@D@/d1-headers bash experiments/runs/2026-09-24-d1-current-topology/headers.sh
H=experiments/runs/@D@/d1-headers/headers
for app in worker orchestrator; do
  echo "== $app"
  jq -r 'select(.phase=="arrival" and .headers != null) | "\(if (.method // "") == "" then "GET /.well-known/agent-card.json" else .method end) | lwi=\(.logical_work_item_id) | remote=\(.remote | sub(":[0-9]+$"; "")) | names=\(.headers.names | join(",")) | values=\([.headers.values | to_entries[] | "\(.key)=\(.value)"] | join(" ; ")) | authorization_present=\(.headers.authorization_present)"' $H/$app-ingress.jsonl
done | tee $H/readings.txt
echo "== names over every arrival carrying the reading"; cat $H/worker-ingress.jsonl $H/orchestrator-ingress.jsonl | jq -r 'select(.phase=="arrival" and .headers != null) | .headers.names[]' | sort | uniq -c | sort -rn
EOF

# --- D-2, the REST and gRPC bindings -----------------------------------------------------------------------------------
step 61-d2 d2 0 <<'EOF'
mkdir -p experiments/runs/@D@/d2
for o in overlay-l1-route overlay-l2-path overlay-l3-deny overlay-l3-require; do cp -R experiments/runs/2026-09-24-d2-bindings/$o experiments/runs/@D@/d2/; done
cp experiments/runs/2026-09-24-d2-bindings/counts.py experiments/runs/@D@/d2/
export RUNREL=@D@/d2 RUN_ID=wtd2
SENDS="bash experiments/runs/2026-09-24-d2-bindings/sends.sh"; W=experiments/runs/@D@/d2
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
readings() { # <window> <label>: the routes, the policies, the agents' setting and pods, the controller's log, the ingress's config dump
  mkdir -p $W/$1
  { echo "# $(date -u +%FT%TZ) readings $1 $2"; kubectl -n lab get httproute,grpcroute,agentgatewaypolicy -o yaml
    for d in worker orchestrator; do echo "$d: $(kubectl -n lab get deploy $d -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="REFUSE_OPERATION")]}{.name}={.value}{end}')"; done
    kubectl -n lab get pods -l 'app in (worker,orchestrator)' -o wide --no-headers
    kubectl -n agentgateway-system logs deploy/agentgateway --since=2m 2>/dev/null | tail -40; } > $W/$1/readings-$2.txt 2>&1
  bash experiments/runs/2026-09-19-waypoint-policy-recheck/config-dump.sh agentgateway-ingress agentgateway-ingress $W/$1/config-dump-ingress-$2.json > /dev/null
}
sendset() { # <window> <rounds>
  for b in rest grpc; do for r in go py; do
    for n in $(seq 1 "$2"); do $SENDS "$1" $b sm $r $n; $SENDS "$1" $b st $r $n; done
    if [ "$b" = rest ]; then for n in $(seq 1 "$2"); do $SENDS "$1" rest cst $r $n; done; fi
  done; done
}
$SENDS pod-up
echo "== the clean send per binding =="
for b in rest grpc; do for r in go py; do $SENDS clean $b sm $r 1; done; done
echo "== p0, nothing applied =="
readings p0 before; sendset p0 1; readings p0 removed
for win in l1-route l2-path l3-deny l3-require; do
  echo "== $win =="
  readings $win before
  kubectl apply -k $W/overlay-$win | tee $W/$win/apply.txt; sleep 8
  readings $win applied
  sendset $win 2
  readings $win end
  kubectl delete -k $W/overlay-$win | tee $W/$win/remove.txt; sleep 8
  readings $win removed
done
echo "== l4-app =="
readings l4-app before
for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION=SubscribeToTask; done | tee $W/l4-app/apply.txt
for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s; done | tee -a $W/l4-app/apply.txt
readings l4-app applied
sendset l4-app 2
readings l4-app end
for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION=; done | tee $W/l4-app/remove.txt
for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s; done | tee -a $W/l4-app/remove.txt
readings l4-app removed
$SENDS pod-down
RUN_ID=d2after RUN_ITEM=@D@/d2/after experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
EOF

# --- D-3, the external authorizer --------------------------------------------------------------------------------------
step 62-d3 d3 0 <<'EOF'
mkdir -p experiments/runs/@D@/d3
cp -R experiments/runs/2026-09-24-d3-extauthz/overlay-d3-extauthz experiments/runs/2026-09-24-d3-extauthz/counts.py experiments/runs/@D@/d3/
export RUNREL=@D@/d3 RUN_ID=d3a
X="bash experiments/runs/2026-09-24-d3-extauthz/d3.sh"; W=experiments/runs/@D@/d3
export IMAGE=$($X image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
row34() { for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc $k $r 1; done; done; }
$X pod-up
echo "== p0 =="
$X read p0-before
for r in go py; do $X send p0 jsonrpc csm $r 1; done
echo "== deny =="
$X read deny-before; $X apply; sleep 8; $X read deny-applied
for r in go py; do for n in 1 2; do for k in sm st ss cst; do $X send deny jsonrpc $k $r $n; done; done; done
$X hop deny-row1
for b in rest grpc; do for r in go py; do for n in 1 2; do $X send deny $b sm $r $n; $X send deny $b st $r $n; done; done; done
row34 deny
$X read deny-end
echo "== allow =="
$X setting allow; $X read allow-applied
row34 allow
$X read allow-end
echo "== unavail =="
$X setting deny; $X read deny-restored
$X scale 0; $X read unavail-scaled-0
for r in go py; do for n in 1 2; do $X send unavail jsonrpc sm $r $n; $X send unavail jsonrpc st $r $n; done; done
$X read unavail-end
$X scale 1; $X read unavail-restored
echo "== off =="
$X remove; sleep 8; $X read removed
$X pod-down
RUN_ID=d3after RUN_ITEM=@D@/d3/after experiments/gate2-single-clean.sh
echo "== shapes =="
$X pod-up
$X read shapes-before; $X apply; sleep 8; $X read shapes-applied
for n in 1 2; do for k in xp xa xg xr; do $X send shapes jsonrpc $k go $n; done; done
for n in 1 2; do for k in xg xr; do $X send shapes jsonrpc $k py $n; done; done
$X read shapes-end
$X remove; sleep 8; $X read shapes-removed
$X pod-down
RUN_ID=d3after2 RUN_ITEM=@D@/d3/after-2 experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
EOF

# --- D-3b, the fixture over every shape the receivers dispatch ---------------------------------------------------------
step 63-d3b d3b 0 <<'EOF'
mkdir -p experiments/runs/@D@/d3b
cp -R experiments/runs/2026-09-25-d3b-extauthz-shapes/overlay-d3-extauthz experiments/runs/2026-09-25-d3b-extauthz-shapes/counts.py experiments/runs/@D@/d3b/
export RUNREL=@D@/d3b RUN_ID=d3b
X="bash experiments/runs/2026-09-25-d3b-extauthz-shapes/d3b.sh"; W=experiments/runs/@D@/d3b
export IMAGE=$($X image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
row34() { for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc $k $r 1; done; done; }
GO_SHAPES="xp xa xg xr xn xt xm xc xh xl gp gs gq xu xq xi rg xk"
PY_SHAPES="xg xr xn xc xh xl xs xe xb x16 xq rg xk"
$X pod-up
echo "== deny =="
$X read deny-before; $X apply; sleep 8; $X read deny-applied
for r in go py; do for n in 1 2; do for k in sm st ss cst; do $X send deny jsonrpc $k $r $n; done; done; done
$X hop deny-row1
for b in rest grpc; do for r in go py; do for n in 1 2; do $X send deny $b sm $r $n; $X send deny $b st $r $n; done; done; done
row34 deny
$X read deny-end
echo "== shapes =="
$X read shapes-before
for n in 1 2; do for k in $GO_SHAPES; do $X send shapes jsonrpc $k go $n; done; done
for n in 1 2; do for k in $PY_SHAPES; do $X send shapes jsonrpc $k py $n; done; done
$X read shapes-end
echo "== allow =="
$X setting allow; $X read allow-applied
row34 allow
$X read allow-end
echo "== restore =="
$X setting deny; $X read deny-restored
$X remove; sleep 8; $X read removed
$X pod-down
RUN_ID=d3bafter RUN_ITEM=@D@/d3b/after experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
EOF

# --- D-4, three ServiceAccounts: the identity rows -----------------------------------------------------------------------
step 64-d4 d4 0 <<'EOF'
mkdir -p experiments/runs/@D@/d4
for o in overlay-d4-z overlay-d4-a overlay-d4-r2; do cp -R experiments/runs/2026-09-25-d4-serviceaccounts/$o experiments/runs/@D@/d4/; done
export RUNREL=@D@/d4
ROWS="bash experiments/runs/2026-09-25-d4-serviceaccounts/rows.sh"; W=experiments/runs/@D@/d4
RUN_ID=d4cc RUN_ITEM=@D@/d4/clean-check experiments/gate2-single-clean.sh
RUN_ID=z1 $ROWS z
RUN_ID=a1 $ROWS a
RUN_ID=r1 $ROWS r2
RUN_ID=x1 $ROWS xa
RUN_ID=d4h1 bash experiments/runs/2026-09-24-d1-current-topology/headers.sh
S=$(date -u +%FT%TZ)
RUN_ID=d4after RUN_ITEM=@D@/d4/after experiments/gate2-single-clean.sh
mkdir -p $W/after/hop-lines
for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do kubectl -n istio-system logs "$zt" --since-time="$S" | grep 'connection complete' | sed "s/^/$zt /"; done > $W/after/hop-lines/ztunnel-connections.txt
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$S" | grep 'request gateway=' > $W/after/hop-lines/agw-central-access.txt
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$S" | grep 'request gateway=' > $W/after/hop-lines/ingress-access.txt
python3 experiments/runs/2026-09-25-d4-serviceaccounts/counts.py $W | tee $W/counts.txt
EOF

# --- D-5, the connection count with the marking applied and removed from the run directory ----------------------------------
step 65-d5-conn d5-conn 0 <<'EOF'
mkdir -p experiments/runs/@D@/d5
cp experiments/runs/2026-09-25-d5-a2a-backend/marking-add.json experiments/runs/2026-09-25-d5-a2a-backend/marking-remove.json experiments/runs/@D@/d5/
export RUNREL=@D@/d5 RUN_ID=s21
D5="bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh"
S=$(date -u +%FT%TZ)
$D5 conn unmarked
$D5 mark
$D5 conn marked
$D5 unmark
$D5 conn removed
mkdir -p experiments/runs/@D@/d5/conn-join
{ echo "# read $(date -u +%FT%TZ): every ztunnel's lines since $S, the start of the connection count"
  for z in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do kubectl -n istio-system logs "$z" --since-time="$S" | sed "s/^/$z /"; done; } > experiments/runs/@D@/d5/conn-join/ztunnel-window.txt
EOF
echo "$(ts) Experiment C's standing rows are done"

# =============================================================================================================
# The two trials whose configuration is not standing
# =============================================================================================================
# --- C-9, the A2A marking switched on, then off ------------------------------------------------------------------------------
step 70-c9-base c9-base 0 <<'EOF'
RUNREL=@D@/c9 RUN_ID=b1 OUTROOT=experiments/runs/@D@/c9 bash experiments/runs/2026-09-24-c9-a2a-marking/c9.sh base 1
EOF
step 70b-c9-mark - 0 <<'EOF'
mkdir -p experiments/runs/@D@/c9-marking
cp experiments/runs/2026-09-25-d5-a2a-backend/marking-add.json experiments/runs/2026-09-25-d5-a2a-backend/marking-remove.json experiments/runs/@D@/c9-marking/
RUNREL=@D@/c9-marking RUN_ID=c9m bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh mark
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol={.spec.ports[0].appProtocol}{"\n"}{end}'
kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s
EOF
step 70c-c9-after c9-after 0 <<'EOF'
RUNREL=@D@/c9 RUN_ID=a1 OUTROOT=experiments/runs/@D@/c9 bash experiments/runs/2026-09-24-c9-a2a-marking/c9.sh after 2
EOF
step 70d-c9-cards-and-forward c9-cards-and-forward 0 <<'EOF'
bash experiments/runs/2026-09-24-c9-a2a-marking/cards.sh experiments/runs/@D@/c9/cards-after
bash experiments/runs/2026-09-24-c9-a2a-marking/fwd.sh experiments/runs/@D@/c9/forward f1
EOF
step 70e-c9-clean-check-under-the-marking c9-clean-check-marked "0 1" <<'EOF'
RUN_ID=c9clean RUN_ITEM=@D@/c9/clean-marked experiments/gate2-single-clean.sh
EOF
step 70f-c9-unmark-and-revert-cards - 0 <<'EOF'
RUNREL=@D@/c9-marking RUN_ID=c9m bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh unmark
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol=[{.spec.ports[0].appProtocol}]{"\n"}{end}'
bash experiments/runs/2026-09-24-c9-revert/cards.sh experiments/runs/@D@/c9/cards-reverted
EOF
step 70g-c9-clean-check-after c9-clean-check-after 0 <<'EOF'
RUN_ID=c9after RUN_ITEM=@D@/c9/after experiments/gate2-single-clean.sh
python3 experiments/runs/2026-09-24-c9-a2a-marking/counts.py experiments/runs/@D@/c9/base experiments/runs/@D@/c9/after | tee experiments/runs/@D@/c9/counts.txt
cat experiments/runs/@D@/c9/cards-after/cards.txt experiments/runs/@D@/c9/cards-reverted/cards.txt
EOF

# --- D-5, the A2A backend type as a trial ---------------------------------------------------------------------------------------
step 71-d5-trial d5-trial 0 <<'EOF'
cp -R experiments/runs/2026-09-25-d5-a2a-backend/trial-overlay experiments/runs/@D@/d5/
RUNREL=@D@/d5 RUN_ID=t22 REPS=2 bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh trial
EOF
step 71b-d5-trial-traces - 0 <<'EOF'
W=experiments/runs/@D@/d5/trial; mkdir -p $W/traces/by-id
grep -h -o 'trace.id=[0-9a-f]*' $W/agw-central-access-in-force-with-cards.txt $W/ingress-access-in-force-with-cards.txt | cut -d= -f2 | sort -u > $W/traces/trace-ids.txt
kubectl -n telemetry port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 30); do curl -sS -o /dev/null --max-time 2 http://127.0.0.1:16686/api/v3/services >/dev/null 2>&1 && break; sleep 1; done
while read -r t; do curl -sS --retry 0 --max-time 20 "http://127.0.0.1:16686/api/traces/$t" -o "$W/traces/by-id/$t.json"; done < $W/traces/trace-ids.txt
kill "$PF" >/dev/null 2>&1 || true; wait "$PF" >/dev/null 2>&1 || true
echo "# $(date -u +%FT%TZ) traces read from Jaeger by the trace.id on every proxy request line of the trial window (port-forward to svc/jaeger, /api/traces/<id>)" > $W/traces/README.txt
echo "trace ids: $(wc -l < $W/traces/trace-ids.txt | tr -d ' '); files: $(ls $W/traces/by-id | wc -l | tr -d ' ')"
EOF
step 71c-d5-clean-check-after d5-clean-check-after 0 <<'EOF'
RUNREL=@D@/d5 RUN_ID=d5after bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh clean
(cd experiments/runs/@D@/d5 && python3 ../../2026-09-25-d5-a2a-backend/counts.py) | tee experiments/runs/@D@/d5/counts.txt
EOF

# --- The closing state -------------------------------------------------------------------------------------------------------
step 80-closing-state - 0 <<'EOF'
echo "## retry stanzas across every HTTPRoute"; kubectl get httproute -A -o yaml | grep -c "retry:"
echo "## AuthorizationPolicies, AgentgatewayPolicies, AgentgatewayBackends, the agent Services' appProtocol, the agents' settings"
kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/AuthorizationPolicy: /'
kubectl get agentgatewaypolicy -A --no-headers | wc -l | tr -d ' ' | sed 's/^/AgentgatewayPolicy: /'
kubectl get agentgatewaybackend -A --no-headers | wc -l | tr -d ' ' | sed 's/^/AgentgatewayBackend: /'
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol=[{.spec.ports[0].appProtocol}]{"\n"}{end}'
kubectl -n lab get deploy -o json | jq -r '.items[] | .metadata.name as $n | ((.spec.template.spec.containers[0].env // [])[] | select(.name | test("^(CLIENT_|MODEL_RETRIES|MODEL_MAX_RETRIES|REFUSE_OPERATION|LEDGER_HEADERS|FORWARD_RESUBSCRIBE|DOWNSTREAM_A2A_URL|EXTAUTHZ_UNDECIDABLE)")) | "\($n): \(.name)=[\(.value)]")'
kubectl -n lab get deploy extauthz -o jsonpath='extauthz replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
echo "## namespaces and probe pods left"; kubectl get ns c3r repro 2>&1 | tail -2; kubectl -n lab get pods --no-headers | grep -v -E '^(worker|orchestrator|mockllm|extauthz|loadgen|replay)-' | wc -l | tr -d ' ' | sed 's/^/other pods in lab: /'
echo "## Jobs and finished pods left in lab"; kubectl -n lab get jobs --no-headers | wc -l | tr -d " " | sed "s/^/jobs: /"; kubectl -n lab get pods --no-headers | awk '{print $3}' | sort | uniq -c
echo "## the Deployments standing in lab"; kubectl -n lab get deploy
EOF
step 81-closing-reset - 0 <<'EOF'
kubectl -n lab run wt-cleanup --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 60
kubectl -n lab wait --for=condition=Ready pod/wt-cleanup --timeout=60s
for u in mockllm worker orchestrator; do
  kubectl -n lab exec wt-cleanup -- curl -s -o /dev/null -w "$u/control/reset -> %{http_code}\n" \
    -X POST "http://$u.lab.svc.cluster.local:8080/control/reset"
done
kubectl -n lab delete pod wt-cleanup
kubectl -n lab logs deploy/mockllm --tail=-1 | jq -R -c 'fromjson? | select(.ledger == "control")' | tail -1
EOF
run 82-my-walkthrough-size - 0 'du -sh experiments/runs/@D@ | cut -f1'

echo "run,$T0UTC,$(ts)" > "$WIN"
echo "$(ts) walk driver exit=0"
