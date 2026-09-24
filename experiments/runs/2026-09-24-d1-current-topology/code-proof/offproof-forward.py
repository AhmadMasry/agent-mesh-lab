import json, os, re, socket, subprocess, time, urllib.request
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
    raise SystemExit('no listen')
BODY='{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"m-fwd","metadata":{"logical_work_item_id":"w-fwd"},"parts":[{"text":"lwi:w-fwd hi"}],"role":"ROLE_USER"}},"id":"rf"}'
def run(root, extra):
    base={k:v for k,v in os.environ.items() if not k.startswith('OTEL_')}; base['OTEL_SDK_DISABLED']='true'
    wp=free(); op=free()
    wenv=dict(base, LISTEN_ADDR=f'127.0.0.1:{wp}', MODEL_BASE_URL='http://127.0.0.1:8080/v1', PUBLIC_URL=f'http://127.0.0.1:{wp}', LEDGER_HEADERS='on')
    tag=f'fwd-{root}-{extra.get("FORWARD_RESUBSCRIBE","unset") or "empty"}'
    wout=open(f'{S}/{tag}-worker.jsonl','w'); oout=open(f'{S}/{tag}-orch.jsonl','w')
    w=subprocess.Popen([f'{S}/tree-worker'],env=wenv,stdout=wout,stderr=subprocess.DEVNULL); wait(wp)
    oenv=dict(base, PORT=str(op), DOWNSTREAM_A2A_URL=f'http://127.0.0.1:{wp}', **extra)
    cwd=f'{TREE}/agents/orchestrator' if root=='tree' else f'{S}/parent/agents/orchestrator'
    o=subprocess.Popen([PY,'-m','orchestrator.server'],cwd=cwd,env=oenv,stdout=oout,stderr=subprocess.DEVNULL); wait(op)
    req=urllib.request.Request(f'http://127.0.0.1:{op}/',data=BODY.encode(),method='POST',headers={'Content-Type':'application/json','A2A-Version':'1.0'})
    print(tag, urllib.request.urlopen(req,timeout=30).read()[:0], end=' ')
    time.sleep(1); o.terminate(); o.wait(); w.terminate(); w.wait(); wout.close(); oout.close()
    return tag
def norm(path, extra_mask=()):
    rows=[]
    for line in open(path):
        line=line.rstrip('\n')
        if not line.startswith('{"ledger"'): continue
        for k in ('ts_arrival','ts_end','ts','remote','taskId','contextId')+extra_mask:
            line=re.sub(f'"{k}":"[^"]*"',f'"{k}":"-"',line)
        line=re.sub(r'"host":"127\.0\.0\.1:\d+"','"host":"-"',line)
        rows.append(line)
    return rows
tags=[run('parent',{}),run('tree',{}),run('tree',{'FORWARD_RESUBSCRIBE':''})]
print()
for side,mask in (('orch',()),('worker',('messageId','body_sha256','id'))):
    base=norm(f'{S}/{tags[0]}-{side}.jsonl',mask)
    for t in tags[1:]:
        o=norm(f'{S}/{t}-{side}.jsonl',mask)
        print(side, tags[0],'vs',t, len(base), len(o), 'IDENTICAL' if o==base else 'DIFFERS')
        if o!=base:
            for a,b in zip(base,o):
                if a!=b: print(' <',a); print(' >',b); break
print([l for l in open(f'{S}/{tags[0]}-worker.jsonl') if '"phase":"arrival"' in l and 'SendMessage' in l][0][-700:])
