#!/usr/bin/env bash
# Follow-ups 23: the tool versions on the host and what the cluster reports about itself, after the walk. Read-only.
# $1 = tool-versions output, $2 = cluster-versions output. PATH carries the walkthrough's lab-scoped istioctl first.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
LAB_TOOLS="${TMPDIR:-/tmp}/agent-mesh-lab-tools"; PATH="$LAB_TOOLS:$PATH"; export PATH
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
echo "# Tool versions observed on the host that produced docs/walkthrough.md, $(ts)."
echo "# The README's prerequisites table is the reference; this is what this run had. istioctl is the walkthrough's"
echo "# lab-scoped copy, first on PATH (\${TMPDIR:-/tmp}/agent-mesh-lab-tools/istioctl)."
for c in "ko version" "kind version" "istioctl version --remote=false" "kubectl version --client" "jq --version" "docker --version" "docker buildx version" "uv --version" "kubescape version" "helm version" "go version"; do
	echo; echo "## $c"; eval "$c" 2>&1 | sed 's/^/   /'
done
} > "$1"
{
echo "# What the cluster this walkthrough built reports about itself, $(ts). Read-only."
echo; echo "## kubectl version"; kubectl version 2>&1 | sed 's/^/  /'
echo; echo "## istioctl version"; istioctl version 2>&1 | sed 's/^/  /'
echo; echo "## the node image, by digest"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  kubelet "}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sed 's/^/  /'
echo "  node image $(grep -m1 'image:' kind-config.yaml | awk '{print $2}')"
echo; echo "## the agentgateway image on each proxy and on the control plane"
for ns in agentgateway-ingress agentgateway-system agentgateway-waypoint; do
	kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' | sed 's/^/  /'
done
echo; echo "## the lab Deployments' images and ServiceAccounts"
kubectl -n lab get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  sa="}{.spec.template.spec.serviceAccountName}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}' | sed 's/^/  /'
echo; echo "## helm list -A"; helm list -A 2>&1 | sed 's/^/  /'
} > "$2"
