#!/usr/bin/env bash
# Follow-on D-1: the Python-client row. The a2a-python SDK as the RECONNECTING client, the author's note of
# 2026-09-24 ("one row with the Python SDK as the reconnecting client -- the orchestrator's forwarder resubscribes once
# after losing its stream -- which reverses, for that row only, the choice that the load client is the streaming
# client in every row"), per the preparation's D2 and its section 4(c).
#
# THE STREAM UNDER TEST is the orchestrator's forward to the worker, with FORWARD_RESUBSCRIBE=on
# (agents/orchestrator/orchestrator/forward.py): one SendStreamingMessage and, if that stream ends without a terminal
# event, EXACTLY ONE SubscribeToTask for its task, sent by the orchestrator itself, never more. Nothing in this driver
# sends a resubscription: the SDK client inside the orchestrator does, once, or not at all.
#
# THE PROXY ON THAT PATH. The orchestrator's DOWNSTREAM_A2A_URL is the worker's Service, so the forward crosses
# agw-central, the waypoint of both agent namespaces and the egress to the model -- the proxy that also carries the
# worker's model call. Removing it therefore cuts both legs of this row at once. The author's ruling for agw-central
# (B-5b, companion entry) is the GRACEFUL delete, and this row uses it for the reason given there: under the forced
# delete B-5a measured the model leg dead and the Task already TASK_STATE_FAILED at 2 055-2 079 ms, before the
# successor was Ready at 2 115-2 511 ms, so there would be no window at all; the graceful delete keeps the old pod
# serving open connections until its drain ends them (B-5a: 10.0 s after SIGTERM, "hbone error: drain timeout") while
# the successor is Ready in about 2 s. On THIS row the stream and the model call are on the same proxy, so both are
# expected to end together at the drain; whether the one resubscription then reaches a running task or a terminal
# one is what the row counts, from parsed stamps joined on identity, and is not assumed here.
#
# THE STIMULUS. Per repetition, the mock reset and armed {mode: delay, lwi, delay_ms: 45000}; kubectl logs -f on the
# agw-central pod about to be removed started BEFORE anything is sent; ONE load-client Job sends ONE unary SendMessage
# to the orchestrator's Service (B-4's Python path: CLIENT_DIAL and CLIENT_HOST empty, so the card GET crosses
# lab/orchestrator on agw-central and the POST goes where the card points, the ingress's lab/orchestrator-ingress,
# which this row does not touch); when the ORCHESTRATOR's own forward line shows the status-update at
# TASK_STATE_WORKING, the driver waits 2 000 ms (B-5b's offset) and deletes the agw-central pod gracefully, ONCE,
# stamping the command on the host clock; the successor is watched through the Kubernetes API alone; nothing else is
# sent. N = 45 000 ms, no caller ceiling moved: the worker's model client 60 s (MODEL_TIMEOUT_S unset), the forward's
# httpx read timeout 90 s, the load client's 90 s.
#
# Nothing is cancelled, resent, retried or reconnected by this driver: one Job, one send, every curl --retry 0. A
# repetition that fails is recorded and never re-run. The waits poll the Kubernetes API or read pod logs.
#
#   bash pyclient.sh <reps>   RUN_ID=<nonce> RUNREL=<run dir name> required; DRY=yes writes under dry/
#
# The setting is switched on once for the row with kubectl set env and restored EMPTY by the EXIT trap, with the
# orchestrator's rollout waited for both times. Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/d1/tools/istioctl-1.31.0:$PATH"
export PATH

REPS="${1:-}"
RUN_ID="${RUN_ID:-}"
RUNREL="${RUNREL:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
CURL_POD=d1-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
TEMPLATE=deploy/base/loadgen-a2-job.yaml
N_MS=45000
REMOVE_AFTER_MS=2000
PNS=agentgateway-waypoint
PDEPLOY=agw-central
JOB_LIMIT_S=240
WORKING_LIMIT_S=60
SUCCESSOR_LIMIT_S=300
SETTLE_AFTER_N_S=30
SETTLE_LIMIT_S=180
COLLECT_WAIT=2

case "$REPS" in '' | *[!0-9]*) echo "pyclient: REPS=$REPS is not a positive integer" >&2; exit 1 ;; esac
[ "$REPS" -ge 1 ] || { echo "pyclient: REPS=$REPS is not a positive integer" >&2; exit 1; }
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "pyclient: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
[ -n "$RUNREL" ] || { echo "pyclient: RUNREL (the run directory's name) is required" >&2; exit 1; }

VARIANT=pyclient-central-graceful
D="experiments/runs/$RUNREL/rows/$VARIANT"
[ "${DRY:-no}" = yes ] && D="experiments/runs/$RUNREL/dry/$VARIANT"
if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
	echo "pyclient: $D already holds files; a variant is run once" >&2; exit 1
fi
mkdir -p "$D"
CONTROL="$D/control.txt"

ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$CONTROL"; }
orch_env() { kubectl -n "$NS" get deployment/orchestrator -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }

say "variant $VARIANT: the orchestrator's forward to the worker, FORWARD_RESUBSCRIBE=on, $PNS/$PDEPLOY removed gracefully, $REPS repetitions, RUN_ID $RUN_ID, DRY=${DRY:-no}"
say "HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null)"
say "N_MS=$N_MS REMOVE_AFTER_MS=$REMOVE_AFTER_MS; template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE"); path: TARGET_URL=$ORCH_URL CLIENT_DIAL=<empty> CLIENT_HOST=<empty> MODE=<empty, unary SendMessage>"

RESTORE=no
cleanup() {
	local rc=$?
	kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$RESTORE" = yes ]; then
		local s=0 r=0
		kubectl -n "$NS" set env deployment/orchestrator FORWARD_RESUBSCRIBE= >/dev/null 2>&1 || s=$?
		kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || r=$?
		if [ "$s" = 0 ] && [ "$r" = 0 ] && [ -z "$(orch_env FORWARD_RESUBSCRIBE)" ]; then
			say "restored: FORWARD_RESUBSCRIBE=[$(orch_env FORWARD_RESUBSCRIBE)] on deployment/orchestrator (set env rc=0, rollout rc=0)"
		else
			say "RESTORE FAILED (set env rc=$s, rollout rc=$r): FORWARD_RESUBSCRIBE is to be put back empty"
			rc=1
		fi
	fi
	say "variant $VARIANT driver exit=$rc"
	exit "$rc"
}
trap cleanup EXIT

kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 10800 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
post_json() {
	local args=(-sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json')
	[ -n "${2:-}" ] && args+=(-d "$2")
	kubectl -n "$NS" exec "$CURL_POD" -- curl "${args[@]}" "$1" 2>/dev/null
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
pods_line() { kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}'; }

between_check() { # B-5b's between-variant proof, the same readings
	local when="$1" dep spec ready
	say "-- between-variant proof ($when) --"
	for dep in worker orchestrator mockllm; do
		spec=$(kubectl -n "$NS" get "deployment/$dep" -o jsonpath='{.spec.replicas}')
		ready=$(kubectl -n "$NS" get "deployment/$dep" -o jsonpath='{.status.readyReplicas}')
		say "   deployment/$dep replicas spec=$spec ready=${ready:-0}"
		[ "$spec" = 1 ] && [ "${ready:-0}" = 1 ] || { say "   deployment/$dep is not at one ready replica"; return 1; }
	done
	for g in "agentgateway-ingress/agentgateway-ingress" "agentgateway-waypoint/agw-central"; do
		local gns="${g%%/*}" gn="${g##*/}"
		spec=$(kubectl -n "$gns" get "deployment/$gn" -o jsonpath='{.spec.replicas}' 2>/dev/null)
		ready=$(kubectl -n "$gns" get "deployment/$gn" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
		say "   deployment/$g replicas spec=$spec ready=${ready:-0} generation=$(kubectl -n "$gns" get deployment "$gn" -o jsonpath='{.metadata.generation}' 2>/dev/null) programmed=$(kubectl -n "$gns" get gateway "$gn" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}' 2>/dev/null)"
		[ "$spec" = 1 ] && [ "${ready:-0}" = 1 ] || { say "   deployment/$g is not at one ready replica"; return 1; }
	done
	say "   proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP} uid={.metadata.uid} restarts={.status.containerStatuses[0].restartCount} created={.metadata.creationTimestamp}; {end}')"
	say "   retry stanzas on HTTPRoutes: $(kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'); AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	local ctl
	ctl=$(kubectl -n "$NS" logs deploy/mockllm --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "control")')
	say "   mock control lines: injects=$(printf '%s\n' "$ctl" | grep -c '/control/inject' || true) resets=$(printf '%s\n' "$ctl" | grep -c '/control/reset' || true); resets after the last inject: $(printf '%s\n' "$ctl" | awk '/\/control\/inject/ {n=0; next} /\/control\/reset/ {n++} END {print n+0}')"
	say "   orchestrator: DOWNSTREAM_A2A_URL=$(orch_env DOWNSTREAM_A2A_URL) PLAN_MODEL_CALL=$(orch_env PLAN_MODEL_CALL) MODEL_MAX_RETRIES=$(orch_env MODEL_MAX_RETRIES) FORWARD_RESUBSCRIBE=[$(orch_env FORWARD_RESUBSCRIBE)] LEDGER_HEADERS=[$(orch_env LEDGER_HEADERS)] REFUSE_OPERATION=[$(orch_env REFUSE_OPERATION)] CLIENT_SDK_RESEND=[$(orch_env CLIENT_SDK_RESEND)] CLIENT_TRANSPORT_RESEND=[$(orch_env CLIENT_TRANSPORT_RESEND)] CLIENT_RETRIES=[$(orch_env CLIENT_RETRIES)]"
	say "   worker model client: MODEL_TIMEOUT_S=[$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_TIMEOUT_S")].value}')] MODEL_RETRIES=[$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_RETRIES")].value}')] (empty is unset: 60 s, no retry)"
	istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" > "$D/certificates-$when.txt" 2>&1
	if awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' "$D/certificates-$when.txt" | grep -qx true; then
		say "   certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default"
	else
		say "   certificate check: VALID CERT is not true; this driver restarts nothing -- stopping"; return 1
	fi
	say "   agent pods: $(pods_line)"
}

switch_on() {
	local pre; pre=$(orch_env FORWARD_RESUBSCRIBE)
	say "orchestrator before: DOWNSTREAM_A2A_URL=$(orch_env DOWNSTREAM_A2A_URL) FORWARD_RESUBSCRIBE=[$pre]"
	[ -n "$(orch_env DOWNSTREAM_A2A_URL)" ] || { say "the orchestrator is not in forward mode; stopping"; exit 1; }
	[ -z "$pre" ] || { say "FORWARD_RESUBSCRIBE is not empty before the row; stopping"; exit 1; }
	[ "$(orch_env PLAN_MODEL_CALL)" = off ] || { say "PLAN_MODEL_CALL is not off; stopping"; exit 1; }
	RESTORE=yes
	kubectl -n "$NS" set env deployment/orchestrator FORWARD_RESUBSCRIBE=on >/dev/null
	kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null || { say "rollout with FORWARD_RESUBSCRIBE=on failed"; exit 1; }
	# the previous pod's object must be gone, so orch_pod can only name the pod that carries the setting
	local w=0
	while [ "$(kubectl -n "$NS" get pods -l app=orchestrator --no-headers 2>/dev/null | wc -l | tr -d ' ')" != 1 ] && [ "$w" -lt 120 ]; do sleep 1; w=$((w + 1)); done
	[ "$(kubectl -n "$NS" get pods -l app=orchestrator --no-headers | wc -l | tr -d ' ')" = 1 ] || { say "more than one orchestrator pod after the rollout; stopping"; exit 1; }
	[ "$(kubectl -n "$NS" get pod "$(orch_pod)" -o jsonpath='{.spec.containers[0].env[?(@.name=="FORWARD_RESUBSCRIBE")].value}')" = on ] || { say "the running orchestrator pod does not carry FORWARD_RESUBSCRIBE=on; stopping"; exit 1; }
	say "FORWARD_RESUBSCRIBE=[$(orch_env FORWARD_RESUBSCRIBE)] on deployment/orchestrator; pod $(kubectl -n "$NS" get pods -l app=orchestrator --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name} uid {.metadata.uid}; {end}')"
}

resolve_image() {
	local t0 t1 rc=0
	t0=$(tsn)
	IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d1/work/ko-build-$RUN_ID-$VARIANT.log") || rc=$?
	t1=$(tsn)
	{ echo "$t0 ko build --platform=linux/$(go env GOARCH) ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) -> rc=$rc"; echo "$t1 image: ${IMAGE:-<none>}"; } >> "$D/image.txt"
	case "$IMAGE" in kind.local/loadgen-*:*) ;; *) say "the image could not be resolved (rc=$rc, '$IMAGE'); stopping"; exit 1 ;; esac
	say "image resolved once for the variant: $IMAGE ($t0 -> $t1)"
}

apply_job() { # $1 lwi, $2 job name, $3 apply log -- B-5b's rendering, MODE and TASK_ID and CANCEL_AFTER_MS empty
	local lwi="$1" name="$2" log="$3" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${ORCH_URL}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}//g" -e "s/\${CLIENT_HOST}//g" \
		-e "s/\${MODE}//g" -e "s/\${TASK_ID}//g" -e "s/\${CANCEL_AFTER_MS}//g" \
		"$TEMPLATE" > "${log%.log}.yaml"
	if grep -q '\${' "${log%.log}.yaml" || ! grep -q "image: ${IMAGE}\$" "${log%.log}.yaml"; then
		echo "rendered Job $name has a placeholder left or not the resolved image; not applied" > "$log"; return 1
	fi
	kubectl apply -f "${log%.log}.yaml" > "$log" 2>&1 || rc=$?
	return "$rc"
}
job_state() {
	kubectl -n "$NS" get job "$1" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null \
		| tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1
}
wait_job() {
	local waited=0 st
	while [ "$waited" -lt "$JOB_LIMIT_S" ]; do
		st=$(job_state "$1")
		[ -n "$st" ] && { echo "$st"; return 0; }
		sleep 1; waited=$((waited + 1))
	done
	echo timeout
}
orch_pod() { kubectl -n "$NS" get pods -l app=orchestrator --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
wait_forward_working() { # $1 lwi, $2 since -> "<ts> <taskId>" off the orchestrator's own forward event line
	local waited=0 line
	while :; do
		line=$(kubectl -n "$NS" logs "pod/$(orch_pod)" --since-time="$2" 2>/dev/null \
			| jq -R -r --arg l "$1" 'fromjson? | select(.ledger == "forward" and .line == "event" and .logical_work_item_id == $l and .state == "TASK_STATE_WORKING") | "\(.ts) \(.taskId)"' | head -1)
		case "$line" in ?*" "?*) echo "$line"; return 0 ;; esac
		sleep 0.2; waited=$((waited + 1))
		[ "$waited" -lt $((WORKING_LIMIT_S * 5)) ] || break
	done
	return 1
}
forward_now() { # $1 lwi, $2 since -> what the orchestrator's forward lines say at this moment
	kubectl -n "$NS" logs "pod/$(orch_pod)" --since-time="$2" 2>/dev/null \
		| jq -R -r --arg l "$1" 'fromjson? | select(.ledger == "forward" and .line == "end" and .logical_work_item_id == $l) | "\(.operation) end \(.stream_end)"' | tr '\n' ';'
}
wait_settled() { # B-5b's, reading the WORKER's terminal state line and the mock's invocation line; sends nothing
	local lwi="$1" since="$2" steps="$3" armed="$4" waited=0 term="" oterm="" inv="" hard=$((SETTLE_LIMIT_S * 2))
	local invdeadline=$((armed + N_MS / 1000 + SETTLE_AFTER_N_S))
	while [ "$waited" -lt "$hard" ]; do
		[ -n "$term" ] || term=$(kubectl -n "$NS" logs deploy/worker --since-time="$since" 2>/dev/null \
			| jq -R -r --arg l "$lwi" 'fromjson? | select(.ledger == "execution" and .event == "state" and .logical_work_item_id == $l) | .state' \
			| grep -E 'TASK_STATE_(COMPLETED|FAILED|CANCELED|REJECTED)' | head -1)
		[ -n "$oterm" ] || oterm=$(kubectl -n "$NS" logs deploy/orchestrator --since-time="$since" 2>/dev/null \
			| jq -R -r --arg l "$lwi" 'fromjson? | select(.ledger == "execution" and .event == "state" and .logical_work_item_id == $l) | .state' \
			| grep -E 'TASK_STATE_(COMPLETED|FAILED|CANCELED|REJECTED)' | head -1)
		[ -n "$inv" ] || inv=$(kubectl -n "$NS" logs deploy/mockllm --since-time="$since" 2>/dev/null \
			| jq -R -r --arg l "$lwi" 'fromjson? | select(.ledger == "invocation" and .logical_work_item_id == $l) | .outcome' | head -1)
		[ -n "$term" ] && [ -n "$oterm" ] && [ -n "$inv" ] && break
		[ -n "$term" ] && [ -n "$oterm" ] && [ "$(date -u +%s)" -ge "$invdeadline" ] && break
		sleep 0.5; waited=$((waited + 1))
	done
	echo "$(tsn) settled after $(awk -v w="$waited" 'BEGIN{printf "%.1f", w/2}')s: worker terminal state=${term:-<none>} orchestrator terminal state=${oterm:-<none>} invocation outcome=${inv:-<none>} (reads pod logs, sends nothing)" >> "$steps"
}
reset_mock() { local c; c=$(post_json "$MOCK_URL/control/reset" ""); echo "$(tsn) POST $MOCK_URL/control/reset -> $c" >> "$1"; ok2xx "$c" || { say "mock reset returned $c"; exit 1; }; }
arm_delay() {
	local body c; body=$(printf '{"mode":"delay","lwi":"%s","delay_ms":%d}' "$1" "$N_MS")
	c=$(post_json "$MOCK_URL/control/inject" "$body")
	echo "$(tsn) POST $MOCK_URL/control/inject $body -> $c" >> "$2"
	ok2xx "$c" || { say "arming the mock returned $c"; exit 1; }
}
proxy_pod() { kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }
pod_fact() { kubectl -n "$PNS" get pod "$1" -o jsonpath="$2" 2>/dev/null; }
pod_json() { kubectl -n "$PNS" get pod "$1" -o json 2>/dev/null; }

one_rep() {
	local n; n=$(printf '%02d' "$1")
	local lwi="d1-pyc-central-graceful-${RUN_ID}-${n}"
	local d="$D/$lwi" j1="loadgen-$lwi"
	mkdir -p "$d"
	local steps="$d/steps.txt" rm="$d/removal.txt" since old new logpid s1="" tid="" opod
	since=$(tsn)
	opod=$(orch_pod)
	echo "$since repetition $lwi variant=$VARIANT orchestrator=$opod proxy=$PNS/$PDEPLOY method=graceful target=$ORCH_URL" >> "$steps"
	old=$(proxy_pod | head -1)
	[ -n "$old" ] || { say "  $lwi: no proxy pod for $PNS/$PDEPLOY; stopping"; exit 1; }
	{
		echo "$(tsn) agent pods before: $(pods_line)"
		echo "$(tsn) proxy pods before: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp} restarts={.status.containerStatuses[0].restartCount}; {end}')"
		echo "$(tsn) old pod: $old ip=$(pod_fact "$old" '{.status.podIP}') grace=$(pod_fact "$old" '{.spec.terminationGracePeriodSeconds}') rs=$(pod_fact "$old" '{.metadata.ownerReferences[0].name}')"
	} >> "$steps"
	pod_json "$old" > "$d/oldpod-before.json"
	kubectl -n "$PNS" logs -f "$old" --since-time="$since" > "$d/oldpod.log" 2>"$d/oldpod-log.err" &
	logpid=$!
	echo "$(tsn) started kubectl logs -f $old (pid $logpid)" >> "$steps"
	reset_mock "$steps"
	local armed; armed=$(date -u +%s)
	arm_delay "$lwi" "$steps"
	echo "$(tsn) apply Job $j1 MODE=<empty> (one unary SendMessage to the orchestrator)" >> "$steps"
	apply_job "$lwi" "$j1" "$d/apply-1.log" || echo "$(tsn) Job apply rc=$?" >> "$steps"
	echo "$(tsn) Job applied" >> "$steps"
	local working tworking
	working=$(wait_forward_working "$lwi" "$since") || working=""
	tworking="${working%% *}"; tid="${working#* }"
	[ -n "$working" ] || { tworking=""; tid=""; }
	echo "$(tsn) the orchestrator's forward saw TASK_STATE_WORKING at ${tworking:-<none within ${WORKING_LIMIT_S}s>} (orchestrator pod clock) naming the worker's task ${tid:-<none>}" >> "$steps"
	if [ -z "$tworking" ]; then
		echo "$(tsn) NO WORKING EVENT on the forward: the proxy is NOT removed in this repetition" >> "$steps"
		say "  $lwi: no forward TASK_STATE_WORKING event within ${WORKING_LIMIT_S}s; nothing removed, repetition recorded as such"
	else
		sleep "$(awk -v m="$REMOVE_AFTER_MS" 'BEGIN{printf "%.3f", m/1000}')"
		local t_rm_start t_rm_done out rc=0
		t_rm_start=$(tsn)
		echo "$t_rm_start REMOVAL COMMAND START method=graceful pod=$old (host clock)" >> "$rm"
		out=$(kubectl -n "$PNS" delete pod "$old" --wait=false 2>&1) || rc=$?
		printf '%s\n' "$out" >> "$rm"
		t_rm_done=$(tsn)
		echo "$t_rm_done REMOVAL COMMAND DONE rc=$rc (host clock)" >> "$rm"
		echo "$(tsn) old pod deletionTimestamp=$(pod_fact "$old" '{.metadata.deletionTimestamp}') (API-server clock, second resolution)" >> "$rm"
		local waited=0 oldgone="" newname="" newready=""
		while [ "$waited" -lt $((SUCCESSOR_LIMIT_S * 5)) ]; do
			if [ -z "$oldgone" ] && ! kubectl -n "$PNS" get pod "$old" >/dev/null 2>&1; then
				oldgone=$(tsn); echo "$oldgone old pod object gone (driver observation, host clock)" >> "$rm"
			fi
			if [ -z "$newname" ]; then
				newname=$(proxy_pod | grep -vx "$old" | head -1)
				[ -n "$newname" ] && echo "$(tsn) successor pod appeared: $newname created=$(pod_fact "$newname" '{.metadata.creationTimestamp}') (driver observation, host clock; created is the API-server clock)" >> "$rm"
			fi
			if [ -n "$newname" ] && [ -z "$newready" ]; then
				if [ "$(pod_fact "$newname" '{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')" = True ]; then
					newready=$(tsn)
					echo "$newready successor Ready (driver observation, host clock); Ready lastTransitionTime=$(pod_fact "$newname" '{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{end}') (API-server clock); ip=$(pod_fact "$newname" '{.status.podIP}')" >> "$rm"
					echo "$(tsn) THE FORWARD AT THIS MOMENT: $(forward_now "$lwi" "$since")<- empty means no end line yet" >> "$rm"
				fi
			fi
			[ -n "$oldgone" ] && [ -n "$newready" ] && break
			sleep 0.2; waited=$((waited + 1))
		done
		[ -n "$newname" ] || echo "$(tsn) NO successor pod within ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		[ -n "$newready" ] || echo "$(tsn) successor NOT Ready within ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		[ -n "$oldgone" ] || echo "$(tsn) old pod object still present after ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		echo "$newname" > "$d/successor.txt"
	fi
	s1=$(wait_job "$j1"); echo "$(tsn) Job $s1" >> "$steps"
	wait_settled "$lwi" "$since" "$steps" "$armed"
	reset_mock "$steps"
	sleep "$COLLECT_WAIT"
	kill "$logpid" 2>/dev/null || true
	wait "$logpid" 2>/dev/null || true
	echo "$(tsn) old-pod log capture stopped ($(wc -l < "$d/oldpod.log" | tr -d ' ') lines)" >> "$steps"
	new=$(cat "$d/successor.txt" 2>/dev/null)
	if [ -n "$new" ]; then
		kubectl -n "$PNS" logs "$new" --tail=-1 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z\t' > "$d/newpod.log" || true
		pod_json "$new" > "$d/newpod-after.json"
	fi
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/otherproxy-access.txt" || true
	# the orchestrator's own forward lines for this work item: the row's client record
	kubectl -n "$NS" logs "pod/$opod" --since-time="$since" 2>/dev/null \
		| jq -R -c --arg l "$lwi" 'fromjson? | select(.ledger == "forward" and .logical_work_item_id == $l)' > "$d/forward.jsonl" || true
	local rc=0
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$d" >/dev/null 2>"$d/ledgers-stderr.txt" || rc=$?
	echo "$(tsn) make ledgers LWI=$lwi exit=$rc" >> "$steps"
	echo "$j1 $(kubectl -n "$NS" get job "$j1" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j1" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$j1" --no-headers 2>/dev/null | wc -l | tr -d ' ')" >> "$d/jobs.txt"
	{
		echo "$(tsn) agent pods after: $(pods_line)"
		echo "$(tsn) proxy pods after: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp}; {end}')"
	} >> "$steps"
	echo "$(tsn) collected" >> "$steps"
	say "  $lwi job=$s1 task=${tid:-<none>} old=$old new=${new:-<none>} forward=$(wc -l < "$d/forward.jsonl" | tr -d ' ') ingress=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ')"
}

between_check "before" || { say "the cluster was not put back before this variant; stopping"; exit 1; }
switch_on
resolve_image
say "== variant $VARIANT: $REPS repetitions, one at a time"
for i in $(seq 1 "$REPS"); do one_rep "$i"; done
reset_mock "$CONTROL"
between_check "after" || { say "the cluster is NOT put back after this variant"; exit 1; }
say "== variant $VARIANT done"
