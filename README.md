# agent-mesh-lab

Can you retry an agent? A reproducible lab for A2A failure semantics on Kubernetes.

## What this is

An experiment lab that produces counted, traced findings about how A2A agent traffic behaves under retries, transport failure, and network-layer policy on Kubernetes, with Istio Ambient and agentgateway on the path. The findings feed a KubeCon + CloudNativeCon Europe 2027 submission. This is experiment apparatus, not a system intended for any other use.

## Read in this order

1. `docs/PROPOSAL.md` — the experiment design, v6, frozen. It is not edited; anything that would change it goes to `docs/proposal-notes.md` for a human decision.
2. `docs/experiment-a-checklist.md` — the working checklist for Experiment A, gate by gate. Every box ends with something recorded, not something built.
3. `findings.md` — one entry per gate, receiver, and mode or run. Numbers first, interpretation second. No entry without a run.
4. `versions.yaml` — every pin with the URL it was verified from. No value without a source.

Progress is read from the checklist and `findings.md`, not from this file.

## Method in one paragraph

One logical work item can become one or more A2A messages; each message can be delivered over one or more network attempts; each delivery can cause downstream side effects. Three ledgers count what happened at three boundaries: every inbound HTTP/JSON-RPC request before the A2A SDK sees it, every message the SDK dispatched and every Task created, and every model invocation attributed to the work item and task that caused it. OpenTelemetry traces explain which layer produced each delivery and why. Ledgers are ground truth; traces are the explanation. The proposal defines the experiments (A, B, C), the pins, and the language standard.

## Layout

Directories appear when their gate needs them.

```
agents/orchestrator/   Python, Strands Agents with A2A support
agents/worker/         Go, a2a-go; hosts the pre-dispatch ingress and execution ledgers
fixtures/mockllm/      Go; OpenAI-compatible model endpoint; failure injection; invocation ledger
fixtures/replay/       Go; controlled duplicate-delivery harness (modes M1–M3)
fixtures/loadgen/      Go; a2a-go client
deploy/                Kustomize: base, step-1-nomesh, step-2-ambient-agw, step-3-stress
experiments/           one runnable script per checklist item; cited run outputs under experiments/runs/
docs/upstream/         draft issue texts for behaviour that looks like a project gap; filed by a human
```

## Working rules

The rules for anyone, or any agent, working in this repository are in `CLAUDE.md`: done means a recorded count; pins come from documents fetched in the session; fixtures never retry; ledgers before agent logic; scope is fixed; the A2A target is v1.0; kind first; one checklist box per task.

## License

Apache License 2.0. See `LICENSE`.
