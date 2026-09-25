# Experiment B after D-1, D-6: the table, with the rollout variant and the Python client as the reconnecting client

Written 2026-09-25. This step ran nothing. It carries B-6's table (experiments/runs/2026-09-23-b6-traces-and-table/
table.md and the compact table in B-6's entry, dated records, not edited) forward with D-1's two B rows. Every cell
cites its entry. B-6's cells are carried as B-6 derived them, with B-6's [entry] cells still marked as quoted: four in B-6's count, per receiver, and three in the compact
table carried here, whose clean-stream row carries both receivers.
D-1's cells are the D-1 entries' own figures; where an entry gives one range over both receivers, the cell gives that
range and says so, and no per-receiver range is computed here. A cell no entry supports is EMPTY and says so.

## The entries the cells come from

| Key | findings.md heading (abridged after the dash) | Date, run directory |
|---|---|---|
| B-6 | Experiment B / both receivers / B-6, the table — what B found, and what each trace shows of it | 2026-09-23, 2026-09-23-b6-traces-and-table |
| B-3 | Experiment B / both receivers / B-3, a clean stream; B-3, SubscribeToTask during a running task; D3, SubscribeToTask on a terminal task (three entries) | 2026-09-21, 2026-09-21-b3-streaming-client |
| B-4 | Experiment B / both receivers / B-4, the control with no proxy event — (abridged) | 2026-09-22, 2026-09-22-b4-control |
| B-5a | Experiment B / both proxies / B-5a, the removal measured — (abridged) | 2026-09-22, 2026-09-22-b5a-removal |
| B-5b | Experiment B / both receivers / B-5b, the agentgateway ingress removed under an open stream; B-5b, agw-central removed under an open stream (two entries) | 2026-09-22, 2026-09-22-b5b-removal-resubscribe |
| D-1r | Experiment B / both receivers / D-1, B-5b's rollout variant — with the agentgateway ingress replaced by a rollout under an open stream, does ONE SubscribeToTask reattach to the still-running Task, and does the Task still complete with one model call? | 2026-09-24, 2026-09-24-d1-current-topology |
| D-1p | Experiment B / go receiver / D-1, the Python client as the reconnecting client — with agw-central removed gracefully under the orchestrator's forward, does its ONE SubscribeToTask reach the worker's Task, and what does it get? | 2026-09-24, 2026-09-24-d1-current-topology |
| D-5c | Records / the tracker searches of B-3, B-5a, B-6 and C-9 — do they hold when re-run as word searches? | 2026-09-25, 2026-09-25-d5c-search-correction |

## The configuration

Every row ran on the topology of 2026-09-19 at the pins k8s v1.37.0, Istio 1.31.0, agentgateway v1.5.0, Gateway API
v1.6.2 experimental, a2a-spec 3303592, a2a-go v2.5.0, a2a-python 1.1.4, the JSON-RPC binding, the agent Services
unmarked, every lab workload on the one default ServiceAccount. D-1's rows ran on D-1's rebuild, before D-2's bindings
and D-4's accounts (D-1r's Method: "one default ServiceAccount, no A2A marking"). No B row has been run under three
accounts; the B entries remain the records of the single-identity setup (D-4b's words for the entries before it).
Every retry is off, the mock armed with a 45 000 ms delay, the removal or cancel 2 000 ms (5 000 ms for B-4) after the
client's WORKING event.

## 1. The table

Ex/Tk is executes and tasks created. "+0/0/0" is what the one SubscribeToTask added in executes, tasks and invocations.
The first seven rows are B-6's compact table as B-6's entry prints it, its code quoting and bold dropped; the last two
are D-1's.

| Row | Receiver | n | What ended the stream, and when | The two ledgers at that moment | Ex/Tk | Task survived — final state | Model invocations | The one SubscribeToTask | Source |
|---|---|---:|---|---|---|---|---|---|---|
| B-3 a clean stream | go, py | 20, 20 | the server, with the task: eof, 4 events, terminal event seen 20 of 20 on each | complete / complete | 1/1 | n/a — nothing threatened it; TASK_STATE_COMPLETED 20 of 20 | 1 [entry: ok] | none sent in this row | B-6 (from B-3) |
| B-3 SubscribeToTask during a running task | go, py | 20, 20 | the server, with the task | complete / complete | 1/1 | n/a; TASK_STATE_COMPLETED 20 of 20 | 1, ok, 45 000.2–45 009.6 ms | reattached to Job 1's task 40 of 40, arriving 16 261.0–18 738.4 ms after WORKING and 26 264.8–28 748.0 ms before the terminal state; first event task/TASK_STATE_WORKING; +0/0/0 | B-6 (from B-3) |
| D3 SubscribeToTask on a terminal task | go | 20 | the server, before the subscription was sent (terminal_before_arrival 20 of 20) | complete / complete | 1/1 | n/a — already completed 20 of 20 | 1 [entry: ok] | refused. Wire -32001 "task not found: no active execution", http 200 text/event-stream; subscription ledgers complete / error; no first event; the client read the error and ended error; +0/0/0 | B-6 (from B-3) |
| D3 SubscribeToTask on a terminal task | py | 20 | as above | complete / complete | 1/1 | n/a — already completed 20 of 20 | 1 [entry: ok] | refused. Wire -32602 "Task <id> is in terminal state: 3", http 200 application/json; subscription ledgers none / error; no first event; the client read no event and no error and ended eof; +0/0/0 | B-6 (from B-3) |
| B-4 the control, no proxy event | go, py | 20, 20 | the client itself, SSE stream error: context canceled, at k = 5000 ms: 5000.1–5003.3 ms after the send and 4997.7–5002.9 ms after the executor's WORKING line, cancel_while_working 40 of 40; 2 events, 0 after the cancel, terminal event seen 0 of 40 | client-gone / consumer-gone, 0.7–4.6 ms after the cancel | 1/1 | yes — TASK_STATE_COMPLETED 40 of 40 | 1, ok, 45 000.2–45 003.7 (go) and 45 000.3–45 002.9 ms (py) | reattached 40 of 40, arriving 5338.6–5630.1 ms after WORKING and 39 373.6–39 670.9 ms before the terminal state; first event task/TASK_STATE_WORKING; +0/0/0 | B-6 (from B-4) |
| B-5b agentgateway-ingress removed, FORCED | go, py | 20, 20 | the removed proxy, abruptly: SSE stream error: unexpected EOF, 38.3–55.6 (go) and 36.3–64.4 ms (py) after the removal command; 2 events, terminal event seen 0 of 40; Job 1 Failed exit 3 | client-gone / consumer-gone, −0.6 to +2.5 ms from the client's own end stamp | 1/1 | yes — TASK_STATE_COMPLETED 40 of 40 | 1, ok, 45 000.5–45 005.1 ms | reattached 40 of 40, arriving 1938.8–2852.3 ms after the removal and 40 045.3–40 931.1 ms before the terminal state; first event task/TASK_STATE_WORKING; +0/0/0; Job 2 Complete exit 0 | B-6 (from B-5b) |
| B-5b agw-central removed, GRACEFUL | go, py | 20, 20 | nothing — the stream never broke. It carried the task's own terminal event and ended eof with no error, 10 053.4–10 067.6 (go) and 10 046.1–15 070.1 ms (py) after the removal command; the two Python repetitions at 15 065.3 and 15 070.1 ms are the span-processor case, and over the other eighteen 10 046.1–10 085.1 ms; 3 events, terminal event seen 40 of 40; Job 1 Complete exit 0 | complete / complete, −4.1 to +1.6 ms from the client's own end stamp | 1/1 | no — the removal took the model leg. TASK_STATE_FAILED 40 of 40, the executor's own text model call: Post "http://model.lab.internal:8080/v1/chat/completions": EOF (go, 20 of 20) and Connection error. (py, 20 of 20) | 1, client-gone, 12 159.9–12 199.0 (go) and 12 119.4–17 201.3 ms (py) | reattached 40 of 40, arriving 2052.8–2803.9 (py) and 2074.4–2413.2 ms (go) after the removal and 7488.5–13 014.9 (py) and 7649.9–7980.0 ms (go) before the terminal state; first event task/TASK_STATE_WORKING, then status-update/TASK_STATE_FAILED; +0/0/0; Job 2 Complete exit 0 | B-6 (from B-5b) |
| D-1 agentgateway-ingress replaced by a ROLLOUT | go, py | 20, 20 | the old pod's drain: "SSE stream error: unexpected EOF", 21 389.2–22 376.0 ms after the command (both receivers); 2 events, SUBMITTED then WORKING, terminal event seen 0 of 40; HTTP 200, Job 1 Failed exit 3 | client-gone / consumer-gone, within 1.4 ms before and 5.4 ms after the client's own end stamp; the result line carries "queue read failed: context canceled" at go 20 of 20 and no error key at py 20 of 20 | 1/1 | yes, COMPLETED 40 of 40, through SUBMITTED, WORKING, COMPLETED | 1, ok, 45 000.2–45 009.6 ms (both receivers); no stale-closed line | reattached 40 of 40, applied while Job 1's stream was still open 40 of 40, arriving 1844.9–3022.6 ms after the command and 19.3–19.6 s before Job 1's stream ended, answered by the successor 40 of 40; the Task's terminal state 39 775.0–40 934.2 ms after its arrival; first event task WORKING with Job 1's task id, then artifact-update and status-update COMPLETED, eof; +0/0/0; Job 2 Complete exit 0 | D-1r |
| D-1 agw-central removed, GRACEFUL, the Python client (the orchestrator's forward) reconnecting | go (the client is a2a-python) | 20 | the removed proxy's drain, which ended both legs: A2AClientError "Network communication error: peer closed connection without sending complete message body (incomplete chunked read)", 15 048.8–15 068.3 ms after the command; 2 events, SUBMITTED then WORKING, no terminal event | the worker's records and the client's disagree: in 9 of 20 the execution ledger has a delivered line for status-update FAILED on the forward's stream, and in 7 of 20 the ingress ledger ends that stream complete rather than client-gone; the client read 2 events in 20 of 20 | 1/1 | no, the removal took the model leg: FAILED 20 of 20, "model call: Post ...: EOF"; its terminal state between 2.5 ms before and 0.3 ms after the client's stream end, across two pods' clocks | 1, client-gone, 17 167.5–17 227.9 ms; no stale-closed line | sent 20 of 20 and never a second, 0.1–0.6 ms after the stream's end line, from the successor 5.0–11.2 ms after the stream ended; arrived 5.2–13.2 ms AFTER the Task reached FAILED, so running at 0 of 20; a2a-go answered "task not found: no active execution", 0 events, the client raised TaskNotFoundError; the orchestrator's Task FAILED and the load client read FAILED | D-1p |

Cell counts, 9 rows by the seven content columns (n and the six after it), 63 cells: **measured 60, quoted from an
entry 3, empty 0.** The 3 quoted cells are B-6's [entry] cells: the model-invocation outcome of the clean-stream row
and of D3's two rows. No cell is read from source.

## 2. The removal measured

B-6's table of B-5a as B-6's entry prints it, its code quoting and bold dropped (Go receiver only, no
resubscription, five repetitions each), with D-1's two removals added. Clocks
as each entry names them.

| Removal | Stream ends after the command | What the client read | Ledgers | Final state | Model | "hbone error: drain timeout" | SIGTERM to the pod's last log line | The cut request's own access line | Source |
|---|---|---|---|---|---|---|---|---|---|
| ingress, graceful | 20 042.8–20 053.2 ms | error, SSE stream error: unexpected EOF | client-gone / consumer-gone | COMPLETED 5 of 5 | 1 ok | 0 of 5 | 20 003.0–20 005.6 ms | none, 0 of 5 | B-6 (from B-5a) |
| ingress, forced | 35.6–43.3 ms | same | client-gone / consumer-gone | COMPLETED 5 of 5 | 1 ok | 0 of 5 | 0.0 ms | POST http.status=200, 5 of 5 | B-6 (from B-5a) |
| ingress, rollout | 21 643.7–27 268.5 ms | same | client-gone / consumer-gone | COMPLETED 5 of 5 | 1 ok | 0 of 5 | 20 003.9–25 002.7 ms (the maximum is the one counted repetition where the span processor's shutdown ran first; the other four 20 003.9–20 008.4 ms) | 2 of 5 | B-6 (from B-5a) |
| agw-central, graceful | 10 046.5–10 065.5 ms | eof, no error at all | complete / complete | FAILED 5 of 5 | 1 client-gone | 5 of 5 | 10 003.1–10 006.8 ms | POST with no http.status field, 5 of 5 | B-6 (from B-5a) |
| agw-central, forced | 2055.1–2078.8 ms | eof, no error at all | complete / complete | FAILED 5 of 5 | 1 client-gone | 0 of 5 | 0.4–0.5 ms | none at all, 5 of 5 | B-6 (from B-5a) |
| agw-central, rollout | 11 467.2–12 309.2 ms | eof, no error at all | complete / complete | FAILED 5 of 5 | 1 client-gone | 5 of 5 | 10 001.8–10 003.6 ms | POST with no http.status field, 5 of 5 | B-6 (from B-5a) |
| ingress, rollout, with one resubscription, both receivers (40) | 21 389.2–22 376.0 ms | error, "SSE stream error: unexpected EOF" | client-gone / consumer-gone | COMPLETED 40 of 40 | 1 ok | 0 of 40 | 20 002.3–20 016.1 ms; SIGTERM 1384.6–2368.7 ms after the command, the drain 0.3–0.6 ms after SIGTERM, the minimum drain done 10 000.5–10 010.8 ms after that; the last line "binds drained" in 39, a request line in 1 | go: none in 19 of 20, one line reading 200 in 1; py: none at all in 20 of 20 | D-1r |
| agw-central, graceful, under the orchestrator's forward, the Python client (20) | 15 048.8–15 068.3 ms | error, A2AClientError "... incomplete chunked read" | the worker's: see the table above (9 of 20 delivered FAILED; 7 of 20 complete) | FAILED 20 of 20 | 1 client-gone | 3 per repetition, 20 of 20 | EMPTY: D-1p gives no figure from SIGTERM to the last line. It gives SIGTERM 44.2–54.9 ms after the command, "BatchSpanProcessor.Shutdown.Timeout" between SIGTERM and the drain in 20 of 20, the drain 5000.4–5010.5 ms after SIGTERM, the minimum drain done 10 000.7–10 006.1 ms after the drain's start, and the last line "binds drained" | EMPTY: D-1p does not report it | D-1p |

Cell counts, 8 rows by the eight content columns (stream end to the cut request's line), 64 cells: **measured 62,
empty 2.** The 2 empty cells are D-1p's last two, each saying what the entry does give.

## 3. Contradictions between entries

**Found and recorded, not resolved: one, reported to the controller.**

- B-6 writes: "No row anywhere has agw-central carrying an A2A stream", and "what a removal of that proxy does to an
  open A2A stream is a question this topology cannot put. That is a limit of what Experiment B can answer here". B-6
  derives it from the load client's paths, the load client being the streaming client in every B row by the author's
  note of 2026-09-20. D-1p, on the same topology, has the orchestrator's forward, a SendStreamingMessage to the
  worker's Service, cross agw-central, and removes agw-central under it: "The forward crosses agw-central, which also
  carries the worker's model call, so removing it cuts both legs"; "At the worker the stream had arrived from the
  removed pod in 20 of 20". B-6's sentence and D-1p's row are set side by side here and not reconciled.

**Checked, consistent:**

- D-1p: the span processor's shutdown timeout "B-5b saw ... in 2 of 40 and B-5a in 2 of 32"; B-5a's entry: "In 2 of 32
  removals, of which exactly one is among the 30 counted"; B-6's B-5a table marks the one counted repetition. The same
  two readings.
- D-1r: "B-5b's forced delete wrote a 200 line for the cut POST in 40 of 40"; B-6: "http.status=200 in 40 of 40 of
  B-5b's ingress repetitions".
- D-1p's a2a-go answer to a SubscribeToTask on a FAILED Task, "task not found: no active execution", and B-3's D3 row's
  answer for a COMPLETED one: the same text at a2a-go v2.5.0. D-5c records that a2a-go#442, in v2.6.0 and not pinned,
  changes that answer for a terminal task; both rows are readings of v2.5.0.
- D-1r's rollout timings and B-5a's rollout row differ (21 389.2–22 376.0 against 21 643.7–27 268.5 ms): different runs,
  receivers and repetition counts, each entry's own.
