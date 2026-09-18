# Draft issue — Istio docs: an agentgateway waypoint reports no Istio standard metrics, and no page says which metrics it reports

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: istio/istio (documentation). Version observed: Istio **1.31.0** ambient, installed by Helm with
`pilot.env.PILOT_ENABLE_AGENTGATEWAY=true`; two waypoints of GatewayClass `istio-agentgateway-waypoint`, provisioned
by istiod; Kubernetes 1.37.0 on kind. Pages read 2026-09-18, whose version menu marks "v1.31 (Current)":
- https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/
- https://istio.io/latest/docs/reference/config/metrics/
- https://istio.io/latest/docs/ambient/usage/agentgateway/

## Summary

This is a documentation gap. The proxies behave consistently; what they report is simply not what the ambient
pages lead a reader to expect.

The ztunnel troubleshooting page says:

> If a service is only using the secure overlay provided by ztunnel, the Istio metrics reported will only be the
> L4 TCP metrics (namely istio_tcp_sent_bytes_total, istio_tcp_received_bytes_total,
> istio_tcp_connections_opened_total, istio_tcp_connections_closed_total). The full set of Istio and Envoy metrics
> will be reported if a waypoint proxy is used.

The standard-metrics reference defines the first of Istio's HTTP metrics:

> Request Count (istio_requests_total): This is a COUNTER incremented for every request handled by an Istio proxy.

The agentgateway usage page states its scope in these sentences:

> Istiod configures agentgateway exclusively through Kubernetes Gateway API resources, which it delivers to the
> proxy over xDS. The proxy is a distinct data plane implementation from Envoy: when a Gateway selects an
> agentgateway GatewayClass, Istiod provisions and manages an agentgateway Deployment and Service for it, in the
> same way it manages Istio’s Envoy-based gateways.

> Istio configures agentgateway only through the Gateway API resources listed above. Istio’s own configuration
> APIs — such as VirtualService, DestinationRule, Sidecar, AuthorizationPolicy, PeerAuthentication,
> RequestAuthentication, Telemetry, WasmPlugin, and EnvoyFilter — are not applied to agentgateway proxies.

Neither page says which metrics an agentgateway waypoint reports.

## What was measured

Both agentgateway waypoints handled HTTP requests in one ten-minute window: by their own
`agentgateway_requests_total`, 50 on the worker's waypoint and 30 on the orchestrator's. The 20 A2A `SendMessage`
calls among the first 50 also appear, one each, in the worker's pre-dispatch ledger. The waypoints' `/metrics` on
port 15020, read before and after that traffic through the Kubernetes API proxy, carries **no `istio_*` family at all** — no `istio_requests_total`, no
`istio_request_duration_milliseconds`. It carries agentgateway's own families instead: `agentgateway_requests_total`
with `gateway`, `route`, `backend`, `method`, `status` and `reason` labels; `agentgateway_request_duration_seconds`;
`agentgateway_retries_total` once a retry has happened; and so on, as agentgateway's own page documents
(https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/metrics/dataplane.md).

In practice, then:
- the per-request series of a service behind an agentgateway waypoint are `agentgateway_*`, not `istio_*`;
- they carry no `source_workload` or `destination_workload` labels, so the Istio-standard dimensions are not
  there to query;
- ztunnel still reports the L4 `istio_tcp_*` families for the hops into and out of the waypoint.

Records: `experiments/runs/2026-09-19-metrics-per-hop/families-start.csv`, `families-end.csv` and `inventory.csv`
in this repository.

## Suggested change

Only that the page say, for the `istio-agentgateway-waypoint` class, which metrics a waypoint of that class
reports. As measured here, those are agentgateway's own families on port 15020, and no Istio standard metrics.
