#!/usr/bin/env bash
# trace-census.sh <out-csv> — starts ONE port-forward to svc/jaeger, runs
# trace-census.py against it, stops it again. Reads only; sends nothing to the lab.
set -euo pipefail
out="${1:?usage: trace-census.sh <out-csv>}"
port="${B6_JAEGER_PORT:-16692}"
here="$(cd "$(dirname "$0")" && pwd)"
if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null; then
  echo "trace-census: something already answers on 127.0.0.1:$port; refusing" >&2; exit 1
fi
pf=""
trap 'if [ -n "$pf" ]; then kill "$pf" >/dev/null 2>&1 || true; fi' EXIT INT TERM
kubectl -n telemetry port-forward svc/jaeger "$port:16686" >/dev/null 2>&1 &
pf=$!
up=0
for _ in $(seq 1 20); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/"; then up=1; break; fi
  sleep 0.5
done
[ "$up" = 1 ] || { echo "trace-census: port-forward did not come up" >&2; exit 1; }
python3 "$here/trace-census.py" "http://127.0.0.1:$port" "$out"
