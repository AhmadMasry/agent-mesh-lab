#!/usr/bin/env bash
# Follow-ups 15, review fix M4: every ztunnel access-log line, at any level, for a connection from either
# istiod-driven waypoint to its backend (worker, orchestrator), since the rebuild's first line. ztunnel writes one
# "connection complete" line when a connection closes, with its duration, so the line's time minus its duration is
# when the connection opened. Read-only (kubectl logs). Identities are trimmed from each line.
set -euo pipefail
SINCE="${1:-2026-09-18T21:08:56Z}"
echo "# waypoint-connections.sh, since $SINCE, read $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for p in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
	echo "## $p"
	kubectl -n istio-system logs "$p" --since-time="$SINCE" |
		grep -E 'src\.workload="agentgateway-waypoint(-orch)?-[^"]*".*dst\.workload="(worker|orchestrator)-' |
		sed -E 's/ (src|dst)\.identity="[^"]*"//g' || true
done
echo
echo "## the same lines, as close time, opened (close minus duration), duration, bytes and outcome"
for p in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
	kubectl -n istio-system logs "$p" --since-time="$SINCE" |
		grep -E 'src\.workload="agentgateway-waypoint(-orch)?-[^"]*".*dst\.workload="(worker|orchestrator)-' || true
done | python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/waypoint-connections.py"
