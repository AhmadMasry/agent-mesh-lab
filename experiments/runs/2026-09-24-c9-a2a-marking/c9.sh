#!/usr/bin/env bash
# Experiment C, step C-9: the reading driver, run once on the standing cluster BEFORE the A2A marking (phase "base",
# C-10's build, the agent Services unmarked) and once on the cluster rebuilt with it (phase "after"). The same
# driver, unedited between the two, so that every difference between the phases is the cluster's and not the
# driver's. Nothing on any Deployment, Service, route or policy is changed by it.
#
#   bash c9.sh <phase> <reps>        RUNREL (the run directory's name) and RUN_ID (a nonce) in the environment
#
# Per repetition:
#   cards  four agent-card GETs from a curl pod in lab, one per path a client of this lab uses or could use:
#          go-ingress   the ingress Service, Host worker.lab.internal       (route lab/worker-ingress; the load client's Go path)
#          go-central   the worker's Service address                        (agw-central, lab/worker; the orchestrator's forward client)
#          py-central   the orchestrator's Service address                  (agw-central, lab/orchestrator; the load client's Python path)
#          py-ingress   the ingress Service, curl's own Host                (lab/orchestrator-ingress; where the Python card points today)
#          each body kept whole, with its headers, and both proxies' access lines in its own window.
#   then, per receiver, on B-4's paths (the Go receiver: TARGET_URL the ingress Service, CLIENT_DIAL=target,
#   CLIENT_HOST=worker.lab.internal; the Python receiver: TARGET_URL the orchestrator's Service, CLIENT_DIAL and
#   CLIENT_HOST empty, so the POST goes where the card it resolves points):
#   sm     ONE SendMessage (the load client, MODE unset).
#   sr     B-3's "subscribe-running": the mock armed {mode: delay, lwi, delay_ms: N_MS} for the work item; Job 1 ONE
#          SendStreamingMessage (MODE=stream), left open; when Job 1's first event line names the task, Job 2 ONE
#          SubscribeToTask (MODE=subscribe) for it while it runs. Both streams end at the Task's own terminal event.
#   st     ONE SubscribeToTask naming no task (MODE=subscribe, TASK_ID no-such-task-<lwi>): the receiver's error answer,
#          so that an error outcome and code is on the wire for the proxy to read. Not one of the three clean operations.
# After each work item: its three ledgers by the committed make ledgers, its client lines, and both proxies' access
# lines since it began. At the end of the phase: each work item's trace by the committed make export-trace, both
# proxies' /config_dump by follow-ups 17's config-dump.sh (unedited), and the four lab Services as the API holds them.
#
# The orchestrator stays in its deployed forward mode (it forwards SendMessage to the worker's Service), so the Python
# work items also carry the orchestrator -> agw-central -> worker leg.
# Every stimulus carries A2A-Version: 1.0 (the load client sets it; the curl GETs are not A2A calls). One send per
# Job, backoffLimit 0 (the template's), every curl --retry 0; nothing is re-sent. No retry logic.
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c10/tools/istioctl-1.31.0:$PATH"
export PATH
PHASE="${1:?phase: base or after}"
REPS="${2:?reps}"
RUNREL="${RUNREL:?RUNREL is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
case "$PHASE" in base | after) ;; *) echo "phase $PHASE" >&2; exit 1 ;; esac
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
OUTROOT="${OUTROOT:-${TMPDIR%/}/c9/run}"
D="$OUTROOT/$PHASE"
if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then echo "$D already holds files; a phase is read once" >&2; exit 1; fi
mkdir -p "$D"
NS=lab
CLUSTER_NAME=agent-mesh-lab
POD=c9-curl
CURL_IMAGE=curlimages/curl:8.22.0
TEMPLATE=deploy/base/loadgen-a2-job.yaml
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
N_MS=10000
JOB_LIMIT_S=90
FIRST_EVENT_LIMIT_S=60
COLLECT_WAIT=2
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
LOG="$D/phase.txt"
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$LOG"; }

cleanup() { local rc=$?; kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; say "phase $PHASE driver exit=$rc"; exit "$rc"; }
trap cleanup EXIT

say "phase $PHASE, reps $REPS, RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD) ($(git log --format=%s -1)); deploy subtree $(git rev-parse HEAD:deploy); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1)"
say "N_MS=$N_MS; template $TEMPLATE blob $(git rev-parse "HEAD:$TEMPLATE")"

# --- the cluster as it stands --------------------------------------------------------------------------------------
kubectl get svc -n "$NS" -o json | jq '[.items[] | {name: .metadata.name, ports: [.spec.ports[] | {name, port, appProtocol}]}]' > "$D/services.json"
say "lab Services' ports: $(jq -c '[.[] | {(.name): [.ports[] | "\(.name):\(.port):\(.appProtocol // "<unset>")"]}] | add' "$D/services.json")"
kubectl get httproute -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) retry=\([.spec.rules[] | select(.retry != null)] | length) hosts=\(.spec.hostnames // [] | join(","))"' > "$D/routes.txt"
say "routes: $(tr '\n' ';' < "$D/routes.txt")"
say "AgentgatewayPolicies: $(kubectl get agentgatewaypolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' '); AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
pods_line() { kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace as $n | ["lab","agentgateway-ingress","agentgateway-waypoint"] | index($n)) | select(.metadata.name | test("^(worker|orchestrator|mockllm|agentgateway-ingress|agw-central)-")) | "\(.metadata.namespace)/\(.metadata.name) ip=\(.status.podIP) uid=\(.metadata.uid) restarts=\(.status.containerStatuses[0].restartCount)"'; }
pods_line > "$D/pods-before.txt"
say "pods: $(tr '\n' ';' < "$D/pods-before.txt")"
INGRESS_IP=$(kubectl -n agentgateway-ingress get pods -l gateway.networking.k8s.io/gateway-name=agentgateway-ingress -o jsonpath='{.items[0].status.podIP}')
CENTRAL_IP=$(kubectl -n agentgateway-waypoint get pods -l gateway.networking.k8s.io/gateway-name=agw-central -o jsonpath='{.items[0].status.podIP}')
say "proxy pod IPs: agentgateway-ingress=$INGRESS_IP agw-central=$CENTRAL_IP"
echo "agentgateway-ingress,$INGRESS_IP" > "$D/proxy-ips.csv"; echo "agw-central,$CENTRAL_IP" >> "$D/proxy-ips.csv"
for dep in worker orchestrator; do
	say "deployment/$dep env PUBLIC_URL=$(kubectl -n "$NS" get deployment/$dep -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PUBLIC_URL")].value}') DOWNSTREAM_A2A_URL=$(kubectl -n "$NS" get deployment/$dep -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}') REFUSE_OPERATION=[$(kubectl -n "$NS" get deployment/$dep -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REFUSE_OPERATION")].value}')]"
done

# --- the curl pod, the certificate check, the image --------------------------------------------------------------
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 7200 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null || { say "curl pod not ready"; exit 1; }
say "curl pod $POD ip=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')"
istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" > "$D/certificates.txt" 2>&1
if awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' "$D/certificates.txt" | grep -qx true; then
	say "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default"
else
	say "certificate check: VALID CERT is not true; this driver restarts nothing -- stopping"; exit 1
fi
t0=$(tsn)
IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/c9/ko-build-$PHASE.log")
rc=$?
echo "$t0 ko build ./fixtures/loadgen (KO_DOCKER_REPO=kind.local) rc=$rc image=${IMAGE:-<none>} fixtures=$(git rev-parse HEAD:fixtures)" > "$D/image.txt"
case "$IMAGE" in kind.local/loadgen-*:*) ;; *) say "the image could not be resolved (rc=$rc); stopping"; exit 1 ;; esac
say "image resolved once for the phase: $IMAGE"

post_json() { # $1 url, $2 body -> http code
	kubectl -n "$NS" exec "$POD" -- curl -sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' ${2:+-d "$2"} "$1" 2>/dev/null
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
reset_mock() { local c; c=$(post_json "$MOCK_URL/control/reset" ""); echo "$(tsn) POST $MOCK_URL/control/reset -> $c" >> "$1"; ok2xx "$c" || { say "mock reset returned $c"; exit 1; }; }
arm_delay() { local body c; body=$(printf '{"mode":"delay","lwi":"%s","delay_ms":%d}' "$1" "$N_MS"); c=$(post_json "$MOCK_URL/control/inject" "$body"); echo "$(tsn) POST $MOCK_URL/control/inject $body -> $c" >> "$2"; ok2xx "$c" || { say "arming the mock returned $c"; exit 1; }; }

proxy_lines() { # $1 since, $2 dir
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$1" 2>/dev/null | grep 'request gateway=' > "$2/agw-central-access.txt" || true
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$1" 2>/dev/null | grep 'request gateway=' > "$2/ingress-access.txt" || true
}

# --- cards -------------------------------------------------------------------------------------------------------
card() { # $1 name, $2 url, $3 host or "", $4 rep
	local name="$1" url="$2" host="$3" w="$D/cards/$4/$1" since code rc
	mkdir -p "$w"; since=$(tsn)
	local hh=(); [ -n "$host" ] && hh=(-H "Host: $host")
	kubectl -n "$NS" exec "$POD" -- curl -sS -D - --retry 0 --max-time 10 ${hh[@]+"${hh[@]}"} -H "X-Logical-Work-Item-Id: c9-card-$PHASE-$name-$RUN_ID-$4" "$url/.well-known/agent-card.json" > "$w/response.txt" 2> "$w/curl-stderr.txt"
	rc=$?
	code=$(head -1 "$w/response.txt" | awk '{print $2}')
	awk 'BEGIN{b=0} b{print} /^\r?$/{b=1}' "$w/response.txt" > "$w/card.json"
	jq -S . "$w/card.json" > "$w/card.pretty.json" 2>/dev/null || true
	sleep 1; proxy_lines "$since" "$w"
	echo "$since card $name url=$url/.well-known/agent-card.json host=${host:-<curl default>} http=$code exit=$rc interfaces=$(jq -c '[.supportedInterfaces[]? | .url]' "$w/card.json" 2>/dev/null) content-length=$(grep -i '^content-length:' "$w/response.txt" | tr -d '\r' | awk '{print $2}')" | tee -a "$D/cards.txt" >> "$LOG"
}

# --- Jobs ----------------------------------------------------------------------------------------------------------
target_of() { case "$1" in go) echo "$INGRESS" ;; py) echo "$ORCH_URL" ;; esac; }
dial_of() { case "$1" in go) echo target ;; py) echo "" ;; esac; }
host_of() { case "$1" in go) echo worker.lab.internal ;; py) echo "" ;; esac; }
apply_job() { # $1 lwi, $2 job name, $3 recv, $4 MODE, $5 TASK_ID, $6 log
	local lwi="$1" name="$2" recv="$3" mode="$4" task="$5" log="$6" rc=0
	kubectl -n "$NS" delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/^  name: loadgen-\${LWI}\$/  name: ${name}/" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#$(target_of "$recv")#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/$(dial_of "$recv")/g" -e "s/\${CLIENT_HOST}/$(host_of "$recv")/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" \
		"$TEMPLATE" > "${log%.log}.yaml"
	if grep -q '\${' "${log%.log}.yaml" || ! grep -q "image: ${IMAGE}\$" "${log%.log}.yaml"; then
		echo "rendered Job $name has a placeholder left or not the resolved image; not applied" > "$log"; return 1
	fi
	kubectl apply -f "${log%.log}.yaml" > "$log" 2>&1 || rc=$?
	return "$rc"
}
job_state() { kubectl -n "$NS" get job "$1" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1; }
wait_job() { local waited=0 st; while [ "$waited" -lt "$JOB_LIMIT_S" ]; do st=$(job_state "$1"); [ -n "$st" ] && { echo "$st"; return 0; }; sleep 1; waited=$((waited + 1)); done; echo timeout; }
first_event_task() { local waited=0 tid; while :; do tid=$(kubectl -n "$NS" logs "job/$1" 2>/dev/null | jq -R -r 'fromjson? | select(.ledger == "client" and .line == "event" and .seq == 1) | .taskId' | head -1); [ -n "$tid" ] && { echo "$tid"; return 0; }; sleep 0.2; waited=$((waited + 1)); [ "$waited" -lt $((FIRST_EVENT_LIMIT_S * 5)) ] || return 1; done; }
collect() { # $1 lwi, $2 dir, $3 job2 or "", $4 since
	local lwi="$1" d="$2" j2="$3" since="$4" rc=0
	sleep "$COLLECT_WAIT"
	proxy_lines "$since" "$d"
	make --no-print-directory ledgers "LWI=$lwi" "OUT=$d" >/dev/null 2>"$d/ledgers-stderr.txt" || rc=$?
	echo "$(tsn) make ledgers LWI=$lwi exit=$rc" >> "$d/steps.txt"
	if [ -n "$j2" ]; then
		kubectl -n "$NS" logs -l "job-name=$j2" --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "client")' > "$d/client-sub.jsonl" 2>/dev/null || true
	fi
	for j in "loadgen-$lwi" $j2; do
		echo "$j $(kubectl -n "$NS" get job "$j" -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}' 2>/dev/null) pod-exit=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null) pod-ip=$(kubectl -n "$NS" get pods -l "job-name=$j" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null) pods=$(kubectl -n "$NS" get pods -l "job-name=$j" --no-headers 2>/dev/null | wc -l | tr -d ' ')" >> "$d/jobs.txt"
	done
}
LWIS="$D/work-items.txt"
one() { # $1 recv, $2 kind, $3 rep
	local recv="$1" kind="$2" n; n=$(printf '%02d' "$3")
	local lwi="c9-$PHASE-$recv-$kind-$RUN_ID-$n" d s1 s2="" j2="" tid=""
	d="$D/$recv/$lwi"; mkdir -p "$d"
	local steps="$d/steps.txt" since; since=$(tsn)
	echo "$since work item $lwi recv=$recv kind=$kind target=$(target_of "$recv") dial=$(dial_of "$recv") host=$(host_of "$recv")" >> "$steps"
	echo "$lwi" >> "$LWIS"
	reset_mock "$steps"
	case "$kind" in
	sm) apply_job "$lwi" "loadgen-$lwi" "$recv" "" "" "$d/apply-1.log" || echo "$(tsn) apply rc=$?" >> "$steps" ;;
	st) apply_job "$lwi" "loadgen-$lwi" "$recv" subscribe "no-such-task-$lwi" "$d/apply-1.log" || echo "$(tsn) apply rc=$?" >> "$steps" ;;
	sr)
		arm_delay "$lwi" "$steps"
		apply_job "$lwi" "loadgen-$lwi" "$recv" stream "" "$d/apply-1.log" || echo "$(tsn) apply 1 rc=$?" >> "$steps"
		echo "$(tsn) Job 1 applied" >> "$steps"
		tid=$(first_event_task "loadgen-$lwi") || tid=""
		echo "$(tsn) Job 1's first event names task ${tid:-<none>}" >> "$steps"
		if [ -n "$tid" ]; then
			j2="loadgen-$lwi-s"
			apply_job "$lwi" "$j2" "$recv" subscribe "$tid" "$d/apply-2.log" || echo "$(tsn) apply 2 rc=$?" >> "$steps"
			echo "$(tsn) Job 2 applied" >> "$steps"
		fi
		;;
	esac
	s1=$(wait_job "loadgen-$lwi"); echo "$(tsn) Job 1 $s1" >> "$steps"
	if [ -n "$j2" ]; then s2=$(wait_job "$j2"); echo "$(tsn) Job 2 $s2" >> "$steps"; fi
	reset_mock "$steps"
	collect "$lwi" "$d" "$j2" "$since"
	say "  $recv $kind $lwi job1=$s1${j2:+ job2=$s2}${tid:+ task=$tid} ingress=$(wc -l < "$d/ingress.jsonl" 2>/dev/null | tr -d ' ') execution=$(wc -l < "$d/execution.jsonl" 2>/dev/null | tr -d ' ') invocation=$(wc -l < "$d/invocation.jsonl" 2>/dev/null | tr -d ' ') client=$(wc -l < "$d/client.jsonl" 2>/dev/null | tr -d ' ') ingress-proxy-lines=$(wc -l < "$d/ingress-access.txt" | tr -d ' ') agw-central-lines=$(wc -l < "$d/agw-central-access.txt" | tr -d ' ')"
}

say "mock reset before the phase"; reset_mock "$LOG"
for i in $(seq 1 "$REPS"); do
	say "== repetition $i: cards"
	card go-ingress "$INGRESS" worker.lab.internal "$i"
	card go-central "$WORKER_URL" "" "$i"
	card py-central "$ORCH_URL" "" "$i"
	card py-ingress "$INGRESS" "" "$i"
	for recv in go py; do
		for kind in sm sr st; do one "$recv" "$kind" "$i"; done
	done
done

# --- end of phase: traces, config dumps ---------------------------------------------------------------------------
sleep 6
while read -r lwi; do
	recv=$(echo "$lwi" | cut -d- -f3)
	rc=0; make --no-print-directory export-trace "LWI=$lwi" "OUT=$D/$recv/$lwi/trace" LOOKBACK=7200 > "$D/$recv/$lwi/export-trace.txt" 2>&1 || rc=$?
	echo "$(ts) export-trace $lwi exit=$rc" >> "$LOG"
done < "$LWIS"
say "traces exported: $(grep -c 'exit=0' <(grep export-trace "$LOG")) of $(wc -l < "$LWIS" | tr -d ' ')"
mkdir -p "$D/proxies"
for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
	set -- $pair
	bash "$F17/config-dump.sh" "$1" "$2" "$D/proxies/$2.config-dump.json" > "$D/proxies/$2.summary.txt" 2>&1 || say "config dump $2 rc=$?"
	say "config dump $2: policies $(jq '.policies | length' "$D/proxies/$2.config-dump.json" 2>/dev/null); A2A policies $(jq '[.policies[]? | select(tostring | test("a2a"; "i"))] | length' "$D/proxies/$2.config-dump.json" 2>/dev/null)"
done
pods_line > "$D/pods-after.txt"
say "pods after: $(tr '\n' ';' < "$D/pods-after.txt")"
reset_mock "$LOG"
say "phase $PHASE done"
