import ast, sys, os
def norm(src):
    t = ast.parse(src)
    for n in ast.walk(t):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef,ast.Module)) and n.body and isinstance(n.body[0],ast.Expr) and isinstance(getattr(n.body[0],'value',None),ast.Constant) and isinstance(n.body[0].value.value,str):
            n.body = n.body[1:] or [ast.Pass()]
    class Strip(ast.NodeTransformer):
        def visit_arg(self,n): n.annotation=None; return n
        def visit_FunctionDef(self,n): n.returns=None; self.generic_visit(n); return n
        visit_AsyncFunctionDef=visit_FunctionDef
        def visit_AnnAssign(self,n):
            if n.value is None: return None
            return ast.Assign(targets=[n.target],value=n.value)
        def visit_Import(self,n): return None
        def visit_ImportFrom(self,n): return None
        def visit_If(self,n):
            if isinstance(n.test,ast.Name) and n.test.id=='TYPE_CHECKING': return None
            if isinstance(n.test,ast.Attribute) and n.test.attr=='TYPE_CHECKING': return None
            self.generic_visit(n); return n
        def visit_Call(self,n):
            self.generic_visit(n)
            if isinstance(n.func,ast.Name) and n.func.id=='cast' and len(n.args)==2: return n.args[1]
            return n
    t=Strip().visit(t); ast.fix_missing_locations(t)
    return t
def defs(t):
    out={}
    def walk(node,prefix):
        for c in getattr(node,'body',[]):
            if isinstance(c,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)):
                name=prefix+c.name
                if isinstance(c,ast.ClassDef):
                    walk(c,name+'.')
                    c2=ast.ClassDef(name=c.name,bases=c.bases,keywords=c.keywords,body=[b for b in c.body if not isinstance(b,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef))] or [ast.Pass()],decorator_list=c.decorator_list,type_params=[])
                    out[name+'(class-level)']=ast.dump(c2,annotate_fields=False,include_attributes=False)
                else:
                    out[name]=ast.dump(c,annotate_fields=False,include_attributes=False)
        mod=[c for c in getattr(node,'body',[]) if not isinstance(c,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef))]
        if prefix=='': out['(module-level)']=ast.dump(ast.Module(body=mod,type_ignores=[]),annotate_fields=False)
    walk(t,'')
    return out
a,b=sys.argv[1],sys.argv[2]
for root,_,files in os.walk(b):
    for f in files:
        if not f.endswith('.py'): continue
        pb=os.path.join(root,f); pa=os.path.join(a,os.path.relpath(pb,b))
        if not os.path.exists(pa): print('NEW FILE',os.path.relpath(pb,b)); continue
        try: da,db=defs(norm(open(pa).read())),defs(norm(open(pb).read()))
        except SyntaxError as e: print('PARSE',pb,e); continue
        ch=[k for k in sorted(set(da)|set(db)) if da.get(k)!=db.get(k)]
        if ch: print(os.path.relpath(pb,b),':',', '.join(ch))
