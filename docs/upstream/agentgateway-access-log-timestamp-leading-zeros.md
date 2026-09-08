# Draft issue — agentgateway: log timestamps drop leading zeros in the sub-second field

Status: **filed and fixed.** Issue agentgateway/agentgateway#3369 (filed 2026-09-08, closed); fix merged the same day as
pull request agentgateway/agentgateway#3370 (`fix(telemetry): zero-pad the sub-second part of log timestamps`, merge
commit 98ada8a496613339d9e9a0f3b4d3e865ee28b79c on `main`). Versions up to v1.5.0 carry the defect; the first release
containing the fix is recorded here when it is published.
- https://github.com/agentgateway/agentgateway/issues/3369
- https://github.com/agentgateway/agentgateway/pull/3370

Project: agentgateway
Version observed: `1.5.0` (`cr.agentgateway.dev/agentgateway:v1.5.0`,
`sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`,
`git_revision fe6732474a96a0363dfb9822859af4e9bab360fa`, `build_target aarch64-unknown-linux-gnu`)
Deployment: Istio 1.31.0 ambient waypoint, GatewayClass `istio-agentgateway-waypoint`, Kubernetes 1.37.0 on kind.

## Summary

agentgateway renders the fractional-second part of its own log timestamps with leading zeros removed, so a
timestamp such as `13:29:20.003270Z` is printed as `13:29:20.3270Z`. Sub-100 ms fractions therefore read
as a value up to a hundred times larger, and consecutive log lines can appear out of chronological order
even though they were emitted in order.

## Reproduction

Any agentgateway that logs at least one line whose timestamp fraction begins with `0`. Compare
agentgateway's own timestamp with the container runtime's timestamp on the same line:

```
kubectl -n <ns> logs deploy/<gateway> --timestamps | grep "request gateway="
```

Field 1 is the kubelet timestamp, field 2 is agentgateway's.

Observed (five paired lines from one waypoint, all from the same access log):

```
kubelet                          agentgateway         true fraction  printed
2026-09-05T13:29:20.003363962Z   ...T13:29:20.3270Z    .003270       .3270
2026-09-05T13:33:11.066276208Z   ...T13:33:11.66179Z   .066179       .66179
2026-09-05T13:33:51.033535546Z   ...T13:33:51.33430Z   .033430       .33430
2026-09-05T13:31:49.824825504Z   ...T13:31:49.824736Z  .824736       .824736   (no leading zero: correct)
2026-09-05T13:34:10.422953930Z   ...T13:34:10.422787Z  .422787       .422787   (no leading zero: correct)
```

Lines whose fraction has no leading zero print correctly, so the effect is confined to the leading-zero
case. Counted over one waypoint's whole access log for this run: **6 of 38 lines are affected**. The
reproducible predicate is the printed fraction's length — agentgateway prints six digits when it prints
them all, and fewer exactly when it has dropped leading zeros:

```
awk '{split($2,b,"."); f=substr(b[2],1,length(b[2])-1); if (length(f)<6) print}' pairs.txt
```

The six affected fractions are `.3270`, `.66179`, `.67896`, `.33430`, `.33344` and `.16671`. A further 4
of the 38 lines differ from the kubelet timestamp in the first three fraction digits, but those are
ordinary sub-millisecond skew between the two clocks (81 µs to 471 µs, e.g. kubelet `.408081926` against
agentgateway `.407967`) and are **not** instances of this defect; the remaining 28 agree closely.

Effect on ordering: in one clean request the agent-card `GET` (kubelet `.003363962`) is emitted before the
`SendMessage` `POST` (kubelet `.207514087`), but agentgateway prints them as `.3270` and `.207364`, so a
reader sorting on agentgateway's own timestamps puts them in the wrong order.

## Where it comes from (read at tag v1.5.0)

`crates/core/src/telemetry/date.rs`, `write()`: the cached part of the timestamp ends at the `.` and the
microseconds are appended with `itoa::Buffer::format(micros)`, which renders `3270` for 3270 µs; the
value is never zero-padded to six digits (lines 20 to 26 at the tag). The cached prefix was introduced by
PR #177 ("Performance optimizations, mostly around logs", merged 2025-07-16). A `{:06}` format of `micros`
would print `.003270`.

Searched 2026-09-07 across issues and pull requests in agentgateway/agentgateway (timestamp, leading zero,
access log time, fractional seconds, subsec, nanosecond, log format, time format, RFC3339): nothing similar,
open or closed.

## Not shared with ztunnel

ztunnel 1.31.0 in the same cluster prints the same class of timestamp correctly (`...T13:33:11.067596Z`
against kubelet `...T13:33:11.067712791Z`), so this is specific to agentgateway's log formatting rather
than to the Istio ambient log pipeline.

## Why it matters here

The access log is the request-scoped evidence that a request traversed the waypoint (per
https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/access-logs/view/, access logs
are written to stdout for every request with no policy configuration). Correlating those lines with other
ledgers by time requires the timestamps to be readable as written.

## Evidence in this repository

`experiments/runs/2026-09-05-baseline-step2/waypoint-access-log.txt` (agentgateway's own lines) and
`experiments/runs/2026-09-05-baseline-step2/waypoint-timestamp-pairs.txt` (kubelet timestamp beside
agentgateway's, same lines).
