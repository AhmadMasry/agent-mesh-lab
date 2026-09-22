# B-4, the cancel setting (CANCEL_AFTER_MS): one mutant or more for each new behaviour, among them the cancel
# sending a second request (C12, C12b, C12c) and the setting read on the unary path (C06, C06b).
# Run on a copy of the tree (MUTANT_TREE), never on the checkout: each mutant is applied, the package's tests run,
# and the file is put back. A verdict is KILLED only when the package built and a test failed.
import os, subprocess, sys
os.chdir(os.environ["MUTANT_TREE"])
S = "fixtures/loadgen/stream.go"; C = "fixtures/loadgen/cancel.go"; M = "fixtures/loadgen/main.go"
AFTER_STOP = '\tend.cancelFacts = cx.stop()\n'
muts = [
("C01 empty reads as on", C, 'if v == "" {\n\t\treturn 0, nil\n\t}', 'if v == "" {\n\t\treturn 1000 * time.Millisecond, nil\n\t}'),
("C02 an unreadable value reads as off", C, 'if !positiveDecimal(v) {\n\t\treturn 0, fmt.Errorf(', 'if !positiveDecimal(v) {\n\t\treturn 0, nil\n\t\treturn 0, fmt.Errorf('),
("C03 a leading zero is accepted", C, "v[0] < '1' || v[0] > '9'", "v[0] < '0' || v[0] > '9'"),
("C04 a k at the process bound is accepted", C, 'if err != nil || k >= int64(requestBound/time.Millisecond) {', 'if err != nil {'),
("C05 the setting is accepted with the subscribe mode", C, 'if mode != modeStream {', 'if mode == modeUnary {'),
("C06 the setting is accepted with the unary send", C, 'if mode != modeStream {', 'if mode == modeSubscribe {'),
("C06b the unary send reads the setting and cancels itself", M,
 '\tres, err := client.SendMessage(sendCtx, req)\n\tif err != nil {\n\t\t// A failed attempt',
 '\tif d, cerr := strconv.Atoi(os.Getenv("CANCEL_AFTER_MS")); cerr == nil && d > 0 {\n\t\tvar cancelUnary context.CancelFunc\n\t\tsendCtx, cancelUnary = context.WithTimeout(sendCtx, time.Duration(d)*time.Millisecond)\n\t\tdefer cancelUnary()\n\t}\n\tres, err := client.SendMessage(sendCtx, req)\n\tif err != nil {\n\t\t// A failed attempt'),
("C07 configFromEnv does not carry the value", M, "\t\tcancelAfter: cancelAfter, host: host}, k, nil", "\t\tcancelAfter: 0 * cancelAfter, host: host}, k, nil"),
("C08 configFromEnv drops cancelFromEnv's refusal", M, 'cancelAfter, err := cancelFromEnv(mode.mode)\n\tif err != nil {', 'cancelAfter, err := cancelFromEnv(mode.mode)\n\tif false && err != nil {'),
("C09 the cancel is never armed", S, '\tcx.start()\n', '\n'),
("C10 k is read as seconds", C, 'c.timer = time.AfterFunc(c.after, c.fire)', 'c.timer = time.AfterFunc(c.after*1000, c.fire)'),
("C11 the cancel is made at once, k ignored", C, 'c.timer = time.AfterFunc(c.after, c.fire)', 'c.timer = time.AfterFunc(0, c.fire)'),
("C12 the cancel is followed by a second SendStreamingMessage", S, AFTER_STOP,
 AFTER_STOP + '\tif end.cancelFacts != nil && end.cancelFacts.CancelFired {\n\t\tfor range client.SendStreamingMessage(ctx, a2areq.Build(c.workItem, c.text)) {\n\t\t}\n\t}\n'),
("C12b the cancel is followed by a SubscribeToTask", S, AFTER_STOP,
 AFTER_STOP + '\tif end.cancelFacts != nil && end.cancelFacts.CancelFired && end.TaskID != "" {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(end.TaskID)}) {\n\t\t}\n\t}\n'),
("C12c the cancel is followed by a CancelTask", S, AFTER_STOP,
 AFTER_STOP + '\tif end.cancelFacts != nil && end.cancelFacts.CancelFired && end.TaskID != "" {\n\t\t_, _ = client.CancelTask(ctx, &a2a.CancelTaskRequest{ID: a2a.TaskID(end.TaskID)})\n\t}\n'),
("C13 a timer after the stream's end still cancels", C, 'if c.ended || c.fired {', 'if c.fired {'),
("C15 ts_cancel is not written", C, '\t\tf.TSCancel = c.firedAt.UTC().Format(time.RFC3339Nano)\n', '\n'),
("C16 ts_cancel is stamped when the end is noticed", C, 'f.TSCancel = c.firedAt.UTC().Format(time.RFC3339Nano)', 'f.TSCancel = time.Now().UTC().Format(time.RFC3339Nano)'),
("C17 ended_before_cancel always false", C, 'EndedBeforeCancel: !c.fired,', 'EndedBeforeCancel: false,'),
("C18 events after the cancel are not counted", S, '\t\tcx.sawEvent(kind, state)\n', '\n'),
("C19 every event counts as after the cancel", C, '\tif !c.fired {\n\t\treturn\n\t}\n\tif state != "" {', '\tif state != "" {'),
("C20 the kind is recorded without its state", C, '\t\tkind += "/" + state\n', '\n'),
("C21 the end line carries cancel keys with the setting off", C, 'func (c *canceller) stop() *cancelFacts {\n\tif c == nil {\n\t\treturn nil', 'func (c *canceller) stop() *cancelFacts {\n\tif c == nil {\n\t\treturn &cancelFacts{}'),
("C22 the process waits for k after the stream ended", S, AFTER_STOP, AFTER_STOP + '\tif cx != nil {\n\t\ttime.Sleep(cx.after)\n\t}\n'),
("C26 kinds_after_cancel null when empty", C, 'KindsAfterCancel: append([]string{}, c.kinds...)}', 'KindsAfterCancel: c.kinds}'),
("C27 the stream's context is not the one cancelled", S, '\t\t\tcx = &canceller{after: c.cancelAfter, cancel: cancel}\n', '\t\t\tcx = &canceller{after: c.cancelAfter, cancel: func() {}}\n\t\t\t_ = cancel\n'),
]
only = sys.argv[1:]
for name, f, old, new in muts:
    if only and name.split()[0] not in only:
        continue
    orig = open(f).read()
    n = orig.count(old)
    if n != 1:
        print(f"{name}: NOT-APPLIED count={n}", flush=True)
        continue
    open(f, "w").write(orig.replace(old, new))
    try:
        r = subprocess.run(["go", "test", "-count=1", "./fixtures/loadgen/"], capture_output=True, text=True, timeout=900)
        out = r.stdout + r.stderr
        if "[build failed]" in out or "setup failed" in out:
            verdict = "BUILD-FAILED (not a kill)\n" + "\n".join(out.splitlines()[:6])
        elif r.returncode != 0:
            fails = sorted(set(l.split()[2] for l in out.splitlines() if l.startswith("--- FAIL:")))
            verdict = "KILLED by " + ",".join(fails)
        else:
            verdict = "SURVIVED"
    finally:
        open(f, "w").write(orig)
    print(f"{name}: {verdict}", flush=True)
