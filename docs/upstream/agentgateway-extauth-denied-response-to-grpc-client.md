# Draft report — agentgateway: an ext-authz denial is returned to a gRPC client as the authorizer's plain HTTP response, where Envoy turns it into a gRPC status

Status: **draft for the author, not filed, not sent.** The author decides the channel. What agentgateway's own policy says
(SECURITY.md at v1.5.0, read 2026-09-25T00:04:30Z), quoted on both sides at the same weight:
- The channel it names: "To report a vulnerability, file a private vulnerability report" (l.5). "If you aren't sure if an
  issue is a security vulnerability, it's best to err on the side of caution and report it privately." (l.9) "If you are
  unsure, report the issue privately: a private report can later be made public, but a public issue cannot be made
  retroactively private." (l.14)
- Toward a bug or a limitation: "External policy components are trusted, at least in part. ext-auth, ext-proc, external
  rate limiting, and similar configured services are expected to behave correctly." (l.27) "Poor or ambiguous
  documentation is not itself a vulnerability." (l.26)
- The reading for the author, not decided here. What was counted is a refusal that held (0 requests reached the backend)
  delivered to the gRPC client in a form other than the one Envoy gives the same authorizer's answer, and the scope of
  agentgateway's gRPC translation was set deliberately (#1848, below). Whether that is a bug, a documentation issue or a
  limitation is the author's to read.

## What we counted (agentgateway v1.5.0; kind, Kubernetes v1.37.0; a GRPCRoute with an extAuth policy, grpc: {})

- The authorizer answered each refused check with status PERMISSION_DENIED and a DeniedHttpResponse {status 403, a text
  body}, the ordinary Envoy-protocol denial. 10 of 10 gRPC SubscribeToTask requests (grpc-go v1.83.2 clients) received a
  plain HTTP/2 response 403 with the text body and no content-type application/grpc. grpc-go reported status 7 with
  "unexpected HTTP status code received from server: 403 (Forbidden); malformed header: missing HTTP content-type". The
  proxy's access line read http.status=403 reason=DirectResponse. 0 requests reached the backend.
- For comparison, a CEL authorization Deny on the same route answered the same clients with HTTP 200, content-type
  application/grpc and grpc-status 7 (the proxy's own gRPC error form).

## What the source says

- agentgateway v1.5.0: a DeniedHttpResponse is built into a response with the authorizer's status, headers and body
  (crates/agentgateway/src/http/ext_authz.rs l.599-627) and returned as ProxyResponse::DirectResponse, which the proxy
  sends unchanged (crates/agentgateway/src/proxy/httpproxy.rs l.685-688). Only ProxyError values are converted to the
  gRPC form for a gRPC request (crates/agentgateway/src/proxy/mod.rs l.496, l.527-535). main, read 2026-09-25T00:34:26Z,
  is unchanged in this: a DirectResponse is still returned as is and only errors take the gRPC form (httpproxy.rs
  l.3692-3693), and the denied-response branch is the same (ext_authz.rs l.607). The commits to ext_authz.rs since the
  v1.5.0 release day are #3426, #3432 and #3599 (the API's commit list for the file, read 2026-09-25T00:34Z).
- Envoy v1.39.1 (read from source, not run here): the ext_authz filter sends a denied check as a local reply
  (source/extensions/filters/http/ext_authz/ext_authz.cc l.1012-1066; an error with failure_mode_allow false likewise,
  l.1096-1148), and a local reply to a gRPC request becomes HTTP 200, content-type application/grpc, grpc-status from the
  HTTP code, and the body as grpc-message (source/common/http/utility.cc l.746-766); 403 maps to PermissionDenied
  (source/common/grpc/status.cc l.14-15).

So an authorizer written for Envoy reaches a gRPC client as PERMISSION_DENIED with its message behind Envoy, and as a
plain HTTP 403 behind agentgateway v1.5.0. Read from the same source, not run: an authorizer could produce the gRPC form
itself by setting the denied response's status to 200 and its headers to content-type application/grpc and grpc-status,
since they are passed through; and a deny without a DeniedHttpResponse gets the proxy's own gRPC form (ext_authz.rs
l.628-631, l.1329-1331).

## Reproduction (the minimal form of the counted run; not run as written)

1. A GRPCRoute to any gRPC service, and an AgentgatewayPolicy on it: traffic.extAuth { backendRef: <authorizer>, grpc: {} }.
2. An envoy.service.auth.v3 authorizer that denies with status PERMISSION_DENIED and
   denied_response { status { code: Forbidden }, body: "denied" }.
3. Call any method through the route with a gRPC client.

Expected, as behind Envoy: grpc-status 7, grpc-message "denied". Counted: HTTP 403, no gRPC content type.

## Asks

- Extend #1848's translation (below) to an ext-authz denied response on a gRPC request, as Envoy's local reply does; or
- document that it is excluded: that the authorizer's denied response is passed through as is, so that an authorizer must
  shape gRPC replies itself.

## Searched before drafting (2026-09-25T00:34Z to 00:37Z, and a second pass 00:43Z to 00:45Z; GitHub search over issues and pull requests, repo agentgateway/agentgateway)

28 queries in two passes, the rate limit read before each, total_count beside each, none throttled
(upstream-search-grpc-deny.txt in the run directory). The first pass (16 queries) missed the change below; the second pass
(12 queries, after review) found it with grpc "trailers-only" and with into_response_with_grpc, and the items were then
read by number (agw-pr1848-3212-2162.txt).
- The change that set the behaviour reported here: #1848, "proxy: translate errors into gRPC errors for gRPC requests",
  merged 2026-05-18, contained in v1.5.0 (the API's compare). Its description: "This gives more useful context to gRPC
  clients. This is only for internally generated errors." An authorizer's denied response is not an internally generated
  error, so this report asks whether that scope should reach it.
- Related: #3212 (closed, completed 2026-09-01), "ext_proc never emits Frame::trailers, so gRPC grpc-status is dropped on
  every request", another path where a gRPC client does not get its status through a policy extension; #2162 (an open pull
  request), "proxy: do not leak error info to clients", which reworks the same error-to-response function.
- Related, not on point: #3431 (request trailers lost), #847 (open; ext-authz gRPC metadata handling), #2291 and #2383 (the
  HTTP ext-authz client's connection and timeout), #3068 (outbound spans for policy calls), #385 (ext-authz improvements),
  #998 (an OPA-Envoy response not returned to an MCP client).

Found by the lab's follow-on D-3 (experiments/runs/2026-09-24-d3-extauthz/).
