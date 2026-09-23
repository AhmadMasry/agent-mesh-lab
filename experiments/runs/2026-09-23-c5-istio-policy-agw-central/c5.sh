#!/usr/bin/env bash
# Experiment C, step C-5: the driver, kept in the run directory. Istio's AuthorizationPolicy with targetRefs naming
# agw-central (overlay-c5/), and ONE probe request per call, sent through agw-central to a receiver's Service.
#
#   c5.sh pod-up | pod-down                 the curl pod in lab (curlimages/curl:8.22.0, as the lab's scripts use)
#   c5.sh probe <phase> <recv> <op> <hdr> <n>
#       recv  go = the worker Service, py = the orchestrator Service; both are bound to agw-central
#             (istio.io/use-waypoint), so the request crosses agw-central's route lab/worker or lab/orchestrator
#       op    SendMessage | SubscribeToTask (a taskId that names no task: a refusal happens before dispatch, so the
#             probe needs no live task; unrefused, the receiver answers it)
#       hdr   yes = the request carries x-c5-probe: deny, the one header the policy names; no = it does not
#   c5.sh read <label>                      readings of every layer, each through rec, into readings-<label>.txt
#   c5.sh apply | remove                    kubectl apply -k / delete -k overlay-c5
#
# One request per call, one curl, --retry 0, --max-time 20; a refusal is recorded as the caller saw it and never
# re-sent. Every request carries A2A-Version: 1.0, X-Logical-Work-Item-Id and a traceparent whose trace id is
# recorded, so agw-central's access line and span can be found even when no receiver sees the request. The three
# ledgers are collected at once by the committed make ledgers; its exit status is kept (it exits 1 when no ledger
# holds the work item, which is what a refused request leaves).
# No retry logic anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c5/tools/istioctl-1.31.0:$PATH"
export PATH
RUNREL="${RUNREL:?RUNREL, the run directory name, is required}"
D="experiments/runs/$RUNREL"
NS=lab
POD=c5-curl
IMG=curlimages/curl:8.22.0
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
rec() { # rec <file> <command...>: stamp, command, output, exit
	local f="$1"; shift
	{ printf '\n# read %s\n$ %s\n' "$(ts)" "$*"; bash -c "$*" 2>&1; printf '# exit %s\n' "$?"; } >> "$f"
}

cmd="${1:-}"; shift || true
case "$cmd" in
pod-up)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run "$POD" --image="$IMG" --restart=Never --command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s
	echo "$(ts) pod-up $POD ip=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')" | tee -a "$D/phases.txt"
	;;
pod-down)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true
	echo "$(ts) pod-down $POD" | tee -a "$D/phases.txt"
	;;
apply)
	echo "$(ts) apply -k overlay-c5" | tee -a "$D/phases.txt"
	rec "$D/apply.txt" "kubectl apply -k $D/overlay-c5"
	echo "$(ts) applied" | tee -a "$D/phases.txt"
	;;
remove)
	echo "$(ts) delete -k overlay-c5" | tee -a "$D/phases.txt"
	rec "$D/removal.txt" "kubectl delete -k $D/overlay-c5"
	echo "$(ts) removed" | tee -a "$D/phases.txt"
	;;
read)
	label="${1:?label}"; since="${2:?since (UTC stamp)}"
	f="$D/readings-$label.txt"
	rec "$f" "kubectl get authorizationpolicy -A -o yaml"
	rec "$f" "kubectl get authorizationpolicy -A --no-headers | wc -l"
	rec "$f" "istioctl ztunnel-config policy --node agent-mesh-lab-worker -o json"
	rec "$f" "istioctl ztunnel-config policy --node agent-mesh-lab-control-plane -o json"
	rec "$f" "kubectl -n istio-system logs deploy/istiod --since-time=$since"
	rec "$f" "kubectl -n agentgateway-system logs deploy/agentgateway --since-time=$since"
	rec "$f" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$since | grep -v 'request gateway='"
	rec "$f" "kubectl get agentgatewaypolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TARGET:.spec.targetRefs[*].name,KEYS:.spec"
	rec "$f" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	# agw-central's own configuration, read from its admin port: every policy it holds, and every occurrence of
	# the probe header's name or the policy's name anywhere in the dump.
	PORT=15998
	kubectl -n agentgateway-waypoint port-forward deploy/agw-central "$PORT:15000" >/dev/null 2>&1 &
	pf=$!
	for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
	curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$PORT/config_dump" -o "$D/config-dump-agw-central-$label.json"
	kill "$pf" 2>/dev/null || true
	rec "$f" "jq -r '(.policies // []) | length as \$n | \"policies: \\(\$n)\", (.[] | \"  key=\\(.key) name=\\(.name|tostring) target=\\(.target|tostring|.[0:160]) kinds=\\(.policy|keys|join(\",\"))\")' $D/config-dump-agw-central-$label.json"
	rec "$f" "grep -o -i 'x-c5-probe\\|c5-deny-probe-header\\|AuthorizationPolicy\\|authorization' $D/config-dump-agw-central-$label.json | sort | uniq -c"
	rec "$f" "wc -c < $D/config-dump-agw-central-$label.json; shasum -a 256 $D/config-dump-agw-central-$label.json"
	echo "$(ts) read $label -> $f" | tee -a "$D/phases.txt"
	;;
probe)
	PHASE="${1:?phase}" RECV="${2:?recv}" OP="${3:?op}" HDR="${4:?hdr}" N="${5:?n}"
	case "$RECV" in go) BASE=http://worker.lab.svc.cluster.local:8080 ;; py) BASE=http://orchestrator.lab.svc.cluster.local:8080 ;; *) echo "recv $RECV" >&2; exit 1 ;; esac
	case "$OP" in SendMessage) o=sm ;; SubscribeToTask) o=st ;; *) echo "op $OP" >&2; exit 1 ;; esac
	case "$HDR" in yes | no) ;; *) echo "hdr $HDR" >&2; exit 1 ;; esac
	LWI="c5-${PHASE}-${RECV}-${o}-h${HDR}-${RUN_ID:?RUN_ID}-${N}"
	W="$D/$PHASE/$LWI"
	mkdir -p "$W"
	TRACE_ID=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8)
	RPC_ID=$(uuidgen | tr 'A-Z' 'a-z'); MSG_ID=$(uuidgen | tr 'A-Z' 'a-z'); TASK="c5-no-such-task-$LWI"
	if [ "$OP" = SendMessage ]; then
		jq -cjn --arg lwi "$LWI" --arg mid "$MSG_ID" --arg id "$RPC_ID" \
			'{jsonrpc:"2.0",method:"SendMessage",params:{message:{messageId:$mid,metadata:{logical_work_item_id:$lwi},parts:[{text:("lwi:"+$lwi+" hello")}],role:"ROLE_USER"}},id:$id}' > "$W/request.json"
		ACCEPT=()
	else
		jq -cjn --arg t "$TASK" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SubscribeToTask",params:{id:$t},id:$id}' > "$W/request.json"
		ACCEPT=(-H 'Accept: text/event-stream')
	fi
	PH=()
	[ "$HDR" = yes ] && PH=(-H 'x-c5-probe: deny')
	s=$(tsn)
	out=$(kubectl -n "$NS" exec -i "$POD" -- curl -sS -i -v --retry 0 --max-time 20 -X POST \
		-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
		-H "traceparent: 00-${TRACE_ID}-${SPAN}-01" ${ACCEPT[@]+"${ACCEPT[@]}"} ${PH[@]+"${PH[@]}"} \
		-w '\n__STATUS__%{http_code}' --data-binary @- "$BASE/" < "$W/request.json" 2> "$W/curl-stderr.txt")
	rc=$?
	e=$(tsn)
	code=$(printf '%s\n' "$out" | sed -n 's/^__STATUS__//p' | tail -1)
	printf '%s\n' "$out" | sed '/^__STATUS__/d' > "$W/response.txt"
	grep '^> ' "$W/curl-stderr.txt" > "$W/request-headers-as-sent.txt" || true
	jq -cn --arg ts "$s" --arg te "$e" --arg lwi "$LWI" --arg phase "$PHASE" --arg recv "$RECV" --arg op "$OP" --arg hdr "$HDR" \
		--arg url "$BASE/" --arg code "$code" --argjson rc "$rc" --arg trace "$TRACE_ID" --arg span "$SPAN" \
		--arg mid "$([ "$OP" = SendMessage ] && echo "$MSG_ID")" --arg id "$RPC_ID" --arg task "$([ "$OP" = SubscribeToTask ] && echo "$TASK")" \
		--arg sha "$(shasum -a 256 "$W/request.json" | cut -d' ' -f1)" \
		--arg head "$(head -c 300 "$W/response.txt" | tr '\r\n' '  ')" \
		'{ledger:"client",client:"curl",ts:$ts,ts_end:$te,logical_work_item_id:$lwi,phase:$phase,receiver:$recv,op:$op,probe_header:$hdr,
		  url:$url,attempt:1,http_status:$code,exit_code:$rc,trace_id:$trace,span_id:$span,messageId:$mid,id:$id,taskId_asked:$task,
		  body_sha256:$sha,response_head:$head}' > "$W/client.jsonl"
	lr=0
	make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || lr=$?
	echo "$(ts) probe $PHASE $RECV $OP hdr=$HDR -> http=$code exit=$rc ledgers-exit=$lr ingress=$(wc -l < "$W/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$W/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$W/invocation.jsonl" 2>/dev/null | tr -d ' ') trace=$TRACE_ID lwi=$LWI" | tee -a "$D/phases.txt"
	;;
*)
	echo "usage: c5.sh pod-up|pod-down|apply|remove|read <label> <since>|probe <phase> <recv> <op> <hdr> <n>" >&2; exit 1 ;;
esac
