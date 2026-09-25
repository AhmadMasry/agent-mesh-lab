# Draft issue — agentgateway: the A2A agent-card rewrite advertises https for a plain-HTTP agent when the card is fetched through an ambient waypoint (HBONE), and an A2A client following the card fails at the waypoint

Status: **draft, not posted.** Text for the author to review and open as a **new issue** on
https://github.com/agentgateway/agentgateway. No link until it is filed.

Why a new issue: the tracker was searched on 2026-09-23 (issues and pull requests, any state, fifteen queries).
Each query is recorded with the page it returned, the REST API's own total_count, and the search rate limit read
before each call; no query failed (experiments/runs/2026-09-24-c9-a2a-marking/tracker-search.txt). Every candidate
was then read by number (items-read.txt in the same directory). Nothing describes this. The nearest items:

- #1031 (closed) and #1678 (merged 2026-04-28, in v1.5.0): the rewrite honours X-Forwarded-Proto. That is the
  opposite case, a plain-HTTP gateway behind a TLS-terminating proxy.
- #3500 (open, 0 comments): the rewrite doubles the path and replaces the authority under a route URLRewrite. The
  field is the same, but the cause is the path, not the scheme.
- #1829 (open issue) and #3453 (open pull request, not merged): set X-Forwarded-Proto on TLS termination towards
  the backend. That is a request header towards the backend, not the card's URL. As its description reads, #3453
  would overwrite X-Forwarded-Proto on every request from the presence of TLS info, which would not change the scheme
  reported here. Its order against the A2A block's read of that header was not read. If it runs first, it would also
  remove the X-Forwarded-Proto: http workaround measured below.
- #3069 (merged 2026-08-17, contained in v1.5.0, "mesh: retain identity with nested TLS in HBONE"): it bears on the
  source reading below (the outer mTLS identity kept on HBONE traffic), and is not a report of this behaviour.

Read at v1.5.0 (fe673247) and at main 3528a428 (read 2026-09-23T23:42:27Z; the files fetched are listed in the
lab's sources/fetch-log.txt). On main, normalize_uri has changed: it is no longer limited to HTTP/1.x and sets the
scheme only when none is set. The TLS-to-https branch inside it is the same, and a2a/mod.rs l.34 still calls
apply_forwarded_scheme.

The website's A2A page (agent/a2a.md l.153) calls the Service appProtocol marking "the legacy way from an earlier
version of agentgateway" and recommends the a2a backend type (AgentgatewayBackend spec.a2a) for most cases. This
report is about the appProtocol marking. The backend type was not tested. Whether it applies to waypoint traffic
addressed to a Service, and whether it rewrites the card the same way, were not read here.

## Issue text to post

Everything between the two rules below is the issue, written to be pasted as it stands.

---

### What happened

A Service port marked appProtocol agentgateway.dev/a2a serves plain HTTP. Istio ambient mode sends the in-cluster
traffic to it through an agentgateway proxy that is the Service's waypoint (GatewayClass agentgateway, the proxy
terminating HBONE on 15008 itself). A client that fetches the agent card at the Service's address gets a card whose
interface URL has the scheme **https**:

    fetched:     http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json   (HTTP 200)
    agent sent:  "url": "http://worker.lab.svc.cluster.local:8080"
    client got:  "url": "https://worker.lab.svc.cluster.local:8080/"

An A2A client that follows the card dials https. Its TLS ClientHello is carried by ztunnel over HBONE to the
waypoint. The waypoint parses it as an HTTP request, logs one warn line per attempt, and answers in plain HTTP:

    warn  proxy::gateway:inbound  proxy error: invalid HTTP method parsed  src.addr=<client pod>:<port>

The client then reports the plain-HTTP answer and sends no A2A request. With the a2a-go v2.5.0 JSON-RPC client:

    failed to send HTTP request: Post "https://worker.lab.svc.cluster.local:8080/": http: server gave HTTP response to HTTPS client

With the a2a-python 1.1.4 client (httpx):

    Network communication error: [SSL: WRONG_VERSION_NUMBER] wrong version number (_ssl.c:1082)

Counted: 22 of 22 failed attempts have that warn line, by source address, and none has a request line on any route.
The agent itself received nothing.

The same agent's card fetched through a plain-HTTP listener of an agentgateway proxy keeps http. The same card
fetched through the waypoint with X-Forwarded-Proto: http also keeps http.

Measured, one GET each, all HTTP 200:

| card fetched through | how the request arrived | url in the card |
|---|---|---|
| the waypoint, Service address (no extra header) | HBONE on 15008 (the Gateway's listener; the access line reads listener=inner-http) | https://worker.lab.svc.cluster.local:8080/ |
| the waypoint, Service address, X-Forwarded-Proto: http | the same | http://worker.lab.svc.cluster.local:8080/ |
| an ingress Gateway, plain HTTP listener on 80, Host worker.lab.internal | plain HTTP on 80 (listener=http) | http://worker.lab.internal/ |

A second agent behind the same waypoint read the same: its card fetched at
http://orchestrator.lab.svc.cluster.local:8080/.well-known/agent-card.json came back as
https://orchestrator.lab.svc.cluster.local:8080/.

### Where it comes from (read from source at v1.5.0; the measurements above agree with it; one step is inferred and marked so)

- crates/agentgateway/src/a2a/mod.rs l.29-34: the card's base URL is the request URI (or OriginalUrl), passed
  through crate::http::x_headers::apply_forwarded_scheme.
- crates/http/src/lib.rs l.75-87 (apply_forwarded_scheme): the scheme is replaced only when X-Forwarded-Proto is
  present. Otherwise the URI's own scheme stands.
- crates/agentgateway/src/proxy/httpproxy.rs l.4287-4310 (normalize_uri): for HTTP/1.x the scheme is set to HTTPS
  when the downstream connection carries TLS connection info, else HTTP. l.746 sets log.tls_info from the request's
  TLSConnectionInfo extension, and l.763 passes it to normalize_uri.
- crates/agentgateway/src/transport/stream.rs l.258-266 (Socket::from_hbone): the HBONE stream's socket wraps the
  outer connection's extension (l.259, Extension::wrap). The comment at l.266 reads "Client identity comes from mTLS
  (TLSConnectionInfo)".
- crates/agentgateway/src/proxy/gateway.rs l.1466 builds the waypoint's socket with Socket::from_hbone. l.1277-1289
  (the passthrough branch) states that the TLSConnectionInfo of "the Istio mTLS connection carrying HBONE" is kept in
  the wrapped extension.
- Inferred, not traced line by line: that the TLSConnectionInfo read at httpproxy.rs l.746 for a request inside the
  HBONE stream is the one the outer mutual-TLS handshake inserted, which would make tls_info present and the scheme
  https.

That TLS is mesh transport between the client's node proxy and the waypoint. It is not a scheme the client can dial:
the client addresses the Service in plaintext, and ztunnel captures it.

### Reproduce

Istio 1.31.0 ambient (ztunnel), agentgateway v1.5.0 under its own control plane. One agentgateway Gateway is used as
the waypoint of a namespace, not enrolled in ambient itself. One HTTPRoute has that Gateway as parent, hostname
<svc>.<ns>.svc.cluster.local and backendRef the Service. The Service's port is plain HTTP and carries
appProtocol: agentgateway.dev/a2a. The agent's card advertises its own http:// Service URL.

    kubectl -n <ns> run c --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 600
    kubectl -n <ns> exec c -- curl -sS http://<svc>.<ns>.svc.cluster.local:8080/.well-known/agent-card.json
    # supportedInterfaces[0].url: https://<svc>.<ns>.svc.cluster.local:8080/
    kubectl -n <ns> exec c -- curl -sS -H 'X-Forwarded-Proto: http' http://<svc>.<ns>.svc.cluster.local:8080/.well-known/agent-card.json
    # supportedInterfaces[0].url: http://<svc>.<ns>.svc.cluster.local:8080/

With the port unmarked, the first GET returns the card unchanged (the agent's own http:// URL).

### What I expected

The card to advertise a URL the client can reach: the scheme the client used, which on an ambient waypoint is the
original request's http. Or, if the rewrite cannot know it, to leave the agent's scheme as advertised. The A2A page
on the website presents the appProtocol marking with a plain-HTTP Service and says nothing about a scheme change.

### Not established

- Whether a TLS-terminating waypoint or ingress that is not HBONE behaves the same. Only the HBONE listener was read.
- Whether this should be fixed in the rewrite (for example, not using the HBONE tunnel's TLS as the request's
  scheme) or in normalize_uri more generally. Other rewrites that build absolute URLs may read the same scheme; that
  was not checked.

---

## For the author, not for the issue

- The lab's record: findings.md, the C-9 entry, and experiments/runs/2026-09-24-c9-a2a-marking/ (cards-after/,
  standard-counts-vs-last-proof.txt, clean-check/).
- The wording "the client addresses the Service in plaintext" rests on the lab's topology entry (ztunnel captures
  the pod's plaintext and carries it over HBONE to the waypoint), not on this step.

## 2026-09-25, a dated note from D-5 (the text above is unchanged)

For the author, not yet part of the issue text. D-5 applied the same marking again, from a run directory, for
one set of sends and then removed it (experiments/runs/2026-09-25-d5-a2a-backend/conn-marked/, counts.txt).

- **The https card reproduced.** Through the waypoint at the Service address, each card's interface urls read
  https://worker.lab.svc.cluster.local:8080/ and https://orchestrator.lab.svc.cluster.local:8080/. Through the
  ingress they read http with the Host the client sent. This matches C-9, one GET per path.
- **New, and a candidate for the issue text: the gRPC interface is rewritten too.** The agents now advertise a
  third interface, protocolBinding GRPC, with the url worker.lab.svc.cluster.local:8081 (no scheme, the gRPC
  port). C-9's agents did not have it. Under the marking every supportedInterfaces url is replaced by the
  gateway base, the gRPC one included:
  - through the waypoint, https://worker.lab.svc.cluster.local:8080 (the HTTP port, and https);
  - through the ingress, http://worker.lab.internal.

  a2a/mod.rs at v1.5.0 (l.182-209) rewrites each entry without reading protocolBinding, and main 06c20cef has no
  gRPC handling in the file either. A gRPC client that followed such a card would dial the HTTP listener's port.
  No gRPC client followed a card here: the lab's gRPC row dials its target.
- **Whether the rewrite changes the connection count: it does not, in this measurement.** With one set of 8
  requests inside 2 s, agw-central's upstream connections per agent rose by 1 with the marking, 1 without it, and
  1 after its removal. C-9's six is discussed in D-5's entry and is not a behaviour of the rewrite.
- The D-5 draft on the a2a backend type (agentgateway-a2a-backend-type-dials-plaintext-outside-ambient-mesh.md)
  is a separate issue. With the backend type, no card reached a client (every card GET was 503), so its card
  scheme was not observed.

## 2026-09-25, a dated note from D-5c (the text above is unchanged): STANDS

For the author, not yet part of the issue text.

- **The first search was phrase-only.** C-9's search (tracker-search.sh) sent each query to gh search as one argument.
  gh 2.101.0 sends that as a quoted phrase, so the pages of its eleven multi-word queries matched the exact phrase
  only (experiments/runs/2026-09-25-d5c-search-correction/gh-phrase-check.txt). The total_count beside each page was a word search.
- **The word pass.** On 2026-09-25, D-5c re-ran the eleven as words, through the search API with an explicit q=,
  issues and pull requests apart, the rate limit read before each call, 0 failed. It made 22 calls and returned 146
  items, 105 of them on no page of C-9 (experiments/runs/2026-09-25-d5c-search-correction/search-words-c9.txt and new-items.txt).
- **Read by number (items-read.txt there):** the only new titles near HBONE or the marking.
  - #993 (closed completed 2026-07-09): the HBONE tunnel protocol on Binds;
  - #1793 (closed, not merged): AppProtocol on Backend.
  - Neither is about the scheme the card rewrite writes. #2983 and #999, raised in D-5's review, were already on C-9's
    pages.
- **Standing: stands.** It is not a duplicate, no fix was found, and there is no documented behaviour for it.
- **Not re-read here:** the state now of the items the text above names (#3500, #3453, #1829).
