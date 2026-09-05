# agent-mesh-lab Makefile. Target names are fixed by the project plan;
# implementations are added as each task needs them.

CLUSTER_NAME := agent-mesh-lab
KIND_CONFIG  := kind-config.yaml
NAMESPACE    := lab

.PHONY: cluster-kind cluster-eks step-1 step-2 step-3 verify-baseline teardown ledgers test

cluster-kind:
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi

cluster-eks:
	@echo "cluster-eks: not used in Gate 1; kind is the environment until a proposal Sec.5 trigger fires" >&2
	@exit 1

step-1:
	kubectl kustomize deploy/step-1-nomesh | KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=$(CLUSTER_NAME) ko apply -f -
	kubectl -n $(NAMESPACE) rollout status deployment/mockllm --timeout=120s

step-2:
	@echo "step-2: not implemented yet (Gate 2)" >&2
	@exit 1

step-3:
	@echo "step-3: not implemented yet (Gate 3)" >&2
	@exit 1

verify-baseline:
	@echo "verify-baseline: not implemented yet" >&2
	@exit 1

teardown:
	kind delete cluster --name $(CLUSTER_NAME)

# ledgers LWI=<id> [OUT=<dir>]: print the mockllm invocation-ledger lines
# for one logical_work_item_id, read from the running mockllm pod's stdout.
# This is a skeleton for the model invocation ledger only; Task 4 extends
# it to also print the worker's pre-dispatch ingress and execution ledgers
# for the same work item.
ledgers:
	@if [ -z "$(LWI)" ]; then \
		echo "usage: make ledgers LWI=<id> [OUT=<dir>]" >&2; \
		exit 1; \
	fi
	@LOGS=$$(kubectl logs deploy/mockllm -n $(NAMESPACE)) || { \
		echo "ledgers: kubectl logs failed" >&2; \
		exit 1; \
	}; \
	LINES=$$(printf '%s\n' "$$LOGS" | \
		jq -R -c --arg lwi "$(LWI)" 'fromjson? | select(.ledger == "invocation" and .logical_work_item_id == $$lwi)') || { \
		echo "ledgers: jq failed" >&2; \
		exit 1; \
	}; \
	if [ -z "$$LINES" ]; then \
		echo "ledgers: no invocation ledger lines found for logical_work_item_id=$(LWI)" >&2; \
		exit 1; \
	fi; \
	if [ -n "$(OUT)" ]; then \
		mkdir -p "$(OUT)"; \
		printf '%s\n' "$$LINES" > "$(OUT)/invocation.jsonl"; \
	fi; \
	printf '%s\n' "$$LINES"

test:
	go test ./...
