#!/usr/bin/env bash
# Gate 1 / mockllm / deterministic (checklist box 6).
#
# Runs entirely against the mockllm Service already deployed by
# `make cluster-kind step-1`, driven from a throwaway curl pod inside the
# cluster. No retry logic anywhere in this script: each request is sent
# exactly once, and whatever curl reports (a status code, or none at all)
# is the recorded outcome.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
SVC_URL="http://mockllm.lab.svc.cluster.local:8080"
RUN_ITEM="2026-09-05-mockllm-deterministic"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="mockllm-det-curl"
CURL_IMAGE="curlimages/curl:8.22.0"

FIXED_BODY='{"model":"mockllm-det-test","messages":[{"role":"user","content":"deterministic check"}]}'

mkdir -p "$RUN_DIR"

sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}

cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== starting throwaway curl pod ${CURL_POD} in namespace ${NAMESPACE} =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

# curl_request sets REQ_STATUS and REQ_BODY from a single POST to
# /v1/chat/completions, made from inside the curl pod with the fixed body
# and any header args given ("Header: value" strings). REQ_STATUS is "000"
# when no HTTP response was received at all (the close-mode case).
curl_request() {
	local -a header_args=()
	local h
	for h in "$@"; do
		header_args+=("-H" "$h")
	done
	local out
	out=$(kubectl -n "$NAMESPACE" exec "$CURL_POD" -- sh -c '
		url="$1"; body="$2"; shift 2
		rm -f /tmp/resp.body
		status=$(curl -s -o /tmp/resp.body -w "%{http_code}" -X POST -H "Content-Type: application/json" "$@" -d "$body" "$url/v1/chat/completions")
		echo "$status"
		echo "__BODY_START__"
		cat /tmp/resp.body 2>/dev/null
		exit 0
	' _ "$SVC_URL" "$FIXED_BODY" "${header_args[@]}")
	REQ_STATUS=$(printf '%s\n' "$out" | sed -n '1p')
	REQ_BODY=$(printf '%s\n' "$out" | awk '/^__BODY_START__$/{found=1; next} found{print}')
}

control_reset() {
	kubectl -n "$NAMESPACE" exec "$CURL_POD" -- \
		curl -s -o /dev/null -w '%{http_code}' -X POST "${SVC_URL}/control/reset"
	echo
}

control_inject() {
	local payload="$1"
	kubectl -n "$NAMESPACE" exec "$CURL_POD" -- \
		curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
		-d "$payload" "${SVC_URL}/control/inject"
	echo
}

echo "== sub-run 1: 20 identical requests, work item det-001 =="
control_reset >/dev/null
hashes=()
latencies_status=()
for i in $(seq 1 20); do
	curl_request "X-Logical-Work-Item-Id: det-001"
	if [ "$REQ_STATUS" != "200" ]; then
		echo "det-001 request $i: unexpected status $REQ_STATUS" >&2
	fi
	hash=$(printf '%s' "$REQ_BODY" | sha256_hex)
	hashes+=("$hash")
	echo "  det-001 request $i: status=$REQ_STATUS sha256=$hash"
done

identical_hashes=0
first_hash="${hashes[0]}"
for h in "${hashes[@]}"; do
	if [ "$h" = "$first_hash" ]; then
		identical_hashes=$((identical_hashes + 1))
	fi
done

echo "== sub-run 2: close injection at invocation count 5, work item det-002 =="
control_reset >/dev/null
control_inject '{"mode":"close","at_count":5}' >/dev/null
det002_failed_at=0
for i in $(seq 1 6); do
	curl_request "X-Logical-Work-Item-Id: det-002"
	echo "  det-002 request $i: status=$REQ_STATUS"
	if [ "$REQ_STATUS" != "200" ] && [ "$det002_failed_at" -eq 0 ]; then
		det002_failed_at=$i
	fi
done

echo "== sub-run 3: close injection keyed to work item det-003 =="
control_reset >/dev/null
control_inject '{"mode":"close","lwi":"det-003"}' >/dev/null
lwi_hits_det003=0
for i in 1 2; do
	curl_request "X-Logical-Work-Item-Id: det-003"
	echo "  det-003 request $i: status=$REQ_STATUS"
	if [ "$REQ_STATUS" != "200" ]; then
		lwi_hits_det003=$((lwi_hits_det003 + 1))
	fi
done
lwi_hits_det004=0
for i in 1 2; do
	curl_request "X-Logical-Work-Item-Id: det-004"
	echo "  det-004 request $i: status=$REQ_STATUS"
	if [ "$REQ_STATUS" != "200" ]; then
		lwi_hits_det004=$((lwi_hits_det004 + 1))
	fi
done

echo "== collecting invocation ledger lines via make ledgers =="
{
	make --no-print-directory ledgers LWI=det-001
	make --no-print-directory ledgers LWI=det-002
	make --no-print-directory ledgers LWI=det-003
	make --no-print-directory ledgers LWI=det-004
} | grep -v '^$' >"${RUN_DIR}/invocation.jsonl"

det001_ledger=$(grep '"logical_work_item_id":"det-001"' "${RUN_DIR}/invocation.jsonl" || true)
latency_min_ms=$(printf '%s\n' "$det001_ledger" | jq -s 'map(.latency_ms) | min')
latency_max_ms=$(printf '%s\n' "$det001_ledger" | jq -s 'map(.latency_ms) | max')

{
	echo "identical_hashes,latency_min_ms,latency_max_ms,count_injection_fired_at,lwi_injection_hits_det003,lwi_injection_hits_det004"
	echo "${identical_hashes},${latency_min_ms},${latency_max_ms},${det002_failed_at},${lwi_hits_det003},${lwi_hits_det004}"
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
