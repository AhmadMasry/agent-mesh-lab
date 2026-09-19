# Draft issue — otelhttp: the server span of a request whose connection the handler hijacked reads `http.response.status_code=200`, status Unset

Status: **draft, not filed.** Low priority by the author's list (to be looked at after the lab is finished, if still
relevant). Text for a human to review and file. No link until it is filed.

Project: open-telemetry/opentelemetry-go-contrib, `instrumentation/net/http/otelhttp`. Version observed: **v0.71.0**
with `go.opentelemetry.io/otel/sdk` v1.46.0, Go 1.27.1. Source read at tag
`instrumentation/net/http/otelhttp/v0.71.0` on 2026-09-19 (16:51:52Z–16:51:53Z); each file fetched from the URL below
is byte-identical to the one in the Go module cache the lab builds from (sha256 compared):

- https://raw.githubusercontent.com/open-telemetry/opentelemetry-go-contrib/instrumentation/net/http/otelhttp/v0.71.0/instrumentation/net/http/otelhttp/internal/request/resp_writer_wrapper.go
  (sha256 `04980168c15c68ba76d77550cd80a66584739d6e9039590f38f8cfe5c68df1ad`)
- https://raw.githubusercontent.com/open-telemetry/opentelemetry-go-contrib/instrumentation/net/http/otelhttp/v0.71.0/instrumentation/net/http/otelhttp/handler.go
  (sha256 `c676d2bdc2d800c8e4904b9509e84db8e13ccf200f072c3bdd40d68fdc606607`)
- https://raw.githubusercontent.com/open-telemetry/opentelemetry-go-contrib/instrumentation/net/http/otelhttp/v0.71.0/instrumentation/net/http/otelhttp/internal/semconv/server.go
  (sha256 `ae774d8376b20615b9c5fbdc2bfcdd1850dea0cef66a6815863e247f49e3ceab`)

Also read on `main` at commit `c80ebac6c21e956131450d593108062d03547e2f` (2026-09-19T16:52:07Z): the wrapper file has
the same sha256 as at the tag, and `handler.go` still passes `httpsnoop.Wrap` the same four hooks. The repository's
issues were searched the same minute for `hijack`, `Hijacker 200`, `hijacked connection span`, `hijack status code`,
`websocket status` and `ErrAbortHandler`: nothing about the recorded status was found (#5402, #5796 and #6562 are about
otelmux *exposing* `http.Hijacker`, which otelhttp already does).

## Summary

A handler behind `otelhttp.NewHandler` takes its connection with `http.Hijacker` and closes it. No status line, no
header and no body byte is ever sent; the client sees `EOF`. The server span for that request ends with
`http.response.status_code=200` and status Unset, so in a trace it cannot be told from a request that was answered
`200 OK`.

The 200 is accurate for a handler that returns without writing and without hijacking: net/http then sends `200 OK`
itself. It is only once the connection has been hijacked that no response follows, and the instrumentation has no way
to know that happened.

## What was observed

On a kind cluster, 2026-09-19: a test model endpoint (Go, `net/http`, wrapped with `otelhttp.NewHandler`) closes the
connection on command instead of answering. The proxy in front of it answered its caller `503`; the endpoint's own
span for the same request, in the same trace, read `200` with status Unset
(`experiments/runs/2026-09-19-failed-model-call/a3-baseline-go/*/spans.csv`, the `mockllm` row).

The same reading in a unit test, no cluster, 2026-09-19T16:50:47Z
(`experiments/runs/2026-09-19-mock-span-on-injected-close/before.txt`):

```
name=POST /v1/chat/completions
kind=server
status.code=Unset
status.description=""
attributes:
  ...
  http.response.status_code=200
  ...
events=0
```

## Cause, as read from the source at the tag

1. `internal/request/resp_writer_wrapper.go` l.36-42 — the wrapper starts at 200:

   ```go
   func NewRespWriterWrapper(w http.ResponseWriter, onWrite func(int64)) *RespWriterWrapper {
   	return &RespWriterWrapper{
   		ResponseWriter: w,
   		OnWrite:        onWrite,
   		statusCode:     http.StatusOK, // default status code in case the Handler doesn't write anything
   	}
   }
   ```

2. `handler.go` l.164-177 — `httpsnoop.Wrap` is given hooks for `Header`, `Write`, `WriteHeader` and `Flush`, and none
   for `Hijack`. httpsnoop keeps `http.Hijacker` available on the wrapped writer, so the handler's `Hijack()` goes
   straight to net/http's writer and the wrapper never learns the connection is gone. `wroteHeader` stays false and
   `statusCode` stays at the default.

3. `handler.go` l.185-201 — after `next.ServeHTTP(w, r)` returns, that default is read back and recorded:

   ```go
   statusCode := rww.StatusCode()
   bytesWritten := rww.BytesWritten()
   span.SetStatus(h.semconv.Status(statusCode))
   bytesRead := bw.BytesRead()
   span.SetAttributes(h.semconv.ResponseTraceAttrs(semconv.ResponseTelemetry{
   	StatusCode: statusCode,
   	...
   ```

   `internal/semconv/server.go` l.70-78: `Status(200)` is `codes.Unset`. l.349-354: `ResponseTraceAttrs` adds
   `http.response.status_code` whenever `StatusCode > 0`.

One detail a change would have to mind, from the same file: `ResponseTraceAttrs` already leaves the attribute out for
a status of 0, but `Status(0)` returns `codes.Error, "Invalid HTTP status code 0"` (l.71-73), so "no status was sent"
cannot be expressed today by passing 0 through both.

## Minimal reproduction

Run on 2026-09-19T16:56:01Z with Go 1.27.1, otelhttp v0.71.0, otel sdk v1.46.0:

```go
package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func main() {
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))

	traced := otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			panic(err)
		}
		_ = conn.Close()
	}), "repro", otelhttp.WithTracerProvider(tp))

	done := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		traced.ServeHTTP(w, r)
		close(done) // the span has ended by the time the traced handler returns
	}))
	defer srv.Close()

	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Get(srv.URL)
	if err == nil {
		fmt.Println("client saw a response, status", resp.StatusCode)
	} else {
		fmt.Println("client saw:", err)
	}
	<-done

	for _, span := range sr.Ended() {
		fmt.Printf("span %q kind=%s status.code=%s status.description=%q\n",
			span.Name(), span.SpanKind(), span.Status().Code, span.Status().Description)
		for _, kv := range span.Attributes() {
			if kv.Key == "http.response.status_code" {
				fmt.Printf("  %s=%s\n", kv.Key, kv.Value.Emit())
			}
		}
	}
}
```

Output (the port replaced):

```
client saw: Get "http://127.0.0.1:PORT": EOF
span "GET" kind=server status.code=Unset status.description=""
  http.response.status_code=200
```

## What is being asked

Whether the span of a hijacked request should carry `http.response.status_code=200`. A `Hijack` hook in the
`httpsnoop.Hooks` passed at `handler.go` l.164 would let the wrapper know the connection was taken before any header
was written, and the status could then be left off that span rather than defaulted. Whether that is wanted, and what
a handler that hijacks and then writes its own status line (a protocol upgrade) should read, is the maintainers' call;
this lab measured the hijack-and-close case only.

## What this lab does meanwhile

Its fixture marks its own server span when it closes a connection on command: status Error with a description naming
the injection, and an attribute of its own. The SDK keeps that Error when the instrumentation sets Unset afterwards
(`sdk/trace/span.go` l.220 at v1.46.0: a later, lower status is ignored). The `200` is still stamped beside it
(`experiments/runs/2026-09-19-mock-span-on-injected-close/after.txt`).
