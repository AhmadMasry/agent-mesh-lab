# Can You Retry an Agent? — Proposal v6 (frozen)

*KubeCon + CloudNativeCon Europe 2027, Barcelona, 15–18 March 2027. CFP closes 11 October 2026.*
*Ahmad Al-Masry (Harri) and Jackie Maertens (Microsoft; Istio maintainer). Revised 4 September 2026 after fourth external review. Supersedes v5. Correction release; the design is frozen after this version. Further changes come from experiment data, not prose review.*

**Track: Agentic AI.** Locked.
**Case study: No.** This is an experimental investigation, not a real-world organisational implementation.
**Protocol target: A2A v1.0**, canonical v1 operation names (`SendMessage`, `SendStreamingMessage`, `GetTask`, `CancelTask`, `SubscribeToTask`). Version negotiation in A2A uses Major.Minor, so "1.0" is the correct target; the exact specification revision and each SDK version are pinned separately (§4.5).

## 1. Editorial direction

An engineering investigation of an emerging distributed-systems behaviour. Not an architecture, not a case study, not a product comparison.

> A question about how cloud-native networking behaves when one request represents an expensive, long-running, streamed, non-deterministic, possibly side-effecting agent work item. The smallest interoperable system that could answer it was built, deliberately broken, counted and traced, so that Kubernetes practitioners can see what to verify before applying familiar networking policies to agent workloads.

Nothing here refers to any production environment. Credibility comes from a reproducible environment, defined questions, controlled failures, ground-truth ledgers, open protocols, pinned versions, and the pairing of a platform practitioner with a mesh maintainer.

*This internal document uses "we." The Sessionize description and benefits text must be written in the third person (§7).*

## 2. The conceptual model

One logical work item can become one or more A2A messages; each message can be delivered over one or more network attempts; each delivery can produce downstream side effects. Four levels, and the harm under investigation lives in the gaps between them.

```
Logical work item
    ↓
A2A operation / Message           (messageId → Task/taskId, when task-based execution is created)
    ↓
Network delivery / attempt         (what proxies and clients retry)
    ↓
Downstream side effect             (model invocation, tool call, external action)
```

"Task" is reserved for the A2A protocol object. Not every `SendMessage` creates one — the server may return a `Task` or a direct `Message` — so the model does not assume a `taskId` exists until the protocol says it does.

Two deliveries are harmless if the receiver deduplicates them. Two side effects are not. The question practitioners need answered is not "did the network retry?" but **"did two attempts create two pieces of work?"**

The protocol puts the question on the table: Send Message operations MAY be idempotent, and agents may utilize the messageId to detect duplicate messages. May, not must. Whether a transport-layer retry is safe therefore depends on what the receiving implementation chose to do with an identifier the protocol left optional.

The talk's answer to its own title:

> A retry occurs at the transport layer, but safety is determined by the relationship between transport attempts, A2A message identity, task lifecycle, and downstream side effects. One is not retrying "an agent"; one is retrying one layer of a multi-layer operation.

## 3. Problem and question

**Premise.** Familiar infrastructure policies — retries, timeouts, request-level load balancing, path-oriented authorization — are often applied under assumptions that do not necessarily hold when one request represents expensive or side-effecting agent work.

We do not claim these mechanisms were designed only for cheap idempotent requests, or that service meshes cannot carry streaming or long-lived traffic. The question is what commonly applied policies do to A2A traffic, whether the protocol's optional safeguards are exercised by real implementations, and whether an operator can tell.

**Central question.**

> When A2A interactions meet retries, transport failures, and network-layer authorization: which layer acts, whether message and task identity survive it, what is duplicated or lost, and which layer had enough information to decide.

## 4. Method

### 4.1 Topology

```
client → Agent A → agentic/network layer → Agent B → controllable model endpoint
```

Istio Ambient and agentgateway are on the path only where required to answer the networking questions. Agent B and the model endpoint are under our control so that deliveries, dispatches, and invocations can be counted authoritatively. Nothing else is added unless an experiment requires it.

### 4.2 Two agents, built independently, as method

Two independently built agents using different language and framework stacks: a Python agent built with Strands Agents and its A2A support, and a Go agent built with the official A2A Go SDK. Two implementations make implementation-dependent differences visible rather than automatically attributed to the protocol or the network; they do not by themselves prove where the protocol/framework boundary lies, and the proposal does not claim they do. A Java agent on the official `a2a-java` SDK is added only if a finding requires a third implementation to be credible. No SDK is a subject of the talk.

### 4.3 Evidence: three measurement boundaries, with traces to explain them

No claim is made that every physical attempt carries a distinct identifier; a gateway retry may replay a byte-identical request. Evidence is instead collected at three boundaries, independently of whether tracing survives the event under study:

| Boundary | Ledger | Records | Distinguishes |
|---|---|---|---|
| Gateway → Agent B, **before** the A2A SDK's duplicate handling or task processing | **Pre-dispatch ingress ledger** | Every inbound HTTP/JSON-RPC request with its `messageId` | Physical deliveries |
| Inside Agent B's A2A server, after SDK handling | **Execution/task ledger** | Every message the SDK dispatched to the executor; every `Task`/`taskId` created | What the implementation accepted for execution |
| Model endpoint | **Invocation ledger** | Every call, attributed to the logical work item and `taskId` (if any) that caused it | Downstream work performed |

The three ledgers make the chain explicit: *delivered twice → dispatched once → model called once* is a different finding from *delivered twice → dispatched twice → model called twice*, and a ledger placed only inside the application handler would collapse the two. Identity is carried as: `logical_work_item_id` (assigned per test case), the native A2A `messageId` (client-created), and the resulting `taskId` where one exists. OpenTelemetry traces and gateway access telemetry then explain *which layer* produced each delivery and *why*. Ledgers are ground truth; traces are the explanation.

Two measurement questions run through everything: can one logical work item be distinguished from multiple physical attempts, and where does trace context survive automatically versus where must application instrumentation take responsibility?

### 4.4 Experiments

#### A — One Work Item, Multiple Attempts (central)

*Where retries happen, whether message identity survives them, what they duplicate, and how retry policies compose.*

A separates two questions that are easy to conflate, then combines them.

**A.1 Receiver semantics under controlled duplicate delivery.** A controlled sender/replay harness sends the *same serialised A2A `Message` with the same `messageId`* twice, through the gateway, to each receiver in turn — the Go receiver, then the Strands receiver. Only the receiver changes; the stimulus is identical. The three ledgers record deliveries, dispatches, tasks created, and model invocations. This answers: *when an identical message arrives twice, does this implementation deduplicate it, create a second task, or do the work again?*

**A.2 Client retry semantics.** Separately, using the real clients: when the Strands A2A client retries, does it reuse the original `messageId` or construct a new message? When the `a2a-go` client retries? This is a property of the sender and is measured independently of A.1.

**A.3 Retry-location matrix.** With A.1 and A.2 known, failures are injected at a controlled point and retries enabled one layer at a time. Retries are first disabled at every reachable layer and the baseline *verified* retry-free by the ledgers — HTTP client libraries retry on their own under some conditions and are checked, not assumed.

| Run | A2A client retry | Gateway retry | Agent B / model-client retry | Question |
|---|---|---|---|---|
| Baseline | off | off | off | What does raw failure look like, and is the baseline truly retry-free? |
| R1 | on | off | off | What does a client-level retry duplicate, given A.2? |
| R2 | off | on | off | R2 configures a gateway-level retry on the A2A request using the Gateway API `HTTPRoute` retry; the experiment verifies whether A2A message identity and body are preserved across attempts, and what Agent B and the model then record |
| R3 | off | off | on | What does an application/model-client retry duplicate below the A2A layer? |
| R4 | on | on | on | What happens when policies compose? |

The `HTTPRoute` retry field's Gateway API channel requirement at the pinned version is confirmed on day one and recorded; current agentgateway and Istio documentation both install experimental Gateway API CRDs in their examples.

**Results table (template — the core slide, filled only from runs, once per receiving implementation):**

| Retry layer | Deliveries at B (pre-dispatch) | Dispatched by A2A server | Distinct `messageId`s | Tasks created | Model invocations | Classification |
|---|---:|---:|---:|---:|---:|---|
| None (baseline) | 1 | 1 | 1 | 0 or 1 | 1 | baseline |
| Client (R1) | | | | | | |
| Gateway (R2) | | | | | | |
| Model client (R3) | | | | | | |
| Composed (R4) | | | | | | |

Classification: safe, inefficient, or potentially dangerous for side-effecting operations. The target finding has the form: *a gateway retry delivered the same message twice; implementation X dispatched it once and preserved one task, implementation Y dispatched it twice* — or *both dispatched once and neither duplicated work* — or whatever the ledgers show. "No layer retried under default configuration" is a valid, reportable result. The question the experiment turns on: **does transport-layer retry behaviour preserve or violate A2A task lifecycle semantics, and did the implementation exercise the protocol's optional safeguard?**

#### B — Transport Failure Without Task Failure

*Whether a streamed A2A task survives loss of its transport, and whether resubscription resumes work or duplicates it.*

A2A v1.0 separates task state from the connection that streams its updates and provides `SubscribeToTask` for reattaching to an active task; the specification requires the operation to return a Task object as the first event in the stream, representing the current state of the task at the time of subscription. So B asks a protocol-semantic question — *did we lose a connection, or did we lose a task?* — and then whether infrastructure recovery converts the first into the second.

Agent A starts a `SendStreamingMessage`; Agent B begins model work; the proxy on the path is removed or replaced; the stream dies; the client reconnects with `SubscribeToTask`.

Captured before disruption: `logical_work_item_id`, `messageId`, `taskId`. Captured after `SubscribeToTask`: the `taskId` reattached to, the first returned `Task` state, and the model invocation count. The result takes the form: *transport disappeared at T+n s; the Task continued; `SubscribeToTask` reattached to the original taskId; model invocations remained one* — or whatever happened. Duration is "long-running streamed task," sized to the experiment.

#### C — The Semantic Policy Boundary

*Which networking or security layer has enough information to authorize an A2A operation.*

The question is not whether one operation can be denied while another is allowed. It is: **what can workload identity, L4 policy, Gateway API routing and policy, and an A2A-aware gateway each actually distinguish about an A2A interaction?**

Two facts shape the experiment. First, binding matters: with the JSON-RPC binding the operation is the `method` field inside the body and operations share an HTTP endpoint, whereas the REST binding exposes operation-oriented paths (`POST /message:send`) and gRPC exposes methods. Findings are stated per binding; JSON-RPC is the primary case. Second, in the current Istio integration agentgateway proxies are configured exclusively through Kubernetes Gateway API resources; Istio's own policy APIs (`AuthorizationPolicy`, `RequestAuthentication`, `Telemetry`, and others) are not applied to them, agentgateway's native configuration is not managed by Istio in this integration, and surfacing that non-Gateway-API policies are not enforced is still open work upstream. The boundary is tested at a stated version, not assumed.

C is not forced to produce a successful deny. The stronger finding may be a map with a gap in it: *layer X sees identity but not operation semantics; layer Y could understand the operation but cannot currently receive the relevant policy through this integration; therefore this decision belongs at Y once a mechanism exists, or at the application until then.* A demonstrated inability at one layer, explained, is as valuable as a working deny at another.

### 4.5 Pins and reproducibility

Pinned and recorded on day one: Kubernetes; Istio; agentgateway; Gateway API version and channel; A2A specification revision (commit); `a2a-go`; the Python A2A SDK that Strands installs; Strands. The A2A wire version each SDK actually selects is confirmed by capturing the `A2A-Version` header on a real request — Strands' A2A support is documented, but the wire version it selects is not stated publicly and is not assumed. If either SDK negotiates v0.x, that is recorded as an interoperability finding.

All findings are re-run against current versions before the conference. The experiments, ledgers, replay harness, and configurations used for the talk will be made reproducible and publicly available. Before the CFP deadline enough is built to confirm feasibility and obtain initial findings, starting with A; a polished public lab is a deliverable of the talk, not a precondition of the submission.

## 5. Co-presenter positioning

Each result is examined from two sides:

- **Platform/operator (Ahmad):** what the ledgers and traces showed when A2A traffic met networking and mesh policy.
- **Istio maintainer (Jackie):** why the layer behaves that way, what is intentional, which configuration assumptions matter, and where a genuine gap exists.

Expected behaviour gets explained. Surprising behaviour or a project limitation gets named and — once filed — linked. The mesh is apparatus, not the subject.

## 6. Language standard

Use: *tested, counted, measured, observed, reproduced, compared, found, under this configuration, for this binding, at this version, in these failure scenarios.*

Do not use: *production-ready; battle-tested; the correct architecture for agents; agents are simply microservices; service meshes do not work for agent traffic; designed only for short-lived request/response; defaults tuned for microservices.*

Do not claim to have filed upstream until an issue or PR URL exists. Working text: *"Where a finding exposes a project gap, the speakers will file it upstream and identify the issue in the final talk."* Upgrade only where true.

**The Sessionize description and benefits fields are written in the third person and in full sentences**, per the CFP. No "we," no "I."

## 7. Submission 1 — main session (30 minutes)

**Title:** Can You Retry an Agent? Failure Semantics for A2A on Kubernetes

**Case study:** No.

**Description (third person; fit to the Sessionize limit):**

> An A2A operation can run for minutes, stream its output, trigger billable inference, and perform external side effects. That makes familiar infrastructure policies worth re-examining: retries, timeouts, request-level load balancing, and path-oriented authorization are often applied under assumptions that do not necessarily hold when one request represents expensive or side-effecting agent work.
>
> One logical work item can become several A2A messages, each delivered over several network attempts, each able to cause downstream work, and the protocol leaves duplicate detection optional. So what actually happens when a proxy retries? This session reports a controlled experiment: two independently built agents, in Python and Go, on Kubernetes with Istio Ambient and agentgateway on the path, broken deliberately, with ledgers at the receiving agent and the model endpoint counting every delivery and invocation and OpenTelemetry explaining each one.
>
> [FINDING A — which layer's retry delivered which message identity, whether the receiving implementation deduplicated it, and what was duplicated downstream.]
> [FINDING B — whether a streamed task survived the loss of its transport, and whether `SubscribeToTask` resumed work or repeated it.]
> [FINDING C — which layer could see enough of a JSON-RPC-bound A2A operation to authorize it, and which could not.]
>
> The session shows that a retry does not retry "an agent" but one layer of a multi-layer operation, and that safety depends on how transport attempts, message identity, task lifecycle, and side effects line up. Attendees leave with the questions to ask of their own stack before familiar networking policies meet agent traffic, whatever framework or gateway they run.

**Benefits to the ecosystem (third person):**

> Agent workloads are arriving on clusters where familiar microservice-oriented networking policies are already in place. This session gives operators evidence rather than assertions: counted, traced behaviour of A2A traffic under retries, transport failure, and policy, reproduced against pinned versions of Istio, agentgateway, and A2A v1.0, with two independently built agents so implementation-dependent differences are visible rather than automatically attributed to the protocol or network. Where behaviour is intentional, an Istio maintainer explains why. Where a finding exposes a project gap, the speakers will file it upstream and identify the issue in the final talk. The experiments, ledgers, and configurations will be published so anyone can rerun them against their own stack. The work-item → operation → attempt → side-effect model gives practitioners a practical way to reason about retries across agent and networking layers.

**Placeholder policy.** Findings are inserted only after runs are complete. If a finding is unavailable by 8 October, the sentence states the question and method, never a predicted result.

## 8. Submission 2 — 80-minute tutorial (draft; third person; low effort until A has a finding)

**Title:** Build, Break, Trace: A Reproducible Agent Traffic Lab on Kubernetes

**Case study:** No.

**Distinction.** The session answers "what did the experiments teach about agent failure semantics?" The tutorial answers "how can practitioners reproduce these failures, observe them, and reason about the behaviour?" Same lab, different deliverable.

**Description (draft):**

> Participants bring a laptop and deploy two interoperable A2A agents, one in Python and one in Go, on a Kubernetes cluster; place Istio Ambient and agentgateway on the path between them; and wire OpenTelemetry so a single trace follows a work item from client to model endpoint, with ledgers counting every delivery and invocation. Then they break it: inject a failure at the model, remove a proxy under a streamed task, and attach a policy to an A2A operation. After each break, participants read the ledgers and the trace, identify which layer retried, recovered, or refused, change one configuration, and run it again. They leave with a lab they can rerun and a method for testing their own agent stack before conventional networking policies meet it.

| | Main session | Tutorial |
|---|---|---|
| Organising principle | By finding: A, B, C, each from operator and maintainer perspective | By the participant's loop: deploy → trace → break → read → change → rerun |
| Attendee leaves with | What happened, why, and what to verify | A working lab and a method |
| Only it can do | Behaviour across versions; patterns over many runs; the maintainer's *why* | The attendee's own hands on the policy that changed the result |
| Findings appear as | The content | Checkpoints: "here is what you should now see" |
| Main risk | Findings not ready by 8 October | Participant environment: promise only what fits 80 minutes from a pre-built start |

Speaker limit: up to three proposals per speaker, but only one non-panel session can be selected per speaker per event. Submitting both improves the odds of one acceptance; it does not yield two slots.

## 9. Submission 3 — observability (conditional, not drafted)

Working title: *One Trace Across Two Agents: Where A2A Context Actually Breaks.* Pursued only if A–C reveal an independently strong observability finding: propagation differences between the two agents, missing context across gateways, inability to correlate logical work items with deliveries, duplicate spans from retries, application and infrastructure telemetry that disagree with the ledgers, or an instrumentation gap that required a real solution. Otherwise observability stays inside the main session as evidence. Decide after 24 September.

## 10. Out of scope

KEDA, Karpenter, Valkey, Gateway API extensions, inference infrastructure, databases, memory systems, additional agents, additional projects — unless a specific experiment requires them.

## 11. Effort allocation and timeline

Eighty percent of effort before 1 October goes to Experiment A. The tutorial description is finalised only after A has produced at least one filled row of the results table. Two non-obvious measured findings by 1 October is the bar for calling this a serious submission.

| Date | Milestone |
|---|---|
| 4 Sep 2026 | v6 frozen |
| 10 Sep | `A2A-Version` header captured from both SDKs; three ledgers producing counts; baseline verified retry-free; Gateway API channel requirement for `HTTPRoute` retry recorded |
| 14 Sep | A.1 (controlled duplicate delivery) and A.2 (client retry identity) complete for both implementations |
| 17 Sep | A.3 matrix R1–R4 run against both receiving implementations, pinned versions |
| 24 Sep | B and C initial findings recorded |
| 1 Oct | Third-person descriptions finalised with findings inserted; reviewed by Jackie and one NA 2026 programme committee member |
| 8 Oct | Submit (CFP closes 11 Oct, 23:59 CEST) |
| 7 Dec | Notifications |
| Feb 2027 | Re-run against current versions |
| 15–18 Mar 2027 | Conference |

## 12. Open decisions

1. Java agent — only if a specific finding requires a third implementation.
2. Whether C tests the REST or gRPC binding in addition to JSON-RPC — only if the JSON-RPC result needs the comparison to state the finding precisely.
3. Jackie's review of §5 and of her portrayal throughout.