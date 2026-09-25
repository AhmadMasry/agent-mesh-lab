#!/usr/bin/env bash
# The currency pass of 2026-09-25, Phase 2: every moved pin read back from the running cluster and the built
# artefacts. Reads only: kubectl get, kubectl exec of one python -c in the orchestrator, helm list, docker inspect of
# the kind nodes, istioctl version. $1 = output file. Nothing is created, changed or deleted.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
ts() { date -u +%FT%TZ; }
{
echo "# $(ts) pins read back from the rebuilt cluster; HEAD $(git log -1 --format=%s | cut -c1-100)"
echo "== every running container: namespace/pod-prefix container image imageID =="
kubectl get pods -A -o json | python3 -c '
import json,sys
rows=set()
for p in json.load(sys.stdin)["items"]:
    ns=p["metadata"]["namespace"]; name=p["metadata"]["name"]
    pref=name.rsplit("-",2)[0] if name.count("-")>=2 else name
    st={s["name"]:s for s in p.get("status",{}).get("containerStatuses",[])}
    for c in p["spec"]["containers"]:
        s=st.get(c["name"],{})
        rows.add("%s/%s %s %s %s" % (ns,pref,c["name"],c["image"],s.get("imageID","")))
print("\n".join(sorted(rows)))'
echo "== helm list -A (chart, app version) =="
helm list -A --output json | python3 -c 'import json,sys
for r in json.load(sys.stdin): print("%s/%s chart=%s app=%s status=%s" % (r["namespace"],r["name"],r["chart"],r["app_version"],r["status"]))'
echo "== kind nodes =="
docker inspect -f '{{.Name}} image={{.Config.Image}}' agent-mesh-lab-control-plane agent-mesh-lab-worker
kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
echo "== Gateway API bundle =="
kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='bundle-version={.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} channel={.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
echo "== istioctl (the lab-scoped copy on PATH) and the control plane =="
istioctl version 2>&1
echo "== the orchestrator's installed packages, read in the running pod =="
kubectl -n lab exec deploy/orchestrator -- python -c 'import importlib.metadata as m
print(" ".join("%s=%s" % (p, m.version(p)) for p in ("a2a-sdk","openai","uvicorn","starlette","httpx2","httpcore2","protobuf","grpcio","opentelemetry-sdk","opentelemetry-distro","opentelemetry-exporter-otlp-proto-http","opentelemetry-instrumentation-openai-v2","opentelemetry-util-genai")))
from orchestrator.model import ModelClient
c=ModelClient(base_url="http://127.0.0.1:1/v1", model="m", api_key="k")
print("ModelClient max_retries=%s transport_retries=%s" % (c.max_retries, c.transport_retries))' 2>&1
echo "== a2a-go and grpc-go: the modules the Go images were built from (go.mod at the built tree) =="
awk '$1 ~ /a2aproject\/a2a-go|google.golang.org\/grpc$|genproto\/googleapis\/rpc/ {print "  "$1"@"$2}' go.mod
echo "== $(ts) end =="
} > "$1" 2>&1
