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
