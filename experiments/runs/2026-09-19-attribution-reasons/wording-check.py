#!/usr/bin/env python3
"""wording-check.py <tool before> <tool now> <directory of copies> -- fix round 1 of follow-ups 19
task 2: after the no-route-column reason was reworded, does any LABEL move on a committed record,
and does every REASON that moves differ in that wording alone?

Same copies and the same four derivations per work item as before-after.py beside this file (the
tool as it was at the branch's pushed tip and the tool as it is, each as receiver `worker` and as
receiver `orchestrator`). What this adds: a reason that moved is compared again after the ONE
earlier wording is replaced by the ONE present wording in the earlier reason. If the two are then
equal the reason differs in that wording alone; anything else is reported as unexplained.

CSV on stdout, one row per (work item, receiver); a summary on stderr.
"""
import csv
import pathlib
import subprocess
import sys

before, now, copies = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
NEW_LINE = "routes named like the model route under another namespace"
OLD_WORDING = "the exported trace has no route column (a record from before 2026-09-19)"
NEW_WORDING = ("the exported trace has no route column (exported before the exporter wrote that column: the "
               "follow-ups 18 exporter of 2026-09-19 is the first that does)")


def derive(tool, directory, receiver):
    done = subprocess.run([tool, str(directory), receiver], capture_output=True, text=True, timeout=30)
    lines = done.stdout.splitlines()
    layer = next((l[len("layer="):] for l in lines if l.startswith("layer=")), "")
    reason = next((l[len("reason="):] for l in lines if l.startswith("reason=")), "")
    rest = "\n".join(l for l in lines if not l.startswith(NEW_LINE) and not l.startswith("reason="))
    return done.returncode, layer, reason, rest


out = csv.writer(sys.stdout, lineterminator="\n")
out.writerow(["run", "work_item", "receiver", "exit_before", "exit_now", "layer_before", "layer_now", "layer_same",
              "reason_same", "reason_carried_the_earlier_wording", "reason_same_once_reworded", "rest_same"])
rows = layer_moved = reason_moved = wording_only = unexplained = rest_moved = exits = 0
for directory in sorted(p for p in copies.iterdir() if p.is_dir()):
    run, work_item = directory.name.split("__", 1)
    for receiver in ("worker", "orchestrator"):
        eb, lb, rb, ob = derive(before, directory, receiver)
        en, ln, rn, on = derive(now, directory, receiver)
        rows += 1
        exits += (eb != 0) + (en != 0)
        layer_moved += lb != ln
        rest_moved += ob != on
        carried = OLD_WORDING in rb
        reworded_equal = rb.replace(OLD_WORDING, NEW_WORDING) == rn
        if rb != rn:
            reason_moved += 1
            if carried and reworded_equal:
                wording_only += 1
            else:
                unexplained += 1
        out.writerow([run, work_item, receiver, eb, en, lb, ln, "yes" if lb == ln else "NO",
                      "yes" if rb == rn else "NO", "yes" if carried else "no",
                      "yes" if reworded_equal else "NO", "yes" if ob == on else "NO"])
print(f"{rows} derivations per tool: non-zero exits {exits}, layer differs on {layer_moved}, reason differs on "
      f"{reason_moved} (in that wording alone: {wording_only}; unexplained: {unexplained}), the rest of the block "
      f"differs on {rest_moved}", file=sys.stderr)
