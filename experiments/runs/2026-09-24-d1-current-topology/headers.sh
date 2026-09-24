#!/usr/bin/env bash
# Follow-on D-1: the header reading. Which request headers reach each application, and does any caller identity
# arrive in one -- the thread C-10 left open ("which headers the proxies forward was not captured in this step").
#
# LEDGER_HEADERS=on is set on BOTH agent Deployments for a short window (kubectl set env, both rollouts waited for)
# and restored EMPTY by the EXIT trap. With it on, each agent's pre-dispatch ingress ledger writes on every arrival
# line the header names that arrived, the values of a fixed list (host, user-agent, x-caller, forwarded,
# x-forwarded-for, x-forwarded-proto, x-forwarded-host, x-real-ip, via, x-forwarded-client-cert) and whether an
# Authorization header was present, never its value (agents/worker/headers.go, agents/orchestrator/orchestrator/
# headers.py).
#
# What is sent, once each, one Job and one process per request, through B-4's paths:
#   go  the load client to the agentgateway ingress's Service with CLIENT_DIAL=target and CLIENT_HOST=worker.lab.internal
#       (the ingress's worker-ingress route): one SendMessage, one SendStreamingMessage, one SubscribeToTask naming
#       the task the stream created (by then terminal; its answer is recorded and does not matter here: the arrival
#       line is written before the SDK sees the request).
#   py  the load client to the orchestrator's Service with both empty (the card GET crosses lab/orchestrator on
#       agw-central, the POSTs go where the card points, the ingress's lab/orchestrator-ingress): the same three.
#       The orchestrator is in its deployed forward mode, so each SendMessage and SendStreamingMessage it serves is
#       forwarded to the worker's Service through agw-central: that is "the orchestrator's forward to the worker",
#       and its arrival at the worker is read the same way.
# Every request's card GET is an arrival too, and is read as such.
# The mock is reset before and after and never armed. Nothing is retried or re-sent; a request that fails is recorded.
#   bash headers.sh   RUN_ID=<nonce> RUNREL=<run dir name> required
# Keep-awake: this driver starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUN_ID="${RUN_ID:-}"
RUNREL="${RUNREL:-}"
NS=lab
CLUSTER_NAME=agent-mesh-lab
CURL_POD=d1-curl
CURL_IMAGE=curlimages/curl:8.22.0
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
GO_TARGET=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
TEMPLATE=deploy/base/loadgen-a2-job.yaml
JOB_LIMIT_S=120
case "$RUN_ID" in '' | *[!a-z0-9]*) echo "headers: RUN_ID=$RUN_ID must be lower-case letters and digits" >&2; exit 1 ;; esac
[ -n "$RUNREL" ] || { echo "headers: RUNREL is required" >&2; exit 1; }
D="experiments/runs/$RUNREL/headers"
if [ -e "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then echo "headers: $D already holds files" >&2; exit 1; fi
mkdir -p "$D"
CONTROL="$D/control.txt"
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
say() { echo "$(ts) $*" | tee -a "$CONTROL"; }
envof() { kubectl -n "$NS" get "deployment/$1" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}"; }

say "header reading: RUN_ID $RUN_ID; HEAD $(git rev-parse HEAD); this driver sha256 $(shasum -a 256 "$0" | cut -d' ' -f1)"
RESTORE=no
cleanup() {
	local rc=$?
	kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$RESTORE" = yes ]; then
		local s=0 r1=0 r2=0
		kubectl -n "$NS" set env deployment/worker deployment/orchestrator LEDGER_HEADERS= >/dev/null 2>&1 || s=$?
		kubectl -n "$NS" rollout status deployment/worker --timeout=180s >/dev/null 2>&1 || r1=$?
		kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || r2=$?
		if [ "$s$r1$r2" = 000 ] && [ -z "$(envof worker LEDGER_HEADERS)$(envof orchestrator LEDGER_HEADERS)" ]; then
			say "restored: LEDGER_HEADERS=[$(envof worker LEDGER_HEADERS)] on worker, [$(envof orchestrator LEDGER_HEADERS)] on orchestrator (set env rc=0, rollouts rc=0)"
		else
			say "RESTORE FAILED (set env rc=$s, rollouts rc=$r1/$r2): LEDGER_HEADERS is to be put back empty"; rc=1
		fi
	fi
	say "header reading driver exit=$rc"
	exit "$rc"
}
trap cleanup EXIT

kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=90s >/dev/null || { say "control pod not ready"; exit 1; }
post_json() { kubectl -n "$NS" exec "$CURL_POD" -- curl -sS --retry 0 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$1" 2>/dev/null; }

for dep in worker orchestrator; do
	say "before: deployment/$dep LEDGER_HEADERS=[$(envof $dep LEDGER_HEADERS)] FORWARD_RESUBSCRIBE=[$(envof $dep FORWARD_RESUBSCRIBE)] REFUSE_OPERATION=[$(envof $dep REFUSE_OPERATION)] DOWNSTREAM_A2A_URL=[$(envof $dep DOWNSTREAM_A2A_URL)]"
	[ -z "$(envof $dep LEDGER_HEADERS)" ] || { say "LEDGER_HEADERS is not empty before the reading; stopping"; exit 1; }
done
RESTORE=yes
say "set LEDGER_HEADERS=on on deployment/worker and deployment/orchestrator"
kubectl -n "$NS" set env deployment/worker deployment/orchestrator LEDGER_HEADERS=on >/dev/null
kubectl -n "$NS" rollout status deployment/worker --timeout=180s >/dev/null || { say "worker rollout failed"; exit 1; }
kubectl -n "$NS" rollout status deployment/orchestrator --timeout=180s >/dev/null || { say "orchestrator rollout failed"; exit 1; }
for app in worker orchestrator; do
	w=0; while [ "$(kubectl -n "$NS" get pods -l app=$app --no-headers 2>/dev/null | wc -l | tr -d ' ')" != 1 ] && [ "$w" -lt 120 ]; do sleep 1; w=$((w + 1)); done
	say "after set: $app pods $(kubectl -n "$NS" get pods -l app=$app -o jsonpath='{range .items[*]}{.metadata.name} LEDGER_HEADERS={.spec.containers[0].env[?(@.name=="LEDGER_HEADERS")].value} uid={.metadata.uid}; {end}')"
done
say "proxy pods: $(kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name in (agw-central,agentgateway-ingress)' -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ip={.status.podIP}; {end}')"
say "agent pods: $(kubectl -n "$NS" get pods -l 'app in (worker,orchestrator,mockllm)' -o jsonpath='{range .items[*]}{.metadata.name} ip={.status.podIP}; {end}')"
SINCE=$(tsn)
echo "$SINCE the reading window opens" >> "$CONTROL"

IMAGE=$(KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko build --platform="linux/$(go env GOARCH)" ./fixtures/loadgen 2>"${TMPDIR%/}/d1/work/ko-build-$RUN_ID-headers.log") || true
case "$IMAGE" in kind.local/loadgen-*:*) say "image: $IMAGE" ;; *) say "the image could not be resolved; stopping"; exit 1 ;; esac
say "mock reset -> $(post_json "$MOCK_URL/control/reset")"

send() { # $1 recv, $2 kind (unary|stream|subscribe), $3 task id -> writes the Job's client lines; echoes its end line
	local recv="$1" kind="$2" task="${3:-}" target dial host mode lwi name y
	case "$recv" in go) target=$GO_TARGET; dial=target; host=worker.lab.internal ;; py) target=$ORCH_URL; dial=""; host="" ;; esac
	case "$kind" in unary) mode="" ;; stream) mode=stream ;; subscribe) mode=subscribe ;; esac
	lwi="d1-hdr-${recv}-${kind}-${RUN_ID}"
	name="loadgen-$lwi"; y="$D/$lwi.yaml"
	sed -e "s#^\(          image: \)ko://github.com/AhmadMasry/agent-mesh-lab/fixtures/loadgen\$#\1${IMAGE}#" \
		-e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" \
		-e "s/\${CLIENT_RETRIES}/0/g" -e "s/\${CLIENT_SDK_RESEND}/off/g" \
		-e "s/\${CLIENT_RETRY_ON}/transport/g" -e "s/\${CLIENT_DIAL}/${dial}/g" -e "s/\${CLIENT_HOST}/${host}/g" \
		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" "$TEMPLATE" > "$y"
	grep -q '\${' "$y" && { say "placeholder left in $y; stopping"; exit 1; }
	echo "$(tsn) apply $name recv=$recv kind=$kind task=${task:-<empty>}" >> "$CONTROL"
	kubectl apply -f "$y" >> "$CONTROL" 2>&1
	local w=0 st=""
	while [ "$w" -lt "$JOB_LIMIT_S" ]; do
		st=$(kubectl -n "$NS" get job "$name" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^(Complete|Failed)$' | head -1)
		[ -n "$st" ] && break; sleep 1; w=$((w + 1))
	done
	echo "$(tsn) $name ${st:-timeout}" >> "$CONTROL"
	kubectl -n "$NS" logs -l "job-name=$name" --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "client")' > "$D/$lwi.client.jsonl"
	say "  $lwi ${st:-timeout}: $(jq -r 'select(.line == "end" or .result_kind != null) | "\(.stream_end // "unary") \(.last_state // .state // "") task=\(.taskId)"' "$D/$lwi.client.jsonl" | tail -1)"
}
taskof() { jq -r 'select(.line == "end") | .taskId' "$1" | tail -1; }

for recv in go py; do
	send "$recv" unary
	send "$recv" stream
	t=$(taskof "$D/d1-hdr-${recv}-stream-${RUN_ID}.client.jsonl")
	[ -n "$t" ] || say "  no task id on the $recv stream's end line; the SubscribeToTask names none"
	send "$recv" subscribe "$t"
done
sleep 3
UNTIL=$(tsn)
echo "$UNTIL the reading window closes" >> "$CONTROL"
say "mock reset -> $(post_json "$MOCK_URL/control/reset")"
for app in worker orchestrator; do
	kubectl -n "$NS" logs "deploy/$app" --since-time="$SINCE" 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "ingress")' > "$D/$app-ingress.jsonl"
	kubectl -n "$NS" logs "deploy/$app" --since-time="$SINCE" 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "execution")' > "$D/$app-execution.jsonl"
	say "  $app: $(wc -l < "$D/$app-ingress.jsonl" | tr -d ' ') ingress lines, $(jq -c 'select(.phase == "arrival" and .headers != null)' "$D/$app-ingress.jsonl" | wc -l | tr -d ' ') arrivals carrying the reading"
done
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$SINCE" 2>/dev/null | grep 'request gateway=' > "$D/ingress-proxy-access.txt" || true
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$SINCE" 2>/dev/null | grep 'request gateway=' > "$D/agw-central-access.txt" || true
say "done"
