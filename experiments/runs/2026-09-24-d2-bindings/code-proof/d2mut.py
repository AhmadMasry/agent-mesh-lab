"""D-2 code proof: mutants. Each mutant is one literal replacement in one file of a fresh copy of the tree at the
commit named (git archive); the suite of the file's side is run on it -- the orchestrator's whole pytest suite in
its locked environment (uv run --frozen), or go test on the Go package the file is in -- and a mutant is killed
when that suite fails. The first entry of each set (id ending 00) is the unmutated copy, which must pass.
Run from inside the repository:
    python3 d2mut.py <commit> <scratch dir> <mutants.json> > results.txt
"""
import json, os, re, shutil, subprocess, sys
COMMIT, SCR, MFILE = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
BASE = os.path.join(SCR, "base")
shutil.rmtree(BASE, ignore_errors=True); os.makedirs(BASE)
subprocess.run(f"git archive {COMMIT} | tar -x -C {BASE}", shell=True, check=True)
sha = subprocess.run(["git", "rev-parse", COMMIT], capture_output=True, text=True).stdout.strip()
print(f"# mutants from {os.path.basename(MFILE)} at {sha}", flush=True)
for mid, f, old, new in json.load(open(MFILE)):
    d = os.path.join(SCR, "m-" + mid)
    shutil.rmtree(d, ignore_errors=True); shutil.copytree(BASE, d, symlinks=True)
    p = os.path.join(d, f); s = open(p).read()
    assert s.count(old) >= 1, (mid, old)
    open(p, "w").write(s.replace(old, new, 1))
    if f.startswith("agents/orchestrator/"):
        r = subprocess.run(["uv", "run", "--frozen", "--quiet", "python", "-m", "pytest", "-q", "-p", "no:cacheprovider"],
                           cwd=os.path.join(d, "agents", "orchestrator"), capture_output=True, text=True)
        out = r.stdout
        lines = [l for l in out.splitlines() if l.startswith("FAILED") or re.match(r"^\d+ (passed|failed)", l)]
        detail = " | ".join(l[:170] for l in lines[:3])
    else:
        pkg = "./" + os.path.dirname(f) + "/"
        r = subprocess.run(["go", "test", pkg, "-count=1"], cwd=d, capture_output=True, text=True)
        out = r.stdout + r.stderr
        fails = [l.split()[2] for l in out.splitlines() if l.startswith("--- FAIL")]
        detail = " ".join(fails[:6]) + (" build failed" if "build failed" in out or "[setup failed]" in out else "")
    ok = r.returncode == 0
    verdict = ("unmutated passes" if ok else "UNMUTATED FAILS") if mid.endswith("00") else ("SURVIVED" if ok else "killed")
    print(mid, verdict, detail, flush=True)
    shutil.rmtree(d, ignore_errors=True)
