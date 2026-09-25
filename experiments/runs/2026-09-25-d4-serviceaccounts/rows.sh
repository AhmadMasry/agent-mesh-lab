#!/usr/bin/env bash
# Follow-on D-4: the rows on the rebuilt cluster, with the load client, the worker and the orchestrator on their own
# ServiceAccounts. One phase per invocation:
#   bash rows.sh z      Row Z: ztunnel's L4 ALLOW on principals at the worker, sends direct to the worker pod
#   bash rows.sh a      Row A: agentgateway's Allow on source.identity on agw-central's route lab/worker
#   bash rows.sh r2     R2: the ingress's source.identity and source.unverifiedWorkload, read by a probe-header Deny
#   bash rows.sh xa     the ingress's ext-authz source principal, re-read with D-3's overlay, unedited, from its record
# RUNREL (the run directory's name) and RUN_ID (lower-case letters and digits) are required.
#
# Each overlay lives in this run directory, never under deploy/; applied by kubectl apply -k and removed by kubectl
# delete -k in the same phase, readings before, in force and after. Every send is one curl --retry 0 or one load-client
# Job (backoffLimit 0, CLIENT_RETRIES 0); nothing is re-sent. A refusal is recorded as the caller saw it.
# Probe pods run under the orchestrator's and the load client's ServiceAccounts: the probe carries the identity
# ztunnel and agentgateway read, the lab standing in for the caller; they are not the workloads themselves.
# Every wait below is on a state (a policy held or gone, a pod ready, a Job ended), bounded, never a re-send.
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PHASE="${1:?phase z|a|r2|xa}"
RUNREL="${RUNREL:?RUNREL is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
case "$RUN_ID" in *[!a-z0-9]*) echo "RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
PATH="${TMPDIR%/}/d4/tools/istioctl-1.31.0:$PATH"; export PATH
R="experiments/runs/$RUNREL"
D="$R/$PHASE"
NS=lab
CLUSTER_NAME=agent-mesh-lab
IMG=curlimages/curl:8.22.0
CARD=/.well-known/agent-card.json
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
INGRESS_URL=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
TEMPLATE=deploy/base/loadgen-a2-job.yaml
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
JOB_LIMIT_S=120
mkdir -p "$D"
PH="$D/phases.txt"
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(tsn) $*" | tee -a "$PH"; }
rec() { { echo "## $(tsn) \$ $2"; bash -c "$2" 2>&1; echo; } >> "$1"; }

ctl_up() {
	kubectl -n "$NS" delete pod d4-ctl --ignore-not-found --wait=true >/dev/null 2>&1 || true
	kubectl -n "$NS" run d4-ctl --image="$IMG" --restart=Never --command -- sleep 7200 >/dev/null
	kubectl -n "$NS" wait --for=condition=Ready pod/d4-ctl --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
}
reset_all() { # the mock and both injectors, by the default-account control pod, through each Service
	local u c
	for u in "$MOCK_URL/control/reset" "$WORKER_URL/control/reset" "$ORCH_URL/control/reset"; do
		c=$(kubectl -n "$NS" exec d4-ctl -- curl -sS --retry 0 -o /dev/null -w '%{http_code}' -X POST "$u" 2>/dev/null)
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
	say "probe up: $(kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.name} sa={.spec.serviceAccountName} automount={.spec.automountServiceAccountToken} ip={.status.podIP} created={.metadata.creationTimestamp}')"
}
readings() { # $1 label
	local f="$D/readings-$1.txt"
	rec "$f" "kubectl get authorizationpolicy -A -o yaml"
	rec "$f" "kubectl get agentgatewaypolicy -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) authorization=\\(.spec.traffic.authorization != null) extAuth=\\(.spec.traffic.extAuth != null) ancestors=\\([.status.ancestors[]? | .conditions[]? | \"\\(.type)=\\(.status)/\\(.reason)\"] | join(\",\"))\"'"
	rec "$f" "istioctl ztunnel-config policy"
	rec "$f" "kubectl get peerauthentication -A --no-headers"
	rec "$f" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	rec "$f" "kubectl -n $NS get serviceaccount"
	rec "$f" "kubectl -n $NS get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,IP:.status.podIP,PHASE:.status.phase"
	for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
		set -- $pair
		"$F17/config-dump.sh" "$1" "$2" "$D/config-dump-$2-${f##*readings-}.json" >/dev/null 2>&1
		rec "$f" "jq -r '(.policies // []) | length as \$n | \"$2 policies: \\(\$n)\", (.[] | \"  name=\\(.name|tostring) target=\\(.target|tostring|.[0:160]) policy=\\(.policy|tostring|.[0:300])\")' '$D/config-dump-$2-${f##*readings-}.json'"
	done
}
apply_ov() { rec "$D/apply-$1.txt" "kubectl apply -k $R/$1"; say "applied $1"; }
remove_ov() { rec "$D/remove-$1.txt" "kubectl delete -k $R/$1"; say "removed $1"; }
wait_ztunnel() { # $1 name, $2 present|absent
	local w=0 has
	while [ "$w" -lt 60 ]; do
		has=$(istioctl ztunnel-config policy 2>/dev/null | grep -c "$1" || true)
		if { [ "$2" = present ] && [ "$has" -gt 0 ]; } || { [ "$2" = absent ] && [ "$has" -eq 0 ]; }; then say "ztunnel: $1 $2 after ${w}s"; return 0; fi
		sleep 1; w=$((w + 1))
	done
	say "ztunnel: $1 not $2 within 60 s; stopping"; exit 1
}
wait_dump() { # $1 namespace, $2 deployment, $3 grep pattern, $4 present|absent
	local w=0 has tmp="$D/.dump-wait.json"
	while [ "$w" -lt 90 ]; do
		"$F17/config-dump.sh" "$1" "$2" "$tmp" >/dev/null 2>&1
		has=$(grep -c "$3" "$tmp" 2>/dev/null || true)
		if { [ "$4" = present ] && [ "$has" -gt 0 ]; } || { [ "$4" = absent ] && [ "$has" -eq 0 ]; }; then say "$2 dump: $3 $4 after ~${w}s"; rm -f "$tmp"; return 0; fi
		sleep 2; w=$((w + 2))
	done
	rm -f "$tmp"; say "$2 dump: $3 not $4 within 90 s; stopping"; exit 1
}

IMAGE=""
resolve_image() {
	mkdir -p "${TMPDIR%/}/d4/work"
	IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d4/work/ko-build-$PHASE-$RUN_ID.log") || true
	case "$IMAGE" in kind.local/loadgen-*:*) say "loadgen image: $IMAGE" ;; *) say "the loadgen image could not be resolved; stopping"; exit 1 ;; esac
}
job() { # $1 lwi, $2 target, $3 dial, $4 host -> the load client, one Job; collects the three ledgers and its client lines
	local lwi="$1" target="$2" dial="${3:-}" host="${4:-}" name y w=0 st=""
	name="loadgen-$lwi"; y="$D/jobs/$lwi.yaml"; mkdir -p "$D/jobs"
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}//g" -e "s/\${TASK_ID}//g" -e "s/\${CANCEL_AFTER_MS}//g" "$TEMPLATE" > "$y"
	grep -q '\${' "$y" && { say "placeholder left in $y; stopping"; exit 1; }
	grep -q 'serviceAccountName: loadgen' "$y" || { say "$y does not name the loadgen account; stopping"; exit 1; }
	say "job $name target=$target dial=${dial:-<empty>} host=${host:-<empty>}"
	kubectl apply -f "$y" >> "$PH" 2>&1
	while [ "$w" -lt "$JOB_LIMIT_S" ]; do
		st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1)
		[ -n "$st" ] && break; sleep 1; w=$((w + 1))
	done
	sleep 1
	mkdir -p "$D/$lwi"
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$D/$lwi" >/dev/null 2>>"$D/$lwi/ledgers-stderr.txt"
	say "  $lwi ${st:-timeout} pod-sa=$(kubectl -n "$NS" get pod -l "job-name=$name" -o jsonpath='{.items[0].spec.serviceAccountName}') ip=$(kubectl -n "$NS" get pod -l "job-name=$name" -o jsonpath='{.items[0].status.podIP}') ingress=$(grep -c '' "$D/$lwi/ingress.jsonl") execution=$(grep -c '' "$D/$lwi/execution.jsonl") invocation=$(grep -c '' "$D/$lwi/invocation.jsonl") client-end=[$(jq -r -c 'select(.line == "end" or .result_kind != null or .error != null) | {result_kind, state, http_status, error}' "$D/$lwi/client.jsonl" 2>/dev/null | tail -1)]"
}
curl_send() { # $1 pod, $2 lwi, $3 base URL, $4 Host, $5 extra header ("" for none), $6 ops ("card+send" | "send")
	local pod="$1" lwi="$2" base="$3" host="$4" xh="$5" ops="$6" W="$D/$2" trace mid rid op method path span out rc code
	mkdir -p "$W"; : > "$W/client.jsonl"
	trace=$(openssl rand -hex 16); mid=$(uuidgen | tr 'A-Z' 'a-z'); rid=$(uuidgen | tr 'A-Z' 'a-z')
	jq -cjn --arg lwi "$lwi" --arg mid "$mid" --arg id "$rid" \
		'{jsonrpc:"2.0",method:"SendMessage",params:{message:{messageId:$mid,metadata:{logical_work_item_id:$lwi},parts:[{text:("lwi:"+$lwi+" hello")}],role:"ROLE_USER"}},id:$id}' > "$W/request.json"
	for op in GetAgentCard SendMessage; do
		[ "$op" = GetAgentCard ] && [ "$ops" = send ] && continue
		if [ "$op" = GetAgentCard ]; then method=GET; path=$CARD; else method=POST; path=/; fi
		span=$(openssl rand -hex 8)
		local args=(-sS --retry 0 --max-time 30 -X "$method" -w '\n%{http_code}' -H "Host: $host" -H 'A2A-Version: 1.0'
			-H "X-Logical-Work-Item-Id: $lwi" -H "traceparent: 00-$trace-$span-01")
		[ -n "$xh" ] && args+=(-H "$xh")
		[ "$method" = POST ] && args+=(-H 'Content-Type: application/json' --data-binary @-)
		local t0; t0=$(tsn)
		if [ "$method" = POST ]; then out=$(kubectl -n "$NS" exec -i "$pod" -- curl "${args[@]}" "$base$path" < "$W/request.json" 2> "$W/stderr-$op.txt"); rc=$?
		else out=$(kubectl -n "$NS" exec "$pod" -- curl "${args[@]}" "$base$path" < /dev/null 2> "$W/stderr-$op.txt"); rc=$?; fi
		code=$(printf '%s\n' "$out" | tail -n 1)
		jq -cn --arg ts "$t0" --arg lwi "$lwi" --arg pod "$pod" --arg op "$op" --arg url "$base$path" --arg host "$host" --arg xh "$xh" \
			--arg code "$code" --argjson rc "$rc" --arg trace "$trace" --arg mid "$mid" --arg id "$rid" \
			--arg head "$(printf '%s\n' "$out" | sed '$d' | head -c 240)" --arg err "$(tr '\n' ' ' < "$W/stderr-$op.txt")" \
			'{ledger:"client",ts:$ts,logical_work_item_id:$lwi,pod:$pod,op:$op,url:$url,host:$host,extra_header:$xh,attempt:1,
			  http_status:$code,exit_code:$rc,trace_id:$trace,messageId:(if $op=="SendMessage" then $mid else "" end),
			  id:(if $op=="SendMessage" then $id else "" end),response_head:$head,stderr:$err}' >> "$W/client.jsonl"
		say "  $lwi $pod $op $method $base$path host=$host ${xh:+[$xh] }-> http=$code exit=$rc trace=$trace"
	done
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$W" >/dev/null 2>>"$W/ledgers-stderr.txt"
	say "  $lwi ledgers ingress=$(grep -c '' "$W/ingress.jsonl") execution=$(grep -c '' "$W/execution.jsonl") invocation=$(grep -c '' "$W/invocation.jsonl")"
}
logs_since() { # $1 since, $2 label
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$1" 2>/dev/null | grep 'request gateway=' > "$D/agw-central-access-$2.txt" || true
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$1" 2>/dev/null | grep 'request gateway=' > "$D/ingress-access-$2.txt" || true
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --since-time="$1" 2>/dev/null | sed "s/^/$zt /"
	done > "$D/ztunnel-$2.txt"
	say "logs since $1 ($2): agw-central $(grep -c '' "$D/agw-central-access-$2.txt"), ingress $(grep -c '' "$D/ingress-access-$2.txt"), ztunnel $(grep -c '' "$D/ztunnel-$2.txt") lines"
}

say "phase $PHASE RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl $(istioctl version --remote=false 2>/dev/null)"
trap 'kubectl -n "$NS" delete pod d4-ctl d4-as-orchestrator d4-as-loadgen --ignore-not-found --wait=false >/dev/null 2>&1 || true; say "phase $PHASE driver exit"' EXIT
ctl_up
say "worker pod: $(kubectl -n "$NS" get pod -l app=worker -o jsonpath='{.items[0].metadata.name} sa={.items[0].spec.serviceAccountName} ip={.items[0].status.podIP}'); orchestrator pod: $(kubectl -n "$NS" get pod -l app=orchestrator -o jsonpath='{.items[0].metadata.name} sa={.items[0].spec.serviceAccountName} ip={.items[0].status.podIP}')"
say "proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP}; {end}')"

case "$PHASE" in
z)
	readings before
	reset_all
	resolve_image
	SINCE=$(tsn); say "window opens"
	apply_ov overlay-d4-z
	wait_ztunnel d4-z-allow-orchestrator-and-agw-central present
	readings applied
	# the probes are created after ztunnel holds the policy, so no connection of theirs predates it (C-3R)
	probe_up d4-as-orchestrator orchestrator
	probe_up d4-as-loadgen loadgen
	WIP=$(kubectl -n "$NS" get pod -l app=worker -o jsonpath='{.items[0].status.podIP}')
	for i in 1 2 3 4 5; do
		curl_send d4-as-orchestrator "d4z-${RUN_ID}-orch-$i" "http://$WIP:8080" "$WIP:8080" "" card+send
		curl_send d4-as-loadgen "d4z-${RUN_ID}-lg-$i" "http://$WIP:8080" "$WIP:8080" "" card+send
	done
	# the forward control: the orchestrator's real forward, through agw-central, under the same policy
	for i in 1 2 3 4 5; do job "d4z-${RUN_ID}-fwd-$i" "$ORCH_URL" "" ""; done
	sleep 3
	logs_since "$SINCE" z-in-force
	remove_ov overlay-d4-z
	wait_ztunnel d4-z-allow-orchestrator-and-agw-central absent
	readings removed
	# after removal, one send direct from each identity, on new connections
	curl_send d4-as-orchestrator "d4z-${RUN_ID}-after-orch" "http://$WIP:8080" "$WIP:8080" "" card+send
	curl_send d4-as-loadgen "d4z-${RUN_ID}-after-lg" "http://$WIP:8080" "$WIP:8080" "" card+send
	reset_all
	;;
a)
	readings before
	reset_all   # before the apply: under the Allow the control pod's resets through lab/worker are refused
	resolve_image
	SINCE=$(tsn); say "window opens"
	apply_ov overlay-d4-a
	wait_dump agentgateway-waypoint agw-central "serviceAccount == 'orchestrator'" present
	readings applied
	for i in 1 2 3 4 5; do
		job "d4a-${RUN_ID}-lg-$i" "$WORKER_URL" "" ""
		job "d4a-${RUN_ID}-fwd-$i" "$ORCH_URL" "" ""
	done
	sleep 3
	logs_since "$SINCE" a-in-force
	remove_ov overlay-d4-a
	wait_dump agentgateway-waypoint agw-central "serviceAccount == 'orchestrator'" absent
	readings removed
	reset_all   # after the removal
	;;
r2)
	readings before
	reset_all
	SINCE=$(tsn); say "window opens"
	apply_ov overlay-d4-r2
	wait_dump agentgateway-ingress agentgateway-ingress "x-d4-probe" present
	readings applied
	probe_up d4-as-loadgen loadgen
	probe_up d4-as-orchestrator orchestrator
	for i in 1 2 3 4 5; do
		for k in verified unverified; do
			curl_send d4-as-loadgen "d4r-${RUN_ID}-lg-$k-go-$i" "$INGRESS_URL" worker.lab.internal "x-d4-probe: $k" send
			curl_send d4-as-loadgen "d4r-${RUN_ID}-lg-$k-py-$i" "$INGRESS_URL" agentgateway-ingress.agentgateway-ingress.svc.cluster.local "x-d4-probe: $k" send
		done
		curl_send d4-as-orchestrator "d4r-${RUN_ID}-orch-unverified-go-$i" "$INGRESS_URL" worker.lab.internal "x-d4-probe: unverified" send
	done
	sleep 3
	logs_since "$SINCE" r2-in-force
	remove_ov overlay-d4-r2
	wait_dump agentgateway-ingress agentgateway-ingress "x-d4-probe" absent
	readings removed
	reset_all
	;;
xa)
	# D-3's overlay, unedited, applied from its own record; the fixture at its deployed setting (deny)
	XR=experiments/runs/2026-09-24-d3-extauthz
	readings before
	reset_all
	resolve_image
	say "extauthz setting: $(kubectl -n "$NS" get deploy extauthz -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXTAUTHZ_UNDECIDABLE")].value}') pod $(kubectl -n "$NS" get pod -l app=extauthz -o jsonpath='{.items[0].metadata.name} sa={.items[0].spec.serviceAccountName}')"
	SINCE=$(tsn); say "window opens"
	rec "$D/apply-overlay-d3-extauthz.txt" "kubectl apply -k $XR/overlay-d3-extauthz"; say "applied $XR/overlay-d3-extauthz"
	wait_dump agentgateway-ingress agentgateway-ingress "extAuthz" present
	readings applied
	for i in 1 2 3 4 5; do
		job "d4x-${RUN_ID}-go-$i" "$INGRESS_URL" target worker.lab.internal
		job "d4x-${RUN_ID}-py-$i" "$ORCH_URL" "" ""
	done
	sleep 3
	logs_since "$SINCE" xa-in-force
	kubectl -n "$NS" logs deploy/extauthz --since-time="$SINCE" 2>/dev/null | jq -R -c 'fromjson? | select(.ledger != null)' > "$D/extauthz-decisions.jsonl"
	say "extauthz decision lines: $(grep -c '' "$D/extauthz-decisions.jsonl"); source_principal values: $(jq -r '.source_principal // "<absent>" | if . == "" then "<empty>" else . end' "$D/extauthz-decisions.jsonl" | sort | uniq -c | tr '\n' ';')"
	rec "$D/remove-overlay-d3-extauthz.txt" "kubectl delete -k $XR/overlay-d3-extauthz"; say "removed $XR/overlay-d3-extauthz"
	wait_dump agentgateway-ingress agentgateway-ingress "extAuthz" absent
	readings removed
	reset_all
	;;
*) echo "unknown phase $PHASE" >&2; exit 1 ;;
esac
