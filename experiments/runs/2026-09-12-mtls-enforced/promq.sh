#!/usr/bin/env bash
# Follow-ups 7 / the Prometheus reader used for the per-hop connection-security table.
#
# Opens one port-forward to the Prometheus in `telemetry`, runs the queries it is given,
# and closes the port-forward again. Both the opening and the closing are printed so the
# record says when the cluster was being read. Read-only: /api/v1/query and
# /api/v1/targets only.
#
# The metric and the label come from documents fetched 2026-09-12 and nothing else is
# queried: "Tcp Connections Opened (istio_tcp_connections_opened_total): This is a
# COUNTER incremented for every opened connection."
# (https://istio.io/latest/docs/reference/config/metrics/) and "Validate that the
# connection_security_policy value is set to mutual_tls along with the expected source
# and destination identity information."
# (https://istio.io/latest/docs/ambient/usage/verify-mtls-enabled/)
#
#   ./promq.sh targets                 # the scrape-target roster, up/down per job
#   ./promq.sh query '<promql>'        # one instant query, JSON on stdout
#   ./promq.sh security                # the per-hop connection-security series
set -euo pipefail

MODE="${1:?usage: promq.sh targets|query <promql>|security}"
PORT="${PROM_PORT:-19090}"
BASE="http://127.0.0.1:${PORT}"

echo "-- port-forward opened at $(date -u +%Y-%m-%dT%H:%M:%SZ): kubectl -n telemetry port-forward svc/prometheus ${PORT}:9090" >&2
kubectl -n telemetry port-forward svc/prometheus "${PORT}:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true; echo "-- port-forward closed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2' EXIT

for _ in $(seq 1 40); do
	curl -sf "${BASE}/-/ready" >/dev/null 2>&1 && break
	sleep 0.25
done
curl -sf "${BASE}/-/ready" >/dev/null || { echo "prometheus did not answer on ${BASE}" >&2; exit 1; }

q() { curl -sG --data-urlencode "query=$1" "${BASE}/api/v1/query"; }

case "$MODE" in
	targets)
		curl -sf "${BASE}/api/v1/targets?state=any" | python3 "$(dirname "${BASH_SOURCE[0]}")/promfmt.py" targets
		;;
	query)
		q "${2:?promql required}"
		;;
	security)
		# Every istio_tcp_connections_opened_total series, with the labels that name the
		# hop and its connection security. Printed as text so the raw reading is in the
		# record before anything is tabulated from it.
		q 'istio_tcp_connections_opened_total' | python3 "$(dirname "${BASH_SOURCE[0]}")/promfmt.py" series
		;;
	*) echo "unknown mode ${MODE}" >&2; exit 2 ;;
esac
