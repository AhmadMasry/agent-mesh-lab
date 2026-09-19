#!/usr/bin/env bash
# cluster-after.sh <out file> -- reads the cluster back after this task's live rows, then deletes the
# loadgen Jobs THIS task created (nonces fu18p, fu18f, fu18r, fu18x) and reads the Jobs again. The six
# Jobs the cluster was found with (fu18c, fu18t: the previous task's readings) are not touched. Nothing
# else is changed. No retry: every command runs once.
set -uo pipefail
OUT="$1"
NS=lab
{
echo "== $(date -u +%FT%TZ) | the cluster after the live rows of follow-ups 18 task 3 =="
echo
echo "-- Gateways and HTTPRoutes --"
kubectl get gateway -A
kubectl get httproute -A
echo
echo "-- retry stanzas --"
echo "across every HTTPRoute (kubectl get httproute -A -o yaml | grep -c 'retry:'): $(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)"
for route in lab/worker lab/orchestrator lab/worker-ingress lab/orchestrator-ingress agentgateway-waypoint/model-via-agw; do
	y=$(kubectl -n "${route%%/*}" get "httproute/${route#*/}" -o yaml) || { echo "  ${route}: UNREADABLE"; continue; }
	echo "  ${route}: $(printf '%s\n' "$y" | grep -c 'retry:' || true)"
done
echo
echo "-- the mock's own control lines (it writes one per inject and per reset; it has not restarted) --"
kubectl -n "$NS" get pods -l app=mockllm -o 'custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.startTime'
CONTROL=$(kubectl -n "$NS" logs deploy/mockllm | jq -R -c 'fromjson? | select(.ledger == "control")')
echo "inject lines: $(printf '%s\n' "$CONTROL" | grep -c '/control/inject' || true)   reset lines: $(printf '%s\n' "$CONTROL" | grep -c '/control/reset' || true)"
echo "the last inject line: $(printf '%s\n' "$CONTROL" | grep '/control/inject' | tail -1)"
echo "the last control line: $(printf '%s\n' "$CONTROL" | tail -1)"
echo
echo "-- retry knobs on the Deployments (empty means unset) --"
for pair in worker:MODEL_RETRIES orchestrator:MODEL_MAX_RETRIES orchestrator:DOWNSTREAM_A2A_URL orchestrator:PLAN_MODEL_CALL; do
	printf '  deployment/%s %s=%s\n' "${pair%%:*}" "${pair#*:}" "$(kubectl -n "$NS" get "deployment/${pair%%:*}" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"${pair#*:}\")].value}")"
done
echo "  CLIENT_* on any Deployment in ${NS}: $(kubectl -n "$NS" get deploy -o json | jq -r '[.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "\($n):\(.name)=\(.value)"] | join(" ") | if . == "" then "<none>" else . end')"
echo
echo "-- pods that are neither Running nor Completed, every namespace --"
kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | sed 's/^/  /'
echo "  (count: $(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | grep -c . || true))"
echo
echo "-- control pods of the run scripts (a3m-curl, a3r-curl, a3t-curl, a2-curl) --"
kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$1 ~ /-curl$/' | sed 's/^/  /'
echo "  (count: $(kubectl -n "$NS" get pods --no-headers | awk '$1 ~ /-curl$/' | grep -c . || true))"
echo
echo "-- Jobs in ${NS}, before this task's are deleted, by run nonce --"
kubectl -n "$NS" get jobs --no-headers | awk '{print $1}' | sed -E 's/.*-(fu18[a-z])-.*/\1/' | sort | uniq -c | sed 's/^/  /'
MINE=$(kubectl -n "$NS" get jobs -o name | grep -E -- '-fu18[pfrx]-' || true)
echo "deleting $(printf '%s\n' "$MINE" | grep -c . || true) Jobs of this task:"
printf '%s\n' "$MINE" | sed 's/^/  /'
# shellcheck disable=SC2086
[ -z "$MINE" ] || kubectl -n "$NS" delete $MINE --wait=true
echo
echo "-- Jobs and pods in ${NS} after --"
kubectl -n "$NS" get jobs
kubectl -n "$NS" get pods
echo
echo "== $(date -u +%FT%TZ) | end =="
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"
