import subprocess, sys, os
os.chdir(subprocess.check_output(["git","rev-parse","--show-toplevel"]).decode().strip())
S="fixtures/loadgen/stream.go"; M="fixtures/loadgen/main.go"
muts = [
("M01 MODE unset reads as stream", S, 'case "":\n\t\tm.mode = modeUnary', 'case "":\n\t\tm.mode = modeStream'),
("M02 unknown MODE falls back to unary", S, 'return modeConfig{}, fmt.Errorf("MODE=%q is not a value this client knows; it is %q, %q or unset, and nothing was sent", v, string(modeStream), string(modeSubscribe))', 'm.mode = modeUnary'),
("M03 subscribe without TASK_ID accepted", S, 'case m.mode == modeSubscribe && task == "":', 'case false:'),
("M04 TASK_ID accepted with another mode", S, 'case m.mode != modeSubscribe && task != "":', 'case false:'),
("M05 placeholder accepted as a task id", S, 'case strings.Contains(task, "${"):', 'case false:'),
("M06 retry knobs accepted on a stream", S, 'if k.retries > 0 || k.sdkResend {', 'if false {'),
("M07 stream client keeps the overall Timeout", S, '\thc.Timeout = 0\n', '\n'),
("M08 main wiring gives streams the unary client", M, 'if mode != modeUnary {\n\t\treturn streamHTTPClient(timeout)', 'if false {\n\t\treturn streamHTTPClient(timeout)'),
("M09 configFromEnv skips the knob check", M, 'if err := checkModeKnobs(mode.mode, k); err != nil {\n\t\treturn runConfig{}, knobs{}, err\n\t}', '_ = checkModeKnobs'),
("M10 stream mode sends SendMessage", S, 'events = client.SendStreamingMessage(callCtx, req)', 'events = func(yield func(a2a.Event, error) bool) {\n\t\t\tr, err := client.SendMessage(callCtx, req)\n\t\t\tif err != nil {\n\t\t\t\tyield(nil, err)\n\t\t\t\treturn\n\t\t\t}\n\t\t\tyield(r, nil)\n\t\t}'),
("M11 subscribe mode always sends a second subscription", S, '\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError', '\tif c.mode.mode == modeSubscribe {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(c.mode.taskID)}) {\n\t\t}\n\t}\n\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError'),
("M12 subscribe mode reconnects when no terminal event came", S, '\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError', '\tif c.mode.mode == modeSubscribe && !end.TerminalSeen {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(c.mode.taskID)}) {\n\t\t}\n\t}\n\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError'),
("M13 subscription names another task", S, 'events = client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(c.mode.taskID)})', 'events = client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID("task-x")})'),
("M14 event lines not printed", S, 'b, _ := json.Marshal(line)\n\t\tfmt.Fprintln(out, string(b))', '_, _ = json.Marshal(line)'),
("M15 terminal_seen always true", S, 'if terminal {', 'if terminal || true {'),
("M16 an SDK error is dropped", S, 'end.StreamEnd = streamEndError\n\t\tend.Error = iterErr.Error()', '_ = iterErr'),
("M17 plain-JSON refusal not read from the wire", S, 'if !strings.HasPrefix(ct, "text/event-stream") {\n\t\treturn rpcError(raw)\n\t}', 'if !strings.HasPrefix(ct, "text/event-stream") {\n\t\treturn 0, ""\n\t}'),
("M18 SSE refusal not read from the wire", S, 'if code, msg := rpcError(bytes.TrimSpace(line[len("data:"):])); code != 0 || msg != "" {', 'if code, msg := rpcError(nil); code != 0 || msg != "" {'),
("M19 card_streaming always true", S, 'end.CardStreaming = card.Capabilities.Streaming', 'end.CardStreaming = true'),
("M20 stream mode subscribes after a cut", S, '\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError', '\tif iterErr != nil && c.mode.mode == modeStream && end.TaskID != "" {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(end.TaskID)}) {\n\t\t}\n\t}\n\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError'),
("M21 exit status always 0", S, '\t\t\treturn 0\n\t\t}\n\t\treturn 3\n\t}', '\t\t\treturn 0\n\t\t}\n\t\treturn 0\n\t}'),
("M22 posts count pinned at 1", S, '\to.posts++\n', '\to.posts = 1\n'),
("M23 observer keeps the last POST, not the first", S, 'first := o.posts == 1', 'first := true'),
("M24 unary default goes through the stream path", S, 'default:\n\t\treturn send(ctx, hc, sendConfig{', 'default:\n\t\treturn streamOnce(ctx, hc, c, out)\n\t\t_ = sendConfig{}\n\t\treturn send(ctx, hc, sendConfig{'),
("M25 no tee on the answer body", S, '\t\tresp.Body = teeBody{Reader: io.TeeReader(resp.Body, &o.body), Closer: resp.Body}\n', '\n'),
("M26 first_* track the last event", S, 'if end.Events == 1 {', 'if true {'),
("M27 ts_sent not written", S, '\tend.TSSent = time.Now().UTC().Format(time.RFC3339Nano)\n', '\n'),
]
only = sys.argv[1:]
res=[]
for name,f,old,new in muts:
    if only and name.split()[0] not in only: continue
    orig=open(f).read()
    n=orig.count(old)
    if n!=1:
        res.append((name,"NOT-APPLIED count=%d"%n)); continue
    open(f,"w").write(orig.replace(old,new))
    try:
        b=subprocess.run(["go","vet","./fixtures/loadgen/"],capture_output=True,text=True)
        compiled = "undefined" not in b.stderr and "syntax error" not in b.stderr and "cannot use" not in b.stderr and "declared and not used" not in b.stderr
        r=subprocess.run(["go","test","-count=1","./fixtures/loadgen/"],capture_output=True,text=True,timeout=300)
        out=r.stdout+r.stderr
        if "[build failed]" in out or "setup failed" in out:
            verdict="BUILD-FAILED (not a kill)"
        elif r.returncode!=0:
            fails=sorted(set(l.split()[2] for l in out.splitlines() if l.startswith("--- FAIL:")))
            verdict="KILLED by "+",".join(fails)
        else:
            verdict="SURVIVED"
    finally:
        open(f,"w").write(orig)
    res.append((name,verdict))
for n,v in res: print(f"{n}: {v}")
