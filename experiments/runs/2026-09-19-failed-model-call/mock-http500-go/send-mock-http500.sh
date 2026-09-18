#!/usr/bin/env bash
# Follow-ups 15, commit 2, reading (b): a status answered by the mock itself to the Go worker's model call, with
# no retry anywhere on the path. A run-directory helper, not an experiments/*.sh: no committed row produces this
# (the egress row arms the same injection with the egress route retry switched on), so this sends one work item
# with the primitives the committed scripts use, and nothing else.
#
# The mock has no 503 mode: its injection modes are http500, close, delay-then-close and stale
# (fixtures/mockllm/injection.go). http500 is the one in which the mock answers with a status, so the status read
# here is 500, answered by the mock and passed through the egress waypoint.
#
# The primitives, each from a committed script:
#   the retry-stanza count        kubectl get httproute -A -o yaml | grep -c 'retry:'   (gate3-matrix.sh)
#   the control pod and posts     curlimages/curl:8.22.0, curl -X POST from inside lab  (gate3-matrix.sh)
#   reset of all three injectors  POST /control/reset on mock, worker, orchestrator     (gate3-matrix.sh)
#   the mock arming               POST /control/inject {"mode":"http500","lwi":<id>}   (gate3-matrix.sh, RUN=egress)
#   the load Job                  deploy/base/loadgen-job.yaml through ko apply          (gate3-trace-per-work-item.sh)
#   complete-or-failed wait       both conditions polled every 2 s up to 180 s           (gate3-matrix.sh)
#   collection                    make ledgers after 2 s, make export-trace after 8 s   (gate3-matrix.sh defaults)
# Nothing here retries: one Job, backoffLimit 0, one send; every curl here is a single POST with no --retry.
#
# RUN_ID=<nonce> (required, lowercase alphanumeric), OUT=<run-directory-relative dir>. Runs from the repo root.
# The first invocation (RUN_ID=fmcb, 2026-09-18T21:21:55Z) stopped at this script's own pre-check and sent nothing:
# the retry-stanza count was taken inside a piped block, so it was not set where it was tested, and the CLIENT_*
# check matched a substring of OTEL_INSTRUMENTATION_HTTP_CAPTURE_HEADERS_CLIENT_REQUEST. Both are fixed below, the
# second with the jq test gate3-matrix.sh uses; that attempt is uncounted and its lines are in attempt-1-control.txt.
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
: "${RUN_ID:?RUN_ID required}"
: "${OUT:?OUT required}"
NAMESPACE=lab
CLUSTER_NAME=agent-mesh-lab
CURL_POD=fmc-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
LWI="fmc-http500-go-${RUN_ID}-01"
D="${OUT}/${LWI}"
CONTROL="${OUT}/control.txt"
mkdir -p "$D"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cleanup() {
	kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST "${MOCK_URL}/control/reset" >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	echo "$(ts) cleanup: mock reset attempted, control pod deleted" >>"$CONTROL"
}
trap cleanup EXIT

stanzas=$(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)
live_client_env="$(kubectl -n "$NAMESPACE" get deploy -o json |
	jq -r '[.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "\($n):\(.name)=\(.value)"] | join(" ")')"
{
echo "== $(ts) | RUN_ID=${RUN_ID} | work item ${LWI} =="
echo "retry stanzas across every HTTPRoute: ${stanzas}"
echo "worker env (names starting MODEL_ or CLIENT_):"
kubectl -n "$NAMESPACE" get deploy/worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(MODEL_|CLIENT_)' || echo "  (none)"
echo "CLIENT_* on any Deployment in lab, by the jq test gate3-matrix.sh uses (empty means none): ${live_client_env}"
} | tee -a "$CONTROL"
if [ "$stanzas" != "0" ]; then echo "STOP: a retry stanza is present; this reading needs none" | tee -a "$CONTROL"; exit 1; fi
if [ -n "$live_client_env" ]; then echo "STOP: a Deployment carries a client knob: ${live_client_env}" | tee -a "$CONTROL"; exit 1; fi
if kubectl -n "$NAMESPACE" get deploy/worker -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep -qx MODEL_RETRIES; then
	echo "STOP: the worker carries MODEL_RETRIES" | tee -a "$CONTROL"; exit 1
fi

kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null
post() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST "$1"; }
post_json() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$1"; }

for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
	code=$(post "$url"); echo "$(ts) POST ${url} -> ${code} (before)" | tee -a "$CONTROL"
	case "$code" in 2??) ;; *) echo "STOP: reset ${url} returned ${code}"; exit 1 ;; esac
done
body="{\"mode\":\"http500\",\"lwi\":\"${LWI}\"}"
code=$(post_json "${MOCK_URL}/control/inject" "$body"); echo "$(ts) POST ${MOCK_URL}/control/inject ${body} -> ${code}" | tee -a "$CONTROL"
case "$code" in 2??) ;; *) echo "STOP: arming returned ${code}"; exit 1 ;; esac

kubectl -n "$NAMESPACE" delete job "loadgen-${LWI}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
sed -e "s/\${LWI}/${LWI}/g" -e "s#\${TARGET_URL}#${WORKER_URL}#g" deploy/base/loadgen-job.yaml \
	| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >"${D}/apply.log" 2>&1
echo "$(ts) job loadgen-${LWI} applied" | tee -a "$CONTROL"
result=none; waited=0
while [ "$waited" -lt 180 ]; do
	conds=$(kubectl -n "$NAMESPACE" get "job/loadgen-${LWI}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
	case " $conds " in *" Complete "*) result=complete; break ;; *" Failed "*) result=failed; break ;; esac
	sleep 2; waited=$((waited + 2))
done
echo "$(ts) job loadgen-${LWI}: ${result} after ${waited}s" | tee -a "$CONTROL"
sleep 2
make --no-print-directory ledgers "LWI=${LWI}" "OUT=${D}" >/dev/null 2>>"${D}/collect.log" || echo "$(ts) make ledgers rc=$?" | tee -a "$CONTROL"
for url in "${WORKER_URL}/control/reset" "${MOCK_URL}/control/reset"; do
	code=$(post "$url"); echo "$(ts) POST ${url} -> ${code} (after)" | tee -a "$CONTROL"
done
sleep 8
make --no-print-directory export-trace "LWI=${LWI}" "OUT=${D}" >>"${D}/collect.log" 2>&1 || echo "$(ts) make export-trace rc=$?" | tee -a "$CONTROL"
echo "$(ts) done: ${D}" | tee -a "$CONTROL"
