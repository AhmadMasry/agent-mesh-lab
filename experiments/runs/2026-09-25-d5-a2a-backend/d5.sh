#!/usr/bin/env bash
# Follow-on D-5, Step 2, by the controller's ruling (ii): the driver, adapted from D-4's rows.sh (curl sends, logs,
# config dumps) and D-2's sends.sh (load-client Jobs on each binding). One phase per invocation:
#   bash d5.sh conn <label>   2.1: ONE set of sends, all inside 90 s, with agw-central's pool idle beforehand: a card
#                             GET and a SendMessage per agent per path (agw-central at the Service address; the
#                             ingress by its Host). Counters read straight from each ztunnel's metrics before and
#                             after the set, and after 100 s of quiet, so every connection the set opened has idled
#                             out (agentgateway's pool idle timeout, 90 s: lib.rs l.335-337 at v1.5.0) and written
#                             its ztunnel line.
#   bash d5.sh mark | unmark  2.1: the Service marking, appProtocol agentgateway.dev/a2a on the http port (8080) of
#                             the worker and the orchestrator Services, added or removed by a JSON patch kept in this
#                             directory (marking-add.json, marking-remove.json), each tested against the port's name.
#   bash d5.sh trial          2.2: the A2A backend type on the four HTTP agent routes, the deciding list (a)-(f),
#                             REPS each, then removal. The GRPCRoutes are not touched.
#   bash d5.sh clean          the clean check after the trial's removal (experiments/gate2-single-clean.sh, unedited).
# RUNREL (this directory's name) and RUN_ID (lower-case letters and digits) are required.
#
# Nothing under deploy/ is edited. Everything applied lives in this directory and is removed in the same phase or by
# the phase named for it. Every send is one curl --retry 0 or one load-client Job (backoffLimit 0, CLIENT_RETRIES 0);
# nothing is re-sent. Every wait is on a state, bounded. No retry logic.
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PHASE="${1:?phase conn|mark|unmark|trial|clean}"
RUNREL="${RUNREL:?RUNREL is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
case "$RUN_ID" in *[!a-z0-9]*) echo "RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
R="experiments/runs/$RUNREL"
NS=lab
CLUSTER_NAME=agent-mesh-lab
IMG=curlimages/curl:8.22.0
CARD=/.well-known/agent-card.json
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
INGRESS_URL=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
INGRESS_HOST=agentgateway-ingress.agentgateway-ingress.svc.cluster.local
TEMPLATE=deploy/base/loadgen-a2-job.yaml
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
JOB_LIMIT_S=90
REPS="${REPS:-3}"
QUIET_S=100
case "$PHASE" in conn) D="$R/conn-${2:?label}" ;; *) D="$R/$PHASE" ;; esac
mkdir -p "$D"
PH="$D/phases.txt"
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(tsn) $*" | tee -a "$PH"; }
rec() { { echo "## $(tsn) \$ $2"; bash -c "$2" 2>&1; echo; } >> "$1"; }

ctl_up() {
	kubectl -n "$NS" delete pod d5-ctl --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run d5-ctl --image="$IMG" --restart=Never --command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready pod/d5-ctl --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
}
reset_all() {
	local u c
	for u in "$MOCK_URL/control/reset" "$WORKER_URL/control/reset" "$ORCH_URL/control/reset"; do
		c=$(kubectl -n "$NS" exec d5-ctl -- curl -sS --retry 0 -o /dev/null -w '%{http_code}' -X POST "$u" 2>/dev/null)
		say "reset $u -> $c"
		case "$c" in 2??) ;; *) say "reset failed; stopping"; exit 1 ;; esac
	done
}
probe_up() { # $1 pod name, $2 ServiceAccount
	kubectl -n "$NS" delete pod "$1" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run "$1" --image="$IMG" --restart=Never \
		--overrides="{\"apiVersion\":\"v1\",\"spec\":{\"serviceAccountName\":\"$2\",\"automountServiceAccountToken\":false}}" \
		--command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready "pod/$1" --timeout=90s >/dev/null || { say "probe $1 not ready"; exit 1; }
	say "probe up: $(kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.name} sa={.spec.serviceAccountName} ip={.status.podIP}')"
}
dumps() { # $1 label: both proxies' config dumps, and their policy and backend entries
	local f="$D/dumps-$1.txt" pair
	for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
		set -- $pair "$1"
		"$F17/config-dump.sh" "$1" "$2" "$D/config-dump-$2-$3.json" >/dev/null 2>&1
		rec "$f" "jq -r '\"$2 policies: \\((.policies // []) | length), backends: \\((.backends // []) | length)\", ((.policies // [])[] | \"  policy name=\\(.name|tostring) target=\\(.target|tostring|.[0:200]) spec=\\(.policy|tostring|.[0:300])\"), ((.backends // [])[] | \"  backend \\(tostring|.[0:400])\")' '$D/config-dump-$2-$3.json'"
	done
}
wait_dump() { # $1 namespace, $2 deployment, $3 jq expression that must print true
	local w=0 tmp="$D/.dump-wait.json"
	while [ "$w" -lt 90 ]; do
		"$F17/config-dump.sh" "$1" "$2" "$tmp" >/dev/null 2>&1
		if [ "$(jq -r "$3" "$tmp" 2>/dev/null)" = true ]; then say "$2 dump: [$3] after ~${w}s"; rm -f "$tmp"; return 0; fi
		sleep 2; w=$((w + 2))
	done
	rm -f "$tmp"; say "$2 dump: [$3] not true within 90 s; stopping"; exit 1
}
counters() { # $1 label: every istio_tcp_connections_opened_total series naming an agent, from each ztunnel directly
	local f="$D/counters-$1.txt" zt
	{
		echo "# $(tsn) istio_tcp_connections_opened_total, destination_workload worker or orchestrator, read from each ztunnel's :15020/metrics through the API server"
		for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
			kubectl get --raw "/api/v1/namespaces/istio-system/pods/$zt:15020/proxy/metrics" 2>/dev/null |
				grep '^istio_tcp_connections_opened_total{' | grep -E 'destination_workload="(worker|orchestrator)"' |
				sed -E 's/^istio_tcp_connections_opened_total\{.*reporter="([^"]*)".*source_workload="([^"]*)".*source_principal="([^"]*)".*destination_workload="([^"]*)".*connection_security_policy="([^"]*)".*\} ([0-9]+)$/reporter=\1 src=\2 src_principal=\3 dst=\4 security=\5 value=\6/' |
				sed "s/^/$zt /"
		done
	} > "$f"
	say "counters $1: $(grep -c 'value=' "$f") series; agw-central->worker(dest)=$(grep 'reporter=destination src=agw-central ' "$f" | grep 'dst=worker ' | sed 's/.*value=//' | paste -sd+ - | bc 2>/dev/null) agw-central->orchestrator(dest)=$(grep 'reporter=destination src=agw-central ' "$f" | grep 'dst=orchestrator ' | sed 's/.*value=//' | paste -sd+ - | bc 2>/dev/null) ingress->worker(dest)=$(grep 'reporter=destination src=agentgateway-ingress ' "$f" | grep 'dst=worker ' | sed 's/.*value=//' | paste -sd+ - | bc 2>/dev/null) ingress->orchestrator(dest)=$(grep 'reporter=destination src=agentgateway-ingress ' "$f" | grep 'dst=orchestrator ' | sed 's/.*value=//' | paste -sd+ - | bc 2>/dev/null)"
}
logs_since() { # $1 since, $2 label: both proxies' request lines, agw-central's whole log, every ztunnel's lines
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$1" > "$D/agw-central-log-$2.txt" 2>/dev/null || true
	grep 'request gateway=' "$D/agw-central-log-$2.txt" > "$D/agw-central-access-$2.txt" || true
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$1" > "$D/ingress-log-$2.txt" 2>/dev/null || true
	grep 'request gateway=' "$D/ingress-log-$2.txt" > "$D/ingress-access-$2.txt" || true
	local zt
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --since-time="$1" 2>/dev/null | sed "s/^/$zt /"
	done > "$D/ztunnel-$2.txt"
	say "logs since $1 ($2): agw-central $(grep -c '' "$D/agw-central-access-$2.txt") request lines of $(grep -c '' "$D/agw-central-log-$2.txt"), ingress $(grep -c '' "$D/ingress-access-$2.txt") of $(grep -c '' "$D/ingress-log-$2.txt"), ztunnel $(grep -c '' "$D/ztunnel-$2.txt") lines"
}
curl_one() { # $1 pod, $2 lwi, $3 op GetAgentCard|SendMessage, $4 base URL, $5 Host -> one request, one client line
	local pod="$1" lwi="$2" op="$3" base="$4" host="$5" W="$D/$2" trace span mid rid out rc code method path t0
	mkdir -p "$W"
	trace=$(openssl rand -hex 16); span=$(openssl rand -hex 8); mid=$(uuidgen | tr 'A-Z' 'a-z'); rid=$(uuidgen | tr 'A-Z' 'a-z')
	if [ "$op" = GetAgentCard ]; then method=GET; path=$CARD; else method=POST; path=/
		jq -cjn --arg lwi "$lwi" --arg mid "$mid" --arg id "$rid" \
			'{jsonrpc:"2.0",method:"SendMessage",params:{message:{messageId:$mid,metadata:{logical_work_item_id:$lwi},parts:[{text:("lwi:"+$lwi+" hello")}],role:"ROLE_USER"}},id:$id}' > "$W/request.json"
	fi
	local args=(-sS --retry 0 --max-time 30 -X "$method" -w '\n%{http_code}' -H "Host: $host" -H 'A2A-Version: 1.0'
		-H "X-Logical-Work-Item-Id: $lwi" -H "traceparent: 00-$trace-$span-01")
	[ "$method" = POST ] && args+=(-H 'Content-Type: application/json' --data-binary @-)
	t0=$(tsn)
	if [ "$method" = POST ]; then out=$(kubectl -n "$NS" exec -i "$pod" -- curl "${args[@]}" "$base$path" < "$W/request.json" 2> "$W/stderr-$op.txt"); rc=$?
	else out=$(kubectl -n "$NS" exec "$pod" -- curl "${args[@]}" "$base$path" < /dev/null 2> "$W/stderr-$op.txt"); rc=$?; fi
	code=$(printf '%s\n' "$out" | tail -n 1)
	[ "$op" = GetAgentCard ] && printf '%s\n' "$out" | sed '$d' > "$W/card.json"
	jq -cn --arg ts "$t0" --arg lwi "$lwi" --arg pod "$pod" --arg op "$op" --arg url "$base$path" --arg host "$host" \
		--arg code "$code" --argjson rc "$rc" --arg trace "$trace" --arg mid "$mid" --arg id "$rid" \
		--arg head "$(printf '%s\n' "$out" | sed '$d' | head -c 400)" --arg err "$(tr '\n' ' ' < "$W/stderr-$op.txt")" \
		'{ledger:"client",client:"curl",ts:$ts,logical_work_item_id:$lwi,pod:$pod,op:$op,url:$url,host:$host,attempt:1,
		  http_status:$code,exit_code:$rc,trace_id:$trace,messageId:(if $op=="SendMessage" then $mid else "" end),
		  id:(if $op=="SendMessage" then $id else "" end),response_head:$head,stderr:$err}' >> "$W/client.jsonl"
	say "  $lwi $op $method $base$path host=$host -> http=$code exit=$rc trace=$trace"
}
ledgers() { # $1 lwi, $2 dir
	make --no-print-directory ledgers "LWI=$1" "OUT=$2" >/dev/null 2>>"$2/ledgers-stderr.txt"
	say "  $1 ledgers ingress=$(grep -c '' "$2/ingress.jsonl" 2>/dev/null) execution=$(grep -c '' "$2/execution.jsonl" 2>/dev/null) invocation=$(grep -c '' "$2/invocation.jsonl" 2>/dev/null)"
}
IMAGE=""
resolve_image() {
	mkdir -p "${TMPDIR%/}/d5"
	IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d5/ko-build-$PHASE-$RUN_ID.log") || true
	case "$IMAGE" in kind.local/loadgen-*:*) say "loadgen image: $IMAGE (fixtures $(git rev-parse HEAD:fixtures), template $(git rev-parse HEAD:$TEMPLATE))" ;; *) say "the loadgen image could not be resolved; stopping"; exit 1 ;; esac
}
job() { # $1 lwi, $2 target, $3 dial, $4 host, $5 binding (""|rest|grpc), $6 grpc authority -> ONE load-client Job
	local lwi="$1" target="$2" dial="$3" host="$4" cb="$5" auth="$6" name W y w=0 st="" since
	name="loadgen-$lwi"; W="$D/$lwi"; y="$W/job.yaml"; mkdir -p "$W"
	since=$(tsn)
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}//g" -e "s/\${TASK_ID}//g" -e "s/\${CANCEL_AFTER_MS}//g" "$TEMPLATE" |
		CB="$cb" AUTH="$auth" yq '(.spec.template.spec.containers[0].env[] | select(.name == "CLIENT_BINDING")).value = strenv(CB) |
		(.spec.template.spec.containers[0].env[] | select(.name == "CLIENT_GRPC_AUTHORITY")).value = strenv(AUTH)' > "$y"
	if grep -v '^ *#' "$y" | grep -q '\${' || ! grep -q "image: ${IMAGE}\$" "$y" || ! grep -q 'serviceAccountName: loadgen' "$y"; then
		say "rendered Job $y has a placeholder left, not the resolved image, or not the loadgen account; stopping"; exit 1
	fi
	say "job $name target=$target dial=${dial:-<empty>} host=${host:-<empty>} binding=${cb:-<empty>} authority=${auth:-<empty>}"
	kubectl apply -f "$y" >> "$PH" 2>&1
	while [ "$w" -lt "$JOB_LIMIT_S" ]; do
		st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1)
		[ -n "$st" ] && break; sleep 1; w=$((w + 1))
	done
	sleep 2
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/ingress-access.txt" || true
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
	echo "$name $(kubectl -n "$NS" get job "$name" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-ip=$(kubectl -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null) since=$since" > "$W/job.txt"
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$W" >/dev/null 2>>"$W/ledgers-stderr.txt"
	say "  $lwi ${st:-timeout} ingress=$(grep -c '' "$W/ingress.jsonl" 2>/dev/null) execution=$(grep -c '' "$W/execution.jsonl" 2>/dev/null) invocation=$(grep -c '' "$W/invocation.jsonl" 2>/dev/null) proxy-lines ingress=$(grep -c '' "$W/ingress-access.txt") agw-central=$(grep -c '' "$W/agw-central-access.txt") client-end=[$(jq -r -c 'select(.line == "end" or .result_kind != null or .error != null) | {result_kind, state, http_status, error}' "$W/client.jsonl" 2>/dev/null | tail -1)]"
}

say "phase $PHASE ${2:-} RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1)"
trap 'kubectl -n "$NS" delete pod d5-ctl d5-as-loadgen --ignore-not-found --wait=false >/dev/null 2>&1 || true; say "phase $PHASE driver exit"' EXIT
say "worker pod: $(kubectl -n "$NS" get pod -l app=worker -o jsonpath='{.items[0].metadata.name} ip={.items[0].status.podIP}'); orchestrator pod: $(kubectl -n "$NS" get pod -l app=orchestrator -o jsonpath='{.items[0].metadata.name} ip={.items[0].status.podIP}')"
say "proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP}; {end}')"
say "Services' http port: $(kubectl -n "$NS" get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.ports[0].name}/{.spec.ports[0].port}/appProtocol={.spec.ports[0].appProtocol}; {end}')"

case "$PHASE" in
conn)
	L="$2"
	ctl_up
	reset_all
	probe_up d5-as-loadgen loadgen
	dumps before
	say "quiet ${QUIET_S} s, so that agw-central's and the ingress's pools to the agents are idle-closed before the set"
	sleep "$QUIET_S"
	counters pre
	SINCE=$(tsn); say "set opens"
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-wc" GetAgentCard "$WORKER_URL" worker.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-wc" SendMessage "$WORKER_URL" worker.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-oc" GetAgentCard "$ORCH_URL" orchestrator.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-oc" SendMessage "$ORCH_URL" orchestrator.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-wi" GetAgentCard "$INGRESS_URL" worker.lab.internal
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-wi" SendMessage "$INGRESS_URL" worker.lab.internal
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-oi" GetAgentCard "$INGRESS_URL" "$INGRESS_HOST"
	curl_one d5-as-loadgen "d5c-$L-$RUN_ID-oi" SendMessage "$INGRESS_URL" "$INGRESS_HOST"
	END=$(tsn); say "set closes"
	counters post
	say "quiet ${QUIET_S} s, so that the set's connections idle out and write their ztunnel lines"
	sleep "$QUIET_S"
	counters idle
	logs_since "$SINCE" set
	for w in wc oc wi oi; do ledgers "d5c-$L-$RUN_ID-$w" "$D/d5c-$L-$RUN_ID-$w"; done
	echo "set_open=$SINCE set_close=$END" > "$D/window.txt"
	;;
mark)
	dumps before
	rec "$D/apply.txt" "kubectl -n $NS patch svc worker --type=json --patch-file $R/marking-add.json"
	rec "$D/apply.txt" "kubectl -n $NS patch svc orchestrator --type=json --patch-file $R/marking-add.json"
	wait_dump agentgateway-waypoint agw-central '[.policies[]? | tostring | test("a2a"; "i")] | map(select(.)) | length == 2'
	wait_dump agentgateway-ingress agentgateway-ingress '[.policies[]? | tostring | test("a2a"; "i")] | map(select(.)) | length == 2'
	dumps applied
	;;
unmark)
	rec "$D/remove.txt" "kubectl -n $NS patch svc worker --type=json --patch-file $R/marking-remove.json"
	rec "$D/remove.txt" "kubectl -n $NS patch svc orchestrator --type=json --patch-file $R/marking-remove.json"
	wait_dump agentgateway-waypoint agw-central '[.policies[]? | tostring | test("a2a"; "i")] | map(select(.)) | length == 0'
	wait_dump agentgateway-ingress agentgateway-ingress '[.policies[]? | tostring | test("a2a"; "i")] | map(select(.)) | length == 0'
	dumps removed
	;;
trial)
	O="$R/trial-overlay"
	ctl_up
	reset_all
	resolve_image
	for r in worker orchestrator worker-ingress orchestrator-ingress; do
		kubectl -n "$NS" get httproute "$r" -o json | jq -S '.spec' > "$D/route-spec-before-$r.json"
	done
	dumps before
	counters before
	SINCE=$(tsn); say "window opens"
	rec "$D/apply.txt" "kubectl apply -f $O/backends.yaml"
	for r in worker worker-ingress; do rec "$D/apply.txt" "kubectl -n $NS patch httproute $r --type=json --patch-file $O/route-to-worker-a2a.json"; done
	for r in orchestrator orchestrator-ingress; do rec "$D/apply.txt" "kubectl -n $NS patch httproute $r --type=json --patch-file $O/route-to-orchestrator-a2a.json"; done
	rec "$D/apply.txt" "kubectl -n $NS get agentgatewaybackend -o yaml"
	wait_dump agentgateway-waypoint agw-central '[.backends[]? | tostring | select(test("worker-a2a") or test("orchestrator-a2a"))] | length == 2'
	wait_dump agentgateway-ingress agentgateway-ingress '[.backends[]? | tostring | select(test("worker-a2a") or test("orchestrator-a2a"))] | length == 2'
	dumps applied
	for i in $(seq 1 "$REPS"); do
		job "d5t-a-$RUN_ID-$i" "$INGRESS_URL" target worker.lab.internal "" ""
		job "d5t-b-$RUN_ID-$i" "$WORKER_URL" "" "" "" ""
		job "d5t-c-$RUN_ID-$i" "$ORCH_URL" "" "" "" ""
		job "d5t-di-$RUN_ID-$i" "$INGRESS_URL" target worker.lab.internal rest ""
		job "d5t-dc-$RUN_ID-$i" "$WORKER_URL" "" "" rest ""
		job "d5t-e-$RUN_ID-$i" "$INGRESS_URL" target worker.lab.internal grpc worker-grpc.lab.internal
		job "d5t-f-$RUN_ID-$i" "$INGRESS_URL" "" "" "" ""
	done
	sleep 3
	counters in-force
	logs_since "$SINCE" in-force
	# the cards as served by each proxy while the backend type is in force: one GET per path a client uses
	probe_up d5-as-loadgen loadgen
	curl_one d5-as-loadgen "d5t-cards-$RUN_ID-go-ingress" GetAgentCard "$INGRESS_URL" worker.lab.internal
	curl_one d5-as-loadgen "d5t-cards-$RUN_ID-go-central" GetAgentCard "$WORKER_URL" worker.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5t-cards-$RUN_ID-py-central" GetAgentCard "$ORCH_URL" orchestrator.lab.svc.cluster.local:8080
	curl_one d5-as-loadgen "d5t-cards-$RUN_ID-py-ingress" GetAgentCard "$INGRESS_URL" "$INGRESS_HOST"
	sleep 2
	logs_since "$SINCE" in-force-with-cards
	REM=$(tsn); say "removal opens"
	for r in worker worker-ingress orchestrator orchestrator-ingress; do
		kubectl -n "$NS" get httproute "$r" -o json | jq -S '.spec' > "$D/route-spec-applied-$r.json"
		jq -c '[{op:"replace",path:"/spec/rules/0/backendRefs",value:.rules[0].backendRefs}]' "$D/route-spec-before-$r.json" > "$D/route-restore-$r.json"
		rec "$D/remove.txt" "kubectl -n $NS patch httproute $r --type=json --patch-file $D/route-restore-$r.json"
	done
	rec "$D/remove.txt" "kubectl delete -f $O/backends.yaml"
	wait_dump agentgateway-waypoint agw-central '[.backends[]? | tostring | select(test("worker-a2a") or test("orchestrator-a2a"))] | length == 0'
	wait_dump agentgateway-ingress agentgateway-ingress '[.backends[]? | tostring | select(test("worker-a2a") or test("orchestrator-a2a"))] | length == 0'
	for r in worker worker-ingress orchestrator orchestrator-ingress; do
		kubectl -n "$NS" get httproute "$r" -o json | jq -S '.spec' > "$D/route-spec-after-$r.json"
		if cmp -s "$D/route-spec-before-$r.json" "$D/route-spec-after-$r.json"; then say "route $r spec restored, byte-equal to before"; else say "route $r spec DIFFERS from before"; fi
	done
	say "AgentgatewayBackends in lab after removal: $(kubectl -n "$NS" get agentgatewaybackend --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	dumps removed
	logs_since "$REM" removal
	reset_all
	;;
clean)
	RUN_ITEM="$RUNREL/clean-after" RUN_ID="$RUN_ID" bash experiments/gate2-single-clean.sh > "$D/clean-driver.txt" 2>&1
	say "clean check exit=$? $(tail -3 "$D/clean-driver.txt" | tr '\n' ' ')"
	;;
*) echo "unknown phase $PHASE" >&2; exit 1 ;;
esac
