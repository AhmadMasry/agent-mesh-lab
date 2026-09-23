#!/usr/bin/env bash
# Experiment C, step C-9: the controller's ruling (b) and its one bounded probe, read-only, on the cluster rebuilt with
# the A2A marking. GETs only: each agent card by every path a client of this lab uses, one GET each, from a curl pod
# in lab (the same image and the same four paths as c9.sh's card readings), then ONE card GET through agw-central at
# the worker's Service address carrying X-Forwarded-Proto: http. Each raw response (headers and body) is kept, with
# both proxies' access lines in its own window. Every curl --retry 0; nothing is re-sent; nothing but a GET is sent.
#   bash cards.sh <out dir>
# Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
OUT="${1:?out dir}"
mkdir -p "$OUT"
NS=lab POD=c9-cards CURL_IMAGE=curlimages/curl:8.22.0
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
WORKER_URL=http://worker.lab.svc.cluster.local:8080
ORCH_URL=http://orchestrator.lab.svc.cluster.local:8080
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
trap 'kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null || { echo "curl pod not ready"; exit 1; }
echo "$(ts) curl pod $POD ip=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')" | tee -a "$OUT/cards.txt"
card() { # $1 name, $2 base url, then extra curl args
	local name="$1" url="$2"; shift 2
	local w="$OUT/$name" since rc code
	mkdir -p "$w"; since=$(tsn)
	kubectl -n "$NS" exec "$POD" -- curl -sS -D - --retry 0 --max-time 10 "$@" "$url/.well-known/agent-card.json" > "$w/response.txt" 2> "$w/curl-stderr.txt"
	rc=$?
	code=$(head -1 "$w/response.txt" | awk '{print $2}')
	awk 'BEGIN{b=0} b{print} /^\r?$/{b=1}' "$w/response.txt" > "$w/card.json"
	jq -S . "$w/card.json" > "$w/card.pretty.json" 2>/dev/null || true
	sleep 1
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$w/agw-central-access.txt" || true
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$w/ingress-access.txt" || true
	echo "$since card $name url=$url/.well-known/agent-card.json extra=[$*] http=$code exit=$rc interfaces=$(jq -c '[.supportedInterfaces[]? | .url]' "$w/card.json" 2>/dev/null) content-length=$(grep -i '^content-length:' "$w/response.txt" | tr -d '\r' | awk '{print $2}')" | tee -a "$OUT/cards.txt"
}
card go-ingress "$INGRESS" -H "Host: worker.lab.internal"
card go-central "$WORKER_URL"
card py-central "$ORCH_URL"
card py-ingress "$INGRESS"
card probe-go-central-xfp-http "$WORKER_URL" -H "X-Forwarded-Proto: http"
echo "$(ts) done" | tee -a "$OUT/cards.txt"
