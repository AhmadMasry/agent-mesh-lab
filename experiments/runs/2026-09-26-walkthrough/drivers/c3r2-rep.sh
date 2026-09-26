#!/usr/bin/env bash
# C-3R2 driver, kept in the run directory: ONE repetition of the draft's reproduction
# (docs/upstream/ztunnel-policy-watcher-selector-scoped-policy.md, "Reproduction", steps
# 1-6) for ONE policy, in the throwaway namespace `repro` the draft's YAML creates
# (objects/setup.yaml), with the pinned public server (versions.yaml c3r2-public-server)
# in place of the draft's placeholder. The shape is C-3R's rep.sh
# (experiments/runs/2026-09-21-c3r-open-connections/rep.sh); what differs is the draft's
# own names, commands and request, and the server's record: nginx's access log, read with
# `kubectl logs --timestamps`, in place of the worker's ingress ledger.
#
#   rep.sh <scope> <n>     scope = selector (the draft's policy B) | namespace (policy A) | none
#
# One repetition, in this order, every reading through rec.sh (stamp, command, output):
#   1. (draft step 1) open ONE TCP connection from the client pod to the server pod --
#      busybox `nc` in the client, fed through `kubectl exec -i` from a FIFO this script
#      holds open, so each request is written exactly once, when this script writes it,
#      on that one connection -- and send the draft's request on it:
#      printf 'GET %s HTTP/1.1\r\nHost: server\r\n\r\n' "$REQ_PATH", REQ_PATH=/?rep=<scope>-<n>;
#   2. read the connection's identity: the client's own socket (netstat in the pod),
#      ztunnel's own record (`istioctl ztunnel-config connections`), and the server's
#      record of the request (nginx's access line);
#   3. (draft step 2) `kubectl apply` the policy (objects/policy-<scope>.yaml), then WAIT ON
#      ZTUNNEL'S OWN STATE with the draft's two commands: until `istioctl ztunnel-config
#      policy` holds the policy and, for policy B, until `istioctl ztunnel-config workloads`
#      lists it on the server -- a condition read, not a timer;
#   4. (draft step 3) read ztunnel's log for `no longer allowed after a policy update`, and
#      the policy's status, ztunnel's copy of it, the server's policy list, the tracked
#      connections and the client's socket;
#   5. (draft step 4) send the same request again on THE SAME connection, if it is still
#      open, and record what came back -- or that the connection had closed before it;
#   6. (draft step 5) open a NEW connection with the draft's command, one
#      `curl -sS --retry 0`, the control that the policy is in force for new connections;
#   7. read the server's access log, the tracked connections and ztunnel's log again;
#   8. (draft step 6) close the held connection (`exec 3>&-`, EOF on nc's input), then
#      delete the policy and wait on ztunnel's state until it no longer holds it; read back
#      0 AuthorizationPolicy;
#   9. read istiod's log from the apply (the push debounce and the WDS/WADS push sizes).
# scope `none` runs the same steps with no policy: the control that a request on the
# held connection is delivered when nothing changes.
#
# No retry logic: nc sends what it is given once and has no retry; the new connection is
# one curl with --retry 0; nothing here re-sends anything. Event stamps are the host's
# clock to the millisecond (GNU date); ztunnel's, istiod's and kubectl's --timestamps
# stamps are the cluster's clock.
set -uo pipefail

SCOPE="${1:?scope}" N="${2:?n}"
case "$SCOPE" in selector | namespace | none) ;; *) echo "scope=${SCOPE} is not selector, namespace or none" >&2 && exit 1 ;; esac
cd "$(git rev-parse --show-toplevel)"
R="experiments/runs/2026-09-26-walkthrough/c3r2"
D="${R}/${SCOPE}-${N}"
if [ -e "$D" ]; then echo "${D} exists; a repetition is never re-run into the same directory" >&2 && exit 1; fi
mkdir -p "$D"
NS="repro"
NODE="agent-mesh-lab-worker"
REC="${R}/rec.sh"
RD="${D}/readings.txt"
POLICY="repro-${SCOPE}"
PFILE="${R}/objects/policy-${SCOPE}.yaml"
REQ_PATH="/?rep=${SCOPE}-${N}"
SCR="$(mktemp -d)"

ts() { gdate -u +%FT%T.%3NZ; }
ev() { printf '%s %s\n' "$(ts)" "$*" | tee -a "${D}/events.txt"; }
nresp() { python3 "${R}/responses.py" "${D}/nc-received.txt"; }
nc_alive() { [ ! -s "${D}/nc-exit.txt" ]; }
# wait_until <seconds> <condition>: evaluates the condition until it holds or the
# deadline passes; each evaluation is a read (a file, or ztunnel's admin state).
wait_until() {
	local deadline=$(($(date +%s) + $1))
	shift
	until eval "$*"; do
		[ "$(date +%s)" -ge "$deadline" ] && return 1
	done
	return 0
}
# the draft's step 2, its two commands with <node> and <policy name> filled in
zt_holds_policy() { istioctl ztunnel-config policy --node "$NODE" -o json 2>/dev/null | jq -e "any(.[]; .name == \"${POLICY}\")" >/dev/null; }
wl_lists_policy() { istioctl ztunnel-config workloads --node "$NODE" -o json 2>/dev/null | jq -e 'any(.[]; (.name | startswith("server")) and ((.authorizationPolicies // []) | index("repro/repro-selector")))' >/dev/null; }
# the draft's step 1 request, verbatim
req() { printf 'GET %s HTTP/1.1\r\nHost: server\r\n\r\n' "$REQ_PATH"; }

cleanup() {
	exec 3>&- 2>/dev/null || true
	rm -rf "$SCR"
}
trap cleanup EXIT

T0="$(date -u +%FT%TZ)"
ZT="$(kubectl -n istio-system get pod -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')"
ISTIOD="$(kubectl -n istio-system get pod -l app=istiod -o jsonpath='{.items[0].metadata.name}')"
SRV_POD="$(kubectl -n "$NS" get pod -l app=server -o jsonpath='{.items[0].metadata.name}')"
SERVER_POD_IP="$(kubectl -n "$NS" get pod "$SRV_POD" -o jsonpath='{.status.podIP}')"
SRV_RE="${SERVER_POD_IP//./\\.}"
ev "rep ${SCOPE}-${N} start T0=${T0} ztunnel=${ZT} istiod=${ISTIOD} server=${SRV_POD} ${SERVER_POD_IP}:8080 policy=$([ "$SCOPE" = none ] && echo none || echo "${POLICY}") REQ_PATH=${REQ_PATH}"

ZLOG="kubectl -n istio-system logs ${ZT} --since-time=${T0} | grep -E 'no longer allowed|policy change|policy rejection|RBAC|${SRV_RE}'"
WATCHER="kubectl -n istio-system logs ${ZT} --since-time=${T0} | grep 'no longer allowed after a policy update'"
CONNS="istioctl ztunnel-config connections --node ${NODE} -o json | jq -c '.[] | select(.info.namespace == \"repro\") | {pod: .info.name, inbound: .connections.inbound, outbound: .connections.outbound}'"
SLOG="kubectl -n ${NS} logs ${SRV_POD} --timestamps --since-time=${T0}"

# precondition: no AuthorizationPolicy anywhere
"$REC" "$RD" 'kubectl get authorizationpolicy -A'
if [ "$(kubectl get authorizationpolicy -A -o name | wc -l | tr -d ' ')" != 0 ]; then ev "STOP: an AuthorizationPolicy exists before the repetition" && exit 1; fi
"$REC" "$RD" "$CONNS"

# 1. one connection, request 1 (draft step 1)
mkfifo "${SCR}/in"
: >"${D}/nc-received.txt"
: >"${D}/nc-stderr.txt"
: >"${D}/nc-exit.txt"
(
	set +e
	kubectl -n "$NS" exec -i client -- nc "$SERVER_POD_IP" 8080 <"${SCR}/in" >"${D}/nc-received.txt" 2>"${D}/nc-stderr.txt"
	rc=$?
	printf '%s exit=%s\n' "$(ts)" "$rc" >"${D}/nc-exit.txt"
) &
exec 3>"${SCR}/in"
ev "held connection: kubectl -n ${NS} exec -i client -- nc ${SERVER_POD_IP} 8080 (stdin held open by this script)"
ev "r1 write: GET ${REQ_PATH} HTTP/1.1, Host: server"
req >&3
wait_until 20 '[ "$(nresp | cut -d" " -f1)" -ge 1 ] || ! nc_alive'
ev "r1 result: complete responses on the held connection: $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"

# 2. the connection's identity
"$REC" "$RD" "kubectl -n ${NS} exec client -- netstat -tn"
"$REC" "$RD" "$CONNS"
"$REC" "$RD" "$SLOG"

if [ "$SCOPE" != none ]; then
	# 3. apply, then wait on ztunnel's own state (draft step 2)
	T_APPLY="$(date -u +%FT%TZ)"
	ev "apply: kubectl apply -f ${PFILE}"
	"$REC" "$RD" "kubectl apply -f ${PFILE}"
	if wait_until 60 zt_holds_policy; then ev "ztunnel holds ${POLICY} (istioctl ztunnel-config policy, the draft's jq)"; else ev "ztunnel did NOT hold ${POLICY} within 60 s"; fi
	if [ "$SCOPE" = selector ]; then
		if wait_until 60 wl_lists_policy; then ev "ztunnel lists repro/repro-selector on the server workload (istioctl ztunnel-config workloads, the draft's jq)"; else ev "ztunnel did NOT list repro/repro-selector on the server workload within 60 s"; fi
	fi
	# 4. the watcher's line (draft step 3), what ztunnel holds, and the client's socket
	ev "held connection after the push: complete responses $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"
	"$REC" "$RD" "$WATCHER"
	"$REC" "$RD" "kubectl -n ${NS} get authorizationpolicy ${POLICY} -o yaml"
	"$REC" "$RD" "istioctl ztunnel-config policy --node ${NODE} -o json | jq '.[] | select(.namespace == \"repro\")'"
	"$REC" "$RD" "istioctl ztunnel-config workloads --node ${NODE} -o json | jq -c '.[] | select(.namespace == \"repro\") | {name, uid, authorizationPolicies}'"
	"$REC" "$RD" "$CONNS"
	"$REC" "$RD" "$ZLOG"
	"$REC" "$RD" "kubectl -n ${NS} exec client -- netstat -tn"
fi

# 5. request 2 on the same connection (draft step 4)
if nc_alive; then
	ev "r2 write: GET ${REQ_PATH} HTTP/1.1, Host: server, on the held connection"
	req >&3
	wait_until 20 '[ "$(nresp | cut -d" " -f1)" -ge 2 ] || ! nc_alive'
	ev "r2 result: complete responses on the held connection: $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"
else
	ev "r2 NOT written: the held connection had closed before it: nc exited $(cat "${D}/nc-exit.txt")"
fi

# 6. a new connection, one request (draft step 5, its command)
ev "new connection: the draft's step 5, one curl -sS --retry 0"
"$REC" "$RD" "kubectl -n ${NS} exec client -- curl -sS --retry 0 \"http://${SERVER_POD_IP}:8080${REQ_PATH}\""

# 7. after the sends
"$REC" "$RD" "$SLOG"
"$REC" "$RD" "$CONNS"
"$REC" "$RD" "$ZLOG"

# 8. close the held connection (draft step 6: exec 3>&-), then delete the policy
if nc_alive; then
	ev "close: exec 3>&- (EOF on nc's input)"
	exec 3>&-
	if ! wait_until 15 '! nc_alive'; then
		ev "nc still running 15 s after EOF; stopping it in the pod"
		kubectl -n "$NS" exec client -- sh -c 'kill $(pidof nc)' || true
		wait_until 15 '! nc_alive' || ev "nc still running after kill"
	fi
fi
exec 3>&- 2>/dev/null || true
ev "held connection ended: nc exited $(cat "${D}/nc-exit.txt"); complete responses on it: $(nresp)"
"$REC" "$RD" "kubectl -n ${NS} exec client -- netstat -tn"
"$REC" "$RD" "$CONNS"
if [ "$SCOPE" != none ]; then
	ev "remove: kubectl delete -f ${PFILE}"
	"$REC" "$RD" "kubectl delete -f ${PFILE}"
	if wait_until 60 '! zt_holds_policy'; then ev "ztunnel no longer holds ${POLICY}"; else ev "ztunnel STILL holds ${POLICY} after 60 s"; fi
	if [ "$SCOPE" = selector ]; then
		if wait_until 60 '! wl_lists_policy'; then ev "ztunnel no longer lists repro/repro-selector on the server workload"; else ev "ztunnel STILL lists repro/repro-selector on the server after 60 s"; fi
	fi
	"$REC" "$RD" 'kubectl get authorizationpolicy -A'
	"$REC" "$RD" "istioctl ztunnel-config policy --node ${NODE} -o json | jq -c '.[] | {name, namespace, scope, action}'"
	"$REC" "$RD" "istioctl ztunnel-config workloads --node ${NODE} -o json | jq -c '.[] | select(.namespace == \"repro\") | {name, authorizationPolicies}'"
	# 9. istiod's pushes for the apply and the removal
	"$REC" "${D}/istiod.txt" "kubectl -n istio-system logs ${ISTIOD} --since-time=${T_APPLY}"
fi
"$REC" "${D}/ztunnel.txt" "kubectl -n istio-system logs ${ZT} --since-time=${T0} | grep -E 'no longer allowed|policy change|policy rejection|RBAC|repro|${SRV_RE}'"
ev "rep ${SCOPE}-${N} end"
