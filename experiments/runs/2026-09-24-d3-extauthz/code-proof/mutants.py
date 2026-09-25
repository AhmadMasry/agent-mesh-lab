import subprocess, sys, pathlib
D='fixtures/extauthz/'
M=[
 ("X01 JSON-RPC SubscribeToTask allowed", 'decide.go', '\td.Operation, d.DecidedBy = m, "body.method"\n\td.rule()', '\td.Operation, d.DecidedBy = m, "body.method"\n\td.rule()\n\tif d.Operation == "SubscribeToTask" {\n\t\td.Decision = "allow"\n\t}'),
 ("X02 REST SubscribeToTask allowed", 'decide.go', '\t\td.TaskID = restSubscribe.FindStringSubmatch(path)[1]\n\t\td.rule()', '\t\td.TaskID = restSubscribe.FindStringSubmatch(path)[1]\n\t\td.Decision, d.Reason = "allow", "operation:SubscribeToTask"'),
 ("X03 gRPC SubscribeToTask allowed", 'decide.go', '\t\t\td.Operation = path[i+1:]\n\t\t}\n\t\td.rule()', '\t\t\td.Operation = path[i+1:]\n\t\t}\n\t\td.Decision, d.Reason = "allow", "operation:"+d.Operation'),
 ("X04 ledger line written after the answer", 'server.go', '\tif err := s.write(line); err != nil {\n\t\t// No line, no answer: the proxy\'s failure mode decides a check the\n\t\t// ledger did not record. The write is tried once.\n\t\treturn nil, status.Errorf(codes.Internal, "extauthz: ledger write failed: %v", err)\n\t}', '\tdefer func() { _ = s.write(line) }()'),
 ("X05 undecidable default flipped to allow", 'decide.go', 'case "", undecidableDeny:\n\t\treturn undecidableDeny, nil\n\tcase undecidableAllow:', 'case undecidableDeny:\n\t\treturn undecidableDeny, nil\n\tcase "", undecidableAllow:'),
 ("X06 a failed ledger write retried once", 'server.go', '\t_, err = s.out.Write(b)\n\treturn err', '\tif _, err = s.out.Write(b); err != nil {\n\t\t_, err = s.out.Write(b)\n\t}\n\treturn err'),
 ("X07 duplicate key not detected (last key wins)", 'decide.go', '\t\t\tif seen[key] {\n\t\t\t\treturn errDuplicateKey\n\t\t\t}', ''),
 ("X08 partial body read as complete", 'decide.go', '\tcase d.Partial:\n\t\td.undecidable(setting, "partial-body")\n\t\treturn\n', ''),
 ("X09 tenant-prefixed REST subscribe not matched", 'decide.go', '`^(?:/[^/]+)?/tasks/([^/]+):subscribe$`', '`^/tasks/([^/]+):subscribe$`'),
 ("X10 query string not stripped", 'decide.go', '\tpath, _, _ := strings.Cut(r.GetPath(), "?")', '\tpath := r.GetPath()'),
 ("X11 work-item header fallback removed", 'decide.go', '\tif d.LogicalWorkItemID == "" {\n\t\td.LogicalWorkItemID = header(r, "x-logical-work-item-id")\n\t}\n', ''),
 ("X12 unknown EXTAUTHZ_UNDECIDABLE read as deny", 'decide.go', '\treturn "", fmt.Errorf("EXTAUTHZ_UNDECIDABLE=%q: want deny or allow", v)', '\t_ = fmt.Errorf\n\treturn undecidableDeny, nil'),
 ("X13 batch read by its first element", 'decide.go', "\tcase '[':\n\t\td.undecidable(setting, \"batch\")\n\t\treturn\n", ''),
 ("X14 GET subscribe not matched", 'decide.go', '(method == "GET" || method == "POST")', 'method == "POST"'),
 ("X15 trailing data accepted", 'decide.go', '\tif _, err := dec.Token(); err != io.EOF {\n\t\treturn errors.New("data after the first value")\n\t}\n', '\t_ = io.EOF\n'),
]
res=[]
for name,f,old,new in M:
    p=pathlib.Path(D+f); src=p.read_text()
    if src.count(old)!=1: res.append(f"{name}: PATTERN NOT FOUND"); continue
    p.write_text(src.replace(old,new))
    try:
        r=subprocess.run(['go','test','./fixtures/extauthz','-count=1'],capture_output=True,text=True)
        out=r.stdout+r.stderr
        fails=[l.strip() for l in out.splitlines() if l.startswith('--- FAIL') or 'build failed' in l or l.startswith('FAIL\t') or 'vet' in l]
        res.append(f"{name}: {'killed' if r.returncode!=0 else 'SURVIVED'} | "+'; '.join(fails[:4]))
    finally:
        p.write_text(src)
print('\n'.join(res))
