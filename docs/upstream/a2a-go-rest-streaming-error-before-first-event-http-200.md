# Draft issue — a2a-go: on the REST binding, a streaming request that fails before its first event is answered HTTP 200, with the error inside the event stream

Status: **draft for the author, not filed, not sent.** Written by follow-on D-2 (experiments/runs/2026-09-24-d2-bindings/).
The searches, in that run directory's upstream-search/:
- a2a-go's issues and pull requests: 8 query strings, is:issue and is:pr each, read 2026-09-24T22:24Z (a2a-go-search.txt).
- The specification repository (a2aproject/A2A): the first search, 2026-09-24T22:25Z, answered one query pair and then stopped
  at GitHub's rate limit; its next calls FAILED (a2a-spec-1262.txt). It was completed 2026-09-24T22:49Z: 8 query strings,
  is:issue and is:pr each, the rate limit read before each call, every call answered, none FAILED
  (a2a-spec-search-completed.txt). It found no duplicate. Read by number:
  - a2aproject/A2A#1262, "[Bug]: Clarify streaming errors in REST transport binding", open since 2025-12-01, two comments of
    2025-12-03, the closest: it asks how a REST stream should carry an error, and the a2a-go maintainers named it in
    a2aproject/a2a-go#319 as their open question on this binding. It does not address the before-first-event case.
  - a2aproject/A2A#2227, an OPEN pull request (the ACTS conformance corpus), related: it rebuilds its error tables from the
    specification's §5.4 and adds header inspection.
  - a2aproject/A2A#1105 (closed; ambiguity of the 0.3.0 REST payloads, not streaming status) and a2aproject/A2A#1503 (closed;
    JSON-RPC streams closed after the first event, not this case), related.
Where the draft goes is the author's decision: a new issue in a2aproject/a2a-go, or a comment on a2aproject/A2A#1262.
Related in a2a-go, and not this case: a2aproject/a2a-go#318 and #319 (opened 2026-04-12, closed and merged 2026-04-21), in
which the REST client learned to decode an error carried as an SSE event. No link until it is filed.

## Issue text

**Version.** a2a-go v2.5.0 (github.com/a2aproject/a2a-go/v2), server side, `a2asrv.NewRESTHandler`.

**What happens.** A REST streaming request whose handler fails before yielding any event is answered `HTTP/1.1 200 OK`,
`Content-Type: text/event-stream`, with a single SSE event carrying the google.rpc.Status error. For example,
`POST /tasks/{id}:subscribe` for a task that does not exist (and `GET`, which the handler also routes):

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

id: c09a490a-e6dc-4626-93cf-5e2ae570231b
data: {"error":{"code":404,"status":"NOT_FOUND","message":"task not found: no active execution","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","domain":"a2a-protocol.org",...,"reason":"TASK_NOT_FOUND"}]}}
```

The body's own `error.code` is 404 while the HTTP status is 200. A unary REST request answers its error with the
matching status: `GET /tasks/{id}` for the same missing task answers `HTTP/1.1 404 Not Found` with the same error shape. An
`UnsupportedOperationError` raised by a `CallInterceptor` before a stream starts behaves the same: 200, and the error
(code 400, `FAILED_PRECONDITION`, reason `UNSUPPORTED_OPERATION`) inside the stream.

**Why it matters.** The specification's error mapping says "All A2A-specific errors defined in Section 3.3.2 **MUST** be
mapped to binding-specific error representations", with `TaskNotFoundError` -> `404 Not Found` and
`UnsupportedOperationError` -> `400 Bad Request` for HTTP (§5.4 at v1.0.1), and §11.6 gives the HTTP error response with
that status. Before any event is written no response header has left, so the status is still free to carry the error.
Anything between the client and the agent that reads statuses (an access log, a metric by status, a gateway's retry or
circuit-breaking policy) records a successful request. On a Kubernetes cluster with agentgateway v1.5.0 in front of an
a2a-go v2.5.0 REST server, the proxy's access line for each such request read `http.status=200`, 22 of 22 (12 subscriptions
to a missing task and 10 refused by an interceptor, from two clients), where the same 22 requests to an a2a-python 1.1.4
REST server read 404 (12) and 400 (10), on the proxy's line and at the client.

**Where.** `a2asrv/rest.go`, `handleStreamingRequest`: `sseWriter.WriteHeaders()` is called before the event sequence is
started, so an error from the sequence's first step can only be written as an event.

**Minimal reproduction.**

```go
package main

import (
	"context"
	"iter"
	"log"
	"net/http"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

type noop struct{}

func (noop) Execute(context.Context, *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(func(a2a.Event, error) bool) {}
}
func (noop) Cancel(context.Context, *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(func(a2a.Event, error) bool) {}
}

func main() {
	log.Fatal(http.ListenAndServe("127.0.0.1:18090", a2asrv.NewRESTHandler(a2asrv.NewHandler(noop{}))))
}
```

```
curl -i -X POST -H 'A2A-Version: 1.0' http://127.0.0.1:18090/tasks/no-such-task:subscribe   # 200, error in the stream
curl -i http://127.0.0.1:18090/tasks/no-such-task                                             # 404
```

**Expected.** An error raised before the first event is answered with the status §5.4 maps it to and the §11.6 error
body, as the unary path answers it. An error after events have been sent remains the open question of A2A#1262.

**Question for the maintainers.** Would a change that pulls the first item of the sequence before writing the SSE headers,
and answers a first-item error with `writeRESTError`, be accepted, or is the current shape intended until #1262 is settled?
