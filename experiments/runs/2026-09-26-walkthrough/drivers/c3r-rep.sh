#!/usr/bin/env bash
# C-3R driver, kept in the run directory: ONE repetition of the reproduction for ONE
# policy scope, in the throwaway namespace `c3r` (objects/).
#
#   rep.sh <scope> <n>     scope = selector | namespace | none
#
# One repetition, in this order, every reading through rec.sh (stamp, command, output):
#   1. open ONE TCP connection from the client pod to the server pod -- busybox `nc`
#      in the client, fed through `kubectl exec -i` from a FIFO this script holds open,
#      so each request is written exactly once, when this script writes it, on that one
#      connection -- and send request 1 (an agent-card GET) on it;
#   2. read the connection's identity: the client's own socket (netstat in the pod),
#      ztunnel's own record (`istioctl ztunnel-config connections`), and the server's
#      record of the request (its ingress ledger's `remote`);
#   3. apply the scope's AuthorizationPolicy (objects/policy-<scope>.yaml), then WAIT ON
#      ZTUNNEL'S OWN STATE: until `istioctl ztunnel-config policy` holds the policy and,
#      for the selector scope, until `istioctl ztunnel-config workloads` lists it on the
#      server -- a condition read, not a timer;
#   4. read the policy's status, ztunnel's copy of it, the server's policy list, the
#      tracked connections, and ztunnel's log for the watcher's line and any close line;
#   5. send request 2 on THE SAME connection, if it is still open, and record what came
#      back (a response, EOF, a reset) -- or that the connection had closed before it;
#   6. open a NEW connection and send one request (one `curl --retry 0`), the control
#      that the policy is in force for new connections;
#   7. read the server's ledger, the tracked connections and ztunnel's log again;
#   8. close the held connection (EOF on nc's input), then remove the policy and wait
#      on ztunnel's state until it no longer holds it; read back 0 AuthorizationPolicy;
#   9. read istiod's log from the apply (the push debounce and the WDS/WADS push sizes).
# scope `none` runs the same steps with no policy: the control that a request on the
# held connection is delivered when nothing changes.
#
# No retry logic: nc sends what it is given once and has no retry; the control is one
# curl with --retry 0; nothing here re-sends anything. Event stamps are the host's clock
# to the millisecond (GNU date); ztunnel's, istiod's and the server's stamps are the
# cluster's clock.
set -uo pipefail

SCOPE="${1:?scope}" N="${2:?n}"
case "$SCOPE" in selector | namespace | none) ;; *) echo "scope=${SCOPE} is not selector, namespace or none" >&2 && exit 1 ;; esac
cd "$(git rev-parse --show-toplevel)"
R="experiments/runs/2026-09-26-walkthrough/c3r"
D="${R}/${SCOPE}-${N}"
if [ -e "$D" ]; then echo "${D} exists; a repetition is never re-run into the same directory" >&2 && exit 1; fi
mkdir -p "$D"
NS="c3r"
NODE="agent-mesh-lab-worker"
REC="${R}/rec.sh"
RD="${D}/readings.txt"
POLICY="c3r-${SCOPE}"
PFILE="${R}/objects/policy-${SCOPE}.yaml"
LWI="c3r-${SCOPE}-${N}"
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
zt_holds_policy() { istioctl ztunnel-config policy --node "$NODE" -o json 2>/dev/null | jq -e --arg n "$POLICY" 'any(.[]; .name == $n and .namespace == "c3r")' >/dev/null; }
wl_lists_policy() { istioctl ztunnel-config workloads --node "$NODE" -o json 2>/dev/null | jq -e --arg p "c3r/${POLICY}" 'any(.[]; .namespace == "c3r" and (.name | startswith("c3r-server")) and ((.authorizationPolicies // []) | index($p)))' >/dev/null; }
req() { printf 'GET /.well-known/agent-card.json HTTP/1.1\r\nHost: %s:8080\r\nUser-Agent: c3r-nc\r\nA2A-Version: 1.0\r\nX-Logical-Work-Item-Id: %s\r\n\r\n' "$SRV_IP" "$1"; }

cleanup() {
	exec 3>&- 2>/dev/null || true
	rm -rf "$SCR"
}
trap cleanup EXIT

T0="$(date -u +%FT%TZ)"
ZT="$(kubectl -n istio-system get pod -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}')"
ISTIOD="$(kubectl -n istio-system get pod -l app=istiod -o jsonpath='{.items[0].metadata.name}')"
SRV_POD="$(kubectl -n "$NS" get pod -l app=c3r-server -o jsonpath='{.items[0].metadata.name}')"
SRV_IP="$(kubectl -n "$NS" get pod "$SRV_POD" -o jsonpath='{.status.podIP}')"
SRV_RE="${SRV_IP//./\\.}"
ev "rep ${SCOPE}-${N} start T0=${T0} ztunnel=${ZT} istiod=${ISTIOD} server=${SRV_POD} ${SRV_IP}:8080 policy=$([ "$SCOPE" = none ] && echo none || echo "${POLICY}")"

ZLOG="kubectl -n istio-system logs ${ZT} --since-time=${T0} | grep -E 'no longer allowed|policy change|policy rejection|RBAC|${SRV_RE}'"
CONNS="istioctl ztunnel-config connections --node ${NODE} -o json | jq -c '.[] | select(.info.namespace == \"c3r\") | {pod: .info.name, inbound: .connections.inbound, outbound: .connections.outbound}'"
SLEDGER="kubectl -n ${NS} logs ${SRV_POD} --since-time=${T0} | grep '\"ledger\":\"ingress\"'"

# precondition: no AuthorizationPolicy anywhere, and no connection to the server tracked
"$REC" "$RD" 'kubectl get authorizationpolicy -A'
if [ "$(kubectl get authorizationpolicy -A -o name | wc -l | tr -d ' ')" != 0 ]; then ev "STOP: an AuthorizationPolicy exists before the repetition" && exit 1; fi
"$REC" "$RD" "$CONNS"

# 1. one connection, request 1
mkfifo "${SCR}/in"
: >"${D}/nc-received.txt"
: >"${D}/nc-stderr.txt"
: >"${D}/nc-exit.txt"
(
	set +e
	kubectl -n "$NS" exec -i c3r-client -- nc "$SRV_IP" 8080 <"${SCR}/in" >"${D}/nc-received.txt" 2>"${D}/nc-stderr.txt"
	rc=$?
	printf '%s exit=%s\n' "$(ts)" "$rc" >"${D}/nc-exit.txt"
) &
exec 3>"${SCR}/in"
ev "held connection: kubectl -n ${NS} exec -i c3r-client -- nc ${SRV_IP} 8080 (stdin held open by this script)"
ev "r1 write: GET /.well-known/agent-card.json X-Logical-Work-Item-Id: ${LWI}-r1"
req "${LWI}-r1" >&3
wait_until 20 '[ "$(nresp | cut -d" " -f1)" -ge 1 ] || ! nc_alive'
ev "r1 result: complete responses on the held connection: $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"

# 2. the connection's identity
"$REC" "$RD" "kubectl -n ${NS} exec c3r-client -- netstat -tn"
"$REC" "$RD" "$CONNS"
"$REC" "$RD" "$SLEDGER"

if [ "$SCOPE" != none ]; then
	# 3. apply, then wait on ztunnel's own state
	T_APPLY="$(date -u +%FT%TZ)"
	ev "apply: kubectl apply -f ${PFILE}"
	"$REC" "$RD" "kubectl apply -f ${PFILE}"
	if wait_until 60 zt_holds_policy; then ev "ztunnel holds ${NS}/${POLICY} (istioctl ztunnel-config policy)"; else ev "ztunnel did NOT hold ${NS}/${POLICY} within 60 s"; fi
	if [ "$SCOPE" = selector ]; then
		if wait_until 60 wl_lists_policy; then ev "ztunnel lists ${NS}/${POLICY} on the server workload (istioctl ztunnel-config workloads)"; else ev "ztunnel did NOT list ${NS}/${POLICY} on the server workload within 60 s"; fi
	fi
	# 4. what ztunnel holds, and whether the connection was closed
	ev "held connection after the push: complete responses $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"
	"$REC" "$RD" "kubectl -n ${NS} get authorizationpolicy ${POLICY} -o yaml"
	"$REC" "$RD" "istioctl ztunnel-config policy --node ${NODE} -o json | jq '.[] | select(.namespace == \"c3r\")'"
	"$REC" "$RD" "istioctl ztunnel-config workloads --node ${NODE} -o json | jq -c '.[] | select(.namespace == \"c3r\") | {name, uid, authorizationPolicies}'"
	"$REC" "$RD" "$CONNS"
	"$REC" "$RD" "$ZLOG"
	"$REC" "$RD" "kubectl -n ${NS} exec c3r-client -- netstat -tn"
fi

# 5. request 2 on the same connection
if nc_alive; then
	ev "r2 write: GET /.well-known/agent-card.json X-Logical-Work-Item-Id: ${LWI}-r2 on the held connection"
	req "${LWI}-r2" >&3
	wait_until 20 '[ "$(nresp | cut -d" " -f1)" -ge 2 ] || ! nc_alive'
	ev "r2 result: complete responses on the held connection: $(nresp); nc $(nc_alive && echo running || echo "exited $(cat "${D}/nc-exit.txt")")"
else
	ev "r2 NOT written: the held connection had closed before it: nc exited $(cat "${D}/nc-exit.txt")"
fi

# 6. a new connection, one request
ev "new connection: one curl --retry 0, X-Logical-Work-Item-Id: ${LWI}-new"
"$REC" "$RD" "kubectl -n ${NS} exec c3r-client -- curl -sS --retry 0 --max-time 10 -o /dev/null -w 'http_code=%{http_code} local_port=%{local_port} num_connects=%{num_connects}\n' -H 'A2A-Version: 1.0' -H 'X-Logical-Work-Item-Id: ${LWI}-new' http://${SRV_IP}:8080/.well-known/agent-card.json"

# 7. after the sends
"$REC" "$RD" "$SLEDGER"
"$REC" "$RD" "$CONNS"
"$REC" "$RD" "$ZLOG"

# 8. close the held connection, then remove the policy
if nc_alive; then
	ev "close: EOF on nc's input"
	exec 3>&-
	if ! wait_until 15 '! nc_alive'; then
		ev "nc still running 15 s after EOF; stopping it in the pod"
		kubectl -n "$NS" exec c3r-client -- sh -c 'kill $(pidof nc)' || true
		wait_until 15 '! nc_alive' || ev "nc still running after kill"
	fi
fi
exec 3>&- 2>/dev/null || true
ev "held connection ended: nc exited $(cat "${D}/nc-exit.txt"); complete responses on it: $(nresp)"
"$REC" "$RD" "kubectl -n ${NS} exec c3r-client -- netstat -tn"
"$REC" "$RD" "$CONNS"
if [ "$SCOPE" != none ]; then
	ev "remove: kubectl delete -f ${PFILE}"
	"$REC" "$RD" "kubectl delete -f ${PFILE}"
	if wait_until 60 '! zt_holds_policy'; then ev "ztunnel no longer holds ${NS}/${POLICY}"; else ev "ztunnel STILL holds ${NS}/${POLICY} after 60 s"; fi
	if [ "$SCOPE" = selector ]; then
		if wait_until 60 '! wl_lists_policy'; then ev "ztunnel no longer lists ${NS}/${POLICY} on the server workload"; else ev "ztunnel STILL lists ${NS}/${POLICY} on the server after 60 s"; fi
	fi
	"$REC" "$RD" 'kubectl get authorizationpolicy -A'
	"$REC" "$RD" "istioctl ztunnel-config policy --node ${NODE} -o json | jq -c '.[] | {name, namespace, scope, action}'"
	"$REC" "$RD" "istioctl ztunnel-config workloads --node ${NODE} -o json | jq -c '.[] | select(.namespace == \"c3r\") | {name, authorizationPolicies}'"
	# 9. istiod's pushes for the apply and the removal
	"$REC" "${D}/istiod.txt" "kubectl -n istio-system logs ${ISTIOD} --since-time=${T_APPLY}"
fi
"$REC" "${D}/ztunnel.txt" "kubectl -n istio-system logs ${ZT} --since-time=${T0} | grep -E 'no longer allowed|policy change|policy rejection|RBAC|c3r|${SRV_RE}'"
ev "rep ${SCOPE}-${N} end"
