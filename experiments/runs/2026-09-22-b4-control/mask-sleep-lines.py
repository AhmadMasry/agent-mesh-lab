"""Experiment B, step B-4: cut the text of every power-log line the host-sleep recorder listed, keeping the stamp
and the kind.

The recorder (experiments/runs/2026-09-20-experiment-a-agentgateway-only/host-sleep.sh) is run unedited, and in
this task's row window it had, for the first time in this lab's records, lines to list: the host slept during the
row. pmset writes each line with its own text -- the wake source, the power source and charge, the process that
asked for the next wake -- and CLAUDE.md allows no device or product name and no power-assertion owner in a
committed file, and the controller asked for counts only. So the committed host-sleep.txt is this program's output:
every listed line keeps its indentation, its stamp with pmset's own offset and its kind, and loses the rest. The
recorder's own counts, its guard's count, the assertion counts and the keep-awake section are passed through
untouched (they are numbers and pmset's own action words). The unedited output is kept in a scratch directory and
is not committed; reading-notes.txt records that, and how many lines this cut.

    python3 mask-sleep-lines.py <the recorder's output> <the file to write>
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
LINE = re.compile(r"^(\s+)(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4})\s+(Sleep|Wake|DarkWake|Maintenance|Wake Requests)\b(.*)$")
cut = 0
out = []
for raw in open(src):
    m = LINE.match(raw.rstrip("\n"))
    if m and m.group(4).strip():
        cut += 1
        out.append(f"{m.group(1)}{m.group(2)} {m.group(3)}\n")
    else:
        out.append(raw)
head = ("# The text of every listed line below was cut by mask-sleep-lines.py beside this file: each keeps its stamp\n"
        f"# and its kind and nothing else ({cut} lines cut). The counts, the assertion counts and the keep-awake\n"
        "# section are the recorder's own, untouched. reading-notes.txt records this.\n")
open(dst, "w").writelines([head] + out)
print(f"cut {cut} lines")
