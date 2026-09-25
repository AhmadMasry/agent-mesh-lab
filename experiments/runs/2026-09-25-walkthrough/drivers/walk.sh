#!/usr/bin/env bash
# Follow-ups 23: the walkthrough's run. From a deleted cluster, every command the refreshed docs/walkthrough.md shows,
# in its order, each once, each logged whole to logs/NN-<label>.txt as "$ <command>", its stdout and stderr, and a
# last line "wall <s>s exit <n>". The make targets and experiment scripts also get a timings.csv row.
# The commands are the reader's, with one difference the walkthrough states: RUN_ITEM and the paths read from it name
# this record's directory, experiments/runs/$D, where the reader's name experiments/runs/my-walkthrough.
# The tools: the walkthrough's own "Before you start" block (setup-tools.sh beside this file, sourced once, logged as
# 00a), which fetches istioctl 1.31.1 and its published checksum, verifies it, puts it first on PATH for this shell,
# and sets an empty Helm scope. Nothing on the host changes.
# Stop rule: the first non-zero exit of a make target, an experiment script or a read stops the driver. No retry:
# each command runs once. Keep-awake: this driver starts none and changes no power setting; keep-awake is not claimed
# absent on the host.
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
# run <file> <timed label or -> <command string>
run() {
	local f="$1" label="$2" cmd="$3" s e rc st
	st=$(ts); s=$(now)
	printf '$ %s\n' "$cmd" > "$L/$f.txt"
	bash -c "$cmd" >> "$L/$f.txt" 2>&1
	rc=$?
	e=$(now)
	local w; w=$(perl -e "printf '%.3f', $e - $s")
	echo "wall ${w}s exit $rc" >> "$L/$f.txt"
	[ "$label" = "-" ] || echo "$label,$st,$(ts),$w,$rc" >> "$TIM"
	echo "$(ts) $f exit=$rc wall=${w}s"
	if [ "$rc" != "0" ]; then echo "walk driver: $f exited $rc; stopping"; echo "run,$T0UTC,$(ts)" > "$WIN"; exit "$rc"; fi
}

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
run 00-teardown teardown 'make teardown'
run 01-cluster-kind cluster-kind 'make cluster-kind'
run 01b-nodes-ready - 'kubectl wait --for=condition=Ready nodes --all --timeout=180s'
run 01c-get-nodes - 'kubectl get nodes'

# --- Step 1 ----------------------------------------------------------------------------------------------------
run 02-step-1 step-1 'make step-1'
run 02b-after-step-1 - 'kubectl -n lab get deploy,svc,pods -o wide; echo; kubectl -n lab get serviceaccounts'
run 03-mockllm-deterministic mockllm-deterministic 'experiments/gate1-mockllm-deterministic.sh'
mkdir -p "$R/step-1/mockllm-deterministic"
cp experiments/runs/2026-09-05-mockllm-deterministic/summary.csv experiments/runs/2026-09-05-mockllm-deterministic/invocation.jsonl "$R/step-1/mockllm-deterministic/"
run 03b-restore-deterministic - 'git checkout -- experiments/runs/2026-09-05-mockllm-deterministic/; git status --short -- experiments/runs/2026-09-05-mockllm-deterministic/'
run 04-step-1-clean step-1-clean "RUN_ID=wt1 RUN_ITEM=$D/step-1/clean experiments/gate2-single-clean.sh"
run 05-ledgers-worker - 'make ledgers LWI=g2c-wt1-worker'

# --- Step 2 ----------------------------------------------------------------------------------------------------
run 06-step-2 step-2 'make step-2'
run 06b-helm-list - 'helm list -A'
run 06c-ztunnel-workloads - 'istioctl ztunnel-config workloads'
run 06d-svc-labels - "kubectl -n lab get svc worker -o jsonpath='{.metadata.labels}'; echo"
run 06e-certificates - 'istioctl ztunnel-config certificates --node agent-mesh-lab-worker'
run 07-step-2-clean step-2-clean "RUN_ID=wt2 RUN_ITEM=$D/step-2/clean experiments/gate2-single-clean.sh"
run 07b-access-logs - "echo '## agw-central request line'; kubectl -n agentgateway-waypoint logs deploy/agw-central | grep 'http.path=/ ' | head -1; echo; echo '## ztunnel access line'; kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep 'loadgen-g2c-wt2-worker' | grep access"
run 07c-plaintext-probe - '
kubectl -n default run mtls-probe --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 300
kubectl -n default wait --for=condition=Ready pod/mtls-probe --timeout=90s
for h in worker orchestrator; do
  echo "## $h"
  kubectl -n default exec mtls-probe -- curl -sS -o /dev/null -w "http=%{http_code} exit=%{exitcode}\n" --retry 0 \
    --connect-timeout 5 --max-time 10 "http://$h.lab.svc.cluster.local:8080/.well-known/agent-card.json"; echo "exit=$?"
done
echo "## ztunnel policy rejections"
kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep "policy rejection" | tail -2
kubectl -n default delete pod mtls-probe'

# --- Step 2b ---------------------------------------------------------------------------------------------------
run 08-step-2b step-2b 'make step-2b'
run 08b-gateways-ns - 'kubectl get gateway -A; echo; kubectl get ns -L istio.io/dataplane-mode'
run 08c-model-url - "kubectl -n lab get deploy orchestrator worker -o json | jq -r '.items[] | .metadata.name + \": \" +
  ([.spec.template.spec.containers[0].env[]? | select(.name==\"MODEL_BASE_URL\" or .name==\"PUBLIC_URL\") |
  \"\\(.name)=\\(.value)\"] | join(\" \"))'"
run 08d-extauthz - 'kubectl -n lab get deploy,svc extauthz -o wide'
run 09-step-2b-clean step-2b-clean "RUN_ID=wt2b RUN_ITEM=$D/step-2b/clean experiments/gate2-single-clean.sh"
run 09b-model-leg - "echo '## agw-central model-route lines'; kubectl -n agentgateway-waypoint logs deploy/agw-central | grep chat/completions | tail -2; echo; echo '## mockllm invocation ledger, both clean work items'; kubectl -n lab logs deploy/mockllm | grep -E 'g2c-wt2b-(worker|orchestrator)'"
run 09c-ingress-card-and-send - '
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
echo "## port-forward closed"'
run 09d-ingress-ledgers - "make ledgers LWI=wt2b-ingress OUT=experiments/runs/$D/step-2b/ingress"

# --- Step 2c ---------------------------------------------------------------------------------------------------
run 10-step-2c step-2c 'make step-2c'
run 10b-step-2c-reads - "kubectl get httproute -A; echo; kubectl get grpcroute -A; echo; kubectl -n lab get svc -o json | jq -r '.items[] |
  \"\\(.metadata.name)  istio.io/use-waypoint=\\(.metadata.labels[\"istio.io/use-waypoint\"] // \"-\")\"'"

# --- Step 3 ----------------------------------------------------------------------------------------------------
run 11-step-3 step-3 'make step-3'
run 12-step-3-clean step-3-clean "RUN_ID=wt3 RUN_ITEM=$D/step-3/clean experiments/gate2-single-clean.sh"
run 13-step-3-trace step-3-trace "REPS=2 RUN_ID=wt3 RUN_ITEM=$D/step-3/trace experiments/gate3-trace-per-work-item.sh"
run 13b-dangling - "python3 experiments/runs/2026-09-16-genai-spans/trace/dangling.py \\
  experiments/runs/$D/step-3/trace"
run 13c-worker-spans - "python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    \"experiments/runs/$D/step-3/trace/a3t-wt3-r1-worker/spans.csv\")))
for r in sorted(rows, key=lambda r: (r[\"trace_id\"], int(r[\"start_us\"]))):
    print(\"%-24s %-44s %s\" % (r[\"service\"], r[\"operation\"], r[\"http_status\"]))
PY"
run 13d-spans-header - "head -1 experiments/runs/$D/step-3/trace/a3t-wt3-r1-worker/spans.csv"
run 13c2-agw-central-routes - "python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    \"experiments/runs/$D/step-3/trace/a3t-wt3-r1-worker/spans.csv\")))
for r in sorted(rows, key=lambda r: (r[\"trace_id\"], int(r[\"start_us\"]))):
    if r[\"service\"] == \"agw-central\" and r[\"route\"]:
        print(\"%-10s %-38s %s\" % (r[\"operation\"], r[\"route\"], r[\"retry_attempt\"] or \"-\"))
PY"
run 13e-genai-spans - "mkdir -p experiments/runs/$D/step-3/trace/genai
python3 experiments/runs/2026-09-16-genai-spans/genai-spans.py \\
  experiments/runs/$D/step-3/trace \\
  experiments/runs/$D/step-3/trace/genai"
run 14-restart-orchestrator - 'kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s'
run 14b-step-3-trace-first-forward step-3-trace-first-forward "REPS=1 RECEIVERS=orchestrator RUN_ID=wt3f RUN_ITEM=$D/step-3/trace-first-forward \\
  experiments/gate3-trace-per-work-item.sh"
run 15-prometheus-targets - 'experiments/runs/2026-09-12-mtls-enforced/promq.sh targets'
run 15b-jaeger-services - '
kubectl -n telemetry port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 30); do curl -sS -o /dev/null --max-time 2 http://127.0.0.1:16686/api/v3/services >/dev/null 2>&1 && break; python3 -c "import time;time.sleep(1)"; done
curl -s http://127.0.0.1:16686/api/v3/services | jq -r ".services[]" | sort
kill "$PF" >/dev/null 2>&1 || true
wait "$PF" >/dev/null 2>&1 || true
exit 0'

# --- Experiment A, six rows ------------------------------------------------------------------------------------
run 16-a1-m1-go a1-m1-go "MODE=M1 RECEIVER=go REPS=2 RUN_ID=wta1 RUN_ITEM=$D/a1-m1-go experiments/gate2-a1.sh"
run 17-a2-go-http-503 a2-go-http-503 "CLIENT=go LAYER=http RETRY_ON=transport+503 REPS=2 RUN_ID=wta2 \\
  RUN_ITEM=$D/a2-go-http-503 experiments/gate2-a2.sh"
run 18-a3-baseline-go a3-baseline-go "RUN=baseline RECEIVER=go REPS=2 RUN_ID=wta3b RUN_ITEM=$D/a3-baseline-go \\
  experiments/gate3-matrix.sh"
run 19-a3-r1-go-http a3-r1-go-http "RUN=R1 RECEIVER=go SUB=http REPS=2 RUN_ID=wta3r1 RUN_ITEM=$D/a3-r1-go-http \\
  experiments/gate3-matrix.sh"
run 19b-worker-span - "python3 experiments/runs/2026-09-19-currency-rebuild/worker-span/worker-span-reading.py \\
  experiments/runs/$D/a3-r1-go-http/a3m-r1-go-http-wta3r1-01"
run 20-a3-egress-go a3-egress-go "RUN=egress RECEIVER=go REPS=1 RUN_ID=wta3e RUN_ITEM=$D/a3-egress-go \\
  experiments/gate3-matrix.sh"
run 21-a3-r2-py-service a3-r2-py-service "RUN=R2 RECEIVER=py SUB=service REPS=2 RUN_ID=wta3s RUN_ITEM=$D/a3-r2-py-service \\
  experiments/gate3-matrix.sh"

# --- Cleanup ---------------------------------------------------------------------------------------------------
run 22-cleanup-state - '
echo "## retry stanzas across every HTTPRoute"
kubectl get httproute -A -o yaml | grep -c "retry:"
echo
echo "## client and model retry knobs on the lab Deployments"
kubectl -n lab get deploy -o json | jq -r ".items[] | .metadata.name as \$n | ((.spec.template.spec.containers[0].env // [])[] | select(.name | startswith(\"CLIENT_\") or . == \"MODEL_RETRIES\" or . == \"MODEL_MAX_RETRIES\") | \"\(\$n): \(.name)=\(.value)\")"
echo
echo "## the orchestrator downstream URL"
kubectl -n lab get deploy orchestrator -o json | jq -r ".spec.template.spec.containers[0].env[] | select(.name==\"DOWNSTREAM_A2A_URL\") | \"\(.name)=\(.value)\""
echo
echo "## Jobs and finished pods left in lab"
kubectl -n lab get jobs --no-headers | wc -l | tr -d " " | sed "s/^/jobs: /"
kubectl -n lab get pods --no-headers | awk "{print \$3}" | sort | uniq -c
echo
echo "## the Deployments standing in lab"
kubectl -n lab get deploy'
run 23-cleanup-reset - '
kubectl -n lab run wt-cleanup --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 60
kubectl -n lab wait --for=condition=Ready pod/wt-cleanup --timeout=60s
for u in mockllm worker orchestrator; do
  kubectl -n lab exec wt-cleanup -- curl -s -o /dev/null -w "$u/control/reset -> %{http_code}\n" \
    -X POST "http://$u.lab.svc.cluster.local:8080/control/reset"
done
kubectl -n lab delete pod wt-cleanup'
run 24-my-walkthrough-size - "du -sh experiments/runs/$D | cut -f1"

echo "run,$T0UTC,$(ts)" > "$WIN"
echo "$(ts) walk driver exit=0"
