# Draft report — agentgateway: extAuth forwardBody.maxSize is described as rejecting a larger body, and the proxy instead sends the authorizer the first maxSize bytes, marked on gRPC only by size -1

Status: **draft for the author, not filed, not sent.** The author decides the channel. What agentgateway's own policy says
(SECURITY.md at v1.5.0, read 2026-09-25T00:04:30Z), quoted on both sides at the same weight:
- The channel it names: "To report a vulnerability, file a private vulnerability report" (l.5). "If you aren't sure if an
  issue is a security vulnerability, it's best to err on the side of caution and report it privately." (l.9) "If you are
  unsure, report the issue privately: a private report can later be made public, but a public issue cannot be made
  retroactively private." (l.14)
- Toward a documentation issue: "Poor or ambiguous documentation is not itself a vulnerability. We may fix documentation
  and call out in release notes that users should review affected configurations, without issuing a CVE." (l.26) The
  line does not name documentation that contradicts the behaviour, which is this case; it is the nearest line, and the one
  this report reads against. "External policy components are trusted, at least in part. ext-auth, ext-proc, external rate
  limiting, and similar configured services are expected to behave correctly." (l.27) l.46, "A dangerous but documented
  default or behavior.", fits less: the behaviour here is not the documented one.
- The reading for the author, not decided here. What differs is the policy API's description against what the
  controller and the dataplane do; the authorizer receives the partial marker the dataplane sets (size -1), so an
  authorizer that reads it can refuse, as the lab's did. That reads toward l.26 and l.27. Against it: the description
  promises the stricter behaviour, so an operator who wrote an authorizer to the description has no reason to read size.

## What the documents say

- AgentgatewayPolicy, spec.traffic.extAuth.forwardBody.maxSize, in the API type at v1.5.0
  (controller/api/v1alpha1/agentgateway/agentgateway_policy_types.go l.3084-3092) and in the installed CRD
  (agentgateway.dev_agentgatewaypolicies.yaml l.5366-5373): "Largest body, in bytes, that will be buffered and sent to the
  authorization server. If the body size is larger than maxSize, then the request will be rejected with a response."
- The controller at v1.5.0 (controller/pkg/agentgateway/plugins/traffic_plugin.go l.1356-1367) sets
  AllowPartialMessage: true on every forwardBody, with the comment "Currently the default, see
  https://github.com/kubernetes-sigs/gateway-api/issues/4198", and PackAsBytes: false with "TODO: should we allow config?".
  The CRD has no field for either.
- The dataplane at v1.5.0 (crates/agentgateway/src/http/ext_authz.rs l.289-317): with allow_partial_message a body past
  max_request_bytes is sent truncated to max_request_bytes, and the gRPC CheckRequest's size is set to -1 (l.307-310,
  l.498, where the comment reads "Report original body size, not truncated size"). The HTTP protocol adds the header
  x-envoy-auth-partial-body (l.834-840); the gRPC protocol adds nothing else. The 413 branch (l.456-460) is reached only
  without allow_partial_message, which the controller never sends.
- Gateway API v1.6.2 (apis/v1/httproute_types.go) carries both texts for the same field: "Bodies over that size must be
  rejected with a 4xx series error (413 or 403 are common examples), and fail processing of the filter." (l.1690-1693)
  and "If the body size is larger than maxSize, then the body sent to the authorization server must be truncated to
  maxSize bytes." (l.1789-1795, "Experimental note: This behavior needs to be checked against various dataplanes").
  kubernetes-sigs/gateway-api#4198 ("External Auth feedback", 2025-10-23) names the contradiction; a maintainer's comment
  of 2025-10-27 reads "The former is a leftover, it should have been updated, we agreed on the latter (I seem to recall)."
  It was closed by the triage robot as not planned on 2026-05-15, and the v1.6.2 text still carries both.
- main, read 2026-09-25T00:02:14Z: the API type's sentence (l.3157), the controller's AllowPartialMessage: true (l.1394)
  and the dataplane's -1 (l.309-311) are unchanged.

## Reproduction (the minimal form of the counted run; not run as written)

1. A Service for any gRPC server of envoy.service.auth.v3.Authorization that logs the size and the length of the body it
   receives, port with appProtocol kubernetes.io/h2c.
2. An AgentgatewayPolicy on an HTTPRoute:

       traffic:
         extAuth:
           backendRef: { name: <authorizer>, namespace: <ns>, port: <port> }
           grpc: {}
           forwardBody:
             maxSize: 2097152

3. POST a 2,200,000-byte JSON body through the route.

Expected by the CRD's description: the request refused with a response. Counted instead (below): the check is sent, with
2,097,152 bytes of body and size -1, and the proxy then does what the authorizer answers.

## What we counted (v1.5.0; kind, Kubernetes v1.37.0; two HTTPRoutes and two GRPCRoutes; the lab's own authorizer)

- 6 JSON-RPC POSTs of 2,200,000 bytes (3 shapes, 2 routes), with the authorizer set to refuse a body it cannot read: every
  check carried body length 2,097,152 and size -1, and every request was refused by the authorizer's 403.
- The same 6 with the authorizer set to allow what it cannot read: every check carried body length 2,097,152 and size
  -1; every request was forwarded (200) with its whole 2,200,000-byte body. The SubscribeToTask padded in params.tenant
  was dispatched by both servers (a2a-go v2.5.0 and a2a-python 1.1.4), the one padded by an extra top-level member by
  a2a-go only (a2a-python refused the extra field itself), and the SendMessage padded in params.tenant completed on both.
- The installed policy, read back from the proxy's config dump, held includeRequestBody {maxRequestBytes 2097152,
  allowPartialMessage true, packAsBytes false}.

## Asks

- Make the forwardBody.maxSize description state what the controller configures: past maxSize the body is truncated to
  maxSize bytes, and on the gRPC protocol the only partial marker is size -1 (on HTTP, the x-envoy-auth-partial-body
  header).
- Or make the choice a field (AllowPartialMessage), so that an operator can have the rejection the description names.

## Searched before drafting (2026-09-25T00:00Z to 00:03Z; GitHub search over issues and pull requests, repo agentgateway/agentgateway)

The rate limit was read before every call; every total_count is beside its query in upstream-search.txt in the run
directory. Six pull-request queries were throttled on the first pass and are recorded there as FAILED; all six were run
again after the reset and completed. None FAILED on the second pass.
- On point, and not this report: #1589 (merged 2026-04-20, "ext authz: implement allow_partial_body", no description;
  it touched ext_authz.rs and its tests only). kubernetes-sigs/gateway-api#4198 (above).
- Related, not on point: #304, #577, #578 (passing the body to ext_authz), #2284 (a custom body for HTTP), #875 (buffer the
  response body only when needed), #2581 (streaming response and ext_authz), #2615 (CEL does not expose a body past the
  buffer), #1781 and #1854 (byte quantities in the API).
- No issue or pull request names the forwardBody description against the controller's AllowPartialMessage.

Found by the lab's follow-on D-3 (experiments/runs/2026-09-24-d3-extauthz/).
