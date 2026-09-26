# Walkthrough B — Experiment B, every row

Experiment B asks what happens to a **streamed** A2A task when the proxy under it is removed or replaced, and what one
`SubscribeToTask` sent afterwards gets. It was measured on the topology the main walkthrough builds, in the order the
author's notes of 2026-09-20, 2026-09-22 and 2026-09-24 in `docs/proposal-notes.md` set: the clean stream and the
model call first (B-3), the control with no proxy event (B-4), the removal itself measured six ways on the Go receiver
(B-5a), the removal under an open stream with one resubscription on both receivers (B-5b), and the two rows D-1 added,
the rollout variant and the Python SDK as the reconnecting client. This document re-takes every one of those rows on the
cluster the main walkthrough leaves standing at step 3, each with its committed driver, at **two repetitions per row**
where the entries ran twenty (five on B-5a), and reads each against the entry that recorded it, by heading. Nothing
here adds a finding.

Everything printed here was taken from the run of 2026-09-26 that also produced the main walkthrough's readings, at
the tree of the commit `docs(proposal-notes): the walkthrough extended to every row of Experiments B and C for the
author's end-to-end test, decided by the author`, on the author's machine; this part ran from 14:27:56Z to 15:13:38Z,
**45 min 42 s**. The record is `experiments/runs/2026-09-26-walkthrough/`, whose `logs/` hold every command's
unabridged output (the B steps are `logs/30-*` to `logs/39c-*`), and whose `b3/`, `b4/`, `b5a/`, `b5b/`, `d1-rollout/`
and `d1-pyclient/` hold each row's outputs. The main walkthrough's rules apply unchanged: the reader's directory is
`experiments/runs/my-walkthrough/`, which no committed record uses, every command runs from the repository root in the
shell the tools block set up, and timings are what this run observed.

**How the output blocks are cut.** Each row's counting tool prints one CSV line per repetition and then a tally of
every column per receiver or variant. The blocks below quote the tally lines for the cells the entry rests on and leave
the per-repetition lines and most timing figures to the record, and each block names the log it comes from. A block
that quotes tally lines whole says nothing more; a block that condenses them starts with a line `# condensed:` naming
what it does, which is one or more of: several cells joined on one line with ` ; `, two variants or receivers set side
by side with ` | ` (each side's value is the tool's for that variant), a timing cell restated as its min and max
(`a .. b`), and a task id that differs between the two repetitions written `<task id>`. Every value in a condensed line
is the tool's; the unabridged output is in the log the block names. The comparison with the entries is `rows-vs-entries.txt` in the record: every
column of every row as the set of values its repetitions took, identifiers masked, each cell classed same, within
(every value here is one the entry took, the entry took more), timing (a duration, not a count) or differs.

## Before you start (B)

The cluster stands at the main walkthrough's step 3 with its six Experiment A rows run, in the shell its tools block
set up, from the repository root. Three things more:

**Tools.** The B drivers use `perl`, `shasum`, `python3`, `uuidgen` and GNU `timeout` (on macOS from Homebrew's
coreutils; `which timeout` must find it). They put `"${TMPDIR:-/tmp}"/<task>/tools/istioctl-1.31.0` first on their own
`PATH` if such a directory exists, so that the istioctl they call is the one of the day they were written; on a reader's
machine that directory does not exist and the tools block's istioctl 1.31.1 stays first. `TMPDIR` must be set to a
writable directory: the drivers expand `"${TMPDIR%/}"` and write their ko build logs under it. macOS sets it; on Linux
`export TMPDIR=/tmp` before you start.

**Two scratch directories the drivers write into without creating them**, and the one driver a reader cannot run as
committed. B-3's `rows.sh` writes into its own dated directory and predates two of the load-client Job template's
placeholders, so every Job it renders stops before it sends (the currency pass of 2026-09-25 met the same and ran a
copy). The reader runs a copy with two lines changed: its run directory, and the two placeholders rendered empty as
every later driver renders them. The `diff` shows exactly those two lines:

```
mkdir -p "${TMPDIR:-/tmp}"/b4 "${TMPDIR:-/tmp}"/d1/work
mkdir -p experiments/runs/my-walkthrough/drivers
sed -e 's#^RUNREL=2026-09-21-b3-streaming-client$#RUNREL=my-walkthrough/b3#' \
    -e 's#-e "s/\\${TASK_ID}/${task}/g" \\$#-e "s/\\${TASK_ID}/${task}/g" -e "s/\\${CANCEL_AFTER_MS}//g" -e "s/\\${CLIENT_HOST}//g" \\#' \
    experiments/runs/2026-09-21-b3-streaming-client/rows.sh > experiments/runs/my-walkthrough/drivers/b3-rows.sh
diff experiments/runs/2026-09-21-b3-streaming-client/rows.sh experiments/runs/my-walkthrough/drivers/b3-rows.sh
```

```
59c59
< RUNREL=2026-09-21-b3-streaming-client
---
> RUNREL=my-walkthrough/b3
177c177
< 		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" \
---
> 		-e "s/\${MODE}/${mode}/g" -e "s/\${TASK_ID}/${task}/g" -e "s/\${CANCEL_AFTER_MS}//g" -e "s/\${CLIENT_HOST}//g" \
```

`diff` exits 1 when the two files differ, which is the expected exit here. Every other B driver takes `RUNREL`, the
name of your directory under `experiments/runs/`, and runs unedited from its record.

**The two proxies' generations, before.** The two rollout variants below (B-5a's and D-1's) roll the proxy
Deployments, which leaves their `generation` and a `restartedAt` annotation behind, as the entries record and no later
row depends on. Read them before B so the change is yours to see afterwards:

```
for g in agentgateway-ingress/agentgateway-ingress agentgateway-waypoint/agw-central; do
  kubectl -n "${g%%/*}" get deploy "${g##*/}" -o jsonpath='{.metadata.namespace}/{.metadata.name} generation={.metadata.generation} restartedAt=[{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}]{"\n"}'
done
```

```
agentgateway-ingress/agentgateway-ingress generation=1 restartedAt=[]
agentgateway-waypoint/agw-central generation=1 restartedAt=[]
```

## B-3, four rows: the model call, the clean stream, and one subscription to a running and to a finished task

Each B-3 row runs both receivers. For the Python receiver the driver takes the orchestrator out of its forwarding role
for the row (it removes `DOWNSTREAM_A2A_URL`, so the orchestrator calls the model itself, and restores it on exit), and
the model-call and subscribe-running rows arm the mock's 45 000 ms delay per repetition and reset it after; the load
client dials what each card advertises (Go: `agw-central` and `lab/worker`; Python: the ingress and
`lab/orchestrator-ingress`). Every row's counts are read against
`## Experiment B / both receivers / B-3, the rebuild and B-2's count` (model-call),
`## Experiment B / both receivers / B-3, a clean stream`,
``## Experiment B / both receivers / B-3, `SubscribeToTask` during a running task`` and
``## Experiment B / both receivers / D3, `SubscribeToTask` on a terminal task``, each of which counted 20 per receiver.

### B-3 model-call — one `SendMessage`, one model call, counted at 45 s

```
RUN_ID=wtb3mc bash experiments/runs/my-walkthrough/drivers/b3-rows.sh model-call 2
python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/my-walkthrough/b3/model-call model-call 45000
```

**288.8 s**, the two rollouts of the orchestrator included. The tally (`logs/31b-b3-model-call-counts.txt`), the same on
both receivers:

```
# condensed: the py tally's twelve lines, equal to the go tally's, are not repeated
## go: 2 repetitions
  arrivals_SendMessage: 1 x2
  received_joined: 1 x2
  executes: 1 x2
  tasks: 1 x2
  invocations: 1 x2
  final_state: TASK_STATE_COMPLETED x2
  a2a_version: 1.0 x2
  invocation_outcomes: ok x2
  invocation_task_matches: yes x2
  client_result: task/TASK_STATE_COMPLETED x2
  job: Complete/exit0 x2
  latency_ms: min 45000.7 max 45004.7 mean 45002.7 over 2
## py: 2 repetitions
  (the same twelve lines)
  latency_ms: min 45001.0 max 45001.3 mean 45001.2 over 2
```

Read against the entry: 1 arrival, 1 received, 1 execute, 1 task, **exactly 1 invocation line, outcome ok**, the Task
completed and the client's answer a completed Task, in 2 of 2 here and 20 of 20 there; the invocation names the Task the
executor created; the model route carried one line per repetition at `agw-central`, status 200. The latency sits 0.7 to
4.7 ms over the armed 45 000 ms here and 0.5 to 6.4 ms there. Set beside the entry, 28 cells the same, 1 within, 7
timing, 0 differing.

### B-3 stream — one `SendStreamingMessage`, nothing disrupted

```
RUN_ID=wtb3st bash experiments/runs/my-walkthrough/drivers/b3-rows.sh stream 2
python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/my-walkthrough/b3/stream stream 45000
```

**135.7 s.** The tally (`logs/32b-b3-stream-counts.txt`), the same on both receivers:

```
  arrivals_SendStreamingMessage: 1 x2
  received_joined: 1 x2
  executes: 1 x2
  tasks: 1 x2
  invocations: 1 x2
  final_state: TASK_STATE_COMPLETED x2
  a2a_version: 1.0 x2
  ingress_stream_end: complete x2
  exec_stream_end: complete x2
  exec_result_state: TASK_STATE_SUBMITTED x2
  client_events: 4 x2
  client_first: task/TASK_STATE_SUBMITTED x2
  client_last_state: TASK_STATE_COMPLETED x2
  client_terminal_seen: True x2
  client_stream_end: eof x2
  client_task_matches: yes x2
  card_streaming: True x2
  job1: Complete/exit0 x2
```

Read against the entry: one arrival joined to one received line on its `messageId`, one execute, one task, one
invocation; both ledgers end the stream `complete`; the client saw 4 events from `task/SUBMITTED` to
`status-update/COMPLETED`, a terminal event, a clean end (`eof`) and the executor's task id; the execution result line's
own `state` is the first Task's, `TASK_STATE_SUBMITTED`, as B-1 recorded. 40 cells the same, 2 within, 2 timing, 0
differing.

### B-3 subscribe-running — one `SubscribeToTask` while the Task runs

```
RUN_ID=wtb3sr bash experiments/runs/my-walkthrough/drivers/b3-rows.sh subscribe-running 2
python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/my-walkthrough/b3/subscribe-running subscribe-running 45000
```

**318.4 s.** Job 1 opens the stream under the 45 s delay; when its first client line names the Task, Job 2, a separate
process, sends ONE `SubscribeToTask` for that id. The tally (`logs/33b-b3-subscribe-running-counts.txt`), the Go
receiver's, the stream's own lines as above and then; the Python receiver's reads the same but for the content type,
`text/event-stream; charset=utf-8`, and its own timing figures:

```
  arrivals_SubscribeToTask: 1 x2
  sub_task_matches: yes x2
  received_sub_joined: 1 x2
  ingress_sub_status: 200 x2
  ingress_sub_stream_end: complete x2
  exec_sub_stream_end: complete x2
  exec_sub_error: <empty> x2
  sub_first_delivered: task/TASK_STATE_WORKING x2
  client2_first: task/TASK_STATE_WORKING x2
  client2_first_task_matches: yes x2
  client2_events: 3 x2
  client2_terminal_seen: True x2
  client2_stream_end: eof x2
  client2_http: 200 text/event-stream x2
  client2_posts: 1 x2
  job2: Complete/exit0 x2
  running_at_arrival: yes x2
  working_to_sub_arrival_ms: min 19066.4 max 19909.8 mean 19488.1 over 2
  sub_arrival_to_terminal_ms: min 25094.4 max 25942.7 mean 25518.6 over 2
```

Read against the entry: +1 arrival (`SubscribeToTask`) joined on the task id, **0 new executes, 0 new tasks,
invocations still 1**; the subscription's first event is a `task` at `TASK_STATE_WORKING` carrying Job 1's task id,
then `artifact-update` and `status-update/COMPLETED`, a terminal event seen, `eof`, HTTP 200 as an event stream, one
POST. It arrived while the Task was running in 4 of 4 here (19.0 to 19.9 s after the working line, 25.1 to 26.0 s
before the completed line) and 40 of 40 there (16.3 to 18.7 s and 26.3 to 28.7 s); the gap is the driver applying
Job 2 with `ko apply`. 80 cells the same, 2 within, 8 timing, 0 differing.

### B-3 subscribe-terminal (the author's row D3) — one `SubscribeToTask` after the Task has finished

```
RUN_ID=wtb3sx bash experiments/runs/my-walkthrough/drivers/b3-rows.sh subscribe-terminal 2
python3 experiments/runs/2026-09-21-b3-streaming-client/counts.py experiments/runs/my-walkthrough/b3/subscribe-terminal subscribe-terminal 45000
```

**232.0 s.** Job 1 runs a clean stream to its end; then Job 2 sends ONE `SubscribeToTask` for the finished task. The
tally (`logs/34b-b3-subscribe-terminal-counts.txt`), the subscription's lines:

```
# condensed: the subscription's cells of both tallies; a task id that differs between the repetitions written <task id>
## go: 2 repetitions
  arrivals_SubscribeToTask: 1 x2
  received_sub_joined: 1 x2
  exec_sub_stream_end: error x2
  exec_sub_error: task in a terminal state "TASK_STATE_COMPLETED": this operation is not supported x2
  sub_first_delivered: none x2
  client2_events: 0 x2
  client2_stream_end: error x2
  client2_http: 200 text/event-stream x2
  client2_wire_error: -32004: task in a terminal state "TASK_STATE_COMPLETED": this operation is not supported x2
  client2_sdk_error: task in a terminal state "TASK_STATE_COMPLETED": this operation is not supported x2
  job2: Failed/exit3 x2
  terminal_before_arrival: yes x2
  prior_resubscriptions: 0 x2
  terminal_to_sub_arrival_ms: min 21572.3 max 23246.6 mean 22409.4 over 2
## py: 2 repetitions
  arrivals_SubscribeToTask: 1 x2
  ingress_sub_stream_end: none x2
  exec_sub_stream_end: error x2
  exec_sub_error: Task <task id> is in terminal state: 3 x1; Task <task id> is in terminal state: 3 x1
  client2_events: 0 x2
  client2_stream_end: eof x2
  client2_http: 200 application/json x2
  client2_wire_error: -32602: Task <task id> is in terminal state: 3 x1; -32602: Task <task id> is in terminal state: 3 x1
  client2_sdk_error: <empty> x2
  job2: Failed/exit3 x2
  terminal_to_sub_arrival_ms: min 23778.3 max 24176.3 mean 23977.3 over 2
```

This row is read against **two** entries, because the Go receiver's answer moved between them. Against
``## Experiment B / both receivers / D3, `SubscribeToTask` on a terminal task`` (2026-09-21, a2a-go v2.5.0) the three Go
error cells differ: that entry read `-32001` "task not found: no active execution" 20 of 20, and this run reads
`-32004` "task in a terminal state" 2 of 2. Against
`## Experiment B / both receivers / the currency pass of 2026-09-25`, which re-counted this row at a2a-go v2.6.0 and
recorded exactly that change (a2a-go#442), every cell reads the same: 80 same, 2 within, 4 timing, 0 differing. What
did not move on either side: the Python receiver answers `-32602` "Task <id> is in terminal state: 3" as
`application/json`, not an event stream, and the a2a-go client reads no event and no error from it (`eof`); the Go
receiver answers as the stream's one event, HTTP 200 `text/event-stream`, and its client reports the error; no new
execute, task or invocation on either; every subscription was the first for its task and arrived 21.6 to 24.2 s after
the terminal state here, 19.2 to 24.5 s there.

## B-4 — the control: the client cancels its only stream, then one subscription

```
RUN_ID=wtb4 RUNREL=my-walkthrough/b4 bash experiments/runs/2026-09-22-b4-control/rows.sh 2
python3 experiments/runs/2026-09-22-b4-control/counts.py experiments/runs/my-walkthrough/b4/control 45000 5000
```

**232.2 s.** No proxy is touched. Job 1 opens a `SendStreamingMessage` under the 45 s delay and cancels its own stream
after 5 000 ms (`CANCEL_AFTER_MS`, the one load-client setting this row turns on); Job 2 sends ONE `SubscribeToTask`.
The Go receiver is reached through the ingress by the `Host` setting the note of 2026-09-22 allows
(`client_dialled_host`), the Python receiver through the ingress from its card. The tally
(`logs/35b-b4-counts.txt`), the same on both receivers:

```
  arrivals_SendStreamingMessage: 1 x2
  received_joined: 1 x2
  executes: 1 x2
  tasks: 1 x2
  ingress_stream_end: client-gone x2
  exec_stream_end: consumer-gone x2
  client_cancel_after_ms: 5000 x2
  client_cancel_fired: True x2
  client_ended_before_cancel: False x2
  client_events_after_cancel: 0 x2
  client_events: 2 x2
  client_first: task/TASK_STATE_SUBMITTED x2
  client_last: status-update/TASK_STATE_WORKING x2
  client_terminal_seen: False x2
  client_stream_end: error x2
  client_error: SSE stream error: context canceled x2
  client_http: 200 x2
  job1: Failed/exit3/pods1 x2
  final_state: TASK_STATE_COMPLETED x2
  invocations: 1 x2
  invocation_outcomes: ok x2
  arrivals_SubscribeToTask: 1 x2
  sub_first_delivered: task/TASK_STATE_WORKING x2
  client2_first: task/TASK_STATE_WORKING x2
  client2_events: 3 x2
  client2_kinds: task/TASK_STATE_WORKING|artifact-update|status-update/TASK_STATE_COMPLETED x2
  client2_terminal_seen: True x2
  client2_stream_end: eof x2
  job2: Complete/exit0/pods1 x2
  senders: SendStreamingMessage<-ingress|SubscribeToTask<-ingress x2
  cancel_while_working: yes x2
  running_at_sub_arrival: yes x2
```

Read against `## Experiment B / both receivers / B-4, the control with no proxy event`: the cancel fires at 5 000 ms
while the Task is working, the client sees 2 events and none after the cancel, ends in `error` with the SDK's
`context canceled` text and a Failed Job (a cancelled stream has no terminal event, which is the client's own exit 3);
the two ledgers record `client-gone` and `consumer-gone`; **the Task still reaches `TASK_STATE_COMPLETED` on exactly
one invocation**, and the one subscription reattaches with `task/TASK_STATE_WORKING` as its first event and reads the
Task to its end. 107 cells the same, 4 within, 29 timing, 0 differing; the four within are the entry's twenty
repetitions taking values (a host-sleep flag, a second POST shape at the ingress) that two repetitions did not.

## B-5a — the removal measured six ways, Go receiver

```
for v in "ingress graceful" "ingress forced" "ingress rollout" "central graceful" "central forced" "central rollout"; do
  RUN_ID=wtb5a RUNREL=my-walkthrough/b5a bash experiments/runs/2026-09-22-b5a-removal/rows.sh $v 2
done
python3 experiments/runs/2026-09-22-b5a-removal/counts.py experiments/runs/my-walkthrough/b5a/removal 45000
```

**683.3 s** for the six (121.5, 150.9, 151.0, 91.0, 74.5 and 94.4 s; this run called `rows.sh` once per variant, in
that order, which the loop above does in one line). Each repetition arms the 45 s delay, opens ONE `SendStreamingMessage`
through the ingress by the `Host` setting, waits 2 000 ms after the client's `WORKING` event, and removes the proxy
once: a graceful delete, a forced delete or a rollout restart, of the ingress or of `agw-central`; a probe follows once
the successor is Ready. The proxy's own log is followed from before the send, so its last lines survive the pod. The
tally (`logs/36g-b5a-counts.txt`), the cells the entry rests on, per variant:

```
# condensed: three variants side by side with " | "; two ledger cells joined with " / "; timing cells as min .. max
## ingress-graceful | ingress-forced | ingress-rollout (2 repetitions each)
  client_events: 2 x2
  client_terminal_seen: False x2
  client_stream_end: error x2
  client_error: SSE stream error: unexpected EOF x2
  job1: Failed/exit3/pods1 x2
  ingress_stream_end / exec_stream_end: client-gone / consumer-gone x2
  final_state: TASK_STATE_COMPLETED x2
  invocations: 1 x2
  invocation_outcomes: ok x2
  probe_final_state: TASK_STATE_COMPLETED x2
  rm_to_client_stream_end_ms_h2c: graceful 20067.2 .. 25064.1 | forced 52.3 .. 62.5 | rollout 21542.4 .. 27192.3
## central-graceful | central-forced | central-rollout (2 repetitions each)
  client_events: 3 x2
  client_terminal_seen: True x2
  client_stream_end: eof x2
  client_error: <none> x2
  job1: Complete/exit0/pods1 x2
  ingress_stream_end / exec_stream_end: complete / complete x2
  final_state: TASK_STATE_FAILED x2
  invocations: 1 x2
  invocation_outcomes: client-gone x2
  drain_timeout_line: graceful yes | forced no | rollout yes
  probe_final_state: TASK_STATE_COMPLETED x2
  rm_to_client_stream_end_ms_h2c: graceful 10057.2 .. 10060.9 | forced 2048.2 .. 2055.0 | rollout 12084.0 .. 12311.3
```

Read against `## Experiment B / both proxies / B-5a, the removal measured`, which ran five of each: the two proxies part
exactly as there. **Removing the ingress cuts the stream and nothing else**: the client reads `unexpected EOF` after 2
events, no terminal event, a Failed Job, the ledgers `client-gone` and `consumer-gone`, and the Task still reaches
`TASK_STATE_COMPLETED` on one invocation. **Removing `agw-central` never cuts the stream; it carries the failure**: 3
events ending `status-update/TASK_STATE_FAILED`, a terminal event seen, `eof` with no error, the Job Complete, and one
invocation with outcome `client-gone`, because that proxy also carries the model leg. The cut's timing per method reads
inside or beside the entry's ranges: ingress graceful 20.07 to 25.06 s here (20.04 to 20.05 s there, one repetition
here 5 s longer, the span processor's shutdown timeout the entry also saw in its rollout variant), ingress forced 52 to
63 ms (36 to 43 ms), ingress rollout 21.5 to 27.2 s (21.6 to 27.3 s); `agw-central` graceful 10.06 s (10.05 to 10.07 s),
forced 2.05 s (2.06 to 2.08 s), rollout 12.1 to 12.3 s (11.5 to 12.3 s); the `hbone error: drain timeout` line is
present on `agw-central`'s graceful and rollout removals here as there, and absent on the ingress's. The probe sent to
the successor completed in 12 of 12.

Set beside the entry, 472 cells the same, 7 within, 184 timing, 9 differing, and the nine are all in what the removed
pod logged in its last moments or what its successor served first, cells whose values varied across the entry's own
five repetitions too. Which lines the dying pod wrote (`old_pod_drain_lines`, compared with the lines sorted because
its listeners drain concurrently and came in five orders in the entry) and how many (`old_pod_log_lines_after_removal`,
{2, 3} there against {1, 2} here on the ingress forced removal, {10} against {10, 11} on the graceful, {10, 14, 15}
against {10, 11} on the rollout); its last line (`old_pod_last_log`, once a request line instead of `binds drained` or
the SIGTERM line); and the successor's first served request (`new_pod_first_served`, once the probe's POST rather than
its card GET on the ingress forced removal, which the entry saw on its graceful one); and one line that differs only by
the byte-copied counting tool's fixed-width cut, this pod's `connection.id` having two digits after the walk's earlier
rows. None of them is a count the entry rests on, and this text does not present the dying pod's line list or its last
line as a fixed reading.

## B-5b — the removal under an open stream, then one `SubscribeToTask`, both receivers

```
for v in "py ingress forced" "py central graceful" "go ingress forced" "go central graceful"; do
  RUN_ID=wtb5b RUNREL=my-walkthrough/b5b bash experiments/runs/2026-09-22-b5b-removal-resubscribe/rows.sh $v 2
done
python3 experiments/runs/2026-09-22-b5b-removal-resubscribe/counts.py experiments/runs/my-walkthrough/b5b/rows 45000
```

**464.6 s** for the four (129.7, 91.6, 153.8 and 89.5 s; this run called `rows.sh` once per variant, in that order,
which the loop above does in one line). Each repetition is B-5a's removal (the ingress by a forced
delete, the abrupt case the question is about; `agw-central` by the graceful delete) and then, when the successor is
first seen Ready, ONE `SubscribeToTask` for Job 1's task id from a second Job. The tally
(`logs/37e-b5b-counts.txt`):

```
# condensed: cells joined with " ; "; the two receivers side by side with " | "; timing cells as min .. max
## go-ingress-forced | py-ingress-forced (2 repetitions each)
  client_events: 2 x2 ; client_terminal_seen: False x2 ; client_stream_end: error x2
  client_error: SSE stream error: unexpected EOF x2 ; job1: Failed/exit3/pods1 x2
  final_state: TASK_STATE_COMPLETED x2 ; states: TASK_STATE_SUBMITTED|TASK_STATE_WORKING|TASK_STATE_COMPLETED x2
  invocations: 1 x2 ; invocation_outcomes: ok x2
  sub_arrival_task_matches_job1: yes x2 ; sub_first_delivered: task/TASK_STATE_WORKING x2
  client2_first: task/TASK_STATE_WORKING x2 ; client2_events: 3 x2 ; client2_terminal_seen: True x2
  client2_stream_end: eof x2 ; job2: Complete/exit0/pods1 x2 ; task_running_at_sub_arrival: yes x2
  exec_result_error: go queue read failed: context canceled x2 | py <no error key> x2
  rm_to_client_stream_end_ms_h2c: go 43.8 .. 46.1 | py 39.4 .. 39.7
## go-central-graceful | py-central-graceful (2 repetitions each)
  client_events: 3 x2 ; client_terminal_seen: True x2 ; client_stream_end: eof x2 ; client_error: <none> x2
  job1: Complete/exit0/pods1 x2
  final_state: TASK_STATE_FAILED x2 ; states: TASK_STATE_SUBMITTED|TASK_STATE_WORKING|TASK_STATE_FAILED x2
  invocations: 1 x2 ; invocation_outcomes: client-gone x2
  final_state_error: go model call: Post "http://model.lab.internal:8080/v1/chat/completions": EOF x2 | py Connection error. x2
  sub_arrival_task_matches_job1: yes x2 ; sub_first_delivered: task/TASK_STATE_WORKING x2
  client2_first: task/TASK_STATE_WORKING x2 ; client2_events: 2 x2 ; client2_terminal_seen: True x2
  client2_stream_end: eof x2 ; job2: Complete/exit0/pods1 x2 ; task_running_at_sub_arrival: yes x2
  rm_to_client_stream_end_ms_h2c: go 10044.0 .. 10062.3 | py 10056.3 .. 10061.7
  rm_to_sub_arrival_ms_h2c: go 2100.5 .. 2127.5 | py 2119.4 .. 2725.4
```

Read against `## Experiment B / both receivers / B-5b, the agentgateway ingress removed under an open stream` and
``## Experiment B / both receivers / B-5b, `agw-central` removed under an open stream``, each 20 per receiver. On the ingress:
the cut comes 39 to 46 ms after the removal command here (36 to 64 ms there), the client reads `unexpected EOF` with no
terminal event, **the removal cost the Task nothing** (`TASK_STATE_COMPLETED` through `SUBMITTED|WORKING|COMPLETED`,
exactly one invocation, outcome `ok`), and **the one resubscription reattached** with `task/TASK_STATE_WORKING` as its
first event and read the Task to `COMPLETED`, while the Task was still running; B-4's asymmetry reproduces on the
execution result line, `queue read failed: context canceled` at the Go receiver and no `error` key at the Python one.
On `agw-central`: the stream is never cut, it carries `TASK_STATE_FAILED` after 10.04 to 10.06 s (10.05 to 10.09 s
there), the removal cost the Task everything on one model attempt (invocation outcome `client-gone`), the two receivers
word the failure as the entry recorded (`model call: Post ... EOF` at the Go worker, `Connection error.` at the Python
orchestrator), and the one resubscription still reached the running Task 2.1 to 2.7 s after the removal (2.05 to 2.80 s
there) and read its failure. 350 cells the same, 1 within, 137 timing, 0 differing.

## D-1 — the rollout variant of B-5b, both receivers

```
RUN_ID=wtd1r RUNREL=my-walkthrough/d1-rollout bash experiments/runs/2026-09-24-d1-current-topology/rows.sh go ingress rollout 2
RUN_ID=wtd1r RUNREL=my-walkthrough/d1-rollout bash experiments/runs/2026-09-24-d1-current-topology/rows.sh py ingress rollout 2
python3 experiments/runs/2026-09-22-b5b-removal-resubscribe/counts.py experiments/runs/my-walkthrough/d1-rollout/rows 45000
```

**289.2 s** (125.6 and 163.6 s). B-5b's row with the removal replaced by `kubectl rollout restart` of the ingress
Deployment, once, and the subscription sent when the successor is first seen Ready; D-1 counted it with B-5b's tool, as
here. The tally (`logs/38c-d1-rollout-counts.txt`):

```
# condensed: cells joined with " ; "; the two receivers side by side with " | "; timing cells as min .. max
## go-ingress-rollout | py-ingress-rollout (2 repetitions each)
  client_events: 2 x2 ; client_terminal_seen: False x2 ; client_stream_end: error x2
  client_error: SSE stream error: unexpected EOF x2 ; job1: Failed/exit3/pods1 x2
  final_state: TASK_STATE_COMPLETED x2 ; invocations: 1 x2 ; invocation_outcomes: ok x2
  sub_first_delivered: task/TASK_STATE_WORKING x2 ; client2_first: task/TASK_STATE_WORKING x2
  client2_events: 3 x2 ; client2_terminal_seen: True x2 ; client2_stream_end: eof x2 ; job2: Complete/exit0/pods1 x2
  task_running_at_sub_arrival: yes x2
  rm_to_client_stream_end_ms_h2c: go 22045.2 .. 22348.3 | py 21894.2 .. 21998.0
  rm_to_sub_arrival_ms_h2c: go 2455.3 .. 2785.3 | py 2442.8 .. 2450.3
  inflight_request_logged_by_old_pod: go no x2 | py no x1; yes x1
```

Read against `## Experiment B / both receivers / D-1, B-5b's rollout variant`, 20 per receiver: the successor is Ready
about 2.5 s after the command and the subscription goes to it then, while the old pod keeps the open stream for its
drain and ends it about 22 s after the command; the stream is lost with `unexpected EOF`, **the Task completes with one
model call**, and **the one resubscription reattaches** with `task/TASK_STATE_WORKING` first and reads the Task to its
end, 4 of 4 here and 40 of 40 there. On the Go receiver 79 cells read the same, 8 within and 35 timing; on the Python
receiver 79 read the same, 35 timing, and **8 differ, and they are one observation this walk took and the entry did
not**: in one of the two
Python repetitions the old ingress pod, at the forced termination of the stream's connection when its drain ended
(20.006 s after SIGTERM by its own stamps, between two `BatchSpanProcessor` "spans emitted after shutdown" warnings and
its `connection forcefully terminated` line), wrote an access line for the cut stream with `http.status=200`, so
`inflight_request_logged_by_old_pod` reads `yes` there and the old pod's access-line, line-count and last-line cells
move with it. D-1's entry read no such line in 0 of 20 on the Python receiver; its Go variant and B-5a's ingress
rollout row took both values. The other Python repetition's identical drain end wrote none of those lines. The cause
on this receiver is not established: no stamp in this run's files says why one repetition wrote the line and the other
did not.

## D-1 — the Python SDK as the reconnecting client

```
RUN_ID=wtd1p RUNREL=my-walkthrough/d1-pyclient bash experiments/runs/2026-09-24-d1-current-topology/pyclient.sh 2
python3 experiments/runs/2026-09-24-d1-current-topology/pyclient-counts.py experiments/runs/my-walkthrough/d1-pyclient/rows/pyclient-central-graceful
```

**95.6 s**, the two rollouts of the orchestrator (`FORWARD_RESUBSCRIBE=on` set for the row and restored empty)
included. The row reverses B's choice of client for this one case: one unary `SendMessage` to the orchestrator makes its
forwarder open a `SendStreamingMessage` to the worker through `agw-central`, which is then deleted gracefully; if that
stream ends without a terminal event the orchestrator's a2a-python client sends exactly one `SubscribeToTask`. The
tally (`logs/39b-d1-pyclient-counts.txt`):

```
# condensed: cells joined with " ; "
  forward_streams: 1 x2 ; forward_subscriptions: 1 x2
  fwd1_events: 2 x2 ; fwd1_terminal_seen: False x2 ; fwd1_stream_end: error x2
  fwd1_error: Network communication error: peer closed connection without sending complete message body (incomplete chunked read) x2
  fwd1_resubscribe: sent x2
  fwd2_requested_task_matches: yes x2 ; fwd2_kinds: <empty> x2 ; fwd2_stream_end: error x2
  fwd2_error_type: UnsupportedOperationError x2
  fwd2_error: task in a terminal state "TASK_STATE_FAILED": this operation is not supported x2
  worker_stream_from: old-pod x2 ; worker_sub_from: successor x2
  worker_final_state: TASK_STATE_FAILED x2 ; task_running_at_sub_arrival: no x2
  invocations: 1 x2 ; invocation_outcomes: client-gone x2 ; stale_closed: 0 x2
  orch_final_state: TASK_STATE_FAILED x2 ; load_client: task/TASK_STATE_FAILED x2 ; job: Complete/exit0/pods1 x2
  rm_to_fwd1_end_ms_h2c: 10043.5 .. 15058.0 (n=2)
```

This row too is read against two entries, each of which ran 20 repetitions where this run ran 2. Against
`## Experiment B / go receiver / D-1, the Python client as the reconnecting client` (2026-09-24, a2a-go v2.5.0) four
cells differ: that entry read the resubscription answered `TaskNotFoundError`, "task not found: no active execution",
and this run reads `UnsupportedOperationError`, "task in a terminal state TASK_STATE_FAILED", on the worker's own
ledger, at the orchestrator's forwarder and in the orchestrator's final error. Against
`## Experiment B / both receivers / the currency pass of 2026-09-25`, which re-counted the row at a2a-go v2.6.0 and
recorded exactly that answer, every cell reads the same: 46 same, 2 within, 14 timing, 0 differing. What both entries
and this run agree on: the forward's stream, opened through the old `agw-central` pod, ends without a terminal event
10.0 to 15.1 s after the removal (the longer one the span processor's shutdown timeout again); the one resubscription
goes to the successor and reaches the worker's Task, but that Task had already failed on its cut model call (one
invocation, `client-gone`), so the subscription is answered with an error and no event; the orchestrator's own Task
fails with that text and the load client reads a failed Task. As the currency pass put it, the Python client is now
told the task is terminal rather than missing.

## What Experiment B leaves behind

The two rollout variants rolled the proxy Deployments. Read the generations again:

```
for g in agentgateway-ingress/agentgateway-ingress agentgateway-waypoint/agw-central; do
  kubectl -n "${g%%/*}" get deploy "${g##*/}" -o jsonpath='{.metadata.namespace}/{.metadata.name} generation={.metadata.generation} restartedAt=[{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}]{"\n"}'
done
```

```
# condensed: the restartedAt stamps written as a placeholder (this run's are in logs/39c-proxy-generations-after.txt)
agentgateway-ingress/agentgateway-ingress generation=7 restartedAt=[<the last rollout's stamp, in your local offset>]
agentgateway-waypoint/agw-central generation=3 restartedAt=[<the last rollout's stamp, in your local offset>]
```

The ingress went from generation 1 to 7 (B-5a's rollout twice, D-1's four times) and `agw-central` from 1 to 3 (B-5a's
rollout twice); the `restartedAt` annotation is `kubectl`'s own stamp in the machine's local offset, and this run's
values are in `logs/39c-proxy-generations-after.txt`. Every removed pod was replaced by its Deployment; the four lab
Deployments are unchanged (`agent_pods_unchanged: yes`, `agent_restarts: 0` in every B-5a variant); the mock is reset
after every row; the orchestrator's `DOWNSTREAM_A2A_URL` and `FORWARD_RESUBSCRIBE` are back to their standing values.
Experiment C's rows follow in [`walkthrough-c.md`](walkthrough-c.md).

## What this part took

| row | wall time |
| --- | ---: |
| B-3 model-call, stream, subscribe-running, subscribe-terminal, `REPS=2` each | 288.8 / 135.7 / 318.4 / 232.0 s |
| B-4 control | 232.2 s |
| B-5a, six variants | 121.5 / 150.9 / 151.0 / 91.0 / 74.5 / 94.4 s |
| B-5b, four variants | 129.7 / 91.6 / 153.8 / 89.5 s |
| D-1 rollout, go and py | 125.6 / 163.6 s |
| D-1 Python client | 95.6 s |
| **first command to last, the reads between included** | **45 min 42 s** |

Every driver exited 0 on its first run and none was repeated. The per-step stamps are in the record's `timings.csv`.
