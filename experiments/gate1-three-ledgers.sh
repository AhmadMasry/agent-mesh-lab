#!/usr/bin/env bash
# Gate 1 / go / single clean request (checklist box 3).
#
# Sends exactly one SendMessage from the a2a-go load client (a Kubernetes Job)
# to the Go worker on the running kind cluster, then collects the four ledgers
# for that work item with `make ledgers` and derives the counts. No retry logic
# anywhere: the Job has backoffLimit 0 and the client sends once.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
# The work-item id carries a per-run nonce: pod logs outlive runs, and a repeated id
# would collect an earlier run's lines as if they were this run's.
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
LWI="${LWI:-clean-${RUN_ID}-001}"
RUN_ITEM="${RUN_ITEM:-$(date +%F)-three-ledgers}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="ledgers-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"

mkdir -p "$RUN_DIR"

cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== resetting mockllm counters and injections =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null
kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w 'reset: %{http_code}\n' -X POST "${MOCK_URL}/control/reset"

echo "== launching loadgen Job for logical_work_item_id=${LWI} =="
kubectl -n "$NAMESPACE" delete job "loadgen-${LWI}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
sed -e "s/\${LWI}/${LWI}/g" -e "s#\${TARGET_URL}#${TARGET_URL:-http://worker.lab.svc.cluster.local:8080}#g" deploy/base/loadgen-job.yaml \
	| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >/dev/null
# A Job that fails is a recorded outcome, so wait for either condition.
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/loadgen-${LWI}" --timeout=180s >/dev/null 2>&1 \
	|| kubectl -n "$NAMESPACE" wait --for=condition=failed "job/loadgen-${LWI}" --timeout=10s >/dev/null 2>&1 \
	|| echo "warning: job loadgen-${LWI} reached neither complete nor failed within the timeout"

echo "== collecting ledgers =="
make --no-print-directory ledgers "LWI=${LWI}" "OUT=${RUN_DIR}"

count_lines() { if [ -s "$1" ]; then grep -c . "$1"; else echo 0; fi; }

# Every delivery has an arrival line (written before dispatch) and a response
# line; deliveries are counted on arrival lines. JSON-RPC deliveries are those
# whose method has no space (HTTP-level lines read "<METHOD> <path>").
ingress_arrivals_for_work_item=$(jq -s '[.[] | select(.phase == "arrival")] | length' "${RUN_DIR}/ingress.jsonl")
deliveries_ingress_jsonrpc=$(jq -s '[.[] | select(.phase == "arrival" and .method != "" and (.method | test(" ") | not))] | length' "${RUN_DIR}/ingress.jsonl")
dispatches=$(jq -s '[.[] | select(.event == "dispatch")] | length' "${RUN_DIR}/execution.jsonl")
distinct_message_ids=$(jq -s '[.[] | select(.phase == "arrival" and .messageId != "") | .messageId] | unique | length' "${RUN_DIR}/ingress.jsonl")
tasks_created=$(jq -s '[.[] | select(.event == "state" and .state == "TASK_STATE_SUBMITTED")] | length' "${RUN_DIR}/execution.jsonl")
task_final_state=$(jq -r -s '[.[] | select(.event == "result")] | last | .state // "none"' "${RUN_DIR}/execution.jsonl")
# model calls made for the work item; a stale-closed line records a connection close, not a call
invocations=$(jq -s '[.[] | select(.outcome != "stale-closed")] | length' "${RUN_DIR}/invocation.jsonl")
a2a_version_seen=$(jq -r -s '[.[] | select(.phase == "arrival" and .method != "" and (.method | test(" ") | not)) | .a2a_version] | unique | join("|")' "${RUN_DIR}/ingress.jsonl")
client_result_kind=$(jq -r -s 'last | .result_kind // "none"' "${RUN_DIR}/client.jsonl")

{
	echo "deliveries_ingress_jsonrpc,ingress_arrivals_for_work_item,dispatches,distinct_message_ids,tasks_created,task_final_state,invocations,a2a_version_seen,client_result_kind"
	echo "${deliveries_ingress_jsonrpc},${ingress_arrivals_for_work_item},${dispatches},${distinct_message_ids},${tasks_created},${task_final_state},${invocations},${a2a_version_seen},${client_result_kind}"
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
