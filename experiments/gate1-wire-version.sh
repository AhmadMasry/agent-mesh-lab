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
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="wire-version-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"

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

run_job "wv-go-001" "$WORKER_URL"
run_job "wv-py-001" "$ORCH_URL"

# header seen at <source> for JSON-RPC deliveries of a work item
ver_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .method != "" and (.method | test(" ") | not)) | .a2a_version] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
method_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .method != "" and (.method | test(" ") | not)) | .method] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
status_at() { jq -r -s --arg src "$2" '[.[] | select(.source == $src and .method != "" and (.method | test(" ") | not)) | .status] | unique | join("|")' "${RUN_DIR}/$1/ingress.jsonl"; }
count_at() { jq -s --arg src "$2" '[.[] | select(.source == $src and .method != "" and (.method | test(" ") | not))] | length' "${RUN_DIR}/$1/ingress.jsonl"; }
result_of() { jq -r -s 'last | "\(.result_kind // "none")/\(.state // "none")\(if .error then " error=" + .error else "" end)"' "${RUN_DIR}/$1/client.jsonl"; }
dispatches_at() { jq -s --arg src "$2" '[.[] | select(.source == $src and .event == "dispatch")] | length' "${RUN_DIR}/$1/execution.jsonl"; }
invocations() { if [ -s "${RUN_DIR}/$1/invocation.jsonl" ]; then grep -c . "${RUN_DIR}/$1/invocation.jsonl"; else echo 0; fi; }

{
	echo "work_item,client_sdk,captured_at,deliveries,a2a_version,method,status,dispatches,invocations,client_result"
	echo "wv-go-001,a2a-go,worker,$(count_at wv-go-001 worker),$(ver_at wv-go-001 worker),$(method_at wv-go-001 worker),$(status_at wv-go-001 worker),$(dispatches_at wv-go-001 worker),$(invocations wv-go-001),$(result_of wv-go-001)"
	echo "wv-py-001,a2a-go,orchestrator,$(count_at wv-py-001 orchestrator),$(ver_at wv-py-001 orchestrator),$(method_at wv-py-001 orchestrator),$(status_at wv-py-001 orchestrator),$(dispatches_at wv-py-001 orchestrator),$(invocations wv-py-001),$(result_of wv-py-001)"
	echo "wv-py-001,a2a-python,worker,$(count_at wv-py-001 worker),$(ver_at wv-py-001 worker),$(method_at wv-py-001 worker),$(status_at wv-py-001 worker),$(dispatches_at wv-py-001 worker),$(invocations wv-py-001),$(result_of wv-py-001)"
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
