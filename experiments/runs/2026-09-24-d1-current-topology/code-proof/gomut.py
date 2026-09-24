"""D-1 code proof: the worker's LEDGER_HEADERS mutants. Each mutant is applied to a fresh copy of the tree at the
commit named on the command line (git archive), and the worker's tests are run on it; a mutant is killed when they
fail. W00 is the unmutated copy, which must pass. Run from inside the repository:
    python3 gomut.py <commit> <scratch dir> > gomut-results.txt
"""
import os, shutil, subprocess, sys
COMMIT, SCR = sys.argv[1], os.path.abspath(sys.argv[2])
BASE = os.path.join(SCR, "gobase")
shutil.rmtree(BASE, ignore_errors=True); os.makedirs(BASE)
subprocess.run(f"git archive {COMMIT} | tar -x -C {BASE}", shell=True, check=True)
M=[
('W00','agents/worker/headers.go','package main','package main'),
('W01','agents/worker/ingress.go','if cfg.headers {','if true {'),
('W02','agents/worker/ingress.go','if cfg.headers {','if false {'),
('W03','agents/worker/headers.go','"x-forwarded-client-cert",\n}','"x-forwarded-client-cert", "authorization",\n}'),
('W04','agents/worker/headers.go','sort.Strings(rec.Names)','_ = sort.Strings'),
('W05','agents/worker/headers.go','\tif r.Host != "" {\n\t\tseen["host"] = true','\tif false {\n\t\tseen["host"] = true'),
('W06','agents/worker/headers.go','seen["transfer-encoding"] = true','_ = 0'),
('W07','agents/worker/ingress.go','\tline.Headers = nil\n',''),
('W08','agents/worker/headers.go','\tswitch v {','\tswitch strings.ToLower(v) {'),
('W09','agents/worker/headers.go','\tswitch v {','\tswitch strings.TrimSpace(v) {'),
('W10','agents/worker/main.go','headersOn, err := ledgerHeadersFrom(os.Getenv(ledgerHeadersEnv))\n\tif err != nil {\n\t\tlog.Fatalf("worker: %v", err)\n\t}','headersOn, _ := ledgerHeadersFrom(os.Getenv(ledgerHeadersEnv))'),
('W11','agents/worker/main.go','withHeaderReading(headersOn)','withHeaderReading(headersOn && false)'),
('W12','agents/worker/headers.go','rec.Values[name] = strings.Join(vs, ", ")','rec.Values[name] = vs[0]'),
('W13','agents/worker/headers.go','\t"x-forwarded-client-cert",\n}','\n}'),
('W14','agents/worker/headers.go','Values: map[string]string{}}','}'),
('W15','agents/worker/headers.go','rec.AuthorizationPresent = len(r.Header.Values("Authorization")) > 0','rec.AuthorizationPresent = true'),
('W16','agents/worker/headers.go','seen["trailer"] = true','_ = 0'),
('W17','agents/worker/headers.go','seen[strings.ToLower(k)] = true','seen[k] = true'),
('W18','agents/worker/headers.go','\t\t\t\trec.Values["host"] = r.Host','\t\t\t\t_ = r.Host'),
]
print(f"# go mutants at {subprocess.run(['git','rev-parse',COMMIT],capture_output=True,text=True).stdout.strip()}", flush=True)
for mid, f, old, new in M:
    d = os.path.join(SCR, "go-" + mid)
    shutil.rmtree(d, ignore_errors=True); shutil.copytree(BASE, d, symlinks=True)
    p = os.path.join(d, f); s = open(p).read()
    assert old in s, (mid, old)
    open(p, "w").write(s.replace(old, new, 1))
    r = subprocess.run(["go", "test", "./agents/worker/", "-count=1"], cwd=d, capture_output=True, text=True)
    fails = [l.split()[2] for l in r.stdout.splitlines() if l.startswith("--- FAIL")]
    build = "build failed" if "build failed" in r.stdout + r.stderr else ""
    ok = r.returncode == 0
    verdict = ("unmutated passes" if ok else "UNMUTATED FAILS") if mid == "W00" else ("SURVIVED" if ok else "killed")
    print(mid, verdict, " ".join(fails[:6]), build, flush=True)
    shutil.rmtree(d, ignore_errors=True)
