#!/usr/bin/env bash
# Experiment B, step B-3: the four counted rows, one row per invocation, run as a background driver on the cluster
# the rebuild of this run directory built (build.txt). No proxy is removed or restarted here; nothing on either proxy
# changes. Every row runs the load client (fixtures/loadgen, a2a-go) as an in-cluster Job rendered from
# deploy/base/loadgen-a2-job.yaml with every retry knob at its off value and CLIENT_DIAL empty (the client dials what
# the receiver's card advertises), so only the receiver changes between the go and py halves of a row, as in A.1.
#
#   bash rows.sh <row> <reps> [<receivers>]      RUN_ID=<nonce> in the environment, required
#
#   model-call          B-2's count, deferred to B-3 by ruling: the mock armed {mode: delay, lwi, delay_ms: N} for
#                       the work item, then ONE unary SendMessage (MODE unset): one N-second model call through the
#                       receiver's model route. Counted: invocation lines, their latency_ms and outcome.
#   stream              ONE SendStreamingMessage (MODE=stream), nothing armed: the clean stream, B-1's first cluster
#                       proof of a streamed request.
#   subscribe-running   the mock armed with the delay; Job 1 = ONE SendStreamingMessage; when Job 1's first client
#                       event line names the task, Job 2 = ONE SubscribeToTask for it (MODE=subscribe), a separate
#                       Job, a separate process, started while the Task is still running.
#   subscribe-terminal  nothing armed; Job 1 = ONE SendStreamingMessage; when Job 1 has COMPLETED (its pod exited),
#                       Job 2 = ONE SubscribeToTask for its task, which is then in a terminal state (the author's
#                       row D3).
#
# Job 1 is named loadgen-<work item>, so `make ledgers` collects its client lines; Job 2 is loadgen-<work item>-s (the
# template's metadata.name line is rewritten for it, nothing else), and its client lines are collected here. Both
# carry the same work item: Job 2's request has no Message, and the X-Logical-Work-Item-Id header the load client
# sets is where the receiver's ingress ledger reads it from.
#
# Standing B rules this driver keeps: every stimulus is the load client, which sends A2A-Version: 1.0 (a2a-go v2.5.0
# sets it from the card's interface); the orchestrator runs in MODEL mode for its rows with PLAN_MODEL_CALL off, read
# and recorded, restored on exit; the delay N stays under both callers' 60 s ceilings; each repetition's ledgers are
# collected as soon as it ends (`make ledgers`, whose second arm collects the resubscription's anonymous execution
# lines by the taskId the work item minted), before any pod log can rotate. Counting is counts.py's, which parses
# stamps and joins on identity; this driver only sends and collects.
#
# No retry, resend or reconnect anywhere: one send per Job, every curl --retry 0, a failed repetition is recorded
# and never re-run. The waits below poll Kubernetes for a Job's state or read a Job's log; they send nothing to a
# receiver.
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
# The istioctl this run uses: the lab-scoped copy of the pinned 1.31.0 (tools.txt), first on PATH for this driver's
# own processes only, by the controller's ruling; the host's Homebrew istioctl (1.31.1 since before this task) is
# not used and not touched.
PATH="${TMPDIR%/}/b3/tools/istioctl-1.31.0:$PATH"
export PATH
# Helm: the lab-scoped empty repository config and cache of the rebuild (the controller's second ruling). This
# driver calls no helm itself; the setting is here so that nothing it starts reads the host's Helm configuration.
HELMSCOPE="${TMPDIR%/}/b3/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME

ROW="${1:-}"
REPS="${2:-}"
RECEIVERS="${3:-go py}"
RUN_ID="${RUN_ID:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
RUNREL=2026-09-21-b3-streaming-client
D="experiments/runs/$RUNREL/$ROW"
# DRY=yes writes to a scratch directory taken from the environment instead: one repetition per receiver, taken
# before the counted run to check this driver on the cluster, as gate3-matrix.sh's DRY_RUN does. Its work items
# carry their own RUN_ID and are named in the run directory's reading notes; nothing of it is counted.
[ "${DRY:-no}" = yes ] && D="${TMPDIR%/}/b3/dry/$ROW"
CURL_POD=b3-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
TEMPLATE=deploy/base/loadgen-a2-job.yaml
# N: 45 s. The Experiment B preparation's window is 40-50 s (section 7.3): both callers cap a model call at 60 s
# (the worker's MODEL_TIMEOUT_S default, the orchestrator's ModelClient), counted from the model call, and B-5 needs
# the Task still running after a forced proxy removal, its replacement and a second Job's start. 45 s leaves 15 s
# under the ceilings for everything before and after the call and the most of the window for B-5.
N_MS=45000
COLLECT_WAIT=2
JOB_LIMIT_S=180
FIRST_EVENT_LIMIT_S=60

case "$ROW" in model-call | stream | subscribe-running | subscribe-terminal) ;; *)
	echo "usage: RUN_ID=<nonce> $0 <model-call|stream|subscribe-running|subscribe-terminal> <reps> [\"go py\"]" >&2; exit 1 ;;
esac
case "$REPS" in '' | *[!0-9]*) echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1 ;; esac
[ "$REPS" -ge 1 ] || { echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1; }
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "rows: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
for r in $RECEIVERS; do case "$r" in go | py) ;; *) echo "rows: receiver $r is not go or py" >&2; exit 1 ;; esac; done
if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ] && [ "${APPEND:-no}" != yes ]; then
	echo "rows: $D already holds files; a row is run once (APPEND=yes adds a chunk under a new RUN_ID)" >&2; exit 1
fi
mkdir -p "$D"
CONTROL="$D/control.txt"

ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$CONTROL"; }

say "row $ROW, reps $REPS per receiver, receivers [$RECEIVERS], RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null)"
say "N_MS=$N_MS (used by model-call and subscribe-running only); template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE")"

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
			say "RESTORE FAILED (set env rc=$s, rollout rc=$r): put it back with kubectl -n $NS set env deployment/orchestrator DOWNSTREAM_A2A_URL=${ORCH_PRE}"
			rc=1
		fi
	fi
	say "row $ROW driver exit=$rc"
	exit "$rc"
}
trap cleanup EXIT

# --- the control pod, the replica check, the certificate check ------------------------------------------------
kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 7200 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
post_json() { # $1 url, $2 body (may be empty) -> http code
	local args=(-sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json')
	[ -n "${2:-}" ] && args+=(-d "$2")
	kubectl -n "$NS" exec "$CURL_POD" -- curl "${args[@]}" "$1" 2>/dev/null
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
for dep in worker orchestrator mockllm; do
	spec=$(kubectl -n "$NS" get "deployment/$dep" -o jsonpath='{.spec.replicas}')
	ready=$(kubectl -n "$NS" get "deployment/$dep" -o jsonpath='{.status.readyReplicas}')
	say "deployment/$dep replicas spec=$spec ready=${ready:-0}"
	[ "$spec" = 1 ] && [ "${ready:-0}" = 1 ] || { say "deployment/$dep is not at one ready replica"; exit 1; }
done
istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" > "$D/certificates.txt" 2>&1
if awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' "$D/certificates.txt" | grep -qx true; then
	say "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default"
else
	say "certificate check: VALID CERT is not true; this driver restarts nothing -- stopping"; exit 1
fi
say "worker env MODEL_TIMEOUT_S=$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_TIMEOUT_S")].value}')<- empty means unset, default 60 s; MODEL_RETRIES=$(kubectl -n "$NS" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_RETRIES")].value}')"
say "retry stanzas on HTTPRoutes: $(kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'); AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

# --- the orchestrator in model mode, for the py half ------------------------------------------------------------
case " $RECEIVERS " in *" py "*)
	ORCH_PRE=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}')
	plan=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAN_MODEL_CALL")].value}')
	say "orchestrator before: DOWNSTREAM_A2A_URL=${ORCH_PRE:-<unset>} PLAN_MODEL_CALL=${plan:-<unset>} MODEL_MAX_RETRIES=$(kubectl -n "$NS" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_MAX_RETRIES")].value}')"
	[ "$plan" = off ] || { say "PLAN_MODEL_CALL is not off; stopping"; exit 1; }
	;;
esac
to_model_mode() {
	[ -n "$ORCH_PRE" ] || { say "orchestrator already in model mode; nothing switched"; return 0; }
	kubectl -n "$NS" set env deployment/orchestrator DOWNSTREAM_A2A_URL- >/dev/null
	RESTORE_ORCH=yes
	kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null || { say "rollout to model mode failed"; exit 1; }
	say "orchestrator in model mode: DOWNSTREAM_A2A_URL removed; pod $(kubectl -n "$NS" get pods -l app=orchestrator -o jsonpath='{.items[0].metadata.name} uid {.items[0].metadata.uid}')"
}
back_from_model_mode() {
	[ "$RESTORE_ORCH" = yes ] || return 0
	kubectl -n "$NS" set env deployment/orchestrator "DOWNSTREAM_A2A_URL=${ORCH_PRE}" >/dev/null
	kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null || { say "rollout back to forward mode failed"; exit 1; }
	RESTORE_ORCH=no
	say "restored the orchestrator: DOWNSTREAM_A2A_URL=${ORCH_PRE}"
}

# --- Jobs ----------------------------------------------------------------------------------------------------------
apply_job() { # $1 lwi, $2 job name, $3 target, $4 MODE, $5 TASK_ID, $6 apply log
	local lwi="$1" name="$2" target="$3" mode="$4" task="$5" log="$6" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}//g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" \
		"$TEMPLATE" \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >"$log" 2>&1 || rc=$?
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
first_event_task() { # $1 job name -> the taskId of the first client event line, read from the Job's log
	local waited=0 tid
	while :; do
		tid=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null | jq -R -r 'fromjson? | select(.ledger == "client" and .line == "event" and .seq == 1) | .taskId' | head -1)
		[ -n "$tid" ] && { echo "$tid"; return 0; }
		sleep 0.5; waited=$((waited + 1))
		[ "$waited" -lt $((FIRST_EVENT_LIMIT_S * 2)) ] || break
	done
	return 1
}
end_task() { # $1 job name -> the taskId on the Job's client end line
	kubectl -n "$NS" logs "job/$1" 2>/dev/null | jq -R -r 'fromjson? | select(.ledger == "client" and .line == "end") | .taskId' | head -1
}

reset_mock() {
	local c; c=$(post_json "$MOCK_URL/control/reset" "")
	echo "$(tsn) POST $MOCK_URL/control/reset -> $c" >> "$1"
	ok2xx "$c" || { say "mock reset returned $c"; exit 1; }
}
arm_delay() { # $1 lwi, $2 file
	local body c; body=$(printf '{"mode":"delay","lwi":"%s","delay_ms":%d}' "$1" "$N_MS")
	c=$(post_json "$MOCK_URL/control/inject" "$body")
	echo "$(tsn) POST $MOCK_URL/control/inject $body -> $c" >> "$2"
	ok2xx "$c" || { say "arming the mock returned $c"; exit 1; }
}

collect() { # $1 lwi, $2 rep dir, $3 job2 name or "", $4 the repetition's start stamp
	local lwi="$1" d="$2" j2="$3" since="$4" rc=0
	sleep "$COLLECT_WAIT"
	# Both proxies' access-log lines since the repetition began: which route each request of it crossed, its status
	# and its duration. One repetition runs at a time and nothing else in the lab sends, so the window holds this
	# repetition's lines (and any the standard proof's scrapes add, which carry no A2A or model route).
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/agw-central-access.txt" || true
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$d/ingress-access.txt" || true
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$d" >/dev/null 2>"$d/ledgers-stderr.txt" || rc=$?
	echo "$(tsn) make ledgers LWI=$lwi exit=$rc" >> "$d/steps.txt"
	if [ -n "$j2" ]; then
		kubectl -n "$NS" logs -l "job-name=$j2" --tail=-1 2>/dev/null > "$d/client-sub.raw" || true
		jq -R -c 'fromjson? | select(.ledger == "client")' "$d/client-sub.raw" > "$d/client-sub.jsonl" 2>/dev/null || true
		rm -f "$d/client-sub.raw"
	fi
	for j in "loadgen-$lwi" $j2; do
		echo "$j $(kubectl -n "$NS" get job "$j" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)" >> "$d/jobs.txt"
	done
}

target_of() { case "$1" in go) echo "$WORKER_URL" ;; py) echo "$ORCH_URL" ;; esac; }

one_rep() { # $1 receiver, $2 repetition number
	local recv="$1" n; n=$(printf '%02d' "$2")
	local short; case "$ROW" in model-call) short=mc ;; stream) short=st ;; subscribe-running) short=sr ;; subscribe-terminal) short=sx ;; esac
	local lwi="b3-${short}-${recv}-${RUN_ID}-${n}"
	local d="$D/$recv/$lwi" target; target=$(target_of "$recv")
	local j1="loadgen-$lwi" j2="" s1="" s2="" tid=""
	mkdir -p "$d"
	local steps="$d/steps.txt" since
	since=$(tsn)
	echo "$since repetition $lwi receiver=$recv target=$target" >> "$steps"
	reset_mock "$steps"
	case "$ROW" in model-call | subscribe-running) arm_delay "$lwi" "$steps" ;; esac
	local mode1=""; [ "$ROW" = model-call ] || mode1=stream
	echo "$(tsn) apply Job 1 $j1 MODE=${mode1:-<empty>} TASK_ID=<empty>" >> "$steps"
	apply_job "$lwi" "$j1" "$target" "$mode1" "" "$d/apply-1.log" || echo "$(tsn) Job 1 ko apply rc=$?" >> "$steps"
	echo "$(tsn) Job 1 applied" >> "$steps"
	case "$ROW" in
	subscribe-running)
		tid=$(first_event_task "$j1") || tid=""
		echo "$(tsn) Job 1's first client event names task ${tid:-<none within ${FIRST_EVENT_LIMIT_S}s>}" >> "$steps"
		if [ -n "$tid" ]; then
			j2="loadgen-$lwi-s"
			echo "$(tsn) apply Job 2 $j2 MODE=subscribe TASK_ID=$tid" >> "$steps"
			apply_job "$lwi" "$j2" "$target" subscribe "$tid" "$d/apply-2.log" || echo "$(tsn) Job 2 ko apply rc=$?" >> "$steps"
			echo "$(tsn) Job 2 applied" >> "$steps"
		fi
		s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
		if [ -n "$j2" ]; then s2=$(wait_job "$j2"); echo "$(tsn) Job 2 $s2" >> "$steps"; fi
		;;
	subscribe-terminal)
		s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
		tid=$(end_task "$j1")
		echo "$(tsn) Job 1's end line names task ${tid:-<none>}" >> "$steps"
		if [ -n "$tid" ]; then
			j2="loadgen-$lwi-s"
			echo "$(tsn) apply Job 2 $j2 MODE=subscribe TASK_ID=$tid" >> "$steps"
			apply_job "$lwi" "$j2" "$target" subscribe "$tid" "$d/apply-2.log" || echo "$(tsn) Job 2 ko apply rc=$?" >> "$steps"
			echo "$(tsn) Job 2 applied" >> "$steps"
			s2=$(wait_job "$j2"); echo "$(tsn) Job 2 $s2" >> "$steps"
		fi
		;;
	*)
		s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
		;;
	esac
	reset_mock "$steps"
	collect "$lwi" "$d" "$j2" "$since"
	echo "$(tsn) collected" >> "$steps"
	say "  $recv $lwi job1=$s1${j2:+ job2=$s2}${tid:+ task=$tid} ingress=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$d/client.jsonl" 2>/dev/null | tr -d ' ')${j2:+ client-sub=$(wc -l < "$d/client-sub.jsonl" 2>/dev/null | tr -d ' ')}"
}

reset_receiver() { # $1 receiver
	local url; url="$(target_of "$1")/control/reset"
	local c; c=$(post_json "$url" "")
	say "POST $url -> $c (nothing armed on the receiver for this row)"
	ok2xx "$c" || exit 1
}

for recv in $RECEIVERS; do
	[ "$recv" = py ] && to_model_mode
	say "== $ROW x $recv: $REPS repetitions; pods: $(kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}')"
	reset_receiver "$recv"
	for i in $(seq 1 "$REPS"); do one_rep "$recv" "$i"; done
	say "== $ROW x $recv done; pods: $(kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}')"
	[ "$recv" = py ] && back_from_model_mode
done
reset_mock "$CONTROL"
say "mock reset after the row; row $ROW done"
