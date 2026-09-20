#!/usr/bin/env bash
# Follow-ups 19, task 4b: the versions the entry's Versions line names, read from the rebuilt cluster. Reads only:
# kubectl get / exec (one python -c that imports importlib.metadata), istioctl version, docker inspect of the two
# kind node containers, helm list. Nothing is created, changed or deleted. $1 = output file.
# The commands are the version lines of reading (c) in experiments/runs/2026-09-19-worker-span-rebuild/checks.sh
# (l.188-199: the server, the nodes, the Gateway API bundle, istioctl, the orchestrator's SDKs, a2a-go from go.mod),
# lifted out because this task drops that reading; added: the agentgateway images the two proxies and the controller
# run, and the a2a-spec commit, which is not on the cluster and is read from versions.yaml, said so where printed.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
echo "# The versions on the rebuilt cluster, read $(ts). Reads only."
echo "== $(ts) the server, the nodes, the Gateway API bundle =="
kubectl version -o json | python3 -c 'import json,sys; v=json.load(sys.stdin); print("kubectl client %s  server %s" % (v["clientVersion"]["gitVersion"], v["serverVersion"]["gitVersion"]))'
kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage
docker inspect -f '{{.Name}} image={{.Config.Image}}' agent-mesh-lab-control-plane agent-mesh-lab-worker 2>&1
for crd in gateways httproutes; do
	printf '%s.gateway.networking.k8s.io: ' "$crd"
	kubectl get crd "$crd.gateway.networking.k8s.io" -o jsonpath='bundle-version={.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} channel={.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
done
istioctl version 2>&1
echo "== $(ts) agentgateway: the image each proxy and the controller run =="
kubectl get pods -A -o json | python3 -c 'import json,sys
for p in json.load(sys.stdin)["items"]:
    for c in p["spec"]["containers"]:
        if "agentgateway" in c["image"]:
            print("  %s/%s %s: %s" % (p["metadata"]["namespace"], p["metadata"]["name"].rsplit("-", 2)[0], c["name"], c["image"]))' | sort -u
echo "== $(ts) the running agents: the SDK each one runs =="
kubectl -n lab exec deploy/orchestrator -- python -c 'import importlib.metadata as m; print(" ".join("%s=%s" % (p, m.version(p)) for p in ("a2a-sdk", "openai")))' 2>&1
echo "(a2a-go's version is the module the worker binary was linked with: go.mod at the built tree -> $(awk '$1 ~ /a2aproject\/a2a-go/ {print $1 "@" $2}' go.mod | tr '\n' ' '))"
echo "(a2a-spec is not on the cluster; versions.yaml at the built tree, key a2a-spec, its value -> $(grep '^a2a-spec:' versions.yaml | sed -n 's/^a2a-spec: *{ value: "\([0-9a-f]*\)".*/\1/p'))"
echo "== $(ts) helm list -A: release, namespace, status, chart, app version =="
helm list -A -o json | python3 -c 'import json,sys; [print("%-22s %-22s %-10s %-36s app_version=%s" % (r["name"], r["namespace"], r["status"], r["chart"], r["app_version"])) for r in json.load(sys.stdin)]'
} > "$1" 2>&1
echo "wrote $1"
