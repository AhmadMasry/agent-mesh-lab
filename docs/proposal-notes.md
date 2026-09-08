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
