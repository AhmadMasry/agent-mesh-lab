"""D-1 code proof: the orchestrator's mutants (LEDGER_HEADERS: hmut.json; FORWARD_RESUBSCRIBE: rmut.json). Each mutant is
applied to a fresh copy of agents/orchestrator at the commit named (git archive) and the whole pytest suite is run
on it with the project's own locked environment (uv run --frozen); a mutant is killed when the suite fails. The
first entry of each set is the unmutated copy, which must pass. Run from inside the repository:
    python3 pymut.py <commit> <scratch dir> <mutants.json> > results.txt
"""
import json, os, shutil, subprocess, sys
COMMIT, SCR, MFILE = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
BASE = os.path.join(SCR, "pybase")
shutil.rmtree(BASE, ignore_errors=True); os.makedirs(BASE)
subprocess.run(f"git archive {COMMIT} agents/orchestrator | tar -x -C {BASE}", shell=True, check=True)
BASE = os.path.join(BASE, "agents", "orchestrator")
print(f"# orchestrator mutants from {os.path.basename(MFILE)} at {subprocess.run(['git','rev-parse',COMMIT],capture_output=True,text=True).stdout.strip()}", flush=True)
for mid, f, old, new in json.load(open(MFILE)):
    d = os.path.join(SCR, "py-" + mid)
    shutil.rmtree(d, ignore_errors=True); shutil.copytree(BASE, d)
    p = os.path.join(d, f); s = open(p).read()
    assert old in s, (mid, old)
    open(p, "w").write(s.replace(old, new, 1))
    r = subprocess.run(["uv", "run", "--frozen", "--quiet", "python", "-m", "pytest", "-q", "-x", "-p", "no:cacheprovider"],
                       cwd=d, capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.startswith("FAILED") or " passed" in l or " failed" in l]
    ok = r.returncode == 0
    verdict = ("unmutated passes" if ok else "UNMUTATED FAILS") if mid.endswith("00") else ("SURVIVED" if ok else "killed")
    print(mid, verdict, " | ".join(l[:160] for l in lines[:2]), flush=True)
    shutil.rmtree(d, ignore_errors=True)
