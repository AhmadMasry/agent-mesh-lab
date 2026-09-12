"""Follow-ups 10 / the Python 3.14 wheel check over agents/orchestrator/uv.lock, re-done after
`uv lock --upgrade` in the shape of experiments/runs/2026-09-10-images-rebuilt/py314-support.txt.

One document per package: https://pypi.org/pypi/<name>/<locked version>/json. Read-only; one
request per package, no retry (a failed read is printed as a failed row, not repeated).

The group column comes from `uv export --frozen --no-dev --no-emit-project`: a package in that
export is runtime, every other lock entry is dev. The 2026-09-10 table put exceptiongroup in dev;
this rule puts it in runtime, because anyio requires it below Python 3.11 and the runtime export
therefore names it. Nothing else about the classification changes.

  uv run --no-project python experiments/runs/2026-09-12-current-versions/local/py314-support.py
"""

import json
import re
import subprocess
import sys
import tomllib
import urllib.request

LOCK = "agents/orchestrator/uv.lock"
MANYLINUX = re.compile(r"manylinux[^-]*_(aarch64|x86_64)\.whl$")


def runtime_names():
    out = subprocess.run(
        ["uv", "export", "--frozen", "--no-hashes", "--no-dev", "--no-emit-project"],
        cwd="agents/orchestrator", capture_output=True, text=True, check=True,
    ).stdout
    return {line.split("==")[0] for line in out.splitlines() if re.match(r"^[a-z0-9]", line)}


def classify(files):
    wheels = [f["filename"] for f in files if f["filename"].endswith(".whl")]
    cp314 = [w for w in wheels if "-cp314-cp314-" in w]
    abi3 = [w for w in wheels if re.search(r"-cp3\d+-abi3-", w)]
    pure = [w for w in wheels if re.search(r"-(py3|py2\.py3)-none-any\.whl$", w)]
    if cp314:
        return "cp314", len(wheels), str(sum(1 for w in cp314 if MANYLINUX.search(w)))
    if abi3:
        tags = sorted({re.search(r"-(cp3\d+)-abi3-", w).group(1) for w in abi3},
                      key=lambda t: -int(t[3:]))
        return "abi3 (" + "/".join(tags) + ")", len(wheels), str(sum(1 for w in abi3 if MANYLINUX.search(w)))
    if pure:
        return "py3-none-any", len(wheels), ""
    return "NONE", len(wheels), ""


def main():
    lock = tomllib.load(open(LOCK, "rb"))
    runtime = runtime_names()
    rows = []
    for p in sorted(lock["package"], key=lambda p: p["name"]):
        if p["name"] == "orchestrator":
            continue
        url = "https://pypi.org/pypi/{}/{}/json".format(p["name"], p["version"])
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                doc = json.load(r)
        except Exception as exc:  # recorded, not retried
            rows.append((p["name"], p["version"], "?", "READ FAILED: {}".format(exc), "", "", ""))
            continue
        how, nwheels, nml = classify(doc["urls"])
        cls = "yes" if "Programming Language :: Python :: 3.14" in (doc["info"].get("classifiers") or []) else "no"
        group = "runtime" if p["name"] in runtime else "dev"
        rows.append((p["name"], p["version"], group, how, cls, str(nwheels), nml))

    print("Python 3.14 support of every package in agents/orchestrator/uv.lock after `uv lock --upgrade`.")
    print("Source, one document per package: https://pypi.org/pypi/<name>/<locked version>/json")
    print("Columns as in experiments/runs/2026-09-10-images-rebuilt/py314-support.txt; the last column")
    print("counts that package's manylinux aarch64/x86_64 wheels of the named kind.")
    print()
    print("{:<42}{:<14}{:<9}{:<22}{:<9}{:<8}{}".format("package", "version", "group", "how", "cls3.14", "wheels", "manylinux"))
    print("{:<42}{:<14}{:<9}{:<22}{:<9}{:<8}{}".format("-" * 40, "-" * 12, "-" * 7, "-" * 20, "-" * 7, "-" * 6, "-" * 9))
    for r in rows:
        print("{:<42}{:<14}{:<9}{:<22}{:<9}{:<8}{}".format(*r))
    print()
    nrt = sum(1 for r in rows if r[2] == "runtime")
    ndev = sum(1 for r in rows if r[2] == "dev")
    print("Packages read: {} ({} runtime, {} dev).".format(len(rows), nrt, ndev))
    bad = [r for r in rows if r[3] in ("NONE",) or r[3].startswith("READ FAILED")]
    print("Packages with no cp314, no abi3 and no pure wheel, or not read: {}.".format(len(bad)))
    for r in bad:
        print("  " + " ".join(r))
    print()
    print("The compiled-extension packages, and what each resolves to on CPython 3.14:")
    for r in rows:
        if r[6]:
            print("  {}=={}  {}  {} manylinux aarch64/x86_64 wheels of {}".format(r[0], r[1], r[3], r[6], r[5]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
