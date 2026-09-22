#!/usr/bin/env bash
# Experiment B, step B-5b: the cluster as this task leaves it, read beside cluster-before.txt, which is the cluster
# as this task FOUND it. Reads only -- every command here is a get or a log read; nothing is applied, armed, deleted
# or restarted, and no request is sent to a receiver. Written to stdout.
#
#   bash cluster-after.sh
#
# The readings are B-5a's cluster-after.sh, unchanged in what they read, with the proxy Deployments' shape kept
# because this step removes each proxy forty more times and the entry has to say what that left behind: the
# generation, the ReplicaSet history, and whether the `restartedAt` annotation B-5a's two rollout variants left on
# the templates is still there (this step runs no rollout of a proxy at all, so it can only be inherited).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
T=$(date -u +%FT%TZ)
echo "# The cluster as this task leaves it, read $T. Reads only."

echo "== $T Gateways and HTTPRoutes =="
echo "gateways: $(kubectl get gateway -A --no-headers 2>/dev/null | wc -l | tr -d ' ') ; httproutes: $(kubectl get httproute -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

echo "== $T retry stanzas: across every HTTPRoute, and per route =="
echo "kubectl get httproute -A -o yaml | grep -c 'retry:' -> $(kubectl get httproute -A -o yaml | grep -c 'retry:')"
kubectl get httproute -A -o json | jq -r '.items[] | "  \(.metadata.namespace)/\(.metadata.name) retry_stanzas=\([.spec.rules[]? | select(.retry != null)] | length)"' | sort
echo "AuthorizationPolicies: $(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

echo "== $T the mock's mode: its own control lines; an inject arms, a reset clears, the last line decides =="
CTL=$(kubectl -n lab logs deploy/mockllm --tail=-1 2>/dev/null | jq -R -c 'fromjson? | select(.ledger == "control")')
echo "control lines since the mock started: $(printf '%s\n' "$CTL" | grep -c 'ledger' || true); injects: $(printf '%s\n' "$CTL" | grep -c '/control/inject' || true); resets: $(printf '%s\n' "$CTL" | grep -c '/control/reset' || true)"
echo "the last inject: $(printf '%s\n' "$CTL" | grep '/control/inject' | tail -1)"
echo "the last line:   $(printf '%s\n' "$CTL" | tail -1)"
echo "resets after the last inject: $(printf '%s\n' "$CTL" | awk '/\/control\/inject/ {n=0; next} /\/control\/reset/ {n++} END {print n+0}')"

echo "== $T the two receivers' injectors =="
echo "  (a receiver writes no LEDGER line for a control call and holds its armed mode in process memory, so there is"
echo "   no mode to read back from it. This task armed neither receiver: its only control calls are the mock's, above."
echo "   The worker's process log, which is not a ledger, prints a line only for a close-after-read that could NOT"
echo "   take its connection or could not close it. Such lines:)"
echo "  worker log lines naming close-after-read: $(kubectl -n lab logs deploy/worker --tail=-1 2>/dev/null | grep -c 'close-after-read' || true)"

echo "== $T every Deployment in lab: env names starting MODEL_, CLIENT_, DOWNSTREAM_ or PLAN_; generation, ready =="
kubectl -n lab get deploy -o json | jq -r '.items[] | "  deploy/\(.metadata.name) generation=\(.metadata.generation) ready=\(.status.readyReplicas // 0)/\(.status.replicas // 0): \([.spec.template.spec.containers[0].env[]? | select(.name | test("^(MODEL_|CLIENT_|DOWNSTREAM_|PLAN_)")) | "\(.name)=\(.value)"] | join(" ") | if . == "" then "(none)" else . end)"'

echo "== $T the two proxies after this step's removals: Deployment shape, and the rollout annotation B-5a left =="
for g in "agentgateway-ingress/agentgateway-ingress" "agentgateway-waypoint/agw-central"; do
	gns="${g%%/*}"; gn="${g##*/}"
	echo "  deploy/$g generation=$(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.metadata.generation}') ready=$(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.status.readyReplicas}')/$(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.status.replicas}') strategy=$(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.spec.strategy.type}{" "}{.spec.strategy.rollingUpdate}') grace=$(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')"
	echo "    template annotations: $(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{.spec.template.metadata.annotations}')"
	echo "    replicasets: $(kubectl -n "$gns" get rs -l "gateway.networking.k8s.io/gateway-name=$gn" -o jsonpath='{range .items[*]}{.metadata.name}=desired{.spec.replicas}/ready{.status.readyReplicas}; {end}')"
	echo "    Gateway Programmed=$(kubectl -n "$gns" get gateway "$gn" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}') address=$(kubectl -n "$gns" get gateway "$gn" -o jsonpath='{.status.addresses[0].value}')"
	echo "    the proxy's own drain settings, printed by the running pod at startup:"
	kubectl -n "$gns" logs "deploy/$gn" --tail=-1 2>/dev/null | grep -E '^(terminationM(in|ax)Deadline|numWorkerThreads):' | sed 's/^/      /'
	echo "    env the deployer set: $(kubectl -n "$gns" get deploy "$gn" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="TERMINATION_GRACE_PERIOD_SECONDS")]}TERMINATION_GRACE_PERIOD_SECONDS={.value}{end}{" "}{range .spec.template.spec.containers[0].env[?(@.name=="CONNECTION_MIN_TERMINATION_DEADLINE")]}CONNECTION_MIN_TERMINATION_DEADLINE={.value}{end}')"
done

echo "== $T pods: every namespace, phase counts; pods neither Running nor Succeeded; control pods left =="
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | awk '{printf "  %s=%s\n", $2, $1}'
echo "pods neither Running nor Completed: $(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' | wc -l | tr -d ' ')"
echo "pods of a curl image (the scripts' control pods): $(kubectl get pods -A -o json | jq '[.items[] | select(.spec.containers[0].image | test("curl"))] | length')"
echo "loadgen Jobs left in lab (each a finished single send, kept for its pod log): $(kubectl -n lab get jobs --no-headers 2>/dev/null | wc -l | tr -d ' ')"
kubectl -n lab get pods -l 'app in (worker,orchestrator,mockllm)' --no-headers -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,START:.status.startTime' 2>/dev/null

echo "== $T helm releases =="
helm list -A -o json 2>/dev/null | jq -r '.[] | "  \(.name)\t\(.namespace)\t\(.status)\t\(.chart)"' | expand -t 24

echo "== $T ztunnel's certificates, worker node =="
PATH="${TMPDIR%/}/b4/tools/istioctl-1.31.0:$PATH" istioctl ztunnel-config certificates --node agent-mesh-lab-worker 2>&1
