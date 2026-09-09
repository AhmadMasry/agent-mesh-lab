#!/usr/bin/env bash
# Gate 3 / A.3 — the retry-location matrix.
#
# One row of the matrix per invocation. A row is a receiver, a set of retry
# knobs, and one failure injected per repetition, and what it records is the
# counts the three ledgers produce for each work item plus the trace that
# explains them. The ledgers are the ground truth; the trace is the explanation,
# and "not attributable" is a recorded outcome, not a failure.
#
# The rows, and what each one switches on. Every knob not named by a row is
# rendered at its off value rather than omitted, so no row can leave a knob on
# by forgetting it.
#
#   baseline  nothing switched on anywhere, and the zero is asserted rather than
#             assumed: zero `retry:` stanzas across every HTTPRoute, the client
#             knobs rendered off into the Job, and the receiver's model-retry
#             knob read back off the live Deployment. One mock `close` keyed by
#             the work item, as Gate 1's baseline did, so the raw failure is
#             visible: the receiver's Task fails and no layer re-sends anything.
#   R1        the client's own retry. SUB=http is CLIENT_RETRIES=1 with
#             CLIENT_RETRY_ON=transport+503; SUB=sdk is CLIENT_SDK_RESEND=on.
#             The failure is injected at the receiver, after its ingress ledger
#             has counted the delivery.
#   R2        the gateway's HTTPRoute retry, with the same receiver-side
#             injection. SUB=waypoint switches it on for the `worker` route the
#             istiod-driven waypoint serves, and is a Go-receiver row only: no
#             HTTPRoute names the orchestrator Service as a parent, and the
#             Python receiver's SendMessage POST enters through the ingress
#             because its card advertises it, so the sub-row is refused there
#             with that reason. SUB=ingress switches it on for the two routes on
#             the agentgateway ingress and takes its stimulus from outside the
#             cluster (see send_through_ingress below). SUB=ingress-incluster is
#             the same route set with the in-cluster stimulus, which is the
#             Python receiver's gateway row.
#   R3        the receiver's own model client retry: MODEL_RETRIES=1 on the Go
#             receiver, MODEL_MAX_RETRIES=1 on the Python one. The mock is armed
#             by invocation count rather than by work item, so exactly one call
#             fails and a second attempt can succeed.
#   R4        R1's http knob, R3's model knob and the gateway route in front of
#             this receiver, with the receiver and the mock both armed for the
#             same work item. The gateway layer is the waypoint route for the Go
#             receiver and the ingress route for the Python one, which is the
#             same object R2's sub-rows use for each: composing with a route the
#             stimulus never crosses would leave the gateway layer inert, and in
#             the composition row that reads as "the layers did not compose"
#             rather than as "the gateway did not retry".
#   egress    the egress route's retry with the model endpoint armed `http500`
#             for the work item (the author's extra row).
#
# Two things about the injections are properties of the fixtures, not choices
# made here, and both are recorded in knobs.txt:
#
#   * A receiver holds ONE armed mode per work item (agents/worker/control.go,
#     agents/orchestrator/orchestrator/control.py), so a row that wants a
#     receiver-side failure gets one, not two.
#   * The Python receiver refuses `close-after-read` with HTTP 400 — ASGI has no
#     portable connection hijack — so rows that inject at the receiver use
#     `http503-before-dispatch` there. Gate 2 measured that the istiod-driven
#     waypoint converts a receiver's connection close into a synthesised 503
#     anyway, so this is the same thing the client would have seen.
#
# No retry logic in this script. Each repetition is one stimulus; any second
# delivery was made by the layer under test. A repetition whose Job failed is
# recorded in the notes column and never re-run, because a re-run would be
# another delivery.
#
#   RUN=<baseline|R1|R2|R3|R4|egress>  required.
#   RECEIVER=<go|py>                   required. `go` is the worker, `py` the
#                                      orchestrator, which runs in model mode
#                                      for its rows (DOWNSTREAM_A2A_URL unset
#                                      for the run, recorded and restored).
#   SUB=<http|sdk|waypoint|ingress|ingress-incluster>
#                                      required for R1 (http, sdk) and R2
#                                      (waypoint, ingress, ingress-incluster),
#                                      refused elsewhere.
#   REPS=<n>                           default 20. An empty or non-numeric value
#                                      is an error; a silent default here spends
#                                      repetitions that cannot be taken back.
#   DRY_RUN=<on|off>                   default on. One repetition under a scratch
#                                      nonce whose directory is deleted, before
#                                      the counted ones.
#   RUN_ID=<nonce>                     default $(date +%H%M%S). Every work-item
#                                      id carries it: the trace backend and the
#                                      pod logs both outlive a run, and a
#                                      repeated id would collect an earlier run's
#                                      lines and spans as this run's.
#   RUN_ITEM=<name>                    default <date>-a3-<run>-<receiver>[-<sub>];
#                                      names the run directory under experiments/runs/.
#   COLLECT_WAIT=<seconds>             default 2, between the client returning
#                                      and `make ledgers`.
#   TRACE_WAIT=<seconds>               default 8, before `make export-trace`: the
#                                      batch span processors flush on a timer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
RUN="${RUN:-}"
RECEIVER="${RECEIVER:-}"
SUB="${SUB:-}"
REPS="${REPS-20}"
DRY_RUN="${DRY_RUN:-on}"
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
COLLECT_WAIT="${COLLECT_WAIT:-2}"
TRACE_WAIT="${TRACE_WAIT:-8}"
CURL_POD="a3m-curl"
CURL_IMAGE="curlimages/curl:8.11.1"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"
INGRESS_NS="agentgateway-system"
INGRESS_PORT=18080
JOB_TEMPLATE="deploy/base/loadgen-a2-job.yaml"

usage() {
	echo "usage: RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=<http|sdk|waypoint|ingress|ingress-incluster>] [REPS=20] [DRY_RUN=on|off] [RUN_ID=<nonce>] [RUN_ITEM=<name>] $0" >&2
	exit 1
}

case "$RUN" in baseline | R1 | R2 | R3 | R4 | egress) ;; *) usage ;; esac
case "$RECEIVER" in go | py) ;; *) usage ;; esac
case "$RUN" in
R1)
	case "$SUB" in http | sdk) ;; *)
		echo "gate3-matrix: RUN=R1 needs SUB=http or SUB=sdk" >&2
		exit 1
		;;
	esac
	;;
R2)
	case "$SUB" in waypoint | ingress | ingress-incluster) ;; *)
		echo "gate3-matrix: RUN=R2 needs SUB=waypoint, SUB=ingress or SUB=ingress-incluster" >&2
		exit 1
		;;
	esac
	# The Python receiver has no waypoint sub-row; the general guard below the row
	# table refuses it, along with any other row that would name that route for
	# this receiver.
	#
	# ingress-incluster is the Python receiver's in-cluster gateway sub-row and
	# means nothing for the Go one: an in-cluster loadgen Job to the worker
	# Service crosses the worker's waypoint, not the ingress.
	if [ "$RECEIVER" = "go" ] && [ "$SUB" = "ingress-incluster" ]; then
		echo "gate3-matrix: RUN=R2 RECEIVER=go SUB=ingress-incluster is refused: an in-cluster Job to the worker Service crosses the worker's waypoint, not the ingress. Use SUB=waypoint for the in-cluster gateway or SUB=ingress for the out-of-cluster one." >&2
		exit 1
	fi
	;;
*)
	if [ -n "$SUB" ]; then
		echo "gate3-matrix: RUN=${RUN} has no sub-rows; SUB=${SUB} names nothing" >&2
		exit 1
	fi
	;;
esac
case "$REPS" in '' | *[!0-9]*) echo "gate3-matrix: REPS=${REPS} is not a positive integer" >&2 && exit 1 ;; esac
[ "$REPS" -ge 1 ] || {
	echo "gate3-matrix: REPS=${REPS} is not a positive integer" >&2
	exit 1
}
case "$DRY_RUN" in on | off) ;; *) usage ;; esac

# --- what this row is ---------------------------------------------------------
# Which Deployment is the receiver, which of its environment variables is the
# model-client retry knob, and where the stimulus is aimed.
if [ "$RECEIVER" = "go" ]; then
	RECEIVER_DEPLOY="worker"
	RECEIVER_SOURCE="worker"
	RECEIVER_URL="$WORKER_URL"
	MODEL_KNOB="MODEL_RETRIES"
	INGRESS_HOST="worker.lab.internal"
else
	RECEIVER_DEPLOY="orchestrator"
	RECEIVER_SOURCE="orchestrator"
	RECEIVER_URL="$ORCH_URL"
	MODEL_KNOB="MODEL_MAX_RETRIES"
	# The orchestrator answers the ingress catch-all route, so no Host is set.
	INGRESS_HOST=""
fi

# Client knobs, rendered into the Job template for every row at these values
# unless the row below changes one.
JOB_RETRIES="0"
JOB_SDK_RESEND="off"
JOB_RETRY_ON="transport"
# The receiver's model-retry knob value this row wants. Empty means "leave the
# Deployment alone", which is not the same as setting it to 0.
MODEL_KNOB_VALUE=""
# The route set whose retry stanza goes on, and how many stanzas that should
# produce across every HTTPRoute in the cluster.
ROUTE=""
EXPECTED_STANZAS=0
# Injections armed per repetition. Empty means none.
RECEIVER_INJECT=""
MOCK_INJECT_TEMPLATE=""
# Where the stimulus comes from.
STIMULUS="loadgen-job"
# Why the receiver injection is the mode it is, recorded rather than assumed.
INJECT_NOTE=""

# The receiver-side injection mode for the rows that fail the delivery itself.
# The Python receiver refuses close-after-read (HTTP 400; ASGI has no portable
# connection hijack), so it is given the 503 instead; behind the waypoint the
# two are the same thing to a client, which Gate 2 measured. Assigned rather
# than printed, so the note it carries is not lost in a subshell.
RECEIVER_CLOSE_MODE="close-after-read"
if [ "$RECEIVER" = "py" ]; then
	RECEIVER_CLOSE_MODE="http503-before-dispatch"
fi

case "${RUN}${SUB:+/$SUB}" in
baseline)
	# Nothing on anywhere. The mock closes the connection on the model call for
	# this work item, as Gate 1's baseline did, so the failure is raw.
	MOCK_INJECT_TEMPLATE='{"mode":"close","lwi":"__LWI__"}'
	;;
R1/http)
	JOB_RETRIES="1"
	JOB_RETRY_ON="transport+503"
	RECEIVER_INJECT="$RECEIVER_CLOSE_MODE"
	;;
R1/sdk)
	JOB_SDK_RESEND="on"
	RECEIVER_INJECT="$RECEIVER_CLOSE_MODE"
	;;
R2/waypoint)
	ROUTE="waypoint"
	EXPECTED_STANZAS=1
	RECEIVER_INJECT="http503-before-dispatch"
	;;
R2/ingress)
	ROUTE="ingress"
	EXPECTED_STANZAS=2
	RECEIVER_INJECT="http503-before-dispatch"
	STIMULUS="curl-through-the-ingress"
	;;
R2/ingress-incluster)
	# Same route set, in-cluster stimulus. The Python receiver's card advertises
	# the ingress, so a loadgen Job to the orchestrator Service sends its
	# SendMessage POST through the ingress and crosses the patched route.
	ROUTE="ingress"
	EXPECTED_STANZAS=2
	RECEIVER_INJECT="http503-before-dispatch"
	;;
R3)
	MODEL_KNOB_VALUE="1"
	# By invocation count, not by work item: the count is reset before every
	# repetition, so exactly the first call of this work item fails and a second
	# attempt can succeed. A work-item-keyed arming would fail both.
	MOCK_INJECT_TEMPLATE='{"mode":"close","at_count":1}'
	;;
R4)
	JOB_RETRIES="1"
	JOB_RETRY_ON="transport+503"
	MODEL_KNOB_VALUE="1"
	# The gateway layer of the composition is whichever gateway is actually in
	# front of this receiver, which is not the same object for the two: the
	# worker's own istiod-driven waypoint, and for the orchestrator the
	# agentgateway ingress its card advertises, which is the route set R2's
	# ingress-incluster sub-row uses. Composing with a route the stimulus never
	# crosses would leave the gateway layer inert, and in the composition row an
	# inert layer does not show up as "the gateway did not retry"; it shows up as
	# "the layers did not compose".
	if [ "$RECEIVER" = "py" ]; then
		ROUTE="ingress"
		EXPECTED_STANZAS=2
	else
		ROUTE="waypoint"
		EXPECTED_STANZAS=1
	fi
	RECEIVER_INJECT="http503-before-dispatch"
	MOCK_INJECT_TEMPLATE='{"mode":"close","at_count":1}'
	INJECT_NOTE="one receiver mode per work item, so the 503 stands for both R1's and R2's injection"
	;;
egress)
	ROUTE="egress"
	EXPECTED_STANZAS=1
	MOCK_INJECT_TEMPLATE='{"mode":"http500","lwi":"__LWI__"}'
	;;
*) usage ;;
esac

# No row switches the waypoint route on for the Python receiver, whichever row
# asks. Two facts make it unmeasurable rather than merely odd: no HTTPRoute names
# the orchestrator Service as a parent (the three that exist name the worker
# Service and the two Gateways), so `retry-on ROUTE=waypoint` patches `lab/worker`
# and leaves the orchestrator's path untouched; and the Task 3 baseline measured
# that this receiver's SendMessage POST enters through the agentgateway ingress,
# because its agent card advertises it. The per-route stanza assertion cannot
# catch this: the stanza does land on `lab/worker`, which is a live route, just
# not one this receiver's stimulus crosses. So the guard is here, before anything
# is sent, rather than in one row's arm.
if [ "$RECEIVER" = "py" ] && [ "$ROUTE" = "waypoint" ]; then
	echo "gate3-matrix: RUN=${RUN}${SUB:+ SUB=$SUB} RECEIVER=py would switch the retry on for the waypoint route, which is refused: no HTTPRoute has the orchestrator Service as its parent, and this receiver's SendMessage POST enters through the agentgateway ingress, not through its own waypoint. The gateway in front of this receiver is the ingress route set (RUN=R2 SUB=ingress-incluster in-cluster, SUB=ingress out-of-cluster)." >&2
	exit 1
fi
if [ "$RUN" = "R1" ] && [ "$RECEIVER" = "py" ]; then
	INJECT_NOTE="the Python receiver refuses close-after-read (HTTP 400), so http503-before-dispatch is armed instead"
fi

KNOB_LABEL="CLIENT_RETRIES=${JOB_RETRIES} CLIENT_SDK_RESEND=${JOB_SDK_RESEND} CLIENT_RETRY_ON=${JOB_RETRY_ON} ${MODEL_KNOB}=${MODEL_KNOB_VALUE:-<left as deployed>} route-retry=${ROUTE:-none}"

# Work-item ids are lowercased and checked before anything uses one: they become
# Job names, which reject an uppercase letter, and they are the key every ledger
# and every trace query is read by, so a rejected id has to stop the run rather
# than produce a repetition nothing can be collected for.
RUN_ID="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]')"
RUN_LC="$(printf '%s' "$RUN" | tr '[:upper:]' '[:lower:]')"
work_item() { # $1 = repetition label -> the id, validated
	local id="a3m-${RUN_LC}-${RECEIVER}${SUB:+-$SUB}-${RUN_ID}-$1"
	id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
	if ! printf '%s' "$id" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
		echo "gate3-matrix: work item id ${id} is not a usable Job name; set RUN_ID to something lowercase and alphanumeric" >&2
		exit 1
	fi
	printf '%s' "$id"
}

RUN_ITEM="${RUN_ITEM:-$(date +%F)-a3-${RUN_LC}-${RECEIVER}${SUB:+-$SUB}}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
mkdir -p "$RUN_DIR"
CONTROL_FILE="${RUN_DIR}/control.txt"
KNOBS_FILE="${RUN_DIR}/knobs.txt"
SUMMARY="${RUN_DIR}/summary.csv"

# One run directory holds one run. Rows are appended as they are produced, so a
# directory whose numbers a findings entry already cites must not grow with rows
# from a second nonce. Refuse before anything is sent.
if [ -s "$SUMMARY" ]; then
	foreign=$(awk -F, -v id="-${RUN_ID}-" 'NR > 1 && index($4, id) == 0 { n++ } END { print n + 0 }' "$SUMMARY")
	if [ "$foreign" != "0" ]; then
		echo "gate3-matrix: ${SUMMARY} already holds ${foreign} rows from another run (this run's nonce is ${RUN_ID}); set RUN_ITEM to a new directory, or RUN_ID to the existing run's nonce to chunk it" >&2
		exit 1
	fi
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEADER="== ${STAMP} | RUN=${RUN} RECEIVER=${RECEIVER}${SUB:+ SUB=$SUB} | RUN_ID=${RUN_ID} | REPS=${REPS} =="

# --- reading and writing the receiver's environment ---------------------------
receiver_env() { # $1 = variable name -> its value on the Deployment, empty if unset
	kubectl -n "$NAMESPACE" get "deployment/${RECEIVER_DEPLOY}" \
		-o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"
}

deploy_env() { # $1 = deployment, $2 = variable name -> its value, empty if unset
	kubectl -n "$NAMESPACE" get "deployment/$1" \
		-o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}" 2>/dev/null || true
}

# --- reading the retry stanzas back -------------------------------------------
# Two reads, because they answer different questions. The cluster-wide count says
# whether any route anywhere carries a retry, which is what every row that is not
# measuring one has to see at zero. The per-route count says whether the stanza
# landed on the routes this row's ROUTE names, which a cluster-wide count cannot:
# a stanza on the wrong route passes a cluster-wide assertion and leaves the row
# measuring a hop the stimulus never crosses.
ROUTES_WAYPOINT="lab/worker"
ROUTES_INGRESS="lab/worker-ingress lab/orchestrator-ingress"
ROUTES_EGRESS="agentgateway-egress/model-via-agw"

routes_for() { # $1 = waypoint|ingress|egress -> "<ns>/<name> ..."
	case "$1" in
	waypoint) printf '%s' "$ROUTES_WAYPOINT" ;;
	ingress) printf '%s' "$ROUTES_INGRESS" ;;
	egress) printf '%s' "$ROUTES_EGRESS" ;;
	esac
}

stanzas_total() { kubectl get httproute -A -o yaml 2>/dev/null | grep -c 'retry:' || true; }

stanzas_on_route() { # $1 = <ns>/<name>
	kubectl -n "${1%%/*}" get "httproute/${1#*/}" -o yaml 2>/dev/null | grep -c 'retry:' || true
}

stanzas_per_route_line() { # every route this lab patches, named, with its count
	local set route line=""
	for set in waypoint ingress egress; do
		for route in $(routes_for "$set"); do
			line="${line}${line:+ }${route}=$(stanzas_on_route "$route")"
		done
	done
	printf '%s' "$line"
}

# --- restore ------------------------------------------------------------------
# Everything this run changed is put back on every exit path. A failed restore
# says so on stderr, records it, and leaves the script non-zero: the alternative
# is a later run measuring a cluster that still carries a retry.
RESTORE_ROUTE="no"
RESTORE_ENV="no"
ENV_UNDO_ARGS=""
ENV_UNDO_SAYS=""
PF_INGRESS=""
cleanup() {
	trigger_rc=$?
	if [ -n "$PF_INGRESS" ]; then
		kill "$PF_INGRESS" >/dev/null 2>&1 || true
		wait "$PF_INGRESS" 2>/dev/null || true
	fi
	restore_failed=0
	if [ "$RESTORE_ENV" = "yes" ]; then
		echo "== restoring deployment/${RECEIVER_DEPLOY}:${ENV_UNDO_SAYS} =="
		set_rc=0
		# shellcheck disable=SC2086 # each element is one NAME=value or NAME- argument
		kubectl -n "$NAMESPACE" set env "deployment/${RECEIVER_DEPLOY}" $ENV_UNDO_ARGS >/dev/null 2>&1 || set_rc=$?
		roll_rc=0
		kubectl -n "$NAMESPACE" rollout status "deployment/${RECEIVER_DEPLOY}" --timeout=180s >/dev/null 2>&1 || roll_rc=$?
		if [ "$set_rc" = "0" ] && [ "$roll_rc" = "0" ]; then
			printf '%s restored deployment/%s:%s\n' "$(date -u +%FT%TZ)" "$RECEIVER_DEPLOY" "$ENV_UNDO_SAYS" | tee -a "$KNOBS_FILE"
			printf '%s live after the restore: %s=%s DOWNSTREAM_A2A_URL=%s\n' "$(date -u +%FT%TZ)" \
				"$MODEL_KNOB" "$(receiver_env "$MODEL_KNOB")" "$(receiver_env DOWNSTREAM_A2A_URL)" | tee -a "$KNOBS_FILE"
		else
			printf '%s RESTORE FAILED (set env rc=%s, rollout rc=%s). Put it back with: kubectl -n %s set env deployment/%s%s\n' \
				"$(date -u +%FT%TZ)" "$set_rc" "$roll_rc" "$NAMESPACE" "$RECEIVER_DEPLOY" "$ENV_UNDO_ARGS" | tee -a "$KNOBS_FILE" >&2
			echo "gate3-matrix: deployment/${RECEIVER_DEPLOY} was NOT restored; see ${KNOBS_FILE}" >&2
			restore_failed=1
		fi
	fi
	if [ "$RESTORE_ROUTE" = "yes" ]; then
		echo "== restoring the ${ROUTE} route: removing the retry stanza =="
		off_rc=0
		make --no-print-directory retry-off "ROUTE=${ROUTE}" "OUT=${RUN_DIR}/routes-off" >>"$CONTROL_FILE" 2>&1 || off_rc=$?
		left=$(kubectl get httproute -A -o yaml 2>/dev/null | grep -c 'retry:' || true)
		if [ "$off_rc" = "0" ] && [ "$left" = "0" ]; then
			printf '%s retry-off ROUTE=%s restored; retry stanzas across every HTTPRoute: 0\n' "$(date -u +%FT%TZ)" "$ROUTE" | tee -a "$KNOBS_FILE" "$CONTROL_FILE" >/dev/null
			echo "restored: retry stanzas across every HTTPRoute: 0"
		else
			printf '%s RESTORE FAILED (retry-off rc=%s, retry stanzas still present: %s). Put it back with: make retry-off\n' \
				"$(date -u +%FT%TZ)" "$off_rc" "$left" | tee -a "$KNOBS_FILE" >&2
			echo "gate3-matrix: the ${ROUTE} route was NOT restored; see ${KNOBS_FILE}" >&2
			restore_failed=1
		fi
	fi
	# The injectors are disarmed last, while the control pod still exists.
	reset_all_quiet
	# The after-state, written unconditionally rather than only on a path that
	# had something to put back. A row that switches no route on still has to
	# leave a record that no route carried one when it ended, and a run that died
	# before it changed anything still has to say what it left behind.
	{
		printf '%s -- after (%s) --\n' "$(date -u +%FT%TZ)" "$(if [ "$trigger_rc" = "0" ]; then echo "normal end"; else echo "exit status ${trigger_rc}"; fi)"
		printf 'retry stanzas across every HTTPRoute: %s\n' "$(stanzas_total)"
		printf 'retry stanzas per route: %s\n' "$(stanzas_per_route_line)"
		printf 'deployment/worker MODEL_RETRIES=%s\n' "$(deploy_env worker MODEL_RETRIES)"
		printf 'deployment/orchestrator MODEL_MAX_RETRIES=%s\n' "$(deploy_env orchestrator MODEL_MAX_RETRIES)"
		printf 'deployment/orchestrator DOWNSTREAM_A2A_URL=%s\n' "$(deploy_env orchestrator DOWNSTREAM_A2A_URL)"
		printf 'deployment/orchestrator PLAN_MODEL_CALL=%s\n' "$(deploy_env orchestrator PLAN_MODEL_CALL)"
		echo "CLIENT_* on any Deployment in ${NAMESPACE} (empty means none):"
		kubectl -n "$NAMESPACE" get deploy -o json 2>/dev/null |
			jq -r '.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "  \($n) \(.name)=\(.value)"' || true
		printf 'injector resets on this exit path: %s\n' "$RESET_RESULTS"
	} >>"$KNOBS_FILE" 2>&1
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	if [ "$restore_failed" = "1" ]; then exit 1; fi
	return "$trigger_rc"
}

# --- certificate check --------------------------------------------------------
# A ztunnel whose leaf certificate is not valid drops every mesh hop this run
# measures, so this runs before anything is sent.
CERT_FILE="${RUN_DIR}/certificates.txt"
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

# --- image freshness -----------------------------------------------------------
# A Deployment's env var means nothing to a binary built before the code that
# reads it existed: `kubectl set env` restarts the pod onto whatever image the
# Deployment already names, it does not rebuild anything. Measured the hard way
# at Task 6 (RUN=R3 RECEIVER=go, before this check existed): MODEL_RETRIES was
# added to agents/worker/main.go one commit after the worker image then running
# was last built (Task 2's own report: "make step-3 was not run"), so setting
# MODEL_RETRIES=1 on the live Deployment did nothing — a full twenty-repetition
# run showed invocations=1 in every one of the 20 work items, silently.
#
# The first version of this check compared the running Deployment's image
# against what `ko build --push=false` resolves from the checkout right now,
# and it was wrong: `ko`'s own tag is not a pure content hash of the Go source
# — two builds of byte-identical code, run minutes apart, resolved to two
# different tags (measured directly, this task: `kind.local/worker-…:7f5add70…`
# then `kind.local/worker-…:bdf46076…` for the same checkout), almost certainly
# because the OCI image's own `Created` field defaults to build wall-clock time.
# That check would have refused every future row once enough time passed,
# whether or not the code had actually changed — a false refusal, not a safe
# one, and it would have blocked R3/py, which never needed a rebuild at all.
#
# Second correction, ruled after review: the ReplicaSet-timestamp version above
# degrades toward PASSING a stale image as Kubernetes prunes old ReplicaSets
# (default revisionHistoryLimit 10). It read the *earliest* ReplicaSet still
# carrying a Deployment's declared image as the image's true build time; once
# the ReplicaSet that first carried a stale image is pruned, the next-earliest
# surviving one with that same image is *later*, which only ever makes the
# comparison "a commit lands after the deploy" true LESS often — the guard
# passes more as history churns, never refuses more. Measured directly on this
# cluster: the worker Deployment was at revision 37, 11 ReplicaSets survived,
# only 2 of them carried its current image, and revisions 23-35 (the ones that
# would have anchored an earlier build) were already gone — a margin of about
# nine ReplicaSets before this exact drift would have started passing a stale
# image. That direction is backwards from what this check exists to guarantee.
#
# Replaced with a stamped source hash instead of anything computed from
# ReplicaSet history or from a freshly built image's own tag (which this
# repository has separately measured is not stable across time either, above).
# Every step target that runs `ko apply` (see the Makefile) annotates both the
# worker and the mock Deployment with `lab.agent-mesh/go-sources=<hash>`, a
# content hash of the tracked Go sources those two binaries are built from
# (`GO_SOURCES_HASH` in the Makefile; test files excluded, since ko does not
# compile them and a test-only commit must not force a rebuild). This check
# recomputes that same hash from the checkout with the same command and
# compares it against each Deployment's own stamp — nothing here is derived
# from elapsed time, ReplicaSet count, or a second build, so nothing here can
# drift. It refuses, rather than silently passing, when: the checkout has an
# uncommitted change under the hashed paths (nothing to compare against); the
# hash itself cannot be computed at all (git unreadable is refused, never
# treated as "assume current"); a Deployment carries no such annotation; or the
# annotation differs from the checkout hash. It is read-only against the
# cluster (`kubectl get` only) and records the checkout hash, each Deployment's
# annotation, and every one of its running pods' own `imageID` in `knobs.txt`.
#
# One accepted gap, recorded rather than discovered later: the annotation is
# Deployment metadata, not a binding to the image itself, so `kubectl rollout
# undo`, `kubectl set image`, or a hand-run `ko apply` all change the running
# binary without touching it — the guard would then pass a Deployment whose
# Go sources have not changed but whose image has. Narrower than the version
# this replaced (which did catch a rollback) but the right trade: ReplicaSet
# pruning was automatic and silent, each of these is a deliberate operator
# action, and only a step target ever changes either Deployment's image in
# this lab.
GO_SOURCES_PATHS=(agents/worker fixtures/mockllm internal go.mod go.sum)
GO_SOURCES_DIRTY="$(git status --porcelain -- "${GO_SOURCES_PATHS[@]}" 2>/dev/null || true)"
if [ -n "$GO_SOURCES_DIRTY" ]; then
	echo "gate3-matrix: ${GO_SOURCES_PATHS[*]} has an uncommitted change; a stale image cannot be ruled out against a change with no commit to hash. Commit or stash before running RUN=${RUN}." >&2
	exit 1
fi
CHECKOUT_GO_SOURCES_HASH="$(git ls-files -s -- "${GO_SOURCES_PATHS[@]}" ':!**/*_test.go' 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"
if [ -z "$CHECKOUT_GO_SOURCES_HASH" ]; then
	echo "gate3-matrix: could not compute the Go-sources hash from this checkout (git ls-files or git hash-object failed or returned nothing); refusing to guess whether any Deployment is current" >&2
	exit 1
fi
image_fresh_or_die() {
	local deploy="$1"
	local annotation pod_ids
	annotation="$(kubectl -n "$NAMESPACE" get "deployment/${deploy}" -o jsonpath='{.metadata.annotations.lab\.agent-mesh/go-sources}' 2>/dev/null || true)"
	pod_ids="$(kubectl -n "$NAMESPACE" get pods -l "app=${deploy}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].imageID}{" "}{end}' 2>/dev/null || true)"
	printf '%s image freshness: deployment/%s checkout-go-sources-hash=%s annotation=%s pod-imageIDs: %s\n' \
		"$(date -u +%FT%TZ)" "$deploy" "$CHECKOUT_GO_SOURCES_HASH" "${annotation:-<none>}" "${pod_ids:-<none>}" |
		tee -a "$KNOBS_FILE"
	if [ -z "$annotation" ]; then
		echo "gate3-matrix: deployment/${deploy} carries no lab.agent-mesh/go-sources annotation; it was never stamped by a step target's ko apply, or the annotation was cleared. Rebuild and reload with 'make step-3' (or the step that last changed it, never mid-run) before running RUN=${RUN}." >&2
		exit 1
	fi
	if [ "$annotation" != "$CHECKOUT_GO_SOURCES_HASH" ]; then
		echo "gate3-matrix: deployment/${deploy} is stamped lab.agent-mesh/go-sources=${annotation}, but this checkout's Go sources hash to ${CHECKOUT_GO_SOURCES_HASH}. Rebuild and reload with 'make step-3' (never mid-run) before running RUN=${RUN}." >&2
		exit 1
	fi
}
image_fresh_or_die worker
image_fresh_or_die mockllm

{
	printf '%s\n' "$HEADER"
	kubectl version
	istioctl version --remote=false
	kubectl -n "$NAMESPACE" get deploy -o wide
	echo "orchestrator image digests, by pod:"
	kubectl -n "$NAMESPACE" get pods -l app=orchestrator \
		-o 'custom-columns=POD:.metadata.name,PHASE:.status.phase,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID'
	kubectl get httproute -A
	kubectl get gateway -A
	echo
} >>"${RUN_DIR}/cluster-versions.txt" 2>&1

# --- the knobs, before anything is changed ------------------------------------
{
	printf '%s\n' "$HEADER"
	printf 'row knobs: %s\n' "$KNOB_LABEL"
	[ -z "$INJECT_NOTE" ] || printf 'injection note: %s\n' "$INJECT_NOTE"
	printf 'receiver injection per repetition: %s\n' "${RECEIVER_INJECT:-none}"
	printf 'mock injection per repetition: %s\n' "${MOCK_INJECT_TEMPLATE:-none}"
	printf 'stimulus: %s\n' "$STIMULUS"
	echo "-- before --"
	printf 'deployment/worker MODEL_RETRIES=%s\n' "$(kubectl -n "$NAMESPACE" get deployment/worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_RETRIES")].value}')"
	printf 'deployment/orchestrator MODEL_MAX_RETRIES=%s\n' "$(kubectl -n "$NAMESPACE" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODEL_MAX_RETRIES")].value}')"
	printf 'deployment/orchestrator DOWNSTREAM_A2A_URL=%s\n' "$(kubectl -n "$NAMESPACE" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DOWNSTREAM_A2A_URL")].value}')"
	printf 'deployment/orchestrator PLAN_MODEL_CALL=%s\n' "$(kubectl -n "$NAMESPACE" get deployment/orchestrator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAN_MODEL_CALL")].value}')"
	echo "CLIENT_* on any Deployment in ${NAMESPACE} (empty means none):"
	kubectl -n "$NAMESPACE" get deploy -o json |
		jq -r '.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "  \($n) \(.name)=\(.value)"'
	printf 'the Job this run renders: CLIENT_RETRIES=%s CLIENT_SDK_RESEND=%s CLIENT_RETRY_ON=%s\n' \
		"$JOB_RETRIES" "$JOB_SDK_RESEND" "$JOB_RETRY_ON"
} >>"$KNOBS_FILE" 2>&1

BEFORE_STANZAS=$(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)
printf '%s pre-run retry stanzas across every HTTPRoute: %s\n' "$(date -u +%FT%TZ)" "$BEFORE_STANZAS" | tee -a "$KNOBS_FILE" "$CONTROL_FILE" >/dev/null
echo "pre-run retry stanzas across every HTTPRoute: ${BEFORE_STANZAS}"
if [ "$BEFORE_STANZAS" != "0" ]; then
	echo "gate3-matrix: the cluster already carries ${BEFORE_STANZAS} retry stanza(s); run 'make retry-off' and start from the baseline" >&2
	exit 1
fi

# Every row starts from a cluster whose only retry is the one that row is about
# to switch on, and every row asserts that rather than recording it. A knob left
# on by hand, or by a run that died before its restore, would otherwise be
# measured as this row's result.
#
#   the route stanzas      asserted at 0 above, for every row
#   CLIENT_* on a Deployment   asserted absent for every row: no matrix row sets
#                          a client knob that way (they are rendered into the
#                          Job), so one on a live object is always a leftover
#   the model-retry knob   asserted off for every row except R3 and R4, which
#                          are the two that set it themselves
#   the Job's own knobs    asserted off for the baseline, which is the row whose
#                          question is whether the baseline is retry-free
LIVE_MODEL_KNOB="$(receiver_env "$MODEL_KNOB")"
LIVE_CLIENT_ENV="$(kubectl -n "$NAMESPACE" get deploy -o json |
	jq -r '[.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "\($n):\(.name)=\(.value)"] | join(" ")')"
fail=""
[ -z "$LIVE_CLIENT_ENV" ] || fail="${fail}a Deployment carries a client retry knob (${LIVE_CLIENT_ENV}); "
if [ -z "$MODEL_KNOB_VALUE" ]; then
	case "$LIVE_MODEL_KNOB" in '' | 0) ;; *) fail="${fail}deployment/${RECEIVER_DEPLOY} carries ${MODEL_KNOB}=${LIVE_MODEL_KNOB} and this row does not set it; " ;; esac
fi
if [ "$RUN" = "baseline" ]; then
	[ "$JOB_RETRIES" = "0" ] || fail="${fail}the Job would render CLIENT_RETRIES=${JOB_RETRIES}; "
	[ "$JOB_SDK_RESEND" = "off" ] || fail="${fail}the Job would render CLIENT_SDK_RESEND=${JOB_SDK_RESEND}; "
fi
if [ -n "$fail" ]; then
	echo "gate3-matrix: RUN=${RUN} requires every retry knob it does not set to be off and this cluster is not: ${fail}" >&2
	exit 1
fi
printf '%s pre-run knob assertion passed for RUN=%s: stanzas=0 %s=%s (this row sets it: %s) CLIENT_*=<none on any Deployment> job=CLIENT_RETRIES=%s CLIENT_SDK_RESEND=%s CLIENT_RETRY_ON=%s\n' \
	"$(date -u +%FT%TZ)" "$RUN" "$MODEL_KNOB" "${LIVE_MODEL_KNOB:-<unset>}" "${MODEL_KNOB_VALUE:-no}" \
	"$JOB_RETRIES" "$JOB_SDK_RESEND" "$JOB_RETRY_ON" | tee -a "$KNOBS_FILE"

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

# Every reset is written to the run record with its HTTP status, including the
# ones before a repetition. "Both injectors are reset before and after every
# repetition" is then a claim the committed file carries rather than one the code
# has to be read for.
RESET_RESULTS=""
reset_all() { # $1 = why, for the record
	local url code why="$1"
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url")
		printf '%s POST %s -> %s (%s)\n' "$(date -u +%FT%TZ)" "$url" "$code" "$why" >>"$CONTROL_FILE"
		ok2xx "$code" || {
			echo "gate3-matrix: reset ${url} returned ${code}" >&2
			exit 1
		}
	done
}
# The restore path cannot exit on a reset that fails; it reports and carries on,
# so the knobs and the route stanza are still put back. What each reset answered
# is kept for the after-state block.
reset_all_quiet() {
	local url code
	RESET_RESULTS=""
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url" 2>/dev/null || echo "000")
		printf '%s POST %s -> %s (restore)\n' "$(date -u +%FT%TZ)" "$url" "$code" >>"$CONTROL_FILE"
		RESET_RESULTS="${RESET_RESULTS}${RESET_RESULTS:+ }${url##*//}=${code}"
	done
}

# Armed here rather than at the top of the script: everything it puts back is
# created below it, and everything above it changes nothing in the cluster.
#
# INT and TERM as well as EXIT. Without them a signal ends the shell without the
# EXIT trap having anything to say about which signal it was, and an untrapped
# SIGINT is deferred while bash waits on a foreground child, so a Ctrl-C during a
# `kubectl` call would not stop the run at all. Both handlers exit, which runs the
# EXIT trap and so the restore. A SIGKILL is the one path no trap covers, and
# knobs.txt holds the exact `kubectl set env` that puts the change back.
trap cleanup EXIT
trap 'echo "gate3-matrix: SIGINT; stopping and restoring" >&2; exit 130' INT
trap 'echo "gate3-matrix: SIGTERM; stopping and restoring" >&2; exit 143' TERM

printf '%s run %s: RUN=%s RECEIVER=%s SUB=%s REPS=%s knobs: %s\n' \
	"$(date -u +%FT%TZ)" "$RUN_ID" "$RUN" "$RECEIVER" "${SUB:-none}" "$REPS" "$KNOB_LABEL" | tee -a "$CONTROL_FILE"
reset_all pre-run

# --- the receiver's environment for this row ----------------------------------
# Every variable this row changes is read off the Deployment and written down
# before anything changes, so what to put back survives a script that is killed,
# and all of them are set in one `set env` so one rollout carries them.
ENV_SET_ARGS=""
ENV_SET_SAYS=""
add_env_change() { # $1 = name, $2 = new value ("-" means unset it)
	local name="$1" value="$2" pre
	pre="$(receiver_env "$name")"
	printf '%s pre-run %s on deployment/%s: %s\n' "$(date -u +%FT%TZ)" "$name" "$RECEIVER_DEPLOY" "${pre:-<unset>}" | tee -a "$KNOBS_FILE"
	if [ "$value" = "-" ]; then
		ENV_SET_ARGS="${ENV_SET_ARGS} ${name}-"
		ENV_SET_SAYS="${ENV_SET_SAYS} ${name}=<unset>"
	else
		ENV_SET_ARGS="${ENV_SET_ARGS} ${name}=${value}"
		ENV_SET_SAYS="${ENV_SET_SAYS} ${name}=${value}"
	fi
	if [ -z "$pre" ]; then
		ENV_UNDO_ARGS="${ENV_UNDO_ARGS} ${name}-"
		ENV_UNDO_SAYS="${ENV_UNDO_SAYS} ${name}=<unset>"
	else
		ENV_UNDO_ARGS="${ENV_UNDO_ARGS} ${name}=${pre}"
		ENV_UNDO_SAYS="${ENV_UNDO_SAYS} ${name}=${pre}"
	fi
}

# The Python receiver runs in model mode for its rows: it is the receiver under
# test, so it must answer the message itself rather than forward it. The deployed
# value is forward mode (step 2b), so it is unset for the run and put back after.
if [ "$RECEIVER" = "py" ]; then
	add_env_change DOWNSTREAM_A2A_URL -
fi
if [ -n "$MODEL_KNOB_VALUE" ]; then
	add_env_change "$MODEL_KNOB" "$MODEL_KNOB_VALUE"
fi

if [ -n "$ENV_SET_ARGS" ]; then
	printf '%s setting deployment/%s:%s; if this script dies without restoring them, put them back with: kubectl -n %s set env deployment/%s%s\n' \
		"$(date -u +%FT%TZ)" "$RECEIVER_DEPLOY" "$ENV_SET_SAYS" "$NAMESPACE" "$RECEIVER_DEPLOY" "$ENV_UNDO_ARGS" | tee -a "$KNOBS_FILE"
	# RESTORE_ENV is set before the change, not after it: a `set env` that
	# applied and then failed to roll out still has to be put back.
	RESTORE_ENV="yes"
	# shellcheck disable=SC2086 # each element is one NAME=value or NAME- argument
	kubectl -n "$NAMESPACE" set env "deployment/${RECEIVER_DEPLOY}" $ENV_SET_ARGS >/dev/null
	kubectl -n "$NAMESPACE" rollout status "deployment/${RECEIVER_DEPLOY}" --timeout=180s >/dev/null
	live_model="$(receiver_env "$MODEL_KNOB")"
	live_downstream="$(receiver_env DOWNSTREAM_A2A_URL)"
	printf '%s live after the rollout: %s=%s DOWNSTREAM_A2A_URL=%s\n' "$(date -u +%FT%TZ)" \
		"$MODEL_KNOB" "${live_model:-<unset>}" "${live_downstream:-<unset>}" | tee -a "$KNOBS_FILE"
	# The Python receiver has to be in model mode for its rows, so the live
	# object is checked rather than the command's exit status.
	if [ "$RECEIVER" = "py" ] && [ -n "$live_downstream" ]; then
		echo "gate3-matrix: deployment/orchestrator still carries DOWNSTREAM_A2A_URL=${live_downstream} after the rollout, so it is in forward mode and is not the receiver under test" >&2
		exit 1
	fi
fi

# --- the route stanza for this row --------------------------------------------
if [ -n "$ROUTE" ]; then
	echo "== switching the retry stanza on for the ${ROUTE} route =="
	# Set before the apply, not after it: an apply that changed one route and
	# then failed still has to be put back.
	RESTORE_ROUTE="yes"
	make --no-print-directory retry-on "ROUTE=${ROUTE}" "OUT=${RUN_DIR}" | tee -a "$CONTROL_FILE"
	ON=$(stanzas_total)
	# The per-route read is the one that matters, and it is why the cluster-wide
	# count is not enough on its own: a stanza that landed on some other route
	# would satisfy a cluster-wide total and leave this row measuring a hop its
	# stimulus never crosses. Both are asserted, so the stanza has to be on the
	# routes this ROUTE names and nowhere else. Read back from the API server, so
	# it is the live object that is checked rather than the manifest.
	ON_SCOPED=0
	for route in $(routes_for "$ROUTE"); do
		n=$(stanzas_on_route "$route")
		ON_SCOPED=$((ON_SCOPED + n))
		printf '%s retry stanzas on %s: %s\n' "$(date -u +%FT%TZ)" "$route" "$n" | tee -a "$KNOBS_FILE" "$CONTROL_FILE" >/dev/null
		echo "retry stanzas on ${route}: ${n}"
		if [ "$n" -lt 1 ]; then
			echo "gate3-matrix: after 'make retry-on ROUTE=${ROUTE}' the route ${route} carries no retry stanza; nothing will be sent" >&2
			exit 1
		fi
	done
	printf '%s retry stanzas with ROUTE=%s on: %s on the %s routes and %s across every HTTPRoute (expected %s each)\n' \
		"$(date -u +%FT%TZ)" "$ROUTE" "$ON_SCOPED" "$ROUTE" "$ON" "$EXPECTED_STANZAS" | tee -a "$KNOBS_FILE" "$CONTROL_FILE" >/dev/null
	echo "retry stanzas with ROUTE=${ROUTE} on: ${ON_SCOPED} on the ${ROUTE} routes, ${ON} cluster-wide (expected ${EXPECTED_STANZAS} each)"
	if [ "$ON_SCOPED" != "$EXPECTED_STANZAS" ] || [ "$ON" != "$EXPECTED_STANZAS" ]; then
		echo "gate3-matrix: after 'make retry-on ROUTE=${ROUTE}' the ${ROUTE} routes carry ${ON_SCOPED} retry stanza(s) and the cluster carries ${ON}, expected ${EXPECTED_STANZAS} each; nothing will be sent" >&2
		exit 1
	fi
fi

# --- the out-of-cluster stimulus, for SUB=ingress -----------------------------
if [ "$STIMULUS" = "curl-through-the-ingress" ]; then
	if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${INGRESS_PORT}/" 2>/dev/null; then
		echo "gate3-matrix: something already answers on 127.0.0.1:${INGRESS_PORT}; refusing to send through a listener this run did not start" >&2
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
		echo "gate3-matrix: port-forward to svc/agentgateway-ingress did not come up" >&2
		exit 1
	}
	echo "== the ingress is reachable on 127.0.0.1:${INGRESS_PORT} =="
fi

# --- counting -----------------------------------------------------------------
# The summary's five ledger columns. The identity of the two arrivals, and
# everything the trace says, is computed by experiments/lib/derive-layer.sh and
# written into the work item's attribution.txt, so there is one implementation of
# those rules and `make test` exercises it against committed fixtures.
jqs() { jq -r -s "$@"; }

write_header() {
	if [ ! -s "$SUMMARY" ]; then
		echo "receiver,run,sub,work_item,deliveries,dispatched,distinct_messageIds,tasks,invocations,client_result,trace_spans,spans_by_service,second_delivery_layer,notes" >"$SUMMARY"
	fi
}

# send_loadgen_job runs the in-cluster load client, whose pod is ztunnel-captured,
# so the request reaches the receiver through that receiver's own waypoint (and,
# for the Python receiver, through the ingress its agent card advertises).
send_loadgen_job() { # $1 = work item, $2 = repetition directory
	local lwi="$1" d="$2" rc=0
	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${RECEIVER_URL}#g" \
		-e "s/\${CLIENT_RETRIES}/${JOB_RETRIES}/g" -e "s/\${CLIENT_SDK_RESEND}/${JOB_SDK_RESEND}/g" \
		-e "s/\${CLIENT_RETRY_ON}/${JOB_RETRY_ON}/g" \
		"$JOB_TEMPLATE" \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >"${d}/apply.log" 2>&1 || rc=$?
	[ "$rc" = "0" ] || return "$rc"
	# A Job that exits non-zero is an expected outcome here: the injected failure
	# is what these rows are about, and a layer that does not retry leaves the
	# client with the failure. `kubectl wait` takes one condition, so both are
	# polled together rather than waiting out a timeout on the first.
	local waited=0 conds=""
	while [ "$waited" -lt 180 ]; do
		conds=$(kubectl -n "$NAMESPACE" get "job/loadgen-${lwi}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
		case " $conds " in
		*" Complete "*) return 0 ;;
		*" Failed "*) return 4 ;;
		esac
		sleep 2
		waited=$((waited + 2))
	done
	echo "gate3-matrix: job loadgen-${lwi} reached neither complete nor failed in ${waited}s" >&2
	return 1
}

# send_through_ingress makes one out-of-cluster POST through the agentgateway
# ingress, addressed to the receiver by the hostname its route matches on. This
# is the same sender the gateway retry mechanics script used, and for the same
# reason: the load client resolves the agent card and then sends to the
# in-cluster address the card advertises, which no host-side process can reach.
# One POST of one body is what this row needs, and curl sends exactly that. No
# --retry is passed, so curl re-sends nothing; any second arrival is the
# gateway's. The body is the shape internal/a2areq builds, with a fresh JSON-RPC
# id and messageId per repetition, and it carries the identity headers and
# A2A-Version: 1.0. The client line this writes is the one `make ledgers` then
# keeps, since there is no Job to read a pod log from.
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
	# The Host header decides which ingress route matches: the worker has its own
	# hostname and the orchestrator answers the catch-all, which matches any
	# Host, so the orchestrator is addressed by a name of its own rather than by
	# the port-forward's 127.0.0.1, and the two receivers are never confused.
	local code host="${INGRESS_HOST:-orchestrator.lab.internal}"
	code=$(curl -s --max-time 120 -o "${d}/response.json" -w '%{http_code}' \
		-X POST \
		-H 'Content-Type: application/json' \
		-H 'A2A-Version: 1.0' \
		-H "Host: ${host}" \
		-H "X-Logical-Work-Item-Id: ${lwi}" \
		-H 'X-Caller: matrix' \
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
    # {"result": {"task": {...}}} or {"result": {"message": {...}}}; the
    # unwrapped shapes are read too so this line does not depend on that
    # staying true.
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

# --- one repetition -----------------------------------------------------------
one_rep() { # $1 = work item id, $2 = summary file to append to (empty for none)
	local lwi="$1" out_summary="$2"
	local d="${RUN_DIR}/${lwi}"
	local notes="" rc=0
	mkdir -p "$d"
	echo "== ${RUN}${SUB:+/$SUB} ${RECEIVER}: logical_work_item_id=${lwi} =="

	# Both injectors are reset before every repetition, so a count-keyed arming
	# starts from zero and nothing an earlier repetition armed can fire into this
	# work item.
	reset_all before-repetition

	local arm_code arm_body
	if [ -n "$RECEIVER_INJECT" ]; then
		arm_body="{\"mode\":\"${RECEIVER_INJECT}\",\"lwi\":\"${lwi}\"}"
		arm_code=$(post_json "${RECEIVER_URL}/control/inject" "$arm_body")
		printf '%s POST %s/control/inject %s -> %s\n' "$(date -u +%FT%TZ)" "$RECEIVER_URL" "$arm_body" "$arm_code" >>"$CONTROL_FILE"
		ok2xx "$arm_code" || {
			echo "gate3-matrix: arming ${RECEIVER_URL} with ${arm_body} returned ${arm_code}" >&2
			exit 1
		}
	fi
	if [ -n "$MOCK_INJECT_TEMPLATE" ]; then
		arm_body="${MOCK_INJECT_TEMPLATE//__LWI__/$lwi}"
		arm_code=$(post_json "${MOCK_URL}/control/inject" "$arm_body")
		printf '%s POST %s/control/inject %s -> %s\n' "$(date -u +%FT%TZ)" "$MOCK_URL" "$arm_body" "$arm_code" >>"$CONTROL_FILE"
		ok2xx "$arm_code" || {
			echo "gate3-matrix: arming ${MOCK_URL} with ${arm_body} returned ${arm_code}" >&2
			exit 1
		}
	fi

	if [ "$STIMULUS" = "curl-through-the-ingress" ]; then
		send_through_ingress "$lwi" "$d" || rc=$?
	else
		send_loadgen_job "$lwi" "$d" || rc=$?
	fi
	case "$rc" in
	0) ;;
	4) notes="${notes}job_failed;" ;;
	*) notes="${notes}stimulus_rc=${rc};" ;;
	esac

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
	local post_reset pair name url
	for pair in "receiver=${RECEIVER_URL}" "mock=${MOCK_URL}"; do
		name="${pair%%=*}"
		url="${pair#*=}"
		post_reset=$(post "${url}/control/reset")
		printf '%s POST %s/control/reset -> %s (after %s)\n' "$(date -u +%FT%TZ)" "$url" "$post_reset" "$lwi" >>"$CONTROL_FILE"
		ok2xx "$post_reset" || notes="${notes}post_reset_${name}=${post_reset};"
	done

	# The trace is exported inside the run: the batch span processors flush on a
	# timer and the trace backend stores in memory. Its status is recorded rather
	# than swallowed, the way the ledger collection's is: `make export-trace`
	# exits non-zero both when the query failed and when no span matched, and
	# `make` collapses either onto 2, so the status and the row count are both
	# kept and the row says which it was. trace_spans is `n-a` when no spans.csv
	# was written at all, which is not the same as a file that matched no span.
	sleep "$TRACE_WAIT"
	local etrc=0
	make --no-print-directory export-trace "LWI=${lwi}" "OUT=${d}" >>"${d}/collect.log" 2>&1 || etrc=$?
	[ "$etrc" = "0" ] || notes="${notes}export_trace_rc=${etrc};"
	local trace_spans="n-a"
	if [ -s "${d}/spans.csv" ]; then trace_spans=$(($(grep -c '' "${d}/spans.csv") - 1)); fi

	# --- the counts, by the Gate 2/3 counting rules ---------------------------
	local deliveries dispatched distinct_msgids tasks invocations
	deliveries=$(jqs --arg src "$RECEIVER_SOURCE" '[.[] | select(.source == $src and .phase == "arrival" and .method == "SendMessage")] | length' "${d}/ingress.jsonl")
	dispatched=$(jqs --arg src "$RECEIVER_SOURCE" '[.[] | select(.source == $src and .event == "execute")] | length' "${d}/execution.jsonl")
	distinct_msgids=$(jqs --arg src "$RECEIVER_SOURCE" '[.[] | select(.source == $src and .phase == "arrival" and .method == "SendMessage") | .messageId // ""] | unique | map(select(. != "")) | length' "${d}/ingress.jsonl")
	tasks=$(jqs --arg src "$RECEIVER_SOURCE" '[.[] | select(.source == $src and .event == "state") | .taskId // ""] | unique | map(select(. != "")) | length' "${d}/execution.jsonl")
	# a stale-closed line records a connection close, not a call
	invocations=$(jqs '[.[] | select(.outcome != "stale-closed")] | length' "${d}/invocation.jsonl")

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

	# --- the layer that made any second delivery ------------------------------
	# Derived by experiments/lib/derive-layer.sh, which reads this repetition's
	# ledgers and trace and knows nothing about which knob this row switched on,
	# so a row cannot be labelled by what it was expected to do. Its whole output
	# is the work item's attribution.txt; the caller reads two lines of it.
	local attribution layer reason spans_by_service
	attribution=$(experiments/lib/derive-layer.sh "$d" "$RECEIVER_SOURCE" 2>>"${d}/collect.log") || {
		echo "gate3-matrix: derive-layer.sh failed for ${lwi}; see ${d}/collect.log" >&2
		exit 1
	}
	printf '%s\n' "$attribution" >"${d}/attribution.txt"
	layer=$(printf '%s\n' "$attribution" | sed -n 's/^layer=//p')
	reason=$(printf '%s\n' "$attribution" | sed -n 's/^reason=//p')
	spans_by_service=$(printf '%s\n' "$attribution" | sed -n 's/^spans by service: //p')
	[ -n "$spans_by_service" ] || spans_by_service="none"
	case "$layer" in
	none) ;;
	*) notes="${notes}layer_reason=${reason};" ;;
	esac
	[ -z "$INJECT_NOTE" ] || notes="${notes}injection=${RECEIVER_INJECT:-none};"

	local row="${RECEIVER},${RUN},${SUB:-none},${lwi},${deliveries},${dispatched},${distinct_msgids},${tasks},${invocations},${client_result},${trace_spans},${spans_by_service},${layer},${notes}"
	echo "  $row"
	[ -z "$out_summary" ] || printf '%s\n' "$row" >>"$out_summary"
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
echo "== ${RUN}${SUB:+/$SUB} ${RECEIVER}: ${REPS} repetitions =="
for i in $(seq 1 "$REPS"); do
	one_rep "$(work_item "$(printf '%02d' "$i")")" "$SUMMARY"
done

echo "== summary =="
cat "$SUMMARY"
