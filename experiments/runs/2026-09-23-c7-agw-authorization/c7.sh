#!/usr/bin/env bash
# Experiment C, step C-7: the driver, kept in the run directory. Part 1's sends are C-6's sends.sh, run from C-6's
# run directory with RUNREL set to this one; this script applies and removes the overlays, reads every layer, and
# sends part 2's identity probes.
#
#   c7.sh apply <overlay> | remove <overlay>     kubectl apply -k / delete -k overlay-c7-header or overlay-c7-identity
#   c7.sh read <label> <since>                   readings, each through rec, into readings-<label>.txt
#   c7.sh pod-up | pod-down                      the curl pod in lab
#   c7.sh probe <path> <n>                       ONE SendMessage carrying x-c7-probe: identity, on one caller path:
#       ingress-go  a curl pod in lab -> the ingress Service, Host worker.lab.internal -> route lab/worker-ingress
#       ingress-py  a curl pod in lab -> the ingress Service, its own host              -> route lab/orchestrator-ingress
#       agw-go      a curl pod in lab -> the worker Service       -> agw-central, route lab/worker
#       agw-py      a curl pod in lab -> the orchestrator Service -> agw-central, route lab/orchestrator
#       pf-go       this host -> kubectl port-forward -> the ingress, Host worker.lab.internal -> lab/worker-ingress
#                   (the out-of-cluster path the lab's replay harness and matrix use)
# One request per call, one curl, --retry 0, --max-time 20, never re-sent. Every request carries A2A-Version: 1.0,
# X-Logical-Work-Item-Id and a traceparent whose trace id is recorded; the ledgers are collected at once.
# No retry logic anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c5/tools/istioctl-1.31.0:$PATH"
export PATH
RUNREL="${RUNREL:?RUNREL, the run directory name, is required}"
D="experiments/runs/$RUNREL"
NS=lab
POD=c7-curl
IMG=curlimages/curl:8.22.0
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
PF_PORT=18087
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
rec() {
	local f="$1"; shift
	{ printf '\n# read %s\n$ %s\n' "$(ts)" "$*"; bash -c "$*" 2>&1; printf '# exit %s\n' "$?"; } >> "$f"
}
dump() { # dump <ns> <deploy> <out> <port>
	kubectl -n "$1" port-forward "deploy/$2" "$4:15000" >/dev/null 2>&1 &
	local pf=$!
	for _ in $(seq 1 40); do nc -z 127.0.0.1 "$4" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
	curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$4/config_dump" -o "$3"
	kill "$pf" 2>/dev/null || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
apply | remove)
	ov="${1:?overlay}"
	case "$ov" in overlay-c7-header | overlay-c7-identity) ;; *) echo "overlay $ov" >&2; exit 1 ;; esac
	verb=apply; [ "$cmd" = remove ] && verb=delete
	echo "$(ts) $verb -k $ov" | tee -a "$D/phases.txt"
	rec "$D/$cmd-$ov.txt" "kubectl $verb -k $D/$ov"
	echo "$(ts) $verb done" | tee -a "$D/phases.txt"
	;;
read)
	label="${1:?label}"; since="${2:?since}"
	f="$D/readings-$label.txt"
	rec "$f" "kubectl get agentgatewaypolicy -A -o yaml"
	rec "$f" "kubectl get agentgatewaypolicy -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) authorization=\\(.spec.traffic.authorization != null) ancestors=\\([.status.ancestors[]? | .conditions[]? | \"\\(.type)=\\(.status)/\\(.reason)\"] | join(\",\"))\"'"
	rec "$f" "kubectl get authorizationpolicy -A --no-headers | wc -l"
	rec "$f" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	rec "$f" "kubectl -n agentgateway-system logs deploy/agentgateway --since-time=$since"
	rec "$f" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$since | grep -v 'request gateway='"
	rec "$f" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$since | grep -v 'request gateway='"
	dump agentgateway-ingress agentgateway-ingress "$D/config-dump-ingress-$label.json" 15997
	dump agentgateway-waypoint agw-central "$D/config-dump-agw-central-$label.json" 15996
	for p in ingress agw-central; do
		rec "$f" "jq -r '(.policies // []) | length as \$n | \"$p policies: \\(\$n)\", (.[] | \"  key=\\(.key) name=\\(.name|tostring) target=\\(.target|tostring|.[0:200]) kinds=\\(.policy|tostring|.[0:240])\")' $D/config-dump-$p-$label.json"
		rec "$f" "wc -c < $D/config-dump-$p-$label.json; shasum -a 256 $D/config-dump-$p-$label.json"
	done
	echo "$(ts) read $label -> $f" | tee -a "$D/phases.txt"
	;;
pod-up)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run "$POD" --image="$IMG" --restart=Never --command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
	echo "$(ts) pod-up $POD ip=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')" | tee -a "$D/phases.txt"
	;;
pod-down)
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
	echo "$(ts) pod-down $POD" | tee -a "$D/phases.txt"
	;;
probe)
	P="${1:?path}" N="${2:?n}"
	HOSTH=()
	case "$P" in
	ingress-go) BASE=$INGRESS; HOSTH=(-H 'Host: worker.lab.internal') ;;
	ingress-py) BASE=$INGRESS ;;
	agw-go) BASE=http://worker.lab.svc.cluster.local:8080 ;;
	agw-py) BASE=http://orchestrator.lab.svc.cluster.local:8080 ;;
	pf-go) BASE=http://127.0.0.1:$PF_PORT; HOSTH=(-H 'Host: worker.lab.internal') ;;
	*) echo "path $P" >&2; exit 1 ;;
	esac
	LWI="c7-id-${P}-${RUN_ID:?RUN_ID}-${N}"
	W="$D/identity/$LWI"
	mkdir -p "$W"
	TRACE_ID=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8)
	RPC_ID=$(uuidgen | tr 'A-Z' 'a-z'); MSG_ID=$(uuidgen | tr 'A-Z' 'a-z')
	jq -cjn --arg lwi "$LWI" --arg mid "$MSG_ID" --arg id "$RPC_ID" \
		'{jsonrpc:"2.0",method:"SendMessage",params:{message:{messageId:$mid,metadata:{logical_work_item_id:$lwi},parts:[{text:("lwi:"+$lwi+" hello")}],role:"ROLE_USER"}},id:$id}' > "$W/request.json"
	ARGS=(-sS -i -v --retry 0 --max-time 20 -X POST ${HOSTH[@]+"${HOSTH[@]}"} -H 'Content-Type: application/json' -H 'A2A-Version: 1.0'
		-H "X-Logical-Work-Item-Id: $LWI" -H "traceparent: 00-${TRACE_ID}-${SPAN}-01" -H 'x-c7-probe: identity'
		-w '\n__STATUS__%{http_code}' --data-binary @-)
	pf=""
	since=$(tsn)
	if [ "$P" = pf-go ]; then
		if lsof -nP -iTCP:"$PF_PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "something listens on $PF_PORT" >&2; exit 1; fi
		kubectl -n agentgateway-ingress port-forward svc/agentgateway-ingress "$PF_PORT:80" >/dev/null 2>&1 &
		pf=$!
		for _ in $(seq 1 200); do lsof -nP -iTCP:"$PF_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; done
		s=$(tsn)
		out=$(curl "${ARGS[@]}" "$BASE/" < "$W/request.json" 2> "$W/curl-stderr.txt"); rc=$?
		kill "$pf" 2>/dev/null || true
	else
		s=$(tsn)
		out=$(kubectl -n "$NS" exec -i "$POD" -- curl "${ARGS[@]}" "$BASE/" < "$W/request.json" 2> "$W/curl-stderr.txt"); rc=$?
	fi
	e=$(tsn)
	code=$(printf '%s\n' "$out" | sed -n 's/^__STATUS__//p' | tail -1)
	printf '%s\n' "$out" | sed '/^__STATUS__/d' > "$W/response.txt"
	grep '^> ' "$W/curl-stderr.txt" > "$W/request-headers-as-sent.txt" || true
	jq -cn --arg ts "$s" --arg te "$e" --arg lwi "$LWI" --arg path "$P" --arg url "$BASE/" --arg code "$code" --argjson rc "$rc" \
		--arg trace "$TRACE_ID" --arg mid "$MSG_ID" --arg id "$RPC_ID" --arg head "$(head -c 300 "$W/response.txt" | tr '\r\n' '  ')" \
		'{ledger:"client",client:"curl",ts:$ts,ts_end:$te,logical_work_item_id:$lwi,path:$path,method:"SendMessage",url:$url,attempt:1,
		  http_status:$code,exit_code:$rc,trace_id:$trace,messageId:$mid,id:$id,probe_header:"x-c7-probe: identity",response_head:$head}' > "$W/client.jsonl"
	sleep 2
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/ingress-access.txt" || true
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
	lr=0
	make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || lr=$?
	echo "$(ts) probe $P $LWI http=$code exit=$rc ledgers-exit=$lr ingress=$(wc -l < "$W/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$W/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$W/invocation.jsonl" 2>/dev/null | tr -d ' ') src.identity=[$(grep -h "$TRACE_ID" "$W/ingress-access.txt" "$W/agw-central-access.txt" | grep -o 'src.identity=[^ 	]*' | sort -u | tr '\n' ' ')]" | tee -a "$D/phases.txt"
	;;
*)
	echo "usage: c7.sh apply|remove <overlay> | read <label> <since> | pod-up | pod-down | probe <path> <n>" >&2; exit 1 ;;
esac
