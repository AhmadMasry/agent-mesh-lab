# Draft issue: agentgateway's A2A backend type dials its host in plaintext outside the mesh, so under Istio ambient STRICT mTLS it cannot reach an in-mesh agent that the legacy Service marking reaches

Status: **draft, not posted.** This text is for the author to review and open as a **new issue** on
https://github.com/agentgateway/agentgateway. No link is added until it is filed. The search behind it ran in two
passes on 2026-09-25. The first pass was exact-phrase only. The second pass, as word searches, was added after the
review and read the items the first pass missed. Neither pass found this reported.

Why a new issue: the agentgateway tracker was searched twice on 2026-09-25, for issues and pull requests in any
state. The files are in experiments/runs/2026-09-25-d5-a2a-backend/.

- **First pass** (tracker-search.txt): 20 queries by title words and by code function and type names, with the
  REST API's total_count beside each page and the search rate limit read before each call. 0 failed. Its result
  pages were exact-phrase searches: gh 2.101.0 sends a multi-word argument as a quoted phrase. So 13 of the 20
  pages read 0 results, 12 of them against a total_count of 1 to 16. The script's header carries a dated
  correction.
- **Second pass** (tracker-search-words.txt): the same 20 queries as word searches through the search API with an
  explicit q=, issues and pull requests separately. That is 40 calls, total_count beside each page, the rate limit
  read before each call, and 0 failed or throttled. It listed 79 distinct items, 58 of them on no page of the first
  pass. Their titles were screened, and the ones that bear on this draft were read by number (items-read.txt).

None of the items describes this behaviour. The nearest are:

- #1018 (closed, completed): the request that led to the A2A backend type, which asks for A2A routing to external
  endpoints. The type's design follows from it: a host and a port, dialled directly.
- #1841 (merged 2026-05-18, merge commit be82e02e, contained in v1.5.0: be82e02e...v1.5.0 is ahead 751, behind
  0): the pull request that added the first-class A2A backend type.
- #3504 (open) and #3550 (open pull request, not merged): a label selector on A2A backends, with Services
  discovered by label and appProtocol. As #3550's description reads, legacy host and port still translate to
  Backend_Static. This draft did not read whether the selector's targets would be dialled through the Service
  path, and so through the mesh.
- #993 (closed, completed): the controller setting the HBONE tunnel protocol on waypoint listeners. It is about the
  proxy's downstream listener, not how a backend is dialled.
- #2983 (merged 2026-08-13, contained in v1.5.0) and #999 (closed) are read beside the second observation below.
  #2983 wrote the card rewrite's interface-url code for a path rewrite. #999 is an "invalid json" error from an
  a2a_sdk crate that v1.0.0 removed. Neither is the card handling replacing an upstream error body.

Read at v1.5.0 (fe673247) and at main 06c20cef (read 2026-09-25). The parts this report relies on are unchanged
in substance on main.

## Issue text to post

The issue is everything between the two rules below, written so it can be pasted as it stands.

---

### What happened

The A2A page on the website (agent/a2a.md, l.151-153 at the v1.5.0 tag of the website) recommends the a2a
backend type, AgentgatewayBackend spec.a2a, "for most cases", and calls the Service appProtocol marking "the
legacy way". We replaced a Service backendRef with an a2a backend. The backend names the agent's own Service host
and port, as the page's example does. The route is an HTTPRoute on an agentgateway proxy that serves as the
Istio ambient waypoint for that Service. Istio runs mesh-wide STRICT mTLS.

With the Service backendRef, the proxy reaches the agent over HBONE and every request succeeds. With the a2a
backend, every request fails. The proxy dials the Service's ClusterIP in plaintext, and the destination ztunnel
refuses the connection:

    agentgateway:  route=lab/worker endpoint=worker.lab.svc.cluster.local:8080 http.status=503 protocol=a2a
                   error="upstream call failed: SendRequest: connection error: Connection reset by peer (os error 104)"
                   reason=UpstreamFailure
    ztunnel (the agent's node, inbound, src = the proxy pod, dst.addr = <pod>:8080, not 15008):
                   error="connection closed due to policy rejection: explicitly denied by:
                          istio-system/istio_converted_static_strict"

We counted 25 of 25 such connections (17 to one agent and 8 to a second). ztunnel's
istio_tcp_connections_opened_total was read after the first 21 of them. It recorded all 21 under
connection_security_policy="unknown" with no source principal (15 and 6). Over that window, ztunnel's
destination-reported mutual_tls series from the proxy (source agw-central) to the agents did not move.

The same backend on an ingress Gateway whose namespace is enrolled in ambient did not fail at the ingress. The
ingress's own ztunnel captured its plaintext dial of the ClusterIP. Because the Service names a waypoint, the
connection was then sent to that waypoint, which is the same proxy with the same a2a backend, so it failed there.
Auto-hostname had set the upstream authority to the backend host, so the waypoint's route matched. The request
gained a hop that the Service backendRef does not take: with the Service backendRef, the ingress dials the pod
over HBONE. Each of these requests appears in the trace as two ingress spans and two waypoint spans.

### What the docs say

The A2A page at the website's v1.5.0 tag (agent/a2a.md) does not mention a mesh, Istio, ambient or a waypoint. The
ambient pages do not mention A2A:
- integrations/istio/ambient/ambient-ingress.md (l.11, l.47) says end-to-end ambient mTLS needs the proxy's
  namespace enrolled, with the route's backendRef a Service (l.179-181).
- ambient-egress.md (l.13-15, l.170-178, l.200-209) puts a static AgentgatewayBackend on the waypoint for a host
  that a ServiceEntry models as MESH_EXTERNAL.

No page we found says how an a2a backend is dialled for an in-mesh Service.

### Where it comes from (read from source at v1.5.0)

- controller/pkg/syncer/backend/backend_plugin.go l.165-181: spec.a2a becomes an api.Backend of kind Static
  (host, port) with an inline A2A policy.
- crates/agentgateway/src/types/agent_xds.rs l.1835-1841: a Static backend becomes
  Backend::Opaque(Target::Hostname(host, port)).
- crates/agentgateway/src/proxy/httpproxy.rs l.2174: SimpleBackend::Opaque goes to BackendCall::from_shared,
  which sets transport_override to None (l.4372-4386).
- httpproxy.rs l.1855-1886 (build_transport): HBONE or Istio mTLS is used only when transport_override is set.
  Only the Service path sets it (build_service_call, l.3171 and l.3224). Otherwise the transport is plaintext,
  or the backend TLS policy if one is set.
- crates/agentgateway/src/client/mod.rs l.452-471: the hostname is resolved by DNS and dialled at the address DNS
  returns.
- controller/api/v1alpha1/agentgateway/agentgateway_backend_types.go l.135-146: A2ABackend has only host and
  port. It has no Service reference that would put the call on the Service path.

The a2a backend runs the same A2A handling as the Service marking. Both produce BackendPolicySpec_A2A
(a2a_plugin.go l.55-78), and the request and response blocks read the same policy field (httpproxy.rs l.403-418
and l.2945-2954). The only difference we found is how the upstream is dialled.

### Also observed with the same backend (the A2A handling, not the transport)

When the upstream of a card GET answers with a non-JSON error body (here the waypoint's own 503 text), the A2A
card handling replaces the answer with its own: http.status=503, reason=Internal, "processing failed: agent card
invalid JSON" (a2a/mod.rs l.171-173 at v1.5.0). The client sees 503 either way, but the ingress's line records
a processing failure, not the upstream failure. We counted this on 14 of 14 card GETs through the ingress.

### Reproduce

Istio 1.31.0 ambient (ztunnel) with a mesh-wide PeerAuthentication STRICT. agentgateway v1.5.0 under its own
control plane. One agentgateway Gateway serves as the waypoint of the agent's Service (istio.io/use-waypoint on
the Service) and is not enrolled itself. It has an internal HTTP listener and an HTTPRoute with the Service's
hostname.

    apiVersion: agentgateway.dev/v1alpha1
    kind: AgentgatewayBackend
    metadata: {name: worker-a2a, namespace: lab}
    spec:
      a2a: {host: worker.lab.svc.cluster.local, port: 8080}

In the route, backendRefs [{group: agentgateway.dev, kind: AgentgatewayBackend, name: worker-a2a}] replaces
[{name: worker, port: 8080}]. From an enrolled client pod:

    curl -sS http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json
    # 503 "upstream call failed: SendRequest: connection error: Connection reset by peer (os error 104)"

With the Service backendRef, the same GET returns the card (200).

### What I expected

Either one of these:
- the a2a backend reaches an in-mesh Service the way a Service backendRef does, over the mesh transport, for
  example through a Service reference in spec.a2a; or
- the A2A page says that the a2a backend dials its host directly, outside the mesh, so that a user on Istio
  ambient with STRICT mTLS knows that the Service marking is the only A2A form that keeps mesh transport.

### Not established

- The #3550 selector, if merged: whether its targets would take the Service path.
- Whether spec.policies (backend TLS) or a tunnel policy could make the a2a backend work under STRICT. Istio's
  mTLS is not a backend TLS setting the lab could configure, and nothing was tried.
- A proxy with an a2a backend whose own pod is enrolled and that is not a waypoint. The ingress above was
  enrolled, but its traffic was sent to the Service's waypoint.

---

## For the author, not for the issue

- The lab's record: findings.md, the D-5 entries, and experiments/runs/2026-09-25-d5-a2a-backend/ (trial/,
  counts.txt, reading-notes.txt).
- The waypoint in this lab is an agentgateway proxy under agentgateway's own control plane serving an in-mesh
  Service. That role is measured in this lab, not documented by the project (deploy/step-2-ambient-agw/central-
  gateway.yaml). The ingress-hop observation depends on it.
