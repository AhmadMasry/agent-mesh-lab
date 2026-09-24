"""Off-proof: the parent commit's agents and this tree's, same requests, lines compared."""
import json, os, re, socket, subprocess, sys, time, urllib.request
S=os.path.abspath(os.environ['WORK'])  # a scratch directory holding parent/ (git archive of the parent), parent-worker, tree-worker
TREE=subprocess.run(['git','rev-parse','--show-toplevel'],capture_output=True,text=True).stdout.strip()
PY=TREE+'/agents/orchestrator/.venv/bin/python'
def free():
    s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); return p
def wait(port):
    t=time.time()+30
    while time.time()<t:
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1',port))==0: return
        time.sleep(0.05)
    raise SystemExit('no listen %d'%port)
BODIES=[
 ('GET','/.well-known/agent-card.json',None),
 ('POST','/','{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"m-off-1","metadata":{"logical_work_item_id":"w-off-1"},"parts":[{"text":"lwi:w-off-1 hi"}],"role":"ROLE_USER"}},"id":"r1"}'),
 ('POST','/','{"jsonrpc":"2.0","method":"SendStreamingMessage","params":{"message":{"messageId":"m-off-2","metadata":{"logical_work_item_id":"w-off-2"},"parts":[{"text":"lwi:w-off-2 hi"}],"role":"ROLE_USER"}},"id":"r2"}'),
 ('POST','/','{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"no-such-task"},"id":"r3"}'),
 ('POST','/','not json'),
]
HDRS={'Content-Type':'application/json','A2A-Version':'1.0','Authorization':'Bearer do-not-record','X-Forwarded-For':'10.0.0.9','X-Caller':'proof','X-Logical-Work-Item-Id':'w-off-h','User-Agent':'offproof/1'}
def drive(port):
    for m,p,b in BODIES:
        req=urllib.request.Request(f'http://127.0.0.1:{port}{p}',data=b.encode() if b else None,method=m,headers=HDRS)
        try: urllib.request.urlopen(req,timeout=20).read()
        except urllib.error.HTTPError as e: e.read()
        time.sleep(0.3)
def run(kind, root, env_extra):
    port=free()
    env={k:v for k,v in os.environ.items() if not k.startswith('OTEL_')}
    env.update({'MODEL_BASE_URL':'http://127.0.0.1:8080/v1','OTEL_SDK_DISABLED':'true'})
    env.update(env_extra)
    if kind=='go':
        env['LISTEN_ADDR']=f'127.0.0.1:{port}'
        cmd=[os.path.join(S,root+'-worker')]
        cwd=S
    else:
        env['PORT']=str(port); env['DOWNSTREAM_A2A_URL']=''
        cmd=[PY,'-m','orchestrator.server']; cwd=os.path.join(root if root!='tree' else TREE,'agents/orchestrator') if root=='tree' else os.path.join(S,root,'agents/orchestrator')
    out=open(os.path.join(S,f'{kind}-{root}-{env_extra.get("LEDGER_HEADERS","unset") or "empty"}.jsonl'),'w')
    proc=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=out,stderr=subprocess.DEVNULL)
    wait(port); drive(port); time.sleep(1.0)
    proc.terminate(); proc.wait(); out.close()
    return out.name
def norm(path):
    rows=[]
    for line in open(path):
        line=line.rstrip('\n')
        if '"ledger":"ingress"' not in line and '"ledger":"execution"' not in line: continue
        for k in ('ts_arrival','ts_end','ts','remote','taskId','contextId'):
            line=re.sub(f'"{k}":"[^"]*"',f'"{k}":"-"',line)
        rows.append(line)
    return rows
res={}
for kind in ('go','py'):
    for root,env in (('parent',{}),('tree',{}),('tree',{'LEDGER_HEADERS':''}),('tree',{'LEDGER_HEADERS':'on'})):
        res[(kind,root,env.get('LEDGER_HEADERS','unset'))]=run(kind,root,env)
for kind in ('go','py'):
    base=norm(res[(kind,'parent','unset')])
    for key in (('tree','unset'),('tree','')):
        other=norm(res[(kind,)+key])
        print(kind, 'parent vs', key, 'lines', len(base), len(other), 'IDENTICAL' if base==other else 'DIFFERS')
        if base!=other:
            for a,b in zip(base,other):
                if a!=b: print(' <',a); print(' >',b); break
    on=norm(res[(kind,'tree','on')])
    strip=[re.sub(r',"headers":\{.*\}\}$','}',l) for l in on]
    print(kind, 'parent vs on with the headers key removed:', 'IDENTICAL' if base==strip else 'DIFFERS', '; lines carrying headers:', sum('"headers":{' in l for l in on), '; authorization value anywhere:', sum('do-not-record' in open(p).read() for p in res.values()))
