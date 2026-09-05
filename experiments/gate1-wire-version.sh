#!/usr/bin/env bash
# Gate 1 / wire version (checklist box 2).
#
# One real request from each SDK client, captured at a pre-dispatch ingress
# ledger on the running kind cluster:
#   wv-go-001: loadgen (a2a-go client) -> worker           : header seen at the worker
#   wv-py-001: loadgen (a2a-go client) -> orchestrator (forward mode, a2a-python client) -> worker
#              : header seen at the orchestrator (a2a-go) and at the worker (a2a-python)
# No retry logic anywhere: one Job per work item, backoffLimit 0.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
RUN_ITEM="${RUN_ITEM:-2026-09-05-wire-version}"
# Work-item ids carry a per-run nonce (pod logs outlive runs; a repeated id would
# collect an earlier run's lines). SUMMARY_ONLY=1 reuses the ids recorded in run-id.txt.
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="wire-version-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"

mkdir -p "$RUN_DIR"
# SUMMARY_ONLY=1 recomputes summary.csv from the committed ledgers without touching the cluster.
SUMMARY_ONLY="${SUMMARY_ONLY:-0}"
if [ "$SUMMARY_ONLY" = "1" ] && [ -s "${RUN_DIR}/run-id.txt" ]; then RUN_ID="$(cat "${RUN_DIR}/run-id.txt")"; fi
GO_LWI="wv-${RUN_ID}-go-001"
PY_LWI="wv-${RUN_ID}-py-001"
echo "$RUN_ID" >"${RUN_DIR}/run-id.txt"

cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$SUMMARY_ONLY" != "1" ]; then
echo "== resetting mockllm counters and injections =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null
kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w 'reset: %{http_code}\n' -X POST "${MOCK_URL}/control/reset"
fi

run_job() {
	local lwi="$1" target="$2"
	echo "== loadgen Job ${lwi} -> ${target} =="
	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" deploy/base/loadgen-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply -f - >/dev/null
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/loadgen-${lwi}" --timeout=180s >/dev/null 2>&1 \
		|| kubectl -n "$NAMESPACE" wait --for=condition=failed "job/loadgen-${lwi}" --timeout=10s >/dev/null 2>&1 \
		|| echo "warning: job loadgen-${lwi} reached neither complete nor failed within the timeout"
	mkdir -p "${RUN_DIR}/${lwi}"
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${RUN_DIR}/${lwi}" >/dev/null
}

if [ "$SUMMARY_ONLY" != "1" ]; then
	run_job "$GO_LWI" "$WORKER_URL"
	run_job "$PY_LWI" "$ORCH_URL"
fi

# header seen at <source> for JSON-RPC deliveries of a work item; deliveries are
# arrival lines, the status comes from the matching response line
ver_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .phase == "arrival" and .method != "" and (.method | test(" ") | not)) | .a2a_version] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
method_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .phase == "arrival" and .method != "" and (.method | test(" ") | not)) | .method] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
status_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .phase == "response" and .method != "" and (.method | test(" ") | not)) | .status] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
count_at() { jq -s --arg src "$2" '[.[] | select(.source == $src and .phase == "arrival" and .method != "" and (.method | test(" ") | not))] | length' "${RUN_DIR}/$1/ingress.jsonl"; }
result_of() { jq -r -s 'last | "\(.result_kind // "none")/\(.state // "none")\(if .error then " error=" + .error else "" end)"' "${RUN_DIR}/$1/client.jsonl"; }
dispatches_at() { jq -s --arg src "$2" '[.[] | select(.source == $src and .event == "dispatch")] | length' "${RUN_DIR}/$1/execution.jsonl"; }
# model invocations made by the agent captured at <source> (caller field), not the whole work item
invocations() { jq -s --arg src "$2" '[.[] | select(.caller == $src and .outcome != "stale-closed")] | length' "${RUN_DIR}/$1/invocation.jsonl"; }

{
	echo "work_item,client_sdk,captured_at,deliveries,a2a_version,method,status,dispatches,invocations,client_result"
	echo "$GO_LWI,a2a-go,worker,$(count_at "$GO_LWI" worker),$(ver_at "$GO_LWI" worker),$(method_at "$GO_LWI" worker),$(status_at "$GO_LWI" worker),$(dispatches_at "$GO_LWI" worker),$(invocations "$GO_LWI" worker),$(result_of "$GO_LWI")"
	echo "$PY_LWI,a2a-go,orchestrator,$(count_at "$PY_LWI" orchestrator),$(ver_at "$PY_LWI" orchestrator),$(method_at "$PY_LWI" orchestrator),$(status_at "$PY_LWI" orchestrator),$(dispatches_at "$PY_LWI" orchestrator),$(invocations "$PY_LWI" orchestrator),$(result_of "$PY_LWI")"
	echo "$PY_LWI,a2a-python,worker,$(count_at "$PY_LWI" worker),$(ver_at "$PY_LWI" worker),$(method_at "$PY_LWI" worker),$(status_at "$PY_LWI" worker),$(dispatches_at "$PY_LWI" worker),$(invocations "$PY_LWI" worker),$(result_of "$PY_LWI")"
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
