#!/usr/bin/env bash
# Reads, by trace id, every span the trace backend holds for the sends that crossed a
# proxy, and prints each proxy SERVER span's name, route, status and error. Read-only.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
R="experiments/runs/2026-09-21-c3-c4-ztunnel"
PORT=16687
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "something already listens on ${PORT}" >&2 && exit 1; fi
kubectl -n telemetry port-forward svc/jaeger "${PORT}:16686" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 200); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; done
for d in "$R"/c34-*/; do
	w=$(basename "$d")
	t=$(jq -r 'select(.op=="SendMessage") | .trace_id' "$d/client.jsonl")
	curl -s --retry 0 --max-time 20 "http://127.0.0.1:${PORT}/api/v3/traces/${t}" -o "$d/trace.json" || true
	printf '%s trace=%s spans=%s\n' "$w" "$t" "$(jq '[.result.resourceSpans[]?.scopeSpans[]?.spans[]?] | length' "$d/trace.json" 2>/dev/null || echo 0)"
	jq -r '.result.resourceSpans[]? | (.resource.attributes[]? | select(.key=="service.name") | .value.stringValue) as $svc
		| .scopeSpans[]?.spans[]? | select(.kind==2 or .kind=="SPAN_KIND_SERVER")
		| (reduce .attributes[]? as $a ({}; .[$a.key] = ($a.value | to_entries[0].value))) as $at
		| "  \($svc) SERVER \(.name) route=\($at.route // "-") http.method=\($at["http.method"] // "-") http.status=\($at["http.status"] // "-") src.identity=\($at["src.identity"] // "-") error=\($at.error // "-") status=\(.status.code // "-")"' \
		"$d/trace.json" 2>/dev/null || true
done
