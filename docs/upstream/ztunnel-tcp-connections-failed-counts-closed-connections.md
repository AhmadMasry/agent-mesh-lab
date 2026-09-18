# Draft issue — ztunnel: `istio_tcp_connections_failed_total` counts a connection that closed with an error as one that "failed to establish"

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: istio/ztunnel. Version observed: ztunnel **1.31.0** (`docker.io/istio/ztunnel:1.31.0-distroless`,
installed by the Istio 1.31.0 Helm charts with `profile: ambient`), Kubernetes 1.37.0 on kind, mesh-wide STRICT
PeerAuthentication. Source read at tag `1.31.0`, 2026-09-18:
https://raw.githubusercontent.com/istio/ztunnel/1.31.0/src/proxy/metrics.rs

## Summary

The counter's own HELP text reads:

> `# HELP istio_tcp_connections_failed The total number of TCP connections that failed to establish (unstable).`

Measured: it also increases for connections that **were** established, stayed open for 293–782 s, carried
648–13 792 bytes each way, and then ended with an error while closing. Each such connection is counted with `response_flags="CONNECT"`, the flag a failed
connect carries. So a reader who takes the counter at its word counts a closed connection as one that was never
made.

## What was observed

Four increments, 2026-09-18, one ztunnel (the node every lab workload runs on). Each matches one access-log line of
that ztunnel at level `error`, of the form `connection complete … error="while closing connection: …"`:

| log time (UTC) | direction | source → destination | duration | bytes sent / received | error | counter series, reporter | value change (Prometheus, 15 s scrape) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 21:31:41.08 | outbound | orchestrator → worker's waypoint | 782 715 ms | 751 / 703 | `send: io error: broken pipe` | `source`, `response_flags=CONNECT` | 0 → 1 |
| 21:50:59.42 | inbound | worker's waypoint → worker | 293 674 ms | 9874 / 13792 | `receive: io error: broken pipe` | `destination`, `response_flags=CONNECT` | 0 → 1 |
| 21:50:59.47 | inbound | orchestrator's waypoint → orchestrator | 293 675 ms | 648 / 1496 | `receive: io error: broken pipe` | `destination`, `response_flags=CONNECT` | 0 → 1 |
| 21:56:52.51 | outbound | orchestrator → worker's waypoint | 782 577 ms | 754 / 705 | `send: io error: broken pipe` | `source`, `response_flags=CONNECT` | 1 → 2 |

Four error lines and four increments. Neither ztunnel logged any other line at level `error` in the 52 minutes
read (21:08:56Z to 22:01:22Z).

The connections were HBONE connections that had been open for 293–782 s. The two waypoint → backend ones each
carried a whole row's traffic, not one request's:
- waypoint → worker, 9874/13 792 bytes: every request the worker's waypoint sent the worker during that row. That
  was 12 deliveries, 6 agent-card fetches and 20 control requests, 38 upstream calls by the waypoint's own histogram.
- waypoint-orch → orchestrator, 648/1496 bytes: that row's 8 control resets.

The two orchestrator → waypoint ones carried about 750 bytes each, about one request's worth, and then stayed open.
Record: `experiments/runs/2026-09-19-metrics-per-hop/waypoint-connections.txt`, with the ztunnel lines in
`failed-connections.txt` beside it.

No request was lost when a connection closed. The receivers' own pre-dispatch ledgers, read from their logs over
the same period, hold 61 A2A `SendMessage` arrivals and 61 responses (worker 48, orchestrator 13), and 43
agent-card GETs, each paired. None is unpaired. Record: `experiments/runs/2026-09-19-metrics-per-hop/pairs.txt`.

## Why, as read from the source (tag 1.31.0, `src/proxy/metrics.rs`)

- Lines 388–389 register the family with the HELP text above.
- `record()` (line 701): when no flag has been set and the result is an error, the flag is inferred by
  `extract_failure_reason()` (line 712). That function maps the known `proxy::Error` variants to specific flags;
  any other `proxy::Error` gives `_ => ResponseFlags::ConnectionFailure` (line 730); and an error that is not a
  `proxy::Error` gives the default at line 735, again `ResponseFlags::ConnectionFailure` ("Default to generic
  connection failure if we can't identify the error type").
- `record_internal()` (line 739) then increments `connection_failures`, the `tcp_connections_failed` family, for
  `ConnectionFailure` and six other flags (line 760).

Nothing on that path separates an error at establishment from an error at close. A connection whose `Result` is an
error for any reason ends up as a connection failure. `ResponseFlags::ConnectionFailure` is also what renders as
`CONNECT` on the `response_flags` label.

## Expected

One of:
- the family counts only connections that failed to establish, as its HELP says, and a connection that completes
  with an error on close gets another flag or none; or
- the HELP text, and any documentation of the family, says it counts connections that **ended** with an error, and
  `CONNECT` is not the flag for an error raised while closing.

## Reproduction

**Observed in a lab cluster, not yet reduced to a standalone case.** The evidence is the log lines and the
Prometheus range answer recorded together in `experiments/runs/2026-09-19-metrics-per-hop/failed-connections.txt`
(this repository), read by the committed `failed-connections.sh` beside it.

The steps a minimal case would take, **not run**:
1. Two ambient-captured pods on one node.
2. A long-lived HTTP/1.1 keep-alive client in one pod against the other, through ztunnel.
3. Let the connection idle past the client's pool timeout, or have the server close its end first.
4. Compare `istio_tcp_connections_failed_total` before and after with the ztunnel access log.

## Impact

`istio_tcp_connections_failed_total{response_flags="CONNECT"}` is the natural series for an alert on
"connections that could not be made". Measured here, it also rises when pooled connections that had been carrying
traffic close. In this lab two such closes happened within 51 ms of each other, in the same second a route in
another namespace was patched; that timing was observed, not established as the cause. An alert on this series
would fire for them.
