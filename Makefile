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

.PHONY: cluster-kind cluster-eks step-1 step-2 step-2b step-3 verify-baseline teardown ledgers test orchestrator-image

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

step-1: orchestrator-image
	kubectl kustomize deploy/step-1-nomesh | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# The orchestrator image keeps one tag, so a rebuilt image needs an explicit restart to be picked up.
	kubectl -n $(NAMESPACE) rollout restart deployment/orchestrator
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s

# step-2: Istio Ambient with agentgateway as the waypoint. Versions come from
# versions.yaml (gateway-api v1.6.2 experimental; istio 1.31.0 via the istioctl on
# PATH; agentgateway v1.5.0 through the waypoint image annotation in the overlay).
# A setup target, like step-1: it rotates all three Deployments, and the worker's
# log is a ledger source, so do not re-run it against a baseline in progress.
# The overlay pulls in step-1, whose orchestrator Deployment needs the buildpacks
# image; ko builds the Go images inline, so orchestrator-image is the only
# prerequisite that makes step-2 runnable on a cluster that never ran step-1.
GATEWAY_API_VERSION := v1.6.2
step-2: orchestrator-image
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
step-2b: orchestrator-image
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

step-3:
	@echo "step-3: not implemented yet (Gate 3)" >&2
	@exit 1

# verify-baseline [STEP=1|2] [REPS=5]: run the baseline (checklist box 4) on the
# running cluster; writes experiments/runs/<date>-baseline-step<STEP>/.
verify-baseline:
	STEP=$(if $(STEP),$(STEP),1) REPS=$(if $(REPS),$(REPS),5) experiments/gate1-baseline.sh

teardown:
	kind delete cluster --name $(CLUSTER_NAME)

# ledgers LWI=<id> [OUT=<dir>]: print the four ledgers for one
# logical_work_item_id, read from pod stdout: both agents' pre-dispatch
# ingress and execution ledgers (lines labelled with their source),
# mockllm's invocation ledger, and the loadgen Job's client line. Stdout
# carries only JSON lines (section headers go to stderr) so scripts can pipe
# it. `kubectl logs deploy/<name>` reads one pod, so this collection assumes
# exactly one replica of each agent and of mockllm. A source whose logs
# cannot be read is reported on stderr and skipped;
# finding nothing at all for the work item is an error. With OUT, each
# ledger is written as <OUT>/<name>.jsonl containing exactly the matching lines.
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
	CLIENT=$$(fetch -l job-name=loadgen-$(LWI) --tail=-1); \
	if [ -z "$$CLIENT" ]; then echo "ledgers: warning: no pod logs for job loadgen-$(LWI) (no such Job, or its pods are gone)" >&2; fi; \
	sel() { jq -R -c --arg lwi "$(LWI)" --arg ledger "$$1" --arg src "$$2" 'fromjson? | select(.ledger == $$ledger and .logical_work_item_id == $$lwi) | . + {source: $$src}' || { echo "ledgers: jq failed" >&2; exit 1; }; }; \
	INGRESS=$$( { printf '%s\n' "$$WORKER" | sel ingress worker; printf '%s\n' "$$ORCH" | sel ingress orchestrator; } ); \
	EXECUTION=$$( { printf '%s\n' "$$WORKER" | sel execution worker; printf '%s\n' "$$ORCH" | sel execution orchestrator; } ); \
	INVOCATION=$$(printf '%s\n' "$$MOCK" | sel invocation mockllm); \
	CLIENTL=$$(printf '%s\n' "$$CLIENT" | sel client loadgen); \
	if [ -z "$$INGRESS$$EXECUTION$$INVOCATION$$CLIENTL" ]; then \
		echo "ledgers: no ledger lines of any kind for logical_work_item_id=$(LWI)" >&2; exit 1; \
	fi; \
	if [ -n "$(OUT)" ]; then \
		mkdir -p "$(OUT)"; \
		for pair in "ingress=$$INGRESS" "execution=$$EXECUTION" "invocation=$$INVOCATION" "client=$$CLIENTL"; do \
			name=$${pair%%=*}; body=$${pair#*=}; \
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
