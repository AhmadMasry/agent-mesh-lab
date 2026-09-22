# B-4, first code commit: the mutants that the three new tests (the B-3 review's R1, R5, R6) must kill.
# Run on a copy of the tree (MUTANT_TREE), never on the checkout: each mutant is applied, the package's tests run,
# and the file is put back. A verdict is KILLED only when the package built and a test failed.
import os, subprocess, sys
os.chdir(os.environ["MUTANT_TREE"])
S = "fixtures/loadgen/stream.go"
OBS = '\tresp, err := o.base.RoundTrip(req)\n\tif err != nil || !first || resp == nil {'
END = '\tif iterErr != nil {\n\t\tend.StreamEnd = streamEndError'
muts = [
("R1 the outermost transport re-sends a POST whose round trip failed", S, OBS,
 '\tresp, err := o.base.RoundTrip(req)\n\tif err != nil && req.GetBody != nil {\n\t\tif b, gerr := req.GetBody(); gerr == nil {\n\t\t\tagain := req.Clone(req.Context())\n\t\t\tagain.Body = b\n\t\t\tresp, err = o.base.RoundTrip(again)\n\t\t}\n\t}\n\tif err != nil || !first || resp == nil {'),
("R1b stream mode sends the stream again after an error before any event", S, END,
 '\tif iterErr != nil && end.Events == 0 && c.mode.mode == modeStream {\n\t\tfor range client.SendStreamingMessage(callCtx, a2areq.Build(c.workItem, c.text)) {\n\t\t}\n\t}\n' + END),
("R1c subscribe mode subscribes again after an error before any event", S, END,
 '\tif iterErr != nil && end.Events == 0 && c.mode.mode == modeSubscribe {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(c.mode.taskID)}) {\n\t\t}\n\t}\n' + END),
("R5 stream mode sends a second SendStreamingMessage after a quiet end", S, END,
 '\tif iterErr == nil && !end.TerminalSeen && c.mode.mode == modeStream {\n\t\tfor range client.SendStreamingMessage(callCtx, a2areq.Build(c.workItem, c.text)) {\n\t\t}\n\t}\n' + END),
("R5b stream mode subscribes to the task after a quiet end", S, END,
 '\tif iterErr == nil && !end.TerminalSeen && c.mode.mode == modeStream && end.TaskID != "" {\n\t\tfor range client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(end.TaskID)}) {\n\t\t}\n\t}\n' + END),
("R6 the wire observer reads only the first data: payload", S,
 '\t\tif code, msg := rpcError(bytes.TrimSpace(line[len("data:"):])); code != 0 || msg != "" {\n\t\t\treturn code, msg\n\t\t}',
 '\t\treturn rpcError(bytes.TrimSpace(line[len("data:"):]))'),
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
        r = subprocess.run(["go", "test", "-count=1", "./fixtures/loadgen/"], capture_output=True, text=True, timeout=600)
        out = r.stdout + r.stderr
        if "[build failed]" in out or "setup failed" in out:
            verdict = "BUILD-FAILED (not a kill)\n" + out
        elif r.returncode != 0:
            fails = sorted(set(l.split()[2] for l in out.splitlines() if l.startswith("--- FAIL:")))
            why = [l.strip() for l in out.splitlines() if "server saw" in l or "wire_error" in l][:4]
            verdict = "KILLED by " + ",".join(fails) + ("".join("\n    " + w for w in why))
        else:
            verdict = "SURVIVED"
    finally:
        open(f, "w").write(orig)
    print(f"{name}: {verdict}", flush=True)
