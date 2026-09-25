#!/usr/bin/env bash
# COPY for the currency pass of 2026-09-25 (the controller's ruling: a driver whose outputs land in its own dated
# run directory runs from a copy in this pass's run directory, only its output path changed). Original:
# experiments/runs/2026-09-21-c3-c4-ztunnel/send-one.sh. One change: R, below, is this copy's directory.
# C-3 / C-4 driver, kept in the run directory: ONE work item on ONE caller path to the
# worker, as the load client shapes it -- one agent-card GET, then one SendMessage POST.
#
#   send-one.sh <phase> <via> <work-item>
#     via=service  a curl pod in `lab` -> the worker Service -> agw-central -> worker
#     via=direct   a curl pod in `lab` -> the worker pod's own address, no proxy
#     via=ingress  this host -> kubectl port-forward -> agentgateway-ingress
#                  (Host: worker.lab.internal, its step-2c route) -> worker
#
# No retry logic. Each request is one curl with --retry 0; a refusal is recorded as the
# caller saw it (HTTP status, or curl's exit code for a transport error) and not repeated.
# Every request carries `A2A-Version: 1.0`, the work-item header the load client sends,
# and a `traceparent` whose trace id is recorded, so each proxy's access line and span
# can be matched to this work item even when the worker never sees the request.
set -euo pipefail

PHASE="$1" VIA="$2" LWI="$3"
cd "$(git rev-parse --show-toplevel)"
R="experiments/runs/2026-09-25-currency-rebuild/c3c4"
D="${R}/${LWI}"
NS="lab"
POD="c34-curl"
IMG="curlimages/curl:8.22.0"
PF_PORT=18080
CARD="/.well-known/agent-card.json"
mkdir -p "$D"

case "$VIA" in service | direct | ingress) ;; *) echo "via=${VIA} is not service, direct or ingress" >&2 && exit 1 ;; esac

TRACE_ID=$(openssl rand -hex 16)
MSG_ID=$(uuidgen | tr 'A-Z' 'a-z')
RPC_ID=$(uuidgen | tr 'A-Z' 'a-z')
jq -cjn --arg lwi "$LWI" --arg mid "$MSG_ID" --arg id "$RPC_ID" \
	'{jsonrpc:"2.0",method:"SendMessage",params:{message:{messageId:$mid,metadata:{logical_work_item_id:$lwi},parts:[{text:("lwi:"+$lwi+" hello")}],role:"ROLE_USER"}},id:$id}' \
	>"${D}/request.json"

pf=""
cleanup() {
	if [ -n "$pf" ]; then kill "$pf" >/dev/null 2>&1 || true; fi
	if [ "$VIA" != "ingress" ]; then kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

if [ "$VIA" = "ingress" ]; then
	if lsof -nP -iTCP:"$PF_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "something already listens on 127.0.0.1:${PF_PORT}; refusing to send to a listener this script did not start" >&2
		exit 1
	fi
	kubectl -n agentgateway-ingress port-forward svc/agentgateway-ingress "${PF_PORT}:80" >/dev/null 2>&1 &
	pf=$!
	# Wait on the listener, not on a request: a probe request would be traffic.
	up=0
	for _ in $(seq 1 200); do
		if lsof -nP -iTCP:"$PF_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1 && break; fi
	done
	[ "$up" = 1 ] || { echo "port-forward to svc/agentgateway-ingress did not come up" >&2 && exit 1; }
	BASE="http://127.0.0.1:${PF_PORT}"
	HOST_HDR="worker.lab.internal"
else
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run "$POD" --image="$IMG" --restart=Never --command -- sleep 900 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=60s >/dev/null
	if [ "$VIA" = "service" ]; then
		BASE="http://worker.lab.svc.cluster.local:8080"
		HOST_HDR="worker.lab.svc.cluster.local:8080"
	else
		WORKER_IP=$(kubectl -n "$NS" get pod -l app=worker -o jsonpath='{.items[0].status.podIP}')
		BASE="http://${WORKER_IP}:8080"
		HOST_HDR="${WORKER_IP}:8080"
	fi
fi

# one request, one curl, --retry 0. $1 = op name, $2 = HTTP method, $3 = path, $4 = span id
one() {
	local op="$1" method="$2" path="$3" span="$4" out rc code resp
	local args=(-sS --retry 0 --max-time 30 -X "$method" -w '\n%{http_code}'
		-H "Host: ${HOST_HDR}"
		-H 'A2A-Version: 1.0'
		-H "X-Logical-Work-Item-Id: ${LWI}"
		-H "traceparent: 00-${TRACE_ID}-${span}-01")
	if [ "$method" = "POST" ]; then args+=(-H 'Content-Type: application/json' --data-binary @-); fi
	local ts
	ts=$(date -u +%FT%TZ)
	set +e
	if [ "$VIA" = "ingress" ]; then
		if [ "$method" = "POST" ]; then out=$(curl "${args[@]}" "${BASE}${path}" <"${D}/request.json" 2>"${D}/stderr-${op}.txt"); else out=$(curl "${args[@]}" "${BASE}${path}" 2>"${D}/stderr-${op}.txt" </dev/null); fi
	else
		if [ "$method" = "POST" ]; then out=$(kubectl -n "$NS" exec -i "$POD" -- curl "${args[@]}" "${BASE}${path}" <"${D}/request.json" 2>"${D}/stderr-${op}.txt"); else out=$(kubectl -n "$NS" exec "$POD" -- curl "${args[@]}" "${BASE}${path}" 2>"${D}/stderr-${op}.txt" </dev/null); fi
	fi
	rc=$?
	set -e
	code=$(printf '%s\n' "$out" | tail -n 1)
	resp=$(printf '%s\n' "$out" | sed '$d')
	printf '%s' "$resp" >"${D}/response-${op}.txt"
	printf '%s\n' "$(jq -cn --arg ts "$ts" --arg lwi "$LWI" --arg phase "$PHASE" --arg via "$VIA" --arg op "$op" \
		--arg method "$method" --arg url "${BASE}${path}" --arg host "$HOST_HDR" --arg code "$code" --argjson rc "$rc" \
		--arg trace "$TRACE_ID" --arg span "$span" --arg mid "$MSG_ID" --arg id "$RPC_ID" \
		--arg sha "$(shasum -a 256 "${D}/request.json" | cut -d' ' -f1)" --argjson len "$(wc -c <"${D}/request.json" | tr -d ' ')" \
		--arg head "${resp:0:240}" --arg err "$(tr '\n' ' ' <"${D}/stderr-${op}.txt")" \
		'{ledger:"client",ts:$ts,logical_work_item_id:$lwi,phase:$phase,via:$via,op:$op,http_method:$method,url:$url,host:$host,
		  attempt:1,http_status:$code,exit_code:$rc,trace_id:$trace,span_id:$span,messageId:(if $op=="SendMessage" then $mid else "" end),
		  id:(if $op=="SendMessage" then $id else "" end),body_sha256:(if $op=="SendMessage" then $sha else "" end),
		  body_len:(if $op=="SendMessage" then $len else 0 end),response_head:$head,stderr:$err}')" >>"${D}/client.jsonl"
	echo "${PHASE} ${VIA} ${LWI} ${op}: ${method} ${BASE}${path} -> status=${code} exit=${rc} trace=${TRACE_ID}"
}

: >"${D}/client.jsonl"
one GetAgentCard GET "$CARD" "$(openssl rand -hex 8)"
one SendMessage POST "/" "$(openssl rand -hex 8)"

# Collect the three ledgers by the committed target. A unary SendMessage is answered
# after its dispatch and its model call, so their lines exist when curl returns.
make --no-print-directory ledgers "LWI=${LWI}" "OUT=${D}" >/dev/null
for f in ingress execution invocation; do printf '%s=%s ' "$f" "$(grep -c '' "${D}/${f}.jsonl" || true)"; done
echo
