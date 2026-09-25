#!/usr/bin/env bash
# The currency pass of 2026-09-25: C-3R (c3r) or C-3R2 (c3r2) re-counted, replaying the steps their records hold
# (phases.txt and the commands in start-state.txt, objects-created.txt, server-and-client.txt, window.txt,
# objects-deleted.txt and versions.txt of experiments/runs/2026-09-21-c3r-open-connections/ and
# experiments/runs/2026-09-21-c3r2-public-server/), in their order:
#   start-state readings; the throwaway objects created and waited on; (c3r2: server and client read); the seven
#   repetitions none-1, selector-1, namespace-1, selector-2, namespace-2, selector-3, namespace-3, each ONE run of the
#   copied rep.sh; the window readings; the objects deleted (c3r2: the image removed from the worker node, as recorded);
#   one clean work item by gate2-single-clean.sh; versions; counts.py.
# The per-directory copies: rep.sh with R changed (its header says so); objects/, rec.sh, responses.py and counts.py
# byte copies, but for c3r's objects/server.yaml, whose image line is today's deploy/worker reference, read the way
# the original read its own ("the worker image exactly as the lab runs it"). Where the original's readings named one
# day's istiod or ztunnel pod, this replay names the pods running now.
#   bash c3r-replay.sh c3r|c3r2
# No retry: rep.sh's sends are nc (no retry) and one curl --retry 0. Keep-awake: this script starts none and changes no
# power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/cur/tools/istioctl-1.31.1:$PATH"; export PATH
K="${1:?c3r|c3r2}"; case "$K" in c3r) NS=c3r ;; c3r2) NS=repro ;; *) exit 2 ;; esac
N=experiments/runs/2026-09-25-currency-rebuild/$K
REC="$N/rec.sh"; PH="$N/phases.txt"
ts() { date -u +%FT%TZ; }
ph() { echo "$(ts) $*" | tee -a "$PH"; }
istiod=$(kubectl -n istio-system get pod -l app=istiod -o jsonpath='{.items[0].metadata.name}')
ztw=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
ztc=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-control-plane -o jsonpath='{.items[0].metadata.name}')
ph "$K replay start; HEAD $(git rev-parse HEAD); istioctl $(istioctl version --remote=false); istiod $istiod; ztunnel worker $ztw, control-plane $ztc"
f="$N/start-state.txt"
for c in "kubectl get authorizationpolicy -A" "kubectl get peerauthentication -A" \
	"kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'" "kubectl get httproute -A" \
	"kubectl get ns --show-labels" "kubectl -n istio-system get pods -l app=ztunnel -o wide" \
	"istioctl ztunnel-config policy --node agent-mesh-lab-worker -o json | jq -c '.[] | {name,namespace,scope,action}'" \
	"istioctl ztunnel-config policy --node agent-mesh-lab-control-plane -o json | jq -c '.[] | {name,namespace,scope,action}'" \
	"kubectl get nodes -o wide; kubectl describe node agent-mesh-lab-control-plane | grep -i -A2 taints" "kubectl -n lab get pods -o wide"; do bash "$REC" "$f" "$c"; done
W=$(ts); ph "throwaway objects create"
f="$N/objects-created.txt"
if [ "$K" = c3r ]; then
	bash "$REC" "$f" "kubectl apply -f $N/objects/namespace.yaml"
	bash "$REC" "$f" "kubectl apply -f $N/objects/server.yaml -f $N/objects/client.yaml"
	bash "$REC" "$f" "kubectl -n c3r wait --for=condition=Available deploy/c3r-server --timeout=120s && kubectl -n c3r wait --for=condition=Ready pod/c3r-client --timeout=120s"
else
	bash "$REC" "$f" "kubectl apply -f $N/objects/setup.yaml"
	bash "$REC" "$f" "kubectl -n repro wait --for=condition=Available deploy/server --timeout=180s && kubectl -n repro wait --for=condition=Ready pod/client --timeout=180s"
fi
bash "$REC" "$f" "kubectl -n $NS get pods -o wide"
bash "$REC" "$f" "kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.serviceAccountName}{\" \"}{.metadata.annotations.ambient\\.istio\\.io/redirection}{\" \"}{.status.containerStatuses[0].imageID}{\"\\n\"}{end}'"
if [ "$K" = c3r2 ]; then
	f="$N/server-and-client.txt"
	bash "$REC" "$f" "kubectl -n repro exec deploy/server -- sh -c 'nginx -v 2>&1; id; nginx -T 2>&1 | grep -n -E \"^# configuration file|listen|keepalive\"'"
	bash "$REC" "$f" "istioctl ztunnel-config workloads --node agent-mesh-lab-worker -o json | jq -c '.[] | select(.namespace==\"repro\") | {name,namespace,serviceAccount,protocol,authorizationPolicies}'"
fi
# c3r2: each repetition starts at the original's recorded offset from its none-1 start (by the controller's ruling after
# attempt 1, which used a 2 s gap), derived from the millisecond stamp on the first line of each repetition's events.txt
# in experiments/runs/2026-09-21-c3r2-public-server/: none-1 20:19:04.067Z, selector-1 +11.297 s, namespace-1 +63.070 s,
# selector-2 +100.742 s, namespace-2 +102.778 s, selector-3 +124.522 s, namespace-3 +126.613 s. c3r runs back to back,
# as it did (its record names the 0.4 s start of selector-1 after none-1, where the original left 39 s).
T0=""
for ro in none-1:0 selector-1:11.297 namespace-1:63.070 selector-2:100.742 namespace-2:102.778 selector-3:124.522 namespace-3:126.613; do
	r=${ro%%:*}; off=${ro##*:}
	if [ "$K" = c3r2 ]; then
		[ -n "$T0" ] || T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
		perl -MTime::HiRes=time,sleep -e '$t='"$T0"'+'"$off"'; while (time < $t) { sleep(0.005) }'
	fi
	ph "rep $r start (offset ${off} s)"; bash "$N/rep.sh" "${r%-*}" "${r##*-}" > "$N/rep-$r-driver.txt" 2>&1; ph "rep $r end exit=$?"
done
f="$N/window.txt"
if [ "$K" = c3r ]; then bash "$REC" "$f" "kubectl -n c3r logs deploy/c3r-server"; else bash "$REC" "$f" "kubectl -n repro logs deploy/server --timestamps --since-time=$W"; fi
bash "$REC" "$f" "kubectl -n $NS get pods -o wide"
bash "$REC" "$f" "kubectl -n istio-system logs $istiod --since-time=$W | grep -E '$NS'"
bash "$REC" "$f" "kubectl -n istio-system logs $istiod --since-time=$W | awk -F'\t' '\$2 == \"warn\" || \$2 == \"error\"' | wc -l"
bash "$REC" "$f" "kubectl -n istio-system logs $ztw --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
bash "$REC" "$f" "kubectl -n istio-system logs $ztw --since-time=$W | awk -F'\t' '\$2 == \"warn\"' | wc -l"
bash "$REC" "$f" "kubectl -n istio-system logs $ztc --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
ph "throwaway objects delete"
f="$N/objects-deleted.txt"
if [ "$K" = c3r ]; then
	bash "$REC" "$f" "kubectl delete -f $N/objects/client.yaml -f $N/objects/server.yaml --wait=true"
	bash "$REC" "$f" "kubectl delete -f $N/objects/namespace.yaml --wait=true --timeout=180s"
else
	bash "$REC" "$f" "kubectl delete -f $N/objects/setup.yaml --wait=true --timeout=180s"
fi
for c in "kubectl get ns $NS" "kubectl get all,authorizationpolicy -n $NS" "kubectl get authorizationpolicy -A" "kubectl get peerauthentication -A" \
	"kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'" \
	"istioctl ztunnel-config policy --node agent-mesh-lab-worker -o json | jq -c '.[] | {name,namespace,scope,action}'" \
	"istioctl ztunnel-config policy --node agent-mesh-lab-control-plane -o json | jq -c '.[] | {name,namespace,scope,action}'" \
	"istioctl ztunnel-config workloads --node agent-mesh-lab-worker -o json | jq '[.[] | select(.namespace == \"$NS\")] | length'" \
	"kubectl get ns --show-labels"; do bash "$REC" "$f" "$c"; done
if [ "$K" = c3r2 ]; then
	bash "$REC" "$f" "docker exec agent-mesh-lab-worker crictl rmi docker.io/nginxinc/nginx-unprivileged@sha256:0918d093d6088225655ddf602fdf00679c1c0c9a89c01c6dcdce5ee5e6c2f3f3"
	bash "$REC" "$f" "for n in agent-mesh-lab-control-plane agent-mesh-lab-worker; do printf '%s nginx images: ' \$n; docker exec \$n crictl images | grep -c nginx; done"
fi
ph "after: gate2-single-clean"
RUN_ID=${K}after RUN_ITEM=2026-09-25-currency-rebuild/$K/after bash experiments/gate2-single-clean.sh > "$N/after-driver.txt" 2>&1; ph "gate2-single-clean exit=$?"
f="$N/versions.txt"
bash "$REC" "$f" "kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].imageID}{\"\\n\"}{end}'"
bash "$REC" "$f" "istioctl version"
python3 "$N/counts.py" > "$N/counts-driver.txt" 2>&1; ph "counts.py exit=$?"
ph "$K replay end"
