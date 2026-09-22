#!/usr/bin/env bash
# Experiment B, step B-5a: what each way of removing a proxy does to an OPEN stream, measured before B-5b uses it
# (the author's note of 2026-09-20 in docs/proposal-notes.md, D5: "what each method does to an open stream is measured
# first -- a graceful delete, a forced delete and a rollout -- and the experiment then uses the forced delete").
#
# ONE VARIANT PER INVOCATION, run as a background driver on the cluster B-4 built (that record's build.txt); no
# deployed path changed, so no rebuild. A variant is one proxy and one removal method:
#
#   bash rows.sh <ingress|central> <graceful|forced|rollout> <reps>   RUN_ID=<nonce> RUNREL=<run dir name> required
#
# Per repetition, ONE open stream and NO resubscription and NO cancel (B-4's CANCEL_AFTER_MS stays empty; the PROXY
# is what ends the stream, or the task finishes first and it ends normally -- both are readings):
#   - the mock is reset and armed {mode: delay, lwi, delay_ms: N} for this work item, so the Task's one model call
#     holds N and the stream stays open across the removal;
#   - `kubectl logs -f` on the proxy pod that is about to be removed is started BEFORE anything is sent, so the pod's
#     own access lines and its drain lines survive the pod (a deleted pod's log cannot be read afterwards);
#   - Job 1 sends ONE SendStreamingMessage (MODE=stream), through the agentgateway ingress with the author's Host
#     setting of 2026-09-22 (CLIENT_DIAL=target, CLIENT_HOST=worker.lab.internal);
#   - when Job 1's OWN client lines show the status-update at TASK_STATE_WORKING -- so the stream is open and
#     carrying events, not merely applied -- the driver waits REMOVE_AFTER_MS and removes the proxy by this
#     variant's method, ONCE, stamping the command on the host clock before and after;
#   - the successor is watched through the Kubernetes API only (no request is sent to find it): the old pod's
#     deletionTimestamp, when the old pod object goes, the successor's creationTimestamp and its Ready condition;
#   - as soon as the successor is Ready, ONE probe request of the row's own kind is sent -- a second loadgen Job,
#     MODE=stream, nothing armed on the mock, so its model call answers at once -- to record the first request the
#     successor answers. One send, no retry, and it is never repeated if it fails;
#   - Job 1 is waited out whatever it does, the mock is reset, and the three ledgers are collected for the work item
#     (`make ledgers`) together with the successor's log and the captured old-pod log.
# Nothing is cancelled, resent, retried or reconnected anywhere: two Jobs, one send each, every curl --retry 0. A
# repetition that fails is recorded and never re-run. The waits below poll the Kubernetes API or read a pod log;
# they send nothing to a receiver.
#
# THE RECEIVER IS THE GO RECEIVER, and one reason is why this step has no receiver dimension at all. B-5a measures
# the STIMULUS -- the proxy and the way it is removed -- and the streaming client is the load client (a2a-go) in
# every B row by the author's note of 2026-09-20, so the client SDK does not change between receivers either. On
# B-4's measured paths the Go receiver puts each proxy on exactly ONE leg of a repetition, which is what makes each
# removal attributable: the agentgateway ingress carries the A2A stream and `agw-central` carries no A2A line of the
# Go half at all (B-4: 80 of 80 arrivals from the ingress pod, 0 from agw-central), while `agw-central` carries the
# model call. The Python receiver's card GET crosses `agw-central` as well, which would put both proxies on one
# repetition. So: removing the ingress cuts the A2A stream and nothing else; removing `agw-central` cuts the model
# leg and nothing else (the preparation's D1). B-5b runs both receivers.
#
# Standing B rules this driver keeps: the stimulus is the load client, which sends A2A-Version: 1.0; N stays under
# both callers' 60 s ceilings (the worker's MODEL_TIMEOUT_S is unset, so its default 60 s); each repetition's ledgers
# are collected as soon as it ends, before any pod log can rotate; repetitions run ONE AT A TIME, because HBONE
# tunnels are shared and concurrent streams from one client would end together (the preparation's 6.3).
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
# The lab-scoped istioctl 1.31.0 (B-4's tools.txt, re-verified in this task's tools.txt), first on PATH for this
# driver's own processes only; the host's Homebrew istioctl (1.31.1) is not used and not touched. Only read-only
# `istioctl ztunnel-config certificates` is run.
PATH="${TMPDIR%/}/b4/tools/istioctl-1.31.0:$PATH"
export PATH

PROXY="${1:-}"
METHOD="${2:-}"
REPS="${3:-}"
RUN_ID="${RUN_ID:-}"
RUNREL="${RUNREL:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
CURL_POD=b5a-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
TEMPLATE=deploy/base/loadgen-a2-job.yaml
# N: 45 000 ms, the only N this lab has measured the path to carry with no timeout set anywhere (the B-3 entry of
# 2026-09-22, "N = 45 000 ms ... leaves 15 s under the ceilings"). The reading notes say why B-5a does not raise it.
N_MS=45000
# The stream is left open REMOVE_AFTER_MS past the client's own TASK_STATE_WORKING event before the proxy is
# removed, so the model call is certainly in flight (the executor calls the model immediately after that event).
REMOVE_AFTER_MS=2000
# Ceilings on the driver's own waits. None of them sends anything.
JOB_LIMIT_S=240
WORKING_LIMIT_S=60
SUCCESSOR_LIMIT_S=300
# The collection waits for the two lines that land last (wait_settled). Once the Task has reached a terminal state
# it waits for the mock's invocation line until SETTLE_AFTER_N_S past the moment the delay itself must be over
# (the arm stamp plus N), and SETTLE_LIMIT_S bounds the whole wait whatever happens.
SETTLE_AFTER_N_S=30
SETTLE_LIMIT_S=180
COLLECT_WAIT=2
# The path, by the author's note of 2026-09-22 (the Host setting) and B-4's rows.sh.
GO_TARGET=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
GO_DIAL=target
GO_HOST=worker.lab.internal

case "$PROXY" in
ingress) PNS=agentgateway-ingress; PDEPLOY=agentgateway-ingress ;;
central) PNS=agentgateway-waypoint; PDEPLOY=agw-central ;;
*) echo "rows: proxy $PROXY is not ingress or central" >&2; exit 1 ;;
esac
case "$METHOD" in graceful | forced | rollout) ;; *) echo "rows: method $METHOD is not graceful, forced or rollout" >&2; exit 1 ;; esac
case "$REPS" in '' | *[!0-9]*) echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1 ;; esac
[ "$REPS" -ge 1 ] || { echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1; }
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "rows: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
[ -n "$RUNREL" ] || { echo "rows: RUNREL (the run directory's name) is required" >&2; exit 1; }

VARIANT="$PROXY-$METHOD"
D="experiments/runs/$RUNREL/removal/$VARIANT"
# DRY=yes: one repetition of one variant before any counted variant, to prove the stimulus and the collection on the
# cluster. It is a request on the cluster, so it is RECORDED, under the run directory's dry/, named in the entry as
# sent and not counted.
[ "${DRY:-no}" = yes ] && D="experiments/runs/$RUNREL/dry/$VARIANT"
if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
	echo "rows: $D already holds files; a variant is run once" >&2; exit 1
fi
mkdir -p "$D"
CONTROL="$D/control.txt"

ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$CONTROL"; }

say "variant $VARIANT: proxy $PNS/$PDEPLOY, method $METHOD, $REPS repetitions, RUN_ID $RUN_ID, DRY=${DRY:-no}"
say "HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null)"
say "N_MS=$N_MS REMOVE_AFTER_MS=$REMOVE_AFTER_MS; template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE"); path: TARGET_URL=$GO_TARGET CLIENT_DIAL=$GO_DIAL CLIENT_HOST=$GO_HOST CANCEL_AFTER_MS=<empty> TASK_ID=<empty>"

cleanup() {
	local rc=$?
	kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	say "variant $VARIANT driver exit=$rc"
	exit "$rc"
}
trap cleanup EXIT

# --- the between-variant proof: the cluster put back, read the way B-4's row driver read it -----------------------
kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 10800 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
post_json() { # $1 url, $2 body (may be empty) -> http code
	local args=(-sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json')
	[ -n "${2:-}" ] && args+=(-d "$2")
	kubectl -n "$NS" exec "$CURL_POD" -- curl "${args[@]}" "$1" 2>/dev/null
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

between_check() { # $1 a word saying when this reading was taken
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
		say "   deployment/$g replicas spec=$spec ready=${ready:-0} programmed=$(kubectl -n "$gns" get gateway "$gn" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}' 2>/dev/null)"
		[ "$spec" = 1 ] && [ "${ready:-0}" = 1 ] || { say "   deployment/$g is not at one ready replica"; return 1; }
	done
	say "   proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP} uid={.metadata.uid} restarts={.status.containerStatuses[0].restartCount} created={.metadata.creationTimestamp}; {end}')"
	say "   retry stanzas on HTTPRoutes: $(kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'); AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	# Nothing armed. A receiver holds its armed mode in process memory and writes no ledger line for a control call,
	# so the reading is the same one B-4's cluster-after.txt takes: the mock's own control lines decide (an inject
	# arms, a reset clears, the last line decides), and the worker's process log is read for a close-after-read that
	# could not take or close its connection -- the only trace an armed receiver leaves.
	local ctl inj res last
	ctl=$(kubectl -n "$NS" logs deploy/mockllm --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "control")')
	inj=$(printf '%s\n' "$ctl" | grep -c '/control/inject' || true)
	res=$(printf '%s\n' "$ctl" | grep -c '/control/reset' || true)
	last=$(printf '%s\n' "$ctl" | tail -1)
	say "   mock control lines: injects=$inj resets=$res; resets after the last inject: $(printf '%s\n' "$ctl" | awk '/\/control\/inject/ {n=0; next} /\/control\/reset/ {n++} END {print n+0}')"
	say "   mock last control line: $last"
	say "   worker log lines naming close-after-read: $(kubectl -n "$NS" logs deploy/worker --tail=-1 2>/dev/null | grep -c 'close-after-read' || true)"
	say "   orchestrator deployed mode: DOWNSTREAM_A2A_URL=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}') PLAN_MODEL_CALL=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAN_MODEL_CALL")].value}')"
	say "   worker model client: MODEL_TIMEOUT_S=$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_TIMEOUT_S")].value}')<- empty means unset, default 60 s; MODEL_RETRIES=$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_RETRIES")].value}')<- empty means unset, default 0"
	istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" > "$D/certificates-$when.txt" 2>&1
	if awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' "$D/certificates-$when.txt" | grep -qx true; then
		say "   certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default"
	else
		say "   certificate check: VALID CERT is not true; this driver restarts nothing -- stopping"; return 1
	fi
	say "   agent pods: $(pods_line)"
	return 0
}

pods_line() { kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}'; }

# --- the image, once for the variant -------------------------------------------------------------------------------
resolve_image() {
	local t0 t1 rc=0
	t0=$(tsn)
	IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/b5a-ko-build-$RUN_ID-$VARIANT.log") || rc=$?
	t1=$(tsn)
	{ echo "$t0 ko build --platform=linux/$(go env GOARCH) ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) -> rc=$rc"; echo "$t1 image: ${IMAGE:-<none>}"; } >> "$D/image.txt"
	case "$IMAGE" in kind.local/loadgen-*:*) ;; *) say "the image could not be resolved (rc=$rc, '$IMAGE'); stopping"; exit 1 ;; esac
	say "image resolved once for the variant: $IMAGE ($t0 -> $t1)"
}

# --- Jobs -----------------------------------------------------------------------------------------------------------
apply_job() { # $1 lwi, $2 job name, $3 MODE, $4 apply log; CANCEL_AFTER_MS and TASK_ID are always empty in B-5a
	local lwi="$1" name="$2" mode="$3" log="$4" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${GO_TARGET}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${GO_DIAL}/g" -e "s/\${CLIENT_HOST}/${GO_HOST}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}//g" -e "s/\${CANCEL_AFTER_MS}//g" \
		"$TEMPLATE" > "${log%.log}.yaml"
	if grep -q '\${' "${log%.log}.yaml" || ! grep -q "image: ${IMAGE}\$" "${log%.log}.yaml"; then
		echo "rendered Job $name has a placeholder left or not the resolved image; not applied" > "$log"; return 1
	fi
	kubectl apply -f "${log%.log}.yaml" > "$log" 2>&1 || rc=$?
	return "$rc"
}
job_state() { # $1 job name -> Complete | Failed | ""
	kubectl -n "$NS" get job "$1" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null \
		| tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1
}
wait_job() { # $1 job name -> prints the final condition, or "timeout"
	local waited=0 st
	while [ "$waited" -lt "$JOB_LIMIT_S" ]; do
		st=$(job_state "$1")
		[ -n "$st" ] && { echo "$st"; return 0; }
		sleep 1; waited=$((waited + 1))
	done
	echo timeout
}
wait_working() { # $1 job name -> prints the client event line's stamp for TASK_STATE_WORKING, or nothing
	local waited=0 t
	while :; do
		t=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null \
			| jq -R -r 'fromjson? | select(.ledger == "client" and .line == "event" and .state == "TASK_STATE_WORKING") | .ts' | head -1)
		[ -n "$t" ] && { echo "$t"; return 0; }
		sleep 0.2; waited=$((waited + 1))
		[ "$waited" -lt $((WORKING_LIMIT_S * 5)) ] || break
	done
	return 1
}

wait_settled() { # $1 lwi, $2 the repetition's start stamp, $3 steps file, $4 the arm stamp in epoch seconds
	local lwi="$1" since="$2" steps="$3" armed="$4" waited=0 term="" inv="" hard=$((SETTLE_LIMIT_S * 2))
	local invdeadline=$((armed + N_MS / 1000 + SETTLE_AFTER_N_S))
	while [ "$waited" -lt "$hard" ]; do
		[ -n "$term" ] || term=$(kubectl -n "$NS" logs deploy/worker --since-time="$since" 2>/dev/null \
			| jq -R -r --arg l "$lwi" 'fromjson? | select(.ledger == "execution" and .event == "state" and .logical_work_item_id == $l) | .state' \
			| grep -E 'TASK_STATE_(COMPLETED|FAILED|CANCELED|REJECTED)' | head -1)
		[ -n "$inv" ] || inv=$(kubectl -n "$NS" logs deploy/mockllm --since-time="$since" 2>/dev/null \
			| jq -R -r --arg l "$lwi" 'fromjson? | select(.ledger == "invocation" and .logical_work_item_id == $l) | .outcome' | head -1)
		[ -n "$term" ] && [ -n "$inv" ] && break
		[ -n "$term" ] && [ "$(date -u +%s)" -ge "$invdeadline" ] && break
		sleep 0.5; waited=$((waited + 1))
	done
	echo "$(tsn) settled after $(awk -v w="$waited" 'BEGIN{printf "%.1f", w/2}')s: terminal state=${term:-<none>} invocation outcome=${inv:-<none>} (the invocation wait ran to the arm stamp plus N plus ${SETTLE_AFTER_N_S}s at the latest, the whole wait to ${SETTLE_LIMIT_S}s; reads two pod logs, sends nothing)" >> "$steps"
}

reset_mock() { local c; c=$(post_json "$MOCK_URL/control/reset" ""); echo "$(tsn) POST $MOCK_URL/control/reset -> $c" >> "$1"; ok2xx "$c" || { say "mock reset returned $c"; exit 1; }; }
arm_delay() { # $1 lwi, $2 file
	local body c; body=$(printf '{"mode":"delay","lwi":"%s","delay_ms":%d}' "$1" "$N_MS")
	c=$(post_json "$MOCK_URL/control/inject" "$body")
	echo "$(tsn) POST $MOCK_URL/control/inject $body -> $c" >> "$2"
	ok2xx "$c" || { say "arming the mock returned $c"; exit 1; }
}

proxy_pod() { kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }
pod_fact() { # $1 pod, $2 jsonpath
	kubectl -n "$PNS" get pod "$1" -o jsonpath="$2" 2>/dev/null
}
pod_json() { kubectl -n "$PNS" get pod "$1" -o json 2>/dev/null; }

remove_proxy() { # $1 old pod name, $2 the repetition's removal log
	local old="$1" f="$2" rc=0 out=""
	case "$METHOD" in
	graceful) out=$(kubectl -n "$PNS" delete pod "$old" --wait=false 2>&1) || rc=$? ;;
	forced) out=$(kubectl -n "$PNS" delete pod "$old" --grace-period=0 --force --wait=false 2>&1) || rc=$? ;;
	rollout) out=$(kubectl -n "$PNS" rollout restart "deployment/$PDEPLOY" 2>&1) || rc=$? ;;
	esac
	printf '%s\n' "$out" >> "$f"
	return "$rc"
}

one_rep() { # $1 repetition number
	local n; n=$(printf '%02d' "$1")
	local lwi="b5a-${PROXY}-${METHOD}-${RUN_ID}-${n}"
	local d="$D/$lwi"
	local j1="loadgen-$lwi" jp="loadgen-$lwi-p"
	mkdir -p "$d"
	local steps="$d/steps.txt" rm="$d/removal.txt" since old new logpid ready="" s1="" sp=""
	since=$(tsn)
	echo "$since repetition $lwi variant=$VARIANT proxy=$PNS/$PDEPLOY method=$METHOD" >> "$steps"

	# the proxy pod that is about to be removed, and the agent pods, before anything is sent
	old=$(proxy_pod | head -1)
	[ -n "$old" ] || { say "  $lwi: no proxy pod for $PNS/$PDEPLOY; stopping"; exit 1; }
	{
		echo "$(tsn) agent pods before: $(pods_line)"
		echo "$(tsn) proxy pods before: $(kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp} restarts={.status.containerStatuses[0].restartCount}; {end}')"
		echo "$(tsn) old pod: $old grace=$(pod_fact "$old" '{.spec.terminationGracePeriodSeconds}') rs=$(pod_fact "$old" '{.metadata.ownerReferences[0].name}')"
	} >> "$steps"
	pod_json "$old" > "$d/oldpod-before.json"

	# the old pod's own log, captured from BEFORE the removal: a deleted pod's log cannot be read afterwards.
	kubectl -n "$PNS" logs -f "$old" --since-time="$since" > "$d/oldpod.log" 2>"$d/oldpod-log.err" &
	logpid=$!
	echo "$(tsn) started kubectl logs -f $old (pid $logpid)" >> "$steps"

	reset_mock "$steps"
	local armed; armed=$(date -u +%s)
	arm_delay "$lwi" "$steps"
	echo "$(tsn) apply Job 1 $j1 MODE=stream TASK_ID=<empty> CANCEL_AFTER_MS=<empty>" >> "$steps"
	apply_job "$lwi" "$j1" stream "$d/apply-1.log" || echo "$(tsn) Job 1 apply rc=$?" >> "$steps"
	echo "$(tsn) Job 1 applied" >> "$steps"

	local tworking
	tworking=$(wait_working "$j1") || tworking=""
	echo "$(tsn) Job 1's client saw TASK_STATE_WORKING at ${tworking:-<none within ${WORKING_LIMIT_S}s>} (client pod clock)" >> "$steps"
	if [ -z "$tworking" ]; then
		echo "$(tsn) NO WORKING EVENT: the proxy is NOT removed in this repetition" >> "$steps"
		say "  $lwi: no TASK_STATE_WORKING event within ${WORKING_LIMIT_S}s; nothing removed, repetition recorded as such"
	else
		sleep "$(awk -v m="$REMOVE_AFTER_MS" 'BEGIN{printf "%.3f", m/1000}')"
		local t_rm_start t_rm_done
		t_rm_start=$(tsn)
		echo "$t_rm_start REMOVAL COMMAND START method=$METHOD pod=$old (host clock)" >> "$rm"
		remove_proxy "$old" "$rm"
		t_rm_done=$(tsn)
		echo "$t_rm_done REMOVAL COMMAND DONE (host clock)" >> "$rm"
		echo "$(tsn) removal issued: $METHOD on $old" >> "$steps"
		# the old pod's deletionTimestamp, read at once (API-server clock; empty when the object is already gone)
		echo "$(tsn) old pod deletionTimestamp=$(pod_fact "$old" '{.metadata.deletionTimestamp}') (API-server clock, second resolution; empty means the object was already gone or none was set)" >> "$rm"
		# Watch the successor and the old pod through the Kubernetes API only; nothing is sent to find them. The ONE
		# probe of the row's own kind goes out inside this loop, the moment the successor is first seen Ready, so
		# that "seconds until the successor serves" is not lengthened by the old pod's own drain: a graceful
		# removal keeps the old pod alive for its whole grace, long after the successor is serving.
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
					echo "$(tsn) apply probe Job $jp MODE=stream, nothing armed on the mock" >> "$steps"
					apply_job "$lwi-p" "$jp" stream "$d/apply-probe.log" || echo "$(tsn) probe apply rc=$?" >> "$steps"
					echo "$(tsn) probe Job applied" >> "$steps"
				fi
			fi
			[ -n "$oldgone" ] && [ -n "$newready" ] && break
			sleep 0.2; waited=$((waited + 1))
		done
		[ -n "$newname" ] || echo "$(tsn) NO successor pod within ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		[ -n "$newready" ] || { echo "$(tsn) successor NOT Ready within ${SUCCESSOR_LIMIT_S}s; NO probe was sent" >> "$rm"; echo "$(tsn) successor never Ready; NO probe was sent" >> "$steps"; }
		[ -n "$oldgone" ] || echo "$(tsn) old pod object still present after ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		echo "$newname" > "$d/successor.txt"
	fi

	s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
	if kubectl -n "$NS" get job "$jp" >/dev/null 2>&1; then sp=$(wait_job "$jp"); echo "$(tsn) probe Job $sp" >> "$steps"; fi
	# The stream can end long before the Task and the model call do -- that is the whole point of B-4's control -- so
	# the collection waits for the two lines that land last: the executor's terminal state line for this work item,
	# and the mock's invocation line, which a delay mode writes only when the delay is over. Without this wait the
	# dry repetition collected 13 s too early and had no invocation line and no final state (reading notes). It
	# reads two pod logs and sends nothing.
	wait_settled "$lwi" "$since" "$steps" "$armed"
	reset_mock "$steps"

	# collection
	sleep "$COLLECT_WAIT"
	kill "$logpid" 2>/dev/null || true
	wait "$logpid" 2>/dev/null || true
	echo "$(tsn) old-pod log capture stopped ($(wc -l < "$d/oldpod.log" | tr -d ' ') lines)" >> "$steps"
	new=$(cat "$d/successor.txt" 2>/dev/null)
	if [ -n "$new" ]; then
		# Only the successor's own stamped log lines: a proxy prints its whole running configuration at startup as
		# one multi-line entry, which would put ~140 unstamped lines in every repetition's record. The header line
		# of that entry is kept; the configuration itself is read once per proxy into drain-defaults.txt.
		kubectl -n "$PNS" logs "$new" --tail=-1 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z\t' > "$d/newpod.log" || true
		pod_json "$new" > "$d/newpod-after.json"
	fi
	# the OTHER proxy's access lines for the repetition's window: it stayed up, and for the central variants it is
	# the ingress that carried the A2A stream (and the other way round).
	case "$PROXY" in
	ingress) kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/otherproxy-access.txt" || true ;;
	central) kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/otherproxy-access.txt" || true ;;
	esac
	local rc=0
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$d" >/dev/null 2>"$d/ledgers-stderr.txt" || rc=$?
	echo "$(tsn) make ledgers LWI=$lwi exit=$rc" >> "$steps"
	# the probe's own work item is <lwi>-p; its client lines and ledgers are collected apart
	if kubectl -n "$NS" get job "$jp" >/dev/null 2>&1; then
		mkdir -p "$d/probe"
		make --no-print-directory ledgers "LWI=$lwi-p" "OUT=$d/probe" >/dev/null 2>"$d/probe/ledgers-stderr.txt" || true
	fi
	for j in "$j1" "$jp"; do
		kubectl -n "$NS" get job "$j" >/dev/null 2>&1 || continue
		echo "$j $(kubectl -n "$NS" get job "$j" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pod-created=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null) container-started=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$j" --no-headers 2>/dev/null | wc -l | tr -d ' ')" >> "$d/jobs.txt"
	done
	{
		echo "$(tsn) agent pods after: $(pods_line)"
		echo "$(tsn) proxy pods after: $(kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp} ready={range .status.conditions[?(@.type=="Ready")]}{.status}{end}; {end}')"
	} >> "$steps"
	echo "$(tsn) collected" >> "$steps"
	say "  $lwi job1=$s1${sp:+ probe=$sp} old=$old new=${new:-<none>} ingress-ledger=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$d/client.jsonl" 2>/dev/null | tr -d ' ')"
}

between_check "before" || { say "the cluster was not put back before this variant; stopping"; exit 1; }
resolve_image
say "== variant $VARIANT: $REPS repetitions, one at a time"
for i in $(seq 1 "$REPS"); do one_rep "$i"; done
reset_mock "$CONTROL"
between_check "after" || { say "the cluster is NOT put back after this variant"; exit 1; }
say "== variant $VARIANT done"
