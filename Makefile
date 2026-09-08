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

.PHONY: cluster-kind cluster-eks step-1 step-2 step-2b step-2c step-3 verify-baseline teardown ledgers replay replay-waypoint replay-ingress test orchestrator-image

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

# step-2c: the Gate 2 stimulus paths. Adds a second istiod-driven waypoint for
# the orchestrator Service, so each receiver has a waypoint of its own, and
# gives the worker its own hostname on the step-2b ingress, so an
# out-of-cluster stimulus can reach either receiver. The two receivers do not
# share one waypoint; the measured reason is in the kustomization comment.
# Applies on top of step 2b and is re-runnable: the overlay adds one Gateway,
# one Service label and one HTTPRoute and edits nothing in place, and `ko apply`
# rebuilds the Go images from the same sources to the same digests, so the
# Deployments are unchanged by a repeat run. Unlike step-1, step-2 and
# step-2b this does not depend on orchestrator-image: the Python image is
# already in the cluster and this overlay does not change its Deployment.
step-2c:
	kubectl kustomize deploy/step-2c-gate2 | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply --platform=linux/$(shell go env GOARCH) -f -
	# Programmed says istiod accepted the Gateway and provisioned for it; the
	# rollout wait after it says the proxy pod is ready to carry traffic.
	kubectl -n $(NAMESPACE) wait --for=condition=Programmed gateway/agentgateway-waypoint-orch --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/agentgateway-waypoint-orch --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/worker --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/orchestrator --timeout=180s

step-3:
	@echo "step-3: not implemented yet (Gate 3)" >&2
	@exit 1

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
#                 <OUT>/client.jsonl, which is where `make ledgers OUT=<dir>`
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
	if [ -n "$(OUT)" ]; then mkdir -p "$(OUT)"; printf '%s\n' "$$out" > "$(OUT)/client.jsonl"; fi; \
	exit $$rc

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
