#!/usr/bin/env bash
# Follow-ups 12: the orchestrator's agent card as a client in lab reads it, directly from the orchestrator Service and
# through the agentgateway ingress, and the interface URL it advertises. One GET each, curl --retry 0. The client pod
# is ztunnel-captured (lab is enrolled), carries the lab's non-root securityContext, and is removed afterwards.
# $1 = output file.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
OUT="$1"; NS=lab; POD=card-read; IMAGE=curlimages/curl:8.22.0
OVERRIDES='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"fsGroup":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"card-read","image":"curlimages/curl:8.22.0","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'
{
echo "# The orchestrator's agent card, read from $NS/$POD at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n "$NS" run "$POD" --image="$IMAGE" --restart=Never --overrides="$OVERRIDES" --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
for url in http://orchestrator.lab.svc.cluster.local:8080/.well-known/agent-card.json http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local/.well-known/agent-card.json; do
	echo
	echo "## GET $url"
	body=$(kubectl -n "$NS" exec "$POD" -- curl -sS --retry 0 --max-time 10 -w '\n%{http_code}' "$url" 2>&1); rc=$?
	code=$(printf '%s\n' "$body" | tail -1); json=$(printf '%s\n' "$body" | sed '$d')
	echo "   curl exit=$rc http_code=$code"
	echo "   every string field ending in url or URL, with its path:"
	printf '%s' "$json" | jq -r 'paths(scalars) as $p | select(($p[-1]|tostring) | test("url$"; "i")) | "      \($p | map(tostring) | join(".")) = \(getpath($p))"' 2>&1
	echo "   sha256 of the body: $(printf '%s' "$json" | shasum -a 256 | cut -c1-16)"
done
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
echo
echo "# $POD removed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT" 2>&1
cat "$OUT"
