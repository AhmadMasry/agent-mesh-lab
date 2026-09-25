# Draft issue — a2a-go: the JSON-RPC client reads an `application/json` answer to a streaming method as an empty stream, with no event and no error

Status: **draft, not posted.** Text for a human to review and open as a **new issue** on
https://github.com/a2aproject/a2a-go. No link until it is filed.

Why a new issue and not a comment: both trackers were searched on 2026-09-22, **issues and pull requests, any
state**, fourteen queries on `a2aproject/a2a-go` with the page each returned and the API's own `total_count`
beside it (`experiments/runs/2026-09-23-b6-traces-and-table/tracker-search.txt`), and every candidate was then
read by number from the API (`items-read.txt`). Nothing describes this. The nearest items are named in the text
below, and each is a *different* cause of the same shape of failure, all of them already fixed.

## Issue text to post

Everything between the two rules below is the issue, written to be pasted as it stands.

---

### What happened

On a streaming JSON-RPC method (`message/stream`, `tasks/resubscribe`), the client accepts any HTTP 200 answer and
reads the body only as Server-Sent Events. A server that answers such a method with a JSON-RPC **error object in a
plain `application/json` body** therefore produces **no event and no error at the caller**: the iterator ends
immediately and the caller cannot tell a refusal from a task that emitted nothing.

The same error object on the **unary** path is surfaced as a typed error. Only the streaming path loses it.

### Where it comes from

Read at **v2.5.0** (`9d95b954`) and at **main `522f8562`** — the two are byte-identical in both files, at the same
line numbers:

- `a2aclient/jsonrpc.go` `sendStreamingRequest` (l.141–161) sets `Accept: text/event-stream` (l.146), checks
  `httpResp.StatusCode != http.StatusOK` (l.153) and returns `httpResp.Body` (l.160). **The response's
  `Content-Type` is never read.** `internal/sse.ContentEventStream` exists (`internal/sse/sse.go` l.32) and is used
  by the client only to set `Accept`, and by the server's `SSEWriter.WriteHeaders` to set the header it writes.
- `internal/sse/sse.go` `ParseDataStream` (l.95–136) scans the body line by line and **skips every line that is not
  `data:`-prefixed** (l.120–122, `if !bytes.HasPrefix(lineBytes, prefixBytes) { continue }`). A one-line JSON body
  has no such prefix, so nothing is accumulated; at EOF `flush()` finds an empty buffer and yields nothing
  (the closure at l.103–110, called at l.136). `scanner.Err()` is nil, so no error is yielded either
  (l.132–135).
- `a2aclient/jsonrpc.go` `parseSSEStream` (l.164–185) is where the JSON-RPC `error` object *would* be turned into a
  typed error (l.177, `jsonrpc.FromJSONRPCError`), but it only ever sees payloads `ParseDataStream` hands it, and
  here it is handed none.
- `streamRequestToEvents` (l.213–) therefore returns with no event and no error.

Contrast `sendRequest`, the unary path, in the same file: it decodes the body (l.128–131) and returns
`jsonrpc.FromJSONRPCError(resp.Error)` (l.133–135). The same bytes are a typed error there and silence here.

### Minimal reproduction

```go
// One HTTP server that answers a streaming method the way a JSON body would carry an error.
srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    _, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,` +
        `"error":{"code":-32602,"message":"Task task-1 is in terminal state: 3"}}`))
}))
defer srv.Close()

// Any a2a-go client over the JSON-RPC transport, against that server:
for event, err := range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: "task-1"}) {
    fmt.Println("event:", event, "err:", err)   // never reached
}
fmt.Println("the loop ended with no event and no error")
```

The loop body never runs and the iteration ends cleanly. Expected: the caller learns that the server refused, with
`-32602` and its message, as it would on the unary path.

### Where it was met, and how often

Against **a2a-python 1.1.4** as the server, which answers a `SubscribeToTask` for a task in a terminal state with a
JSON-RPC error in an `application/json` body — because its dispatcher fetches the first event before it opens the
stream, so the error is raised before any event exists. Over a Kubernetes cluster, one request per repetition,
nothing retried: **20 repetitions of 20** read HTTP 200, `application/json`, the error object
`-32602 "Task <id> is in terminal state: 3"` on the wire, and at the a2a-go client **0 events, no error, a clean
end**. The code and the text exist at that client only because the test harness kept the bytes itself.

That is not a claim about a2a-python: the specification at v1.0.1 says how a streaming method's **successful**
answer is framed and does not say how its **error** answer is framed, so a plain JSON body is not a violation. The
point is what the client does with one.

### The nearest existing items, each a different cause of the same shape

- **#162 / #188** — `ParseDataStream` required a space after `data:`, so a non-compliant stream produced, in the
  issue's own words, "silent parsing failures where no data is yielded and no error is reported". Fixed; first
  contained in **v0.3.7**. The shape is the one reported here; the cause is different, and the reader still has no
  way to say "this body was not an event stream at all".
- **#385 / #386** — the JSON-RPC client lost the server's real error because `error.data` would not decode, "masking
  the real error". Fixed; first contained in **v2.5.0**.
- **#318 / #319** — the REST client did not deserialise SSE error events into typed errors. Fixed; first contained in
  **v2.2.1**. #318 says "JSON-RPC does not have this issue because `parseSSEStream` checks `resp.Error != nil`
  ... before attempting event deserialization" — which holds for an error carried *inside* an SSE event, and is
  exactly what does not happen when the body is not an SSE stream.

### Two possible shapes for a fix, not a preference

1. In `sendStreamingRequest`, read the response's `Content-Type`; when it is not `text/event-stream`, decode the
   body as a JSON-RPC response and return `jsonrpc.FromJSONRPCError(resp.Error)` — which is what `sendRequest`
   already does a few lines above.
2. Or, in `streamRequestToEvents`, when the iteration ends having yielded nothing, surface an error rather than a
   clean end, so that "the server said nothing an SSE reader could use" is never silence.

---

## Lab notes (not part of the issue)

- The count is `findings.md`, "Experiment B / both receivers / D3, `SubscribeToTask` on a terminal task"
  (2026-09-21), with every line in `experiments/runs/2026-09-21-b3-streaming-client/subscribe-terminal/`, and it is
  carried into B's results table in "Experiment B / both receivers / B-6, the table".
- The in-process reproduction is already committed and passing:
  `fixtures/loadgen/stream_test.go`, `TestSubscribe_ARefusalInPlainJSONIsRecordedFromTheWire` (a scripted server
  answering `application/json`, asserting `events` 0, `error` empty, `stream_end` `eof`, and the wire code and text
  read by the harness's own observer), beside `TestSubscribe_ARefusalAsAnEventIsRecordedFromTheWire`, which shows
  the same refusal reaching the client when a2a-go's own server frames it as an SSE event. Both were re-run in this
  task and pass.
- The two source files were read from the module the lab links (`github.com/a2aproject/a2a-go/v2@v2.5.0`) and from
  `main` through the repository contents API in this task; the stamps are in
  `experiments/runs/2026-09-23-b6-traces-and-table/sources.txt`.
- The author approved writing this draft on 2026-09-22; B-3 recorded the behaviour and left it undrafted, and its
  search for it was issues-only, which is why it was run again here with pull requests included.
- The client in the cluster count is the lab's load client, `fixtures/loadgen`, in `MODE=subscribe`. The path from
  it to the Python receiver crossed the agentgateway v1.5.0 ingress (route `lab/orchestrator-ingress`) under
  Istio 1.31.0 ambient; the proxy logged the answer as a 200, so the framing is the server's and not the proxy's.

## 2026-09-25, a dated note from D-5c (the text above is unchanged): STANDS

For the author, not part of the issue.

- **The first search was phrase-only.** B-6's search (and B-3's, cited in the lab notes) sent every multi-word query to
  gh search as one argument, which gh 2.101.0 sends as a quoted phrase (experiments/runs/2026-09-25-d5c-search-correction/gh-phrase-check.txt). Its "fourteen
  queries" were phrase matches for the ten multi-word ones.
- **The word pass.** On 2026-09-25, D-5c re-ran them as words, through the search API with an explicit q=, issues and
  pull requests apart, the rate limit read before each call, 0 failed:
  - B-6: 16 queries, 32 calls, 194 items, 110 on no earlier page;
  - B-3: 17 queries, 34 calls, 90 items, 85 new.
  - The records: experiments/runs/2026-09-25-d5c-search-correction/search-words-b6.txt, search-words-b3.txt and new-items.txt.
- **Read by number (items-read.txt there), the nearest new titles:**
  - #76 (closed completed): a client falling back when a server does not stream;
  - #265 (merged, in v2.5.0): the server's JSON-RPC Content-Type;
  - #92 (merged, in v2.5.0): an early streaming fix.
  - None describes the client reading an application/json answer to a streaming method as an empty stream.
- **The release.** a2a-go v2.6.0 was published 2026-09-25T06:22:49Z, and it changes neither a2aclient/jsonrpc.go nor
  internal/sse/sse.go (compare v2.5.0...v2.6.0, followups-read.txt). The line citations above hold at v2.6.0 as well.
- **Standing: stands.** It is not a duplicate, no fix was found, and there is no documented behaviour for it.
