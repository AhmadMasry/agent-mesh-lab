# CLAUDE.md — agent-mesh-lab

## What this repository is

An experiment lab that produces **counted, traced findings** about how A2A agent traffic behaves under retries, transport failure, and network-layer policy on Kubernetes, with Istio Ambient and agentgateway on the path. The findings feed a KubeCon + CloudNativeCon Europe 2027 submission. Nothing here is, or is described as, a production system.

## Read these first, every session

1. `docs/PROPOSAL.md` — **frozen.** Do not edit it. Do not redesign the experiments, rename them, add scope, or "improve" the method. If something in it looks infeasible or wrong, write a dated note in `docs/proposal-notes.md` and stop for a human decision.
2. `docs/experiment-a-checklist.md` — the current work. Work only on the current gate.
3. `findings.md` — where every task ends.
4. `versions.yaml` — every pin, each with the URL it was verified from.

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
10. **Gate discipline.** No Gate 2 code exists until every Gate 1 box in the checklist is ticked with a findings entry. One checklist box per task. Do not bundle.
11. **Upstream.** A behaviour that looks like a project gap gets a minimal reproduction and a draft issue text in `docs/upstream/`. It is filed by a human, and linked only after it is filed.

## Repository layout

```
agent-mesh-lab/
├── CLAUDE.md
├── README.md
├── findings.md
├── versions.yaml
├── Makefile
├── docs/
│   ├── PROPOSAL.md                  # frozen
│   ├── experiment-a-checklist.md
│   ├── proposal-notes.md            # created only when something needs a human decision
│   └── upstream/                    # draft issue texts, one file each
├── agents/
│   ├── orchestrator/                # Python, a2a-python; same behaviour as worker, Agent A by default
│   └── worker/                      # Go, a2a-go; hosts the ingress and execution ledgers
├── fixtures/
│   ├── mockllm/                     # Go; OpenAI-compatible; failure injection; invocation ledger
│   ├── replay/                      # Go; controlled duplicate-delivery harness (modes M1–M3)
│   └── loadgen/                     # Go; a2a-go client
├── deploy/
│   ├── base/
│   ├── step-1-nomesh/
│   ├── step-2-ambient-agw/
│   └── step-3-stress/
└── experiments/                     # one runnable script per checklist item; writes findings input
```

## Make targets (names are fixed; implement as needed)

`cluster-kind` · `cluster-eks` · `step-1` · `step-2` · `step-3` · `verify-baseline` · `replay MODE=<M1|M2|M3> RECEIVER=<go|py>` · `matrix RUN=<baseline|R1|R2|R3|R4> RECEIVER=<go|py>` · `ledgers` (print all three for a given work item) · `teardown`

## Conventions

- **Go:** one module at the repository root; each binary in its listed directory; images built with `ko`. Standard library HTTP with retries explicitly disabled where the transport would otherwise replay.
- **Python:** one project under `agents/orchestrator/` with a committed lockfile; images built with Cloud Native Buildpacks.
- **Identity fields** appear in every ledger line: `logical_work_item_id`, `messageId`, `taskId` (may be empty), plus JSON-RPC `id` and body hash on the ingress ledger.
- **Run outputs** cited by a findings entry are committed under `experiments/runs/<date>-<item>/` as small CSV or JSONL. Large or ephemeral logs are ignored.
- **Commits:** `type(scope): summary` — e.g. `feat(worker): pre-dispatch ingress ledger`. One checklist box per commit or PR; the findings entry ships in the same commit.
- **Kustomize:** every overlay applies cleanly on top of the previous step; nothing is edited in place across steps.

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

Stop and ask. A note in `docs/proposal-notes.md` is always preferable to a workaround, a guessed version, or a widened scope. If context is running long and rules start slipping, say so; the human will start a fresh session.
