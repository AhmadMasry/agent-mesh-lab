#!/usr/bin/env bash
# Gate 3 / gateway retry mechanics.
#
# Asks one question of each of the three gateway routes: with the experimental
# HTTPRoute retry stanza on, and one failure injected on the hop that route
# serves, does the proxy re-send the request, and are the two deliveries the same
# bytes carrying the same identity?
#
# The stanza is switched on for the route under test and off again afterwards.
# Two things are recorded separately and must not be confused:
#
#   the proxy HOLDS the policy   read once per route from the proxy's own
#                                /config_dump, which is the check the
#                                agentgateway documentation gives
#   the proxy FIRED the retry    counted from the receiver's pre-dispatch ingress
#                                ledger (waypoint, ingress) or the model
#                                endpoint's invocation ledger (egress)
#
# A proxy that holds the policy and does not fire it is a finding, not a failure.
#
# The three routes and how each is stimulated:
#
#   waypoint  the `worker` HTTPRoute in `lab`, served by the istiod-driven
#             agentgateway waypoint. One loadgen Job in-cluster to the worker
#             Service, whose pod is ztunnel-captured, so the request crosses that
#             waypoint. The worker is armed with `http503-before-dispatch` for the
#             repetition's work item: the arrival is counted on the ingress ledger
#             and then answered 503, and the arming disarms itself, so a second
#             delivery is served normally.
#   ingress   `worker-ingress` and the `orchestrator-ingress` catch-all on the
#             agentgateway ingress. The stimulus is out-of-cluster, per the
#             project's stimulus-path rule: a `kind` port-forward to the ingress
#             Service and one POST from this host, addressed to the worker by its
#             `worker.lab.internal` hostname, with the same injection armed.
#   egress    `model-via-agw` in `agentgateway-egress`, the route to
#             model.lab.internal. One clean loadgen Job to the worker; the model
#             endpoint is armed with `http500` for the work item, so the worker's
#             one model call fails at the egress waypoint and the count that
#             matters is the model endpoint's.
#
# No retry logic in this script, and no repetition of a delivery: each repetition
# is one stimulus, and any second arrival was made by the gateway under test. A
# repetition whose Job failed is recorded in the notes column and never re-run,
# because a re-run would be another delivery.
#
#   ROUTE=<waypoint|ingress|egress>  required.
#   REPS=<n>                         default 5. An empty or non-numeric value is
#                                    an error; a silent default here spends
#                                    repetitions that cannot be taken back.
#   DRY_RUN=<on|off>                 default on. One repetition under a scratch
#                                    nonce, whose directory is deleted, before the
#                                    measured ones.
#   DUMP_ONLY=<on|off>               default off. Switch the stanza on, read the
#                                    proxy's /config_dump, switch it off, and send
#                                    nothing. The read-back is a separate question
#                                    from whether the retry fires, and re-reading
#                                    it must not cost repetitions.
#   RUN_ID=<nonce>                   default $(date +%H%M%S). Every work-item id
#                                    carries it: pod logs and the trace backend
#                                    both outlive a run, and a repeated id would
#                                    collect an earlier run's lines and spans as
#                                    this run's.
#   RUN_ITEM=<name>                  default <date>-a3-gateway-retry-mechanics;
#                                    names the run directory under experiments/runs/.
#   COLLECT_WAIT=<seconds>           default 2, between the client returning and
#                                    `make ledgers`.
#   TRACE_WAIT=<seconds>             default 8, before `make export-trace`: the
#                                    batch span processors flush on a timer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
ROUTE="${ROUTE:-}"
REPS="${REPS-5}"
DRY_RUN="${DRY_RUN:-on}"
DUMP_ONLY="${DUMP_ONLY:-off}"
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
COLLECT_WAIT="${COLLECT_WAIT:-2}"
TRACE_WAIT="${TRACE_WAIT:-8}"
CURL_POD="a3r-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"
INGRESS_NS="agentgateway-system"
INGRESS_PORT=18080
ADMIN_PORT=15002

usage() {
	echo "usage: ROUTE=<waypoint|ingress|egress> [REPS=5] [DRY_RUN=on|off] [DUMP_ONLY=on|off] [RUN_ID=<nonce>] [RUN_ITEM=<name>] $0" >&2
	exit 1
}

case "$ROUTE" in waypoint | ingress | egress) ;; *) usage ;; esac
case "$REPS" in '' | *[!0-9]*) echo "gate3-retry: REPS=${REPS} is not a positive integer" >&2 && exit 1 ;; esac
[ "$REPS" -ge 1 ] || {
	echo "gate3-retry: REPS=${REPS} is not a positive integer" >&2
	exit 1
}
case "$DRY_RUN" in on | off) ;; *) usage ;; esac
case "$DUMP_ONLY" in on | off) ;; *) usage ;; esac

# Work-item ids are lowercased and checked before anything uses one. They become
# Job names, which reject an uppercase letter, and they are the key every ledger
# and every trace query is read by, so a rejected id has to stop the run rather
# than produce a repetition nothing can be collected for.
RUN_ID="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]')"
work_item() { # $1 = repetition label -> the id, validated
	local id="a3r-${ROUTE}-${RUN_ID}-$1"
	id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
	if ! printf '%s' "$id" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
		echo "gate3-retry: work item id ${id} is not a usable Job name; set RUN_ID to something lowercase and alphanumeric" >&2
		exit 1
	fi
	printf '%s' "$id"
}

RUN_ITEM="${RUN_ITEM:-$(date +%F)-a3-gateway-retry-mechanics}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
mkdir -p "$RUN_DIR"
CONTROL_FILE="${RUN_DIR}/control.txt"
SUMMARY="${RUN_DIR}/summary.csv"

# One run directory holds one run per route. Rows are appended as they are
# produced, so a directory whose numbers a findings entry already cites must not
# grow with rows from a second nonce for the same route. Refuse before anything
# is sent. A DUMP_ONLY read appends no row and sends nothing, so it is exempt:
# re-reading a policy must not be blocked by the repetitions it does not touch.
if [ -s "$SUMMARY" ] && [ "$DUMP_ONLY" = "off" ]; then
	foreign=$(awk -F, -v r="$ROUTE" -v id="-${RUN_ID}-" 'NR > 1 && $1 == r && index($2, id) == 0 { n++ } END { print n + 0 }' "$SUMMARY")
	if [ "$foreign" != "0" ]; then
		echo "gate3-retry: ${SUMMARY} already holds ${foreign} ${ROUTE} rows from another run (this run's nonce is ${RUN_ID}); set RUN_ITEM to a new directory, or RUN_ID to the existing run's nonce to chunk it" >&2
		exit 1
	fi
fi

# --- restore ------------------------------------------------------------------
# The stanza this run switches on, and the injectors it arms, are put back on
# every exit path. A failed restore says so on stderr, records it, and leaves the
# script non-zero: the alternative is a later run measuring a cluster that still
# carries a retry.
RESTORE_ROUTE="no"
PF_INGRESS=""
cleanup() {
	trigger_rc=$?
	if [ -n "$PF_INGRESS" ]; then
		kill "$PF_INGRESS" >/dev/null 2>&1 || true
		wait "$PF_INGRESS" 2>/dev/null || true
	fi
	if [ "$RESTORE_ROUTE" = "yes" ]; then
		echo "== restoring the ${ROUTE} route: removing the retry stanza =="
		off_rc=0
		make --no-print-directory retry-off "ROUTE=${ROUTE}" "OUT=${RUN_DIR}/routes-off-${ROUTE}" >>"$CONTROL_FILE" 2>&1 || off_rc=$?
		left=$(kubectl get httproute -A -o yaml 2>/dev/null | grep -c 'retry:' || true)
		if [ "$off_rc" = "0" ] && [ "$left" = "0" ]; then
			printf '%s retry-off ROUTE=%s restored; retry stanzas across every HTTPRoute: 0\n' "$(date -u +%FT%TZ)" "$ROUTE" | tee -a "$CONTROL_FILE"
		else
			printf '%s RESTORE FAILED (retry-off rc=%s, retry stanzas still present: %s). Put it back with: make retry-off\n' \
				"$(date -u +%FT%TZ)" "$off_rc" "$left" | tee -a "$CONTROL_FILE" >&2
			echo "gate3-retry: the ${ROUTE} route was NOT restored; see ${CONTROL_FILE}" >&2
			kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
			exit 1
		fi
	fi
	# The injectors are disarmed last, while the control pod still exists.
	reset_all_quiet
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	return "$trigger_rc"
}

# --- certificate check --------------------------------------------------------
CERT_FILE="${RUN_DIR}/certificates.txt"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEADER="== ${STAMP} | ROUTE=${ROUTE} | RUN_ID=${RUN_ID} | REPS=${REPS} =="
echo "== certificate check =="
CERTS="$(istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker")"
printf '%s\n' "$HEADER" "$CERTS" "" >>"$CERT_FILE"
printf '%s\n' "$CERTS"
if ! printf '%s\n' "$CERTS" | awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' | grep -qx true; then
	echo "certificate check: VALID CERT is not true for spiffe://cluster.local/ns/lab/sa/default; restarting ztunnel" >&2
	kubectl -n istio-system rollout restart daemonset/ztunnel
	kubectl -n istio-system rollout status daemonset/ztunnel --timeout=180s
	CERTS="$(istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker")"
	printf '%s\n' "== after a ztunnel restart ==" "$CERTS" "" >>"$CERT_FILE"
	printf '%s\n' "$CERTS" | awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' | grep -qx true || {
		echo "certificate check: VALID CERT still not true after a ztunnel restart" >&2
		exit 1
	}
	echo "certificate check: VALID CERT true after a ztunnel restart"
else
	echo "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default; ztunnel not restarted"
fi

{
	printf '%s\n' "$HEADER"
	kubectl version
	istioctl version --remote=false
	kubectl -n "$NAMESPACE" get deploy -o wide
	kubectl get httproute -A
	kubectl get gateway -A
	echo
} >>"${RUN_DIR}/cluster-versions.txt" 2>&1

# The retry stanza is `<gateway:experimental>` at the pinned Gateway API version and
# exists only in the experimental CRD. Which CRD the cluster actually serves is a
# property of the cluster, not of the manifest that installed it, so it is read back
# here and committed beside the counts rather than quoted from the install URL.
{
	printf '%s\n' "$HEADER"
	echo "\$ kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}'"
	kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}'
	echo
	echo
	echo "\$ kubectl explain httproute.spec.rules.retry --recursive"
	kubectl explain httproute.spec.rules.retry --recursive
	echo
} >>"${RUN_DIR}/crd-httproute.txt" 2>&1

# --- the baseline this run starts from ----------------------------------------
# Every row in this gate is measured against a cluster whose routes carry no
# retry. That is asserted here rather than assumed, before the stanza goes on.
BEFORE=$(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)
printf '%s ROUTE=%s pre-run retry stanzas across every HTTPRoute: %s\n' "$(date -u +%FT%TZ)" "$ROUTE" "$BEFORE" | tee -a "$CONTROL_FILE"
if [ "$BEFORE" != "0" ]; then
	echo "gate3-retry: the cluster already carries ${BEFORE} retry stanza(s); run 'make retry-off' and start from the baseline" >&2
	exit 1
fi

# --- control pod --------------------------------------------------------------
echo "== starting the control pod =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

post() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST "$1"; }
post_json() { # $1 = url, $2 = body
	kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' \
		-X POST -H 'Content-Type: application/json' -d "$2" "$1"
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

reset_all() {
	local url code
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url")
		ok2xx "$code" || {
			echo "gate3-retry: reset ${url} returned ${code}" >&2
			exit 1
		}
	done
}
# The restore path cannot exit on a reset that fails; it reports and carries on,
# so the route stanza is still removed.
reset_all_quiet() {
	local url code
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url" 2>/dev/null || echo "000")
		printf '%s POST %s -> %s (restore)\n' "$(date -u +%FT%TZ)" "$url" "$code" >>"$CONTROL_FILE"
	done
}

# Armed here rather than at the top of the script: everything it puts back is
# created below it, and everything above it changes nothing in the cluster.
trap cleanup EXIT

printf '%s run %s: route=%s reps=%s\n' "$(date -u +%FT%TZ)" "$RUN_ID" "$ROUTE" "$REPS" | tee -a "$CONTROL_FILE"

# Arming an injector addresses a Service, and a Service load-balances: with more
# than one replica the arming lands on one pod while the request that should fire
# it can reach another, and `make ledgers` reads one pod's log either way. Both
# counts would be wrong and neither would say so, so the replica count is asserted
# and recorded here, before anything is armed.
assert_single_replica() { # $1 = deployment name
	local deploy="$1" spec ready
	spec=$(kubectl -n "$NAMESPACE" get "deployment/${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
	ready=$(kubectl -n "$NAMESPACE" get "deployment/${deploy}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
	printf '%s deployment/%s replicas: spec=%s ready=%s\n' \
		"$(date -u +%FT%TZ)" "$deploy" "${spec:-<none>}" "${ready:-0}" | tee -a "$CONTROL_FILE"
	if [ "$spec" != "1" ] || [ "${ready:-0}" != "1" ]; then
		echo "gate3-retry: deployment/${deploy} is not at exactly one ready replica (spec=${spec:-<none>} ready=${ready:-0}); scale it to 1 before an injector is armed through its Service" >&2
		exit 1
	fi
}
assert_single_replica worker
assert_single_replica mockllm
reset_all

# --- the stanza ---------------------------------------------------------------
# Which proxy serves this route, and how many routes the stanza lands on. The
# expected count is named per route so the apply can be checked rather than
# trusted: `ingress` patches two routes, the other two patch one each.
case "$ROUTE" in
waypoint) PROXY_NS="lab" PROXY_DEPLOY="agentgateway-waypoint" EXPECTED_STANZAS=1 ;;
ingress) PROXY_NS="agentgateway-system" PROXY_DEPLOY="agentgateway-ingress" EXPECTED_STANZAS=2 ;;
egress) PROXY_NS="agentgateway-egress" PROXY_DEPLOY="agw-egress" EXPECTED_STANZAS=1 ;;
esac

echo "== switching the retry stanza on for the ${ROUTE} route =="
# Set before the apply, not after it: an apply that changed one route and then
# failed still has to be put back.
RESTORE_ROUTE="yes"
make --no-print-directory retry-on "ROUTE=${ROUTE}" "OUT=${RUN_DIR}/routes-on-${ROUTE}" | tee -a "$CONTROL_FILE"
ON=$(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)
printf '%s retry stanzas across every HTTPRoute with ROUTE=%s on: %s (expected %s)\n' \
	"$(date -u +%FT%TZ)" "$ROUTE" "$ON" "$EXPECTED_STANZAS" | tee -a "$CONTROL_FILE"
# Asserted, not merely printed. A stanza that failed to apply would leave the run
# measuring a route with no retry on it, and the rows would say "the gateway did
# not retry", which is exactly the shape of a result worth believing. The count is
# read back from the API server, so it is the live object that is checked.
if [ "$ON" != "$EXPECTED_STANZAS" ]; then
	echo "gate3-retry: after 'make retry-on ROUTE=${ROUTE}' the cluster carries ${ON} retry stanza(s) across every HTTPRoute, expected ${EXPECTED_STANZAS}; the stanza is not live and nothing will be sent" >&2
	exit 1
fi

# --- does the proxy hold the policy? ------------------------------------------
# Read once per route from the proxy's own /config_dump, the way the agentgateway
# documentation reads a retry back. This answers "the gateway has the retry",
# which is a different question from "the gateway fired the retry".
DUMP_FILE="${RUN_DIR}/config-dump-${ROUTE}.txt"
echo "== reading ${PROXY_NS}/${PROXY_DEPLOY} /config_dump =="
{
	printf '%s\n' "$HEADER"
	echo "kubectl -n ${PROXY_NS} port-forward deploy/${PROXY_DEPLOY} ${ADMIN_PORT}:15000"
	echo "curl -s http://127.0.0.1:${ADMIN_PORT}/config_dump | jq '[.binds[].listeners | to_entries[] | (.value.routes // {}) | to_entries[] | .value]'"
	echo
} >>"$DUMP_FILE"
kubectl -n "$PROXY_NS" port-forward "deploy/${PROXY_DEPLOY}" "${ADMIN_PORT}:15000" >/dev/null 2>&1 &
PF_ADMIN=$!
sleep 3
if curl -s --max-time 5 "http://127.0.0.1:${ADMIN_PORT}/config_dump" -o "${RUN_DIR}/.config-dump-${ROUTE}.json"; then
	jq '[.binds[].listeners | to_entries[] | (.value.routes // {}) | to_entries[] | .value]' \
		"${RUN_DIR}/.config-dump-${ROUTE}.json" >>"$DUMP_FILE" 2>&1 || echo "(the routes section could not be read from the dump)" >>"$DUMP_FILE"
	POLICY_HELD=$(jq -r '[.binds[].listeners | to_entries[] | (.value.routes // {}) | to_entries[] | .value.inlinePolicies // [] | .[] | select(has("retry"))] | length' \
		"${RUN_DIR}/.config-dump-${ROUTE}.json" 2>/dev/null || echo "unreadable")
else
	echo "(the proxy's admin endpoint did not answer)" >>"$DUMP_FILE"
	POLICY_HELD="unreadable"
fi
# Killed and then reaped, so bash's job control does not print a Terminated
# notice over the next command's output.
kill "$PF_ADMIN" >/dev/null 2>&1 || true
wait "$PF_ADMIN" 2>/dev/null || true
rm -f "${RUN_DIR}/.config-dump-${ROUTE}.json"
printf '%s %s/%s holds %s retry policy/policies in its own config_dump\n' \
	"$(date -u +%FT%TZ)" "$PROXY_NS" "$PROXY_DEPLOY" "$POLICY_HELD" | tee -a "$CONTROL_FILE" >>"$DUMP_FILE"
echo "config_dump: ${PROXY_NS}/${PROXY_DEPLOY} holds ${POLICY_HELD} retry policy/policies"

if [ "$DUMP_ONLY" = "on" ]; then
	echo "== DUMP_ONLY: the policy has been read back and nothing was sent =="
	exit 0
fi

# --- the out-of-cluster stimulus, for ROUTE=ingress ---------------------------
if [ "$ROUTE" = "ingress" ]; then
	if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${INGRESS_PORT}/" 2>/dev/null; then
		echo "gate3-retry: something already answers on 127.0.0.1:${INGRESS_PORT}; refusing to send through a listener this run did not start" >&2
		exit 1
	fi
	kubectl -n "$INGRESS_NS" port-forward svc/agentgateway-ingress "${INGRESS_PORT}:80" >/dev/null 2>&1 &
	PF_INGRESS=$!
	up=0
	for _ in $(seq 1 20); do
		if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${INGRESS_PORT}/"; then
			up=1
			break
		fi
		sleep 0.5
	done
	[ "$up" = "1" ] || {
		echo "gate3-retry: port-forward to svc/agentgateway-ingress did not come up" >&2
		exit 1
	}
	echo "== the ingress is reachable on 127.0.0.1:${INGRESS_PORT} =="
fi

# --- counting helpers ---------------------------------------------------------
jqs() { jq -r -s "$@"; }

# nth_field reads one field of the nth line of a ledger selection.
worker_arrival_field() { # $1 = ingress.jsonl, $2 = index, $3 = field
	jqs --argjson i "$2" --arg f "$3" \
		'[.[] | select(.source == "worker" and .phase == "arrival" and .method == "SendMessage")]
		 | if length > $i then (.[$i][$f] // "" | tostring) else "" end' "$1"
}
invocation_field() { # $1 = invocation.jsonl, $2 = index, $3 = field
	jqs --argjson i "$2" --arg f "$3" \
		'[.[] | select(.outcome != "stale-closed")]
		 | if length > $i then (.[$i][$f] // "" | tostring) else "" end' "$1"
}
same_across() { # $1 = a, $2 = b -> yes | no | n-a
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "n-a"
	elif [ "$1" = "$2" ]; then
		echo "yes"
	else
		echo "no"
	fi
}

write_header() {
	if [ ! -s "$SUMMARY" ]; then
		echo "route,work_item,arrivals_at_worker,invocations_at_mock,retried,identity_source,messageId_same,rpc_id_same,taskId_same,caller_same,body_sha256_same,body_len_same,executes,client_result,trace_spans,notes" >"$SUMMARY"
	fi
}

# --- one repetition -----------------------------------------------------------
one_rep() { # $1 = work item id, $2 = summary file to append to (empty for none)
	local lwi="$1" out_summary="$2"
	local d="${RUN_DIR}/${lwi}"
	local notes="" rc=0
	mkdir -p "$d"
	echo "== ${ROUTE}: logical_work_item_id=${lwi} =="

	reset_all

	# Arm the hop this route serves. The worker's injector disarms itself on the
	# delivery it fires for, so a gateway's re-send is served normally; the model
	# endpoint's arming is keyed by work item and stays armed for that work item,
	# so both a call and its re-send are answered 500. Neither is a retry.
	local arm_url arm_body arm_code
	if [ "$ROUTE" = "egress" ]; then
		arm_url="${MOCK_URL}/control/inject"
		arm_body="{\"mode\":\"http500\",\"lwi\":\"${lwi}\"}"
	else
		arm_url="${WORKER_URL}/control/inject"
		arm_body="{\"mode\":\"http503-before-dispatch\",\"lwi\":\"${lwi}\"}"
	fi
	arm_code=$(post_json "$arm_url" "$arm_body")
	printf '%s POST %s %s -> %s\n' "$(date -u +%FT%TZ)" "$arm_url" "$arm_body" "$arm_code" >>"$CONTROL_FILE"
	ok2xx "$arm_code" || {
		echo "gate3-retry: arming ${arm_url} for ${lwi} returned ${arm_code}" >&2
		exit 1
	}

	if [ "$ROUTE" = "ingress" ]; then
		send_through_ingress "$lwi" "$d" || rc=$?
		[ "$rc" = "0" ] || notes="${notes}stimulus_rc=${rc};"
	else
		send_loadgen_job "$lwi" "$d" || rc=$?
		[ "$rc" = "0" ] || notes="${notes}stimulus_rc=${rc};"
	fi

	sleep "$COLLECT_WAIT"
	local lrc=0
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${d}" >/dev/null 2>>"${d}/collect.log" || lrc=$?
	[ "$lrc" = "0" ] || notes="${notes}ledgers_rc=${lrc};"
	local f
	for f in ingress execution invocation client; do
		[ -f "${d}/${f}.jsonl" ] || : >"${d}/${f}.jsonl"
	done

	# Disarm after collection, so an arming that never fired cannot fire into the
	# next repetition's work item.
	local post_reset
	post_reset=$(post "${WORKER_URL}/control/reset")
	printf '%s POST %s/control/reset -> %s (after %s)\n' "$(date -u +%FT%TZ)" "$WORKER_URL" "$post_reset" "$lwi" >>"$CONTROL_FILE"
	ok2xx "$post_reset" || notes="${notes}worker_post_reset=${post_reset};"
	post_reset=$(post "${MOCK_URL}/control/reset")
	printf '%s POST %s/control/reset -> %s (after %s)\n' "$(date -u +%FT%TZ)" "$MOCK_URL" "$post_reset" "$lwi" >>"$CONTROL_FILE"
	ok2xx "$post_reset" || notes="${notes}mock_post_reset=${post_reset};"

	# The trace is exported inside the run: the batch span processors flush on a
	# timer and the trace backend stores in memory.
	sleep "$TRACE_WAIT"
	make --no-print-directory export-trace "LWI=${lwi}" "OUT=${d}" >>"${d}/collect.log" 2>&1 || true
	local trace_spans=0
	if [ -s "${d}/spans.csv" ]; then trace_spans=$(($(grep -c '' "${d}/spans.csv") - 1)); fi

	local arrivals invocations executes
	arrivals=$(jqs '[.[] | select(.source == "worker" and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
	invocations=$(jqs '[.[] | select(.outcome != "stale-closed")] | length' "${d}/invocation.jsonl")
	executes=$(jqs '[.[] | select(.source == "worker" and .event == "execute")] | length' "${d}/execution.jsonl")

	# What "retried" means differs by which hop the route serves: on the two
	# routes in front of the receiver it is a second arrival at the receiver, and
	# on the egress route it is a second call at the model endpoint.
	local retried identity_source msg_same id_same task_same caller_same body_same len_same
	if [ "$ROUTE" = "egress" ]; then
		identity_source="invocation-lines"
		[ "$invocations" -ge 2 ] && retried="yes" || retried="no"
		msg_same=$(same_across "$(invocation_field "${d}/invocation.jsonl" 0 messageId)" "$(invocation_field "${d}/invocation.jsonl" 1 messageId)")
		id_same="n-a"
		task_same=$(same_across "$(invocation_field "${d}/invocation.jsonl" 0 taskId)" "$(invocation_field "${d}/invocation.jsonl" 1 taskId)")
		caller_same=$(same_across "$(invocation_field "${d}/invocation.jsonl" 0 caller)" "$(invocation_field "${d}/invocation.jsonl" 1 caller)")
		body_same=$(same_across "$(invocation_field "${d}/invocation.jsonl" 0 body_sha256)" "$(invocation_field "${d}/invocation.jsonl" 1 body_sha256)")
		len_same="n-a"
	else
		identity_source="ingress-arrivals"
		[ "$arrivals" -ge 2 ] && retried="yes" || retried="no"
		msg_same=$(same_across "$(worker_arrival_field "${d}/ingress.jsonl" 0 messageId)" "$(worker_arrival_field "${d}/ingress.jsonl" 1 messageId)")
		id_same=$(same_across "$(worker_arrival_field "${d}/ingress.jsonl" 0 id)" "$(worker_arrival_field "${d}/ingress.jsonl" 1 id)")
		task_same=$(same_across "$(worker_arrival_field "${d}/ingress.jsonl" 0 taskId)" "$(worker_arrival_field "${d}/ingress.jsonl" 1 taskId)")
		caller_same="n-a"
		body_same=$(same_across "$(worker_arrival_field "${d}/ingress.jsonl" 0 body_sha256)" "$(worker_arrival_field "${d}/ingress.jsonl" 1 body_sha256)")
		len_same=$(same_across "$(worker_arrival_field "${d}/ingress.jsonl" 0 body_len)" "$(worker_arrival_field "${d}/ingress.jsonl" 1 body_len)")
	fi

	local client_result
	client_result=$(jqs '
		if length == 0 then "none"
		else (last | if ((.error // "") != "") then "error" else "\(.result_kind // "none")/\(if (.state // "") == "" then "none" else .state end)" end)
		end' "${d}/client.jsonl")
	local errs
	errs=$(jqs '[.[] | select((.error // "") != "") | "a\(.attempt // 1):\((.error // "") | gsub("[,;]"; " ") | .[0:120])"] | join(" ")' "${d}/client.jsonl")
	[ -z "$errs" ] || notes="${notes}client_errors=${errs};"

	local row="${ROUTE},${lwi},${arrivals},${invocations},${retried},${identity_source},${msg_same},${id_same},${task_same},${caller_same},${body_same},${len_same},${executes},${client_result},${trace_spans},${notes}"
	echo "  $row"
	[ -z "$out_summary" ] || printf '%s\n' "$row" >>"$out_summary"
}

# send_loadgen_job runs the in-cluster load client, whose pod is ztunnel-captured,
# so the request reaches the worker through the worker's own waypoint.
send_loadgen_job() { # $1 = work item, $2 = repetition directory
	local lwi="$1" d="$2" rc=0
	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${WORKER_URL}#g" deploy/base/loadgen-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >"${d}/apply.log" 2>&1 || rc=$?
	[ "$rc" = "0" ] || return "$rc"
	# A Job that exits non-zero is an expected outcome here: the injected failure
	# is what the gateway is being asked to retry, and a gateway that does not
	# retry leaves the client with the 503. `kubectl wait` takes one condition, so
	# both are polled together rather than waiting out a timeout on the first.
	local waited=0 conds=""
	while [ "$waited" -lt 180 ]; do
		conds=$(kubectl -n "$NAMESPACE" get "job/loadgen-${lwi}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
		case " $conds " in
		*" Complete "* | *" Failed "*) return 0 ;;
		esac
		sleep 2
		waited=$((waited + 2))
	done
	echo "gate3-retry: job loadgen-${lwi} reached neither complete nor failed in ${waited}s" >&2
	return 1
}

# send_through_ingress makes one out-of-cluster POST through the agentgateway
# ingress, addressed to the worker by the hostname its step-2c route matches on.
#
# curl, not the load client: the load client resolves the agent card and then
# sends to the address the card advertises, which is an in-cluster Service name
# no host-side process can reach. One POST of one body is what this probe needs,
# and curl sends exactly that. No --retry is passed, so curl re-sends nothing;
# any second arrival is the gateway's.
#
# The body is the shape internal/a2areq builds and the replay harness renders,
# with a fresh JSON-RPC id and messageId per repetition. The client line this
# writes is the one `make ledgers` then keeps, since there is no Job to read a
# pod log from.
send_through_ingress() { # $1 = work item, $2 = repetition directory
	local lwi="$1" d="$2"
	LWI="$lwi" python3 - "${d}/request.json" <<'PY'
import json, os, sys, uuid
lwi = os.environ["LWI"]
body = {
    "jsonrpc": "2.0",
    "method": "SendMessage",
    "params": {"message": {
        "messageId": str(uuid.uuid4()),
        "metadata": {"logical_work_item_id": lwi},
        "parts": [{"text": "lwi:%s hello" % lwi}],
        "role": "ROLE_USER",
    }},
    "id": str(uuid.uuid4()),
}
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(body, separators=(",", ":")))
PY
	local code
	code=$(curl -s --max-time 120 -o "${d}/response.json" -w '%{http_code}' \
		-X POST \
		-H 'Content-Type: application/json' \
		-H 'A2A-Version: 1.0' \
		-H 'Host: worker.lab.internal' \
		-H "X-Logical-Work-Item-Id: ${lwi}" \
		-H 'X-Caller: probe' \
		--data-binary "@${d}/request.json" \
		"http://127.0.0.1:${INGRESS_PORT}/" || echo "000")
	LWI="$lwi" CODE="$code" python3 - "${d}/request.json" "${d}/response.json" "${d}/client.jsonl" <<'PY'
import datetime, hashlib, json, os, sys
req_path, resp_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(req_path, "rb").read()
req = json.loads(raw)
line = {
    "ledger": "client",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "logical_work_item_id": os.environ["LWI"],
    "attempt": 1,
    "via": "curl-through-the-ingress",
    "id": req["id"],
    "messageId": req["params"]["message"]["messageId"],
    "body_sha256": hashlib.sha256(raw).hexdigest(),
    "body_len": len(raw),
    "status": int(os.environ["CODE"]),
    "result_kind": "none",
    "taskId": "",
    "state": "",
    "error": "",
}
try:
    resp = json.load(open(resp_path))
except Exception as exc:
    resp = None
    line["error"] = "response was not JSON: %s" % exc
if isinstance(resp, dict):
    if "error" in resp:
        line["result_kind"] = "error"
        line["error"] = json.dumps(resp["error"])[:200]
    result = resp.get("result") or {}
    # a2a-go v2 answers SendMessage with the result wrapped in the kind it is,
    # {"result": {"task": {...}}} or {"result": {"message": {...}}}; the unwrapped
    # shapes are read too so this line does not depend on that staying true.
    if isinstance(result, dict):
        task = result.get("task") if isinstance(result.get("task"), dict) else (result if "status" in result else None)
        message = result.get("message") if isinstance(result.get("message"), dict) else (result if "messageId" in result else None)
        if task is not None:
            line["result_kind"] = "task"
            line["taskId"] = task.get("id", "")
            line["state"] = (task.get("status") or {}).get("state", "")
        elif message is not None:
            line["result_kind"] = "message"
            line["taskId"] = message.get("taskId", "")
with open(out_path, "w") as f:
    f.write(json.dumps(line) + "\n")
PY
	case "$code" in 000) return 3 ;; esac
	return 0
}

# --- the run ------------------------------------------------------------------
if [ "$DRY_RUN" = "on" ]; then
	echo "== dry run: one repetition, its directory deleted afterwards =="
	DRY_ID="$(work_item "dry")"
	one_rep "$DRY_ID" ""
	rm -rf "${RUN_DIR:?}/${DRY_ID}"
	kubectl -n "$NAMESPACE" delete job "loadgen-${DRY_ID}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	echo "== dry run done; ${RUN_DIR}/${DRY_ID} removed =="
fi

write_header
echo "== ${ROUTE}: ${REPS} repetitions =="
for i in $(seq 1 "$REPS"); do
	one_rep "$(work_item "$(printf '%02d' "$i")")" "$SUMMARY"
done

echo "== summary (${ROUTE}) =="
awk -F, -v r="$ROUTE" 'NR == 1 || $1 == r' "$SUMMARY"
