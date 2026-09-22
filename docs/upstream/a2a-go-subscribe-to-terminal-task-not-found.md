# Draft comment — a2a-go: SubscribeToTask on a terminal task answers TaskNotFound, counted on a cluster (for a2aproject/a2a-go#438)

Status: **draft, not posted.** Text for a human to review and post as a comment on
https://github.com/a2aproject/a2a-go/issues/438 ("SendMessage and SubscribeToTask on a terminal task return
InvalidParams/TaskNotFound instead of UnsupportedOperationError", open, read 2026-09-21T21:27:38Z). That issue already
reports this behaviour with an in-process reproduction, so this is a corroborating comment, not a new issue. No link
until it is posted.

## Comment text to post

Everything between the two rules below is the comment, written to be pasted as it stands.

---

A second reproduction of the `SubscribeToTask` half of this issue, over the network on a Kubernetes cluster rather than
in process, in case a count helps.

**Setup.** a2a-go **v2.5.0** as the server: `a2asrv.NewHandler(executor)` behind `a2asrv.NewJSONRPCHandler`, card
`capabilities.streaming: true`, the default in-memory task store, one replica. The executor emits a submitted Task,
working, one artifact, completed. The client is a2a-go v2.5.0 too. Each repetition runs two separate processes:

1. `client.SendStreamingMessage(...)`. The stream carried the four events and ended cleanly after
   `TASK_STATE_COMPLETED`.
2. After the first process has exited, a new process sends one `client.SubscribeToTask(ctx,
   &a2a.SubscribeToTaskRequest{ID: <that task id>})`. Every request carries `A2A-Version: 1.0`, and nothing is retried.

**What the server answered, 20 repetitions out of 20:** HTTP 200, `Content-Type: text/event-stream`, carrying a
JSON-RPC response with this error object:

```
"code": -32001, "message": "task not found: no active execution"
```

The client's iteration yielded that error, with that text, and no event. Two things here are read from source, not
checked by this run:

- The error arrives as the stream's only event. `a2asrv/jsonrpc.go` l.235–238 writes one error event and returns.
  Consistent with that, the server's own record (the lab's execution ledger) shows no Task or update handed to the
  subscription's stream.
- The client maps `-32001` to `a2a.ErrTaskNotFound`: `internal/jsonrpc/jsonrpc.go` l.75, wrapped by
  `FromJSONRPCError`, l.89–103.

Each subscription was the first one sent for its task. It arrived 19.2–24.5 s after the executor emitted
`TASK_STATE_COMPLETED`. That the task was still in the store is not checked: the first stream had just completed it,
but no `GetTask` was sent. The answer did not vary across the 20.

**Where it comes from, as read at the tag** (`9d95b954`): `internal/taskexec/local_manager.go` `Resubscribe` returns
`"no active execution"` when `m.executions[taskID]` is absent (l.134–140). `cleanupExecution` deletes that entry as
soon as the execution ends (l.259–266). `a2asrv/handler.go` `SubscribeToTask` then wraps any `Resubscribe` error in
`a2a.ErrTaskNotFound` (l.371–374). So once a task has finished, a subscription to it reads as "not found" whatever the
store holds.

The specification at v1.0.1 (`3303592`) §3.1.6 lists `UnsupportedOperationError` for "The operation is attempted on a
task that is in a terminal state", and `TaskNotFoundError` for "The task ID does not exist or is not accessible". §9.4.6
repeats the former, and §5.4 maps it to `-32004`. The fix proposed above (load the task when `Resubscribe` fails, and
return `ErrUnsupportedOperation` if it exists and is terminal) would give `-32004` here.

---

## Lab notes (not part of the comment)

- The count is `findings.md`, "Experiment B / both receivers / D3, `SubscribeToTask` on a terminal task" (2026-09-21),
  with every line in `experiments/runs/2026-09-21-b3-streaming-client/subscribe-terminal/`.
- The server is the lab's worker, behind the lab's own ledgers. The client is the lab's load client, `fixtures/loadgen`,
  in `MODE=subscribe`. Its end line records the status, content type and JSON-RPC error read from the bytes the SDK
  read.
- The path from the client to the worker crossed an agentgateway v1.5.0 proxy (`agw-central`, route `lab/worker`)
  under Istio 1.31.0 ambient. The proxy logged the answer as a 200, so the answer is the SDK's, not the proxy's.
- The in-process test in the load client's suite (`TestModes_AgainstTheA2AGoServer`) gets the same code from a2a-go's
  own server with no proxy.
- The sources and their fetch stamps are in `experiments/runs/2026-09-21-b3-streaming-client/sources.txt`, and the
  tracker search that found #438 is in `tracker-search.txt` there.
- The `SendMessage` half of #438 was not exercised by this row.

## Refresh, 2026-09-22 (B-6) — nothing changed; the draft stands as written

Re-read from the API by number, not from a search page, at 2026-09-22T23:25:14Z:

- **a2aproject/a2a-go#438** is still **open**, `created_at` and `updated_at` both `2026-09-15T15:46:08Z`, **0
  comments**. Nothing has happened on it since this draft was written, so the comment text above needs no change.
- The tracker was searched again, this time **issues AND pull requests, any state** — B-3's search for this row
  covered both, but the lesson of B-5a is that a page labelled one way and run the other is how a search concludes
  "nothing" and is wrong, so it was re-run and recorded with the page and the API's own `total_count` beside it
  (`experiments/runs/2026-09-23-b6-traces-and-table/tracker-search.txt`, block 3). **No pull request touches this
  path**: the five queries return #438 itself, its sibling #439, and items about other parts of the task
  lifecycle. `UnsupportedOperationError` returns exactly one item across the whole repository, #438.
- **#439** ("SubscribeToTask on an INPUT_REQUIRED task returns TASK_NOT_FOUND because localManager tears down the
  execution/broker on INPUT_REQUIRED") is also still open with 0 comments, read at the same time. It is the same
  `Resubscribe`-has-no-execution root cause on a *non-terminal* task, and it is not this draft's case; it is named
  here so that a human filing this comment can see the pair.
- Nothing in this refresh moves a number in the comment text.
