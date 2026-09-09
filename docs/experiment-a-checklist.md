# Experiment A — Implementation Checklist

*Companion to Proposal v6 (frozen). This file changes; the proposal does not. Every box ends with something recorded, not something built.*

## Gate 1 — 10 September: instruments trusted

- [x] **Pins recorded**: Kubernetes, Istio, agentgateway, Gateway API version *and channel*, A2A spec revision (commit), `a2a-go`, `a2a-python`, `openai-python`.
- [x] **Wire version captured**: one real request from each SDK, `A2A-Version` header value recorded. If either negotiates 0.x → interoperability finding, recorded, proposal unchanged.
- [x] **Three ledgers producing counts** on a single clean request:
  - pre-dispatch ingress: sits at the HTTP/JSON-RPC boundary *before* the A2A SDK sees the request; records JSON-RPC `id`, A2A `messageId`, body hash, arrival time
  - execution/task: records what the SDK dispatched to the executor and every `Task`/`taskId` created
  - model invocation: records every call with the `logical_work_item_id` and `taskId` (if any) that caused it
- [x] **Baseline proven retry-free** by the ledgers, not by configuration: one injected failure, zero second deliveries. Check the places that retry quietly — Go's HTTP transport on stale connections, Python HTTP client defaults, any SDK-level retry — and record what had to be disabled.
- [x] **`HTTPRoute` retry channel requirement** at the pinned Gateway API version recorded (expected: experimental).
- [x] **Model endpoint deterministic**: fixed latency, fixed output, failure injection by count or by `logical_work_item_id`, so two runs are comparable.

## Gate 2 — 14 September: A.1 and A.2 complete for both implementations

### A.1 — Receiver semantics under controlled duplicate delivery

Replay harness modes. Run each against the Go receiver, then the Python receiver, through the gateway. Stimulus identical across receivers.

| Mode | JSON-RPC `id` | A2A `messageId` | Body | Distinguishes |
|---|---|---|---|---|
| M1 exact transport replay | same | same | identical | What a gateway or transport retry looks like to the receiver |
| M2 same logical message, new RPC | new | same | identical except `id` | Whether dedup is keyed on A2A `messageId` rather than on the RPC identifier |
| M3 control | new | new | identical otherwise | Whether dedup is keyed on identity rather than on body content |

For each mode × receiver, record: deliveries (pre-dispatch), dispatches, tasks created, model invocations, and the second response's shape (same `Task`? new `Task`? error?). Twenty repetitions minimum; report counts, not one run.

- [x] M1 × Go — recorded
- [ ] M1 × Python — recorded
- [ ] M2 × Go — recorded
- [ ] M2 × Python — recorded
- [ ] M3 × Go — recorded
- [ ] M3 × Python — recorded

### A.2 — Client retry identity

For each real client, force one retry and capture both attempts at the pre-dispatch ledger.

- [ ] `a2a-python` client: on retry, `messageId` reused or regenerated? JSON-RPC `id` reused or regenerated? Body identical?
- [ ] `a2a-go` client: same three questions.
- [ ] Where the retry is configured (SDK option, underlying HTTP client, none available) — recorded.

## Gate 3 — 17 September: A.3 matrix

Prerequisite: A.1 and A.2 results exist, so every matrix row can be interpreted.

- [ ] Baseline row filled for both receivers
- [ ] R1 (client retry only) — both receivers
- [ ] R2 (gateway `HTTPRoute` retry only) — both receivers. Record whether the gateway replayed an identical body and `messageId` (measure at pre-dispatch ledger; do not assume). Record whether request-body buffering was required for the retry to fire on a POST.
- [ ] R3 (model-client retry only) — both receivers
- [ ] R4 (composed) — both receivers
- [ ] Each row classified: safe / inefficient / potentially dangerous, with the one-line reason.
- [ ] Traces attached to each row attributing every second delivery to a layer. Where a trace could not attribute it, say so; the ledgers still count.

## Recording rules

- One `findings.md` entry per gate, per receiver, per mode or row. Include the pins.
- Numbers first, interpretation second, no adjective without a count behind it.
- Any behaviour that looks like a project gap gets a minimal reproduction and a draft issue the same day. File it only when the reproduction holds against the pinned version; link it only once filed.
- Anything that would change the *proposal* is written here as a note and left for after the runs. The proposal is frozen.