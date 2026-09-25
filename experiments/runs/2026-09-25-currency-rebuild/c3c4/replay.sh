#!/usr/bin/env bash
# The currency pass of 2026-09-25: C-3 and C-4 re-counted, replaying the steps the entries "Experiment C / go
# receiver / C-3, ztunnel L4" and "C-4, ztunnel given an HTTP rule" record (experiments/runs/2026-09-21-c3-c4-ztunnel/
# phases.txt and the commands its reading files hold), in their order, with the same objects:
#   P0     no policy: send-one direct, send-one ingress
#   C3     kubectl apply -k overlay-c3 (the waypoint page's "allow only the waypoint's identity" on app=worker), wait on
#          ztunnel holding it; readings; one work item through agw-central by gate2-single-clean.sh; send-one direct;
#          send-one ingress; readings; then, at the original's offset from the apply (12 min 57 s), the second ingress
#          send (c34-c3-ingress-2)
#   C4     kubectl apply -k overlay-c4 (C-3's policy plus to.operation.methods GET), readings; send-one service, direct,
#          ingress; readings
#   remove kubectl delete -k overlay-c4; readings
#   after  send-one direct, send-one ingress; gate2-single-clean.sh
# The overlays are byte copies of the originals (diff -r: identical). send-one.sh, counts.sh and proxy-spans.sh are
# copies with R changed to this directory (their headers say so); rec.sh and gate2-single-clean.sh run unedited.
# The readings keep the originals' commands; where the original grepped for one run's pod IP, port or trace id, this
# replay keeps the whole window's lines (the same command without that grep), so nothing is filtered by a guess.
# No retry anywhere: every send is one curl --retry 0 or one load-client Job. Every wait is on a state, bounded, or on
# the clock to reproduce the original's offset. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/cur/tools/istioctl-1.31.1:$PATH"; export PATH
N=experiments/runs/2026-09-25-currency-rebuild/c3c4
REC=experiments/runs/2026-09-21-c3-c4-ztunnel/rec.sh
PH="$N/phases.txt"
ts() { date -u +%FT%TZ; }
ph() { echo "$1 $(ts)" | tee -a "$PH"; }
node=agent-mesh-lab-worker
istiod() { kubectl -n istio-system get pod -l app=istiod -o jsonpath='{.items[0].metadata.name}'; }
ztw() { kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}'; }
wait_zt() { # $1 present|absent
	local i=0 has
	while [ $i -lt 60 ]; do
		has=$(istioctl ztunnel-config policy --node $node -o json 2>/dev/null | jq '[.[] | select(.name=="require-agw-central")] | length')
		if { [ "$1" = present ] && [ "${has:-0}" -ge 1 ]; } || { [ "$1" = absent ] && [ "${has:-0}" = 0 ]; }; then echo "ztunnel $1 after ${i}s"; return 0; fi
		perl -e 'select(undef,undef,undef,1)'; i=$((i+1))
	done; echo "ztunnel not $1 after 60 s"; return 1
}
echo "$(ts) replay start; HEAD $(git rev-parse HEAD); istioctl $(istioctl version --remote=false)" | tee -a "$PH"
bash "$REC" "$N/start-state.txt" "kubectl get authorizationpolicy -A; kubectl get peerauthentication -A; kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"

ph "P0 start"
bash "$N/send-one.sh" p0-nopolicy direct c34-p0-direct
bash "$N/send-one.sh" p0-nopolicy ingress c34-p0-ingress
ph "P0 end"

A=$(ts); ph "C3 apply"
bash "$REC" "$N/c3-policy.txt" "kubectl apply -k $N/overlay-c3"
APPLY_EPOCH=$(date +%s)
wait_zt present | tee -a "$PH"
bash "$REC" "$N/c3-policy.txt" "kubectl get authorizationpolicy -A"
bash "$REC" "$N/c3-policy.txt" "istioctl ztunnel-config policy --node $node -o json"
bash "$REC" "$N/c3-policy.txt" "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
ph "C3 sends start"
RUN_ID=c3 RUN_ITEM=2026-09-25-currency-rebuild/c3c4 bash experiments/gate2-single-clean.sh > "$N/g2c-c3-driver.txt" 2>&1; echo "gate2-single-clean exit=$?" | tee -a "$PH"
bash "$N/send-one.sh" c3-l4 direct c34-c3-direct
bash "$N/send-one.sh" c3-l4 ingress c34-c3-ingress
ph "C3 sends end"
bash "$REC" "$N/c3-istiod.txt" "kubectl -n istio-system logs $(istiod) --since-time=$A"
bash "$REC" "$N/c3-ztunnel.txt" "kubectl -n istio-system get pods -l app=ztunnel -o wide"
bash "$REC" "$N/c3-ztunnel.txt" "kubectl -n istio-system logs $(ztw) --since-time=$A"
bash "$REC" "$N/c3-ztunnel-connections.txt" "istioctl ztunnel-config connections --node $node -o json"
bash "$REC" "$N/c3-proxies.txt" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$A | grep 'route=lab/worker'"
bash "$REC" "$N/c3-proxies.txt" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$A | grep 'route=lab/worker-ingress'"
T=$((APPLY_EPOCH + 777)); echo "$(ts) waiting for the original's offset of the second ingress send, 777 s after the apply" | tee -a "$PH"
while [ "$(date +%s)" -lt "$T" ]; do perl -e 'select(undef,undef,undef,1)'; done
ph "C3 ingress-2 start"
bash "$N/send-one.sh" c3-l4 ingress c34-c3-ingress-2
ph "C3 ingress-2 end"
B=$(ts); bash "$REC" "$N/c3-proxies.txt" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$A | grep 'route=lab/worker-ingress'"

ph "C4 apply"
bash "$REC" "$N/c4-policy.txt" "kubectl apply -k $N/overlay-c4"
i=0; while [ $i -lt 60 ]; do g=$(kubectl -n lab get authorizationpolicy require-agw-central -o jsonpath='{.status.conditions[0].observedGeneration}' 2>/dev/null); [ "$g" = 2 ] && break; perl -e 'select(undef,undef,undef,1)'; i=$((i+1)); done; echo "observedGeneration=$g after ${i}s" | tee -a "$PH"
bash "$REC" "$N/c4-policy.txt" "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
bash "$REC" "$N/c4-policy.txt" "istioctl ztunnel-config policy --node $node -o json | jq '.[] | select(.name==\"require-agw-central\")'"
ph "C4 sends start"
bash "$N/send-one.sh" c4-l7rule service c34-c4-service
bash "$N/send-one.sh" c4-l7rule direct c34-c4-direct
bash "$N/send-one.sh" c4-l7rule ingress c34-c4-ingress
ph "C4 sends end"
bash "$REC" "$N/c4-istiod.txt" "kubectl -n istio-system logs $(istiod) --since-time=$B"
bash "$REC" "$N/c4-ztunnel.txt" "kubectl -n istio-system logs $(ztw) --since-time=$B"
bash "$REC" "$N/c4-proxies.txt" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$B | grep 'route=lab/worker'"
bash "$REC" "$N/c4-proxies.txt" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$B | grep 'route=lab/worker-ingress'"

ph "remove"
bash "$REC" "$N/removal.txt" "kubectl delete -k $N/overlay-c4"
wait_zt absent | tee -a "$PH"
bash "$REC" "$N/removal.txt" "kubectl get authorizationpolicy -A"
bash "$REC" "$N/removal.txt" "istioctl ztunnel-config policy --node agent-mesh-lab-worker -o json | jq -c '.[] | {name,namespace,action}'"
bash "$REC" "$N/removal.txt" "istioctl ztunnel-config policy --node agent-mesh-lab-control-plane -o json | jq -c '.[] | {name,namespace,action}'"
bash "$REC" "$N/removal.txt" "kubectl get peerauthentication -A"
bash "$REC" "$N/removal.txt" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"

ph "after sends start"
bash "$N/send-one.sh" after-removal direct c34-after-direct
bash "$N/send-one.sh" after-removal ingress c34-after-ingress
RUN_ID=c34after RUN_ITEM=2026-09-25-currency-rebuild/c3c4/after bash experiments/gate2-single-clean.sh > "$N/g2c-after-driver.txt" 2>&1; echo "gate2-single-clean exit=$?" | tee -a "$PH"
ph "after sends end"
bash "$N/counts.sh" > "$N/counts.csv" 2> "$N/counts-stderr.txt"; echo "counts exit=$?" | tee -a "$PH"
echo "$(ts) replay end" | tee -a "$PH"
