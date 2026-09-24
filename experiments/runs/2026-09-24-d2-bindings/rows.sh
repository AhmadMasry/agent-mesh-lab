#!/usr/bin/env bash
# Follow-on D-2: the rows. Each layer's window: readings before, the overlay applied by kubectl apply -k from this run
# directory (never under deploy/), readings with it in force, the sends, the overlay removed by kubectl delete -k,
# readings after. The application layer instead sets REFUSE_OPERATION=SubscribeToTask on both agents with kubectl set
# env and restores it empty, as C-10 did, each change waited on by rollout status. One send at a time (sends.sh).
#   bash rows.sh <window>      window: p0 | l1-route | l2-path | l3-deny | l3-require | l4-app
# Sends per window: per binding (rest, grpc) and receiver (go, py), REPS each of SendMessage (sm) and SubscribeToTask
# naming no task (st) by the load client, and on rest REPS curl SubscribeToTask (cst) with curl's own headers.
# p0 is the same with one of each and nothing applied. No retry logic. Keep-awake: this script starts none and
# changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL="${RUNREL:?}"; RUN_ID="${RUN_ID:?}"; IMAGE="${IMAGE:?}"
export RUNREL RUN_ID IMAGE
D="experiments/runs/$RUNREL"
S="$D/sends.sh"
WIN="${1:?window}"
REPS=5
ts() { date -u +%FT%TZ; }
dump() { # label
	local port=19$((RANDOM % 900 + 100))
	kubectl -n agentgateway-ingress port-forward deploy/agentgateway-ingress "$port:15000" >/dev/null 2>&1 &
	local pf=$!
	sleep 2
	curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$port/config_dump" -o "$D/$WIN/config-dump-ingress-$1.json" || echo "$(ts) config dump $1 failed" >> "$D/phases.txt"
	kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
}
readings() { # label
	{
		echo "# $(ts) readings $WIN $1"
		echo "## kubectl -n lab get httproute,grpcroute,agentgatewaypolicy -o yaml"
		kubectl -n lab get httproute,grpcroute,agentgatewaypolicy -o yaml
		echo "## worker and orchestrator REFUSE_OPERATION and pods"
		for d in worker orchestrator; do echo "$d: $(kubectl -n lab get deploy $d -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="REFUSE_OPERATION")]}{.name}={.value}{end}')"; done
		kubectl -n lab get pods -l 'app in (worker,orchestrator)' -o wide --no-headers
		echo "## agentgateway controller log, last 2 minutes"
		kubectl -n agentgateway-system logs deploy/agentgateway --since=2m 2>/dev/null | tail -40
	} > "$D/$WIN/readings-$1.txt" 2>&1
	dump "$1"
}
sendset() { # reps
	local n b r
	for b in rest grpc; do for r in go py; do
		for n in $(seq 1 "$1"); do bash "$S" "$WIN" "$b" sm "$r" "$n"; bash "$S" "$WIN" "$b" st "$r" "$n"; done
		if [ "$b" = rest ]; then for n in $(seq 1 "$1"); do bash "$S" "$WIN" rest cst "$r" "$n"; done; fi
	done; done
}
mkdir -p "$D/$WIN"
echo "$(ts) window $WIN start" | tee -a "$D/phases.txt"
readings before
case "$WIN" in
p0) sendset 1 ;;
l1-route | l2-path | l3-deny | l3-require)
	kubectl apply -k "$D/overlay-$WIN" > "$D/$WIN/apply.txt" 2>&1; echo "$(ts) applied overlay-$WIN rc=$?" | tee -a "$D/phases.txt"
	sleep 8
	readings applied
	sendset "$REPS"
	readings end
	kubectl delete -k "$D/overlay-$WIN" > "$D/$WIN/remove.txt" 2>&1; echo "$(ts) removed overlay-$WIN rc=$?" | tee -a "$D/phases.txt"
	sleep 8
	;;
l4-app)
	for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION=SubscribeToTask >> "$D/$WIN/apply.txt" 2>&1; done
	for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s >> "$D/$WIN/apply.txt" 2>&1; done
	echo "$(ts) REFUSE_OPERATION=SubscribeToTask set on both agents" | tee -a "$D/phases.txt"
	readings applied
	sendset "$REPS"
	readings end
	for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION= >> "$D/$WIN/remove.txt" 2>&1; done
	for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s >> "$D/$WIN/remove.txt" 2>&1; done
	echo "$(ts) REFUSE_OPERATION restored empty on both agents" | tee -a "$D/phases.txt"
	;;
*) echo "window $WIN" >&2; exit 1 ;;
esac
readings removed
echo "$(ts) window $WIN end" | tee -a "$D/phases.txt"
