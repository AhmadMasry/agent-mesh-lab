import os, shutil, subprocess
REPO="<REPO>/agents/orchestrator"
S=os.path.dirname(os.path.abspath(__file__))
A="orchestrator/agent.py"; R="orchestrator/refuse.py"; V="orchestrator/server.py"
M=[
 ("P00 the unmutated copy (must pass)",A,[]),
 ("P01 refuses the wrong operation",A,[('if self.refuse == operation:','if self.refuse == "SendMessage":')]),
 ("P02 refuses when the setting is empty",A,[('if self.refuse == operation:','if self.refuse in ("", operation):')]),
 ("P03 any value accepted",R,[('    if value in REFUSABLE_OPERATIONS:\n        return value\n','    return value\n')]),
 ("P04 case folded",R,[('    if value in REFUSABLE_OPERATIONS:\n        return value\n','    for op in REFUSABLE_OPERATIONS:\n        if value.lower() == op.lower():\n            return op\n')]),
 ("P05 value stripped",R,[('    if value == "":\n        return ""\n','    value = value.strip()\n    if value == "":\n        return ""\n')]),
 ("P06 another operation accepted",R,[('REFUSABLE_OPERATIONS = ("SendMessage", "SendStreamingMessage", "SubscribeToTask")','REFUSABLE_OPERATIONS = ("SendMessage", "SendStreamingMessage", "SubscribeToTask", "GetTask")')]),
 ("P07 app_from_env swallows a bad value",V,[('    refuse = refuse_operation_from(os.environ.get(REFUSE_OPERATION_ENV, ""))','    try:\n        refuse = refuse_operation_from(os.environ.get(REFUSE_OPERATION_ENV, ""))\n    except ValueError:\n        refuse = ""')]),
 ("P08 app_from_env never passes the setting",V,[('plan_model_call=plan, refuse=refuse)','plan_model_call=plan, refuse="")')]),
 ("P09 build_app never passes it to the handler",V,[('plan_model_call=plan_model_call, refuse=refuse)','plan_model_call=plan_model_call)')]),
 ("P10 build_handler never passes it",A,[('writer=writer, refuse=refuse)','writer=writer)')]),
 ("P11 refusal as TaskNotFoundError",R,[('from a2a.utils.errors import UnsupportedOperationError','from a2a.utils.errors import TaskNotFoundError as UnsupportedOperationError')]),
 ("P12 refusal text drops the operation",R,[('{operation} is refused by this agent','refused by this agent')]),
 ("P13 SendMessage refused before its received line",A,[('        base = self._received("SendMessage", params)\n        try:\n            self._refuse_if("SendMessage")\n','        self._refuse_if("SendMessage")\n        base = self._received("SendMessage", params)\n        try:\n')]),
 ("P14 SubscribeToTask refused after the SDK's handler ran",A,[('            self._refuse_if("SubscribeToTask")\n            async for event in super().on_subscribe_to_task(params, context):','            async for event in super().on_subscribe_to_task(params, context):\n                self._refuse_if("SubscribeToTask")')]),
 ("P15 SendMessage refused after dispatch",A,[('            self._refuse_if("SendMessage")\n            result = await super().on_message_send(params, context)','            result = await super().on_message_send(params, context)\n            self._refuse_if("SendMessage")')]),
 ("P16 every operation refused when set",A,[('if self.refuse == operation:','if self.refuse:')]),
 ("P17 no refusal at all",A,[('if self.refuse == operation:','if False:')]),
 ("P18 streamed send not refused",A,[('            self._refuse_if("SendStreamingMessage")\n','')]),
]
out=[]
for name,f,reps in M:
    d=os.path.join(S,"tree"); shutil.rmtree(d,ignore_errors=True)
    shutil.copytree(REPO,d,ignore=shutil.ignore_patterns(".venv","__pycache__",".pytest_cache"))
    p=os.path.join(d,f); s=open(p).read()
    for a,b in reps:
        assert s.count(a)==1,(name,a); s=s.replace(a,b)
    open(p,"w").write(s)
    r=subprocess.run([REPO+"/.venv/bin/python","-m","pytest","-q","-x","-p","no:cacheprovider","tests/"],cwd=d,capture_output=True,text=True)
    fails=[l.split(" ")[1].split("::")[-1] for l in r.stdout.splitlines() if l.startswith("FAILED") or l.startswith("ERROR")]
    out.append((name,"KILLED" if r.returncode!=0 else "SURVIVED",",".join(fails)[:120]))
    print(out[-1],flush=True)
print(sum(o[1]=="KILLED" for o in out[1:]),"of",len(out)-1,"killed; control:",out[0][1])
