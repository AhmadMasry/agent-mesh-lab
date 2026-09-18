#!/usr/bin/env bash
# Follow-ups 15, commit 3: one reading of every hop counter, through a Prometheus port-forward this script opens
# and closes. Evaluates each expression in promql.txt as an instant query at one evaluation time and writes the
# answers, with that time and the wall-clock stamps of the read, to samples/<label>.json. Read-only
# (/api/v1/query only).
#
# $1 = label (for example clean-before). Runs from the repository root.
set -euo pipefail
LABEL="$1"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PROM_PORT:-19093}"
mkdir -p "$DIR/samples"
OPENED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "-- port-forward opened at ${OPENED}: kubectl -n telemetry port-forward svc/prometheus ${PORT}:9090" >&2
kubectl -n telemetry port-forward svc/prometheus "${PORT}:9090" >/dev/null 2>&1 &
PF=$!
close_pf() { if [ -n "${PF:-}" ]; then kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true; PF=""; echo "-- port-forward closed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2; fi; }
trap close_pf EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null 2>&1 && break; sleep 0.25; done
curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null || { echo "prometheus did not answer" >&2; exit 1; }
EVAL="$(python3 -c 'import time; print(f"{time.time():.3f}")')"
python3 - "$DIR/promql.txt" "$PORT" "$EVAL" "$LABEL" "$OPENED" > "$DIR/samples/${LABEL}.json" <<'PY'
import json, sys, urllib.parse, urllib.request, datetime
qfile, port, ev, label, opened = sys.argv[1:6]
out = {"label": label, "port_forward_opened_utc": opened, "eval_time": float(ev),
       "eval_time_utc": datetime.datetime.fromtimestamp(float(ev), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
       "queries": {}}
for line in open(qfile):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    name, expr = line.split("\t", 1)
    url = f"http://127.0.0.1:{port}/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": ev})
    ans = json.load(urllib.request.urlopen(url))
    out["queries"][name] = {"expr": expr, "status": ans.get("status"), "result": ans.get("data", {}).get("result", [])}
json.dump(out, sys.stdout, sort_keys=True, separators=(",", ":"))
PY
close_pf
python3 - "$DIR/samples/${LABEL}.json" <<'PY' >&2
import json, sys
d = json.load(open(sys.argv[1]))
print(f"-- reading {d['label']} at eval {d['eval_time_utc']}: " + " ".join(f"{k}={len(v['result'])}" for k, v in d["queries"].items()))
ls = [float(r["value"][1]) for r in d["queries"]["last_scrape"]["result"]]
print(f"-- last scrape of the 9 targets: oldest {d['eval_time'] - min(ls):.1f} s before eval, newest {d['eval_time'] - max(ls):.1f} s before eval; up={sum(1 for r in d['queries']['up']['result'] if r['value'][1] == '1')}/{len(d['queries']['up']['result'])}")
PY
