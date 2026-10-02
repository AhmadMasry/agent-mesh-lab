# CLAUDE.md — agent-mesh-lab

## What this repository is

An experiment lab that produces **counted, traced findings** about how A2A agent traffic behaves under retries, transport failure, and network-layer policy on Kubernetes, with Istio Ambient and agentgateway on the path. It exists to show how agentic traffic — A2A, model and MCP calls — is carried and observed on these projects, one counted reading at a time. The findings feed a KubeCon + CloudNativeCon Europe 2027 submission. Nothing here is, or is described as, a production system.

## Read these first, every session

1. `docs/PROPOSAL.md` — **frozen.** Do not edit it. Do not redesign the experiments, rename them, add scope, or "improve" the method. If something in it looks infeasible or wrong, write a dated note in `docs/proposal-notes.md` and stop for a human decision.
2. `docs/proposal-notes.md` — the author's dated decisions since the proposal froze (topology, added rows, reframings). They are in force; read all of them. "Decisions in force" below is their summary, not a replacement.
3. `findings.md` — where every task ends.
4. `versions.yaml` — every pin, each with the URL it was verified from.
5. `docs/experiment-a-checklist.md` — Experiment A's gates, closed on 2026-09-19 (all boxes ticked). History; later Experiment A work is in `findings.md`.

## Non-negotiable rules

1. **Done means a recorded count.** A task is complete when `findings.md` has an entry with numbers from a ledger and the pins used. "It works," "deployed successfully," or a passing smoke test is not done.
2. **Pins come from documents fetched in this session**, never from memory. Record the value and the source URL in `versions.yaml`. If you cannot verify a version or a feature's availability, say so and stop; do not propose a plausible number.
3. **Never write a findings entry from expectation.** If the run did not happen, there is no entry. If a run happened and the result is "as documented," that is an entry.
4. **Fixtures must not retry.** The mock model endpoint, the replay harness, and the load client contain no retry logic, and every HTTP client they use has retries explicitly disabled and the setting recorded. The baseline experiment depends on this. Do not add "robustness" retries anywhere.
5. **Ledgers before agent logic.** The pre-dispatch ingress ledger sits at the HTTP/JSON-RPC boundary *before* the A2A SDK sees the request. The execution/task ledger records what the SDK dispatched and every Task created. The model invocation ledger records every call with its work-item and task identity. Build and verify these before touching agent behaviour.
6. **Scope is exactly:** a Python agent (official `a2a-python`), a Go agent (official `a2a-go`), a controllable OpenAI-compatible model endpoint, a replay harness, a load client, Istio Ambient, agentgateway, an OpenTelemetry pipeline with a trace backend and Prometheus. **Do not add:** dashboards, Grafana, Kiali, an Envoy-waypoint comparison, KEDA, Karpenter, Valkey, chaos tooling, databases, memory systems, a third agent, or any other project. If you believe one is required, write a note in `docs/proposal-notes.md` and stop.
7. **A2A target is v1.0.** Canonical operation names (`SendMessage`, `SendStreamingMessage`, `GetTask`, `CancelTask`, `SubscribeToTask`). Capture the `A2A-Version` header from a real request for each SDK and record it. If an SDK negotiates 0.x, record it as a finding; do not paper over it.
8. **Environment:** kind first. Move to EKS only on one of the four triggers in `docs/PROPOSAL.md` §5, and record which trigger fired in `findings.md`. Kustomize overlays for agents, mesh, and telemetry never reference the cluster type.
9. **Language.** Use: tested, counted, measured, observed, reproduced, compared, found, under this configuration, for this binding, at this version. Never use: production, production-ready, battle-tested, works perfectly, robust, enterprise-grade. This applies to code comments, commit messages, README text, and findings.
10. **Task discipline.** One checklist box or one approved task per commit or PR, with its findings entry in the same commit. Do not bundle. No code for an experiment exists before its method is approved in `docs/proposal-notes.md`, and no code is written to answer a question: a question, or "let's confirm", is answered by a live check shown to the author first.
11. **Upstream.** A behaviour that looks like a project gap gets a minimal reproduction and a draft issue text in `docs/upstream/`. It is filed by a human, and linked only after it is filed.

## Repository layout

```
agent-mesh-lab/
├── CLAUDE.md
├── README.md
├── findings.md
├── versions.yaml
├── Makefile
├── kind-config.yaml
├── docs/
│   ├── PROPOSAL.md                  # frozen
│   ├── proposal-notes.md            # the author's dated decisions since the freeze
│   ├── experiment-a-checklist.md    # closed 2026-09-19
│   ├── walkthrough.md               # the lab, step by step, from a deleted cluster
│   └── upstream/                    # draft issue texts, one file each, each with its Status line
├── agents/
│   ├── orchestrator/                # Python, a2a-python; same behaviour as worker, Agent A by default
│   └── worker/                      # Go, a2a-go; hosts the ingress and execution ledgers
├── fixtures/
│   ├── mockllm/                     # Go; OpenAI-compatible; failure injection; invocation ledger
│   ├── replay/                      # Go; controlled duplicate-delivery harness (modes M1–M3)
│   └── loadgen/                     # Go; a2a-go client
├── internal/                        # Go packages shared by the binaries: a2areq, httpclient (retries off), otel
├── deploy/
│   ├── base/
│   ├── step-1-nomesh/               # the lab with no mesh
│   ├── step-2-ambient-agw/          # Istio ambient (L4), agentgateway's control plane, agw-central, STRICT
│   ├── step-2b-agw-ingress-egress/  # the agentgateway ingress; the model route on agw-central
│   ├── step-2c-gate2/               # the orchestrator's route on agw-central; the worker's ingress route
│   └── step-3-stress/               # telemetry (collector, Jaeger, Prometheus), tracing, access logs, retry route sets
└── experiments/                     # one runnable script per checklist item or row; writes findings input
    ├── lib/                         # the trace exporter and the layer-attribution tool
    ├── fixtures/                    # the tools' test fixtures (`make test`)
    └── runs/                        # the committed records findings entries cite
```

## Make targets (names are fixed; implement as needed)

`cluster-kind` · `cluster-eks` · `step-1` · `step-2` · `step-2b` · `step-2c` · `step-3` · `verify-baseline` · `replay MODE=<M1|M2|M3> RECEIVER=<go|py>` (and `replay-waypoint`, `replay-ingress`) · `matrix RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=…]` · `retry-on ROUTE=<set>` / `retry-off [ROUTE=<set>]` · `ledgers` (print all three for a given work item) · `export-trace` · `test` · `orchestrator-image` · `scan-images` · `teardown`

A change to any deployed path (`deploy/`, `Makefile`, `agents/`, `fixtures/`, `internal/`, `experiments/lib/`, `experiments/*.sh`, `go.mod`, `go.sum`, `.ko.yaml`, `kind-config.yaml`) is proven by a rebuild from a deleted cluster — `make teardown` through `make step-3`, make targets only, no manual step — and the standard proof: the clean check, the trace per work item with dangling parents and the GenAI summary, the Prometheus targets, the STRICT posture with the plaintext probe and the per-hop connection security, both proxies' config dumps, and the retry knobs last.

## Conventions

- **Go:** one module at the repository root; each binary in its listed directory; images built with `ko`. Standard library HTTP with retries explicitly disabled where the transport would otherwise replay.
- **Python:** one project under `agents/orchestrator/` with a committed lockfile; images built from `agents/orchestrator/Dockerfile`.
- **Identity fields** appear in every ledger line: `logical_work_item_id`, `messageId`, `taskId` (may be empty), plus JSON-RPC `id` and body hash on the ingress ledger.
- **Run outputs** cited by a findings entry are committed under `experiments/runs/<date>-<item>/` as small CSV or JSONL. Large or ephemeral logs are ignored.
- **Commits:** `type(scope): summary` — e.g. `feat(worker): pre-dispatch ingress ledger`. One checklist box or approved task per commit or PR; the findings entry ships in the same commit. Cite a commit by its subject and a built tree by its deployed subtree and blob ids: history was rewritten on 2026-09-19, and SHAs from before that day do not resolve.
- **Kustomize:** every overlay applies cleanly on top of the previous step; nothing is edited in place across steps.
- **Records are append-only.** A dated findings entry or run record is never edited; a correction is a dated note beside it.
- **No host-identifying string** in any committed file: no host name, serial, device or product name, or power-assertion owner. Host-sleep records carry Sleep, Wake, DarkWake and Maintenance lines and counts only. A task starts no keep-awake and changes no power setting, and never claims none was active: the agent harness holds its own.

## Decisions in force (summary; the dated notes and entries are the record)

- **Topology (2026-09-19).** Every agentic L7 hop — A2A, LLM and MCP traffic — goes through agentgateway-managed proxies: the ingress `agentgateway-ingress` and one central waypoint-and-egress proxy `agw-central` (class `agentgateway`). Istio is L4 only: ambient ztunnel, no istiod-managed waypoint. Nothing custom on either.
- **Installation.** Helm wherever the project publishes a chart; Istio's configuration in its Helm values (`meshConfig`), never IstioOperator; sub-components the lab does not use are disabled.
- **Tracing.** No sampling anywhere: every emitter at 100 %. Istio through `meshConfig` (extension provider and default providers); agentgateway through one `AgentgatewayPolicy` per Gateway. Python spans by zero-code instrumentation, the `opentelemetry-instrument` command in the image's CMD (the OpenTelemetry Operator is not used); Go spans by the otelhttp wrappers in `internal/otel`; no eBPF.
- **mTLS.** Mesh-wide STRICT. The mock model endpoint, the agentgateway control plane and the telemetry namespace are outside the mesh; one port is PERMISSIVE (the ingress's metrics port, 15020). `agw-central`'s namespace is not enrolled: the proxy terminates HBONE on 15008 itself, with its own SPIFFE identity.
- **Images.** Go images by `ko` on the latest Go; the orchestrator by its own multistage Dockerfile; every image runs with a read-only root filesystem, as non-root.
- **Versions.** "Latest" means the latest stable release. A project with no stable line is pinned at the latest release of the only line it has, and named so in `versions.yaml`.

## `findings.md` entry format

```
## <Gate or Experiment> / <receiver> / <mode or run> — <question>
- Versions: k8s=<> istio=<> agentgateway=<> gateway-api=<version, channel> a2a-spec=<commit> a2a-go=<> a2a-python=<> openai-python=<>
- Environment: kind | eks (trigger, if eks)
- Method: <what ran, how many repetitions>
- Result: <counts from the three ledgers; run output path>
- Interpretation: <one paragraph; "as documented" is a valid interpretation>
- Follow-up: <docs/upstream/<file> | none>
```

## When unsure

Stop and ask. A note in `docs/proposal-notes.md` is always preferable to a workaround, a guessed version, or a widened scope. If you notice a rule in this file slipping, say so and re-read this file before continuing; do not stop or suggest a new session on account of context length.

## Delegation in this repository

Subagents may fetch pin documents and run `make test` or experiment scripts on your behalf; the pin value and its source URL still go into `versions.yaml`, and the counts still go into `findings.md`, in the same task. A subagent's report is not a recorded count.

## Compact instructions

When compacting, preserve exactly: every pin verified this session with its source URL; every ledger count and run output path produced this session; the checklist item or approved task in progress and its state; the decisions in force that were consulted; and any note written to `docs/proposal-notes.md`.
