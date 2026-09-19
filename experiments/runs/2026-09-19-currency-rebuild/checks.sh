#!/usr/bin/env bash
# Follow-ups 19, task 3: the readings on the rebuilt cluster, in order, each step stamped.
# Part one is the standard proof, every reading the last proof took, in its order (clean check; trace REPS=2 with
# dangling parents and the GenAI summary; Prometheus targets; STRICT posture, the plaintext probe against both
# receivers, every ztunnel series -> the hops table; both proxies' config dumps; the cluster facts). Part two is
# what this proof adds because it carries a currency pass and follow-ups 19 task 2's code: (a) the pins read back
# from the cluster, (b) the A2A-Version header per SDK, (c) rule 4 as the running pods record it, (d) Jaeger
# 2.21.0's API, (e) the mock's span on an injected close, live, for `close` and `delay-then-close`, (g) the image
# scan. Reading (f), the exporter's columns, is a host-side count over part one's two trace work items and is
# taken after this script. The retry knobs come LAST, as in the last proof, and end at zero stanzas. Part three,
# reading (h), the worker's own close-after-read span, was asked for by the controller after the knobs had been
# read once; it ran next, and the knobs were then read a second time so that they are last again.
# Part two comes after part one so that the ztunnel series of part one hold what the last proof's held: the clean
# check, the trace and the probe, and no other traffic.
# Committed scripts are run unedited; nothing on the cluster is edited, restarted or deleted by hand. What the
# committed scripts themselves do to the cluster: the clean check, the trace, the wire-version script and the
# matrix row create and remove their own client pods and Jobs; gate1-baseline.sh run type 3 sets MODEL_TIMEOUT_S=5
# on deployment/worker for its one repetition and unsets it again (two rollouts of the worker, its own recipe);
# the plaintext probe creates and removes its own pod; the retry-knob readings are `make retry-on` / `make
# retry-off`. Runs from the repository root AFTER the rebuild; the log is written to $1 (outside the repository)
# and copied in afterwards. Adapted from experiments/runs/2026-09-19-agentgateway-only/checks.sh: the output
# paths and nonces, hops.py run from that record unedited, and part two. No retry anywhere: every curl here is
# --retry 0 and every send is one send.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-19-currency-rebuild
D=experiments/runs/$RUNREL
F14=experiments/runs/2026-09-16-genai-spans
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
F18=experiments/runs/2026-09-19-agentgateway-only
MTLS=experiments/runs/2026-09-12-mtls-enforced
LOG="$1"
ONLY="${2:-all}"   # all | part1 | part2 (= part2a then part2b) | part2a | part2b | part3 | knobs. The parts were taken one at a time, in this order,
                   # so that part one's counts could be read against the last proof's before any other traffic was sent.
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)  epoch $s" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
mkdir -p "$D/strict" "$D/proxies/raw" "$D/cluster" "$D/retry-knobs" "$D/pins/raw" "$D/rule-4" "$D/jaeger-api" "$D/mock-span" "$D/worker-span"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
echo "# Follow-ups 19 task 3 readings ($ONLY), started $(ts). HEAD $(git rev-parse HEAD) ($(git log --format=%s -1 | cut -c1-60)...); git status --short over the deployed paths -> $(git status --short -- "${DEPLOYED[@]}" | tr '\n' ' ')" >> "$LOG"

if [ "$ONLY" = all ] || [ "$ONLY" = part1 ]; then
# --- 1-5: the standard proof, as every rebuild since follow-ups 12 has taken it -------------------------------
step "clean check" env RUN_ID=fu19c RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ID=fu19t RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents (follow-ups 14 dangling.py, unedited)" bash -c "python3 $F14/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "GenAI spans per operation (follow-ups 14 genai-spans.py, unedited)" bash -c "mkdir -p $D/trace/genai && python3 $F14/genai-spans.py $D/trace $D/trace/genai > $D/trace/genai/summary.csv && cat $D/trace/genai/summary.csv"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# $MTLS/promq.sh targets'; echo; $MTLS/promq.sh targets; } > $D/prometheus-targets.txt 2>&1; cat $D/prometheus-targets.txt"

# --- 6: STRICT. Posture, the plaintext probe against both receivers, then every ztunnel series ----------------
posture() {
	echo "== $(ts) PeerAuthentication, every namespace =="
	kubectl get peerauthentication -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MODE:.spec.mtls.mode,SELECTOR:.spec.selector.matchLabels,PORTS:.spec.portLevelMtls
	echo "== $(ts) namespaces and their dataplane-mode label =="
	kubectl get ns -o custom-columns=NS:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode'
	echo "== $(ts) istioctl ztunnel-config workloads (PROTOCOL HBONE = captured, TCP = not) =="
	istioctl ztunnel-config workloads
}
step "STRICT posture" bash -c "$(declare -f posture ts); posture > $D/strict/posture.txt 2>&1; cat $D/strict/posture.txt"

probe() { # the walkthrough's probe ('Plaintext is refused'), against both receivers, one request each
	local pod=mtls-probe img=curlimages/curl:8.22.0 tp label
	kubectl -n default delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
	kubectl -n default run "$pod" --image="$img" --restart=Never --command -- sleep 600 >/dev/null
	kubectl -n default wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null
	tp=$(ts)
	label=$(kubectl get ns default -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')
	echo "# The plaintext probe, $(ts): a pod in namespace default (not enrolled: ${label:-no dataplane-mode label}) asks each receiver for its agent card, once, curl --retry 0." > "$D/strict/plaintext-probe.txt"
	echo "target,http_code,curl_exit" > "$D/strict/plaintext-probe.csv"
	for r in worker orchestrator; do
		local url="http://$r.lab.svc.cluster.local:8080/.well-known/agent-card.json" res rc=0
		res=$(kubectl -n default exec "$pod" -- curl -sS -o /dev/null -w 'http=%{http_code} exit=%{exitcode}' --retry 0 --connect-timeout 5 --max-time 10 "$url" 2>>"$D/strict/plaintext-probe.txt") || rc=$?
		echo "$url -> $res (kubectl exec status $rc)" >> "$D/strict/plaintext-probe.txt"
		echo "$url,$(printf '%s' "$res" | sed -n 's/.*http=\([0-9]*\).*/\1/p'),$(printf '%s' "$res" | sed -n 's/.*exit=\([0-9]*\).*/\1/p')" >> "$D/strict/plaintext-probe.csv"
	done
	sleep 3
	echo "# ztunnel refusal lines since the probe started ($tp), every ztunnel pod:" > "$D/strict/plaintext-probe-ztunnel.txt"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --since-time="$tp" 2>/dev/null | grep 'policy rejection' || true
	done >> "$D/strict/plaintext-probe-ztunnel.txt"
	cat "$D/strict/plaintext-probe.txt" "$D/strict/plaintext-probe.csv"
	echo "ztunnel 'policy rejection' lines (the file's own header line does not hold those words): $(grep -c 'policy rejection' "$D/strict/plaintext-probe-ztunnel.txt")"
	echo "  of them naming istio-system/istio_converted_static_strict: $(grep -c 'istio-system/istio_converted_static_strict' "$D/strict/plaintext-probe-ztunnel.txt")"
}
step "plaintext probe, both receivers" bash -c "D=$D; $(declare -f probe ts); probe"

security() {
	echo "-- waiting 35 s so Prometheus has scraped ztunnel (every 15 s) after the last connection above --"
	sleep 35
	{ echo "# istio_tcp_connections_opened_total, every series, $(ts): $MTLS/promq.sh security"; "$MTLS/promq.sh" security 2>&1; } > "$D/strict/tcp-connection-security-raw.txt"
	python3 "$F18/hops.py" "$D/strict/tcp-connection-security-raw.txt" "$D/strict/hops-security.csv" "$D/strict/legs.csv"
	echo "--- named legs:"; cat "$D/strict/legs.csv"
	echo "--- ztunnel error/denied/reject lines since the build, other than the probe's own (by source workload; a probe"
	echo "--- line ztunnel could not attribute carries no src.workload and stays in this file -- the last proof's note 2):"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --tail=-1 2>/dev/null | grep -E 'error|denied|reject' | grep -v 'src.workload="mtls-probe"' || true
	done > "$D/strict/ztunnel-other-error-lines.txt"
	echo "count: $(grep -c '' "$D/strict/ztunnel-other-error-lines.txt")"
}
step "ztunnel connection security, every series (follow-ups 18 hops.py, unedited)" bash -c "D=$D; MTLS=$MTLS; F18=$F18; $(declare -f security ts); security"
kubectl -n default delete pod mtls-probe --ignore-not-found --wait=false >/dev/null 2>&1

# --- 7: each proxy's own /config_dump: its policies and the control plane it is a client of -------------------
dumps() {
	for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
		set -- $pair
		echo "== $(ts) $1/$2 =="
		"$F17/config-dump.sh" "$1" "$2" "$D/proxies/raw/$2.config-dump.json" >/dev/null
		python3 "$F17/extract-config-dump.py" "$D/proxies/raw/$2.config-dump.json" "$D/proxies/$2.extract.json"
	done
}
step "config dumps (follow-ups 17 config-dump.sh and extract-config-dump.py, unedited)" bash -c "D=$D; F17=$F17; $(declare -f dumps ts); dumps 2>&1 | tee $D/proxies/extracts.txt"

# --- 8: the cluster facts ------------------------------------------------------------------------------------
facts() {
	echo "== $(ts) kubectl get gateway -A, with class =="
	kubectl get gateway -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:'.status.conditions[?(@.type=="Programmed")].status',ADDRESS:'.status.addresses[0].value'
	echo "Gateways of a class whose name starts with istio: $(kubectl get gateway -A -o jsonpath='{range .items[*]}{.spec.gatewayClassName}{"\n"}{end}' | grep -c '^istio' || true)"
	echo "== $(ts) kubectl get gatewayclass =="
	kubectl get gatewayclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:'.status.conditions[?(@.type=="Accepted")].status'
	echo "== $(ts) kubectl get httproute -A, with parent and status =="
	kubectl get httproute -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames,PARENT:'.spec.parentRefs[0].name',SECTION:'.spec.parentRefs[0].sectionName',ACCEPTED:'.status.parents[0].conditions[?(@.type=="Accepted")].status',RESOLVED:'.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status',CONTROLLER:'.status.parents[0].controllerName'
	echo "== $(ts) kubectl get telemetry -A =="
	kubectl get telemetries.telemetry.istio.io -A 2>&1
	echo "== $(ts) kubectl get agentgatewaypolicy -A, with status =="
	kubectl get agentgatewaypolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TARGET:'.spec.targetRefs[0].name',ACCEPTED:'.status.ancestors[0].conditions[?(@.type=="Accepted")].status',ATTACHED:'.status.ancestors[0].conditions[?(@.type=="Attached")].status'
	echo "== $(ts) the waypoint binding Istio wrote on each bound object (istio.io/WaypointBound) =="
	for o in "service/worker" "service/orchestrator" "serviceentry/model-external"; do
		printf '%s: ' "$o"; kubectl -n lab get "$o" -o jsonpath='{range .status.conditions[?(@.type=="istio.io/WaypointBound")]}{.status}{" -- "}{.message}{end}'; echo
	done
	echo "== $(ts) istiod's container env =="
	kubectl -n istio-system get deploy istiod -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
	echo "lines naming PILOT_ENABLE_AGENTGATEWAY: $(kubectl -n istio-system get deploy istiod -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' | grep -c PILOT_ENABLE_AGENTGATEWAY || true)"
	echo "== $(ts) the istio ConfigMap's mesh config =="
	kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}'; echo
	echo "== $(ts) the central proxy: its pod's labels, its image, and its namespace's labels =="
	kubectl -n agentgateway-waypoint get pods -o custom-columns=POD:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode',GATEWAY:'.metadata.labels.gateway\.networking\.k8s\.io/gateway-name',REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection',IMAGE:'.spec.containers[0].image',SA:.spec.serviceAccountName
	echo "namespace agentgateway-waypoint labels: $(kubectl get ns agentgateway-waypoint -o jsonpath='{.metadata.labels}')"
	echo "== $(ts) the ingress proxy, the same way =="
	kubectl -n agentgateway-ingress get pods -o custom-columns=POD:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode',GATEWAY:'.metadata.labels.gateway\.networking\.k8s\.io/gateway-name',REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection',IMAGE:'.spec.containers[0].image',SA:.spec.serviceAccountName
	echo "namespace agentgateway-ingress labels: $(kubectl get ns agentgateway-ingress -o jsonpath='{.metadata.labels}')"
	echo "== $(ts) namespaces that exist =="
	kubectl get ns -o name | tr '\n' ' '; echo
	echo "== $(ts) helm list -A =="
	helm list -A -o json | python3 -c 'import json,sys; [print("%-20s %-20s %-10s %s" % (r["name"], r["namespace"], r["status"], r["chart"])) for r in json.load(sys.stdin)]'
	echo "== $(ts) ztunnel's certificates, each node =="
	for n in agent-mesh-lab-worker agent-mesh-lab-control-plane; do echo "-- node $n"; istioctl ztunnel-config certificates --node "$n"; done
}
step "cluster facts" bash -c "$(declare -f facts ts); facts > $D/cluster/facts.txt 2>&1; cat $D/cluster/facts.txt"
fi

if [ "$ONLY" = all ] || [ "$ONLY" = part2 ] || [ "$ONLY" = part2a ]; then
# ================= part two: what the currency pass and task 2's code add ======================================
# --- (a) the pins, read back from the cluster -------------------------------------------------------------------
pinsread() {
	echo "== $(ts) every container of every pod: image as the spec names it, imageID as the node resolved it, ready, restarts =="
	kubectl get pods -A -o json > "$D/pins/raw/pods.json"
	python3 "$D/pins/containers.py" "$D/pins/raw/pods.json" "$D/pins/containers.csv"
	cat "$D/pins/containers.csv"
	echo "== $(ts) helm list -A: release, namespace, status, chart, app version =="
	helm list -A -o json > "$D/pins/helm-list.json"
	python3 -c 'import json,sys; [print("%-22s %-22s %-10s %-36s app_version=%s" % (r["name"], r["namespace"], r["status"], r["chart"], r["app_version"])) for r in json.load(open(sys.argv[1]))]' "$D/pins/helm-list.json"
	echo "== $(ts) the server, the nodes, the Gateway API bundle, istioctl =="
	kubectl version -o json | python3 -c 'import json,sys; v=json.load(sys.stdin); print("kubectl client %s  server %s" % (v["clientVersion"]["gitVersion"], v["serverVersion"]["gitVersion"]))'
	kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage
	docker inspect -f '{{.Name}} image={{.Config.Image}}' agent-mesh-lab-control-plane agent-mesh-lab-worker 2>&1
	for crd in gateways httproutes; do
		printf '%s.gateway.networking.k8s.io: ' "$crd"
		kubectl get crd "$crd.gateway.networking.k8s.io" -o jsonpath='bundle-version={.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} channel={.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
	done
	echo "HTTPRoute CRD: lines naming the retry field in its schema: $(kubectl get crd httproutes.gateway.networking.k8s.io -o json | grep -c '"retry"' || true)"
	istioctl version 2>&1
	echo "== $(ts) the orchestrator: every installed distribution inside the running container, name==version (compared with uv.lock afterwards) =="
	kubectl -n lab exec deploy/orchestrator -- python -c 'import importlib.metadata as m
for n, v in sorted({(d.metadata["Name"].lower().replace("_", "-"), d.version) for d in m.distributions()}): print("%s==%s" % (n, v))' > "$D/pins/orchestrator-installed.txt" 2>&1
	echo "distributions installed in the running orchestrator container: $(grep -c '==' "$D/pins/orchestrator-installed.txt")"
	echo "== $(ts) the two images that are ahead of their chart's appVersion: pods, readiness, restarts =="
	kubectl -n telemetry get pods -o custom-columns=POD:.metadata.name,PHASE:.status.phase,READY:'.status.containerStatuses[*].ready',RESTARTS:'.status.containerStatuses[*].restartCount',IMAGE:'.spec.containers[*].image',STARTED:'.status.containerStatuses[*].state.running.startedAt'
	for d in otel-collector jaeger; do
		kubectl -n telemetry logs "deploy/$d" --tail=-1 > "$D/pins/raw/$d.log" 2>&1
		python3 "$D/pins/log-levels.py" "$D/pins/raw/$d.log" "$D/pins/$d-warn-error-lines.txt" "$d"
	done
}
step "(a) pins read back" bash -c "D=$D; $(declare -f pinsread ts); pinsread 2>&1 | tee $D/pins/readback.txt"

# --- (b) the A2A-Version header per SDK, committed script unedited ----------------------------------------------
step "(b) gate1-wire-version.sh, unedited" env RUN_ID=fu19w RUN_ITEM=$RUNREL/wire-version experiments/gate1-wire-version.sh

# --- (c) rule 4 as the running pods record it -------------------------------------------------------------------
rule4() {
	echo "== $(ts) every Deployment in lab: env names starting MODEL_, CLIENT_, DOWNSTREAM_ or PLAN_ =="
	kubectl -n lab get deploy -o json | python3 -c 'import json,sys
for d in json.load(sys.stdin)["items"]:
    for c in d["spec"]["template"]["spec"]["containers"]:
        e = ["%s=%s" % (x["name"], x.get("value", "")) for x in c.get("env", []) if x["name"].startswith(("MODEL_", "CLIENT_", "DOWNSTREAM_", "PLAN_"))]
        print("  deploy/%s container %s: %s" % (d["metadata"]["name"], c["name"], " ".join(e) or "(none)"))'
	echo "CLIENT_* on any Deployment in lab, by the jq test gate3-matrix.sh uses (empty means none): $(kubectl -n lab get deploy -o json | jq -r '[.items[] | .metadata.name as $n | (.spec.template.spec.containers[0].env // [])[] | select(.name | startswith("CLIENT_")) | "\($n):\(.name)=\(.value)"] | join(" ")')"
	echo "== $(ts) the worker (Go): its own startup line, which prints the model timeout and MODEL_RETRIES as the process read them =="
	kubectl -n lab logs deploy/worker --tail=-1 | grep -m1 'listening on' || echo "  (no startup line found)"
	echo "== $(ts) the mock (Go): its startup line =="
	kubectl -n lab logs deploy/mockllm --tail=-1 | grep -m1 'listening on' || echo "  (no startup line found)"
	echo "== $(ts) the load client (Go): the env of every loadgen Job that exists, names starting CLIENT_ (the Job template carries none; the client builds internal/httpclient.New unless one is set) =="
	kubectl -n lab get jobs -o json | python3 -c 'import json,sys
for j in json.load(sys.stdin)["items"]:
    env = [x for c in j["spec"]["template"]["spec"]["containers"] for x in c.get("env", [])]
    e = ["%s=%s" % (x["name"], x.get("value", "")) for x in env if x["name"].startswith("CLIENT_")]
    print("  job/%s backoffLimit=%s: %s" % (j["metadata"]["name"], j["spec"].get("backoffLimit"), " ".join(e) or "(no CLIENT_ variable)"))'
	echo "== $(ts) the orchestrator (Python): inside the running container, the packages it runs and the model client its own constructor builds from the pod's environment =="
	kubectl -n lab exec deploy/orchestrator -- python -c '
import importlib.metadata as m, os, sys
print("python", sys.version.split()[0])
print(" ".join("%s=%s" % (p, m.version(p)) for p in ("a2a-sdk", "openai", "uvicorn", "httpx2", "httpcore2", "protobuf", "opentelemetry-distro", "opentelemetry-instrumentation-openai-v2", "opentelemetry-util-genai")))
print("env: MODEL_MAX_RETRIES=%r PLAN_MODEL_CALL=%r DOWNSTREAM_A2A_URL=%r" % (os.environ.get("MODEL_MAX_RETRIES"), os.environ.get("PLAN_MODEL_CALL"), os.environ.get("DOWNSTREAM_A2A_URL")))
import openai
from openai import _constants
from orchestrator.model import ModelClient
c = ModelClient(base_url=os.environ.get("MODEL_BASE_URL", ""), model=os.environ.get("MODEL_NAME", "mock"), api_key=os.environ.get("MODEL_API_KEY", "unused"), max_retries=int(os.environ.get("MODEL_MAX_RETRIES", "0")))
print("ModelClient built as server.py builds it: max_retries=%r transport_retries=%r ; AsyncOpenAI.max_retries=%r ; openai DEFAULT_MAX_RETRIES=%r" % (c.max_retries, c.transport_retries, c._client.max_retries, _constants.DEFAULT_MAX_RETRIES))
try:
    t = c._client._client._transport
    print("httpx2 transport %s: pool retries=%r" % (type(t).__name__, getattr(getattr(t, "_pool", None), "_retries", "not readable")))
except Exception as e:
    print("httpx2 transport: not readable (%s)" % e)
from a2a.utils import constants as k
print("a2a VERSION_HEADER=%r PROTOCOL_VERSION_CURRENT=%r" % (getattr(k, "VERSION_HEADER", None), getattr(k, "PROTOCOL_VERSION_CURRENT", None)))
' 2>&1
	echo "(the running orchestrator is in forward mode when DOWNSTREAM_A2A_URL is set and PLAN_MODEL_CALL is off: server.py then builds no model client at all, so the line above is what it WOULD build from this pod's environment, read in this pod's image)"
}
step "(c) rule 4 on the running pods" bash -c "D=$D; $(declare -f rule4 ts); rule4 2>&1 | tee $D/rule-4/running-pods.txt"

# --- (d) Jaeger 2.21.0's API on the cluster ---------------------------------------------------------------------
jaegerapi() {
	local port=16688 pf up=0
	if curl -s -o /dev/null --retry 0 --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null; then echo "something already answers on 127.0.0.1:$port; not querying a listener this reading did not start"; return 1; fi
	kubectl -n telemetry port-forward svc/jaeger "$port:16686" >/dev/null 2>&1 &
	pf=$!
	trap 'kill $pf >/dev/null 2>&1 || true' RETURN
	for i in $(seq 1 20); do if curl -s -o /dev/null --retry 0 --max-time 1 "http://127.0.0.1:$port/"; then up=1; break; fi; sleep 0.5; done
	[ "$up" = 1 ] || { echo "port-forward to svc/jaeger did not come up"; return 1; }
	echo "== $(ts) the image the jaeger pod runs =="
	kubectl -n telemetry get pods -l app.kubernetes.io/name=jaeger -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"  "}{.status.containerStatuses[0].imageID}{"\n"}{end}'
	echo "path,http_status,bytes" > "$D/jaeger-api/endpoints.csv"
	for path in "/api/v3/services" "/api/v3/operations?service=worker" "/api/services" "/api/operations?service=worker" "/api/services/worker/operations" "/api/traces?service=worker&limit=1"; do
		local name; name=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')
		local code; code=$(curl -sS --retry 0 --max-time 10 -o "$D/jaeger-api/body$name.txt" -w '%{http_code}' "http://127.0.0.1:$port$path")
		echo "$(ts) GET $path -> $code ($(wc -c < "$D/jaeger-api/body$name.txt" | tr -d ' ') bytes)"
		echo "\"$path\",$code,$(wc -c < "$D/jaeger-api/body$name.txt" | tr -d ' ')" >> "$D/jaeger-api/endpoints.csv"
	done
	echo "== /api/v3/services body =="; cat "$D/jaeger-api/body_api_v3_services.txt"; echo
	echo "== /api/services body (first 300 bytes) =="; head -c 300 "$D/jaeger-api/body_api_services.txt"; echo
	kill $pf >/dev/null 2>&1 || true
}
step "(d) Jaeger API on the cluster" bash -c "D=$D; $(declare -f jaegerapi ts); jaegerapi 2>&1 | tee $D/jaeger-api/readings.txt"

# --- (e) the mock's span on an injected close, live: one work item per mode, each by a committed row ------------
step "(e) close: gate3-matrix.sh RUN=baseline RECEIVER=go REPS=1 DRY_RUN=off (committed row, arms the mock's close by work item)" env RUN=baseline RECEIVER=go REPS=1 DRY_RUN=off RUN_ID=fu19m RUN_ITEM=$RUNREL/mock-span/close experiments/gate3-matrix.sh
fi
if [ "$ONLY" = all ] || [ "$ONLY" = part2 ] || [ "$ONLY" = part2b ]; then
step "(e) delay-then-close: gate1-baseline.sh RUNS=3 REPS=1 (committed run type 3: 8 s delay against MODEL_TIMEOUT_S=5 on the worker, set and unset by the script)" env STEP=3 RUNS=3 REPS=1 RUN_ID=fu19m RUN_ITEM=$RUNREL/mock-span/delay-then-close experiments/gate1-baseline.sh
step "(e) delay-then-close: make export-trace for its work item (gate1-baseline.sh exports no trace)" make --no-print-directory export-trace LWI=b3-fu19m-r3-01 OUT=$D/mock-span/delay-then-close/b3-fu19m-r3-01
mockmode() {
	echo "== $(ts) the mock's control lines (its own ledger): an inject arms a mode, a reset clears it; the last line decides the mode it is in =="
	kubectl -n lab logs deploy/mockllm --tail=-1 | grep '"ledger":"control"' > "$D/mock-span/mock-control-lines.jsonl" || true
	echo "control lines: $(grep -c '' "$D/mock-span/mock-control-lines.jsonl"); injects: $(grep -c '/control/inject' "$D/mock-span/mock-control-lines.jsonl"); resets: $(grep -c '/control/reset' "$D/mock-span/mock-control-lines.jsonl")"
	echo "the last three:"; tail -3 "$D/mock-span/mock-control-lines.jsonl"
	echo "== $(ts) the worker Deployment after run type 3 put its env back =="
	kubectl -n lab get deploy/worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(MODEL_|CLIENT_)' || echo "  (no MODEL_ or CLIENT_ variable)"
	kubectl -n lab get deploy worker orchestrator mockllm -o custom-columns=DEPLOY:.metadata.name,GENERATION:.metadata.generation,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas
}
step "(e) the mock's mode read back" bash -c "D=$D; $(declare -f mockmode ts); mockmode 2>&1 | tee $D/mock-span/mock-mode-readback.txt"
step "(e) one clean work item per receiver after the disarm" env RUN_ID=fu19z RUN_ITEM=$RUNREL/mock-span/clean-after experiments/gate2-single-clean.sh

# --- (g) the image scan, as the 2026-09-12 currency entry took it ----------------------------------------------
step "(g) make scan-images" make --no-print-directory scan-images SCAN_OUT=$D/scan
gomods() { # the Go images the scan just built into the Docker daemon: the module versions each binary was linked with
	local tmp; tmp=$(mktemp -d)
	echo "image,binary,go,module,version" > "$D/scan/go-binary-modules.csv"
	for n in worker mockllm loadgen replay; do
		local img cid; img=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^ko.local/$n-" | grep ':latest$' | head -1)
		[ -n "$img" ] || { echo "$n: no ko.local image found"; continue; }
		cid=$(docker create "$img"); docker cp "$cid:/ko-app/$n" "$tmp/$n" >/dev/null; docker rm "$cid" >/dev/null
		go version -m "$tmp/$n" > "$tmp/$n.mods.txt"
		local gov; gov=$(head -1 "$tmp/$n.mods.txt" | awk '{print $2}')
		awk -v img="$img" -v bin="$n" -v gov="$gov" '$1 == "dep" || $1 == "=>" { print img "," bin "," gov "," $2 "," $3 }' "$tmp/$n.mods.txt" >> "$D/scan/go-binary-modules.csv"
		local nmods grpc a2a otel otelhttp
		nmods=$(awk '$1=="dep"{n++} END{print n+0}' "$tmp/$n.mods.txt")
		grpc=$(awk '$1=="dep" && $2=="google.golang.org/grpc" {print $3}' "$tmp/$n.mods.txt")
		a2a=$(awk '$1=="dep" && $2 ~ /a2a-go/ {printf "%s@%s ", $2, $3}' "$tmp/$n.mods.txt")
		otel=$(awk '$1=="dep" && $2=="go.opentelemetry.io/otel" {print $3}' "$tmp/$n.mods.txt")
		otelhttp=$(awk '$1=="dep" && $2 ~ /otelhttp$/ {print $3}' "$tmp/$n.mods.txt")
		echo "$n ($img, $gov): $nmods modules linked; grpc: ${grpc:-not linked}; a2a-go: ${a2a:-not linked}; otel: ${otel:-not linked}; otelhttp: ${otelhttp:-not linked}"
	done
	rm -rf "$tmp"
}
step "(g) the module versions linked into the scanned Go binaries (go version -m)" bash -c "D=$D; $(declare -f gomods ts); gomods 2>&1 | tee $D/scan/go-binary-modules.txt"
fi

if [ "$ONLY" = all ] || [ "$ONLY" = part3 ]; then
# ================= part three: reading (h), asked for by the controller after the first knobs reading had been taken ===
# The author decided on 2026-09-19 that the WORKER is to mark the server span of its own injected close-after-read,
# as the mock does; that is a later commit. This is that span's reading at THIS tree and these pins, the live BEFORE
# for it. The committed row that arms the Go receiver with close-after-read is R1 (gate3-matrix.sh l.226-234:
# RECEIVER_INJECT="$RECEIVER_CLOSE_MODE", which is close-after-read for RECEIVER=go); R2's sub-rows arm
# http503-before-dispatch (l.235-253), so R2 is not it. R1 SUB=http also switches on the load client's own knob for
# its one Job (CLIENT_RETRIES=1, CLIENT_RETRY_ON=transport+503), which is what that row measures; it patches no
# route and rolls no Deployment on the Go receiver.
step "(h) the worker's own close-after-read: gate3-matrix.sh RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off (committed row, unedited)" env RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off RUN_ID=fu19h RUN_ITEM=$RUNREL/worker-span/close-after-read experiments/gate3-matrix.sh
afterh() {
	echo "== $(ts) retry stanzas across every HTTPRoute after that row: $(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)"
	echo "== $(ts) the worker Deployment's env, names starting MODEL_ or CLIENT_ (deploy/ sets MODEL_BASE_URL, MODEL_NAME, MODEL_API_KEY and no other) =="
	kubectl -n lab get deploy/worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(MODEL_|CLIENT_)' || echo "  (none)"
	kubectl -n lab get deploy worker orchestrator mockllm -o custom-columns=DEPLOY:.metadata.name,GENERATION:.metadata.generation,READY:.status.readyReplicas
	kubectl -n lab get pods -o custom-columns=POD:.metadata.name,STARTED:.status.startTime --no-headers | grep -v '^loadgen-'
	echo "== $(ts) the mock's control lines: count, and the last one =="
	kubectl -n lab logs deploy/mockllm --tail=-1 | grep '"ledger":"control"' | tail -1
}
step "(h) stanzas, the worker's env and the mock's last control line after that row" bash -c "D=$D; $(declare -f afterh ts); afterh 2>&1 | tee $D/worker-span/after-the-row.txt"
step "(h) one clean work item per receiver after it (the receiver writes no control line, so a clean 1/1/1/1/1 is what shows it disarmed)" env RUN_ID=fu19y RUN_ITEM=$RUNREL/worker-span/clean-after experiments/gate2-single-clean.sh
fi

if [ "$ONLY" = all ] || [ "$ONLY" = knobs ]; then
# --- last: the retry knobs: each route set on, read, off; and everything off at the end -------------------------
stanzas() { # per route: namespace/name and how many retry stanzas it carries
	kubectl get httproute -A -o json | python3 -c 'import json,sys
for r in json.load(sys.stdin)["items"]:
    n = sum(1 for rule in r["spec"].get("rules", []) if "retry" in rule)
    print("  %s/%s retry_stanzas=%d%s" % (r["metadata"]["namespace"], r["metadata"]["name"], n, "" if not n else " " + json.dumps([rule["retry"] for rule in r["spec"]["rules"] if "retry" in rule])))'
}
knobs() {
	echo "== $(ts) before anything: every route, stanza count =="; stanzas
	for route in waypoint ingress egress; do
		echo "== $(ts) make retry-on ROUTE=$route =="; make --no-print-directory retry-on ROUTE=$route; stanzas
		echo "== $(ts) make retry-off ROUTE=$route =="; make --no-print-directory retry-off ROUTE=$route; stanzas
	done
	echo "== $(ts) make retry-off (every route set), the state every run starts and ends in =="; make --no-print-directory retry-off; stanzas
}
# A second take never overwrites the first: the knobs were read once as the last reading (18:33Z), then reading (h)
# was asked for, so they were read again after it to be last again. Both files are kept.
KNOBS_OUT=$D/retry-knobs/readings.txt
if [ -e "$KNOBS_OUT" ]; then KNOBS_OUT=$D/retry-knobs/readings-take-2-after-reading-h.txt; fi
step "retry knobs -> $KNOBS_OUT" bash -c "D=$D; $(declare -f knobs stanzas ts); knobs > $KNOBS_OUT 2>&1; cat $KNOBS_OUT"
fi

echo "# readings ($ONLY) finished $(ts)" >> "$LOG"
echo "$(ts) checks done ($ONLY)"
