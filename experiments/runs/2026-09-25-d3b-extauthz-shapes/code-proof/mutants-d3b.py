# Follow-on D-3b: the fixture's mutants. Each is applied to one file, the tests run, the file restored.
# Run from the root of a git archive copy of the tree, never the checkout: python3 mutants-d3b.py
# The worker's TestMain_* tests start the worker process on fixed ports and are skipped here; they gate nothing below.
import subprocess, pathlib, hashlib
F='fixtures/extauthz/decide.go'
# Each shape a receiver dispatches, allowed in turn: an early allow for exactly that request, killed only if a test
# sends that shape. (name, method, path, content-type, body-marker) -- the body is matched by a substring.
SHAPES=[
 ("xp","POST","/x","application/json","SubscribeToTask"),("xa","POST","/a2a/v1","application/json","SubscribeToTask"),
 ("xg","POST","/","application/grpc","SubscribeToTask"),("xr","POST","/tasks/t9%3Asubscribe","",""),
 ("xn","POST","/%0A","application/json","SubscribeToTask"),("xt","POST","/message:send/","application/json","SubscribeToTask"),
 ("xm","POST","/lf.a2a.v1.A2AService/SendMessage","application/grpc","SubscribeToTask"),
 ("xc","POST","/tasks/t9:subscribe","application/grpc",""),("xh","HEAD","/tasks/t9:subscribe","",""),
 ("xl","POST","/tasks/t9:%73ubscribe","",""),("xs","POST","/tasks%2Ft9:subscribe","",""),("xe","POST","/tasks/t9:subscribe%0A","",""),
 ("gp","POST","/lf.a2a.v1.A2AService/Subscribe%54oTask","application/grpc",""),("gs","POST","/lf.a2a.v1.A2AService%2FSubscribeToTask","application/grpc",""),
 ("xb","POST","/","application/json","\\xef\\xbb\\xbf"),("x16","POST","/","application/json","{\\x00"),
 ("gq","POST","/lf.a2a.v1.A2AService/SubscribeToTask?x=1","application/grpc",""),("xu","POST","/","application/json","\\\"METHOD\\\":\\\"SubscribeToTask"),
 ("xq","POST","/","application/json","Subscribe\\\\u0054oTask"),("xi","POST","/tasks/a%2Fb:subscribe","",""),("rg","GET","/tasks/t9:subscribe","",""),
 ("xk","POST","/?x=1","application/json","SubscribeToTask"),
]
ANCHOR='\td := decision{BodyLen: len(r.GetBody()), Size: r.GetSize(), Partial: r.GetSize() == -1}\n'
M=[]
for n,m,p,ct,b in SHAPES:
    M.append((f"S-{n} the shape allowed", F, ANCHOR, ANCHOR+f'\tif r.GetMethod() == "{m}" && r.GetPath() == "{p}" && header(r, "content-type") == "{ct}" && strings.Contains(r.GetBody(), "{b}") {{\n\t\treturn decision{{Decision: "allow", Reason: "mutant"}}\n\t}}\n'))
M+=[
 ("N01 decoding skipped", F, '\treturn strings.ToValidUTF8(b.String(), "\\uFFFD")', '\t_ = b\n\treturn p'),
 ("N02 D1 (the trailing newline) skipped", F, '\tpath1 := strings.TrimSuffix(path, "\\n")', '\tpath1 := path'),
 ("N03 the body read only on /", F, '\tgoReach := method == "POST" && reachesWorkerJSONRPC(r.GetPath())', '\tgoReach := false && reachesWorkerJSONRPC(r.GetPath())'),
 ("N04 rule 4's pattern set missing the catch-all", 'internal/workermux/workermux.go', '\tmux.Handle(JSONRPCPath, jsonrpc)\n\treturn mux', '\t_ = jsonrpc\n\treturn mux'),
 ("N05 the case-folded duplicate check removed", F, '\t\t\t\tif strings.EqualFold(k, key) {', '\t\t\t\tif k == key {'),
 ("N06 (own) a syntax error on the worker's catch-all read as undecidable", F, '\tcase err != nil || m == "":\n\t\treturn false', '\tcase err != nil:\n\t\td.Binding = "jsonrpc"\n\t\td.undecidable(setting, "not-json")\n\t\treturn true\n\tcase m == "":\n\t\treturn false'),
 ("N07 (own) rule 1 on GET and POST only", F, '\tcase strings.HasSuffix(path, ":subscribe") || strings.HasSuffix(path1, ":subscribe"):', '\tcase (method == "GET" || method == "POST") && (strings.HasSuffix(path, ":subscribe") || strings.HasSuffix(path1, ":subscribe")):'),
 ("N08 (own) the BOM not removed", F, '\tbody := []byte(strings.TrimPrefix(r.GetBody(), utf8BOM))', '\tbody := []byte(r.GetBody())'),
 ("N09 (own) a partial body on the catch-all read as not dispatched", F, '\tcase d.Partial && (errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)):', '\tcase false && d.Partial && (errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)):'),
 ("N10 (own) rule 2 on the raw path", F, '\tlast := path[strings.LastIndex(path, "/")+1:]', '\traw, _, _ := strings.Cut(r.GetPath(), "?")\n\tlast := raw[strings.LastIndex(raw, "/")+1:]'),
]
res=[]
for name,f,old,new in M:
    p=pathlib.Path(f); src=p.read_text()
    if src.count(old)!=1: res.append(f"{name}: PATTERN NOT FOUND ({src.count(old)})"); continue
    p.write_text(src.replace(old,new))
    try:
        r=subprocess.run(['go','test','./fixtures/extauthz','./internal/workermux','./agents/worker','-count=1','-skip','TestMain_'],capture_output=True,text=True)
        out=r.stdout+r.stderr
        fails=[l.strip() for l in out.splitlines() if l.lstrip().startswith('--- FAIL') or 'build failed' in l or l.startswith('FAIL\t')]
        res.append(f"{name}: {'killed' if r.returncode!=0 else 'SURVIVED'} | "+'; '.join(fails[:4]))
    finally:
        p.write_text(src)
print('\n'.join(res))
print("killed", sum(1 for x in res if ': killed' in x), "of", len(M))
