#!/usr/bin/env bash
# Gate 2 / instruments / single clean request.
#
# One clean SendMessage per receiver on the running kind cluster, counted after
# the executor-entry line was added, the SDK-entry event was renamed, and the
# injection hooks were built. Nothing is armed here: both control endpoints are
# reset before each request and no injection is applied, so this measures the
# instruments, not a failure.
#
#   worker:       loadgen -> worker Service (the waypoint the Service names is on the
#                 path: since 2026-09-19 `agw-central`, under agentgateway's own control
#                 plane; until then an istiod-driven waypoint)
#   orchestrator: loadgen -> orchestrator Service for the card; the card
#                 advertises the agentgateway ingress, so the SendMessage POST
#                 enters through the ingress, and the orchestrator forwards to
#                 the worker (forward mode as deployed).
#
# No retry logic anywhere: one Job per work item, backoffLimit 0, one send.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
# The work-item id carries a per-run nonce: pod logs outlive runs, and a repeated
# id would collect an earlier run's lines as if they were this run's.
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
RUN_ITEM="${RUN_ITEM:-$(date +%F)-instruments-single-clean}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="gate2-curl"
CURL_IMAGE="curlimages/curl:8.22.0"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"

mkdir -p "$RUN_DIR"

cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== starting the control pod =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 900 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

post() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w "%{http_code}" -X POST "$1"; }

reset_all() {
	echo "== resetting mockllm and both receivers' injectors =="
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url")
		echo "reset ${url}: ${code}"
		case "$code" in 2??) ;; *) echo "reset ${url} returned ${code}" >&2; exit 1 ;; esac
	done
}

run_one() { # $1 = receiver, $2 = target URL, $3 = work item
	local receiver="$1" target="$2" lwi="$3"
	echo "== ${receiver}: one clean request, logical_work_item_id=${lwi} =="
	reset_all
	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" deploy/base/loadgen-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >/dev/null
	# A Job that fails is a recorded outcome, so wait for either condition.
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/loadgen-${lwi}" --timeout=180s >/dev/null 2>&1 \
		|| kubectl -n "$NAMESPACE" wait --for=condition=failed "job/loadgen-${lwi}" --timeout=10s >/dev/null 2>&1 \
		|| echo "warning: job loadgen-${lwi} reached neither complete nor failed within the timeout"
	sleep 1
	mkdir -p "${RUN_DIR}/${lwi}"
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${RUN_DIR}/${lwi}" >/dev/null
}

# Counts are scoped to the named receiver's own ledgers, except invocations:
# the model call for a forwarded work item is made by the downstream agent, so
# model invocations are counted for the work item as a whole.
counts() { # $1 = receiver, $2 = work item
	local receiver="$1" d="${RUN_DIR}/$2"
	local deliveries received executes tasks invocations result
	deliveries=$(jq -s --arg src "$receiver" '[.[] | select(.source == $src and .phase == "arrival" and .method == "SendMessage")] | length' "$d/ingress.jsonl")
	received=$(jq -s --arg src "$receiver" '[.[] | select(.source == $src and .event == "received")] | length' "$d/execution.jsonl")
	# dispatches are executor entries since Gate 2 Task 0: event "execute", not the SDK's "received"
	executes=$(jq -s --arg src "$receiver" '[.[] | select(.source == $src and .event == "execute")] | length' "$d/execution.jsonl")
	tasks=$(jq -s --arg src "$receiver" '[.[] | select(.source == $src and .event == "state" and .state == "TASK_STATE_SUBMITTED") | .taskId] | unique | length' "$d/execution.jsonl")
	# a stale-closed line records a connection close, not a call
	invocations=$(jq -s '[.[] | select(.outcome != "stale-closed")] | length' "$d/invocation.jsonl")
	result=$(jq -r -s 'if length == 0 then "none" else (last | "\(.result_kind // "none")/\(.state // "none")\(if .error then " error" else "" end)") end' "$d/client.jsonl")
	echo "${receiver},$2,${deliveries},${received},${executes},${tasks},${invocations},${result}"
}

WORKER_LWI="g2c-${RUN_ID}-worker"
ORCH_LWI="g2c-${RUN_ID}-orchestrator"
run_one worker "$WORKER_URL" "$WORKER_LWI"
run_one orchestrator "$ORCH_URL" "$ORCH_LWI"

# The injectors are disarmed after the run as well as before it, so a run that ends
# here leaves nothing armed for the next one to be surprised by. reset_all exits
# non-zero on any reply that is not 2xx, which is the loud failure this needs: the
# next run would otherwise start against a cluster this one cannot vouch for.
echo "== after the run =="
reset_all

{
	echo "receiver,work_item,deliveries,received,executes,tasks_created,invocations,client_result"
	counts worker "$WORKER_LWI"
	counts orchestrator "$ORCH_LWI"
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
