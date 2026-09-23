# Draft report — agentgateway: a Deny rule on request.body does not fire when the client sends a body past maxBufferSize, and nothing is logged at the default log level

Status: **draft for the author, not filed, not sent.** The author decides the channel: a private vulnerability report or a
public issue. What agentgateway's own policy says, read 2026-09-23 (SECURITY.md at v1.5.0; main differs only by an added
CRA stewardship paragraph), quoted on both sides at the same weight:
- The channel it names: "To report a vulnerability, file a private vulnerability report" (GitHub security advisories,
  l.5). "Please do not report security vulnerabilities through public GitHub issues. If you aren't sure if an issue is a
  security vulnerability, it's best to err on the side of caution and report it privately." (l.8-9) "Project
  maintainers are responsible for determining whether a report describes a security vulnerability. If you are unsure,
  report the issue privately: a private report can later be made public, but a public issue cannot be made
  retroactively private." (l.14)
- Toward a vulnerability: "A vulnerability defeats a promised security boundary. An attacker must be able to defeat a
  security boundary that Agentgateway claims to enforce without already possessing equivalent authority." (l.23, its
  first two sentences) "Issues remotely exploitable by an unauthenticated attacker are generally more serious than those
  requiring authentication, administrative access, infrastructure privileges, or equivalent authority." (l.29)
- Toward a bug, limitation or documentation issue: "Outcomes caused solely by user configuration, user-written CEL,
  trusted extensions or services, documented behavior, or already-privileged access are generally bugs, limitations, or
  user error." (l.23, its third sentence) "If a user writes an incorrect policy, even if it was a reasonable mistake, it
  is their responsibility to fix it." (l.25) "Poor or ambiguous documentation is not itself a vulnerability." (l.26)
  Listed as generally bugs, limitations or user error: "A dangerous but documented default or behavior." (l.46) and "A
  user's CEL expression producing unintended behavior, including failing to compile or evaluate as the author
  expected." (l.47)
- The two readings, stated for the author and not decided here. (a) The client needs no authority over the policy: it
  chooses the body size, and an operator-written authorization rule then does not fire, which reads against l.23's
  first two sentences and l.29. (b) Each half of the behaviour is documented — request.body fails to evaluate past the
  limit (cel.md l.14), and Deny's expression failures fail to deny (the CRD) — and the rule is user-written CEL, which
  reads against l.23's third sentence, l.25, l.26, l.46 and l.47. The section "What no page we read joins together"
  below bears on (b): the halves are documented, their combination for body rules is not, and the buffering page states
  a different outcome for over-limit bodies. The policy's own instruction when unsure is l.8-9 and l.14.
- A conflicting page: the website's reference/vulnerabilities.md at the v1.5.0 tag names the kgateway project and a
  kgateway email list as where to report; the repository's SECURITY.md names GitHub's private report. The author may
  want to mention the mismatch whichever channel is used.

Written 2026-09-23 from Experiment C, step C-8 (findings.md, "Experiment C / both receivers / C-8"; run directory
experiments/runs/2026-09-23-c8-body-rule/). Nothing was posted, reported or sent to anyone.

Project: agentgateway (the proxy; its documentation, and possibly its logging)
Version observed: v1.5.0 (cr.agentgateway.dev/agentgateway:v1.5.0; image id
sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896 as the lab records it in versions.yaml,
key agentgateway-controlplane, observed.proxy_image_id — this step's run directory records the tag only), Kubernetes
controller v1.5.0, Gateway API
v1.6.2, on kind (Kubernetes v1.37.0). No maxBufferSize is set, so the default of 2,097,152 bytes applies
(crates/agentgateway/src/lib.rs at v1.5.0, l.339-340).

## What the documents already say

- request.body: "The request's body, buffered up to maxBufferSize. If the body exceeds the max buffer size, this field is
  not available and will fail to evaluate." (schema/cel.md at v1.5.0, l.14; unchanged on main).
- Deny: "Deny is not recommended because expression failures fail to deny; prefer Allow or Require. If used, design
  expressions defensively against evaluation errors." (the AgentgatewayPolicy CRD's description of
  traffic.authorization.policy, as installed; crates/agentgateway/src/http/authorization.rs at v1.5.0, l.135-137;
  schema/config.md; unchanged on main).
- The website's buffering page at v1.5.0 (traffic-management/buffering.md, l.6): "For large requests that must be buffered
  and that exceed the default buffer limit, agentgateway either disconnects the connection to the downstream service if
  headers were already sent, or returns a 413 HTTP response code." What was counted departs from that: the over-limit
  body was forwarded with 200. No document we read says whether a body buffered for a CEL rule counts as one that "must
  be buffered"; the source (crates/agentgateway/src/http/mod.rs at v1.5.0, inspect_body_with_limit) returns a partial
  body past the limit rather than an error, and the CEL request body is not then available (schema/cel.md l.14).
- The website's authorization page at v1.5.0 (security/authorization.md) recommends against Deny for missing fields,
  with a JWT-claim example: "evaluates to false and the rule does not fire — silently allowing requests you intended to
  block" (l.276).

## What no page we read joins together

- A body over maxBufferSize is an evaluation failure, and the client chooses the body size. So a Deny rule on
  request.body can be bypassed by a client that pads its request past the limit (counted: curl, on two routes), and
  the documented example of the failure is a missing JWT claim, not a body. The authorization page does not mention
  bodies or buffering. The buffering page states a 413 or a disconnect for over-limit bodies that must be buffered,
  not a forward. The CRD's sentence does not reach the website's authorization page.
- At the default log level (the lab sets none), the proxy logs nothing when this happens. The forwarded request's
  access line reads like any other (http.status=200, no error, no reason), and in each of the four rule windows the
  proxy wrote 0 lines other than access lines. In source, the rule set's validate() returns a bool and the only log
  line on that path is at debug level (crates/agentgateway/src/http/authorization.rs at v1.5.0).
- The recommended alternative, Require, fails closed on the padded body. Written naively, it also refuses every
  request with no body on the same route (for an A2A server, the agent-card GET). A first term that exempts bodyless
  requests fixes that (counted below).

## Reproduction

The commands below are the minimal form of the lab's probes (c8.sh in the run directory) and were not run as written.
The counted probes also sent Host, A2A-Version: 1.0, X-Logical-Work-Item-Id and traceparent headers, and the comments
give the counted results. One difference beyond size: curl sent Expect: 100-continue for the 2,200,000-byte bodies
only. The attribution of the forward to maxBufferSize rests on schema/cel.md l.14 and the source's partial-body branch;
no control padded to just under the limit was sent.

Any HTTP backend behind an agentgateway Gateway and an HTTPRoute. One AgentgatewayPolicy on the route:

    apiVersion: agentgateway.dev/v1alpha1
    kind: AgentgatewayPolicy
    metadata:
      name: deny-by-body
      namespace: default
    spec:
      targetRefs:
        - group: gateway.networking.k8s.io
          kind: HTTPRoute
          name: my-route
      traffic:
        authorization:
          action: Deny
          policy:
            matchExpressions:
              - 'json(request.body).method == "SubscribeToTask"'

A small body is refused:

    printf '{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"t1"},"id":"1"}' > small.json
    curl -sS --retry 0 -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
      --data-binary @small.json http://GATEWAY/
    # counted: 403; access line http.status=403 error="authorization failed" reason=Authorization

The same request padded past the default limit, here inside a field the request type defines (A2A's
SubscribeToTaskRequest has an optional opaque tenant string), is forwarded:

    { printf '{"jsonrpc":"2.0","method":"SubscribeToTask","id":"1","params":{"id":"t1","tenant":"'
      head -c 2200000 /dev/zero | tr '\0' 'a'; printf '"}}'; } > padded.json
    curl -sS --retry 0 -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
      --data-binary @padded.json http://GATEWAY/
    # counted: forwarded, the backend's own status (200); access line http.status=200, no error, no reason; no other
    # proxy log line

## What we counted (v1.5.0, two HTTPRoutes, one rule at a time; two A2A servers, a2a-go v2.5.0 and a2a-python 1.1.4)

- **Deny** on json(request.body).method == "SubscribeToTask", bodies under the limit: 40 of 40 SubscribeToTask
  requests refused with 403, none reaching a server. 40 of 40 SendMessage and SendStreamingMessage requests forwarded.
  30 of 30 bodyless GETs forwarded.
- **Deny**, a 2,200,000-byte SubscribeToTask:
  - padded with an extra top-level member: forwarded 2 of 2. a2a-go dispatched it; a2a-python rejected the unknown
    member itself (-32600).
  - padded inside params.tenant: forwarded 1 of 1, and a2a-python dispatched it (answering -32001, task not found,
    because the task id did not exist).
  - So both servers dispatched a padded SubscribeToTask that the rule was written to refuse.
- **Require** on json(request.body).method != "SubscribeToTask":
  - the 2,200,000-byte SubscribeToTask: refused 2 of 2.
  - bodyless GETs on the same route (an A2A client's agent-card fetch): refused 15 of 15, so that client could send no
    operation at all.
- **Require** on request.method == "GET" || json(request.body).method != "SubscribeToTask": bodyless GETs 15 of 15
  forwarded; SendMessage and SendStreamingMessage 20 of 20 forwarded; SubscribeToTask 20 of 20 refused; the
  2,200,000-byte SubscribeToTask 2 of 2 refused. In the CEL implementation agentgateway builds
  (crates/cel-fork/cel/src/objects.rs at v1.5.0, l.770-786), a true left side decides the || without evaluating the
  right side.
- A JSON-RPC batch (an array holding one SubscribeToTask) also passed the Deny rule, 2 of 2. Both servers refused
  batches themselves, so nothing was dispatched, but the rule did not refuse it.

## Asks

1. Documentation: say on the authorization page, and beside request.body in the CEL reference, that a body over
   maxBufferSize makes request.body fail to evaluate, so a Deny on it does not fire. The client controls the size, so a
   Deny on request.body is bypassed by padding. Carry the CRD's "expression failures fail to deny" sentence onto the
   website's authorization page. Show a body rule written as Require, with a term that exempts bodyless requests.
2. A question: can an authorization expression's failure to evaluate be made visible in the access log or a span? At
   v1.5.0 and the default log level we found no signal: the forwarded request's line reads like any other, and the
   proxy writes no other line. (proxy.error, added after v1.5.0 by #3215, describes responses synthesized from a failed
   request, so a fail-open forward does not reach it.)

## Searched before drafting (2026-09-23; GitHub search over issues and pull requests, repo agentgateway/agentgateway unless noted; published security advisories; commits on main since v1.5.0)

Queries, total_count and rate limit per call are in experiments/runs/2026-09-23-c8-body-rule/upstream-search.txt. None
covers this case. Related:
- #2615 (PR, merged 2026-07-21, in v1.5.0) "cel: do not expose body when exceeds buffer": the change that makes
  request.body fail to evaluate over the limit.
- #2678 (PR, merged 2026-07-24, in v1.5.0) "cel: if the body exceeds the buffer size, expose it as a separate
  attribute": request.bodyPrefix.
- #2677 (PR, merged 2026-07-24, in v1.5.0) "docs: recommend against Deny policies".
- #3523 (issue, open) "remoteRateLimit can bypass quotas when descriptor CEL evaluation fails": the same fail-open
  shape, for rate limiting.
- #3610 (issue, open) "Feature: A2A protocol guardrails (parity with MCP ExtMCP)".
- #3215 (PR, merged 2026-08-31, not in v1.5.0) "cel: expose proxy.error attributes": not on point, since proxy.error
  covers responses synthesized from a failed request and a fail-open forward is not one.
- Published security advisories: 4, none on authorization expressions or request bodies.
- main is 259 commits past v1.5.0. The request.body entry in schema/cel.md and the Deny comment in authorization.rs are
  unchanged there. We found no fix after v1.5.0.
