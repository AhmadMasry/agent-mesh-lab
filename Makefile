# agent-mesh-lab Makefile. Target names are fixed by the project plan;
# implementations are added as each task needs them.

CLUSTER_NAME := agent-mesh-lab
KIND_CONFIG  := kind-config.yaml
NAMESPACE    := lab

ORCHESTRATOR_IMAGE := orchestrator:dev

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

# HELM: Istio, the agentgateway control plane and the three telemetry components are
# installed by Helm and by nothing else. The author's direction of 2026-09-12 put Helm
# first; the direction of 2026-09-15 made it the only route for Istio -- "installation
# and deployment of istio, only helm" -- and retired the step-3 telemetry manifests
# with it, each after a committed record showed the Helm values and charts carry
# everything the retired inputs carried (experiments/runs/2026-09-15-helm-only/).
# istioctl stays on PATH as this lab's debugging client, not as its installer.
#
# `command -v` is used rather than `which` because it is a POSIX shell builtin and
# needs nothing on PATH itself. The value is the path to the binary, which
# helm-required prints, so a run record names the helm that ran.
#
# One component has no Helm route, and one has no route but Helm, and both facts are
# recorded rather than worked around:
#   - Gateway API's CRDs: the project publishes no Helm chart (its install page gives
#     only `kubectl apply -f <release>/experimental-install.yaml`), so step-2 applies
#     them that way.
#   - the agentgateway control plane (step-2): the project documents only a Helm
#     install of its two OCI charts. Until 2026-09-19 step-2b installed it; it moved to
#     step-2 with the author's decision of that day (docs/proposal-notes.md), because
#     step 2's waypoint is now a proxy under that control plane.
HELM := $(shell command -v helm 2>/dev/null)

# The Helm requirement is checked while make reads this file, before any goal runs.
# HELM_GOALS are the goals whose recipes call helm. When the command line names any of
# them and helm is not on PATH, make stops here through $(error), so no goal on that
# command line runs -- not the goals that need helm, and not the ones before them
# either: `make step-1 step-2` runs neither. `make -n` reads the file the same way, so
# it stops with the same message and a non-zero status instead of printing a plan the
# host cannot carry out. Until follow-ups 12 (2026-09-15) the check sat only in
# helm-required's recipe, which make expands when it reaches step-2 or step-3, so on a
# host without helm `make step-1 step-2` ran step-1 in full before stopping. The
# demonstration with a PATH that lacks helm, before and after this change, is committed
# in experiments/runs/2026-09-15-ingress-namespace/guard/.
#
# step-2b left this list on 2026-09-19, when its two Helm installs moved to step-2: its
# recipe calls helm no more, and the list is the goals whose recipes do. It still cannot
# run to any purpose on a host without helm, because it applies on top of step-2.
HELM_GOALS           := step-2 step-3
HELM_GOALS_REQUESTED := $(filter $(HELM_GOALS),$(MAKECMDGOALS))
ifneq ($(HELM_GOALS_REQUESTED),)
ifeq ($(HELM),)
$(error $(HELM_GOALS_REQUESTED): helm is not on PATH. Istio and agentgateway install through Helm in this lab and there is no other route. make stopped while reading the Makefile, so no goal on this command line ran; install helm and re-run)
endif
endif

# helm-required: the first prerequisite of step-2 and step-3 (and of step-2b until
# 2026-09-19, while that target installed the agentgateway control plane). It names the helm
# that runs, so a run record carries it. The check above has already stopped any command line
# that names those goals without helm; the $(error) here is kept for a goal that reaches
# them without naming them, and it says only what is then true. `make -n step-2 step-2b
# step-3` with helm on PATH, as the targets were on 2026-09-15, is committed in
# experiments/runs/2026-09-15-ingress-namespace/make-n.txt.
.PHONY: helm-required
helm-required:
	$(if $(HELM),@echo "helm: $(HELM)",$(error helm-required: helm is not on PATH. Istio and agentgateway install through Helm in this lab and there is no other route; install helm and re-run))

# Chart versions. Every one of these, and every values key the values files use, was
# read from a document in the session that added it and is recorded in versions.yaml
# with that URL. They are not the component versions: each chart's appVersion is the
# component version this lab already counted against, which is why these four chart
# versions and no others. Since 2026-09-19 (follow-ups 19) that sentence holds for Istio
# and Prometheus only: the collector image (0.161.0) and the Jaeger image (2.21.0) are
# each one release ahead of the appVersion of the newest chart that exists (0.173.1 ->
# 0.160.0, 4.13.1 -> 2.20.0), set through each chart's own image tag value in the values
# files; versions.yaml records the chart index reads under opentelemetry-collector-chart
# and trace-backend-chart. No chart release names either image yet. If either pairing
# fails on the rebuilt cluster, the fallback is to set that image's tag back to its
# chart's appVersion in the values file until a chart names the newer release; these
# chart versions stay either way.
ISTIO_CHART_VERSION          := 1.31.0
ISTIO_CHART_REPO             := https://blob.istio.io/istio-release/charts
OTEL_COLLECTOR_CHART_VERSION := 0.173.1
OTEL_COLLECTOR_CHART_REPO    := https://open-telemetry.github.io/opentelemetry-helm-charts
JAEGER_CHART_VERSION         := 4.13.1
JAEGER_CHART_REPO            := https://jaegertracing.github.io/helm-charts
PROMETHEUS_CHART_VERSION     := 29.31.1
PROMETHEUS_CHART_REPO        := https://prometheus-community.github.io/helm-charts

.PHONY: cluster-kind cluster-eks step-1 step-2 step-2b step-2c step-3 verify-baseline teardown ledgers matrix replay replay-waypoint replay-ingress export-trace retry-on retry-off test orchestrator-image scan-images

cluster-kind:
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi

cluster-eks:
	@echo "cluster-eks: not used in Gate 1; kind is the environment until a proposal Sec.5 trigger fires" >&2
	@exit 1

# orchestrator-image: build the Python agent from agents/orchestrator/Dockerfile
# and load it into kind. Cloud Native Buildpacks were replaced by that Dockerfile
# on 2026-09-10 by the author's decision. The pack builder was amd64-only, so the
# image it produced ran under emulation on this arm64 host, and no digest could
# change that (versions.yaml, pack-builder).
#
# --platform follows the host the same way every ko call site in this file does,
# so a build on an amd64 host does not silently produce an arm64 image. The build
# context is agents/orchestrator, which is what the Dockerfile's paths are
# relative to. The Dockerfile's lockfile-only dependency sync saves work only in a
# build that uses the layer cache, and this one does not, for the reason below.
#
# --pull is what makes the author's decision of 2026-09-10 -- every base image of
# ours referenced by tag rather than digest -- mean what it says: without it a
# local copy of python:3.14-slim or ghcr.io/astral-sh/uv:latest would be reused
# and the tag would stop floating. The digest each tag resolved to, and the uv
# version the builder printed, go into the run record for that build.
#
# --no-cache (author's decision, 2026-09-11) is for the two dnf RUNs, the rootfs
# stage's `dnf ... install ... upgrade` above all. A RUN's cache key is its parent
# layer and its command text and holds no repository state, so while the Amazon
# Linux base digest stands still a cached build answers CACHED on it and a package
# update published to the AL2023 repositories between base-image digests does not
# reach the image (`#16 CACHED` on the same base digest in
# experiments/runs/2026-09-10-orchestrator-al2023/build.txt). uv:latest does not
# need it: --pull re-resolves the COPY --from reference and the resolved digest is
# part of that step's cache key, so a moved tag is a cache miss on its own (the
# build of 2026-09-10T21:29Z resolved the new digest and took uv 0.12.13 on a miss;
# uv-correction.txt in that run directory). The cost is build time, stated in the
# README. The measurement is
# experiments/runs/2026-09-11-orchestrator-nocache/cache-measurement.txt.
orchestrator-image:
	docker build --pull --no-cache --platform linux/$(shell go env GOARCH) -t $(ORCHESTRATOR_IMAGE) -f agents/orchestrator/Dockerfile agents/orchestrator
	kind load docker-image $(ORCHESTRATOR_IMAGE) --name $(CLUSTER_NAME)

# scan-images: run the Kubescape CLI over the five images this lab builds and write
# the counts into a run directory. Host-side only: nothing is installed in the
# cluster, no Kubescape Operator, no node agent. Added on 2026-09-10 by the author's
# decision, recorded in docs/proposal-notes.md; the CLI version and the URL it came
# from are in versions.yaml under `kubescape`.
#
# Kubescape reads images straight out of the local Docker daemon, so the kind node's
# containerd store is not consulted: the four Go images are rebuilt here with
# `ko build` into ko.local, from the same sources and the same .ko.yaml base that
# `make step-3` uses, and the Python image is the orchestrator:dev the same
# `make orchestrator-image` produced. The scan record names the digest of every
# image scanned beside the imageID each lab pod is running, so a reader can see for
# themselves whether the two agree.
#
# What it writes into SCAN_OUT: Kubescape's JSON and text report per image, one
# <image>-findings.csv per image derived from that JSON by
# experiments/lib/kubescape-findings.jq (the per-finding record the findings entry
# reads its no-fix counts from), a summary.csv of counts by severity, and a
# scan-context.txt naming the scanner version, the vulnerability-database date, the
# command, and every digest scanned beside the image each lab pod is running.
#
# The target does not fail on findings. Counting what is there is the point; fixing
# any of it is the author's decision and was not taken in the task that added this.
# SCAN_OUT is dated and named for the scan itself, not for any one experiment
# item: a scan on a later date must not write into a run directory named for an
# item that did not run. The 2026-09-10 scan the findings entry cites was written
# into experiments/runs/2026-09-10-images-rebuilt/scan/, beside the run whose
# images it scanned, and stays there; pass SCAN_OUT= to put a scan anywhere else.
SCAN_OUT ?= experiments/runs/$(shell date +%F)-image-scan
scan-images:
	@command -v kubescape >/dev/null || { echo "kubescape is not on PATH; see versions.yaml key kubescape for the documented install" >&2; exit 1; }
	@command -v jq >/dev/null || { echo "jq is not on PATH; the per-finding CSVs are derived with experiments/lib/kubescape-findings.jq" >&2; exit 1; }
	@mkdir -p "$(SCAN_OUT)"
	KO_DOCKER_REPO=ko.local ko build ./agents/worker ./fixtures/mockllm ./fixtures/loadgen ./fixtures/replay --platform=linux/$(shell go env GOARCH) > "$(SCAN_OUT)/ko-build.txt" 2>&1
	@experiments/scan-images.sh "$(SCAN_OUT)"

step-1: check-go-sources-clean orchestrator-image
	kubectl kustomize deploy/step-1-nomesh | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# The orchestrator image keeps one tag, so a rebuilt image needs an explicit restart to be picked up.
	kubectl -n $(NAMESPACE) rollout restart deployment/orchestrator
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2: Istio Ambient for L4, and agentgateway under its OWN control plane as the waypoint.
# Versions come from versions.yaml (gateway-api v1.6.2 experimental; istio 1.31.0 through its
# four Helm charts; agentgateway v1.5.0 through its two Helm charts, whose appVersion is the
# proxy the controller deploys).
#
# Since 2026-09-19 (the author's decision of that day in docs/proposal-notes.md) every L7
# proxy is managed by agentgateway's control plane and istiod programs none: the overlay
# creates one Gateway of class `agentgateway`, `agw-central`, in a namespace of its own, and
# binds the worker Service to it. So this target installs three things in order -- Gateway
# API's CRDs, Istio, then agentgateway's CRDs and control plane -- before it applies the
# overlay, which holds an AgentgatewayParameters and a Gateway of that class and would be
# refused without them. Until that day the waypoint was istiod's (class
# `istio-agentgateway-waypoint`, behind the pilot flag PILOT_ENABLE_AGENTGATEWAY, both gone)
# and agentgateway's control plane was step-2b's to install.
#
# A setup target, like step-1: it rotates all three Deployments, and the worker's
# log is a ledger source, so do not re-run it against a baseline in progress.
# The overlay pulls in step-1, whose orchestrator Deployment needs the Python
# image; ko builds the Go images inline, so orchestrator-image is the only
# prerequisite that makes step-2 runnable on a cluster that never ran step-1.
GATEWAY_API_VERSION := v1.6.2
# The agentgateway charts' pin; recorded in versions.yaml under agentgateway-controlplane.
AGENTGATEWAY_CHART_VERSION := v1.5.0
step-2: helm-required check-go-sources-clean orchestrator-image
	# Applied unconditionally: a present CRD does not tell us the channel it came
	# from, and the experimental channel is what carries HTTPRoute.Retry.
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/experimental-install.yaml
	# istioctl is this lab's debugging client, not its installer. step-3's certificate
	# check and the experiment scripts read the mesh with `istioctl ztunnel-config`,
	# and those reads were recorded with the client at the pinned version, so the
	# client on PATH is held to the pin here.
	istioctl version --remote=false
	istioctl version --remote=false | grep -q 1.31.0 || { echo "istioctl on PATH is not the pinned 1.31.0 (see versions.yaml)" >&2; exit 1; }
	# Istio, by Helm (see the HELM comment at the top of this file): the four charts the
	# ambient Helm install page installs, in the page's order, each pinned to 1.31.0 and
	# each from the repository URL that page's `helm repo add` line gives. `--repo` is
	# used instead of `helm repo add` so the target adds nothing to the user's Helm
	# configuration. `helm upgrade -i` rather than the page's `helm install`, so a re-run
	# of this target is not an error -- the same substitution the agentgateway installs
	# below make. The page
	# passes `--set profile=ambient` to istiod and cni and nothing to ztunnel or base;
	# here istiod takes the profile from istio-values.yaml, which also carries the mesh
	# configuration (the OpenTelemetry tracing provider, and since 2026-09-19 the tracing
	# and metrics default providers and the sampling rate, in place of Telemetry objects) and
	# istiod's default workload certificate lifetime. ztunnel takes a values file of its
	# own, for the certificate lifetime it asks for and for the ambient profile; the page
	# passes ztunnel nothing, but without the profile the ztunnel chart ran the
	# non-distroless image and lacked ISTIO_META_ENABLE_HBONE (measured 2026-09-12), and
	# the reason neither key can live in istio-values.yaml is in ztunnel-values.yaml's
	# header.
	@echo "step-2: Istio via Helm ($(HELM)), charts pinned to $(ISTIO_CHART_VERSION)"
	helm upgrade -i istio-base base --repo $(ISTIO_CHART_REPO) --version $(ISTIO_CHART_VERSION) \
		-n istio-system --create-namespace --wait
	helm upgrade -i istiod istiod --repo $(ISTIO_CHART_REPO) --version $(ISTIO_CHART_VERSION) \
		-n istio-system -f deploy/step-2-ambient-agw/istio-values.yaml --wait
	helm upgrade -i istio-cni cni --repo $(ISTIO_CHART_REPO) --version $(ISTIO_CHART_VERSION) \
		-n istio-system --set profile=ambient --wait
	helm upgrade -i ztunnel ztunnel --repo $(ISTIO_CHART_REPO) --version $(ISTIO_CHART_VERSION) \
		-n istio-system -f deploy/step-2-ambient-agw/ztunnel-values.yaml --wait
	# The agentgateway control plane, by Helm, after Istio: the proxy it deploys for the
	# overlay's Gateway has `istio.enabled` and takes its identity from istiod. One route
	# only: the agentgateway documentation installs its control plane by Helm from two OCI
	# charts, agentgateway-crds and agentgateway from oci://cr.agentgateway.dev/charts, and
	# documents no other way, which is a fact about the project's install surface and is
	# recorded as one in findings.md (versions.yaml, agentgateway-controlplane). The
	# documented install adds --set controller.image.pullPolicy=Always, which is omitted
	# here because a pinned tag is not re-pulled. Both installs were step-2b's until
	# 2026-09-19 and are unchanged but for their place and the values file's path.
	#
	# agentgateway-system holds the control plane only and is not labelled ambient, so the
	# controller is outside the mesh by its namespace: it is not on the traffic path. The
	# values file sets nothing, and its header says what it set before and why that is gone.
	@echo "step-2: agentgateway control plane via Helm ($(HELM)), charts pinned to $(AGENTGATEWAY_CHART_VERSION)"
	helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
		--create-namespace --namespace agentgateway-system --version $(AGENTGATEWAY_CHART_VERSION)
	helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
		--namespace agentgateway-system --version $(AGENTGATEWAY_CHART_VERSION) \
		-f deploy/step-2-ambient-agw/agentgateway-values.yaml --wait
	kubectl kustomize deploy/step-2-ambient-agw | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# ztunnel captures a pod when it starts, so pods that predate the namespace's
	# ambient label are restarted to be enrolled.
	kubectl -n $(NAMESPACE) rollout restart deployment/mockllm deployment/worker deployment/orchestrator
	# The central proxy. Programmed is the wait agentgateway's egress page uses for this
	# Gateway shape, and it says the controller accepted the Gateway; the rollout wait
	# after it says the proxy pod is ready to carry traffic. The controller creates that
	# Deployment, named after the Gateway, some time after the apply above, and `rollout
	# status` on an object that does not exist yet is an error rather than a wait, so its
	# creation is waited for first. None of the three is a retry of anything measured.
	kubectl -n agentgateway-waypoint wait --for=condition=Programmed gateway/agw-central --timeout=180s
	kubectl -n agentgateway-waypoint wait --for=create deployment/agw-central --timeout=180s
	kubectl -n agentgateway-waypoint rollout status deployment/agw-central --timeout=180s
	# The worker's route on it: Accepted by agentgateway's controller, the wait its egress
	# page uses for its own route. If the controller wrote no such status, the target fails.
	kubectl -n $(NAMESPACE) wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True httproute/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2b: the way in and the way out, both on proxies under agentgateway's own
# control plane. The way in is a second agentgateway proxy, the ingress in front of
# Agent A. The way out is a ROLE, not a proxy: the model host is bound to `agw-central`,
# the proxy step 2 created, with its backend and its route there. The shapes follow the
# agentgateway documentation's Istio ambient ingress and egress pages.
#
# Until 2026-09-19 this target also installed the agentgateway control plane, by Helm,
# and the overlay created a third proxy, `agw-egress`, for the model leg. The installs
# moved to step-2 (its waypoint needs them; see there) and that proxy is retired (the
# author's decision of that day in docs/proposal-notes.md). So this target calls helm no
# more, and helm-required is no longer its prerequisite; step-2 must have run, which is
# where the guard now stands.
#
# Like step-1 and step-2 this is a setup target: it rotates the worker and the
# orchestrator, whose logs are ledger sources, and `ko apply` can rotate the mock
# as well, so do not run it against a baseline in progress. The overlay pulls in
# step-2, whose orchestrator Deployment needs the Python image, so
# orchestrator-image is a prerequisite here for the same reason it is on step-2.
#
# The control plane has three clients. Two are outside the mesh and speak plaintext to
# it: the central proxy's XDS and Prometheus. The third, since follow-ups 12, is the
# ingress proxy in the ambient namespace agentgateway-ingress, whose XDS dial to
# https://agentgateway.agentgateway-system.svc.cluster.local:9978 leaves a captured pod
# for an uncaptured one: ztunnel does not tunnel it, so it is not mesh mTLS, and what
# rides it is agentgateway's own TLS.
step-2b: check-go-sources-clean orchestrator-image
	# The ingress proxy's namespace, agentgateway-ingress, is created by the overlay with
	# the ambient label the ingress page asks for, so the hop from the gateway pod to the
	# backend pod is HBONE like every other hop in the mesh and the proxy pod is captured
	# from its creation. Until follow-ups 12 the ingress ran in agentgateway-system and
	# this target labelled that namespace here.
	kubectl kustomize deploy/step-2b-agw-ingress-egress | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	kubectl -n agentgateway-ingress wait --for=condition=Programmed gateway/agentgateway-ingress --timeout=180s
	# The model route on the central proxy: Accepted, by the wait agentgateway's egress
	# page uses for its own route. If the controller wrote no such status for the route,
	# this wait runs out and the target fails, instead of the step ending with a route
	# that nothing serves.
	kubectl -n agentgateway-waypoint wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True httproute/model-via-agw --timeout=180s
	# ko rebuilds the Go images, so the mock can rotate on this apply too.
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-2c: the Gate 2 stimulus paths. Binds the orchestrator Service to `agw-central`
# and gives it a hostname route there, so an in-cluster stimulus to either receiver
# crosses the agentgateway-managed proxy, and gives the worker its own hostname on the
# step-2b ingress, so an out-of-cluster stimulus can reach either receiver. Until
# 2026-09-19 it added a second istiod-driven waypoint instead, one per receiver; what
# that was for, and what supersedes it, is in the kustomization comment.
# Applies on top of step 2b: the overlay adds two HTTPRoutes and the Service's two
# labels and edits nothing in place. It is not free to repeat, though.
# Measured on 2026-09-09 while running step 3 (evidence in
# experiments/runs/2026-09-09-a3-pipeline/replicasets.txt): `ko apply` rebuilds
# the Go images from unchanged sources to NEW digests, so the worker and the mock
# Deployments roll on every repeat run. Both are ledger sources, so this and every
# other setup target stay out of a measurement in progress. Unlike step-1, step-2 and
# step-2b this does not depend on orchestrator-image: the Python image is
# already in the cluster and this overlay does not change its Deployment.
step-2c: check-go-sources-clean
	kubectl kustomize deploy/step-2c-gate2 | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# No proxy is created by this overlay, so there is no Gateway or rollout to wait for.
	# What it adds to the central proxy is one route, waited for the way step-2b waits
	# for the model route: Accepted by agentgateway's controller, or the target fails.
	kubectl -n $(NAMESPACE) wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True httproute/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s
	kubectl -n $(NAMESPACE) annotate --overwrite deployment/worker deployment/mockllm lab.agent-mesh/go-sources=$(GO_SOURCES_HASH)

# step-3: the telemetry pipeline.
#
# No OpenTelemetry Operator is installed. The Python agent starts under the
# OpenTelemetry distro's own `opentelemetry-instrument` launcher, which is
# installed in its image; the Operator's Python injection route was measured in
# four states at Gate 3 Task 1 and removed from this target on 2026-09-10 by the
# author's decision. The counts that route produced stay in findings.md, and the
# `opentelemetry-operator` and `otel-python-autoinstrumentation` keys stay in
# versions.yaml, marked as not used, as the record those entries cite.
#
# The overlay adds only new objects: the telemetry namespace and step 3's
# configuration. It declares no change to any agent, fixture or
# gateway. `ko apply` is used rather than `kubectl apply -k`
# because the overlay pulls in deploy/base, whose Deployments carry ko:// image
# references that only ko resolves; `kubectl apply -k` would send those strings to
# the cluster as image names.
#
# The three components themselves are installed from their charts, pinned above,
# with the values files in deploy/step-3-stress (see the HELM comment at the top of
# this file).
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
#
# **Never apply the overlay with a plain `kubectl apply -k deploy/step-3-stress`.**
# The overlay carries the Go Deployments, whose images are `ko://` references that
# only `kubectl kustomize ... | ko apply` resolves; a plain `apply -k` writes the
# raw `ko://` string into deployment/worker and deployment/mockllm and each gets an
# InvalidImageName pod beside the running one. Measured on 2026-09-12 while applying
# a telemetry-only change, and undone with `kubectl -n lab rollout undo deploy/worker
# deploy/mockllm`; the serving pods never changed and the guard annotation survived.
# A telemetry-only change to this overlay is applied by file -- `kubectl apply -f`
# the manifests it touches -- or by running this target, which pipes through ko.
TELEMETRY_NS                := telemetry
step-3: helm-required check-go-sources-clean
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
	# The telemetry components, by Helm (see the HELM comment at the top of this file):
	# each of the three from its project's chart, pinned above, with its values file in
	# deploy/step-3-stress. The namespace is created by the configuration overlay, which
	# is applied first so `--create-namespace` is not needed and the namespace's own
	# labels are the overlay's.
	@echo "step-3: telemetry via Helm ($(HELM)); collector chart $(OTEL_COLLECTOR_CHART_VERSION), jaeger chart $(JAEGER_CHART_VERSION), prometheus chart $(PROMETHEUS_CHART_VERSION)"
	kubectl kustomize deploy/step-3-stress | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	helm upgrade -i otel-collector opentelemetry-collector --repo $(OTEL_COLLECTOR_CHART_REPO) \
		--version $(OTEL_COLLECTOR_CHART_VERSION) -n $(TELEMETRY_NS) \
		-f deploy/step-3-stress/otel-collector-values.yaml --wait
	helm upgrade -i jaeger jaeger --repo $(JAEGER_CHART_REPO) \
		--version $(JAEGER_CHART_VERSION) -n $(TELEMETRY_NS) \
		-f deploy/step-3-stress/jaeger-values.yaml --wait
	helm upgrade -i prometheus prometheus --repo $(PROMETHEUS_CHART_REPO) \
		--version $(PROMETHEUS_CHART_VERSION) -n $(TELEMETRY_NS) \
		-f deploy/step-3-stress/prometheus-values.yaml --wait
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
#   waypoint  the `worker` HTTPRoute in `lab`, the worker Service's hostname route on
#             `agw-central`, the agentgateway-managed proxy that is its waypoint (step 2)
#   ingress   `worker-ingress` and the `orchestrator-ingress` catch-all, both on
#             the agentgateway ingress under agentgateway's own control plane
#             (steps 2b and 2c)
#   egress    `model-via-agw` in `agentgateway-waypoint`, the route to
#             model.lab.internal on `agw-central` in its egress role (step 2b)
#
# Since 2026-09-19 the waypoint and the egress route are served by ONE proxy, where
# until then each had its own (an istiod-driven waypoint in `lab`, and `agw-egress` in
# `agentgateway-egress`). The route names are the same; the egress route's namespace is
# what changed. The stanza stays per route: `retry-on ROUTE=waypoint` patches `lab/worker`
# and nothing else on that proxy. The `orchestrator` route the same proxy serves since
# that day (step 2c) is in no route set.
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
#                 the request reaches the receiver through the waypoint its
#                 Service names, which since 2026-09-19 is `agw-central` for
#                 both receivers (until then each receiver's own istiod-driven
#                 waypoint). The target URL is the receiver Service's fully
#                 qualified name, which is what that proxy's routes match on.
#                 The two client lines are in the pod log, which
#                 `make ledgers LWI=<id>` collects.
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
REPLAY_INGRESS_NS   := agentgateway-ingress
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
	@# Both lines a caller reads are compared, `layer=` and `reason=`, the reason
	@# whole and unmasked: it is the rest of the fixture's line in expected.txt. A
	@# right label reached by the wrong branch fails here, and so does a line that
	@# records no reason.
	@fail=0; \
	while read -r name receiver expected reason; do \
		[ -n "$$name" ] || continue; \
		case "$$name" in \#*) continue ;; esac; \
		out=$$(experiments/lib/derive-layer.sh experiments/fixtures/derive-layer/$$name $$receiver); \
		got=$$(printf '%s\n' "$$out" | sed -n 's/^layer=//p'); \
		got_reason=$$(printf '%s\n' "$$out" | sed -n 's/^reason=//p'); \
		if [ "$$got" != "$$expected" ]; then \
			echo "FAIL derive-layer: $$name -> $$got, expected $$expected" >&2; \
			fail=1; \
		elif [ -z "$$reason" ] || [ "$$got_reason" != "$$reason" ]; then \
			echo "FAIL derive-layer: $$name -> $$got as expected, but not for the recorded reason" >&2; \
			echo "  recorded reason=$$reason" >&2; \
			echo "  derived  reason=$$got_reason" >&2; \
			fail=1; \
		else \
			echo "ok  derive-layer: $$name -> $$got, for the recorded reason"; \
		fi; \
	done < experiments/fixtures/derive-layer/expected.txt; \
	[ "$$fail" = "0" ] || exit 1
