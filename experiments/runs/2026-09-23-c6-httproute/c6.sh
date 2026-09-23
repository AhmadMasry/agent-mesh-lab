#!/usr/bin/env bash
# Experiment C, step C-6: apply and remove overlay-c6 and read the route layer. The sends are sends.sh's.
#   c6.sh apply | remove            kubectl apply -k / delete -k overlay-c6
#   c6.sh read <label> <since>      readings, each through rec, into readings-<label>.txt: every HTTPRoute with its
#                                   status, the retry stanzas, the AuthorizationPolicies, agentgateway's controller log
#                                   and the ingress's non-request log lines since <since>, and the ingress's own
#                                   /config_dump (its routes: name, hostnames, matches, backends)
# Reads and the two kubectl calls only; nothing is sent to a receiver. Keep-awake: starts none, changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
RUNREL="${RUNREL:?RUNREL is required}"
D="experiments/runs/$RUNREL"
ts() { date -u +%FT%TZ; }
rec() { local f="$1"; shift; { printf '\n# read %s\n$ %s\n' "$(ts)" "$*"; bash -c "$*" 2>&1; printf '# exit %s\n' "$?"; } >> "$f"; }
case "${1:-}" in
apply | remove)
	verb=apply; [ "$1" = remove ] && verb=delete
	echo "$(ts) $verb -k overlay-c6" | tee -a "$D/phases.txt"
	rec "$D/$1.txt" "kubectl $verb -k $D/overlay-c6"
	echo "$(ts) $verb done" | tee -a "$D/phases.txt"
	;;
read)
	label="${2:?label}"; since="${3:?since}"; f="$D/readings-$label.txt"
	rec "$f" "kubectl get httproute -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) hostnames=\\(.spec.hostnames // [] | join(\",\")) rules=\\([.spec.rules[] | {matches: (.matches // []), backends: ([.backendRefs[]?.name])}] | tostring) status=\\([.status.parents[]? | .conditions[]? | \"\\(.type)=\\(.status)/\\(.reason)\"] | join(\",\"))\"'"
	rec "$f" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	rec "$f" "kubectl get authorizationpolicy -A --no-headers | wc -l"
	rec "$f" "kubectl get agentgatewaypolicy -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) authorization=\\(.spec.traffic.authorization != null)\"'"
	rec "$f" "kubectl -n agentgateway-system logs deploy/agentgateway --since-time=$since"
	rec "$f" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$since | grep -v 'request gateway='"
	PORT=15995
	kubectl -n agentgateway-ingress port-forward deploy/agentgateway-ingress "$PORT:15000" >/dev/null 2>&1 &
	pf=$!
	for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
	curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$PORT/config_dump" -o "$D/config-dump-ingress-$label.json"
	kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
	rec "$f" "jq -r '[.. | objects | select(has(\"matches\") and has(\"backends\"))] | .[] | \"route key=\\(.key // .name | tostring) hostnames=\\(.hostnames|tostring) matches=\\(.matches|tostring|.[0:300]) backends=\\(.backends|tostring|.[0:200])\"' $D/config-dump-ingress-$label.json"
	rec "$f" "jq -c '[.. | objects | select(.kind? == \"HTTPRoute\" and has(\"key\"))] | .[] | {key, hostnames, matches, backends}' $D/config-dump-ingress-$label.json"
	rec "$f" "wc -c < $D/config-dump-ingress-$label.json; shasum -a 256 $D/config-dump-ingress-$label.json"
	echo "$(ts) read $label -> $f" | tee -a "$D/phases.txt"
	;;
*) echo "usage: c6.sh apply|remove|read <label> <since>" >&2; exit 1 ;;
esac
