# Sources read at Gate 3 Task 0 that later tasks depend on

Everything here was fetched on 2026-09-09 in the session that built the step-3 overlay.
Pins and their URLs live in `versions.yaml`; this file holds the three things Task 1
and Task 2 need that are not themselves version numbers.

## 1. agentgateway tracing, for the ingress and the egress (Task 1)

The ingress `agentgateway-ingress` and the egress waypoint `agw-egress` run under
agentgateway's own control plane (v1.5.0, GatewayClass `agentgateway`), so they are
configured by agentgateway's own CRDs.

- The proxy emits no traces until asked to. Source:
  `https://raw.githubusercontent.com/agentgateway/website/main/assets/agw-docs/pages/observability/traces/setup.md`
  opens with "The agentgateway proxy does not emit traces by default."
- The resource is an `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`) targeting the
  Gateway, with the tracing block under `spec.frontend.tracing`. The documented shape,
  with the site's snippets resolved (`policy.md` -> `AgentgatewayPolicy`,
  `api-version.md` -> `agentgateway.dev/v1alpha1`, `namespace.md` ->
  `agentgateway-system`):

  ```yaml
  apiVersion: agentgateway.dev/v1alpha1
  kind: AgentgatewayPolicy
  metadata:
    name: tracing
    namespace: agentgateway-system
  spec:
    targetRefs:
      - kind: Gateway
        name: agentgateway-proxy
        group: gateway.networking.k8s.io
    frontend:
      tracing:
        backendRef:
          name: opentelemetry-collector
          namespace: tracing
          port: 4317
        protocol: GRPC
        randomSampling: "true"
  ```

  Sources: the OTel-collector backend page
  `.../assets/agw-docs/pages/observability/traces/configs/otel.md` and the Jaeger page
  `.../configs/jaeger.md`, which differ only in the backend they name.
- Sampling has two independent settings, from the setup page's own table:
  `randomSampling` applies "The incoming request carries no trace context, so the proxy
  decides whether to start a new trace" and defaults to `false`; `clientSampling`
  applies when the request already carries trace context and defaults to `true`. Both
  take `"true"`, `"false"` or a decimal string. Sampling every request therefore needs
  `randomSampling: "true"`.
- The CRD is installed on this cluster. `kubectl explain
  agentgatewaypolicy.spec.frontend.tracing` at agentgateway v1.5.0 lists `attributes`,
  `backendRef` ("Mutually exclusive with `url`"), `clientSampling`, `filter`, and
  describes the block as "OpenTelemetry tracing settings." So Task 1 can point the two
  proxies at `otel-collector.telemetry.svc.cluster.local:4317` by `backendRef`, or at a
  URL, and does not need a new CRD installed.

## 2. The istiod-driven waypoints (Task 1's spike)

The two waypoints in `lab` (`agentgateway-waypoint`, `agentgateway-waypoint-orch`) are
driven by istiod, not by agentgateway's control plane. Istio's own page,
`https://istio.io/latest/docs/ambient/usage/agentgateway/`, read 2026-09-09:

- Istio configures agentgateway "**only** through the Gateway API resources listed
  above", namely "Gateway (using the istio-agentgateway or istio-agentgateway-waypoint
  class), HTTPRoute, GRPCRoute, TCPRoute, and TLSRoute, InferencePool, from the Gateway
  API Inference Extension".
- "Istio's own configuration APIs — such as `VirtualService`, `DestinationRule`,
  `Sidecar`, `AuthorizationPolicy`, `PeerAuthentication`, `RequestAuthentication`,
  `Telemetry`, `WasmPlugin`, and `EnvoyFilter` — are **not** applied to agentgateway
  proxies."

So the Telemetry API is not a route to tracing on these two proxies, and the page names
no replacement. That leaves Task 1's spike to try whether an `AgentgatewayPolicy` is
read by an istiod-driven proxy at all, and to record the outcome either way. The page
says nothing about it, so nothing here predicts the answer.

## 3. HTTPRoute retry (Task 2)

- Fields at the pinned Gateway API v1.6.2, read from
  `https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.2/apis/v1/httproute_types.go`:
  `HTTPRouteRetry` has `codes` (list of status codes, Support: Extended), `attempts`
  (maximum retries of one backend request, minimum 1, Support: Extended) and `backoff`
  (minimum duration between attempts, Gateway API Duration format, Support: Extended).
  The type's own comment: "Implementations SHOULD retry on connection errors
  (disconnect, reset, timeout, TCP failure) if a retry stanza is configured." The stanza
  is still `<gateway:experimental>` at v1.6.2 and present only in the experimental CRD,
  which is the channel this lab installs.
- agentgateway documents the same stanza on an HTTPRoute rule, under a warning that the
  feature is experimental, in
  `.../assets/agw-docs/pages/resiliency/retry/retry.md`: a rule carrying
  `retry: {attempts: 3, backoff: 1s, codes: [500, 503]}`, and a way to read the policy
  back out of the proxy, `curl -s http://localhost:15000/config_dump | jq ...` after
  `kubectl port-forward deploy/<proxy> 15000`. That config_dump read is the check for
  "the gateway has the retry" that is separate from "the gateway fired the retry".
- Istio's agentgateway page lists HTTPRoute among the resources it passes to agentgateway
  but says nothing about the retry stanza specifically, so whether an istiod-driven
  waypoint honours it is a measurement, not a quotation.
- Neither document says whether a POST body is buffered for the retry. Task 2 counts
  arrivals at the receiver's ingress ledger and compares `body_sha256`, which answers it
  without needing the documentation to.
