#!/usr/bin/env bash
# config-dump.sh <namespace> <deployment> <out.json>: one read of the proxy's admin /config_dump
# through a port-forward that is closed afterwards. curl without retries (--retry 0).
set -euo pipefail
ns="$1"; dep="$2"; out="$3"; port="${PORT:-15999}"
kubectl --context kind-agent-mesh-lab -n "$ns" port-forward "deploy/$dep" "$port:15000" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do nc -z 127.0.0.1 "$port" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$port/config_dump" -o "$out"
python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
pol=d.get("policies") or []
cfg=(d.get("config") or {})
print("policies:",len(pol))
for p in pol:
    print("  key=",p.get("key"),"name=",p.get("name"),"target=",json.dumps(p.get("target")))
print("config.tracing:",json.dumps(cfg.get("tracing")))
print("xds:",json.dumps({k:v for k,v in cfg.items() if "xds" in k.lower()})[:300])
PY
