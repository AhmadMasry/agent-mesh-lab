# Draft issue — agentgateway docs: say that `agentgateway_requests_total` counts downstream requests at their final status, and that retry attempts are counted only by `agentgateway_retries_total`

Status: **withdrawn, not to be filed** (the author's decision, 2026-09-19). The file is kept because the findings entry
on metrics per hop cites it; nothing below is proposed upstream.

Project: agentgateway/agentgateway (documentation). Version observed: agentgateway **v1.5.0**, as istiod-provisioned
waypoints (GatewayClass `istio-agentgateway-waypoint`, Istio 1.31.0) and as a control-plane-provisioned egress,
Kubernetes 1.37.0 on kind. Pages and source read 2026-09-18:
- https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/metrics/dataplane.md (the 1.5.x line)
- https://raw.githubusercontent.com/agentgateway/agentgateway/v1.5.0/crates/agentgateway/src/telemetry/log.rs
- https://raw.githubusercontent.com/agentgateway/agentgateway/v1.5.0/crates/agentgateway/src/telemetry/metrics.rs

## Summary

This is a documentation clarification. The counters behave consistently; the page does not say which side of the
proxy one of them counts.

The data-plane metrics page describes the two counters as:

> `agentgateway_requests_total` | Counter | -- | The total number of HTTP requests sent.

> `agentgateway_retries_total` | Counter | -- | The total number of request retries.

It also opens with "Metrics are collected automatically for every request that passes through the gateway".

The series carry `backend` and `reason="Upstream"`, so "requests sent" can be read as requests sent to the
backend. When a route retries, that reading and the measurement part ways.

## What was measured

Two routes had a one-attempt retry (`attempts: 1`, `backoff: 100ms`) switched on, one at a time, and six requests
were sent through each. Every request's first attempt failed and its second was sent.

| route | requests sent to the backend (the receiving end's own per-request log) | `agentgateway_requests_total` delta | `agentgateway_retries_total` delta | `agentgateway_upstream_call_duration_seconds_count`, less the proxy's other requests |
| --- | --- | --- | --- | --- |
| a waypoint's HTTPRoute, `codes: [503]`, backend answers 503 then 200 | **12** | **6**, all `status="200"` | **6**, `status="200"` | **12** |
| an egress HTTPRoute, `codes: [500, 503]`, backend answers 500 twice | **12** | **6**, all `status="500"` | **6**, `status="500"` | **12** |

So `agentgateway_requests_total` counts one per downstream request, labelled with the final status. No series
records the first attempt's 503. The retry is counted only by `agentgateway_retries_total`, whose `status` label
is the retried request's final status, not the status that triggered the retry.

The v1.5.0 source reads the same way. Every HTTP metric is recorded in the request log's `drop()`
(`telemetry/log.rs:1214`), once per request, with labels that carry the final response status (`:1261`).
`requests` is incremented once (`:1330`), and `retries` by the log's `retry_attempt` count (`:1346`–`:1351`), with
the same labels. The HELP strings are at `telemetry/metrics.rs:420`–`421` and `:561`–`562`.

Records: `experiments/runs/2026-09-19-metrics-per-hop/` in this repository (`r2-waypoint-table.csv`,
`egress-table.csv` and the raw `samples/`).

## Suggested change

Only that the page say so: `agentgateway_requests_total` counts downstream requests, one per request, at their
final status; a retry attempt is not a second sample of it and is counted only by `agentgateway_retries_total`,
whose `status` label is the final status. One consequence belongs beside it: the page's own "Error rate" example,
`rate(agentgateway_requests_total{status=~"5.."}[5m]) / rate(agentgateway_requests_total[5m])`, counts final
statuses only, so a 5xx that a retry turned into a success does not appear in it.
