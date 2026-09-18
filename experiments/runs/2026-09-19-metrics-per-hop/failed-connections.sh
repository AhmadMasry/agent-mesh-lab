#!/usr/bin/env bash
# Follow-ups 15, commit 3: the evidence for the three families that appeared between the start and end exposition
# reads without being request flow -- istio_tcp_connections_failed_total, agentgateway_xds_connection_terminations_total
# and istio_xds_connection_terminations_total. Read-only: ztunnel's own access log (every line at level error since
# the rebuild), and Prometheus's range answer for each family since the rebuild, at the scrape step, through a
# port-forward this script opens and closes. Writes failed-connections.txt beside itself.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/failed-connections.txt"
SINCE="2026-09-18T21:08:56Z"
PORT="${PROM_PORT:-19096}"
{
echo "# read $(date -u +%Y-%m-%dT%H:%M:%SZ); since the rebuild's first line, $SINCE"
echo
echo "## ztunnel access-log lines at level error, both ztunnel pods (identities trimmed)"
for p in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
	echo "# $p"
	kubectl -n istio-system logs "$p" --since-time="$SINCE" | awk '$2=="error"' | sed -E 's/ (src|dst)\.identity="[^"]*"//g' || true
done
echo
kubectl -n telemetry port-forward svc/prometheus "${PORT}:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null 2>&1 && break; sleep 0.25; done
echo "## Prometheus range answers, $SINCE to now, step 15 s: each series, and every time its value changed"
for q in 'sum by (instance, reporter, source_workload, destination_workload, destination_service, response_flags) (istio_tcp_connections_failed_total)' \
         'agentgateway_xds_connection_terminations_total' 'istio_xds_connection_terminations_total'; do
	echo "# $q"
	curl -sG "http://127.0.0.1:${PORT}/api/v1/query_range" --data-urlencode "query=$q" \
		--data-urlencode "start=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$SINCE" +%s)" --data-urlencode "end=$(date +%s)" --data-urlencode "step=15" |
		python3 -c '
import json, sys, datetime
for r in json.load(sys.stdin)["data"]["result"]:
    m = {k: v for k, v in r["metric"].items() if k not in ("job", "__name__", "namespace")}
    prev, ch = None, []
    for t, v in r["values"]:
        if v != prev:
            ch.append(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%H:%M:%SZ") + "=" + v); prev = v
    print("  ", m, "changes:", " ".join(ch))'
done
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"
