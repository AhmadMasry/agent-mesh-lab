#!/usr/bin/env bash
# Gate 2 / A.1 — receiver semantics under controlled duplicate delivery.
#
# Sends one SendMessage twice with the replay harness (fixtures/replay), for one
# mode and one receiver, over both Gate 2 stimulus paths, REPS times each, and
# counts what the three ledgers recorded for each repetition.
#
#   MODE=<M1|M2|M3>          required. M1 identical bytes; M2 a new JSON-RPC id;
#                            M3 a new JSON-RPC id and a new messageId.
#   RECEIVER=<go|py>         required. `go` is the worker (a2a-go), `py` the
#                            orchestrator (a2a-python).
#   REPS=<n>                 default 20. Unset takes the default; set to an
#                            empty or non-numeric value is an error, because a
#                            silent default here spends REPS x 2 deliveries that
#                            cannot be taken back.
#   VIAS="waypoint ingress"  which stimulus paths to run, in order. Naming one
#                            path chunks the run: rows append to the same
#                            summary.csv, so `VIAS=waypoint` then `VIAS=ingress`
#                            with the same RUN_ID and RUN_ITEM produces the same
#                            file as one invocation of both.
#   RUN_ID=<nonce>           default $(date +%H%M%S). Work-item ids carry it:
#                            pod logs outlive a run, and a repeated id would
#                            collect an earlier run's lines as if they were this
#                            run's.
#   RUN_ITEM=<name>          default <date>-a1-<mode>-<receiver>; names the run
#                            directory under experiments/runs/.
#   COLLECT_WAIT=<seconds>   default 2. Seconds between the harness returning
#                            and `make ledgers`, because the receiver writes its
#                            response line and the mock its invocation line
#                            after the client already holds its answer.
#
# The two stimulus paths, as measured in Gate 2 Task 1:
#   waypoint  an in-cluster Job, ztunnel-captured, so the request reaches the
#             receiver through that receiver's own istiod-driven agentgateway
#             waypoint.
#   ingress   the harness on this host through `kubectl port-forward` to the
#             agentgateway ingress Service. port-forward is a TCP tunnel and not
#             an HTTP proxy: it forwards bytes and rewrites nothing, so the Host
#             header the harness sets is what the gateway matches on. The
#             ingress dials the receiver pod on 15008 rather than the Service
#             VIP, so no waypoint is on that hop.
#
# No retry logic here. Each repetition is one `make replay`, which is exactly two
# deliveries and no more. A repetition whose harness run failed is recorded in
# the notes column and is never re-run: a re-run would be a third delivery.
#
# Outcomes are read from the harness client lines, which carry the status, the
# result kind, the state and the error of each attempt. `make replay` returns 0
# or 2 and nothing finer (GNU make maps every recipe failure to 2), so its exit
# status is used only as success or failure and is recorded in the notes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
MODE="${MODE:-}"
RECEIVER="${RECEIVER:-}"
REPS="${REPS-20}"
VIAS="${VIAS:-waypoint ingress}"
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
CURL_POD="a1-curl"
CURL_IMAGE="curlimages/curl:8.22.0"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"
# The orchestrator's DOWNSTREAM_A2A_URL as it was found before this script
# removed it, read from the Deployment rather than assumed; step 2b deploys
# http://worker.lab.svc.cluster.local:8080. Empty until the RECEIVER=py switch
# reads it, and the value the EXIT trap puts back.
ORCH_DOWNSTREAM_PRE=""
COLLECT_WAIT="${COLLECT_WAIT:-2}"

case "$MODE" in
M1 | M2 | M3) ;;
*)
	echo "usage: MODE=<M1|M2|M3> RECEIVER=<go|py> [REPS=20] [VIAS=\"waypoint ingress\"] [RUN_ID=<nonce>] $0" >&2
	exit 1
	;;
esac
case "$RECEIVER" in
go)
	SOURCE="worker"
	RECEIVER_URL="$WORKER_URL"
	;;
py)
	SOURCE="orchestrator"
	RECEIVER_URL="$ORCH_URL"
	;;
*)
	echo "usage: MODE=<M1|M2|M3> RECEIVER=<go|py> [REPS=20] [VIAS=\"waypoint ingress\"] [RUN_ID=<nonce>] $0" >&2
	exit 1
	;;
esac
case "$REPS" in
'' | *[!0-9]*)
	echo "gate2-a1: REPS=${REPS} is not a positive integer" >&2
	exit 1
	;;
esac
if [ "$REPS" -lt 1 ]; then
	echo "gate2-a1: REPS=${REPS} is not a positive integer" >&2
	exit 1
fi
for via in $VIAS; do
	case "$via" in
	waypoint | ingress) ;;
	*)
		echo "gate2-a1: VIAS entry '$via' is not waypoint or ingress" >&2
		exit 1
		;;
	esac
done

MODE_LC="$(printf '%s' "$MODE" | tr 'A-Z' 'a-z')"
RUN_ITEM="${RUN_ITEM:-$(date +%F)-a1-${MODE_LC}-${RECEIVER}}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
mkdir -p "$RUN_DIR"

# One run directory holds one run. Chunking by VIAS appends to the same summary
# and keeps the same RUN_ID, so rows carrying a different nonce mean two runs are
# being mixed into one directory, and a directory whose numbers a findings entry
# already cites must not grow. Refuse before anything is sent.
if [ -s "${RUN_DIR}/summary.csv" ]; then
	foreign=$(awk -F, -v id="-${RUN_ID}-" 'NR > 1 && index($4, id) == 0 { n++ } END { print n + 0 }' "${RUN_DIR}/summary.csv")
	if [ "$foreign" != "0" ]; then
		echo "gate2-a1: ${RUN_DIR}/summary.csv already holds ${foreign} rows from another run (this run's nonce is ${RUN_ID}); set RUN_ITEM to a new directory, or RUN_ID to the existing run's nonce to chunk it" >&2
		exit 1
	fi
fi

RESTORE_ORCH="no"
# Written only when the RECEIVER=py switch is made: the value that was there
# before, and what became of it. A kill -9 leaves this file behind, so the value
# to put back survives the script that removed it.
ORCH_MODE_FILE="${RUN_DIR}/orchestrator-mode.txt"

# The restore cannot fail quietly. Each command's status is kept, and a failed
# restore says so on stderr, records it in the run directory and leaves the
# script non-zero, because the alternative is a later run measuring an
# orchestrator that is still in model mode.
cleanup() {
	trigger_rc=$?
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$RESTORE_ORCH" = "yes" ]; then
		echo "== restoring the orchestrator's DOWNSTREAM_A2A_URL =="
		set_rc=0
		kubectl -n "$NAMESPACE" set env deployment/orchestrator "DOWNSTREAM_A2A_URL=${ORCH_DOWNSTREAM_PRE}" >/dev/null 2>&1 || set_rc=$?
		roll_rc=0
		kubectl -n "$NAMESPACE" rollout status deployment/orchestrator --timeout=180s >/dev/null 2>&1 || roll_rc=$?
		if [ "$set_rc" = "0" ] && [ "$roll_rc" = "0" ]; then
			printf '%s restored DOWNSTREAM_A2A_URL=%s\n' "$(date -u +%FT%TZ)" "$ORCH_DOWNSTREAM_PRE" | tee -a "$ORCH_MODE_FILE"
		else
			printf '%s RESTORE FAILED (set env rc=%s, rollout rc=%s); deployment/orchestrator is still in model mode. Put it back with: kubectl -n %s set env deployment/orchestrator DOWNSTREAM_A2A_URL=%s\n' \
				"$(date -u +%FT%TZ)" "$set_rc" "$roll_rc" "$NAMESPACE" "$ORCH_DOWNSTREAM_PRE" | tee -a "$ORCH_MODE_FILE" >&2
			echo "gate2-a1: the orchestrator was NOT restored; see ${ORCH_MODE_FILE}" >&2
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
	awk '$2 == "Leaf" && $4 == "true" { if ($1 ~ /ns\/lab\/sa\/worker$/) w = 1; if ($1 ~ /ns\/lab\/sa\/orchestrator$/) o = 1 } END { exit !(w && o) }' "$CERT_FILE"
}
echo "== certificate check =="
istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker" >"$CERT_FILE"
if cert_valid; then
	echo "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/worker and spiffe://cluster.local/ns/lab/sa/orchestrator; ztunnel not restarted"
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

# --- control pod and the unarmed receiver ------------------------------------
echo "== starting the control pod =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

post() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w '%{http_code}' -X POST "$1"; }
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

# A.1 measures a duplicate delivery to a receiver that is failing nothing, so the
# receiver's injector is disarmed before the run and the reply is recorded.
RESET_FILE="${RUN_DIR}/control-reset.txt"

# A control endpoint is addressed through a Service, and a Service load-balances:
# with more than one replica a reset lands on one pod while the request can reach
# another, and `make ledgers` reads one pod's log either way. Both counts would be
# wrong and neither would say so, so the replica count is asserted and recorded
# here, before any control endpoint is called. This run arms nothing; the check is
# the same one the arming runs make, for the same reason.
assert_single_replica() { # $1 = deployment name
	local deploy="$1" spec ready
	spec=$(kubectl -n "$NAMESPACE" get "deployment/${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
	ready=$(kubectl -n "$NAMESPACE" get "deployment/${deploy}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
	printf '%s deployment/%s replicas: spec=%s ready=%s\n' \
		"$(date -u +%FT%TZ)" "$deploy" "${spec:-<none>}" "${ready:-0}" | tee -a "$RESET_FILE"
	if [ "$spec" != "1" ] || [ "${ready:-0}" != "1" ]; then
		echo "gate2-a1: deployment/${deploy} is not at exactly one ready replica (spec=${spec:-<none>} ready=${ready:-0}); scale it to 1 before a control endpoint is called through its Service" >&2
		exit 1
	fi
}
assert_single_replica "$SOURCE"
assert_single_replica mockllm

echo "== disarming the receiver under test =="
reset_code=$(post "${RECEIVER_URL}/control/reset")
printf '%s POST %s/control/reset -> %s (receiver %s; nothing armed for this run)\n' \
	"$(date -u +%FT%TZ)" "$RECEIVER_URL" "$reset_code" "$SOURCE" | tee -a "$RESET_FILE"
ok2xx "$reset_code" || {
	echo "gate2-a1: ${RECEIVER_URL}/control/reset returned ${reset_code}" >&2
	exit 1
}

reset_mock() {
	local c
	c=$(post "${MOCK_URL}/control/reset")
	ok2xx "$c" || {
		echo "gate2-a1: mock reset returned $c" >&2
		exit 1
	}
}

# --- receiver mode -----------------------------------------------------------
# A.1 asks what one receiver does with a duplicate, so the receiver under test
# answers the request itself. The orchestrator is deployed in forward mode, so
# for RECEIVER=py it is put into model mode for the run and restored on exit.
if [ "$RECEIVER" = "py" ]; then
	echo "== putting the orchestrator into model mode for this run =="
	ORCH_DOWNSTREAM_PRE=$(kubectl -n "$NAMESPACE" get deployment/orchestrator \
		-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}')
	printf '%s pre-run DOWNSTREAM_A2A_URL on deployment/orchestrator: %s\n' \
		"$(date -u +%FT%TZ)" "${ORCH_DOWNSTREAM_PRE:-<unset>}" | tee -a "$ORCH_MODE_FILE"
	if [ -z "$ORCH_DOWNSTREAM_PRE" ]; then
		# Already in model mode. Nothing to switch, so nothing to restore, and
		# no value is invented for a variable that was not set.
		printf '%s already in model mode; nothing switched and nothing to restore\n' \
			"$(date -u +%FT%TZ)" | tee -a "$ORCH_MODE_FILE"
	else
		kubectl -n "$NAMESPACE" set env deployment/orchestrator DOWNSTREAM_A2A_URL- >/dev/null
		RESTORE_ORCH="yes"
		printf '%s removed DOWNSTREAM_A2A_URL; if this script dies without restoring it, put it back with: kubectl -n %s set env deployment/orchestrator DOWNSTREAM_A2A_URL=%s\n' \
			"$(date -u +%FT%TZ)" "$NAMESPACE" "$ORCH_DOWNSTREAM_PRE" | tee -a "$ORCH_MODE_FILE"
		kubectl -n "$NAMESPACE" rollout status deployment/orchestrator --timeout=180s >/dev/null
	fi
fi

# --- counting ----------------------------------------------------------------
# Counts are scoped to the receiver under test's own ledger lines, except model
# invocations, which are counted for the work item as a whole.
jqs() { jq -r -s "$@"; }

shape() { # $1 = client.jsonl, $2 = attempt number -> result_kind/state
	jqs --argjson n "$2" '
		[.[] | select(.attempt == $n)]
		| if length == 0 then "none/none"
		  else (last | "\(.result_kind // "none")/\(if (.state // "") == "" then "none" else .state end)")
		  end' "$1"
}
task_of() { # $1 = client.jsonl, $2 = attempt number -> taskId or empty
	jqs --argjson n "$2" '[.[] | select(.attempt == $n)] | if length == 0 then "" else (last.taskId // "") end' "$1"
}
err_of() { # $1 = client.jsonl, $2 = attempt number -> "<code>:<message>" or empty
	jqs --argjson n "$2" '
		[.[] | select(.attempt == $n)]
		| if length == 0 then ""
		  else (last | if ((.error // "") == "" and (.error_code // 0) == 0) then ""
		               else "\(.error_code // 0):\((.error // "") | gsub("[,;]"; " "))" end)
		  end' "$1"
}

# The header is written once, and each row is appended as it is produced rather
# than buffered to the end: a repetition that has already been spent cannot be
# re-run, so its row must not depend on the run reaching its last line. Rows
# appending is also what lets VIAS chunk a run into one summary.
write_header() {
	if [ ! -s "${RUN_DIR}/summary.csv" ]; then
		echo "mode,receiver,path,work_item,deliveries,executes,distinct_message_ids,tasks_created,invocations,resp1,resp2,same_task,notes" >"${RUN_DIR}/summary.csv"
	fi
}

one_rep() { # $1 = via, $2 = repetition number
	local via="$1" n="$2"
	local lwi="a1-${MODE_LC}-${RECEIVER}-${via}-${RUN_ID}-$(printf '%02d' "$n")"
	local d="${RUN_DIR}/${via}/${lwi}"
	local notes="" rc=0
	mkdir -p "$d"

	reset_mock
	make --no-print-directory replay "MODE=${MODE}" "RECEIVER=${RECEIVER}" "VIA=${via}" "LWI=${lwi}" "OUT=${d}" >"${d}/replay.log" 2>&1 || rc=$?
	# `make replay` returns 0 or 2 and nothing finer, so it is read as success or
	# failure only; what each attempt got is read from the client lines below.
	if [ "$rc" != "0" ]; then notes="${notes}replay_make_rc=${rc};"; fi

	sleep "$COLLECT_WAIT"
	local lrc=0
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${d}" >/dev/null 2>>"${d}/replay.log" || lrc=$?
	if [ "$lrc" != "0" ]; then notes="${notes}ledgers_rc=${lrc};"; fi
	local f
	for f in ingress execution invocation client; do
		[ -f "${d}/${f}.jsonl" ] || : >"${d}/${f}.jsonl"
	done

	local deliveries executes distinct_message_ids tasks_created invocations
	deliveries=$(jqs --arg src "$SOURCE" '[.[] | select(.source == $src and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
	distinct_message_ids=$(jqs --arg src "$SOURCE" '[.[] | select(.source == $src and .phase == "arrival" and .method == "SendMessage") | .messageId] | unique | length' "${d}/ingress.jsonl")
	# a dispatch is the executor entry line, not the SDK's "received"
	executes=$(jqs --arg src "$SOURCE" '[.[] | select(.source == $src and .event == "execute")] | length' "${d}/execution.jsonl")
	tasks_created=$(jqs --arg src "$SOURCE" '[.[] | select(.source == $src and .state == "TASK_STATE_SUBMITTED") | .taskId] | unique | length' "${d}/execution.jsonl")
	# a stale-closed line records a connection close, not a call
	invocations=$(jqs '[.[] | select(.outcome != "stale-closed")] | length' "${d}/invocation.jsonl")

	local resp1 resp2 t1 t2 same_task
	resp1=$(shape "${d}/client.jsonl" 1)
	resp2=$(shape "${d}/client.jsonl" 2)
	t1=$(task_of "${d}/client.jsonl" 1)
	t2=$(task_of "${d}/client.jsonl" 2)
	if [ -z "$t1" ] || [ -z "$t2" ]; then
		same_task="n-a"
	elif [ "$t1" = "$t2" ]; then
		same_task="yes"
	else
		same_task="no"
	fi

	# Everything below is evidence that the repetition was not the clean two
	# deliveries it was meant to be. Each is recorded, never repaired.
	local client_lines injections other_arrivals e1 e2
	client_lines=$(jqs 'length' "${d}/client.jsonl")
	[ "$client_lines" = "2" ] || notes="${notes}client_lines=${client_lines};"
	injections=$(jqs '[.[] | select(.injection != null)] | length' "${d}/ingress.jsonl")
	[ "$injections" = "0" ] || notes="${notes}injection_lines=${injections};"
	other_arrivals=$(jqs --arg src "$SOURCE" '[.[] | select(.source != $src and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
	[ "$other_arrivals" = "0" ] || notes="${notes}arrivals_at_the_other_agent=${other_arrivals};"
	e1=$(err_of "${d}/client.jsonl" 1)
	e2=$(err_of "${d}/client.jsonl" 2)
	[ -z "$e1" ] || notes="${notes}attempt1_error=${e1};"
	[ -z "$e2" ] || notes="${notes}attempt2_error=${e2};"

	local row="${MODE},${RECEIVER},${via},${lwi},${deliveries},${executes},${distinct_message_ids},${tasks_created},${invocations},${resp1},${resp2},${same_task},${notes}"
	echo "  $row"
	printf '%s\n' "$row" >>"${RUN_DIR}/summary.csv"
}

write_header
for via in $VIAS; do
	echo "== ${MODE} x ${RECEIVER} via ${via}: ${REPS} repetitions =="
	for i in $(seq 1 "$REPS"); do
		one_rep "$via" "$i"
	done
done

# Both injectors are disarmed after the run as well as before, so a run that ends
# here leaves nothing armed for the next one to be surprised by. A reset that does
# not answer 2xx fails the script rather than being noted: the next run would
# otherwise start against a cluster this one cannot vouch for.
echo "== disarming the receiver and the mock after the run =="
for url in "${RECEIVER_URL}/control/reset" "${MOCK_URL}/control/reset"; do
	code=$(post "$url")
	printf '%s POST %s -> %s (post-run)\n' "$(date -u +%FT%TZ)" "$url" "$code" | tee -a "$RESET_FILE"
	ok2xx "$code" || {
		echo "gate2-a1: post-run ${url} returned ${code}; the cluster may still be armed" >&2
		exit 1
	}
done

echo "== summary =="
cat "${RUN_DIR}/summary.csv"
