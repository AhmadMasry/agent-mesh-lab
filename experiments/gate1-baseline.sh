#!/usr/bin/env bash
# Gate 1 / baseline proven retry-free (checklist box 4), step 1 (no mesh) or
# step 2 (STEP=2: same runs through the mesh path). STEP is a label, not a switch:
# it names the run directory and the work-item ids, and the path is whatever the
# cluster currently has applied, so STEP=2b with RUN4_URL set counts the same runs
# through the agentgateway ingress and egress.
#
# Seven run types, REPS repetitions each, every repetition a fresh work item.
# For each, the four ledgers are collected and the counts that would reveal a
# retry are derived: deliveries at each receiver, dispatches, model invocations
# per caller. No retry logic anywhere in this script; a failed request is a
# recorded outcome. Runs 5 and 6 change the orchestrator's environment
# (PLAN_MODEL_CALL, MODEL_MAX_RETRIES) and run 3 the worker's (MODEL_TIMEOUT_S);
# the script restores them at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
STEP="${STEP:-1}"
REPS="${REPS:-5}"
RUN_ITEM="${RUN_ITEM:-$(date +%F)-baseline-step${STEP}}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="baseline-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"
# Run 4's entry point, meaning the URL loadgen resolves the agent card from. It
# defaults to the orchestrator's own Service, which is what steps 1 and 2 measured;
# step 2b sets it to the agentgateway ingress Service so the request enters through
# that gateway.
#
# Runs 5 and 6 keep ORCH_URL, and that fixes where the card is fetched from, not
# where the request goes: the a2a-go client is built from the card and sends every
# request to the interface URL the card advertises. At steps 1 and 2 the card
# advertises the orchestrator's own Service, so the card fetch and the POST both go
# there. With the step-2b overlay applied the card advertises the ingress, so a run 5
# or 6 request would fetch the card from ORCH_URL and then send its POST through the
# ingress. Runs 5 and 6 were counted once, in the step-1 entry, and have not been run
# at step 2b.
RUN4_URL="${RUN4_URL:-$ORCH_URL}"
RUNS="${RUNS:-1 2 3 4 5 6 7}"
# Work-item ids carry a per-invocation nonce: pod logs outlive a run, and a
# repeated id would collect an earlier run's lines as if they were retries.
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"

mkdir -p "$RUN_DIR"

restore_env() {
	kubectl -n "$NAMESPACE" set env deployment/worker MODEL_TIMEOUT_S- >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" set env deployment/orchestrator PLAN_MODEL_CALL=off MODEL_MAX_RETRIES=0 >/dev/null 2>&1 || true
}
cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	restore_env
	kubectl -n "$NAMESPACE" rollout status deployment/worker --timeout=120s >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

control() { # $1 = path, $2 = JSON body (or empty)
	kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${2:-}" "${MOCK_URL}$1"
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
reset_mock() { local c; c=$(control /control/reset); ok2xx "$c" || { echo "mock reset returned $c" >&2; exit 1; }; }
inject() { local c; c=$(control /control/inject "$1"); ok2xx "$c" || { echo "mock inject returned $c for $1" >&2; exit 1; }; }

set_env() { # $1 = deployment, rest = env assignments
	local d="$1"; shift
	kubectl -n "$NAMESPACE" set env "deployment/$d" "$@" >/dev/null
	kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=180s >/dev/null
}

job() { # $1 = lwi, $2 = target url, $3 = seconds to wait before collecting (an injection that
	# delays the mock's response also delays its ledger line; collect only after it has landed)
	kubectl -n "$NAMESPACE" delete job "loadgen-$1" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/$1/g" -e "s#\${TARGET_URL}#$2#g" deploy/base/loadgen-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >/dev/null 2>&1
	JOB_NOTE=""
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/loadgen-$1" --timeout=240s >/dev/null 2>&1 \
		|| kubectl -n "$NAMESPACE" wait --for=condition=failed "job/loadgen-$1" --timeout=10s >/dev/null 2>&1 \
		|| { JOB_NOTE="job loadgen-$1 reached neither complete nor failed within the timeout"; echo "warning: $JOB_NOTE" >&2; }
	sleep "${3:-1}"
	mkdir -p "${RUN_DIR}/$1"
	make --no-print-directory ledgers "LWI=$1" "OUT=${RUN_DIR}/$1" >/dev/null
}

# per-work-item counts: deliveries@worker deliveries@orchestrator dispatches@worker invocations invocations_by_caller client_result
counts() {
	local d="${RUN_DIR}/$1"
	local dw do dsp inv byc res
	dw=$(jq -s '[.[] | select(.source=="worker" and .phase=="arrival" and .method != "" and (.method|test(" ")|not))] | length' "$d/ingress.jsonl")
	do=$(jq -s '[.[] | select(.source=="orchestrator" and .phase=="arrival" and .method != "" and (.method|test(" ")|not))] | length' "$d/ingress.jsonl")
	dsp=$(jq -s '[.[] | select(.source=="worker" and .event=="dispatch")] | length' "$d/execution.jsonl")
	inv=$(jq -s '[.[] | select(.outcome != "stale-closed")] | length' "$d/invocation.jsonl")
	byc=$(jq -r -s '[.[] | select(.outcome != "stale-closed") | .caller] | group_by(.) | map("\(.[0])=\(length)") | join("+")' "$d/invocation.jsonl")
	res=$(jq -r -s 'if length == 0 then "none" else (last | "\(.result_kind // "none")/\(.state // "none")\(if .error then " error" else "" end)") end' "$d/client.jsonl")
	echo "$dw,$do,$dsp,$inv,${byc:-none},$res"
}

declare -a ROWS
run_type() { # $1 = run id, $2 = label, $3 = target, $4 = injection JSON template (LWI substituted), $5 = notes, $6 = collect wait
	local id="$1" label="$2" target="$3" tpl="$4" notes="$5" wait="${6:-1}"
	echo "== run $id: $label =="
	for i in $(seq 1 "$REPS"); do
		local lwi="b${STEP}-${RUN_ID}-r${id}-$(printf '%02d' "$i")"
		reset_mock
		if [ -n "$tpl" ]; then inject "${tpl//__LWI__/$lwi}"; fi
		job "$lwi" "$target" "$wait"
		local c; c=$(counts "$lwi")
		echo "  $lwi: $c"
		ROWS+=("$id,$label,$lwi,$c,${notes}${JOB_NOTE:+ ${JOB_NOTE}}")
	done
}

for r in $RUNS; do
	case "$r" in
	1) run_type 1 "close@model; loadgen->worker" "$WORKER_URL" '{"mode":"close","lwi":"__LWI__"}' "" ;;
	2) run_type 2 "http500@model; loadgen->worker" "$WORKER_URL" '{"mode":"http500","lwi":"__LWI__"}' "" ;;
	3) set_env worker MODEL_TIMEOUT_S=5
	   run_type 3 "delay-then-close@model 8s > worker timeout 5s; loadgen->worker" "$WORKER_URL" '{"mode":"delay-then-close","lwi":"__LWI__","delay_ms":8000}' "worker MODEL_TIMEOUT_S=5" 10
	   set_env worker MODEL_TIMEOUT_S- ;;
	4) run_type 4 "close@model; loadgen->orchestrator->worker" "$RUN4_URL" '{"mode":"close","lwi":"__LWI__"}' "" ;;
	5) set_env orchestrator PLAN_MODEL_CALL=on MODEL_MAX_RETRIES=0
	   run_type 5 "close@model for the orchestrator's own call; PLAN_MODEL_CALL=on; max_retries=0" "$ORCH_URL" '{"mode":"close","lwi":"__LWI__"}' "orchestrator PLAN_MODEL_CALL=on MODEL_MAX_RETRIES=0" ;;
	6) set_env orchestrator PLAN_MODEL_CALL=on MODEL_MAX_RETRIES=2
	   run_type 6 "control: close@model for the orchestrator's own call; PLAN_MODEL_CALL=on; openai default max_retries=2" "$ORCH_URL" '{"mode":"close","lwi":"__LWI__"}' "orchestrator PLAN_MODEL_CALL=on MODEL_MAX_RETRIES=2"
	   set_env orchestrator PLAN_MODEL_CALL=off MODEL_MAX_RETRIES=0 ;;
	7) echo "== run 7: stale keep-alive connection, two sequential requests per work item =="
	   for i in $(seq 1 "$REPS"); do
	   	lwi="b${STEP}-${RUN_ID}-r7-$(printf '%02d' "$i")"
	   	reset_mock; inject "{\"mode\":\"stale\",\"lwi\":\"$lwi\"}"
	   	job "$lwi" "$WORKER_URL"
	   	# second request, same work item: the worker's pooled connection to the model was closed while idle
	   	kubectl -n "$NAMESPACE" delete job "loadgen-$lwi" --wait=true >/dev/null 2>&1 || true
	   	sleep 1
	   	job "$lwi" "$WORKER_URL"
	   	c=$(counts "$lwi"); echo "  $lwi: $c"
	   	stale_closed=$(jq -s '[.[] | select(.outcome=="stale-closed")] | length' "${RUN_DIR}/$lwi/invocation.jsonl")
	   	ROWS+=("7,stale: two sequential requests on one keep-alive connection; loadgen->worker,$lwi,$c,stale_closed_lines=$stale_closed (second Job replaces the first; client.jsonl holds the second request)${JOB_NOTE:+ ${JOB_NOTE}}")
	   done ;;
	esac
done

# Rows append to an existing summary so the seven run types can be executed in
# chunks (RUNS="1 2 3", then "4 5 6", then "7") into the same run directory.
if [ ! -s "${RUN_DIR}/summary.csv" ]; then
	echo "run,label,work_item,deliveries_worker,deliveries_orchestrator,dispatches_worker,invocations,invocations_by_caller,client_result,notes" >"${RUN_DIR}/summary.csv"
fi
if [ "${#ROWS[@]}" -gt 0 ]; then printf '%s\n' "${ROWS[@]}" >>"${RUN_DIR}/summary.csv"; fi

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
