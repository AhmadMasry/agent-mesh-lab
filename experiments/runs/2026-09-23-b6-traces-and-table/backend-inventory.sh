#!/usr/bin/env bash
# backend-inventory.sh — which of Experiment B's counted work items still carry
# spans in the standing cluster's trace backend, and how many.
#
# Reads only. It starts ONE port-forward to svc/jaeger on a port of its own,
# queries the documented GET /api/v3/traces binding once per work item with the
# same query `make export-trace` uses, counts the rows the committed
# experiments/lib/jaeger-spans.jq gives for each, and stops the port-forward.
# It sends nothing to the lab, arms nothing and changes nothing.
#
# The work item lists come from the committed summary.csv of each row, so a row
# that was never counted cannot appear here.
#
# usage: backend-inventory.sh <out-file>
set -euo pipefail

out="${1:?usage: backend-inventory.sh <out-file>}"
port="${B6_JAEGER_PORT:-16691}"
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
runs="$repo/experiments/runs"

if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null; then
  echo "backend-inventory: something already answers on 127.0.0.1:$port; refusing" >&2
  exit 1
fi

pf=""
cleanup() { if [ -n "$pf" ]; then kill "$pf" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM
kubectl -n telemetry port-forward svc/jaeger "$port:16686" >/dev/null 2>&1 &
pf=$!
up=0
for _ in $(seq 1 20); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/"; then up=1; break; fi
  sleep 0.5
done
[ "$up" = 1 ] || { echo "backend-inventory: port-forward did not come up" >&2; exit 1; }

# The window is deliberately wider than any B run: the question is whether the
# backend holds the span at all, not when.
tmin="2026-09-20T00:00:00Z"
tmax="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp="$(mktemp -d)"
trap 'cleanup; rm -rf "$tmp"' EXIT INT TERM

count_one() {
  local lwi="$1"
  curl -sS -G "http://127.0.0.1:$port/api/v3/traces" \
    --data-urlencode "query.attributes={\"lab.work_item\":\"$lwi\"}" \
    --data-urlencode "query.start_time_min=$tmin" \
    --data-urlencode "query.start_time_max=$tmax" \
    --data-urlencode "query.search_depth=100" \
    -o "$tmp/t.json"
  jq -r -s -f "$repo/experiments/lib/jaeger-spans.jq" "$tmp/t.json" | tail -n +2 | grep -c '' || true
}

# row label | summary.csv | column holding the work item
rows=(
  "B-3 clean stream|$runs/2026-09-21-b3-streaming-client/stream/summary.csv|2"
  "B-3 SubscribeToTask during a running task|$runs/2026-09-21-b3-streaming-client/subscribe-running/summary.csv|2"
  "B-3 D3 SubscribeToTask on a terminal task|$runs/2026-09-21-b3-streaming-client/subscribe-terminal/summary.csv|2"
  "B-4 control|$runs/2026-09-22-b4-control/control/summary.csv|2"
  "B-5a removal|$runs/2026-09-22-b5a-removal/removal/summary.csv|4"
  "B-5b removal and resubscribe|$runs/2026-09-22-b5b-removal-resubscribe/rows/summary.csv|5"
)

{
  echo "# Which counted work items of Experiment B still carry spans in the standing"
  echo "# cluster's trace backend. Read $(date -u +%Y-%m-%dT%H:%M:%SZ). Query window $tmin..$tmax."
  echo "# Jaeger pod uptime is what bounds this: the cluster B-3 ran on was deleted by"
  echo "# B-4's rebuild, so B-3's spans are not 'expired' but gone with their backend."
  echo
  printf '%s\n' "row,work_item,spans"
} > "$out"

for r in "${rows[@]}"; do
  label="${r%%|*}"; rest="${r#*|}"
  csv="${rest%%|*}"; col="${rest##*|}"
  while IFS= read -r lwi; do
    [ -n "$lwi" ] || continue
    n="$(count_one "$lwi")"
    printf '%s,%s,%s\n' "$label" "$lwi" "$n" >> "$out"
  done < <(awk -F, -v c="$col" 'NR>1{print $c}' "$csv")
done

echo >> "$out"
echo "# totals by row: rows with at least one span / rows probed" >> "$out"
awk -F, 'NR>6 && NF==3 {t[$1]++; if ($3+0>0) w[$1]++} END {for (k in t) printf "# %s: %d/%d\n", k, w[k]+0, t[k]}' "$out" | sort >> "$out"
