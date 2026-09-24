#!/usr/bin/env bash
# Follow-on D-1: B-5b's rollout variant -- the agentgateway ingress removed under an open stream by
# kubectl rollout restart of its Deployment, and ONE SubscribeToTask after it -- per receiver x20, on the lab's
# current topology (one default ServiceAccount, no A2A marking), so its rows are comparable with B-5b's main rows.
# The author's note of 2026-09-24 adds it ("B gains the rollout variant the note of 2026-09-20 allowed if it fits").
#
# This is experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh with exactly these changes, and nothing else:
#   - this header;
#   - the one pairing it accepts is ingress-rollout (B-5b's two ruled pairings, ingress-forced and central-graceful,
#     are refused here: they are B-5b's rows, not this one's);
#   - remove_proxy's rollout case: kubectl -n agentgateway-ingress rollout restart deployment/agentgateway-ingress,
#     once, and the pod template's kubectl.kubernetes.io/restartedAt annotation and the Deployment's generation read
#     before and after it into the repetition's removal record, because B-5a found that a rollout leaves restartedAt
#     on the pod template and the agentgateway controller does not remove it;
#   - the work-item prefix d1- and the control pod's name d1-curl, so no line of this task can be read as B-5b's;
#   - the lab-scoped istioctl path and the scratch path of the ko build log (${TMPDIR}/d1/...).
# The stimulus, N, the removal offset, the moment Job 2 goes out (the successor FIRST seen Ready), the two Jobs, the
# collection and every wait are B-5b's. What a rollout does differently is the point: the successor becomes Ready
# BEFORE the old pod is asked to stop (B-5a: at the moment the rollout command returns the old pod has no
# deletionTimestamp, 5 of 5), so on this row Job 2 is expected to go out while Job 1's stream is still open, and
# which pod answered it is recorded rather than assumed. B-5a measured the ingress rollout to end the stream
# 21 643.7-27 268.5 ms after the command; with N = 45 000 ms and the removal 2 000 ms after WORKING the Task has
# about 40 s left at the command, so the stream's end is expected inside the Task's life. None of this is assumed
# by the counter: every figure is read from the repetition's own files.
#
#   bash rows.sh <go|py> ingress rollout <reps>   RUN_ID=<nonce> RUNREL=<run dir name> required
#
# The rest of B-5b's header, kept for what it says of the Jobs, the paths and the standing B rules:
#
# | Experiment B, step B-5b: the experiment proper -- the proxy on the path is removed while a stream is open, and ONE
# | SubscribeToTask follows. This is section 4.4 B as the proposal words it, with the stimulus and N that B-5a measured
# | rather than guessed (experiments/runs/2026-09-22-b5a-removal/, and its findings entry).
# |
# | ONE VARIANT PER INVOCATION, run as a background driver on the cluster B-4 built and B-5a left standing (no deployed
# | path changed at this branch's HEAD, so no rebuild). A variant is one receiver, one proxy and one removal method:
# |
# |   bash rows.sh <go|py> <ingress|central> <forced|graceful> <reps>   RUN_ID=<nonce> RUNREL=<run dir name> required
# |
# | THE TWO ROWS, and why they use DIFFERENT removals -- the author's ruling of 2026-09-22, taken from B-5a's table:
# |   * MAIN ROWS, the agentgateway ingress, FORCED delete (--grace-period=0 --force), per receiver x20. B-5a measured
# |     it: the stream is gone 35.6-43.3 ms after the command, the Task runs on for another 42.9 s and reaches
# |     TASK_STATE_COMPLETED 5 of 5 with one model call, and the successor serves at 1 818.3-3 254.2 ms. So a
# |     resubscription has about 40 s of running Task to attach to. This is D5's abrupt case.
# |   * ONE VARIANT, `agw-central`, GRACEFUL delete, per receiver x20. The author ruled the graceful delete HERE and
# |     the forced delete there, on purpose: with the FORCED delete of agw-central B-5a measured the Task already
# |     TASK_STATE_FAILED at 2 055-2 079 ms while the successor was only Ready at 2 115-2 511 ms, so a resubscription
# |     could never reach a running Task at all; the graceful delete leaves about 7 s (the Task fails at
# |     10 046-10 066 ms, the successor serves at 2 16x-3 05x ms). The pairing is therefore refused below if it is not
# |     one of these two, so that a typo cannot run an unruled stimulus.
# |
# | N = 45 000 ms, unchanged from B-3, B-4 and B-5a, and no caller ceiling moves.
# |
# | Per repetition, ONE open stream and ONE resubscription, in two Jobs and two processes:
# |   - the mock is reset and armed {mode: delay, lwi, delay_ms: N} for this work item, so the Task's one model call
# |     holds N and the stream is still open when the proxy is removed;
# |   - `kubectl logs -f` on the proxy pod that is about to be removed is started BEFORE anything is sent, so that
# |     pod's access lines and its drain lines survive the pod (a deleted pod's log cannot be read afterwards);
# |   - Job 1 sends ONE SendStreamingMessage (MODE=stream), with CANCEL_AFTER_MS EMPTY and TASK_ID EMPTY: nothing
# |     cancels, the proxy is what ends the stream (or, on the agw-central row, what ends the model call);
# |   - when Job 1's OWN client lines show the status-update at TASK_STATE_WORKING -- so the stream is open and
# |     carrying events, not merely applied -- the driver reads the taskId off that same line, waits REMOVE_AFTER_MS
# |     and removes the proxy by this variant's method, ONCE, stamping the command on the host clock;
# |   - THE TASK ID COMES FROM JOB 1'S OWN EVENT LINE, not from its end line as B-4 read it. On the agw-central row
# |     Job 1's stream is still open when the successor becomes Ready (B-5a: the stream ends at 10.05 s, the successor
# |     is Ready at 1.45-2.51 s), so no end line exists yet at the moment Job 2 has to go out. The event line carries
# |     the same id and is written about a second after the send;
# |   - the successor is watched through the Kubernetes API alone (nothing is sent to find it), and the moment it is
# |     first seen Ready, Job 2 is applied: a SECOND Job and a SECOND process, ONE SubscribeToTask for Job 1's task
# |     id. There is no loop, no reconnect and no second send: a refusal, an empty reattachment or an arrival after
# |     the Task has ended is a RECORDED OUTCOME (rule 4 and the brief), never retried and never re-run;
# |   - whether Job 1's stream had already ended when Job 2 was applied is read and recorded, because it differs
# |     between the two rows by design;
# |   - both Jobs are waited out whatever they do, the collection then waits for the two lines that land last
# |     (wait_settled, B-5a's: `make ledgers` can otherwise run before the Task and the model call settle), the mock
# |     is reset, and the three ledgers are taken for the work item together with both proxies' lines.
# | Nothing is cancelled, resent, retried or reconnected anywhere: two Jobs, one send each, every curl --retry 0. A
# | repetition that fails is recorded and never re-run. The waits below poll the Kubernetes API or read a pod log;
# | they send nothing to a receiver.
# |
# | BOTH RECEIVERS, on the paths the author's second note of 2026-09-22 fixes and B-4 measured:
# |   go  TARGET_URL is the agentgateway ingress's Service, CLIENT_DIAL=target, CLIENT_HOST=worker.lab.internal, so
# |       the card GET and both POSTs name the host the ingress's `worker-ingress` route matches. Nothing of either
# |       Job crosses agw-central except the model call itself.
# |   py  TARGET_URL is the orchestrator's Service with CLIENT_DIAL and CLIENT_HOST empty (as B-3 and B-4): the card
# |       GET crosses `lab/orchestrator` on agw-central and the POSTs go where the card points, the ingress's
# |       `lab/orchestrator-ingress`. On the agw-central row that means Job 2's card GET crosses the proxy that was
# |       just removed -- it is sent once, to whatever answers, and what answered is recorded.
# | The orchestrator runs in MODEL mode for its half (DOWNSTREAM_A2A_URL removed, PLAN_MODEL_CALL read and required
# | off), restored by the EXIT trap.
# |
# | Standing B rules this driver keeps: the stimulus is the load client, which sends A2A-Version: 1.0; N stays under
# | both callers' 60 s ceilings (the worker's MODEL_TIMEOUT_S is unset, so its default 60 s); each repetition's
# | ledgers are collected as soon as it ends, before any pod log can rotate; repetitions run ONE AT A TIME, because
# | HBONE tunnels are shared and concurrent streams from one client would end together (the preparation's 6.3).
# | Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
# The lab-scoped istioctl 1.31.0 (re-verified in this task's tools.txt), first on PATH for this
# driver's own processes only; the host's Homebrew istioctl (1.31.1) is not used and not touched. Only the read-only
# `istioctl ztunnel-config certificates` is run.
PATH="${TMPDIR%/}/d1/tools/istioctl-1.31.0:$PATH"
export PATH

RECV="${1:-}"
PROXY="${2:-}"
METHOD="${3:-}"
REPS="${4:-}"
RUN_ID="${RUN_ID:-}"
RUNREL="${RUNREL:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
CURL_POD=d1-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
TEMPLATE=deploy/base/loadgen-a2-job.yaml
# N: 45 000 ms, the only N this lab has measured the path to carry with no timeout set anywhere, unchanged by the
# author's ruling of 2026-09-22. No caller ceiling moves.
N_MS=45000
# The stream is left open REMOVE_AFTER_MS past the client's own TASK_STATE_WORKING event before the proxy is
# removed, so the model call is certainly in flight (the executor calls the model immediately after that event).
# B-5a's offset, unchanged, so this step's cut lands where B-5a's table measured it.
REMOVE_AFTER_MS=2000
# Ceilings on the driver's own waits. None of them sends anything.
JOB_LIMIT_S=240
WORKING_LIMIT_S=60
SUCCESSOR_LIMIT_S=300
SETTLE_AFTER_N_S=30
SETTLE_LIMIT_S=180
COLLECT_WAIT=2
# The paths, by the author's second note of 2026-09-22 and B-4's rows.sh.
GO_TARGET=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
GO_DIAL=target
GO_HOST=worker.lab.internal

case "$RECV" in go | py) ;; *) echo "rows: receiver $RECV is not go or py" >&2; exit 1 ;; esac
case "$PROXY" in
ingress) PNS=agentgateway-ingress; PDEPLOY=agentgateway-ingress ;;
central) PNS=agentgateway-waypoint; PDEPLOY=agw-central ;;
*) echo "rows: proxy $PROXY is not ingress or central" >&2; exit 1 ;;
esac
# The author's pairing, and only it: the ingress is removed by force, agw-central gracefully. Anything else would be
# a stimulus nobody ruled, so it is refused here rather than recorded.
case "$PROXY-$METHOD" in
ingress-rollout) ;;
*) echo "rows: $PROXY with a $METHOD removal is not this row's (ingress-rollout, the author's note of 2026-09-24); nothing was sent" >&2; exit 1 ;;
esac
case "$REPS" in '' | *[!0-9]*) echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1 ;; esac
[ "$REPS" -ge 1 ] || { echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1; }
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "rows: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
[ -n "$RUNREL" ] || { echo "rows: RUNREL (the run directory's name) is required" >&2; exit 1; }

VARIANT="$RECV-$PROXY-$METHOD"
D="experiments/runs/$RUNREL/rows/$VARIANT"
# DRY=yes: one repetition of a variant before any counted variant, to prove the stimulus and the collection on the
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

case "$RECV" in
go) TARGET="$GO_TARGET"; DIAL="$GO_DIAL"; HOST="$GO_HOST" ;;
py) TARGET="$ORCH_URL"; DIAL=""; HOST="" ;;
esac

say "variant $VARIANT: receiver $RECV, proxy $PNS/$PDEPLOY, method $METHOD, $REPS repetitions, RUN_ID $RUN_ID, DRY=${DRY:-no}"
say "HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null)"
say "N_MS=$N_MS REMOVE_AFTER_MS=$REMOVE_AFTER_MS; template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE"); path: TARGET_URL=$TARGET CLIENT_DIAL=${DIAL:-<empty>} CLIENT_HOST=${HOST:-<empty>} CANCEL_AFTER_MS=<empty>"

RESTORE_ORCH=no
ORCH_PRE=""
cleanup() {
	local rc=$?
	kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$RESTORE_ORCH" = yes ]; then
		local s=0 r=0
		kubectl -n "$NS" set env deployment/orchestrator "DOWNSTREAM_A2A_URL=${ORCH_PRE}" >/dev/null 2>&1 || s=$?
		kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || r=$?
		if [ "$s" = 0 ] && [ "$r" = 0 ]; then
			say "restored the orchestrator: DOWNSTREAM_A2A_URL=${ORCH_PRE} (set env rc=0, rollout rc=0)"
		else
			say "RESTORE FAILED (set env rc=$s, rollout rc=$r): the orchestrator's DOWNSTREAM_A2A_URL is to be put back to ${ORCH_PRE}"
			rc=1
		fi
	fi
	say "variant $VARIANT driver exit=$rc"
	exit "$rc"
}
trap cleanup EXIT

# --- the between-variant proof: the cluster put back, read the way B-5a's row driver read it ----------------------
kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 10800 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
post_json() { # $1 url, $2 body (may be empty) -> http code
	local args=(-sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json')
	[ -n "${2:-}" ] && args+=(-d "$2")
	kubectl -n "$NS" exec "$CURL_POD" -- curl "${args[@]}" "$1" 2>/dev/null
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

pods_line() { kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}'; }

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
		say "   deployment/$g replicas spec=$spec ready=${ready:-0} generation=$(kubectl -n "$gns" get deployment "$gn" -o jsonpath='{.metadata.generation}' 2>/dev/null) programmed=$(kubectl -n "$gns" get gateway "$gn" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}' 2>/dev/null)"
		[ "$spec" = 1 ] && [ "${ready:-0}" = 1 ] || { say "   deployment/$g is not at one ready replica"; return 1; }
	done
	say "   proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP} uid={.metadata.uid} restarts={.status.containerStatuses[0].restartCount} created={.metadata.creationTimestamp}; {end}')"
	say "   retry stanzas on HTTPRoutes: $(kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'); AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	# Nothing armed. A receiver holds its armed mode in process memory and writes no ledger line for a control call,
	# so the reading is B-5a's: the mock's own control lines decide (an inject arms, a reset clears, the last line
	# decides), and the worker's process log is read for a close-after-read, the only trace an armed receiver leaves.
	local ctl inj res last
	ctl=$(kubectl -n "$NS" logs deploy/mockllm --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "control")')
	inj=$(printf '%s\n' "$ctl" | grep -c '/control/inject' || true)
	res=$(printf '%s\n' "$ctl" | grep -c '/control/reset' || true)
	last=$(printf '%s\n' "$ctl" | tail -1)
	say "   mock control lines: injects=$inj resets=$res; resets after the last inject: $(printf '%s\n' "$ctl" | awk '/\/control\/inject/ {n=0; next} /\/control\/reset/ {n++} END {print n+0}')"
	say "   mock last control line: $last"
	say "   worker log lines naming close-after-read: $(kubectl -n "$NS" logs deploy/worker --tail=-1 2>/dev/null | grep -c 'close-after-read' || true)"
	say "   orchestrator mode now: DOWNSTREAM_A2A_URL=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}') PLAN_MODEL_CALL=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAN_MODEL_CALL")].value}') MODEL_MAX_RETRIES=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_MAX_RETRIES")].value}')"
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

# --- the orchestrator in model mode, for the py half --------------------------------------------------------------
to_model_mode() {
	ORCH_PRE=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}')
	local plan; plan=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAN_MODEL_CALL")].value}')
	say "orchestrator before: DOWNSTREAM_A2A_URL=${ORCH_PRE:-<unset>} PLAN_MODEL_CALL=${plan:-<unset>} MODEL_MAX_RETRIES=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_MAX_RETRIES")].value}')"
	[ "$plan" = off ] || { say "PLAN_MODEL_CALL is not off; stopping"; exit 1; }
	[ -n "$ORCH_PRE" ] || { say "orchestrator already in model mode; nothing switched"; return 0; }
	kubectl -n "$NS" set env deployment/orchestrator DOWNSTREAM_A2A_URL- >/dev/null
	RESTORE_ORCH=yes
	kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null || { say "rollout to model mode failed"; exit 1; }
	say "orchestrator in model mode: DOWNSTREAM_A2A_URL removed; pod $(kubectl -n "$NS" get pods -l app=orchestrator -o jsonpath='{.items[0].metadata.name} uid {.items[0].metadata.uid}')"
}

# --- the image, once for the variant -------------------------------------------------------------------------------
resolve_image() {
	local t0 t1 rc=0
	t0=$(tsn)
	IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d1/work/ko-build-$RUN_ID-$VARIANT.log") || rc=$?
	t1=$(tsn)
	{ echo "$t0 ko build --platform=linux/$(go env GOARCH) ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) -> rc=$rc"; echo "$t1 image: ${IMAGE:-<none>}"; } >> "$D/image.txt"
	case "$IMAGE" in kind.local/loadgen-*:*) ;; *) say "the image could not be resolved (rc=$rc, '$IMAGE'); stopping"; exit 1 ;; esac
	say "image resolved once for the variant: $IMAGE ($t0 -> $t1)"
}

# --- Jobs -----------------------------------------------------------------------------------------------------------
apply_job() { # $1 lwi, $2 job name, $3 MODE, $4 TASK_ID, $5 apply log; CANCEL_AFTER_MS is always empty in B-5b
	local lwi="$1" name="$2" mode="$3" task="$4" log="$5" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${TARGET}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${DIAL}/g" -e "s/\${CLIENT_HOST}/${HOST}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" \
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
wait_working() { # $1 job name -> prints "<ts> <taskId>" off the client's own TASK_STATE_WORKING event line
	local waited=0 line
	while :; do
		line=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null \
			| jq -R -r 'fromjson? | select(.ledger == "client" and .line == "event" and .state == "TASK_STATE_WORKING") | "\(.ts) \(.taskId)"' | head -1)
		case "$line" in ?*" "?*) echo "$line"; return 0 ;; esac
		sleep 0.2; waited=$((waited + 1))
		[ "$waited" -lt $((WORKING_LIMIT_S * 5)) ] || break
	done
	return 1
}
job1_end_now() { # $1 job name -> the stream_end on Job 1's end line if that line is already there, else "<still open>"
	local v
	v=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null | jq -R -r 'fromjson? | select(.ledger == "client" and .line == "end") | .stream_end' | head -1)
	echo "${v:-<still open>}"
}

wait_settled() { # $1 lwi, $2 the repetition's start stamp, $3 steps file, $4 the arm stamp in epoch seconds
	# B-5a's, unedited in behaviour: a stream can end long before the Task and the model call do, and `make ledgers`
	# run at the stream's end collected 13 s before either line existed (B-5a's first dry repetition). It reads two
	# pod logs and SENDS NOTHING.
	local lwi="$1" since="$2" steps="$3" armed="$4" waited=0 term="" inv="" hard=$((SETTLE_LIMIT_S * 2))
	local invdeadline=$((armed + N_MS / 1000 + SETTLE_AFTER_N_S))
	while [ "$waited" -lt "$hard" ]; do
		[ -n "$term" ] || term=$(kubectl -n "$NS" logs "deploy/$RDEPLOY" --since-time="$since" 2>/dev/null \
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
pod_fact() { kubectl -n "$PNS" get pod "$1" -o jsonpath="$2" 2>/dev/null; }
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

case "$RECV" in go) RDEPLOY=worker ;; py) RDEPLOY=orchestrator ;; esac

one_rep() { # $1 repetition number
	local n; n=$(printf '%02d' "$1")
	local lwi="d1-${RECV}-${PROXY}-${METHOD}-${RUN_ID}-${n}"
	local d="$D/$lwi"
	local j1="loadgen-$lwi" j2="loadgen-$lwi-s"
	mkdir -p "$d"
	local steps="$d/steps.txt" rm="$d/removal.txt" since old new logpid s1="" s2="" tid=""
	since=$(tsn)
	echo "$since repetition $lwi variant=$VARIANT receiver=$RECV proxy=$PNS/$PDEPLOY method=$METHOD target=$TARGET dial=${DIAL:-<empty>} host=${HOST:-<empty>}" >> "$steps"

	old=$(proxy_pod | head -1)
	[ -n "$old" ] || { say "  $lwi: no proxy pod for $PNS/$PDEPLOY; stopping"; exit 1; }
	{
		echo "$(tsn) agent pods before: $(pods_line)"
		echo "$(tsn) proxy pods before: $(kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp} restarts={.status.containerStatuses[0].restartCount}; {end}')"
		echo "$(tsn) other proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP}; {end}')"
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
	apply_job "$lwi" "$j1" stream "" "$d/apply-1.log" || echo "$(tsn) Job 1 apply rc=$?" >> "$steps"
	echo "$(tsn) Job 1 applied" >> "$steps"

	local working tworking
	working=$(wait_working "$j1") || working=""
	tworking="${working%% *}"; tid="${working#* }"
	[ -n "$working" ] || { tworking=""; tid=""; }
	echo "$(tsn) Job 1's client saw TASK_STATE_WORKING at ${tworking:-<none within ${WORKING_LIMIT_S}s>} (client pod clock) naming task ${tid:-<none>}" >> "$steps"
	if [ -z "$tworking" ]; then
		echo "$(tsn) NO WORKING EVENT: the proxy is NOT removed and NO resubscription is sent in this repetition" >> "$steps"
		say "  $lwi: no TASK_STATE_WORKING event within ${WORKING_LIMIT_S}s; nothing removed, repetition recorded as such"
	else
		sleep "$(awk -v m="$REMOVE_AFTER_MS" 'BEGIN{printf "%.3f", m/1000}')"
		local t_rm_start t_rm_done
		t_rm_start=$(tsn)
		echo "$(tsn) deployment/$PDEPLOY before: generation=$(kubectl -n "$PNS" get deployment "$PDEPLOY" -o jsonpath='{.metadata.generation}') restartedAt=[$(kubectl -n "$PNS" get deployment "$PDEPLOY" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')]" >> "$rm"
		t_rm_start=$(tsn)
		echo "$t_rm_start REMOVAL COMMAND START method=$METHOD pod=$old (host clock)" >> "$rm"
		remove_proxy "$old" "$rm"
		t_rm_done=$(tsn)
		echo "$t_rm_done REMOVAL COMMAND DONE (host clock)" >> "$rm"
		echo "$(tsn) deployment/$PDEPLOY after: generation=$(kubectl -n "$PNS" get deployment "$PDEPLOY" -o jsonpath='{.metadata.generation}') restartedAt=[$(kubectl -n "$PNS" get deployment "$PDEPLOY" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')]" >> "$rm"
		echo "$(tsn) removal issued: $METHOD on $old" >> "$steps"
		echo "$(tsn) old pod deletionTimestamp=$(pod_fact "$old" '{.metadata.deletionTimestamp}') (API-server clock, second resolution; empty means the object was already gone or none was set)" >> "$rm"
		# Watch the successor and the old pod through the Kubernetes API only; nothing is sent to find them. The ONE
		# resubscription goes out inside this loop, the moment the successor is FIRST seen Ready -- the brief's
		# instruction, and on the agw-central row the only moment at which the Task is still running (B-5a: it fails
		# at 10.05 s and the successor is Ready at 1.45-2.51 s). One send, never repeated, whatever it gets.
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
					echo "$(tsn) JOB 1 STREAM AT THIS MOMENT: $(job1_end_now "$j1")" >> "$rm"
					echo "$(tsn) apply Job 2 $j2 MODE=subscribe TASK_ID=$tid CANCEL_AFTER_MS=<empty>" >> "$steps"
					apply_job "$lwi" "$j2" subscribe "$tid" "$d/apply-2.log" || echo "$(tsn) Job 2 apply rc=$?" >> "$steps"
					echo "$(tsn) Job 2 applied" >> "$steps"
				fi
			fi
			[ -n "$oldgone" ] && [ -n "$newready" ] && break
			sleep 0.2; waited=$((waited + 1))
		done
		[ -n "$newname" ] || echo "$(tsn) NO successor pod within ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		[ -n "$newready" ] || { echo "$(tsn) successor NOT Ready within ${SUCCESSOR_LIMIT_S}s; NO resubscription was sent" >> "$rm"; echo "$(tsn) successor never Ready; NO resubscription was sent" >> "$steps"; }
		[ -n "$oldgone" ] || echo "$(tsn) old pod object still present after ${SUCCESSOR_LIMIT_S}s" >> "$rm"
		echo "$newname" > "$d/successor.txt"
	fi

	s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
	if kubectl -n "$NS" get job "$j2" >/dev/null 2>&1; then s2=$(wait_job "$j2"); echo "$(tsn) Job 2 $s2" >> "$steps"; fi
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
		# one multi-line entry, which would put ~140 unstamped lines in every repetition's record.
		kubectl -n "$PNS" logs "$new" --tail=-1 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z\t' > "$d/newpod.log" || true
		pod_json "$new" > "$d/newpod-after.json"
	fi
	# the OTHER proxy's access lines for the repetition's window: it stayed up, and it is the one that carried the
	# A2A stream (ingress) or the model call (agw-central) that this variant did not remove.
	case "$PROXY" in
	ingress) kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/otherproxy-access.txt" || true ;;
	central) kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/otherproxy-access.txt" || true ;;
	esac
	local rc=0
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$d" >/dev/null 2>"$d/ledgers-stderr.txt" || rc=$?
	echo "$(tsn) make ledgers LWI=$lwi exit=$rc" >> "$steps"
	# Job 2's own client lines. `make ledgers` reads the client ledger from the pods labelled job-name=loadgen-<lwi>,
	# which is Job 1 alone; Job 2 is loadgen-<lwi>-s and its lines are collected here, as B-4's driver collected them.
	if kubectl -n "$NS" get job "$j2" >/dev/null 2>&1; then
		kubectl -n "$NS" logs -l "job-name=$j2" --tail=-1 2>/dev/null > "$d/client-sub.raw" || true
		jq -R -c 'fromjson? | select(.ledger == "client")' "$d/client-sub.raw" > "$d/client-sub.jsonl" 2>/dev/null || true
		rm -f "$d/client-sub.raw"
	fi
	for j in "$j1" "$j2"; do
		kubectl -n "$NS" get job "$j" >/dev/null 2>&1 || continue
		echo "$j $(kubectl -n "$NS" get job "$j" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pod-created=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null) container-started=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$j" --no-headers 2>/dev/null | wc -l | tr -d ' ')" >> "$d/jobs.txt"
	done
	{
		echo "$(tsn) agent pods after: $(pods_line)"
		echo "$(tsn) proxy pods after: $(kubectl -n "$PNS" get pods -l "gateway.networking.k8s.io/gateway-name=$PDEPLOY" -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} ip={.status.podIP} created={.metadata.creationTimestamp} ready={range .status.conditions[?(@.type=="Ready")]}{.status}{end}; {end}')"
	} >> "$steps"
	echo "$(tsn) collected" >> "$steps"
	say "  $lwi job1=$s1${s2:+ job2=$s2} task=${tid:-<none>} old=$old new=${new:-<none>} ingress-ledger=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$d/client.jsonl" 2>/dev/null | tr -d ' ') client-sub=$(wc -l < "$d/client-sub.jsonl" 2>/dev/null | tr -d ' ')"
}

[ "$RECV" = py ] && to_model_mode
between_check "before" || { say "the cluster was not put back before this variant; stopping"; exit 1; }
resolve_image
say "== variant $VARIANT: $REPS repetitions, one at a time"
for i in $(seq 1 "$REPS"); do one_rep "$i"; done
reset_mock "$CONTROL"
between_check "after" || { say "the cluster is NOT put back after this variant"; exit 1; }
say "== variant $VARIANT done"
