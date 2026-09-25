# Proposal notes

Dated notes on questions that touch `docs/PROPOSAL.md`, which is frozen. Each note records a decision or an open
question for the author; the proposal text itself does not change.

## 2026-09-08 — agentgateway ingress and egress under agentgateway's own control plane

Decision by the author. Gate 1 placed agentgateway on the path only as an Istio ambient waypoint driven by istiod
(the integration the proposal's §4.4 C describes, where agentgateway proxies are configured through Gateway API
resources alone). From step 2b on, two further agentgateway proxies are added under agentgateway's own control
plane (Helm charts `agentgateway-crds` and `agentgateway`, GatewayClass `agentgateway`), following the
agentgateway documentation's Istio ambient integration pages:

- an ingress gateway in front of Agent A (the client entry point), and
- an egress waypoint between Agent B and the model endpoint, with the model host modelled as an external
  destination through an Istio ServiceEntry, as those pages prescribe for an LLM provider.

Consequences the author accepts: (1) the topology gains two hops, `client → ingress → Agent A → waypoint →
Agent B → egress → model`; every baseline claim through the new hops needs its own recorded count (step 2b);
(2) Experiment C's premise widens: the proxies under agentgateway's own control plane can receive
agentgateway-native policy resources, which the istiod-driven waypoint cannot, so C's map of "what each layer
can distinguish" must state which control plane drives each hop; (3) one more pin, the agentgateway control
plane chart version, recorded in `versions.yaml`. The istiod-driven waypoint stays as the measured layer between
the two agents. The proposal text is unchanged.

## 2026-09-09 — one waypoint per receiver Service, and what the ingress hop actually traverses

Decision by the author. Gate 2's stimulus path rule sends an in-cluster stimulus through the istiod-driven
waypoint, which for the Python agent means enrolling `Service/orchestrator` on a waypoint the way step 2
enrols `Service/worker`. Enrolling both Services on the one waypoint step 2 created does not work at this
version. Measured on 2026-09-09 at Istio 1.31.0 with GatewayClass `istio-agentgateway-waypoint` and
agentgateway v1.5.0: with both Services bound to a single waypoint, requests addressed to
`orchestrator.lab.svc.cluster.local:8080` were answered by the worker, and adding a matching Service-attached
`HTTPRoute` for the orchestrator inverted it so that both Services were answered by the orchestrator. Isolated
to that one label by removing and restoring it. Reproduction and draft issue text:
`docs/upstream/istio-waypoint-shared-by-two-services-misroutes.md`, drafted against Istio because
`istioctl x internal-debug syncz` shows istiod pushing the agentgateway resources to that proxy.

The author's ruling: the orchestrator does not ship without a gateway on its in-cluster path, so
`deploy/step-2c-gate2` adds a second waypoint, `agentgateway-waypoint-orch`, for the orchestrator Service
alone. Two waypoint instances, one per receiver Service, instead of one shared. No HTTPRoute is attached to
the new waypoint; step 2's `worker` route keeps `Service/worker` as its only parentRef and stays on the
worker's waypoint. Measured after the change: each Service answers with its own agent card; an in-cluster
replay to the orchestrator Service produced orchestrator ledger lines whose `remote` is the new waypoint pod;
the worker's arrivals still come from `agentgateway-waypoint` and its counts are unchanged.

Consequences the author accepts: the topology carries one waypoint per receiver rather than one shared
waypoint between the two agents, so any claim about "the waypoint" in Gate 2 names which instance it means;
and one more Deployment in the `lab` namespace. The proposal text is unchanged.

The second measured fact this note records, because it corrects what Gate 2 entries were going to say. The
agentgateway ingress, running under agentgateway's own control plane, dials the backend **pod** on port 15008
rather than the Service VIP: `istioctl ztunnel-config connections` shows it addressing
`worker-<pod>.lab:15008` with remote target `worker-<pod>.lab:8080`, and the receivers' ingress ledgers
recorded the arrival from the ingress pod's address, not from a waypoint's. A Service-scoped waypoint is
therefore not on the ingress to receiver hop. Every Gate 2 entry's Method states it that way: an in-cluster
stimulus reaches its receiver through that receiver's own istiod-driven waypoint; an out-of-cluster stimulus
reaches its receiver through the agentgateway ingress and no waypoint.

## 2026-09-09 — one extra retry-location row, on the egress route (author's addition)

Decision by the author, taken when the Gate 3 plan was finalised and written down here when the row was run,
on 2026-09-09/10. The proposal's §4.4 A.3 matrix names five rows: a baseline and R1 to R4, whose retry
locations are the client, the gateway in front of the receiver, the receiver's own model client, and the four
composed. None of them puts a retry on the hop between the receiver and the model endpoint, which at step 2b
became a proxy of its own: the `agw-egress` waypoint under agentgateway's own control plane, carrying the
route to `model.lab.internal`. The author adds one row there.

The question it answers: does an egress gateway retry duplicate a model call, and what does the model endpoint
see when it does? Method: `make retry-on ROUTE=egress` (one stanza, `attempts: 1`, `backoff: 100ms`,
`codes: [500, 503]`, on `agentgateway-egress/model-via-agw`), every other retry layer asserted off, the mock
armed `http500` keyed by the repetition's work item so that both the call and its re-send are answered 500 —
the row measures the duplication, not a recovery — an in-cluster loadgen Job as the stimulus, the Python
receiver in model mode, twenty repetitions per receiver through the same harness every other row uses,
`experiments/gate3-matrix.sh RUN=egress`.

Consequences the author accepts: (1) the results table Gate 3 fills has one row more than the proposal's
template, marked as an addition rather than as one of the five; (2) the row carries no checklist box, because
the checklist follows the proposal; (3) it is counted and classified by the same rules as the five, so it can
be read beside them. The proposal text is unchanged.

The entry is `## Gate 3 / both receivers / egress-route retry — Does an egress gateway retry duplicate a model
call, and what does the mock see?` in `findings.md`, with its runs under
`experiments/runs/2026-09-10-a3-egress-go/` and `experiments/runs/2026-09-10-a3-egress-py/`.

## 2026-09-10 — a host-side image vulnerability scanner (Kubescape), added by the author

`CLAUDE.md` rule 6 fixes the scope: a Python agent, a Go agent, a controllable model endpoint, a replay
harness, a load client, Istio Ambient, agentgateway, and an OpenTelemetry pipeline with a trace backend and
Prometheus — and names chaos tooling, dashboards and "any other project" as things not to add. A vulnerability
scanner is not on the list. The author widened the scope on 2026-09-10 to include one, and this note records
that decision and its boundary rather than the tool arriving unannounced.

What was added: the **Kubescape CLI on the host**, run by `make scan-images` over the five images this lab
builds (the Python agent, and the four Go binaries — worker, mockllm, loadgen, replay). Kubescape is a CNCF
incubating project, read from https://www.cncf.io/projects/ on the day of the decision; Trivy and Grype, the
obvious alternatives, are not CNCF projects, and that is why this one was chosen.

The boundary, which is what keeps rule 6 meaningful: **nothing is installed in the cluster.** No Kubescape
Operator, no node agent, no host scanner, no CRD, no namespace. The cluster's component list is exactly what
it was. `make scan-images` reads images out of the local Docker daemon on the machine that builds them, writes
JSON per image and a `summary.csv` of counts by severity, and exits 0 whatever it finds.

Why the author judged it in scope for the lab's purpose: this repository's claim is that its findings are
counted and traced at named versions, and the images those findings ran on are part of what is named. A count
of what a scanner sees in each image on a given date, with the scanner version and its vulnerability-database
date beside it, is the same kind of artefact as a pinned version — it says what was there, not that anything
is safe.

What was deliberately NOT done: nothing is fixed in response to a scan. No base image was moved, no dependency
re-pinned, no `apt` package held back because a scan named it. A fix is the author's decision, taken separately
if at all, and a scan that changes the images would make the counts in `findings.md` describe images that no
longer exist. The first scan's counts are the entry
`## Gate 3 / n/a / image vulnerability scan — What does Kubescape count in each of our images on this date?`,
with its outputs under `experiments/runs/2026-09-10-images-rebuilt/scan/`.

The proposal text is unchanged.

## 2026-09-12 — Mesh-wide STRICT mTLS refused the model leg: the question asked, and the shape decided

Follow-ups 7 applied the STRICT `PeerAuthentication` the Istio documents prescribe for mesh level
(`security.istio.io/v1`, name `default`, in the root namespace `istio-system`, `spec.mtls.mode:
STRICT`; `deploy/step-2-ambient-agw/peer-authentication.yaml` cites the sentence behind every
field). It did what the documents say — a plaintext request from a pod outside the mesh went from
HTTP 200 to a connection reset — and it also refused one hop of the lab's own path, so the counted
in-mesh flow failed. The policy was reverted in the same session and the clean check verified to
pass again. Both attempts are counted in `findings.md` under
`## Gate 3 / both receivers / mTLS enforced — …`, with outputs under
`experiments/runs/2026-09-12-mtls-enforced/` (`attempt-1/` and `attempt-2/`).

The hop that refused, named by both sides:

- `agw-egress -> mockllm.lab.svc.cluster.local:8080`. The egress waypoint's own access log reads
  `http.status=503 error="upstream call failed: SendRequest: connection error: Connection reset by
  peer (os error 104)" reason=UpstreamFailure`; mockllm's receiving ztunnel reads
  `error="connection closed due to policy rejection: explicitly denied by:
  istio-system/istio_converted_static_strict"`.

Why it is structural rather than a policy mistake. The namespace `agentgateway-egress` is
deliberately not ambient-enrolled — that is agentgateway's documented ambient egress shape, and the
model is reached as a `MESH_EXTERNAL` `ServiceEntry` (`model.lab.internal`) bound to the
`agw-egress` waypoint. The egress proxy therefore carries an Istio identity on the way *in*
(`worker -> agw-egress` reports `mutual_tls`, and the egress access log records
`src.identity=spiffe://cluster.local/ns/lab/sa/default`) but dials its upstream in plaintext on the
way *out*. `mockllm` was an ambient-captured pod in `lab`, so under mesh-wide STRICT its ztunnel
refused that inbound connection. The pre-apply metrics reading had already shown this leg as
`connection_security_policy="unknown"` at `reporter="destination"` while every other hop of both
flows read `mutual_tls`; the apply turned that reading into a counted refusal.

A second, smaller consequence was counted: Prometheus (in the unenrolled `telemetry` namespace)
lost its scrape of the agentgateway ingress pod's `:15020`, 9/9 targets to 8/9, for the same
reason — a plaintext request into a captured pod. It came back on the revert.

### The question that was put to the author

Deciding it in the implementer's session would have meant either tuning the policy past what the
documents describe or wiring a known-refusing manifest into the step-2 overlay, so it was put up
as four options:

1. **Leave the mesh at PERMISSIVE** and keep the measurement as the finding — enforcement is
   documented as refusing the lab's own model leg at this shape, and the entry says so. No manifest
   ships.
2. **Enrol `agentgateway-egress` in ambient** so the egress proxy's upstream leg is HBONE too, then
   re-apply and re-count. This changes the mesh shape the earlier gates measured, and agentgateway's
   own egress documentation is what led to leaving that namespace out, so it needs checking against
   those documents first.
3. **Scope the policy to the namespaces whose hops all report `mutual_tls`** (that is, not `lab`,
   because `lab` holds `mockllm`). This is a narrower policy than the documents' mesh-level example
   and would leave the agents themselves unenforced, which is the opposite of the point.
4. **Ship the manifest unwired** — the file and its citations committed under
   `deploy/step-2-ambient-agw/` but not referenced by the kustomization, so the counted finding has
   its artefact and no overlay applies a policy that refuses the lab's own traffic.

### The decision taken, and by whom

**The author, 2026-09-12: none of the four — the mock model leaves the mesh.** The question had been
framed as what to do about the *policy*; the author reframed it as what the *mock* is. It stands in
for an external model provider, so the egress-to-model leg is this lab's external plaintext leg by
design, and a captured mock was the thing that did not belong. The mock therefore carries the
documented per-pod opt-out `istio.io/dataplane-mode: none` in `deploy/base/mockllm.yaml`, the
mesh-wide policy ships wired into the step-2 overlay with its text unchanged, and the whole path
counts again under STRICT. This also keeps the mesh boundary honest — what is in the mesh is
mutually authenticated, and what leaves for the model is visibly outside it — and it matches the
standing decision that the mock is the instrument for experiments while a real model sits outside
the cluster for the demo.

**The controller, 2026-09-12, two additions to that shape.** First, one port-level exception for the
agentgateway ingress pod's scrape port, `deploy/step-2b-agw-ingress-egress/peer-authentication-ingress-metrics.yaml`,
`portLevelMtls: {15020: {mode: PERMISSIVE}}` on a selector-scoped policy — otherwise Prometheus,
which runs outside the mesh, keeps losing that target. Second, **the `telemetry` namespace stays
outside the mesh**, reversing the author's initial choice to enrol it: an in-mesh collector would
enforce mTLS on inbound OTLP and so refuse the spans of every emitter that is not ztunnel-captured
— the mock once opted out, the egress proxy and both istiod-driven waypoints, all of which export
in plaintext to `otel-collector:4317/4318` — and the trace would lose exactly the hops Gate 3's
preceding two tasks worked to light up. The same "reject any plaintext traffic" mechanism the
plaintext probe measures would have been turned against our own telemetry. Enforcement and
observability genuinely pull against each other at that boundary, and this lab resolves it in
favour of not losing hops, with the trade recorded rather than hidden.

### What the second measurement counted under that shape

Clean check `1/1/1/1/1` and `TASK_STATE_COMPLETED` for both receivers with `invocations=1`; the
`REPS=1` trace run at 66 and 12 spans, 2 trace ids each, 0 dangling parents and no dark hop — the
figures the preceding two entries established, so enforcement cost no span; `mockllm`'s span
survives the opt-out because its export goes to the collector outside the mesh; Prometheus 9/9
across both readings including the target the first attempt lost; and exactly two ztunnel refusals
under the policy, both the plaintext probe's.

One documentation gap is worth keeping beside this. `portLevelMtls` is documented on the
`PeerAuthentication` reference and requires a selector, but the ambient Layer 4 page — the page that
says peer authentication modes "are supported by ztunnel" — never mentions a port-level mode, and no
current Istio page states whether ztunnel honours one. The measurement answers it at this version:
with the exception the target stayed up across both readings and ztunnel logged no refusal on that
port, where without it the target went down inside 15 s and ztunnel logged eight refusals, one per
15 s scrape, spanning 105 s.
Recorded as measured, not as documented support, in `versions.yaml` under `istio-peerauth-portlevel`,
and it is the part of this configuration most likely to break if either project moves. Because the
gap is a project documentation gap with a reproduction already in hand, rule 11 applies and a draft
issue text is written at `docs/upstream/istio-ambient-portlevelmtls-reach-undocumented.md` — not
filed, and no link until a human files it.

Nothing was tuned to get past a refusal: the mesh-wide policy's text is identical in both attempts,
and no retry was added anywhere. The proposal text is unchanged.

## 2026-09-19 — All agentic L7 traffic goes through agentgateway; Istio is L4 only

**2026-09-19 — All agentic L7 traffic goes through agentgateway; Istio is L4 only.** Decision by the author. Every
agentic L7 traffic is using agentgateway, under agentgateway's own control plane. This mainly covers LLM
communication, A2A and MCP traffic. Istio keeps ztunnel capture, identity and mesh-wide STRICT mTLS. The
istiod-driven agentgateway waypoints (GatewayClass `istio-agentgateway-waypoint`) are retired. Measured at Istio
1.31.0 and agentgateway v1.5.0: Istio's APIs do not reach those waypoints, and agentgateway's own policies do not
either — an `AgentgatewayPolicy` reads Attached and is never delivered. One agentgateway-managed proxy in its own
namespace, not enrolled in ambient, is the waypoint for the worker and the orchestrator and the egress for the model
host. Every mesh leg reads `mutual_tls`, and plaintext is still refused. Tracing is set by Helm `meshConfig` for
Istio and by one `AgentgatewayPolicy` per Gateway for agentgateway, with nothing custom. This supersedes the last
sentence of the 2026-09-08 note and the 2026-09-09 note (one waypoint per Service). Experiment A's counts are
re-measured on the new topology before any entry cites it. The proposal text is unchanged.

## 2026-09-19 — Experiment A gains in-cluster rows for the Python receiver

**2026-09-19 — Experiment A gains in-cluster rows for the Python receiver.** Decision by the author. Since the
topology change of the same date the orchestrator's Service has its own route, `lab/orchestrator`, on the central
agentgateway proxy. The A.3 matrix gains rows that send work items to the orchestrator in-cluster, addressed to its
Service and not to the ingress URL its agent card advertises. The retry stanza for these rows is on that route. They
are reported beside the existing Python-receiver rows through the ingress, not instead of them. The proposal text is
unchanged.

## 2026-09-20 — Experiment B on the agentgateway-only topology: which proxy, which client, and how it is removed

Decision by the author. §4.4 B says "the proxy on the path is removed or replaced". Since the note of 2026-09-19 one proxy,
`agw-central`, carries the agent leg and the model leg, so removing it cuts the model call as well and the Task fails, every retry
being off (rule 4). B is therefore run on both proxies and each is named: the agentgateway ingress, where only the A2A stream is
cut and the task can continue, as the main rows; and `agw-central` as one further variant, which is the case the second clause of
the proposal's sentence names — whether infrastructure recovery converts a lost connection into a lost task.

The streaming client is the load client (`a2a-go`) in every row, so that only the receiver changes between rows, as in A.1;
`a2a-python` is exercised as a receiver and not as a reconnecting client, and that is recorded rather than left to be assumed.

Removal: what each method does to an open stream is measured first — a graceful delete, a forced delete and a rollout — and the
experiment then uses the forced delete, the abrupt case the question is about; a rollout variant is added if it fits. Both SDKs
keep the keep-alive settings they ship with (`a2a-go` none, `a2a-python` a 15 s ping), recorded and not aligned, so that an
idle-timer result can be attributed.

B gains one row the proposal does not list: `SubscribeToTask` against a task that has already reached a terminal state, per
receiver. The specification requires one error for it and the two SDKs return different ones, so the row records what each
answers. The proposal text is unchanged.

## 2026-09-20 — Experiment C on the agentgateway-only topology: what it asks now

Decision by the author. §4.4 C rests on two facts. The first stands: binding matters, and JSON-RPC is the
primary case. The second described a layer this lab no longer runs — agentgateway proxies programmed by istiod
through Gateway API resources alone, which neither Istio's policy APIs nor agentgateway's own policies reach.
That boundary was tested before the layer was retired, at Istio 1.31.0 and agentgateway v1.5.0: an
`AgentgatewayPolicy` on an istiod-managed waypoint read Attached and was never delivered (`findings.md`, "the
documented AgentgatewayPolicy tracing on an istiod-managed agentgateway waypoint"). It stays on record as
measured. Since the note of 2026-09-19 every L7 proxy is agentgateway's own, so C's question — what can each
layer actually distinguish about an A2A interaction — is put to the layers that exist, each with the control
plane that drives it:

- **ztunnel** (istiod; `AuthorizationPolicy`, `PeerAuthentication`): workload identity and L4 policy. Behind a
  proxy the receiver's ztunnel sees the proxy's identity, not the caller's.
- **Gateway API routes on the agentgateway proxies** (agentgateway's controller; `HTTPRoute`): host, path,
  headers, query parameters, HTTP method. Nothing in the body.
- **agentgateway's own policy** (agentgateway's controller; `AgentgatewayPolicy`): CEL rules over the caller's
  SPIFFE identity, the request's headers and the request's body. For a backend marked A2A it reads the JSON-RPC
  `method` into its logs and spans; it gives rules no A2A variable, where MCP has one for the tool.
- **the application** (no control plane; `a2a-go`'s call interceptor, `a2a-python`'s per-operation request
  handler, the agent card's security schemes).

C has two halves. **Observation**: one map, layer by layer, of what each can tell apart when a `SendMessage`
and a second operation arrive at the same JSON-RPC endpoint — caller identity, target Service, path and
headers, the `method` in the body, `messageId` and `taskId`. Every cell is a measured reading or a documented
limit with its source; cells the lab already holds are cited, not re-run. **Enforcement**: one deny attempted
at each layer that documents a mechanism, the same rule each time — one operation refused and another allowed
on one endpoint — counted by the three ledgers and by the layer's own record of the refusal. A layer that
cannot express the rule is recorded as that, with the sentence that says so. C is still not forced to produce
a deny.

Consequences the author accepts: (1) the map names the control plane behind each hop, as the 2026-09-08 note
required; there are now two and they do not overlap — istiod for L4, agentgateway's controller for L7;
(2) the REST binding is tested only if the JSON-RPC result needs the comparison (§12.2, unchanged); (3) nothing
is added: no external authorization service, no rate-limit service, no token issuer, no Envoy waypoint for
comparison (rule 6) — a mechanism that needs one is recorded as documented and not attempted. The proposal
text is unchanged.

## 2026-09-22 — Experiment B gains a control with no proxy event (author's addition)

Decision by the author. B gains a second row the proposal does not list, run before any proxy is removed: per receiver, ×20,
Job 1 opens a `SendStreamingMessage` and cancels its own stream after k seconds, and Job 2 sends one `SubscribeToTask`. It counts
whether the task still reaches `TASK_STATE_COMPLETED` after losing its only stream, and whether the model was invoked exactly
once. It needs one load-client setting (cancel after k ms), off by default. It separates what each SDK does when a task loses its only stream from
anything a proxy does, so that a task that fails in the proxy-removal rows can be attributed. The proposal text is unchanged.

## 2026-09-22 — Experiment B: the Go receiver is reached through the ingress by a Host setting on the load client

Decision by the author. The note of 2026-09-20 makes the agentgateway ingress B's main rows, because removing it cuts only the A2A
stream while the model leg stays up. The in-cluster load client reaches the Python receiver through the ingress from the URL its
card advertises, but reaches the Go receiver through `agw-central` from its card's URL; the ingress's worker route
(`worker-ingress`) matches only the host `worker.lab.internal`, which does not resolve in the cluster (measured 2026-09-22, from a
pod in `lab`). The load client therefore gains one setting, off by default, that sets that host on its requests, so that both
receivers' B rows cross the same proxy from the same in-cluster client. For Experiment B only, this departs from the stimulus path
rule recorded in the note of 2026-09-09 (an in-cluster stimulus goes through the receiver's in-cluster gateway); every B entry
names the path it used. The proposal text is unchanged.

## 2026-09-23 — Experiment C: the second operation, one identity, and the A2A marking switched on for one step

Decision by the author. C's enforcement half refuses one operation and allows another on one endpoint, so it needs a second
operation on the wire. It uses the ones Experiment B already made the load client send: `SendMessage` is the operation allowed
and `SubscribeToTask` the one refused, so no fixture learns a new operation. Every workload in `lab` keeps the one default
ServiceAccount: identity was tested at ztunnel in C-3, and at agentgateway an identity rule is recorded as a limit of this
configuration — one value for every caller — rather than exercised with new accounts. One step marks the agent Services as A2A,
the marking agentgateway's A2A handling keys on, so that the "A2A-aware gateway" of §4.4 C is switched on in this lab at least
once; it is a step of its own, rebuilt from a deleted cluster, and it counts what the gateway then records and whether anything
else moved. The proposal text is unchanged.

## 2026-09-24 — Experiments B and C: the remaining rows, the REST binding, one lab-written authorization fixture, and two standing changes

Decision by the author, after Experiments B and C were measured: run what was proposed and not done, and close the open threads
the entries name. **B** gains the rollout variant the note of 2026-09-20 allowed "if it fits", and one row with the Python SDK as
the reconnecting client — the orchestrator's forwarder resubscribes once after losing its stream — which reverses, for that row
only, the choice that the load client is the streaming client in every row. **C** measures which request headers reach each
application (a ledger setting, off by default), and gains the REST binding, deciding §12.2 of the proposal: both agents serve REST,
the load client can send it, and the route, header and body rules are run on it as they were on JSON-RPC. **Rule 6 is widened for
one fixture only**: a minimal external-authorization server written in this repository under `fixtures/`, speaking the protocol
agentgateway calls, measured against the same rule as C-8; no third-party project is added. Two changes become **standing**: the
load client, the worker and the orchestrator each get their own ServiceAccount, and from the step that adds them every rebuild
uses them, earlier entries remaining the records of the single-identity setup; and agentgateway's A2A backend type is measured
and kept as standing if it does not break clients that follow the agent card, with C-9's unexplained connection count
investigated by a temporary Service marking applied and removed from a run directory. Rows on the current topology run first; the
two standing changes run last. The proposal text is unchanged.

## 2026-09-24 — Experiment C adds the gRPC binding beside REST

Decision by the author, later the same day, changing one part of the note above: C gains the **gRPC** binding as well as REST.
Both agents serve it, the load client can send it, and the route, header and body rules are run on it as on JSON-RPC and REST.
At the pinned versions a2a-go carries its gRPC server and client; a2a-python carries a gRPC request handler that needs the
`grpcio` package, which is added to the orchestrator's lockfile as a pin recorded from a fetched source. gRPC runs over HTTP/2
through a `GRPCRoute` on the agentgateway proxies; whether that holds at the pinned agentgateway and Gateway API versions is
verified from documents before any code, and a step that finds it does not is stopped for the author. The proposal text is
unchanged.

## 2026-09-24 — the history rewritten to remove absolute home paths, scratch paths and the host name

Decision by the author. CLAUDE.md forbids host-identifying strings in committed files; 63 files on main carried the absolute
home path of the checkout (most of them the lab's own driver scripts), 17 lines carried a session scratch path, and 7 lines of the
2026-09-10 and 2026-09-11 image-scan reports carried the host's name. The whole history of every published branch — 18 branches,
169 commits — was rewritten with four literal replacements: the checkout path became `$(git rev-parse --show-toplevel)`, so the
old scripts still run from any clone; any other home path became `$HOME/`; the scratch path became `<scratchpad>`; and the host
name became `<host>`. The rewrite was verified before it was pushed: none of the four strings remains in any published object;
every deployed subtree id (`deploy`, `agents`, `fixtures`, `internal`, `Makefile`, `experiments/lib`, `go.mod`, `go.sum`) is
unchanged at every branch tip; every changed file equals its original with only those replacements applied; authors and dates are
unchanged; and 14 commit messages changed only where they quoted an old commit id, which the tool updated to the new one. Every
commit id changed, so a commit cited by id from before this note no longer resolves; commits are cited by subject, as CLAUDE.md
already asks since the rewrite of 2026-09-19.

**The one consequence for the records.** The standard proof's driver,
`experiments/runs/2026-09-20-experiment-a-agentgateway-only/checks.sh`, carried the path on its line 40 (the `cd` into the
checkout), and that line is the only one the rewrite changed in it. Its sha256 before the rewrite was
`8ee90f7de5d8a64d3a93fbfaa269e747da219025732f45999e0f18b5e847fb00`; after it, `4056b5596883187fe1a7b0528a833f533437aaf93760ee6a8130215ddd16224b`.
Every record that cites the first value — as the committed file's hash, or as the hash of an as-run copy equal to it — refers to
the bytes before this rewrite, and those records are left exactly as they were written. One local branch that was never published
(`spike-central-waypoint`) was not rewritten. The proposal text is unchanged.

## 2026-09-24 — the gRPC rows: the client's transparent retry, and the Host setting beyond Experiment B

Decision by the author, on two points the gRPC binding raised. **Rule 4.** grpc-go's client disables retries only in part: its
`WithDisableRetry` "does not impact transparent retries", which re-send a request the server never began processing. The load
client's gRPC path disables every retry the library allows and records every attempt with the library's own transparent-retry flag;
any repetition in which a transparent attempt occurred is flagged in its entry, and the pre-dispatch ingress ledger counts any
duplicate arrival independently. This is recorded under rule 4 as the Go HTTP client's replay on a stale connection already is, not
treated as a retry the lab added. **The Host setting.** gRPC is routed only on the agentgateway ingress, on hostnames of its own, so
the in-cluster load client reaches the gRPC ports with the Host setting the note of 2026-09-22 allowed for Experiment B only; that
allowance now extends to the gRPC rows. The central proxy's waypoint listener serves only the HTTP port, so gRPC through it is not
routed, and the entries say so. The proposal text is unchanged.

## 2026-09-25 — Experiment C: the authorization fixture covers every shape the receivers dispatch (D-3b)

Decision by the author, after D-3 was measured. D-3's fixture decided the operation from the shapes the SDK clients send: the
JSON-RPC body only on a POST to exactly /, the REST subscribe path as written, the gRPC method path. Counted live, 30 of 30
requests carrying SubscribeToTask in other shapes the receivers dispatch (a POST to /x or /a2a/v1 at the Go receiver, a POST to /
with a gRPC content-type, a REST subscribe path with its colon percent-encoded) were allowed by the fixture and dispatched by the
SDKs. D-3's entries record that as a limit of that fixture. **D-3b changes the fixture** so that its view of the operation covers
every shape either receiver dispatches, as read from both receivers' routing: the path decoded as the receivers decode it before
it is matched, and the JSON-RPC body read on every request the receivers would hand to their JSON-RPC handler, whatever its path
or content-type. The rule is unchanged (refuse SubscribeToTask, allow everything else), and so are the undecidable setting and
its default. It is rebuilt from a deleted cluster and counted against D-3's rows and the shapes D-3 found, plus any shape the
routing reading adds. It runs on the current topology, before the two standing changes, as the note of 2026-09-24 orders. No
third-party project is added. The proposal text is unchanged.

## 2026-09-25 — a currency pass: every dependency at its latest stable release, with the rows a moved dependency can change re-counted

Decision by the author, after the D series. a2a-go v2.6.0 was released on 2026-09-25 and changes an answer the lab counted
(the reply to a SubscribeToTask naming a terminal task, B-3 and D-1's Python-client row, a2a-go#442). The author asked for a full
dependency upgrade rather than one pin: **every pin is re-read from its release source and moved to its latest stable release**
(the rule of 2026-09-19: no alpha, beta, release candidate or nightly; a project with no stable line is pinned at the latest release
of the only line it has and named so), each move recorded in versions.yaml with its source, and a pin held below its latest only
with the documents that justify the hold. The lab is then rebuilt from a deleted cluster at the new pins and the standard proof is
run. **Re-run scope, the author's choice:** every experiment row whose outcome a moved dependency could change is re-counted with
its committed driver, the rows chosen from each moved release's changelog and code diff and listed before any is run; the rows no
diff touches are listed with the reason they were not re-run. Earlier entries stay the records of their versions. Nothing is added
to the lab's scope; a moved dependency that needs a code change gets the smallest change, test first. The proposal text is unchanged.

## 2026-09-25 — the two contradictions D-6 recorded are cleared; the follow-up fix; the walkthrough; submission 3 is pursued

Decisions by the author, after the currency pass.

**The two contradictions D-6 recorded are cleared, by the wording the records support.** Both dated entries stay as written;
a new entry records the clearing beside them. (1) C-11 wrote that the application sees "nothing that tells one caller from
another", while D-1 counted a lab-set x-caller header at both applications (15 of 15) and B-6 records a lab.caller span
attribute. The cleared statement: **the application receives no verified caller identity; it receives only what the caller
declares about itself** (x-caller, set by the lab's own clients, which any client could set to anything; D-1 and D-4 found no
verified identity reaching the applications). (2) B-6 wrote that removing agw-central under an open A2A stream "is a question
this topology cannot put", while D-1's Python-client row removed agw-central under the orchestrator's forward stream (20 of 20).
The cleared statement: **B's own rows could not put that question, because the load client was the streaming client in every
B row (the note of 2026-09-20) and none of its streams crosses agw-central; D-1's row, added by the note of 2026-09-24, put it.**

**The follow-up fix the currency pass recorded** is done as one task with a rebuild from a deleted cluster: experiments/gate3-matrix.sh's
Go-sources path list gains fixtures/extauthz, as the Makefile's has since D-3's deploy commit, so the matrix passes its own
image-freshness check on the current tree; the two stale comments in agents/orchestrator/pyproject.toml are brought to the pins
they describe; versions.yaml's grpc-go hold wording says the hold rests on GO-2026-6443 alone.

**The walkthrough** (docs/walkthrough.md, taken on 2026-09-20) is then refreshed to the lab as it stands, walked again from a
deleted cluster, every printed output taken from that run.

**Submission 3, observability (proposal §9), is pursued**, the decision §9 left for after 24 September: it is worked on together
with submissions 1 and 2, after the fix and the walkthrough, from the findings already counted. The proposal text is unchanged.
