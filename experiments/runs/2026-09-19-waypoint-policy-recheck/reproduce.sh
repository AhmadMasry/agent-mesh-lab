#!/usr/bin/env bash
# reproduce.sh — the 2026-09-19 re-check as one script.
#
# Question: does the AgentgatewayPolicy of agentgateway's Kubernetes tracing page
#   https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/traces/configs/otel/
# reach an agentgateway waypoint that istiod manages (GatewayClass
# istio-agentgateway-waypoint)? And is this lab's own tracing route for those waypoints
# (the parametersRef overlay, the Istio Telemetry objects) what stands in its way?
#
# Repetition 1 was run by hand on 2026-09-19T08:45Z-08:53Z; its records are the numbered
# directories beside this file. This script is that sequence, and it writes under rep-2/
# (REP=<name> for another). It refuses to write into a directory that exists: a record is
# not overwritten.
#
# Sequence, on lab/agentgateway-waypoint (the worker's waypoint) only:
#   0  preflight, nothing changed: tools, certificate check, and the cluster must be in the
#      lab's standard state, because that captured state is what the restore is read against
#   1  lift the parametersRef overlay -> args ["--config","{}"]; dump
#   2  apply 2-doc-policy/policy.yaml (the page's manifest, names changed only); status;
#      SETTLE seconds; dumps of the waypoint and of the ingress (positive control, class
#      agentgateway); the agentgateway controller's push lines; one traced work item;
#      the waypoint's dump again after that traffic
#   3  nothing custom: the policy deleted, the lab's three Telemetry objects deleted, a new
#      waypoint pod; dump; the policy re-created; status; SETTLE; dump; one traced work
#      item; dump again
#   4  restore: policy deleted, deploy/step-3-stress/istio-tracing.yaml applied by file,
#      the parametersRef put back; dump; one traced work item per receiver; readback with
#      a PASS/FAIL line per check. The script exits 1 if any check reads FAIL.
#
# The restore also runs from the EXIT trap if the script stops anywhere after step 0, so a
# failure in the middle still ends in the standard state. It is the same function, run once.
#
# No retry anywhere. Each HTTP read of /config_dump is one `curl --retry 0`. Every wait
# reads an object and sends nothing: a Deployment's args and rollout status, a Gateway's
# pods, the policy's status conditions, and kubectl's own "Forwarding from" line for the
# port-forward. SETTLE is a fixed sleep, not a poll: there is nothing to poll for a delivery
# that may never come, so the delay is fixed and written into the record with both stamps.
# The traced work items are sent by experiments/gate3-trace-per-work-item.sh, unchanged:
# one Job per work item, backoffLimit 0, one send.
#
# The policy's status is waited for only until its conditions EXIST, whatever they read.
#
# /config_dump files are about 46 KB; they are written as *.config-dump.json, which this
# directory's .gitignore leaves out, and extract-config-dump.py writes the committed
# *.extract.json (policies, config.tracing, config.xds) beside each.
#
# bash 3.2 (the host's). Stamps from `date -u`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

RUN_NAME="2026-09-19-waypoint-policy-recheck"
RUN="experiments/runs/${RUN_NAME}"
REP="${REP:-rep-2}"
OUT="${RUN}/${REP}"
CTX="kind-agent-mesh-lab"
NS="lab"
GW="agentgateway-waypoint"
GW_ORCH="agentgateway-waypoint-orch"
INGRESS_NS="agentgateway-ingress"
INGRESS_GW="agentgateway-ingress"
CONTROLLER_NS="agentgateway-system"
CONTROLLER_DEPLOY="agentgateway"
POLICY_FILE="${RUN}/2-doc-policy/policy.yaml"
TELEMETRY_FILE="deploy/step-3-stress/istio-tracing.yaml"
PORT="${PORT:-15999}"
SETTLE="${SETTLE:-30}"
# Work-item ids must not repeat an earlier run's: pod logs outlive runs. Repetition 1 used
# rc0, rc2, rc3, rc4.
ID_PREFIX="${ID_PREFIX:-r2}"

PF_PID=""
STATE_BEFORE=""
CHANGED=0
RESTORED=0
FAILS=0

stamp() { date -u +%FT%TZ; }
K() { kubectl --context "$CTX" "$@"; }
log() { printf '%s %s\n' "$(stamp)" "$*" | tee -a "${OUT}/run.txt"; }

stop_pf() {
	if [ -n "$PF_PID" ]; then
		kill "$PF_PID" 2>/dev/null || true
		wait "$PF_PID" 2>/dev/null || true
		PF_PID=""
	fi
}

# The newest pod of a Gateway that is not terminating. Both control planes label the pods
# they provision with gateway.networking.k8s.io/gateway-name.
gateway_pod() { # $1 ns, $2 gateway
	K -n "$1" get pods -l "gateway.networking.k8s.io/gateway-name=$2" -o json | python3 -c '
import json, sys
pods = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
pods.sort(key=lambda p: p["metadata"]["creationTimestamp"])
print(pods[-1]["metadata"]["name"] if pods else "")'
}

# Reads the Gateway's pods until exactly one is left and it is Ready.
wait_single_pod() { # $1 ns, $2 gateway
	local i=0 state
	while :; do
		state="$(K -n "$1" get pods -l "gateway.networking.k8s.io/gateway-name=$2" -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
ready = [p for p in items if not p["metadata"].get("deletionTimestamp")
         and any(c["type"] == "Ready" and c["status"] == "True" for c in p.get("status", {}).get("conditions", []))]
print("one" if len(items) == 1 and len(ready) == 1 else "%d pods, %d ready" % (len(items), len(ready)))')"
		[ "$state" = "one" ] && return 0
		i=$((i + 1))
		if [ "$i" -gt 90 ]; then
			echo "wait_single_pod: ${1}/${2} still reads ${state} after 90 reads" >&2
			return 1
		fi
		sleep 1
	done
}

waypoint_args() { K -n "$NS" get deploy "$GW" -o jsonpath='{.spec.template.spec.containers[0].args}'; }

# Reads the Deployment until istiod has re-rendered it, then its rollout status.
wait_args() { # $1 = "empty" | "tracing"
	local i=0 args
	while :; do
		args="$(waypoint_args)"
		case "$1" in
			empty) [ "$args" = '["--config","{}"]' ] && break ;;
			tracing) case "$args" in *otlpEndpoint*) break ;; esac ;;
		esac
		i=$((i + 1))
		if [ "$i" -gt 120 ]; then
			echo "wait_args $1: args still read ${args} after 120 reads" >&2
			return 1
		fi
		sleep 1
	done
	K -n "$NS" rollout status "deploy/${GW}" --timeout=180s
	wait_single_pod "$NS" "$GW"
}

# One read of a proxy's admin /config_dump, through a port-forward to the pod by name.
dump() { # $1 ns, $2 gateway, $3 output base (no extension)
	local ns="$1" gw="$2" base="$3" pod pflog i=0
	pod="$(gateway_pod "$ns" "$gw")"
	if [ -z "$pod" ]; then
		echo "dump: no pod for ${ns}/${gw}" >&2
		return 1
	fi
	pflog="${base}.port-forward.tmp"
	# kubectl is started directly, not through K(): `K ... &` backgrounds a subshell, $! is
	# then the subshell's pid, and killing it leaves kubectl running and holding the port.
	# That is what ended the first attempt at repetition 2 (rep-2-aborted/ABORTED.txt).
	kubectl --context "$CTX" -n "$ns" port-forward "pod/${pod}" "${PORT}:15000" >"$pflog" 2>&1 &
	PF_PID=$!
	until grep -q "Forwarding from" "$pflog" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -gt 80 ] || ! kill -0 "$PF_PID" 2>/dev/null; then
			echo "dump: port-forward to ${ns}/${pod} did not come up: $(cat "$pflog" 2>/dev/null)" >&2
			stop_pf
			rm -f "$pflog"
			return 1
		fi
		sleep 0.25
	done
	{
		echo "$(stamp) ${ns}/${gw} pod=${pod} started=$(K -n "$ns" get pod "$pod" -o jsonpath='{.status.startTime}')"
		curl -sS --retry 0 --max-time 10 "http://127.0.0.1:${PORT}/config_dump" -o "${base}.config-dump.json"
		python3 "${RUN}/extract-config-dump.py" "${base}.config-dump.json" "${base}.extract.json"
	} >"${base}.txt"
	stop_pf
	rm -f "$pflog"
	cat "${base}.txt"
}

policy_status() {
	K -n "$NS" get agentgatewaypolicy tracing -o json | python3 -c '
import json, sys
obj = json.load(sys.stdin)
print("generation=%s created=%s" % (obj["metadata"].get("generation"), obj["metadata"].get("creationTimestamp")))
for anc in (obj.get("status") or {}).get("ancestors") or []:
    ref = anc.get("ancestorRef", {})
    print("controller=%s ancestor=%s/%s/%s" % (anc.get("controllerName"), ref.get("kind"), ref.get("namespace"), ref.get("name")))
    for c in anc.get("conditions") or []:
        print("  %s=%s reason=%s message=%s observedGeneration=%s lastTransitionTime=%s" % (
            c.get("type"), c.get("status"), c.get("reason"), c.get("message"), c.get("observedGeneration"), c.get("lastTransitionTime")))'
}

# Reads the policy until a controller has written conditions, whatever they say.
wait_policy_conditions() {
	local i=0 n
	while :; do
		n="$(K -n "$NS" get agentgatewaypolicy tracing -o json | python3 -c '
import json, sys
anc = (json.load(sys.stdin).get("status") or {}).get("ancestors") or []
print(sum(len(a.get("conditions") or []) for a in anc))')"
		[ "$n" -ge 2 ] && return 0
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			echo "NO CONDITIONS after 60 reads: no controller wrote a status on lab/tracing"
			return 0
		fi
		sleep 1
	done
}

apply_policy_and_read() { # $1 output dir
	local dir="$1" t_apply t_status
	t_apply="$(stamp)"
	{
		echo "$t_apply apply ${POLICY_FILE} sha256=$(shasum -a 256 "$POLICY_FILE" | cut -d' ' -f1)"
		K apply -f "$POLICY_FILE"
	} >"${dir}/apply.txt" 2>&1
	cat "${dir}/apply.txt"
	wait_policy_conditions | tee -a "${dir}/apply.txt"
	t_status="$(stamp)"
	{
		echo "$t_status"
		K get agentgatewaypolicy -A
		echo
		policy_status
	} >"${dir}/status.txt" 2>&1
	cat "${dir}/status.txt"
	log "settle ${SETTLE} s after the status read of ${t_status} (fixed sleep; nothing to poll)"
	sleep "$SETTLE"
}

controller_log_extract() { # $1 since-time, $2 output file
	{
		echo "# ${CONTROLLER_NS}/deploy/${CONTROLLER_DEPLOY} log since $1, read $(stamp): the lines naming a push (msg \"push debounce stable\") whose cause names ${NS}/"
		K -n "$CONTROLLER_NS" logs "deploy/${CONTROLLER_DEPLOY}" --since-time="$1" 2>/dev/null \
			| grep -F '"push debounce stable"' | grep -F "${NS}/" || echo "(no such line)"
	} >"$2"
	cat "$2"
}

trace() { # $1 variant dir, $2 run id, $3 receivers
	local dir="$1" id="$2" receivers="$3" rc=0
	mkdir -p "${OUT}/${dir}/trace"
	log "traced work item(s): RUN_ID=${id} RECEIVERS=${receivers}"
	REPS=1 RECEIVERS="$receivers" RUN_ID="$id" RUN_ITEM="${RUN_NAME}/${REP}/${dir}/trace" \
		bash experiments/gate3-trace-per-work-item.sh \
		>"${OUT}/${dir}/trace-stdout.txt" 2>"${OUT}/${dir}/trace-stderr.txt" || rc=$?
	if [ "$rc" -ne 0 ]; then
		log "trace script exited ${rc}; stderr tail: $(tail -3 "${OUT}/${dir}/trace-stderr.txt" | tr '\n' ' ')"
		return "$rc"
	fi
	cat "${OUT}/${dir}/trace/summary.csv" | tee -a "${OUT}/run.txt"
	python3 "${RUN}/dangling-parents.py" "${OUT}/${dir}/trace"/*/spans.csv | tee "${OUT}/${dir}/dangling-parents.csv" | tee -a "${OUT}/run.txt"
}

state() { # the four things the restore is read against
	echo "# $(stamp)"
	K get gateway -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.gatewayClassName,PARAMS:.spec.infrastructure.parametersRef.name,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status'
	K get telemetry -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name'
	K get agentgatewaypolicy -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ACCEPTED:.status.ancestors[0].conditions[?(@.type=="Accepted")].status,ATTACHED:.status.ancestors[0].conditions[?(@.type=="Attached")].status'
	echo "args ${NS}/${GW}: $(waypoint_args)"
	echo "args ${NS}/${GW_ORCH}: $(K -n "$NS" get deploy "$GW_ORCH" -o jsonpath='{.spec.template.spec.containers[0].args}')"
}

# The comparable part of state(): no stamp.
state_key() { state | grep -v '^# '; }

restore() { # idempotent; run once, from the sequence or from the EXIT trap
	local dir="${OUT}/4-restored"
	mkdir -p "$dir"
	# Marked at the start: a restore that fails part-way is not run a second time by the
	# trap. The trap then prints the state it finds, and a human takes it from there.
	RESTORED=1
	{
		stamp
		echo "# restore: remove the test policy, re-apply the lab's Telemetry objects by file, put the parametersRef overlay back"
		K -n "$NS" delete agentgatewaypolicy tracing --ignore-not-found
		K apply -f "$TELEMETRY_FILE"
		K -n "$NS" patch gateway "$GW" --type merge \
			-p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"waypoint-tracing-config"}}}}'
		wait_args tracing
		stamp
	} >>"${dir}/restore.txt" 2>&1
	cat "${dir}/restore.txt"
}

on_exit() {
	local rc=$?
	stop_pf
	if [ "$CHANGED" -eq 1 ] && [ "$rc" -ne 0 ]; then
		if [ "$RESTORED" -eq 0 ]; then
			log "EXIT with rc=${rc} before the restore: restoring from the trap"
			restore || true
		else
			log "EXIT with rc=${rc} during or after the restore: not run again"
		fi
		mkdir -p "${OUT}/4-restored"
		state | tee "${OUT}/4-restored/state-at-exit.txt"
		if [ "$(state_key)" = "$STATE_BEFORE" ]; then
			log "state at exit EQUALS the state captured at preflight"
		else
			log "state at exit DIFFERS from the state captured at preflight: the lab is NOT in its standard state"
		fi
	fi
	exit "$rc"
}

check() { # $1 description, $2 actual, $3 wanted
	if [ "$2" = "$3" ]; then
		echo "PASS  $1: $2"
	else
		echo "FAIL  $1: read \"$2\", wanted \"$3\""
		FAILS=$((FAILS + 1))
	fi
}

# ---------------------------------------------------------------- 0 preflight, nothing changed
if [ -e "$OUT" ]; then
	echo "${OUT} exists; a record is not overwritten. Use REP=<name> for another repetition." >&2
	exit 2
fi
for tool in kubectl istioctl ko go curl python3 make shasum lsof; do
	command -v "$tool" >/dev/null || { echo "missing tool: ${tool}" >&2; exit 2; }
done
# Every dump binds this local port; if something holds it, stop before anything is changed.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	echo "local port ${PORT} is in use; nothing was changed. Free it or set PORT=<n>." >&2
	exit 2
fi
[ -f "$POLICY_FILE" ] || { echo "missing ${POLICY_FILE}" >&2; exit 2; }
mkdir -p "${OUT}/0-before"
trap on_exit EXIT

T_START="$(stamp)"
{
	echo "== ${T_START} | reproduce.sh | REP=${REP} | SETTLE=${SETTLE} | ID_PREFIX=${ID_PREFIX} =="
	echo "branch=$(git rev-parse --abbrev-ref HEAD) head=$(git rev-parse HEAD)"
	echo "git status --short (the load client is built by ko from this tree; anything listed here makes Go stamp vcs.modified=true):"
	git status --short | sed 's/^/  /'
	echo "git diff --stat HEAD -- agents fixtures internal go.mod go.sum (the sources the images are built from):"
	git diff --stat HEAD -- agents fixtures internal go.mod go.sum | sed 's/^/  /'
	echo "  (end)"
	echo "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
	echo "istioctl: $(istioctl version --remote=false 2>/dev/null | head -1)"
	echo "ko: $(ko version 2>/dev/null | head -1)"
	echo "go: $(go version | sed 's/^go version //')"
	echo "curl: $(curl --version | head -1 | cut -d' ' -f1-2), every read with --retry 0"
	echo "policy file: ${POLICY_FILE} sha256=$(shasum -a 256 "$POLICY_FILE" | cut -d' ' -f1)"
} >"${OUT}/run.txt"
cat "${OUT}/run.txt"

log "0 preflight"
{
	stamp
	K get gatewayclass -o 'custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status'
	echo
	K -n "$CONTROLLER_NS" get deploy -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'
	K -n "$NS" get deploy "$GW" "$GW_ORCH" -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'
	K -n istio-system get deploy istiod -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'
	echo
	state
} >"${OUT}/0-before/state.txt" 2>&1
cat "${OUT}/0-before/state.txt"
STATE_BEFORE="$(state_key)"

# The restore's target is the standard state, so the start must already be it.
start_ok=1
[ "$(K -n "$NS" get gateway "$GW" -o jsonpath='{.spec.infrastructure.parametersRef.name}')" = "waypoint-tracing-config" ] || start_ok=0
[ "$(K -n "$NS" get gateway "$GW_ORCH" -o jsonpath='{.spec.infrastructure.parametersRef.name}')" = "waypoint-orch-tracing-config" ] || start_ok=0
[ "$(K get telemetry -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "3" ] || start_ok=0
[ -z "$(K -n "$NS" get agentgatewaypolicy --no-headers 2>/dev/null)" ] || start_ok=0
if [ "$start_ok" -ne 1 ]; then
	log "the cluster is not in the lab's standard state; nothing was changed. Stop."
	exit 3
fi

CERTS="$(istioctl --context "$CTX" ztunnel-config certificates --node agent-mesh-lab-worker)"
printf '%s\n%s\n' "$(stamp)" "$CERTS" >"${OUT}/0-before/certificates.txt"
if ! printf '%s\n' "$CERTS" | awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' | grep -qx true; then
	log "certificate check: VALID CERT is not true for ns/lab/sa/default; nothing was changed. Stop."
	exit 3
fi
log "preflight done: standard state, VALID CERT true"

# ---------------------------------------------------------------- 1 lift
log "1 lift the parametersRef overlay from ${NS}/${GW}"
D="${OUT}/1-workaround-lifted"
mkdir -p "$D"
CHANGED=1
{
	stamp
	echo "# lift the parametersRef overlay from ${NS}/${GW} (the worker's istiod-managed waypoint)"
	K -n "$NS" patch gateway "$GW" --type json -p '[{"op":"remove","path":"/spec/infrastructure/parametersRef"}]'
	wait_args empty
	echo "args now: $(waypoint_args)"
	echo "gateway spec.infrastructure: $(K -n "$NS" get gateway "$GW" -o jsonpath='{.spec.infrastructure}')"
	echo "gateway conditions: $(K -n "$NS" get gateway "$GW" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')"
	stamp
} >"${D}/lift.txt" 2>&1
cat "${D}/lift.txt"
dump "$NS" "$GW" "${D}/waypoint"

# ---------------------------------------------------------------- 2 the page's policy
log "2 apply the page's policy to ${NS}/${GW}"
D="${OUT}/2-doc-policy"
mkdir -p "$D"
T_V2="$(stamp)"
apply_policy_and_read "$D"
dump "$NS" "$GW" "${D}/waypoint"
dump "$INGRESS_NS" "$INGRESS_GW" "${D}/ingress"
controller_log_extract "$T_V2" "${D}/controller-log-extract.txt"
trace "2-doc-policy" "${ID_PREFIX}v2" "worker"
dump "$NS" "$GW" "${D}/waypoint.after-traffic"
{ stamp; policy_status; } >"${D}/status.after-traffic.txt" 2>&1
cat "${D}/status.after-traffic.txt"

# ---------------------------------------------------------------- 3 nothing custom
log "3 nothing custom around ${NS}/${GW}: the policy, the three Telemetry objects, the pod"
D="${OUT}/3-doc-policy-nothing-custom"
mkdir -p "$D"
T_V3="$(stamp)"
{
	stamp
	echo "# remove every custom piece around ${NS}/${GW}: the page's policy (re-created below), the three Istio Telemetry objects, then a new pod"
	K -n "$NS" delete agentgatewaypolicy tracing
	K delete -f "$TELEMETRY_FILE"
	echo "telemetry objects left: $(K get telemetry -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	K -n "$NS" rollout restart "deploy/${GW}"
	K -n "$NS" rollout status "deploy/${GW}" --timeout=180s
	wait_single_pod "$NS" "$GW"
	echo "args: $(waypoint_args)"
	echo "gateway annotations: $(K -n "$NS" get gateway "$GW" -o jsonpath='{.metadata.annotations}')"
	echo "gateway spec.infrastructure: $(K -n "$NS" get gateway "$GW" -o jsonpath='{.spec.infrastructure}')"
	K -n "$NS" get pods -l "gateway.networking.k8s.io/gateway-name=${GW}" -o 'custom-columns=POD:.metadata.name,START:.status.startTime,IMAGE:.spec.containers[0].image'
	stamp
} >"${D}/steps.txt" 2>&1
cat "${D}/steps.txt"
dump "$NS" "$GW" "${D}/waypoint.before"
apply_policy_and_read "$D"
dump "$NS" "$GW" "${D}/waypoint.after"
controller_log_extract "$T_V3" "${D}/controller-log-extract.txt"
trace "3-doc-policy-nothing-custom" "${ID_PREFIX}v3" "worker"
dump "$NS" "$GW" "${D}/waypoint.after-traffic"
{ stamp; policy_status; } >"${D}/status.after-traffic.txt" 2>&1
cat "${D}/status.after-traffic.txt"

# ---------------------------------------------------------------- 4 restore, read back
log "4 restore"
D="${OUT}/4-restored"
restore
dump "$NS" "$GW" "${D}/waypoint"
trace "4-restored" "${ID_PREFIX}v4" "worker orchestrator"

log "readback"
STATE_AFTER="$(state_key)"
{
	state
	echo
	echo "# checks"
	check "state equal to the one captured at preflight (Gateways' class, parametersRef and Programmed; Telemetry objects; policies and their status; both waypoints' args)" \
		"$([ "$STATE_AFTER" = "$STATE_BEFORE" ] && echo equal || echo differs)" "equal"
	check "${NS}/${GW} parametersRef" "$(K -n "$NS" get gateway "$GW" -o jsonpath='{.spec.infrastructure.parametersRef.name}')" "waypoint-tracing-config"
	check "${NS}/${GW_ORCH} parametersRef" "$(K -n "$NS" get gateway "$GW_ORCH" -o jsonpath='{.spec.infrastructure.parametersRef.name}')" "waypoint-orch-tracing-config"
	check "Telemetry objects" "$(K get telemetry -A --no-headers -o 'custom-columns=N:.metadata.namespace,M:.metadata.name' | sort | tr -s ' ' '/' | tr '\n' ' ' | sed 's/ $//')" \
		"istio-system/mesh-tracing lab/waypoint-orch-tracing lab/waypoint-tracing"
	check "AgentgatewayPolicy objects in ${NS}" "$(K -n "$NS" get agentgatewaypolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')" "0"
	check "AgentgatewayPolicy objects in the cluster" "$(K get agentgatewaypolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" "4"
	check "the waypoint's dump holds a policy of key frontend/tracing" \
		"$(python3 -c 'import json,sys; print(sum(1 for p in json.load(open(sys.argv[1]))["policies"] if p.get("key") == "frontend/tracing"))' "${D}/waypoint.extract.json")" "1"
	for row in $(tail -n +2 "${D}/trace/summary.csv" | cut -d, -f1,4,6); do
		check "hops without a span, ${row%%,*} (spans $(echo "$row" | cut -d, -f2))" "$(echo "$row" | cut -d, -f3)" "none"
	done
	check "traced work items after the restore" "$(tail -n +2 "${D}/trace/summary.csv" | wc -l | tr -d ' ')" "2"
	echo
	echo "FAILS=${FAILS}"
} >"${D}/readback.txt" 2>&1
cat "${D}/readback.txt"
if [ "$STATE_AFTER" != "$STATE_BEFORE" ]; then
	diff <(printf '%s\n' "$STATE_BEFORE") <(printf '%s\n' "$STATE_AFTER") >"${D}/state-diff.txt" || true
	cat "${D}/state-diff.txt"
fi

log "done: started ${T_START}, FAILS=${FAILS}"
[ "$FAILS" -eq 0 ]
