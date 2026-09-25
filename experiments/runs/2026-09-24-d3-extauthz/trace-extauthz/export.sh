#!/usr/bin/env bash
# Follow-on D-3, review round (review-d3 M10): a compact export of what trace-extauthz/join.csv reads from the trace backend,
# so that join.csv can be derived from committed files (derive-join.py). For every access line of the deny and allow windows
# (<phase>/<work item>/ingress-access.txt) it asks the trace backend for the line's trace id and writes ONE JSONL line: the
# phase, work item, HTTP method, the access line's trace id, span id and status, and every span of that trace named ExtAuthz,
# each with its span id, parent reference, process service name and tags; and, for the fixture's decision line of the same
# method in that send, its request_id and the number of spans the backend holds under it. Reads only.
#   bash export.sh      (run from the repository; opens and closes one port-forward to the trace backend)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/experiments/runs/2026-09-24-d3-extauthz"
PORT=16687
kubectl -n telemetry port-forward svc/jaeger "$PORT:16686" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
PORT=$PORT python3 - <<'PY'
import glob, json, os, re, urllib.request
base = "http://127.0.0.1:%s/api/traces/" % os.environ["PORT"]
import urllib.error
def get(tid):
    # The backend answers 404 for a trace id it holds no span of; that is read as no spans.
    try:
        return json.load(urllib.request.urlopen(base + tid, timeout=10)).get("data") or []
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise
out = open("trace-extauthz/extauthz-spans.jsonl", "w")
for d in sorted(glob.glob("deny/*/") + glob.glob("allow/*/")):
    phase, wi = d.rstrip("/").split("/")
    dec = [json.loads(l) for l in open(d + "extauthz-window.txt") if l.startswith("{")]
    for line in open(d + "ingress-access.txt"):
        m = re.search(r"http\.method=(\S+)", line); t = re.search(r"trace\.id=([0-9a-f]+)", line)
        sp = re.search(r"span\.id=([0-9a-f]+)", line); st = re.search(r"http\.status=(\d+)", line)
        data = get(t.group(1))
        spans = []
        for tr in data:
            for s in tr["spans"]:
                if s["operationName"] == "ExtAuthz":
                    spans.append({"spanID": s["spanID"], "references": s.get("references", []),
                                  "service": tr["processes"][s["processID"]]["serviceName"],
                                  "tags": {x["key"]: x["value"] for x in s["tags"]}})
        fr = next((x["request_id"] for x in dec if x["http_method"] == m.group(1)), "")
        fr_spans = sum(len(tr["spans"]) for tr in get(fr)) if fr else None
        out.write(json.dumps({"phase": phase, "work_item": wi, "http_method": m.group(1), "access_trace_id": t.group(1),
                              "access_span_id": sp.group(1), "access_status": st.group(1), "extauthz_spans": spans,
                              "fixture_request_id": fr, "fixture_request_id_spans": fr_spans}, sort_keys=True) + "\n")
out.close()
PY
