# agent-mesh-lab Makefile. Target names are fixed by the project plan;
# implementations are added as each task needs them.

CLUSTER_NAME := agent-mesh-lab
KIND_CONFIG  := kind-config.yaml
NAMESPACE    := lab

ORCHESTRATOR_IMAGE := orchestrator:dev
# Pinned by digest; matches the digest recorded in the wire-version findings entry
# and confirmed against the local image with:
#   docker image inspect paketobuildpacks/builder-jammy-base --format '{{index .RepoDigests 0}}'
PACK_BUILDER := paketobuildpacks/builder-jammy-base@sha256:029a4f6bf32aec6fe05fd576cbf2ba3e793761690ce2b0aff6f95940bf78cabf

# GO_SOURCES_HASH: a content hash of the tracked Go sources the worker and mock
# Deployments are built from (test files excluded: ko does not compile them, and a
# test-only commit must not force a rebuild). Time-independent, unlike a ko-built
# image's own tag or digest, which this repository has measured to change on every
# `ko apply` even from an unchanged tree (see step-2c's and step-3's comments below).
# Every step target that runs `ko apply` stamps both Deployments with this value as
# a metadata annotation (no rollout of its own) so a later check can tell "this
# image was built from this source" without rebuilding anything itself; see
# experiments/gate3-matrix.sh's image_fresh_or_die().
GO_SOURCES_HASH := $(shell git ls-files -s -- agents/worker fixtures/mockllm internal go.mod go.sum ':!**/*_test.go' | git hash-object --stdin)
# The stamp hashes the index while ko builds the working tree, so a step target
# refuses to run while the hashed Go paths carry uncommitted changes; the
# harness applies the same refusal before a row (experiments/gate3-matrix.sh).
GO_SOURCES_DIRTY := $(shell git status --porcelain -- agents/worker fixtures/mockllm internal go.mod go.sum ':!**/*_test.go')

.PHONY: check-go-sources-clean
check-go-sources-clean:
	@if [ -n "$(GO_SOURCES_DIRTY)" ]; then \
		echo "uncommitted changes under the Go paths the image stamp hashes; commit or stash them before a step target runs ko apply:" >&2; \
		printf '%s\n' "$(GO_SOURCES_DIRTY)" >&2; \
		exit 1; \
	fi

.PHONY: cluster-kind cluster-eks step-1 step-2 step-2b step-2c step-3 verify-baseline teardown ledgers matrix replay replay-waypoint replay-ingress export-trace retry-on retry-off test orchestrator-image

cluster-kind:
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi

cluster-eks:
	@echo "cluster-eks: not used in Gate 1; kind is the environment until a proposal Sec.5 trigger fires" >&2
	@exit 1

# orchestrator-image: build the Python agent with Cloud Native Buildpacks from
# agents/orchestrator (pyproject.toml + uv.lock + Procfile) and load it into kind.
orchestrator-image:
	pack build $(ORCHESTRATOR_IMAGE) --builder $(PACK_BUILDER) --path agents/orchestrator --pull-policy if-not-present
	kind load docker-image $(ORCHESTRATOR_IMAGE) --name $(CLUSTER_NAME)

step-1: check-go-sources-clean orchestrator-image
	kubectl kustomize deploy/step-1-nomesh | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# The orchestrator image keeps one tag, so a rebuilt image needs an explicit restart to be picked up.
	kubectl -n $(NAMESPACE) rollout restart deployment/orchestrator
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2: Istio Ambient with agentgateway as the waypoint. Versions come from
# versions.yaml (gateway-api v1.6.2 experimental; istio 1.31.0 via the istioctl on
# PATH; agentgateway v1.5.0 through the waypoint image annotation in the overlay).
# A setup target, like step-1: it rotates all three Deployments, and the worker's
# log is a ledger source, so do not re-run it against a baseline in progress.
# The overlay pulls in step-1, whose orchestrator Deployment needs the buildpacks
# image; ko builds the Go images inline, so orchestrator-image is the only
# prerequisite that makes step-2 runnable on a cluster that never ran step-1.
GATEWAY_API_VERSION := v1.6.2
step-2: check-go-sources-clean orchestrator-image
	# Applied unconditionally: a present CRD does not tell us the channel it came
	# from, and the experimental channel is what carries HTTPRoute.Retry.
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/experimental-install.yaml
	istioctl version --remote=false
	istioctl version --remote=false | grep -q 1.31.0 || { echo "istioctl on PATH is not the pinned 1.31.0 (see versions.yaml)" >&2; exit 1; }
	istioctl install --set profile=ambient --set values.pilot.env.PILOT_ENABLE_AGENTGATEWAY=true -y
	kubectl kustomize deploy/step-2-ambient-agw | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# ztunnel captures a pod when it starts, so pods that predate the namespace's
	# ambient label are restarted to be enrolled.
	kubectl -n $(NAMESPACE) rollout restart deployment/mockllm deployment/worker deployment/orchestrator
	kubectl -n $(NAMESPACE) rollout status deployment/agentgateway-waypoint --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2b: two more agentgateway proxies, an ingress in front of Agent A and an
# egress waypoint between Agent B and the model, both under agentgateway's own
# control plane. The waypoint from step 2 is untouched and stays driven by istiod.
# The two Helm installs and the namespace label follow the agentgateway
# documentation's Istio ambient ingress and egress pages; the chart version is
# pinned in versions.yaml under agentgateway-controlplane. The documented install
# adds --set controller.image.pullPolicy=Always, which is omitted here because a
# pinned tag is not re-pulled; the omission is recorded in the findings entry.
# Like step-1 and step-2 this is a setup target: it rotates the worker and the
# orchestrator, whose logs are ledger sources, and `ko apply` can rotate the mock
# as well, so do not run it against a baseline in progress. The overlay pulls in
# step-2, whose orchestrator Deployment needs the buildpacks image, so
# orchestrator-image is a prerequisite here for the same reason it is on step-2.
AGENTGATEWAY_CHART_VERSION := v1.5.0
step-2b: check-go-sources-clean orchestrator-image
	helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
		--create-namespace --namespace agentgateway-system --version $(AGENTGATEWAY_CHART_VERSION)
	helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
		--namespace agentgateway-system --version $(AGENTGATEWAY_CHART_VERSION) --wait
	# The ingress page labels the proxy namespace ambient so the hop from the
	# gateway pod to the backend pod is HBONE like every other hop in the mesh.
	kubectl label ns agentgateway-system istio.io/dataplane-mode=ambient --overwrite
	kubectl kustomize deploy/step-2b-agw-ingress-egress | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	kubectl -n agentgateway-system wait --for=condition=Programmed gateway/agentgateway-ingress --timeout=180s
	kubectl -n agentgateway-egress wait --for=condition=Programmed gateway/agw-egress --timeout=180s
	# ko rebuilds the Go images, so the mock can rotate on this apply too.
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2c: the Gate 2 stimulus paths. Adds a second istiod-driven waypoint for
# the orchestrator Service, so each receiver has a waypoint of its own, and
# gives the worker its own hostname on the step-2b ingress, so an
# out-of-cluster stimulus can reach either receiver. The two receivers do not
# share one waypoint; the measured reason is in the kustomization comment.
# Applies on top of step 2b: the overlay adds one Gateway, one Service label and
# one HTTPRoute and edits nothing in place. It is not free to repeat, though.
# Measured on 2026-09-09 while running step 3 (evidence in
# experiments/runs/2026-09-09-a3-pipeline/replicasets.txt): `ko apply` rebuilds
# the Go images from unchanged sources to NEW digests, so the worker and the mock
# Deployments roll on every repeat run. Both are ledger sources, so this and every
# other setup target stay out of a measurement in progress. Unlike step-1, step-2 and
# step-2b this does not depend on orchestrator-image: the Python image is
# already in the cluster and this overlay does not change its Deployment.
step-2c: check-go-sources-clean
	kubectl kustomize deploy/step-2c-gate2 | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# Programmed says istiod accepted the Gateway and provisioned for it; the
	# rollout wait after it says the proxy pod is ready to carry traffic.
	kubectl -n $(NAMESPACE) wait --for=condition=Programmed gateway/agentgateway-waypoint-orch --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/agentgateway-waypoint-orch --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-3: the telemetry pipeline. The OpenTelemetry Operator comes from its Helm
# chart, the way step-2b installs agentgateway's control plane and for the same
# reason: it is a controller with CRDs, not an application manifest, and this
# overlay's Instrumentation resource cannot be applied until those CRDs exist.
# The chart version is held here, mirroring AGENTGATEWAY_CHART_VERSION, and is
# recorded in versions.yaml under opentelemetry-operator with the release whose
# appVersion it carries.
#
# The overlay itself adds only new objects: the telemetry namespace and its three
# Deployments, plus one Instrumentation resource in lab. It declares no change to
# any agent, fixture or gateway. `ko apply` is used rather than `kubectl apply -k`
# because the overlay pulls in deploy/base, whose Deployments carry ko:// image
# references that only ko resolves; `kubectl apply -k` would send those strings to
# the cluster as image names.
#
# This is still a setup target, and running it does rotate all three lab pods.
# Measured on 2026-09-09, with the evidence in
# experiments/runs/2026-09-09-a3-pipeline/replicasets.txt: ko rebuilt the worker
# and the mock from unchanged sources to new digests, so those two Deployments
# rolled; and the orchestrator rolled because the declared env list orders
# DOWNSTREAM_A2A_URL fifth where `kubectl set env` and the Gate 2 A.2 restore had
# left it ninth, the same nine names with the same nine values in a different
# order, which is still a pod-template change. No retry knob was set on the live
# object before that apply or after it. Both agents' logs are ledger sources, so
# do not run this against a measurement in progress.
#
# The certificate check runs first, as the experiment scripts do, because a
# cluster left asleep for a day has an expired ztunnel workload certificate and
# every mesh hop fails until ztunnel is restarted.
OTEL_OPERATOR_CHART_VERSION := 0.122.0
OTEL_OPERATOR_NS            := opentelemetry-operator-system
TELEMETRY_NS                := telemetry
step-3: check-go-sources-clean
	@set -e; \
	echo "== certificate check =="; \
	certs=$$(istioctl ztunnel-config certificates --node $(CLUSTER_NAME)-worker); \
	printf '%s\n' "$$certs"; \
	if printf '%s\n' "$$certs" | awk '$$1 ~ /ns\/lab\/sa\/default$$/ && $$2 == "Leaf" { print $$4 }' | grep -qx true; then \
		echo "certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/default; ztunnel not restarted"; \
	else \
		echo "certificate check: VALID CERT is not true; restarting ztunnel" >&2; \
		kubectl -n istio-system rollout restart daemonset/ztunnel; \
		kubectl -n istio-system rollout status daemonset/ztunnel --timeout=180s; \
		istioctl ztunnel-config certificates --node $(CLUSTER_NAME)-worker \
			| awk '$$1 ~ /ns\/lab\/sa\/default$$/ && $$2 == "Leaf" { print $$4 }' | grep -qx true \
			|| { echo "certificate check: VALID CERT still not true after a ztunnel restart" >&2; exit 1; }; \
		echo "certificate check: VALID CERT true after a ztunnel restart"; \
	fi
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo update open-telemetry
	# The two admissionWebhooks values are the pair the chart README gives for a
	# self-signed certificate generated by Helm, which is how this cluster avoids
	# needing cert-manager for the Operator's webhooks.
	helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
		--version $(OTEL_OPERATOR_CHART_VERSION) \
		--namespace $(OTEL_OPERATOR_NS) --create-namespace \
		--set admissionWebhooks.certManager.enabled=false \
		--set admissionWebhooks.autoGenerateCert.enabled=true \
		--wait
	kubectl -n $(OTEL_OPERATOR_NS) rollout status deployment/opentelemetry-operator --timeout=180s
	kubectl kustomize deploy/step-3-stress | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	kubectl -n $(TELEMETRY_NS) rollout status deployment/otel-collector --timeout=180s
	kubectl -n $(TELEMETRY_NS) rollout status deployment/jaeger --timeout=180s
	kubectl -n $(TELEMETRY_NS) rollout status deployment/prometheus --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)
	@echo
	@echo "trace backend query Service: jaeger.$(TELEMETRY_NS).svc.cluster.local:16686 (its own UI and API; nothing else is installed)"
	@echo "read it from this host with: kubectl -n $(TELEMETRY_NS) port-forward svc/jaeger 16686:16686  then open http://127.0.0.1:16686"

# export-trace LWI=<id> OUT=<dir> [LOOKBACK=<seconds>]
#
# Writes the trace that carries lab.work_item=<id> into the run directory: the
# raw query response as <OUT>/trace.json, and one row per span as
# <OUT>/spans.csv. Exits 0 when at least one span was written and 2 when the
# query matched none, so a run script can tell "no trace" from "query failed".
# GNU make collapses any recipe failure onto its own exit 2, so a caller that
# needs the difference runs this target and reads spans.csv, or reads the
# message this recipe prints.
#
# The query is Jaeger's stable /api/v3/traces binding, reached through a
# short-lived port-forward this recipe starts and stops. Its parameters are the
# ones jaeger-idl documents for that binding: query.attributes as a URL-encoded
# JSON map matched against span and resource attributes, and the two required
# RFC-3339 bounds. LOOKBACK is how many seconds before now the window opens
# (default one hour); the window closes one minute in the future so a span
# written moments ago is inside it.
#
# spans.csv is produced from trace.json by experiments/lib/jaeger-spans.jq, and
# that program is exercised by `make test` against a response captured from this
# API, so a change to it that stops parsing a real response fails the tests.
JAEGER_QUERY_PORT := 16687
EXPORT_LOOKBACK    = $(or $(LOOKBACK),3600)
export-trace:
	@if [ -z "$(LWI)" ] || [ -z "$(OUT)" ]; then \
		echo "usage: make export-trace LWI=<logical_work_item_id> OUT=<dir> [LOOKBACK=<seconds>]" >&2; \
		exit 1; \
	fi
	@set -u; \
	if curl -s -o /dev/null --max-time 1 http://127.0.0.1:$(JAEGER_QUERY_PORT)/ 2>/dev/null; then \
		echo "export-trace: something already answers on 127.0.0.1:$(JAEGER_QUERY_PORT); refusing to query a listener this target did not start" >&2; \
		exit 1; \
	fi; \
	pf=""; \
	trap 'if [ -n "$$pf" ]; then kill $$pf >/dev/null 2>&1 || true; fi' EXIT INT TERM; \
	kubectl -n $(TELEMETRY_NS) port-forward svc/jaeger $(JAEGER_QUERY_PORT):16686 >/dev/null 2>&1 & \
	pf=$$!; \
	up=0; \
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		if curl -s -o /dev/null --max-time 1 http://127.0.0.1:$(JAEGER_QUERY_PORT)/ ; then up=1; break; fi; \
		sleep 0.5; \
	done; \
	if [ "$$up" != "1" ]; then echo "export-trace: port-forward to svc/jaeger did not come up" >&2; exit 1; fi; \
	now=$$(date -u +%s); \
	stamp() { date -u -r "$$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$$1" +%Y-%m-%dT%H:%M:%SZ; }; \
	tmin=$$(stamp $$((now - $(EXPORT_LOOKBACK)))); \
	tmax=$$(stamp $$((now + 60))); \
	mkdir -p "$(OUT)"; \
	curl -sS -G "http://127.0.0.1:$(JAEGER_QUERY_PORT)/api/v3/traces" \
		--data-urlencode 'query.attributes={"lab.work_item":"$(LWI)"}' \
		--data-urlencode "query.start_time_min=$$tmin" \
		--data-urlencode "query.start_time_max=$$tmax" \
		--data-urlencode "query.search_depth=100" \
		-o "$(OUT)/trace.json" || { echo "export-trace: the query to the trace backend failed" >&2; exit 1; }; \
	jq -r -s -f experiments/lib/jaeger-spans.jq "$(OUT)/trace.json" > "$(OUT)/spans.csv" \
		|| { echo "export-trace: jaeger-spans.jq could not read $(OUT)/trace.json" >&2; exit 1; }; \
	rows=$$(($$(grep -c '' "$(OUT)/spans.csv") - 1)); \
	echo "export-trace: lab.work_item=$(LWI) window $$tmin..$$tmax -> $$rows span(s) in $(OUT)/spans.csv"; \
	if [ "$$rows" -lt 1 ]; then \
		echo "export-trace: no span carried lab.work_item=$(LWI) in that window" >&2; \
		exit 2; \
	fi

# retry-on ROUTE=<waypoint|ingress|egress> [OUT=<dir>]
# retry-off [ROUTE=<waypoint|ingress|egress>] [OUT=<dir>]
#
# Switches the experimental HTTPRoute retry stanza on for one route set and off
# again. The stanza is `retry: {attempts: 1, codes: [...], backoff: 100ms}`; the
# codes are [503] on the waypoint and ingress routes and [500, 503] on the egress
# route, because the failure injected on that hop is the model endpoint's 500.
# The three route sets are:
#
#   waypoint  the `worker` HTTPRoute in `lab`, attached to the worker Service and
#             served by the istiod-driven agentgateway waypoint (step 2)
#   ingress   `worker-ingress` and the `orchestrator-ingress` catch-all, both on
#             the agentgateway ingress under agentgateway's own control plane
#             (steps 2b and 2c)
#   egress    `model-via-agw` in `agentgateway-egress`, the route to
#             model.lab.internal on the egress waypoint (step 2b)
#
# What these targets touch is routes and nothing else. The manifests come from
# deploy/step-3-stress/retry/<route>/{off,on}, which read the step-2/2b/2c route
# files rather than copying them, and the rendered stream is filtered to its
# HTTPRoute documents by experiments/lib/httproute-only.awk before it reaches
# `kubectl apply`. No image is built and no Deployment is rolled: this is
# `kubectl apply` of route objects, not `ko apply` of the overlay.
#
# `retry-off` with no ROUTE puts all three route sets back, which is the state
# every run that is not measuring a gateway retry has to start and end in. Both
# targets then print how many `retry:` lines exist across every HTTPRoute in the
# cluster, and with OUT they write the route objects read back from the API
# server into <OUT>/routes.txt, so a run directory records the routes as the
# cluster held them rather than as the manifests declared them.
#
# LoadRestrictionsNone is needed because each kustomization reads a route file
# from an earlier overlay instead of copying it; that is the point of the layout,
# and the relocatability it costs is not something this repository uses.
RETRY_DIR    := deploy/step-3-stress/retry
RETRY_ROUTES := waypoint ingress egress

define retry_readback
	echo "== retry stanzas across every HTTPRoute in the cluster =="; \
	routes=$$(kubectl get httproute -A -o yaml); \
	n=$$(printf '%s\n' "$$routes" | grep -c 'retry:' || true); \
	echo "kubectl get httproute -A -o yaml | grep -c 'retry:' -> $$n"; \
	if [ -n "$(OUT)" ]; then \
		mkdir -p "$(OUT)"; \
		printf '%s\n' "$$routes" > "$(OUT)/routes.txt"; \
		echo "route objects read back into $(OUT)/routes.txt"; \
	fi
endef

# The render is not piped straight into `kubectl apply`. A recipe shell is
# whatever /bin/sh is on the host, and `set -o pipefail` is not portable across
# those, so a kustomize or awk failure in the middle of a pipeline would be hidden
# behind a successful `kubectl apply` of nothing. The rendered routes are captured
# first and refused when empty, which is the same guarantee without depending on
# the shell. `set -e` then carries the apply's own status.
define retry_apply
	rendered=$$(kubectl kustomize --load-restrictor=LoadRestrictionsNone "$$dir" | awk -f experiments/lib/httproute-only.awk); \
	if [ -z "$$rendered" ]; then \
		echo "retry: $$dir rendered no HTTPRoute; nothing was applied" >&2; \
		exit 1; \
	fi; \
	printf '%s\n' "$$rendered" | kubectl apply -f -
endef

retry-on:
	@case "$(ROUTE)" in \
	waypoint | ingress | egress) ;; \
	*) echo "usage: make retry-on ROUTE=<waypoint|ingress|egress> [OUT=<dir>]" >&2; exit 1 ;; \
	esac
	@set -e; \
	dir="$(RETRY_DIR)/$(ROUTE)/on"; \
	$(retry_apply); \
	$(retry_readback)

retry-off:
	@case "$(ROUTE)" in \
	'' | waypoint | ingress | egress) ;; \
	*) echo "usage: make retry-off [ROUTE=<waypoint|ingress|egress>] [OUT=<dir>]" >&2; exit 1 ;; \
	esac
	@set -e; \
	for route in $(if $(ROUTE),$(ROUTE),$(RETRY_ROUTES)); do \
		dir="$(RETRY_DIR)/$$route/off"; \
		$(retry_apply); \
	done; \
	$(retry_readback)

# replay MODE=<M1|M2|M3> RECEIVER=<go|py> VIA=<waypoint|ingress> LWI=<id> [OUT=<dir>] [GAP_MS=<n>]
#
# Sends one A2A message twice with the duplicate-delivery harness, over one of
# the two Gate 2 stimulus paths. RECEIVER names the SDK: `go` is the worker,
# `py` the orchestrator.
#
#   VIA=waypoint  in-cluster. Renders deploy/base/replay-job.yaml as Job
#                 replay-$(LWI) and applies it; the pod is ztunnel-captured, so
#                 the request reaches the receiver through that receiver's own
#                 istiod-driven waypoint. The two client lines are in the pod
#                 log, which `make ledgers LWI=<id>` collects.
#   VIA=ingress   out-of-cluster. Opens `kubectl port-forward` to the ingress
#                 Service, runs the harness on this host against 127.0.0.1, and
#                 stops the port-forward. port-forward is a TCP tunnel, not an
#                 HTTP proxy: it forwards bytes and rewrites nothing, so the
#                 Host header the harness sets is the one the gateway matches on.
#                 The worker is addressed as worker.lab.internal (its step-2c
#                 route); the orchestrator needs no Host, being the catch-all
#                 route. With OUT, the two client lines are written to
#                 <OUT>/client.jsonl, each labelled source=host the way the
#                 ledgers target labels the lines it reads from a pod log, so
#                 no client line in a run directory is without the field. That
#                 is where `make ledgers OUT=<dir>`
#                 then finds them (there is no Job to read logs from). Readiness
#                 is probed by one GET / through the gateway, which the catch-all
#                 receiver records as an ingress line carrying no work item; the
#                 collection for a work item filters it out.
#
# Outcomes. **The client lines are the authority**: each carries the HTTP status,
# the result kind, the state and the error of one attempt, and a run script reads
# its counts from them, not from an exit status.
#
# The two recipes now agree on what they return: 0 when both attempts got an HTTP
# response, 3 when either failed at the transport, 1 for a usage error or a run
# that produced no outcome at all. The ingress path runs a built binary rather
# than `go run` for this, because `go run` reports a child's exit 3 as 1
# (measured: `go run` -> 1, the same binary built and executed -> 3); the
# waypoint path maps a Job that reached condition=failed onto 3.
#
# What `make` itself returns is coarser, and no Makefile can change it: GNU make
# exits 2 whenever a recipe fails, whatever status the recipe used, and a
# recursive invocation collapses the same way (measured on a scratch Makefile:
# a recipe exiting 3 gives make status 2, directly and through $(MAKE)). So
# `make replay` returns 0 on success and 2 on any failure, and a caller that
# needs to tell a transport failure from a usage error reads the client lines or
# runs the harness binary directly.
#
# The name is VIA, not PATH: a command-line `PATH=` assignment is exported into
# every recipe's shell, which leaves kubectl, go, ko and jq unresolvable.
REPLAY_INGRESS_NS   := agentgateway-system
REPLAY_INGRESS_PORT := 18080
REPLAY_TARGET_URL    = $(if $(filter py,$(RECEIVER)),http://orchestrator.lab.svc.cluster.local:8080,http://worker.lab.svc.cluster.local:8080)
REPLAY_INGRESS_HOST  = $(if $(filter py,$(RECEIVER)),,worker.lab.internal)
REPLAY_GAP_MS        = $(or $(GAP_MS),0)

replay:
	@if [ -z "$(LWI)" ] || [ -z "$(MODE)" ] || [ -z "$(RECEIVER)" ] || [ -z "$(VIA)" ]; then \
		echo "usage: make replay MODE=<M1|M2|M3> RECEIVER=<go|py> VIA=<waypoint|ingress> LWI=<id> [OUT=<dir>] [GAP_MS=<n>]" >&2; \
		exit 1; \
	fi
	@case "$(MODE)" in M1|M2|M3) ;; *) echo "replay: MODE=$(MODE) is not M1, M2 or M3" >&2; exit 1 ;; esac
	@case "$(RECEIVER)" in go|py) ;; *) echo "replay: RECEIVER=$(RECEIVER) is not go or py" >&2; exit 1 ;; esac
	@case "$(VIA)" in waypoint|ingress) ;; *) echo "replay: VIA=$(VIA) is not waypoint or ingress" >&2; exit 1 ;; esac
	@$(MAKE) --no-print-directory replay-$(VIA) MODE=$(MODE) RECEIVER=$(RECEIVER) LWI=$(LWI) OUT=$(OUT) GAP_MS=$(REPLAY_GAP_MS)

replay-waypoint:
	kubectl -n $(NAMESPACE) delete job replay-$(LWI) --ignore-not-found --wait=true
	sed -e 's/$${LWI}/$(LWI)/g' -e 's#$${TARGET_URL}#$(REPLAY_TARGET_URL)#g' -e 's/$${MODE}/$(MODE)/g' -e 's/$${GAP_MS}/$(REPLAY_GAP_MS)/g' deploy/base/replay-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	@# A Job that exits non-zero is a recorded outcome, not an error in this
	@# target; it is reported as 3, the harness's own transport-failure status,
	@# so both paths agree. The client lines say what happened either way.
	@if kubectl -n $(NAMESPACE) wait --for=condition=complete job/replay-$(LWI) --timeout=180s >/dev/null 2>&1; then \
		echo "replay: job replay-$(LWI) completed"; \
	elif kubectl -n $(NAMESPACE) wait --for=condition=failed job/replay-$(LWI) --timeout=10s >/dev/null 2>&1; then \
		echo "replay: job replay-$(LWI) failed; the client lines record what each attempt got" >&2; \
		exit 3; \
	else \
		echo "replay: job replay-$(LWI) reached neither complete nor failed within the timeout" >&2; \
		exit 1; \
	fi

replay-ingress:
	@set -u; \
	if curl -s -o /dev/null --max-time 1 http://127.0.0.1:$(REPLAY_INGRESS_PORT)/ 2>/dev/null; then \
		echo "replay: something already answers on 127.0.0.1:$(REPLAY_INGRESS_PORT); refusing to run against a listener this target did not start" >&2; \
		exit 1; \
	fi; \
	tmpdir=$$(mktemp -d); pf=""; \
	trap 'if [ -n "$$pf" ]; then kill $$pf >/dev/null 2>&1 || true; fi; rm -rf "$$tmpdir"' EXIT INT TERM; \
	go build -o "$$tmpdir/replay" ./fixtures/replay || exit 1; \
	kubectl -n $(REPLAY_INGRESS_NS) port-forward svc/agentgateway-ingress $(REPLAY_INGRESS_PORT):80 >/dev/null 2>&1 & \
	pf=$$!; \
	up=0; \
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		if curl -s -o /dev/null --max-time 1 http://127.0.0.1:$(REPLAY_INGRESS_PORT)/ ; then up=1; break; fi; \
		sleep 0.5; \
	done; \
	if [ "$$up" != "1" ]; then echo "replay: port-forward to svc/agentgateway-ingress did not come up" >&2; exit 1; fi; \
	rc=0; \
	out=$$(TARGET_URL=http://127.0.0.1:$(REPLAY_INGRESS_PORT) LWI=$(LWI) MODE=$(MODE) HOST=$(REPLAY_INGRESS_HOST) TEXT=hello GAP_MS=$(REPLAY_GAP_MS) \
		"$$tmpdir/replay") || rc=$$?; \
	printf '%s\n' "$$out"; \
	if [ -n "$(OUT)" ]; then \
		mkdir -p "$(OUT)"; \
		labelled=$$(printf '%s\n' "$$out" | jq -R -c 'fromjson? | . + {source: "host"}') || \
			{ echo "replay: jq could not label the client lines with source=host" >&2; exit 1; }; \
		if [ "$$(printf '%s\n' "$$out" | grep -c .)" != "$$(printf '%s\n' "$$labelled" | grep -c .)" ]; then \
			echo "replay: the harness printed a line that is not JSON; it would be dropped by the labelling, so nothing was written to $(OUT)/client.jsonl" >&2; \
			exit 1; \
		fi; \
		printf '%s\n' "$$labelled" > "$(OUT)/client.jsonl"; \
	fi; \
	exit $$rc

# matrix RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=<http|sdk|waypoint|ingress>] [REPS=20]
#
# One row of the A.3 retry-location matrix. RUN names the row and, with SUB, its
# sub-row; RECEIVER names the SDK under test, `go` being the worker and `py` the
# orchestrator. The script switches on exactly the knobs that row names, arms the
# injection that row names once per repetition, sends one stimulus per
# repetition, and writes the three ledgers, the client lines and the exported
# trace per work item under experiments/runs/<date>-a3-<run>-<receiver>[-<sub>]/,
# with one summary row per repetition. Everything it changed is put back on every
# exit path, loudly.
#
# The script takes more than this target passes: DRY_RUN (default on, one
# repetition under a scratch nonce whose directory is deleted), RUN_ID, RUN_ITEM,
# COLLECT_WAIT and TRACE_WAIT are read from the environment, so a chunked or
# re-nonced run calls experiments/gate3-matrix.sh directly. REPS is defaulted
# here rather than passed through empty, because the script refuses an empty
# value rather than silently spending repetitions.
matrix:
	@if [ -z "$(RUN)" ] || [ -z "$(RECEIVER)" ]; then \
		echo "usage: make matrix RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=<http|sdk|waypoint|ingress>] [REPS=20]" >&2; \
		exit 1; \
	fi
	RUN=$(RUN) RECEIVER=$(RECEIVER) SUB=$(SUB) REPS=$(if $(REPS),$(REPS),20) experiments/gate3-matrix.sh

# verify-baseline [STEP=1|2] [REPS=5]: run the baseline (checklist box 4) on the
# running cluster; writes experiments/runs/<date>-baseline-step<STEP>/.
verify-baseline:
	STEP=$(if $(STEP),$(STEP),1) REPS=$(if $(REPS),$(REPS),5) experiments/gate1-baseline.sh

teardown:
	kind delete cluster --name $(CLUSTER_NAME)

# ledgers LWI=<id> [OUT=<dir>]: print the four ledgers for one
# logical_work_item_id, read from pod stdout: both agents' pre-dispatch
# ingress and execution ledgers (lines labelled with their source),
# mockllm's invocation ledger, and the client lines from whichever in-cluster
# Job sent the work item, loadgen-<id> or replay-<id>. Stdout
# carries only JSON lines (section headers go to stderr) so scripts can pipe
# it. `kubectl logs deploy/<name>` reads one pod, so this collection assumes
# exactly one replica of each agent and of mockllm. A source whose logs
# cannot be read is reported on stderr and skipped;
# finding nothing at all for the work item is an error. With OUT, each
# ledger is written as <OUT>/<name>.jsonl containing exactly the matching lines.
#
# One exception to that last sentence: an existing non-empty <OUT>/client.jsonl
# is kept rather than written, and the fact is reported on stderr. `make replay VIA=ingress
# OUT=<dir>` runs the harness on this host, where no Job and so no pod log
# exists, and writes its two client lines there; the collection that follows
# would otherwise truncate them.
ledgers:
	@if [ -z "$(LWI)" ]; then \
		echo "usage: make ledgers LWI=<id> [OUT=<dir>]" >&2; \
		exit 1; \
	fi
	@set -e; \
	fetch() { kubectl logs "$$@" -n $(NAMESPACE) 2>/dev/null || { echo "ledgers: warning: kubectl logs $$* failed; that ledger is missing from this collection" >&2; }; }; \
	WORKER=$$(fetch deploy/worker); \
	ORCH=$$(fetch deploy/orchestrator); \
	MOCK=$$(fetch deploy/mockllm); \
	quiet() { kubectl logs "$$@" -n $(NAMESPACE) 2>/dev/null || true; }; \
	LOADGEN=$$(quiet -l job-name=loadgen-$(LWI) --tail=-1); \
	REPLAY=$$(quiet -l job-name=replay-$(LWI) --tail=-1); \
	if [ -z "$$LOADGEN$$REPLAY" ]; then echo "ledgers: warning: no pod logs for job loadgen-$(LWI) or replay-$(LWI) (no such Job, its pods are gone, or the work item was sent from this host)" >&2; fi; \
	sel() { jq -R -c --arg lwi "$(LWI)" --arg ledger "$$1" --arg src "$$2" 'fromjson? | select(.ledger == $$ledger and .logical_work_item_id == $$lwi) | . + {source: $$src}' || { echo "ledgers: jq failed" >&2; exit 1; }; }; \
	INGRESS=$$( { printf '%s\n' "$$WORKER" | sel ingress worker; printf '%s\n' "$$ORCH" | sel ingress orchestrator; } ); \
	EXECUTION=$$( { printf '%s\n' "$$WORKER" | sel execution worker; printf '%s\n' "$$ORCH" | sel execution orchestrator; } ); \
	INVOCATION=$$(printf '%s\n' "$$MOCK" | sel invocation mockllm); \
	CLIENTL=$$( { printf '%s\n' "$$LOADGEN" | sel client loadgen; printf '%s\n' "$$REPLAY" | sel client replay; } ); \
	if [ -z "$$INGRESS$$EXECUTION$$INVOCATION$$CLIENTL" ]; then \
		echo "ledgers: no ledger lines of any kind for logical_work_item_id=$(LWI)" >&2; exit 1; \
	fi; \
	if [ -n "$(OUT)" ]; then \
		mkdir -p "$(OUT)"; \
		for pair in "ingress=$$INGRESS" "execution=$$EXECUTION" "invocation=$$INVOCATION" "client=$$CLIENTL"; do \
			name=$${pair%%=*}; body=$${pair#*=}; \
			if [ "$$name" = "client" ] && [ -s "$(OUT)/client.jsonl" ]; then \
				echo "ledgers: $(OUT)/client.jsonl exists and was kept; the client lines collected here were not written" >&2; \
				continue; \
			fi; \
			if [ -n "$$body" ]; then printf '%s\n' "$$body" > "$(OUT)/$$name.jsonl"; else : > "$(OUT)/$$name.jsonl"; fi; \
		done; \
	fi; \
	for pair in "ingress=$$INGRESS" "execution=$$EXECUTION" "invocation=$$INVOCATION" "client=$$CLIENTL"; do \
		name=$${pair%%=*}; body=$${pair#*=}; \
		echo "## $$name" >&2; \
		if [ -n "$$body" ]; then printf '%s\n' "$$body"; fi; \
	done

test:
	go test ./...
	@# The jq program that `make export-trace` turns a query response into
	@# spans.csv with, run against a response captured from the running trace
	@# backend in the Task 0 probe. A change that stops it reading a real
	@# response fails here.
	@out=$$(jq -r -s -f experiments/lib/jaeger-spans.jq experiments/fixtures/jaeger-trace-sample.json) || \
		{ echo "jaeger-spans.jq: could not read experiments/fixtures/jaeger-trace-sample.json" >&2; exit 1; }; \
	if [ "$$out" = "$$(cat experiments/fixtures/jaeger-trace-sample.spans.csv)" ]; then \
		echo "ok  jaeger-spans.jq: fixture rows unchanged"; \
	else \
		echo "FAIL jaeger-spans.jq: output differs from experiments/fixtures/jaeger-trace-sample.spans.csv" >&2; \
		printf '%s\n' "$$out" | diff -u experiments/fixtures/jaeger-trace-sample.spans.csv - >&2 || true; \
		exit 1; \
	fi
	@# The layer derivation the matrix harness labels every second delivery with,
	@# run against committed fixtures. Six are real repetitions copied from
	@# experiments/runs/ (Task 2's three gateway retry probes, one Task 3 baseline
	@# work item per receiver, and one Task 4 R1 py/http work item); the rest are
	@# synthetic, because a derivation with a
	@# label no test can reach is a derivation nobody has read. The expected
	@# labels are in experiments/fixtures/derive-layer/expected.txt.
	@fail=0; \
	while read -r name receiver expected; do \
		[ -n "$$name" ] || continue; \
		case "$$name" in \#*) continue ;; esac; \
		got=$$(experiments/lib/derive-layer.sh experiments/fixtures/derive-layer/$$name $$receiver | sed -n 's/^layer=//p'); \
		if [ "$$got" = "$$expected" ]; then \
			echo "ok  derive-layer: $$name -> $$got"; \
		else \
			echo "FAIL derive-layer: $$name -> $$got, expected $$expected" >&2; \
			fail=1; \
		fi; \
	done < experiments/fixtures/derive-layer/expected.txt; \
	[ "$$fail" = "0" ] || exit 1
