#!/usr/bin/env python3
"""before-after.py <tool before> <tool now> <directory of copies> -- does follow-ups 19's
change to experiments/lib/derive-layer.sh move any label or reason on a committed record?

<directory of copies> holds one sub-directory per committed work item that has an
attribution.txt, named <run>__<work item>, with COPIES of the five files the derivation
reads (the records themselves are not touched; `copy-records.sh` beside this file made
them). Each is derived four times: by the tool as it was and by the tool as it is, as
receiver `worker` and as receiver `orchestrator`, because which of the two a work item was
recorded for is not in its files and a regression check should not depend on guessing it.

Written to stdout as CSV, one row per (work item, receiver), then a summary on stderr.
`output_same` compares the whole attribution block after removing the ONE line the tool
now prints that it did not before ("routes named like the model route ...").
"""
import csv
import pathlib
import subprocess
import sys

before, now, copies = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
NEW_LINE = "routes named like the model route under another namespace"


def derive(tool, directory, receiver):
    done = subprocess.run([tool, str(directory), receiver], capture_output=True, text=True, timeout=30)
    lines = done.stdout.splitlines()
    layer = next((l[len("layer="):] for l in lines if l.startswith("layer=")), "")
    reason = next((l[len("reason="):] for l in lines if l.startswith("reason=")), "")
    rest = "\n".join(l for l in lines if not l.startswith(NEW_LINE))
    return done.returncode, layer, reason, rest


out = csv.writer(sys.stdout, lineterminator="\n")
out.writerow(["run", "work_item", "receiver", "exit_before", "exit_now", "layer_before", "layer_now",
              "layer_same", "reason_same", "output_same"])
rows = layer_moved = reason_moved = output_moved = 0
for directory in sorted(p for p in copies.iterdir() if p.is_dir()):
    run, work_item = directory.name.split("__", 1)
    for receiver in ("worker", "orchestrator"):
        eb, lb, rb, ob = derive(before, directory, receiver)
        en, ln, rn, on = derive(now, directory, receiver)
        rows += 1
        layer_moved += lb != ln
        reason_moved += rb != rn
        output_moved += ob != on
        out.writerow([run, work_item, receiver, eb, en, lb, ln,
                      "yes" if lb == ln else "NO", "yes" if rb == rn else "NO", "yes" if ob == on else "NO"])
print(f"{rows} derivations per tool: layer differs on {layer_moved}, reason differs on {reason_moved}, "
      f"the rest of the block differs on {output_moved}", file=sys.stderr)
