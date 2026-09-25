#!/usr/bin/env bash
# Follow-on D-3b: the one driver of the rows. Adapted from experiments/runs/2026-09-24-d3-extauthz/d3.sh, changed in:
# this header, the scratch paths (${TMPDIR}/d3b/...), the D-3b shapes added to the curl kinds (below, after D-3's four),
# a curl request's method, body and HTTP version made per kind, and the per-send summary line carrying the fixture's
# decoded_path and jsonrpc_reach. D-3's kinds, readings, dumps, settings, scale and hop are that script's, unchanged.
# D-3's header follows.
#
# Follow-on D-3: the one driver of the rows. Adapted from experiments/runs/2026-09-24-d2-bindings/sends.sh (the load
# client's sends on the three bindings, D-2's paths and Host settings) and experiments/runs/2026-09-23-c8-body-rule/c8.sh
# (the curl probes, the readings and the dumps), changed in: one script for both, the fixture's decision ledger
# collected with the three, the fixture's setting and scale, and the padded SendMessage control.
#
#   d3.sh image | pod-up | pod-down               the load client image (ko build, once); the curl pod d3-curl in lab
#   d3.sh send <phase> <binding> <kind> <recv> <n>
#       the load client (one Job):  binding jsonrpc|rest|grpc; kind sm (SendMessage) | st (SubscribeToTask naming no
#                                   task) | ss (SendStreamingMessage, jsonrpc only)
#       curl (one POST to the ingress, JSON-RPC, path /, the same Host as the load client's go path):
#            cst    SubscribeToTask with curl's own headers
#            csm    a small SendMessage (the control of the JSON shape the padded one uses)
#            pad    SubscribeToTask padded to PAD_LEN bytes by one more top-level member, x_pad (C-8's Row 3)
#            padt   SubscribeToTask padded inside params.tenant (C-8's tenant pad)
#            padsm  SendMessage padded inside params.tenant: SendMessageRequest defines tenant (a2a.proto at 3303592,
#                   l.648-651, "Optional. Opaque routing identifier."), the controller's control of 2026-09-24
#            batch  a JSON-RPC batch holding one SubscribeToTask (C-8's Row 4)
#            dup    one object with method written twice, SendMessage first and SubscribeToTask second (C-8's Row 4)
#       the review round's shapes (review-d3 I1; added after the first record), each ONE curl, SubscribeToTask:
#            xp     cst's JSON-RPC body POSTed to /x instead of /
#            xa     cst's JSON-RPC body POSTed to /a2a/v1
#            xg     cst's JSON-RPC body POSTed to / with Content-Type: application/grpc
#            xr     POST /tasks/<no task>%3Asubscribe with no body (REST, the colon percent-encoded)
#       D-3b's shapes (the routing reading of D-3b, docs of the run directory), each ONE curl, SubscribeToTask; <t> is the
#       task named by no task, "cst's body" is cst's JSON-RPC body:
#            xn     cst's body POSTed to /%0A (Python's "$" matches before a final newline; Go's catch-all)
#            xt     cst's body POSTed to /message:send/ (no exact match at Go: the catch-all)
#            xm     cst's body POSTed to /lf.a2a.v1.A2AService/SendMessage with Content-Type application/grpc (port 8080)
#            xc     POST /tasks/<t>:subscribe, no body, Content-Type application/grpc
#            xh     HEAD /tasks/<t>:subscribe
#            xl     POST /tasks/<t>:%73ubscribe, no body (an unreserved letter percent-encoded)
#            xs     POST /tasks%2F<t>:subscribe, no body (the separating slash encoded)
#            xe     POST /tasks/<t>:subscribe%0A, no body
#            xb     cst's body after a UTF-8 byte order mark, POSTed to /
#            x16    cst's body in UTF-16LE (no byte order mark), POSTed to /
#            xu     cst's body with its member name written METHOD, POSTed to /
#            xq     cst's body with its method written Subscribe\u0054oTask (a JSON escape), POSTed to /
#            xi     POST /tasks/a%2F<t>:subscribe, no body (a slash encoded inside the id)
#            rg     GET /tasks/<t>:subscribe
#            xk     cst's body POSTed to /?x=1
#            gp gs gq  gRPC over HTTP/2 with prior knowledge, Host worker-grpc.lab.internal, a SubscribeToTaskRequest{id: <t>}
#                   frame, Content-Type application/grpc, TE trailers, to /lf.a2a.v1.A2AService/Subscribe%54oTask (gp),
#                   /lf.a2a.v1.A2AService%2FSubscribeToTask (gs), /lf.a2a.v1.A2AService/SubscribeToTask?x=1 (gq); go only
#   d3.sh read <label>                             readings and both proxies' dumps
#   d3.sh apply | remove                           kubectl apply -k / delete -k overlay-d3-extauthz
#   d3.sh setting <deny|allow>                     kubectl set env deploy/extauthz EXTAUTHZ_UNDECIDABLE, waited on
#   d3.sh scale <0|1>                              kubectl scale deploy/extauthz, waited on
#   d3.sh hop <label>                              the per-hop connection security of the ingress-to-extauthz leg
#
# Every request carries A2A-Version 1.0 (the load client's own header or gRPC metadata; curl sets it) and
# X-Logical-Work-Item-Id. One send per Job (backoffLimit 0) or curl (--retry 0); nothing is re-sent; one send runs at a
# time. After each send: the Job's end or curl's status, the three ledgers and the fixture's by make ledgers, the
# fixture's lines since the send began, and both proxies' access lines since the send began.
# No retry logic anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/d3b/tools/istioctl-1.31.0:$PATH"
export PATH
NS=lab
CLUSTER_NAME=agent-mesh-lab
POD=d3-curl
CURL_IMAGE=curlimages/curl:8.22.0
TEMPLATE=deploy/base/loadgen-a2-job.yaml
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
JOB_LIMIT_S=90
PAD_LEN=2200000
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
RUNREL="${RUNREL:?RUNREL is required}"
D="experiments/runs/$RUNREL"
mkdir -p "$D"
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
	wait "$pf" 2>/dev/null || true
}
cnt() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else echo 0; fi; }
collect() { # collect <W> <LWI> <since> -- after every send
	local W="$1" LWI="$2" since="$3" lr=0
	sleep 2
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null > "$W/ingress-log-window.txt" || true
	grep 'request gateway=' "$W/ingress-log-window.txt" > "$W/ingress-access.txt" || true
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
	# Every decision line the fixture wrote since the send began, whatever work item it names (a batch or a request
	# whose identity the fixture could not read would otherwise be missed). Empty when no fixture pod exists.
	kubectl -n "$NS" logs deploy/extauthz --since-time="$since" 2>/dev/null | grep '^{' > "$W/extauthz-window.txt" || true
	make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || lr=$?
	echo "$(tsn) make ledgers exit=$lr" >> "$W/steps.txt"
	local st_ing dec
	st_ing=$(awk -F'http.status=' 'NF>1{split($2,a," "); printf "%s ", a[1]}' "$W/ingress-access.txt")
	dec=$(jq -r '"\(.decision)/\(.reason)/\(.undecidable_setting)/len=\(.body_len)/size=\(.size)/reach=\(.jsonrpc_reach)/decoded=\(.decoded_path|@json)"' "$W/extauthz-window.txt" 2>/dev/null | tr '\n' ' ')
	echo "ledgers-exit=$lr ingress-ledger=$(cnt "$W/ingress.jsonl") execution=$(cnt "$W/execution.jsonl") invocation=$(cnt "$W/invocation.jsonl") extauthz-lines=$(cnt "$W/extauthz-window.txt") extauthz=[${dec% }] ingress-proxy-status=[${st_ing% }]"
}

cmd="${1:-}"
case "$cmd" in
image)
	t0=$(tsn)
	IMG=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d3b/ko-build-loadgen.log")
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
apply | remove)
	verb=apply; [ "$cmd" = remove ] && verb=delete
	echo "$(ts) $verb -k overlay-d3-extauthz" | tee -a "$D/phases.txt"
	rec "$D/$cmd-overlay-d3-extauthz.txt" "kubectl $verb -k $D/overlay-d3-extauthz"
	echo "$(ts) $verb done" | tee -a "$D/phases.txt"
	exit 0
	;;
setting)
	v="${2:?deny|allow}"; case "$v" in deny | allow) ;; *) echo "setting $v" >&2; exit 1 ;; esac
	f="$D/setting-$v.txt"
	echo "$(ts) setting EXTAUTHZ_UNDECIDABLE=$v begin" | tee -a "$D/phases.txt"
	rec "$f" "kubectl -n $NS get pods -l app=extauthz -o wide --no-headers"
	rec "$f" "kubectl -n $NS set env deploy/extauthz EXTAUTHZ_UNDECIDABLE=$v"
	rec "$f" "kubectl -n $NS rollout status deploy/extauthz --timeout=120s"
	rec "$f" "kubectl -n $NS get deploy extauthz -o jsonpath='{.spec.template.spec.containers[0].env}{\"\\n\"}'"
	rec "$f" "kubectl -n $NS get pods -l app=extauthz -o wide --no-headers"
	rec "$f" "kubectl -n $NS logs deploy/extauthz | grep -v '^{'"
	echo "$(ts) setting EXTAUTHZ_UNDECIDABLE=$v done, pod $(kubectl -n $NS get pods -l app=extauthz --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')" | tee -a "$D/phases.txt"
	exit 0
	;;
scale)
	n="${2:?0|1}"
	f="$D/scale-$n.txt"
	echo "$(ts) scale extauthz to $n begin" | tee -a "$D/phases.txt"
	rec "$f" "kubectl -n $NS scale deploy/extauthz --replicas=$n"
	if [ "$n" = 0 ]; then
		rec "$f" "kubectl -n $NS wait --for=delete pod -l app=extauthz --timeout=120s"
	else
		rec "$f" "kubectl -n $NS rollout status deploy/extauthz --timeout=120s"
		rec "$f" "kubectl -n $NS wait --for=condition=Ready pod -l app=extauthz --timeout=120s"
	fi
	rec "$f" "kubectl -n $NS get deploy extauthz -o wide --no-headers"
	rec "$f" "kubectl -n $NS get pods -l app=extauthz -o wide --no-headers"
	rec "$f" "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=extauthz -o jsonpath='{range .items[*]}{.metadata.name}{\" endpoints=\"}{.endpoints}{\"\\n\"}{end}'"
	echo "$(ts) scale extauthz to $n done, pods $(kubectl -n $NS get pods -l app=extauthz --no-headers 2>/dev/null | wc -l | tr -d ' ')" | tee -a "$D/phases.txt"
	exit 0
	;;
hop)
	label="${2:?label}"
	f="$D/hop-$label.txt"
	ip=$(kubectl -n "$NS" get pod -l app=extauthz -o jsonpath='{.items[0].status.podIP}')
	rec "$f" "kubectl -n $NS get pods -l app=extauthz -o wide --no-headers"
	rec "$f" "kubectl -n agentgateway-ingress get pods -o wide --no-headers"
	rec "$f" "kubectl -n istio-system logs ds/ztunnel --since=15m --prefix | grep -F 'dst.addr=$ip:9000' | tail -40"
	rec "$f" "kubectl -n istio-system logs ds/ztunnel --since=15m | grep -F 'dst.addr=$ip:9000' | grep -o 'connection_security_policy=[a-z_]*\\|src.identity=\"[^\"]*\"\\|dst.identity=\"[^\"]*\"' | sort | uniq -c"
	rec "$f" "istioctl ztunnel-config workloads --node agent-mesh-lab-worker | grep -E 'extauthz|agentgateway-ingress|NAMESPACE'"
	# The reading the standard proof takes for every other leg: istio_tcp_connections_opened_total from Prometheus
	# (experiments/runs/2026-09-12-mtls-enforced/promq.sh security), after 35 s so ztunnel has been scraped; the series
	# whose destination is the fixture are the ingress-to-extauthz leg.
	sleep 35
	rec "$f" "experiments/runs/2026-09-12-mtls-enforced/promq.sh security > $D/hop-$label-raw.txt 2>&1; grep -c . $D/hop-$label-raw.txt"
	rec "$f" "grep '\"destination_app\": \"extauthz\"' $D/hop-$label-raw.txt | jq -r '[.connection_security_policy, .source_workload, .source_workload_namespace, .source_principal, .destination_workload, .destination_principal, .reporter, .value[1]? // .value] | @tsv' 2>/dev/null || grep extauthz $D/hop-$label-raw.txt"
	rec "$f" "kubectl get peerauthentication -A -o wide"
	echo "$(ts) hop $label -> $f" | tee -a "$D/phases.txt"
	exit 0
	;;
read)
	label="${2:?label}"
	f="$D/readings-$label.txt"
	since="$(date -u -v-3M +%FT%TZ)"
	rec "$f" "kubectl get agentgatewaypolicy -A -o yaml"
	rec "$f" "kubectl get agentgatewaypolicy -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) extAuth=\\(.spec.traffic.extAuth != null) authorization=\\(.spec.traffic.authorization != null) ancestors=\\([.status.ancestors[]? | .conditions[]? | \"\\(.type)=\\(.status)/\\(.reason)\"] | join(\",\"))\"'"
	rec "$f" "kubectl get authorizationpolicy -A --no-headers | wc -l"
	rec "$f" "kubectl get httproute,grpcroute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	rec "$f" "kubectl -n $NS get deploy extauthz -o jsonpath='{.spec.replicas} {.spec.template.spec.containers[0].env}{\"\\n\"}'"
	rec "$f" "kubectl -n $NS get pods -l 'app in (worker,orchestrator,mockllm,extauthz)' -o wide --no-headers"
	rec "$f" "kubectl -n $NS logs deploy/extauthz 2>/dev/null | grep -c '^{'"
	rec "$f" "kubectl -n agentgateway-system logs deploy/agentgateway --since-time=$since"
	rec "$f" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$since | grep -v 'request gateway='"
	rec "$f" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$since | grep -v 'request gateway='"
	dump agentgateway-ingress agentgateway-ingress "$D/config-dump-ingress-$label.json" 15997
	dump agentgateway-waypoint agw-central "$D/config-dump-agw-central-$label.json" 15996
	for p in ingress agw-central; do
		rec "$f" "jq -r '(.policies // []) | length as \$n | \"$p policies: \\(\$n)\", (.[] | \"  key=\\(.key) name=\\(.name|tostring) target=\\(.target|tostring|.[0:200]) kinds=\\(.policy|tostring|.[0:400])\")' $D/config-dump-$p-$label.json"
		rec "$f" "jq -r '[.. | objects | select(has(\"extAuthz\")) ] | \"$p objects carrying extAuthz: \\(length)\"' $D/config-dump-$p-$label.json"
		rec "$f" "wc -c < $D/config-dump-$p-$label.json; shasum -a 256 $D/config-dump-$p-$label.json"
	done
	echo "$(ts) read $label -> $f" | tee -a "$D/phases.txt"
	exit 0
	;;
send) ;;
*) echo "command $cmd" >&2; exit 1 ;;
esac

PHASE="${2:?phase}" BINDING="${3:?binding}" KIND="${4:?kind}" RECV="${5:?recv}" N="${6:?n}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
case "$BINDING" in jsonrpc) CB= ;; rest) CB=rest ;; grpc) CB=grpc ;; *) echo "binding $BINDING" >&2; exit 1 ;; esac
case "$KIND" in
sm | st) ;;
ss | cst | csm | pad | padt | padsm | batch | dup | xp | xa | xg | xr | xn | xt | xm | xc | xh | xl | xs | xe | xb | x16 | xu | xq | xi | rg | xk | gp | gs | gq) [ "$BINDING" = jsonrpc ] || { echo "$KIND is jsonrpc only" >&2; exit 1; } ;;
*) echo "kind $KIND" >&2; exit 1 ;;
esac
case "$RECV" in go | py) ;; *) echo "recv $RECV" >&2; exit 1 ;; esac
LWI="${PHASE}-${BINDING}-${RECV}-${KIND}-${RUN_ID}-${N}"
W="$D/$PHASE/$LWI"
mkdir -p "$W"
since=$(tsn)
TASK="no-such-task-$LWI"
echo "$since send $LWI phase=$PHASE binding=$BINDING kind=$KIND recv=$RECV" > "$W/steps.txt"

case "$KIND" in
cst | csm | pad | padt | padsm | batch | dup | xp | xa | xg | xr | xn | xt | xm | xc | xh | xl | xs | xe | xb | x16 | xu | xq | xi | rg | xk | gp | gs | gq)
	case "$RECV" in go) HOSTH=(-H 'Host: worker.lab.internal') ;; py) HOSTH=() ;; esac
	case "$KIND" in gp | gs | gq) [ "$RECV" = go ] || { echo "$KIND is go only" >&2; exit 1; }; HOSTH=(-H 'Host: worker-grpc.lab.internal') ;; esac
	TRACE_ID=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8); RPC_ID=$(uuidgen | tr 'A-Z' 'a-z'); MID=$(uuidgen | tr 'A-Z' 'a-z')
	B="${TMPDIR%/}/d3b/body-$LWI.json"
	msg=$(jq -cjn --arg mid "$MID" --arg lwi "$LWI" '{messageId:$mid,role:"ROLE_USER",parts:[{text:("d3 control " + $lwi)}],metadata:{logical_work_item_id:$lwi}}')
	case "$KIND" in
	cst | xp | xa | xg | xn | xt | xm | xk) jq -cjn --arg t "$TASK" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SubscribeToTask",params:{id:$t},id:$id}' > "$B" ;;
	xr | xc | xh | xl | xs | xe | xi | rg) : > "$B" ;;
	xb) { printf '\357\273\277'; jq -cjn --arg t "$TASK" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SubscribeToTask",params:{id:$t},id:$id}'; } > "$B" ;;
	x16) jq -cjn --arg t "$TASK" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SubscribeToTask",params:{id:$t},id:$id}' | iconv -f UTF-8 -t UTF-16LE > "$B" ;;
	xu) printf '{"jsonrpc":"2.0","METHOD":"SubscribeToTask","params":{"id":"%s"},"id":"%s"}' "$TASK" "$RPC_ID" > "$B" ;;
	xq) printf '{"jsonrpc":"2.0","method":"Subscribe\\u0054oTask","params":{"id":"%s"},"id":"%s"}' "$TASK" "$RPC_ID" > "$B" ;;
	gp | gs | gq) # a gRPC frame: flag 0, 4-byte big-endian length, then SubscribeToTaskRequest field 2 (id), a string
		# (a2apb/v1 a2av1.pb.go l.3263); the task id is under 128 bytes, so its length is one varint byte
		perl -e 'my $t=shift; my $m=pack("C C", 0x12, length $t).$t; print pack("C N", 0, length $m).$m' "$TASK" > "$B" ;;
	csm) jq -cjn --argjson m "$msg" --arg id "$RPC_ID" '{jsonrpc:"2.0",method:"SendMessage",id:$id,params:{message:$m}}' > "$B" ;;
	pad)
		head=$(printf '{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s","x_pad":"' "$TASK" "$RPC_ID")
		fill=$((PAD_LEN - ${#head} - 2))
		{ printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' 'a'; printf '"}'; } > "$B"
		;;
	padt)
		head=$(printf '{"jsonrpc":"2.0","method":"SubscribeToTask","id":"%s","params":{"id":"%s","tenant":"' "$RPC_ID" "$TASK")
		fill=$((PAD_LEN - ${#head} - 3))
		{ printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' 'a'; printf '"}}'; } > "$B"
		;;
	padsm)
		head=$(printf '{"jsonrpc":"2.0","method":"SendMessage","id":"%s","params":{"message":%s,"tenant":"' "$RPC_ID" "$msg")
		fill=$((PAD_LEN - ${#head} - 3))
		{ printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' 'a'; printf '"}}'; } > "$B"
		;;
	batch) printf '[{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s"}]' "$TASK" "$RPC_ID" > "$B" ;;
	dup) printf '{"jsonrpc":"2.0","method":"SendMessage","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s"}' "$TASK" "$RPC_ID" > "$B" ;;
	esac
	blen=$(wc -c < "$B" | tr -d ' '); bsha=$(shasum -a 256 "$B" | cut -d' ' -f1)
	case "$KIND" in
	pad | padt | padsm) head -c 400 "$B" > "$W/request-head.txt"; tail -c 40 "$B" > "$W/request-tail.txt" ;; # 2.2 MB: not kept
	gp | gs | gq | x16 | xb) od -An -tx1 -v "$B" | tr -s ' \n' ' ' > "$W/request-hex.txt" ;; # binary: kept as hex
	*) cp "$B" "$W/request.json" ;;
	esac
	case "$KIND" in csm | padsm) meth=SendMessage ;; *) meth=SubscribeToTask ;; esac
	UPATH=/; CT='application/json'; HM=POST; H2=()
	case "$KIND" in xp) UPATH=/x ;; xa) UPATH=/a2a/v1 ;; xg) CT='application/grpc' ;; xr) UPATH="/tasks/$TASK%3Asubscribe" ;; esac
	case "$KIND" in
	xn) UPATH=/%0A ;; xt) UPATH=/message:send/ ;; xm) UPATH=/lf.a2a.v1.A2AService/SendMessage; CT='application/grpc' ;;
	xc) UPATH="/tasks/$TASK:subscribe"; CT='application/grpc' ;; xh) UPATH="/tasks/$TASK:subscribe"; HM=HEAD ;;
	xl) UPATH="/tasks/$TASK:%73ubscribe" ;; xs) UPATH="/tasks%2F$TASK:subscribe" ;; xe) UPATH="/tasks/$TASK:subscribe%0A" ;;
	xi) UPATH="/tasks/a%2F$TASK:subscribe" ;; rg) UPATH="/tasks/$TASK:subscribe"; HM=GET ;; xk) UPATH='/?x=1' ;;
	gp) UPATH=/lf.a2a.v1.A2AService/Subscribe%54oTask ;; gs) UPATH=/lf.a2a.v1.A2AService%2FSubscribeToTask ;;
	gq) UPATH='/lf.a2a.v1.A2AService/SubscribeToTask?x=1' ;;
	esac
	case "$KIND" in gp | gs | gq) CT='application/grpc'; H2=(--http2-prior-knowledge -H 'TE: trailers') ;; esac
	# The request's method and body: HEAD by curl's own --head (no body is read back), GET with no body, a POST whose
	# body is empty sent with no body at all (Content-Length 0), every other POST with its body.
	case "$HM" in HEAD) MB=(--head) ;; GET) MB=(-X GET) ;; *) if [ -s "$B" ]; then MB=(-X POST --data-binary @-); else MB=(-X POST -H 'Content-Length: 0'); fi ;; esac
	s=$(tsn)
	out=$(kubectl -n "$NS" exec -i "$POD" -- curl -sS -i -v --retry 0 --max-time 30 "${MB[@]}" ${H2[@]+"${H2[@]}"} ${HOSTH[@]+"${HOSTH[@]}"} \
		-H "Content-Type: $CT" -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
		-H "traceparent: 00-${TRACE_ID}-${SPAN}-01" -w '\n__STATUS__%{http_code}' "$INGRESS$UPATH" < "$B" 2> "$W/curl-stderr.txt")
	rc=$?
	e=$(tsn)
	rm -f "$B"
	code=$(printf '%s\n' "$out" | sed -n 's/^__STATUS__//p' | tail -1)
	printf '%s\n' "$out" | sed '/^__STATUS__/d' > "$W/response.txt"
	grep '^> ' "$W/curl-stderr.txt" > "$W/request-headers-as-sent.txt" || true
	jq -cn --arg ts "$s" --arg te "$e" --arg lwi "$LWI" --arg phase "$PHASE" --arg recv "$RECV" --arg kind "$KIND" --arg url "$INGRESS$UPATH" --arg hm "$HM" \
		--arg code "$code" --argjson rc "$rc" --arg trace "$TRACE_ID" --arg id "$RPC_ID" --arg task "$TASK" --arg mid "$MID" --arg meth "$meth" --arg ct "$CT" \
		--argjson blen "$blen" --arg bsha "$bsha" --arg head "$(head -c 300 "$W/response.txt" | tr '\r\n' '  ')" \
		'{ledger:"client",client:"curl",binding:"jsonrpc",ts:$ts,ts_end:$te,logical_work_item_id:$lwi,phase:$phase,receiver:$recv,kind:$kind,method:$meth,http_method:$hm,
		  url:$url,content_type:$ct,attempt:1,http_status:$code,exit_code:$rc,trace_id:$trace,id:$id,taskId_asked:$task,messageId:$mid,body_len:$blen,
		  body_sha256:$bsha,response_head:$head}' > "$W/client.jsonl"
	echo "$(tsn) curl http=$code exit=$rc body_len=$blen" >> "$W/steps.txt"
	outcome="http=$code exit=$rc body_len=$blen"
	;;
*)
	IMAGE="${IMAGE:?IMAGE (d3.sh image) is required}"
	case "$RECV" in go) target=$INGRESS dial=target host=worker.lab.internal auth=worker-grpc.lab.internal ;; py) target=$ORCH_URL dial= host= auth=orchestrator-grpc.lab.internal ;; esac
	[ "$BINDING" = grpc ] || auth=
	case "$KIND" in sm) mode= task= ;; st) mode=subscribe task=$TASK ;; ss) mode=stream task= ;; esac
	name="loadgen-$LWI"
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${LWI}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" \
		"$TEMPLATE" | CB="$CB" AUTH="$auth" yq '(.spec.template.spec.containers[0].env[] | select(.name == "CLIENT_BINDING")).value = strenv(CB) |
		(.spec.template.spec.containers[0].env[] | select(.name == "CLIENT_GRPC_AUTHORITY")).value = strenv(AUTH)' > "$W/job.yaml"
	if grep -v '^ *#' "$W/job.yaml" | grep -q '\${' || ! grep -q "image: ${IMAGE}\$" "$W/job.yaml"; then
		echo "rendered Job has a placeholder left or not the resolved image; not applied" | tee -a "$W/steps.txt"; exit 1
	fi
	echo "$(tsn) apply $name CLIENT_BINDING=${CB:-<empty>} CLIENT_GRPC_AUTHORITY=${auth:-<empty>} MODE=${mode:-<empty>} TASK_ID=${task:-<empty>} TARGET_URL=$target CLIENT_DIAL=${dial:-<empty>} CLIENT_HOST=${host:-<empty>}" >> "$W/steps.txt"
	kubectl apply -f "$W/job.yaml" > "$W/apply.txt" 2>&1 || echo "$(tsn) apply rc=$?" >> "$W/steps.txt"
	waited=0 st=""
	while [ "$waited" -lt "$JOB_LIMIT_S" ]; do
		st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1)
		[ -n "$st" ] && break
		sleep 1; waited=$((waited + 1))
	done
	echo "$(tsn) Job ${st:-timeout}" >> "$W/steps.txt"
	echo "$name $(kubectl -n "$NS" get job "$name" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')" > "$W/job.txt"
	outcome="job=${st:-timeout}"
	;;
esac
res=$(collect "$W" "$LWI" "$since")
gc=$(jq -r 'select(.line=="end" or .attempt!=null) | "\(.grpc_attempts // "-")/\(.grpc_transparent_attempts // "-")/\(.grpc_status // "-")"' "$W/client.jsonl" 2>/dev/null | tail -1)
echo "$(ts) $PHASE $BINDING $RECV $KIND $LWI $outcome grpc=${gc:-} $res" | tee -a "$D/phases.txt"
