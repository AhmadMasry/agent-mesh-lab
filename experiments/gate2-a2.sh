#!/usr/bin/env bash
# Gate 2 / A.2 — client retry identity.
#
# Makes one real client retry one real request, and counts what the receiver's
# pre-dispatch ingress ledger recorded for each of the two attempts: the same
# A2A messageId? the same JSON-RPC id? the same body?
#
# Neither SDK offers a retry, so the retry is the lab's own and it is opt-in.
# Each knob defaults to off, is asserted off by a unit test, and is switched on
# by this script alone, for the row being measured:
#
#   CLIENT=go  LAYER=http   loadgen with CLIENT_RETRIES=1, so its HTTP client is
#                           httpclient.NewRetryingOn, which re-sends the same
#                           bytes. RETRY_ON says what it re-sends on.
#   CLIENT=go  LAYER=sdk    loadgen with CLIENT_SDK_RESEND=on, so it hands the
#                           same request object to a2aclient's SendMessage twice.
#   CLIENT=py  LAYER=http   the orchestrator in forward mode with either
#                           CLIENT_RETRIES=1 (httpx's own, which covers
#                           connection attempts only) or
#                           CLIENT_TRANSPORT_RESEND=on (ResendOnceTransport,
#                           which re-sends the same httpx request once, on what
#                           RETRY_ON names). Which one is chosen by PY_HTTP_KNOB;
#                           both are measured, as sub-rows, and neither is wrong.
#   CLIENT=py  LAYER=sdk    the orchestrator with CLIENT_SDK_RESEND=on, so it
#                           hands the same SendMessageRequest to the a2a-python
#                           client's send_message twice.
#
# The failure the client retries is injected at the WORKER for both clients: one
# `close-after-read` armed for the repetition's work item, which writes the
# arrival line and then takes the connection away without writing a status. For
# CLIENT=go the worker is the client's own target; for CLIENT=py it is the agent
# the orchestrator forwards to, and the orchestrator's httpx client is the one
# under test. The worker's injector fires once per arming and disarms itself.
#
#   CLIENT=<go|py>            required.
#   LAYER=<http|sdk>          required. Which layer's knob is switched on.
#   PY_HTTP_KNOB=<retries|resend>
#                             default retries. CLIENT=py LAYER=http only.
#   RETRY_ON=<transport|transport+503>
#                             default transport. What the HTTP-layer resend acts
#                             on. `transport` is a transport error only, which is
#                             what A.2 measured first: behind the worker's
#                             waypoint a receiver-side connection close reaches
#                             the client as a synthesised 503, so that mode never
#                             re-sends at all. `transport+503` also re-sends once
#                             on a 503, and on no other status, which is the only
#                             thing an HTTP-layer retry can act on here. The mode
#                             is not a switch and only applies where there is an
#                             HTTP-layer resend to widen, so it is refused on the
#                             sdk rows and on the httpx-`retries` sub-row, where
#                             it would name a knob it cannot reach.
#   REPS=<n>                  default 20. Unset takes the default; an empty or
#                             non-numeric value is an error, because a silent
#                             default here spends repetitions that cannot be
#                             taken back.
#   RUN_ID=<nonce>            default $(date +%H%M%S). Work-item ids carry it:
#                             pod logs outlive a run, and a repeated id would
#                             collect an earlier run's lines as this run's.
#   RUN_ITEM=<name>           default <date>-a2-<client>-<layer>[-<knob>];
#                             names the run directory under experiments/runs/.
#   COLLECT_WAIT=<seconds>    default 2. Seconds between the client returning and
#                             `make ledgers`, because the receiver writes its
#                             response line and the mock its invocation line
#                             after the client already holds its answer.
#
# Both rows are in-cluster. CLIENT=go is a ztunnel-captured Job to the worker
# Service, so it reaches the worker through the worker's own istiod-driven
# agentgateway waypoint. CLIENT=py is a ztunnel-captured Job to the orchestrator,
# whose agent card advertises the agentgateway ingress Service, so the stimulus
# enters through the ingress; the hop this row measures is the next one, the
# orchestrator's own forward to the worker Service, which goes through the
# worker's waypoint. No port-forward and no out-of-cluster stimulus here.
#
# No retry logic in this script. Each repetition is one client invocation, and
# whatever second delivery appears was made by the client under test. A
# repetition whose Job failed is recorded in the notes column and is never
# re-run: a re-run would be another delivery.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
CLIENT="${CLIENT:-}"
LAYER="${LAYER:-}"
PY_HTTP_KNOB="${PY_HTTP_KNOB:-retries}"
RETRY_ON="${RETRY_ON:-transport}"
REPS="${REPS-20}"
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
CURL_POD="a2-curl"
CURL_IMAGE="curlimages/curl:8.22.0"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"
COLLECT_WAIT="${COLLECT_WAIT:-2}"

usage() {
	echo "usage: CLIENT=<go|py> LAYER=<http|sdk> [PY_HTTP_KNOB=<retries|resend>] [RETRY_ON=<transport|transport+503>] [REPS=20] [RUN_ID=<nonce>] $0" >&2
	exit 1
}

case "$CLIENT" in go | py) ;; *) usage ;; esac
case "$LAYER" in http | sdk) ;; *) usage ;; esac
case "$PY_HTTP_KNOB" in retries | resend) ;; *) usage ;; esac
case "$RETRY_ON" in transport | 'transport+503') ;; *) usage ;; esac
case "$REPS" in '' | *[!0-9]*) echo "gate2-a2: REPS=${REPS} is not a positive integer" >&2 && exit 1 ;; esac
if [ "$REPS" -lt 1 ]; then
	echo "gate2-a2: REPS=${REPS} is not a positive integer" >&2
	exit 1
fi

# --- which knob this row switches on -----------------------------------------
# The knobs the row does not test are rendered at their off values rather than
# omitted, so no row can leave a knob on by forgetting it.
KNOB_NAMES=()
KNOB_VALUES=()
SUBROW=""
WIDENED="no" # whether this row's HTTP-layer resend was widened past transport
if [ "$RETRY_ON" = "transport+503" ]; then WIDENED="yes"; fi
refuse_mode() {
	echo "gate2-a2: RETRY_ON=${RETRY_ON} has nothing to act on for CLIENT=${CLIENT} LAYER=${LAYER}${1:+ PY_HTTP_KNOB=$PY_HTTP_KNOB}; it widens an HTTP-layer resend and this row has none" >&2
	exit 1
}
case "${CLIENT}/${LAYER}" in
go/http)
	KNOB_NAMES=(CLIENT_RETRIES CLIENT_RETRY_ON)
	KNOB_VALUES=(1 "$RETRY_ON")
	if [ "$WIDENED" = "yes" ]; then SUBROW="503"; fi
	;;
go/sdk)
	[ "$WIDENED" = "no" ] || refuse_mode
	KNOB_NAMES=(CLIENT_SDK_RESEND)
	KNOB_VALUES=(on)
	;;
py/http)
	SUBROW="$PY_HTTP_KNOB"
	if [ "$PY_HTTP_KNOB" = "retries" ]; then
		# httpx's own retries reaches httpcore's _connect and is not affected by
		# the mode, so widening it here would name a knob it cannot reach.
		[ "$WIDENED" = "no" ] || refuse_mode py
		KNOB_NAMES=(CLIENT_RETRIES)
		KNOB_VALUES=(1)
	else
		KNOB_NAMES=(CLIENT_TRANSPORT_RESEND CLIENT_RETRY_ON)
		KNOB_VALUES=(on "$RETRY_ON")
		if [ "$WIDENED" = "yes" ]; then SUBROW="resend503"; fi
	fi
	;;
py/sdk)
	[ "$WIDENED" = "no" ] || refuse_mode
	KNOB_NAMES=(CLIENT_SDK_RESEND)
	KNOB_VALUES=(on)
	;;
esac
# One label for the whole knob set, used in the row's notes column.
KNOB_LABEL=""
for i in $(seq 0 $((${#KNOB_NAMES[@]} - 1))); do
	KNOB_LABEL="${KNOB_LABEL}${KNOB_LABEL:+ }${KNOB_NAMES[$i]}=${KNOB_VALUES[$i]}"
done

RUN_ITEM="${RUN_ITEM:-$(date +%F)-a2-${CLIENT}-${LAYER}${SUBROW:+-$SUBROW}}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
mkdir -p "$RUN_DIR"

# One run directory holds one run. Rows are appended as they are produced, so a
# directory whose numbers a findings entry already cites must not grow, and rows
# carrying another nonce mean two runs are being mixed. Refuse before anything
# is sent.
if [ -s "${RUN_DIR}/summary.csv" ]; then
	foreign=$(awk -F, -v id="-${RUN_ID}-" 'NR > 1 && index($3, id) == 0 { n++ } END { print n + 0 }' "${RUN_DIR}/summary.csv")
	if [ "$foreign" != "0" ]; then
		echo "gate2-a2: ${RUN_DIR}/summary.csv already holds ${foreign} rows from another run (this run's nonce is ${RUN_ID}); set RUN_ITEM to a new directory, or RUN_ID to the existing run's nonce to chunk it" >&2
		exit 1
	fi
fi

# --- the orchestrator's knobs, for CLIENT=py ---------------------------------
# The value each knob had before this script set one, read from the Deployment
# rather than assumed, written down before anything is changed, and put back on
# exit. A kill -9 leaves this file behind, so what to restore survives the
# script that changed it.
ORCH_KNOBS_FILE="${RUN_DIR}/orchestrator-knobs.txt"
RESTORE_ORCH="no"
ORCH_PRE=()

orch_env() { # $1 = variable name -> its value on the Deployment, empty if unset
	kubectl -n "$NAMESPACE" get deployment/orchestrator \
		-o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"
}

# The restore cannot fail quietly: a failed restore says so on stderr, records
# it in the run directory and leaves the script non-zero, because the
# alternative is a later run measuring an orchestrator that still has a retry
# switched on.
cleanup() {
	trigger_rc=$?
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$RESTORE_ORCH" = "yes" ]; then
		echo "== restoring the orchestrator's ${KNOB_LABEL} =="
		# Every knob this run set is put back in one `set env`, so one rollout
		# restores them all and no intermediate state is ever deployed.
		restore_args=""
		restore_says=""
		for i in $(seq 0 $((${#KNOB_NAMES[@]} - 1))); do
			if [ -z "${ORCH_PRE[$i]}" ]; then
				restore_args="${restore_args} ${KNOB_NAMES[$i]}-"
				restore_says="${restore_says}${restore_says:+ }${KNOB_NAMES[$i]}=<unset>"
			else
				restore_args="${restore_args} ${KNOB_NAMES[$i]}=${ORCH_PRE[$i]}"
				restore_says="${restore_says}${restore_says:+ }${KNOB_NAMES[$i]}=${ORCH_PRE[$i]}"
			fi
		done
		set_rc=0
		# shellcheck disable=SC2086 # each element is one NAME=value or NAME- argument
		kubectl -n "$NAMESPACE" set env deployment/orchestrator $restore_args >/dev/null 2>&1 || set_rc=$?
		roll_rc=0
		kubectl -n "$NAMESPACE" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || roll_rc=$?
		if [ "$set_rc" = "0" ] && [ "$roll_rc" = "0" ]; then
			printf '%s restored %s\n' "$(date -u +%FT%TZ)" "$restore_says" | tee -a "$ORCH_KNOBS_FILE"
		else
			printf '%s RESTORE FAILED (set env rc=%s, rollout rc=%s); deployment/orchestrator still carries %s. Put it back with: kubectl -n %s set env deployment/orchestrator%s\n' \
				"$(date -u +%FT%TZ)" "$set_rc" "$roll_rc" "$KNOB_LABEL" "$NAMESPACE" "$restore_args" | tee -a "$ORCH_KNOBS_FILE" >&2
			echo "gate2-a2: the orchestrator was NOT restored; see ${ORCH_KNOBS_FILE}" >&2
			exit 1
		fi
	fi
	return "$trigger_rc"
}
trap cleanup EXIT

# --- certificate check -------------------------------------------------------
# A ztunnel whose leaf certificate is not valid drops the mesh hops this run
# measures, so this runs before anything is sent.
CERT_FILE="${RUN_DIR}/certificates.txt"
cert_valid() {
	awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' "$CERT_FILE" | grep -qx true
}
echo "== certificate check =="
istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" >"$CERT_FILE"
if cert_valid; then
	echo "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default; ztunnel not restarted"
else
	echo "certificate check: VALID CERT is not true; restarting ztunnel" >&2
	kubectl -n istio-system rollout restart daemonset/ztunnel
	kubectl -n istio-system rollout status daemonset/ztunnel --timeout=180s
	istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" >"$CERT_FILE"
	cert_valid || {
		echo "certificate check: VALID CERT still not true after a ztunnel restart" >&2
		exit 1
	}
	echo "certificate check: VALID CERT true after a ztunnel restart"
fi

# --- control pod -------------------------------------------------------------
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

CONTROL_FILE="${RUN_DIR}/control.txt"
# The knob set this run switched on, written at the head of the control log, so
# the file that records every arming also records what was armed against.
printf '%s run %s: client=%s layer=%s knobs: %s\n' \
	"$(date -u +%FT%TZ)" "$RUN_ID" "$CLIENT" "$LAYER" "$KNOB_LABEL" | tee -a "$CONTROL_FILE"
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
		echo "gate2-a2: deployment/${deploy} is not at exactly one ready replica (spec=${spec:-<none>} ready=${ready:-0}); scale it to 1 before an injector is armed through its Service" >&2
		exit 1
	fi
}
assert_single_replica worker
assert_single_replica mockllm

echo "== disarming the worker before the run =="
reset_code=$(post "${WORKER_URL}/control/reset")
printf '%s POST %s/control/reset -> %s (pre-run)\n' "$(date -u +%FT%TZ)" "$WORKER_URL" "$reset_code" | tee -a "$CONTROL_FILE"
ok2xx "$reset_code" || {
	echo "gate2-a2: ${WORKER_URL}/control/reset returned ${reset_code}" >&2
	exit 1
}

reset_mock() {
	local c
	c=$(post "${MOCK_URL}/control/reset")
	ok2xx "$c" || {
		echo "gate2-a2: mock reset returned $c" >&2
		exit 1
	}
}

# --- the client under test ---------------------------------------------------
JOB_RETRIES="0"
JOB_SDK_RESEND="off"
JOB_RETRY_ON="transport"
JOB_TEMPLATE="deploy/base/loadgen-job.yaml"
TARGET_URL="$ORCH_URL"
if [ "$CLIENT" = "go" ]; then
	JOB_TEMPLATE="deploy/base/loadgen-a2-job.yaml"
	TARGET_URL="$WORKER_URL"
	for i in $(seq 0 $((${#KNOB_NAMES[@]} - 1))); do
		case "${KNOB_NAMES[$i]}" in
		CLIENT_RETRIES) JOB_RETRIES="${KNOB_VALUES[$i]}" ;;
		CLIENT_SDK_RESEND) JOB_SDK_RESEND="${KNOB_VALUES[$i]}" ;;
		CLIENT_RETRY_ON) JOB_RETRY_ON="${KNOB_VALUES[$i]}" ;;
		esac
	done
else
	# The a2a-python client under test is the orchestrator's Forwarder, so the
	# orchestrator has to be in forward mode. Its deployed value is the step-2b
	# one; it is read rather than assumed, and a missing value stops the run
	# instead of measuring a receiver that answers requests itself.
	downstream=$(orch_env DOWNSTREAM_A2A_URL)
	printf '%s pre-run DOWNSTREAM_A2A_URL on deployment/orchestrator: %s\n' \
		"$(date -u +%FT%TZ)" "${downstream:-<unset>}" | tee -a "$ORCH_KNOBS_FILE"
	if [ -z "$downstream" ]; then
		echo "gate2-a2: deployment/orchestrator has no DOWNSTREAM_A2A_URL, so it is not in forward mode and there is no a2a-python client to measure" >&2
		exit 1
	fi
	# Every knob this row sets is read off the Deployment and written down before
	# anything changes, so what to put back survives a script that is killed.
	set_args=""
	undo_args=""
	for i in $(seq 0 $((${#KNOB_NAMES[@]} - 1))); do
		ORCH_PRE[$i]=$(orch_env "${KNOB_NAMES[$i]}")
		printf '%s pre-run %s on deployment/orchestrator: %s\n' \
			"$(date -u +%FT%TZ)" "${KNOB_NAMES[$i]}" "${ORCH_PRE[$i]:-<unset>}" | tee -a "$ORCH_KNOBS_FILE"
		set_args="${set_args} ${KNOB_NAMES[$i]}=${KNOB_VALUES[$i]}"
		if [ -z "${ORCH_PRE[$i]}" ]; then
			undo_args="${undo_args} ${KNOB_NAMES[$i]}-"
		else
			undo_args="${undo_args} ${KNOB_NAMES[$i]}=${ORCH_PRE[$i]}"
		fi
	done
	printf '%s setting %s; if this script dies without restoring them, put them back with: kubectl -n %s set env deployment/orchestrator%s\n' \
		"$(date -u +%FT%TZ)" "$KNOB_LABEL" "$NAMESPACE" "$undo_args" | tee -a "$ORCH_KNOBS_FILE"
	# shellcheck disable=SC2086 # each element is one NAME=value argument
	kubectl -n "$NAMESPACE" set env deployment/orchestrator $set_args >/dev/null
	RESTORE_ORCH="yes"
	kubectl -n "$NAMESPACE" rollout status deployment/orchestrator --timeout=180s >/dev/null
	for i in $(seq 0 $((${#KNOB_NAMES[@]} - 1))); do
		printf '%s live %s after the rollout: %s\n' \
			"$(date -u +%FT%TZ)" "${KNOB_NAMES[$i]}" "$(orch_env "${KNOB_NAMES[$i]}")" | tee -a "$ORCH_KNOBS_FILE"
	done
fi

# --- counting ----------------------------------------------------------------
# Everything is counted at the WORKER's pre-dispatch ingress ledger, for both
# clients: it is the receiver whose injection made the client retry, and the
# ledger line is written before the A2A SDK sees the request, so a delivery that
# was refused is still counted.
jqs() { jq -r -s "$@"; }

arrivals_field() { # $1 = ingress.jsonl, $2 = attempt index (0 or 1), $3 = field
	jqs --argjson i "$2" --arg f "$3" \
		'[.[] | select(.source == "worker" and .phase == "arrival" and .method == "SendMessage")]
		 | if length > $i then (.[$i][$f] // "") else "" end' "$1"
}

same_across_attempts() { # $1 = ingress.jsonl, $2 = field -> yes | no | n-a
	local a b
	a=$(arrivals_field "$1" 0 "$2")
	b=$(arrivals_field "$1" 1 "$2")
	if [ -z "$a" ] || [ -z "$b" ]; then
		echo "n-a"
	elif [ "$a" = "$b" ]; then
		echo "yes"
	else
		echo "no"
	fi
}

write_header() {
	if [ ! -s "${RUN_DIR}/summary.csv" ]; then
		echo "client,layer,work_item,arrivals,messageId_reused,id_reused,body_identical,injection_fired,executes,invocations,client_result,notes" >"${RUN_DIR}/summary.csv"
	fi
}

one_rep() { # $1 = repetition number
	local n="$1"
	# The sub-row is part of the work-item id, not only of the directory name:
	# pod logs outlive a run, and the two CLIENT=py LAYER=http sub-rows would
	# otherwise share an id, so the second would collect the first's lines from
	# the worker's log as if they were its own.
	local lwi="a2-${CLIENT}-${LAYER}${SUBROW:+-$SUBROW}-${RUN_ID}-$(printf '%02d' "$n")"
	local d="${RUN_DIR}/${lwi}"
	local notes="knob=${KNOB_LABEL};" rc=0
	mkdir -p "$d"

	reset_mock
	# Arm the worker for this work item only. take() disarms on the first
	# delivery, so exactly one attempt is failed and any later one is served.
	local arm_code
	arm_code=$(post_json "${WORKER_URL}/control/inject" "{\"mode\":\"close-after-read\",\"lwi\":\"${lwi}\"}")
	printf '%s POST %s/control/inject close-after-read lwi=%s -> %s\n' \
		"$(date -u +%FT%TZ)" "$WORKER_URL" "$lwi" "$arm_code" >>"$CONTROL_FILE"
	ok2xx "$arm_code" || {
		echo "gate2-a2: arming the worker for ${lwi} returned ${arm_code}" >&2
		exit 1
	}

	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	# CLIENT_DIAL (added to the template on 2026-09-19) is rendered empty: A.2's
	# client dials what the card advertises, as it did when these rows were run.
	# Left unsubstituted, the client would refuse to start.
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${TARGET_URL}#g" \
		-e "s/\${CLIENT_RETRIES}/${JOB_RETRIES}/g" -e "s/\${CLIENT_SDK_RESEND}/${JOB_SDK_RESEND}/g" \
		-e "s/\${CLIENT_RETRY_ON}/${JOB_RETRY_ON}/g" -e "s/\${CLIENT_DIAL}//g" \
		"$JOB_TEMPLATE" \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >"${d}/apply.log" 2>&1 || rc=$?
	if [ "$rc" != "0" ]; then notes="${notes}ko_apply_rc=${rc};"; fi
	# A Job that exits non-zero is a recorded outcome, and in these rows it is the
	# expected one: the injected failure is what the client is being asked to
	# retry, so many repetitions end with the client reporting an error and the
	# Job failing. Both conditions are therefore watched at once, in a bounded
	# poll, rather than waiting out a timeout on `complete` before looking at
	# `failed`: `kubectl wait` takes one condition, so waiting on them in
	# sequence would spend its whole timeout on every failing repetition.
	local waited=0 conds=""
	while [ "$waited" -lt 180 ]; do
		conds=$(kubectl -n "$NAMESPACE" get "job/loadgen-${lwi}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
		case " $conds " in
		*" Complete "*) break ;;
		*" Failed "*)
			notes="${notes}job_failed;"
			break
			;;
		esac
		sleep 2
		waited=$((waited + 2))
	done
	case " $conds " in
	*" Complete "* | *" Failed "*) ;;
	*) notes="${notes}job_neither_complete_nor_failed_in_${waited}s;" ;;
	esac

	sleep "$COLLECT_WAIT"
	local lrc=0
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${d}" >/dev/null 2>>"${d}/apply.log" || lrc=$?
	if [ "$lrc" != "0" ]; then notes="${notes}ledgers_rc=${lrc};"; fi
	local f
	for f in ingress execution invocation client; do
		[ -f "${d}/${f}.jsonl" ] || : >"${d}/${f}.jsonl"
	done

	# Disarm after collection, so an arming that never fired cannot fire into
	# the next repetition's work item.
	local post_reset
	post_reset=$(post "${WORKER_URL}/control/reset")
	printf '%s POST %s/control/reset -> %s (after %s)\n' "$(date -u +%FT%TZ)" "$WORKER_URL" "$post_reset" "$lwi" >>"$CONTROL_FILE"
	ok2xx "$post_reset" || notes="${notes}post_reset=${post_reset};"

	local arrivals injection_fired executes invocations
	arrivals=$(jqs '[.[] | select(.source == "worker" and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
	injection_fired=$(jqs '[.[] | select(.source == "worker" and .injection != null)] | length' "${d}/ingress.jsonl")
	executes=$(jqs '[.[] | select(.source == "worker" and .event == "execute")] | length' "${d}/execution.jsonl")
	# a stale-closed line records a connection close, not a call
	invocations=$(jqs '[.[] | select(.outcome != "stale-closed")] | length' "${d}/invocation.jsonl")

	local msg_reused id_reused body_identical
	msg_reused=$(same_across_attempts "${d}/ingress.jsonl" messageId)
	id_reused=$(same_across_attempts "${d}/ingress.jsonl" id)
	body_identical=$(same_across_attempts "${d}/ingress.jsonl" body_sha256)
	if [ "$arrivals" -lt 2 ]; then
		notes="${notes}one_arrival_only_so_no_second_attempt_to_compare;"
	fi

	# The client's own outcome, from its client lines and nothing else.
	local client_result client_lines
	client_lines=$(jqs 'length' "${d}/client.jsonl")
	client_result=$(jqs '
		if length == 0 then "none"
		else (last | if ((.error // "") != "") then "error" else "\(.result_kind // "none")/\(if (.state // "") == "" then "none" else .state end)" end)
		end' "${d}/client.jsonl")
	notes="${notes}client_lines=${client_lines};"
	local errs
	errs=$(jqs '[.[] | select((.error // "") != "") | "a\(.attempt // 1):\((.error // "") | gsub("[,;]"; " ") | .[0:120])"] | join(" ")' "${d}/client.jsonl")
	[ -z "$errs" ] || notes="${notes}client_errors=${errs};"
	# For CLIENT=py the outer delivery is a separate hop; one is expected, and
	# anything else is recorded rather than repaired.
	if [ "$CLIENT" = "py" ]; then
		local outer
		outer=$(jqs '[.[] | select(.source == "orchestrator" and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
		[ "$outer" = "1" ] || notes="${notes}outer_arrivals_at_the_orchestrator=${outer};"
	fi

	local row="${CLIENT},${LAYER},${lwi},${arrivals},${msg_reused},${id_reused},${body_identical},${injection_fired},${executes},${invocations},${client_result},${notes}"
	echo "  $row"
	printf '%s\n' "$row" >>"${RUN_DIR}/summary.csv"
}

write_header
echo "== ${CLIENT} client, ${LAYER} layer, ${KNOB_LABEL}: ${REPS} repetitions =="
for i in $(seq 1 "$REPS"); do
	one_rep "$i"
done

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
