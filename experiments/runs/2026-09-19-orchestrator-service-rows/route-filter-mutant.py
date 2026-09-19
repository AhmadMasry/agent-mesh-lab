"""route-filter-mutant.py [<repository root>]

Runs every fixture in experiments/fixtures/derive-layer/expected.txt against a COPY of
experiments/lib/derive-layer.sh with one change: rule (b)'s fallback counts every POST
entry of the proxy's SERVICE, as it did before the route key of 2026-09-19, instead of the
entries on the one route that forwarded the delivery. The copy is written to a temporary
directory; the derivation itself is not edited.

A fixture the mutant answers differently from expected.txt is one that guards the route
filter. Before follow-ups 19 task 4a added gateway-service-py and gateway-service-r4-py,
none did. Written 2026-09-19; its output is route-filter-mutant.txt.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
src = (root / "experiments/lib/derive-layer.sh").read_text()
old = "    proxy_entries = route_entries(route, proxy)\n"
new = ("    proxy_entries = [r for r in sorted(rows, key=start) if r[\"service\"] == proxy and (r.get(\"route\") or \"\")\n"
       "                     and r[\"operation\"].upper().startswith(\"POST\")]\n")
if src.count(old) != 1:
    sys.exit("route-filter-mutant: the line to mutate was not found exactly once")

with tempfile.TemporaryDirectory() as tmp:
    mutant = pathlib.Path(tmp) / "derive-layer-mutant.sh"
    mutant.write_text(src.replace(old, new))
    mutant.chmod(0o755)
    killed_by = []
    total = 0
    for raw in (root / "experiments/fixtures/derive-layer/expected.txt").read_text().splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        name, receiver, expected, reason = raw.split(" ", 3)
        total += 1
        out = subprocess.run([str(mutant), str(root / "experiments/fixtures/derive-layer" / name), receiver],
                             capture_output=True, text=True, timeout=60).stdout.splitlines()
        got = next((l[len("layer="):] for l in out if l.startswith("layer=")), "")
        got_reason = next((l[len("reason="):] for l in out if l.startswith("reason=")), "")
        if got == expected and got_reason == reason:
            print(f"same  {name}: {got}")
        else:
            killed_by.append(name)
            print(f"DIFF  {name}: mutant says {got} / {got_reason}")
print(f"== {total} fixtures; the mutant answers {len(killed_by)} differently from expected.txt: "
      f"{' '.join(killed_by) or 'none'}")
