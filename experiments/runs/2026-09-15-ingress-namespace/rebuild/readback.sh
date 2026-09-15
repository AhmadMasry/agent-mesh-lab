#!/usr/bin/env bash
# Follow-ups 12: read the rebuilt cluster back. Read-only (get/logs/istioctl reads/helm list); nothing created,
# changed, restarted or deleted. Writes into the directory given as $1. Copied from
# experiments/runs/2026-09-15-helm-only/rebuild/readback.sh (followups-11) with these changes only: the header
# texts; the mesh-shape reading adds the dataplane label of the two agentgateway namespaces' pods, a per-row
# summary of the ztunnel workload table for the rows this task's brief names, the Gateways' Programmed
# condition, the HTTPRoutes' parent status and the AgentgatewayPolicies' status; and an attachment file.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
D="$1"; mkdir -p "$D"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- helm releases
{
echo "# Helm releases on the rebuilt cluster, read $(ts), against the chart pins in the Makefile at HEAD."
echo
echo "## helm list -A"; helm list -A 2>&1
echo
echo "## each release against its pin"
mk() { sed -n "s/^$1[[:space:]]*:= *//p" Makefile; }
IV=$(mk ISTIO_CHART_VERSION); AV=$(mk AGENTGATEWAY_CHART_VERSION); OV=$(mk OTEL_COLLECTOR_CHART_VERSION); JV=$(mk JAEGER_CHART_VERSION); PV=$(mk PROMETHEUS_CHART_VERSION)
n=0; ok=0
while read -r rel ns chart; do
	n=$((n+1))
	got=$(helm list -A -o json | jq -r --arg r "$rel" --arg ns "$ns" '.[] | select(.name==$r and .namespace==$ns) | "\(.chart) \(.status)"')
	res=$([ "$got" = "$chart deployed" ] && echo same || echo DIFFERENT)
	[ "$res" = same ] && ok=$((ok+1))
	printf '   %-18s %-20s expected %-38s got %-44s %s\n' "$rel" "$ns" "$chart deployed" "${got:-<absent>}" "$res"
done <<LIST
istio-base istio-system base-$IV
istiod istio-system istiod-$IV
istio-cni istio-system cni-$IV
ztunnel istio-system ztunnel-$IV
agentgateway-crds agentgateway-system agentgateway-crds-$AV
agentgateway agentgateway-system agentgateway-$AV
otel-collector telemetry opentelemetry-collector-$OV
jaeger telemetry jaeger-$JV
prometheus telemetry prometheus-$PV
LIST
echo "   releases expected $n; at the pin and deployed $ok; releases listed $(helm list -A -o json | jq length)"
} > "$D/helm-releases.txt" 2>&1

# ---------------------------------------------------------------- Istio images, env, mesh config, certificates
{
echo "# Istio on the rebuilt cluster, read $(ts): images, the settings the retired route carried, the mesh"
echo "# ConfigMap, and the workload certificates."
echo
echo "## istioctl version (client, control plane, data plane)"; istioctl version 2>&1
echo
echo "## images, from the running workloads (spec image, then the imageID the kubelet resolved)"
for spec in "ds ztunnel" "ds istio-cni-node" "deploy istiod"; do
	set -- $spec
	printf '   %-6s %-16s %s\n' "$1" "$2" "$(kubectl -n istio-system get "$1" "$2" -o jsonpath='{.spec.template.spec.containers[0].image}')"
done
kubectl -n istio-system get pods -o json | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[] | "   \($p)  \(.image)  \(.imageID)"'
echo
echo "## the container env the retired route's settings reach"
echo "   ztunnel: $(kubectl -n istio-system get ds ztunnel -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="ISTIO_META_ENABLE_HBONE" or .name=="SECRET_TTL") | "\(.name)=\(.value)"' | tr '\n' ' ')"
echo "   istiod:  $(kubectl -n istio-system get deploy istiod -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="DEFAULT_WORKLOAD_CERT_TTL" or .name=="PILOT_ENABLE_AGENTGATEWAY") | "\(.name)=\(.value)"' | tr '\n' ' ')"
echo
echo "## mesh ConfigMap istio-system/istio, data.mesh"
kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' 2>&1
echo
echo "## the provider and the flag, read out of data.mesh with yq"
kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' | yq -o=json '{"enableTracing": .enableTracing, "extensionProviders": .extensionProviders}' 2>&1
echo
for node in agent-mesh-lab-worker agent-mesh-lab-control-plane; do
	echo "## istioctl ztunnel-config certificates --node $node"
	istioctl ztunnel-config certificates --node "$node" 2>&1
	echo
done
echo "## leaf lifetimes, NOT AFTER minus NOT BEFORE, from the worker node's table"
istioctl ztunnel-config certificates --node agent-mesh-lab-worker 2>/dev/null | awk '$2=="Leaf" {print $1, $4, $6, $7}' | while read -r id valid na nb; do
	s=$(( $(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$na" +%s) - $(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$nb" +%s) ))
	printf '   %-70s VALID %s NOT BEFORE %s NOT AFTER %s span %dh%02dm\n' "$id" "$valid" "$nb" "$na" $((s/3600)) $(((s%3600)/60))
done
echo
echo "## ztunnel pods' start times (issuance is read forward from these)"
kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}'
} > "$D/istio.txt" 2>&1

# ---------------------------------------------------------------- mesh shape
{
echo "# The mTLS shape, the mesh membership and the waypoint tracing route on the rebuilt cluster, read $(ts). Read-only."
echo
echo "## PeerAuthentication"; kubectl get peerauthentication -A -o yaml 2>&1 | yq '.items[] | {"ns": .metadata.namespace, "name": .metadata.name, "spec": .spec}' 2>&1
echo
echo "## namespace dataplane labels"; kubectl get ns -L istio.io/dataplane-mode 2>&1
echo
echo "## pods carrying the label istio.io/dataplane-mode (namespace, pod, value; pods without the label are not listed)"
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.labels["istio.io/dataplane-mode"] != null) | [.metadata.namespace, .metadata.name, .metadata.labels["istio.io/dataplane-mode"]] | @tsv' | column -t
echo
echo "## istioctl ztunnel-config workloads"; istioctl ztunnel-config workloads 2>&1
echo
echo "## the ztunnel workload table, the rows this task names (namespace, pod, protocol)"
istioctl ztunnel-config workloads 2>/dev/null | awk 'NR>1 && ($1=="agentgateway-ingress" || $1=="agentgateway-system" || $1=="agentgateway-egress" || $1=="lab" || $1=="telemetry") {print "   " $1, $2, $NF}' | column -t
echo
echo "## every pod in agentgateway-system and agentgateway-ingress with all its labels"
for ns in agentgateway-system agentgateway-ingress; do
	kubectl -n "$ns" get pods -o json | jq -r '.items[] | "   \(.metadata.namespace)/\(.metadata.name) restarts=\([.status.containerStatuses[].restartCount] | add) labels=\(.metadata.labels | tostring)"'
done
echo
echo "## the waypoint Gateways' parametersRef"
kubectl get gateway -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) class=\(.spec.gatewayClassName) parametersRef=\(.spec.infrastructure.parametersRef // "none" | tostring)"'
} > "$D/mesh-shape.txt" 2>&1

# ---------------------------------------------------------------- attachment
{
echo "# Gateways, routes and policies on the rebuilt cluster, as their status reads, $(ts). Read-only."
echo
echo "## Gateways: Accepted and Programmed"
kubectl get gateway -A -o json | jq -r '.items[] | "   \(.metadata.namespace)/\(.metadata.name) class=\(.spec.gatewayClassName) " + ([.status.conditions[]? | select(.type=="Accepted" or .type=="Programmed") | "\(.type)=\(.status) (\(.reason))"] | join(" ")) + " addresses=" + ([.status.addresses[]?.value] | join(","))'
echo
echo "## HTTPRoutes: each parent's Accepted and ResolvedRefs, as the controller that holds the parent writes them"
kubectl get httproute -A -o json | jq -r '.items[] | .metadata as $m | .status.parents[]? | "   \($m.namespace)/\($m.name) parent=\(.parentRef.namespace // $m.namespace)/\(.parentRef.name) controller=\(.controllerName) " + ([.conditions[] | select(.type=="Accepted" or .type=="ResolvedRefs") | "\(.type)=\(.status) (\(.reason))"] | join(" "))'
echo
echo "## AgentgatewayPolicies: status, whole"
kubectl get agentgatewaypolicies.agentgateway.dev -A -o json | jq -r '.items[] | "   \(.metadata.namespace)/\(.metadata.name) targets=\([.spec.targetRefs[] | .name] | join(",")) status=\(.status | tostring)"'
echo
echo "## PeerAuthentication agentgateway-ingress-metrics and the pods its selector matches"
kubectl get peerauthentication -A -o json | jq -r '.items[] | select(.metadata.name=="agentgateway-ingress-metrics") | "   \(.metadata.namespace)/\(.metadata.name) selector=\(.spec.selector.matchLabels | tostring)"'
kubectl get pods -A -l gateway.networking.k8s.io/gateway-name=agentgateway-ingress -o jsonpath='{range .items[*]}   {.metadata.namespace}/{.metadata.name}{"\n"}{end}'
echo
echo "## the orchestrator Deployment's PUBLIC_URL (what its card advertises)"
kubectl -n lab get deploy orchestrator -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="PUBLIC_URL") | "   PUBLIC_URL=\(.value)"'
echo
echo "## Services named agentgateway-ingress"
kubectl get svc -A --field-selector metadata.name=agentgateway-ingress 2>&1
} > "$D/attachment.txt" 2>&1

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
} > "$D/egress-first-stream.txt" 2>&1

echo "readback written to $D at $(ts)"
