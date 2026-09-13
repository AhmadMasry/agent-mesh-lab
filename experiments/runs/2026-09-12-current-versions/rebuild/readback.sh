#!/usr/bin/env bash
# Follow-ups 10: read the rebuilt cluster back. Read-only (get/logs/istioctl reads); nothing created,
# changed, restarted or deleted. Writes into the run directory given as $1.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
D="$1"; mkdir -p "$D"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- pins read back
{
echo "# The pins read back from the rebuilt cluster, $(ts), and compared with the values in versions.yaml."
echo "# Read-only: kubectl get / version, istioctl version, helm list."
echo
echo "## kubectl version"; kubectl version 2>&1
echo
echo "## istioctl version (client, control plane, data plane)"; istioctl version 2>&1
echo
echo "## helm list -A"; helm list -A 2>&1
echo
echo "## every container image in the cluster, with the imageID the kubelet resolved, by namespace/pod"
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | .spec.nodeName as $n
	| (.status.containerStatuses // [])[] | [$ns, $p, .name, .image, .imageID] | @tsv' | sort | column -t -s $'\t'
echo
echo "## init containers"
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p
	| (.status.initContainerStatuses // [])[] | [$ns, $p, .name, .image, .imageID] | @tsv' | sort | column -t -s $'\t'
echo
echo "## node image"
kubectl get nodes -o wide 2>&1
docker inspect agent-mesh-lab-control-plane agent-mesh-lab-worker --format '{{.Name}} {{.Config.Image}}' 2>&1
echo
echo "## Gateway API CRD bundle version and channel annotations"
kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} {.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
echo
echo "## agentgateway proxies' own version lines"
for spec in "lab deploy/agentgateway-waypoint" "lab deploy/agentgateway-waypoint-orch" "agentgateway-system deploy/agentgateway-ingress" "agentgateway-egress deploy/agw-egress"; do
	set -- $spec
	echo "-- $1 $2"; kubectl -n "$1" logs "$2" 2>/dev/null | sed -n '/version: {/,/^}/p' | head -12
done
echo
echo "## orchestrator image package versions, read inside the running pod's image on this host"
docker run --rm --entrypoint /app/.venv/bin/python orchestrator:dev -c 'import importlib.metadata as m; print({p: m.version(p) for p in ["a2a-sdk","openai","httpx2","httpx","opentelemetry-sdk","opentelemetry-distro"]})' 2>&1
kubectl -n lab get pod -l app=orchestrator -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].imageID}{"\n"}{end}'
docker image inspect orchestrator:dev --format 'local orchestrator:dev id {{.Id}}'
} > "$D/cluster-pins.txt" 2>&1

# ---------------------------------------------------------------- Istio images and certificates
{
echo "# Istio images, the certificate lifetime settings and the workload certificates on the rebuilt cluster, read $(ts)."
echo
echo "## images, from the running workloads"
printf '   ds/ztunnel               %s\n' "$(kubectl -n istio-system get ds ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}')"
printf '   ds/istio-cni-node        %s\n' "$(kubectl -n istio-system get ds istio-cni-node -o jsonpath='{.spec.template.spec.containers[0].image}')"
printf '   deploy/istiod            %s\n' "$(kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "   ztunnel container env: $(kubectl -n istio-system get ds ztunnel -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="ISTIO_META_ENABLE_HBONE" or .name=="SECRET_TTL") | "\(.name)=\(.value)"' | tr '\n' ' ')"
echo "   istiod container env:  $(kubectl -n istio-system get deploy istiod -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="DEFAULT_WORKLOAD_CERT_TTL" or .name=="PILOT_ENABLE_AGENTGATEWAY") | "\(.name)=\(.value)"' | tr '\n' ' ')"
echo
for node in agent-mesh-lab-worker agent-mesh-lab-control-plane; do
	echo "## istioctl ztunnel-config certificates --node $node"
	istioctl ztunnel-config certificates --node "$node" 2>&1
	echo
done
echo "## leaf lifetimes, NOT AFTER minus NOT BEFORE, from the worker node's table"
istioctl ztunnel-config certificates --node agent-mesh-lab-worker 2>/dev/null | awk '$2=="Leaf" {print $1, $5, $6}' | while read -r id nb na; do
	s=$(( $(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$na" +%s) - $(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$nb" +%s) ))
	printf '   %-70s NOT BEFORE %s NOT AFTER %s span %dh%02dm\n' "$id" "$nb" "$na" $((s/3600)) $(((s%3600)/60))
done
} > "$D/certificates.txt" 2>&1

# ---------------------------------------------------------------- egress first stream
{
echo "# The egress waypoint on the rebuilt cluster, read $(ts); nothing restarted, deleted or upgraded before it."
kubectl -n agentgateway-egress get pods -o wide 2>&1
kubectl -n agentgateway-egress get pod -l gateway.networking.k8s.io/gateway-name=agw-egress -o jsonpath='{range .items[*]}restartCount={.status.containerStatuses[0].restartCount} ready={.status.containerStatuses[0].ready} started={.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}'
kubectl -n agentgateway-egress get rs 2>&1
L=$(kubectl -n agentgateway-egress logs deploy/agw-egress 2>/dev/null)
echo "lines in log:                          $(printf '%s\n' "$L" | grep -c '')"
echo "'Stream established' lines:            $(printf '%s\n' "$L" | grep -c 'Stream established')"
echo "'XDS client connection error' lines:   $(printf '%s\n' "$L" | grep -c 'XDS client connection error')"
echo "'readiness check failed' lines:        $(printf '%s\n' "$L" | grep -c 'readiness check failed')"
echo "-- controller pod labels and ztunnel's view"
kubectl -n agentgateway-system get pods --show-labels 2>&1
istioctl ztunnel-config workloads 2>&1 | awk 'NR==1 || $1=="agentgateway-system" || $1=="agentgateway-egress" || $1=="telemetry"'
} > "$D/egress-first-stream.txt" 2>&1

echo "readback written to $D at $(ts)"
