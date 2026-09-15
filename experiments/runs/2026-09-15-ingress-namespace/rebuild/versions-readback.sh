#!/usr/bin/env bash
# Follow-ups 12: the cluster-side fields of the Versions line, and the image identities, read back from the rebuilt
# cluster. Read-only. $1 = output directory. Writes versions-readback.txt and images.txt.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
D="$1"; mkdir -p "$D"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{
echo "# The cluster-side fields of the Versions line, read back from the rebuilt cluster $(ts). Read-only."
echo
echo "## kind node images (k8s=)"
docker inspect --format '{{.Name}} {{.Config.Image}}' agent-mesh-lab-control-plane agent-mesh-lab-worker 2>&1
echo
echo "## Gateway API CRD bundle version and channel (gateway-api=)"
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} {.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
echo
echo "## agentgateway images (agentgateway=)"
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[].image | test("agentgateway")) | "\(.metadata.namespace)/\(.metadata.name) \([.spec.containers[].image] | join(","))"' | sort -u
echo
echo "## istio= is in istio.txt (istioctl version and every Istio image)"
echo "## a2a-go, a2a-python, openai-python: their sources against d28dea6 (the base of this branch):"
for f in go.mod go.sum agents/orchestrator/uv.lock; do
	printf '   %-28s d28dea6 %s  HEAD %s\n' "$f" "$(git rev-parse d28dea6:$f)" "$(git rev-parse HEAD:$f)"
done
} > "$D/versions-readback.txt" 2>&1

{
echo "# The images the rebuilt cluster runs, read $(ts), against the followups-11 rebuild. Read-only."
echo
echo "## Go images: the source stamp (lab.agent-mesh/go-sources) on the two Deployments against the checkout's hash"
H=$(git ls-files -s -- agents/worker fixtures/mockllm internal go.mod go.sum ':!**/*_test.go' | git hash-object --stdin)
echo "   GO_SOURCES_HASH at HEAD (the Makefile's command): $H"
for d in worker mockllm; do
	echo "   deployment/$d annotation: $(kubectl -n lab get deploy $d -o jsonpath='{.metadata.annotations.lab\.agent-mesh/go-sources}')"
done
echo "   followups-11's stamp (experiments/runs/2026-09-15-helm-only/make-n.txt): $(grep -o 'go-sources=[0-9a-f]*' experiments/runs/2026-09-15-helm-only/make-n.txt | head -1)"
echo "   image input paths against d28dea6 (git rev-parse <rev>:<path>):"
for p in agents fixtures internal go.mod go.sum .ko.yaml agents/orchestrator/uv.lock agents/orchestrator/Dockerfile; do
	a=$(git rev-parse d28dea6:$p); b=$(git rev-parse HEAD:$p)
	printf '      %-32s %s %s\n' "$p" "$b" "$([ "$a" = "$b" ] && echo same || echo DIFFERENT)"
done
echo
echo "## the running pods' images and image IDs"
kubectl -n lab get pods -o json | jq -r '.items[] | select(.metadata.name | test("^(worker|mockllm|orchestrator)-")) | .metadata.name as $n | .status.containerStatuses[] | "   \($n)  \(.image)  \(.imageID)"'
echo
echo "## the orchestrator image in the local Docker daemon (what make orchestrator-image built last)"
echo "   $(docker image inspect orchestrator:dev --format '{{.Id}} created {{.Created}}' 2>&1)"
echo "   followups-11 (experiments/runs/2026-09-15-helm-only/scan/scan-context.txt): $(awk '/^  orchestrator  orchestrator:dev/ {getline; print $1}' experiments/runs/2026-09-15-helm-only/scan/scan-context.txt)"
} > "$D/images.txt" 2>&1
cat "$D/versions-readback.txt" "$D/images.txt"
