# Draft comment — a2a-python: SubscribeToTask on a terminal task answers InvalidParams, counted on a cluster (for a2aproject/a2a-python#1205)

Status: **draft, not posted.** Text for a human to review and post as a comment on
https://github.com/a2aproject/a2a-python/issues/1205 ("Wrong error when sending a message for a terminal task", open,
read 2026-09-21T21:28:03Z).

That issue is about `SendMessage`. A comment on it (2026-08-30, author association COLLABORATOR) names the same bug
class on `SubscribeToTask` and asks that both be fixed together. The same text is a CHANGES_REQUESTED review on the
open PR #1207 (Fixes #1205), submitted 2026-08-30T21:31:27Z (read 2026-09-22T00:20:21Z). #1207 itself, as read on
2026-09-21, changes only the send paths, not `on_subscribe_to_task` or `ActiveTask.start`/`subscribe`. A
collaborator has therefore already asked for the `SubscribeToTask` fix. This is a comment
carrying a count and three details that neither thread states, not a new issue. No link until it is posted.

## Comment text to post

Everything between the two rules below is the comment, written to be pasted as it stands.

---

A count of the `SubscribeToTask` case named in the 2026-08-30 comment, which is also the changes-requested review on
#1207. It was taken over the network on a Kubernetes cluster, and three details below may help whoever fixes that
path: the framing of the answer, a second text that depends on timing, and the state printed as a number.

**Setup.** a2a-sdk **1.1.4** as the server: `DefaultRequestHandler` (V2) with the in-memory task store, served over
JSON-RPC by uvicorn, card `capabilities.streaming: true`, one replica. The executor enqueues a submitted Task, working,
one artifact, completed. Each repetition runs two separate client processes (a2a-go v2.5.0):

1. One `SendStreamingMessage`. It ended cleanly after `TASK_STATE_COMPLETED`.
2. After that process has exited, a new process sends one `SubscribeToTask` with `{"id": "<that task id>"}` and
   `A2A-Version: 1.0`. Nothing is retried.

**What the server answered, 20 repetitions out of 20:** HTTP 200, `Content-Type: application/json` (not an event
stream), a JSON-RPC response whose error object reads:

```
"code": -32602, "message": "Task <task id> is in terminal state: 3"
```

The text did not vary across the 20, apart from the task id. Each subscription was the first one sent for its task,
and it arrived 19.4–22.7 s after the executor emitted completed.

**As read at tag v1.1.4** (`2d4d3048`):

- **The code.** `on_subscribe_to_task` calls `get_or_create(task_id, create_task_if_missing=False)`
  (`default_request_handler_v2.py` l.431–445). The finished ActiveTask has already been removed, so a new one is
  built. Its `start()` raises `InvalidParamsError(f'Task {task.id} is in terminal state: {task.status.state}')`
  (`active_task.py` l.466–474). That is `-32602`, where the specification (v1.0.1 §3.1.6 and §9.4.6) requires
  `UnsupportedOperationError`, `-32004` (§5.4).
- **The message.** The state is formatted as its enum number (`3`), not its name (`TASK_STATE_COMPLETED`).
- **The other text.** When the finished ActiveTask is still registered, `subscribe()` raises a different
  `InvalidParamsError`: `Task <id> is already completed.` (l.624–628). We saw that text in a local test when the
  subscription came while the original stream's tap was still open. With a new process some seconds later it did not
  appear. So the same request gets one of two texts depending on timing, both `-32602`.
- **The framing.** Because the dispatcher fetches the first event eagerly (`jsonrpc_dispatcher.py` l.376–380), the
  error is raised before any event. It is caught at l.337–338 (`except A2AError`) and answered by
  `_generate_error_response` as a plain `JSONResponse` (l.201–204), not as an event on an SSE stream. The
  specification does not say how an error answer to a streaming method is framed, so this is not a
  conformance point. It does matter to clients that read the body only as SSE. a2a-go v2.5.0's client skips every line
  that does not begin `data:`, so it reads this answer as an empty stream with no error.

---

## Lab notes (not part of the comment)

- The count is `findings.md`, "Experiment B / both receivers / D3, `SubscribeToTask` on a terminal task" (2026-09-21),
  with every line in `experiments/runs/2026-09-21-b3-streaming-client/subscribe-terminal/`.
- The server is the lab's orchestrator in model mode, behind the lab's own ledgers. Its execution ledger's result line
  for each subscription carries the same text, and its ingress ledger's response line has no `stream_end`, because
  the answer was not a stream.
- The path to it crossed the agentgateway v1.5.0 ingress (route `lab/orchestrator-ingress`) under Istio 1.31.0
  ambient.
- The client is the lab's load client, `fixtures/loadgen`, `MODE=subscribe`. The code and text above come from its
  record of the bytes it read. The a2a-go SDK itself reported no event and no error for these 20 — the last point of
  the comment.
- The "already completed" text and its timing are B-1's local measurement (the lab's orchestrator tests, 2026-09-20),
  not this cluster run.
- Sources and fetch stamps: `experiments/runs/2026-09-21-b3-streaming-client/sources.txt`. The tracker search is in
  `tracker-search.txt` there.

## Refresh, 2026-09-22 (B-6) — nothing changed; the draft stands as written

Re-read from the API by number at 2026-09-22T23:25:15Z–23:27Z:

- **a2aproject/a2a-python#1205** is still **open**, 3 comments, `updated_at` `2026-09-13T22:35:31Z` — the
  stale-bot notice this draft already accounts for. No new comment since.
- **#1207** ("fix: Use correct errors when rejecting messages to terminal tasks", Fixes #1205) is still **open and
  NOT merged** (`merged=false`, `merged_at=null`), `updated_at` `2026-08-30T21:34:15Z`, **1 commit**, head
  `46a3d524`, `mergeable_state=behind`. Its five changed files are re-read in this task —
  `default_request_handler.py`, `default_request_handler_v2.py` and three test files — and **its diff still
  contains no `subscribe` line at all**, so the `SubscribeToTask` case remains unfixed by it, exactly as this draft
  says. Read from the pull-request API by number, because a search page's "closed"/"open" says nothing about
  whether a pull request was merged.
- The tracker was searched again, **issues AND pull requests, any state**, seven queries with the page and the
  API's `total_count` beside each (`experiments/runs/2026-09-23-b6-traces-and-table/tracker-search.txt`, block 2).
  It surfaced one pair this draft did not name and which is **not** this bug: **#1175** (open) and its open,
  unmerged **#1191** — `cancel()` and a producer failure write a terminal state to the store but not to active
  subscriber streams. That is about a *live* subscriber missing a terminal event, not about the error code
  returned to a *new* subscription on an already-terminal task. Named here so a human can see it is separate.
- **The last point of the comment text now has a draft of its own.** "a2a-go v2.5.0's client skips every line that
  does not begin `data:`, so it reads this answer as an empty stream with no error" is the subject of
  `docs/upstream/a2a-go-client-reads-a-json-answer-to-a-streaming-method-as-an-empty-stream.md`, written in B-6 on
  the author's decision of 2026-09-22 and filed against the a2a-go **client**, not against this project's framing:
  the specification says how a streaming method's successful answer is framed and not how its error answer is.
  If both are posted, the a2a-go issue may be worth linking from this comment; that is the poster's call.
- Nothing in this refresh moves a number in the comment text.

## 2026-09-25, a dated note from D-5c (the text above is unchanged): NEEDS THE AUTHOR'S ATTENTION

For the author, not part of the comment.

- **The first searches were phrase-only.** B-3's search and B-6's refresh sent every multi-word query to gh search as
  one argument, which gh 2.101.0 sends as a quoted phrase (experiments/runs/2026-09-25-d5c-search-correction/gh-phrase-check.txt).
- **The word pass.** On 2026-09-25, D-5c re-ran every multi-word query of both records as words, through the search API
  with an explicit q=, issues and pull requests apart, the rate limit read before each call, 0 failed:
  - B-3: 17 queries, 34 calls, 90 items, 85 on no earlier page;
  - B-6: 16 queries, 32 calls, 194 items, 110 new.
  - The records: experiments/runs/2026-09-25-d5c-search-correction/search-words-b3.txt, search-words-b6.txt and new-items.txt.
- **Read by number (items-read.txt, followups-read.txt there):**
  - #1205 is unchanged: open, 3 comments, updated 2026-09-13.
  - #1207 is unchanged: open, not merged, head 46a3d524.
  - **New: #1268**, "fix(server): reject terminal-task operations with UnsupportedOperationError", opened 2026-09-23.
    It is **open and not merged**, with no review, and its only comment is a coverage bot.
    - It changes all three terminal-state raises in active_task.py (start, both branches, and subscribe) from
      InvalidParamsError to UnsupportedOperationError.
    - Its description says this covers subscribe_to_task, and it adds test_on_subscribe_to_task_in_terminal_state.
    - Merged, it would turn the -32602 counted here into -32004.
  - a2a-python v1.1.5 (published 2026-09-21) does not contain it.
  - #215 (merged 2025-06-18, in v1.1.4), the origin of the terminal-state error, changes nothing here.
- **What #1268 changes beyond SubscribeToTask.**
  - It changes default_request_handler.py's _setup_message_execution, the legacy handler's send path, the same way.
  - It re-keys the V2 on_cancel_task remap, so a terminal task still answers TaskNotCancelableError.
  - Its description says it covers send_message as well. It is therefore a second fix for #1205's own subject, and
    it overlaps the open #1207.
  - Its description also states this draft's mechanism: on_subscribe_to_task has no terminal check of its own,
    get_or_create calls ActiveTask.start(), and the error surfaces on the first __anext__.
- **What it leaves standing.** Of the comment's four details (the code, the message, the other text, the framing),
  #1268 changes only the code's number. Three stand:
  - the message: the state is still formatted as a number ({task.status.state});
  - the other text: both texts remain, "is already completed." from subscribe() and "is in terminal state" from
    start(), now both -32004. The timing dependence stands, with the code changed;
  - the framing: no dispatcher file is touched, so the error is still raised before the first event.
- **What needs the author.** The introduction says that #1207 changes only the send paths and that no one has written
  the SubscribeToTask fix. The second half no longer holds. The comment may belong on #1268, which now covers both
  operations and states the mechanism, rather than on #1205. Or it may be cut to the three details that stand. Neither
  a duplicate nor a shipped fix: the draft is kept, for the author to reword or retarget.
