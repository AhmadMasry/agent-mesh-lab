import os, shutil, subprocess, sys
REPO="<REPO>"
S=os.path.dirname(os.path.abspath(__file__))
M=[
 ("G00 the unmutated copy (must pass)","refuse.go",[]),
 ("G01 refuses the wrong operation","refuse.go",'if callCtx.Method() == r.op {','if callCtx.Method() == "SendMessage" {'),
 ("G02 refuses when the setting is empty (guard gone, empty op refuses all)","refuse.go",[('if refuse != "" {','if true {'),('if callCtx.Method() == r.op {','if r.op == "" || callCtx.Method() == r.op {')]),
 ("G03 interceptor attached when empty (refuses nothing)","refuse.go",'if refuse != "" {','if true {'),
 ("G04 any value accepted","refuse.go",'	if v == "" {\n		return "", nil\n	}','	return v, nil'),
 ("G05 case folded","refuse.go",'if v == op {','if strings.EqualFold(v, op) {'),
 ("G06 value trimmed","refuse.go",'	if v == "" {\n		return "", nil\n	}','	v = strings.TrimSpace(v)\n	if v == "" {\n		return "", nil\n	}'),
 ("G07 another operation accepted","refuse.go",'"SendMessage", "SendStreamingMessage", "SubscribeToTask"}','"SendMessage", "SendStreamingMessage", "SubscribeToTask", "GetTask"}'),
 ("G08 main ignores an unknown value","main.go",'	if err != nil {\n		log.Fatalf("worker: %v", err)\n	}\n\n	// Tracing','	_ = err\n\n	// Tracing'),
 ("G09 main never passes the setting","main.go",'newRequestHandler(executor, ledger, refuse)','newRequestHandler(executor, ledger, "")'),
 ("G10 the same text not wrapping the A2A error (-32603 on the wire)","refuse.go",'fmt.Errorf("%w: %s is refused by this agent (%s)", a2a.ErrUnsupportedOperation, r.op, refuseOperationEnv)','fmt.Errorf("%s: %s is refused by this agent (%s)", a2a.ErrUnsupportedOperation, r.op, refuseOperationEnv)'),
 ("G11 no refusal at all","refuse.go",'if callCtx.Method() == r.op {','if false {'),
 ("G12 every operation refused when set","refuse.go",'if callCtx.Method() == r.op {','if r.op != "" {'),
 ("G13 refusal text drops the operation","refuse.go",'"%w: %s is refused by this agent (%s)", a2a.ErrUnsupportedOperation, r.op, refuseOperationEnv','"%w: refused by this agent (%s)", a2a.ErrUnsupportedOperation, refuseOperationEnv'),
 ("G14 refusal as TaskNotFound","refuse.go",'a2a.ErrUnsupportedOperation, r.op','a2a.ErrTaskNotFound, r.op'),
]
results=[]
for m in M:
    name,f=m[0],m[1]
    reps=m[2] if isinstance(m[2],list) else [(m[2],m[3])]
    d=os.path.join(S,"tree"); shutil.rmtree(d,ignore_errors=True); os.makedirs(d)
    for x in ["go.mod","go.sum"]: shutil.copy(os.path.join(REPO,x),d)
    for x in ["agents/worker","internal"]: shutil.copytree(os.path.join(REPO,x),os.path.join(d,x))
    p=os.path.join(d,"agents/worker",f); s=open(p).read()
    for a,b in reps:
        assert a in s,(name,a); s=s.replace(a,b)
    if "strings." in s and '"strings"' not in s: s=s.replace('import (\n\t"context"','import (\n\t"context"\n\t"strings"',1)
    open(p,"w").write(s)
    r=subprocess.run(["go","test","-count=1","./agents/worker/"],cwd=d,capture_output=True,text=True)
    killed=r.returncode!=0
    fails=sorted({l.split()[2] for l in r.stdout.splitlines() if l.startswith("--- FAIL")})
    build="BUILD FAILED" if ("[build failed]" in r.stdout or "[setup failed]" in r.stdout) else ""
    results.append((name,"KILLED" if killed else "SURVIVED",build or ",".join(fails)))
    print(results[-1],flush=True)
print(sum(1 for r in results if r[1]=="KILLED"),"of",len(results),"killed")
