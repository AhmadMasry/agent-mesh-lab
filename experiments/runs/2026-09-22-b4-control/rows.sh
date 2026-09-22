#!/usr/bin/env bash
# Experiment B, step B-4: the control with no proxy event (the author's note of 2026-09-22 in docs/proposal-notes.md),
# one row, run as a background driver on the cluster the rebuild of this run directory built (build.txt). Nothing on
# any proxy is changed, deleted or restarted. Per receiver, per repetition:
#   - the mock armed {mode: delay, lwi, delay_ms: N} for the work item, so the Task's one model call holds N;
#   - Job 1: ONE SendStreamingMessage (MODE=stream) with CANCEL_AFTER_MS=K: the load client cancels its own stream K
#     after the send, while the Task is WORKING, and sends nothing after it (fixtures/loadgen/cancel.go);
#   - when Job 1's own end line is in its log (read from the Job's log), Job 2: a separate Job and a separate process,
#     ONE SubscribeToTask (MODE=subscribe) for the taskId that end line names, while the Task still runs.
# Both Jobs run to their end, the mock is reset, and the ledgers are collected at once (`make ledgers`, whose second
# arm collects the subscription's anonymous execution lines by the taskId the work item minted; Job 2's client lines
# collected here), with both proxies' access-log lines since the repetition began.
#
#   bash rows.sh <reps> [<receivers>]      RUN_ID=<nonce> in the environment, required
#
# Paths (the author's D1: the B-5b main rows go through the agentgateway ingress, for BOTH receivers):
#   py  TARGET_URL is the orchestrator's Service, CLIENT_DIAL empty: the card GET crosses lab/orchestrator on
#       agw-central and the POSTs go where the card points, the agentgateway ingress, lab/orchestrator-ingress (as B-3).
#   go  by the author's note of 2026-09-22 (the Host setting) and the controller's ruling on this step's STOP:
#       TARGET_URL is the agentgateway ingress's Service, CLIENT_DIAL=target, CLIENT_HOST=worker.lab.internal, so the
#       card GET and both POSTs name the host the ingress's worker-ingress route matches and are sent to the ingress.
#       The worker's card advertises its own Service URL (the agw-central path); CLIENT_DIAL=target keeps the POST on
#       the ingress. The py half renders CLIENT_HOST empty.
#
# Job 2's start. B-3 built each Job with `ko apply` at the moment of use (~16 s of Job 2's start). Here the image is
# resolved ONCE per row: `ko build` of fixtures/loadgen, loaded into the kind nodes, which prints the image reference
# `ko apply` puts into the Job (kind.local/loadgen-<hash>:<digest>, as B-3's 258 Jobs read). Each Job is then the
# template with its `ko://` image line replaced by that reference and its placeholders substituted as B-3's driver
# substituted them, applied with `kubectl apply`. Same template, same substitutions, same image; the build is taken
# out of each Job's start. Recorded per
# repetition: the stamps of reading Job 1's end line, applying Job 2, Job 2 applied, and (in counts.py, from the
# ledger) Job 2's arrival at the receiver.
#
# Standing B rules this driver keeps: every stimulus is the load client, which sends A2A-Version: 1.0; the
# orchestrator runs in MODEL mode for its half with PLAN_MODEL_CALL off, read and recorded, restored on exit; N stays
# under both callers' 60 s ceilings; each repetition's ledgers are collected as soon as it ends, before any pod log
# can rotate. Counting is counts.py's, which parses stamps, joins on identity, reads the final state from the
# executor's state lines and counts every invocation line, stale-closed included.
#
# No retry, resend or reconnect anywhere: one send per Job, every curl --retry 0, a failed repetition is recorded and
# never re-run. The waits below poll Kubernetes for a Job's state or read a Job's log; they send nothing to a receiver.
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
# The lab-scoped istioctl 1.31.0 (tools.txt) and Helm scope, first on PATH / in the environment for this driver's own
# processes only; the host's Homebrew istioctl (1.31.1) and the host's Helm configuration are not used and not touched.
PATH="${TMPDIR%/}/b4/tools/istioctl-1.31.0:$PATH"
export PATH
HELMSCOPE="${TMPDIR%/}/b4/tools/helm-scope"
HELM_REPOSITORY_CONFIG="$HELMSCOPE/config/repositories.yaml"
HELM_REPOSITORY_CACHE="$HELMSCOPE/cache/repository"
HELM_CACHE_HOME="$HELMSCOPE/cache"
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE HELM_CACHE_HOME

REPS="${1:-}"
RECEIVERS="${2:-go py}"
RUN_ID="${RUN_ID:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
RUNREL="${RUNREL:-}"
D="experiments/runs/$RUNREL/control"
# DRY=yes: one repetition per receiver before the counted row, to check this driver on the cluster. By the
# controller's ruling they are requests on the cluster and are RECORDED, under the run directory's dry/, named in the
# entry as sent and not counted, with their own counts beside it.
[ "${DRY:-no}" = yes ] && D="experiments/runs/$RUNREL/dry/control"
CURL_POD=b4-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
TEMPLATE=deploy/base/loadgen-a2-job.yaml
# N: 45 s, as in B-3 (both callers cap a model call at 60 s).
N_MS=45000
# K: see the run directory's reading notes and the findings entry for why 5 000 ms.
K_MS=5000
COLLECT_WAIT=2
JOB_LIMIT_S=180
END_LINE_LIMIT_S=60
# The go half's path (see the header).
GO_TARGET=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
GO_DIAL=target
GO_HOST=worker.lab.internal

case "$REPS" in '' | *[!0-9]*) echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1 ;; esac
[ "$REPS" -ge 1 ] || { echo "rows: REPS=$REPS is not a positive integer" >&2; exit 1; }
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "rows: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
[ -n "$RUNREL" ] || { echo "rows: RUNREL (the run directory's name) is required" >&2; exit 1; }
for r in $RECEIVERS; do case "$r" in go | py) ;; *) echo "rows: receiver $r is not go or py" >&2; exit 1 ;; esac; done

if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ] && [ "${APPEND:-no}" != yes ]; then
	echo "rows: $D already holds files; a row is run once (APPEND=yes adds a chunk under a new RUN_ID)" >&2; exit 1
fi
mkdir -p "$D"
CONTROL="$D/control.txt"

ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$CONTROL"; }

say "row control, reps $REPS per receiver, receivers [$RECEIVERS], RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1); istioctl on PATH: $(istioctl version --remote=false 2>/dev/null)"
say "N_MS=$N_MS K_MS=$K_MS; template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE"); go path: TARGET_URL=$GO_TARGET CLIENT_DIAL=$GO_DIAL CLIENT_HOST=$GO_HOST; py path: TARGET_URL=$ORCH_URL CLIENT_DIAL=<empty> CLIENT_HOST=<empty>"

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
	say "row control driver exit=$rc"
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
say "proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP} uid={.metadata.uid} restarts={.status.containerStatuses[0].restartCount}; {end}')"

# --- the image, once for the row -------------------------------------------------------------------------------
IMGLOG="$D/image.txt"
t0=$(tsn)
IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/b4/ko-build-$RUN_ID.log")
rc=$?
t1=$(tsn)
{ echo "$t0 ko build --platform=linux/$(go env GOARCH) ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) -> rc=$rc"; echo "$t1 image: ${IMAGE:-<none>}"; } >> "$IMGLOG"
case "$IMAGE" in kind.local/loadgen-*:*) ;; *) say "the image could not be resolved (rc=$rc, '$IMAGE'); stopping"; exit 1 ;; esac
say "image resolved once for the row: $IMAGE ($t0 -> $t1)"

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
apply_job() { # $1 lwi, $2 job name, $3 target, $4 dial, $5 host, $6 MODE, $7 TASK_ID, $8 CANCEL_AFTER_MS, $9 apply log
	local lwi="$1" name="$2" target="$3" dial="$4" host="$5" mode="$6" task="$7" cancel="$8" log="$9" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}/${cancel}/g" \
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
end_line_task() { # $1 job name -> the taskId on the Job's client end line, once that line is in the Job's log
	local waited=0 tid
	while :; do
		tid=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null | jq -R -r 'fromjson? | select(.ledger == "client" and .line == "end") | .taskId' | head -1)
		[ -n "$tid" ] && { echo "$tid"; return 0; }
		sleep 0.2; waited=$((waited + 1))
		[ "$waited" -lt $((END_LINE_LIMIT_S * 5)) ] || break
	done
	return 1
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
	# Both proxies' access-log lines since the repetition began. One repetition runs at a time and nothing else in the
	# lab sends, so the window holds this repetition's lines (and the standing scrapes, which carry no A2A route).
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
		echo "$j $(kubectl -n "$NS" get job "$j" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pod-created=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null) container-started=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$j" --no-headers 2>/dev/null | wc -l | tr -d ' ')" >> "$d/jobs.txt"
	done
}

target_of() { case "$1" in go) echo "$GO_TARGET" ;; py) echo "$ORCH_URL" ;; esac; }
dial_of() { case "$1" in go) echo "$GO_DIAL" ;; py) echo "" ;; esac; }
host_of() { case "$1" in go) echo "$GO_HOST" ;; py) echo "" ;; esac; }

one_rep() { # $1 receiver, $2 repetition number
	local recv="$1" n; n=$(printf '%02d' "$2")
	local lwi="b4-ct-${recv}-${RUN_ID}-${n}"
	local d="$D/$recv/$lwi" target dial host; target=$(target_of "$recv"); dial=$(dial_of "$recv"); host=$(host_of "$recv")
	local j1="loadgen-$lwi" j2="" s1="" s2="" tid=""
	mkdir -p "$d"
	local steps="$d/steps.txt" since
	since=$(tsn)
	echo "$since repetition $lwi receiver=$recv target=$target dial=${dial:-<empty>} host=${host:-<empty>}" >> "$steps"
	reset_mock "$steps"
	arm_delay "$lwi" "$steps"
	echo "$(tsn) apply Job 1 $j1 MODE=stream TASK_ID=<empty> CANCEL_AFTER_MS=$K_MS" >> "$steps"
	apply_job "$lwi" "$j1" "$target" "$dial" "$host" stream "" "$K_MS" "$d/apply-1.log" || echo "$(tsn) Job 1 apply rc=$?" >> "$steps"
	echo "$(tsn) Job 1 applied" >> "$steps"
	tid=$(end_line_task "$j1") || tid=""
	echo "$(tsn) Job 1's end line names task ${tid:-<none within ${END_LINE_LIMIT_S}s>}" >> "$steps"
	if [ -n "$tid" ]; then
		j2="loadgen-$lwi-s"
		echo "$(tsn) apply Job 2 $j2 MODE=subscribe TASK_ID=$tid CANCEL_AFTER_MS=<empty>" >> "$steps"
		apply_job "$lwi" "$j2" "$target" "$dial" "$host" subscribe "$tid" "" "$d/apply-2.log" || echo "$(tsn) Job 2 apply rc=$?" >> "$steps"
		echo "$(tsn) Job 2 applied" >> "$steps"
	fi
	s1=$(wait_job "$j1"); echo "$(tsn) Job 1 $s1" >> "$steps"
	if [ -n "$j2" ]; then s2=$(wait_job "$j2"); echo "$(tsn) Job 2 $s2" >> "$steps"; fi
	reset_mock "$steps"
	collect "$lwi" "$d" "$j2" "$since"
	echo "$(tsn) collected" >> "$steps"
	say "  $recv $lwi job1=$s1${j2:+ job2=$s2}${tid:+ task=$tid} ingress=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$d/client.jsonl" 2>/dev/null | tr -d ' ')${j2:+ client-sub=$(wc -l < "$d/client-sub.jsonl" 2>/dev/null | tr -d ' ')}"
}

reset_receiver() { # $1 receiver: the receiver's own control reset, sent to its Service (nothing is armed on it here)
	local url; case "$1" in go) url="$WORKER_URL/control/reset" ;; py) url="$ORCH_URL/control/reset" ;; esac
	local c; c=$(post_json "$url" "")
	say "POST $url -> $c (nothing armed on the receiver for this row)"
	ok2xx "$c" || exit 1
}

pods_line() { kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}/ip={.status.podIP}/restarts={.status.containerStatuses[0].restartCount} {end}'; }
for recv in $RECEIVERS; do
	[ "$recv" = py ] && to_model_mode
	say "== control x $recv: $REPS repetitions; agent pods before: $(pods_line)"
	reset_receiver "$recv"
	for i in $(seq 1 "$REPS"); do one_rep "$recv" "$i"; done
	say "== control x $recv done; agent pods after: $(pods_line)"
	[ "$recv" = py ] && back_from_model_mode
done
reset_mock "$CONTROL"
say "mock reset after the row; row control done"
