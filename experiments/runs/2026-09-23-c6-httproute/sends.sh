#!/usr/bin/env bash
# Experiment C, steps C-6 and C-7: the send driver, kept in C-6's run directory and used by C-7 from here. ONE
# request per call, on the paths B-4 fixed for both receivers (the agentgateway ingress; see B-4's entry):
#   go  the load client with TARGET_URL = the ingress Service, CLIENT_DIAL=target, CLIENT_HOST=worker.lab.internal:
#       the card GET and the POST cross the ingress's route lab/worker-ingress (the author's note of 2026-09-22).
#   py  the load client with TARGET_URL = the orchestrator Service: the card GET crosses agw-central's
#       lab/orchestrator, and the POST goes where the card points, the ingress, route lab/orchestrator-ingress.
# The orchestrator stays as deployed (forward mode); nothing on any Deployment is changed.
#
#   bash sends.sh <phase> <kind> <recv> <n>        RUNREL, RUN_ID and IMAGE in the environment
#     kind  sm   the load client, MODE unset: ONE SendMessage (unary)
#           st   the load client, MODE=subscribe, TASK_ID naming no task: ONE SubscribeToTask. A refusal happens
#                before dispatch, so a refused one needs no live task (the brief); an unrefused one is answered by the
#                receiver for a task it does not hold
#           ss   the load client, MODE=stream: ONE SendStreamingMessage (the operation a header cannot tell from st)
#           cst  a curl pod: ONE SubscribeToTask with the same JSON-RPC shape the load client sends, to the same
#                ingress route with the same Host, and curl's own default headers -- no Accept: text/event-stream.
#                The operation is the same; the client's headers are not.
#   bash sends.sh image                             resolve the load client image once (ko build, as B-4's rows did)
#   bash sends.sh pod-up | pod-down                 the curl pod in lab
#
# Every stimulus carries A2A-Version: 1.0 (the load client sets it on every POST; the curl sets it). One send per
# Job, backoffLimit 0 (the template's), every curl --retry 0; a refused or failed send is recorded as the caller saw
# it and never re-sent. After each send: the Job's end, the three ledgers by the committed make ledgers (exit kept),
# the client lines, and both proxies' access lines since the send began. One send runs at a time and nothing else in
# the lab sends, so that window holds this send's lines; each line also names the sender's pod address.
# No retry logic. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c5/tools/istioctl-1.31.0:$PATH"
export PATH
NS=lab
CLUSTER_NAME=agent-mesh-lab
POD=c6-curl
CURL_IMAGE=curlimages/curl:8.22.0
TEMPLATE=deploy/base/loadgen-a2-job.yaml
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
JOB_LIMIT_S=90
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
RUNREL="${RUNREL:?RUNREL is required}"
D="experiments/runs/$RUNREL"
mkdir -p "$D"

cmd="${1:-}"
case "$cmd" in
image)
	t0=$(tsn)
	IMG=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/c5/ko-build-$RUNREL.log")
	rc=$?
	echo "$t0 ko build ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) rc=$rc image=${IMG:-<none>} HEAD=$(git rev-parse HEAD) fixtures=$(git rev-parse HEAD:fixtures) template=$(git rev-parse HEAD:$TEMPLATE)" | tee -a "$D/image.txt"
	exit "$rc"
	;;
pod-up)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run "$POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
	echo "$(ts) pod-up $POD ip=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')" | tee -a "$D/phases.txt"
	exit 0
	;;
pod-down)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
	echo "$(ts) pod-down $POD" | tee -a "$D/phases.txt"
	exit 0
	;;
esac

PHASE="${1:?phase}" KIND="${2:?kind}" RECV="${3:?recv}" N="${4:?n}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
case "$KIND" in sm | st | ss | cst) ;; *) echo "kind $KIND" >&2; exit 1 ;; esac
case "$RECV" in go | py) ;; *) echo "recv $RECV" >&2; exit 1 ;; esac
LWI="${PHASE}-${RECV}-${KIND}-${RUN_ID}-${N}"
W="$D/$PHASE/$LWI"
mkdir -p "$W"
since=$(tsn)
TASK="no-such-task-$LWI"
echo "$since send $LWI phase=$PHASE kind=$KIND recv=$RECV" > "$W/steps.txt"

if [ "$KIND" = cst ]; then
	case "$RECV" in go) HOSTH=(-H 'Host: worker.lab.internal') ;; py) HOSTH=() ;; esac
	TRACE_ID=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8); RPC_ID=$(uuidgen | tr 'A-Z' 'a-z')
	jq -cjn --arg t "$TASK" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SubscribeToTask",params:{id:$t},id:$id}' > "$W/request.json"
	s=$(tsn)
	out=$(kubectl -n "$NS" exec -i "$POD" -- curl -sS -i -v --retry 0 --max-time 20 -X POST ${HOSTH[@]+"${HOSTH[@]}"} \
		-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
		-H "traceparent: 00-${TRACE_ID}-${SPAN}-01" -w '\n__STATUS__%{http_code}' --data-binary @- "$INGRESS/" < "$W/request.json" 2> "$W/curl-stderr.txt")
	rc=$?
	e=$(tsn)
	code=$(printf '%s\n' "$out" | sed -n 's/^__STATUS__//p' | tail -1)
	printf '%s\n' "$out" | sed '/^__STATUS__/d' > "$W/response.txt"
	grep '^> ' "$W/curl-stderr.txt" > "$W/request-headers-as-sent.txt" || true
	jq -cn --arg ts "$s" --arg te "$e" --arg lwi "$LWI" --arg phase "$PHASE" --arg recv "$RECV" --arg url "$INGRESS/" \
		--arg code "$code" --argjson rc "$rc" --arg trace "$TRACE_ID" --arg id "$RPC_ID" --arg task "$TASK" \
		--arg head "$(head -c 300 "$W/response.txt" | tr '\r\n' '  ')" \
		'{ledger:"client",client:"curl",ts:$ts,ts_end:$te,logical_work_item_id:$lwi,phase:$phase,receiver:$recv,method:"SubscribeToTask",
		  url:$url,attempt:1,http_status:$code,exit_code:$rc,trace_id:$trace,id:$id,taskId_asked:$task,response_head:$head}' > "$W/client.jsonl"
	echo "$(tsn) curl http=$code exit=$rc" >> "$W/steps.txt"
	outcome="http=$code exit=$rc"
else
	IMAGE="${IMAGE:?IMAGE (sends.sh image) is required}"
	case "$RECV" in go) target=$INGRESS dial=target host=worker.lab.internal ;; py) target=$ORCH_URL dial= host= ;; esac
	case "$KIND" in sm) mode= task= ;; st) mode=subscribe task=$TASK ;; ss) mode=stream task= ;; esac
	name="loadgen-$LWI"
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${LWI}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" \
		"$TEMPLATE" > "$W/job.yaml"
	if grep -q '\${' "$W/job.yaml" || ! grep -q "image: ${IMAGE}\$" "$W/job.yaml"; then
		echo "rendered Job has a placeholder left or not the resolved image; not applied" | tee -a "$W/steps.txt"; exit 1
	fi
	echo "$(tsn) apply $name MODE=${mode:-<empty>} TASK_ID=${task:-<empty>} TARGET_URL=$target CLIENT_DIAL=${dial:-<empty>} CLIENT_HOST=${host:-<empty>}" >> "$W/steps.txt"
	kubectl apply -f "$W/job.yaml" > "$W/apply.log" 2>&1 || echo "$(tsn) apply rc=$?" >> "$W/steps.txt"
	waited=0 st=""
	while [ "$waited" -lt "$JOB_LIMIT_S" ]; do
		st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1)
		[ -n "$st" ] && break
		sleep 1; waited=$((waited + 1))
	done
	echo "$(tsn) Job ${st:-timeout}" >> "$W/steps.txt"
	echo "$name $(kubectl -n "$NS" get job "$name" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pod-ip=$(kubectl -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')" > "$W/job.txt"
	outcome="job=${st:-timeout}"
fi

sleep 2
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/ingress-access.txt" || true
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
lr=0
make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || lr=$?
echo "$(tsn) make ledgers exit=$lr" >> "$W/steps.txt"
st_ing=$(awk -F'http.status=' 'NF>1{split($2,a," "); printf "%s ", a[1]}' "$W/ingress-access.txt")
echo "$(ts) $PHASE $RECV $KIND $LWI $outcome ledgers-exit=$lr ingress-ledger=$(wc -l < "$W/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$W/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$W/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$W/client.jsonl" 2>/dev/null | tr -d ' ') ingress-proxy-status=[${st_ing% }]" | tee -a "$D/phases.txt"
