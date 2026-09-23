#!/usr/bin/env bash
# Experiment C, step C-9: the controller's ruling (a), its question about the orchestrator's own forward. ONE
# SendMessage by the load client to the orchestrator along the one path whose card still advertises an address the
# client can dial on the marked cluster: TARGET_URL the ingress Service, CLIENT_DIAL and CLIENT_HOST empty, so the card
# GET crosses lab/orchestrator-ingress and the POST goes where that card points (the ingress, the same route). The
# orchestrator then forwards to DOWNSTREAM_A2A_URL, the worker's Service, resolving the worker's card there through
# agw-central. Then: the three ledgers by make ledgers, the client line, both proxies' access lines, the orchestrator's
# own log lines in the window, and the trace by make export-trace.
#   bash fwd.sh <out dir> <run id>
# One send, backoffLimit 0 (the template's); no retry logic. Keep-awake: this script starts none.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
OUT="${1:?out dir}"; RUN_ID="${2:?run id}"
NS=lab CLUSTER_NAME=agent-mesh-lab TEMPLATE=deploy/base/loadgen-a2-job.yaml
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
LWI="c9-fwd-py-sm-$RUN_ID-01"
W="$OUT/$LWI"; mkdir -p "$W"
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>/dev/null)
case "$IMAGE" in kind.local/loadgen-*:*) ;; *) echo "image not resolved"; exit 1 ;; esac
echo "$(tsn) image $IMAGE" > "$W/steps.txt"
orch_pod=$(kubectl -n "$NS" get pods -l app=orchestrator -o jsonpath='{.items[0].metadata.name}')
echo "$(tsn) orchestrator pod $orch_pod uid $(kubectl -n "$NS" get pod "$orch_pod" -o jsonpath='{.metadata.uid}') restarts $(kubectl -n "$NS" get pod "$orch_pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" >> "$W/steps.txt"
since=$(tsn)
name="loadgen-$LWI"
sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
	-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" -e "s/\${LWI}/${LWI}/g" -e "s#\${TARGET_URL}#${INGRESS}#g" \
	-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" -e "s/\${CLIENT_RETRY_ON}/transport/g" \
	-e "s/\${CLIENT_DIAL}//g" -e "s/\${CLIENT_HOST}//g" -e "s/\${MODE}//g" -e "s/\${TASK_ID}//g" -e "s/\${CANCEL_AFTER_MS}//g" \
	"$TEMPLATE" > "$W/job.yaml"
if grep -q '\${' "$W/job.yaml"; then echo "placeholder left; not applied"; exit 1; fi
kubectl apply -f "$W/job.yaml" > "$W/apply.log" 2>&1
echo "$(tsn) applied $name TARGET_URL=$INGRESS CLIENT_DIAL=<empty> CLIENT_HOST=<empty> MODE=<empty>" >> "$W/steps.txt"
st=""; for _ in $(seq 1 90); do st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1); [ -n "$st" ] && break; sleep 1; done
echo "$(tsn) Job ${st:-timeout}" >> "$W/steps.txt"
sleep 2
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/ingress-access.txt" || true
kubectl -n "$NS" logs "$orch_pod" --since-time="$since" 2>/dev/null > "$W/orchestrator-log-window.txt" || true
rc=0; make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || rc=$?
echo "$(tsn) make ledgers exit=$rc" >> "$W/steps.txt"
sleep 5
rc=0; make --no-print-directory export-trace "LWI=$LWI" "OUT=$W/trace" LOOKBACK=3600 > "$W/export-trace.txt" 2>&1 || rc=$?
echo "$(tsn) export-trace exit=$rc" >> "$W/steps.txt"
cat "$W/steps.txt"
