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
