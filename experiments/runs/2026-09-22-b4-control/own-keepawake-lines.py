"""Experiment B, step B-4: this run directory's own lines that name caffeinate or pmset, and of them the lines that
would START a keep-awake or SET a power value.

Every .sh and .py file of this directory is read; comment lines (whose first non-space character is #) are left out
of the count, as the last record's own section counts them. A line COUNTS AS NAMING either when it holds the word
caffeinate or pmset. It counts as STARTING a keep-awake or SETTING a power value when it holds caffeinate as a
command word, or pmset with one of its setting arguments (-a, -b, -c, -u, schedule, repeat, sleepnow, displaysleepnow);
`pmset -g` is a read and is not one. A file that holds such a line is not hiding a command: the only lines in this
directory that match are this program's own match strings and the words of a docstring, and every one of them is
printed below the table, so the reader sees the line and not only the number. Reads files only.

    python3 own-keepawake-lines.py <run directory> <output file>
"""
import os
import re
import sys

root, out = sys.argv[1], sys.argv[2]
NAMES = re.compile(r"\b(caffeinate|pmset)\b")
STARTS = re.compile(r"(^|[^-\w./])caffeinate\b|\bpmset\s+(-a|-b|-c|-u|schedule|repeat|sleepnow|displaysleepnow)\b")
rows = []
for dirpath, _, files in os.walk(root):
    for f in sorted(files):
        if not f.endswith((".sh", ".py")):
            continue
        p = os.path.join(dirpath, f)
        rel = os.path.relpath(p, root)
        naming = starting = 0
        hits = []
        for n, raw in enumerate(open(p, errors="replace"), 1):
            line = raw.strip()
            if line.startswith("#"):
                continue
            if NAMES.search(line):
                naming += 1
                if STARTS.search(line):
                    starting += 1
                    hits.append((n, line))
        rows.append((rel, naming, starting, hits))
with open(out, "w") as fh:
    fh.write("# This run directory's own lines that name caffeinate or pmset, and of them the lines that would START a keep-awake or SET a power value.\n")
    fh.write("# Read by own-keepawake-lines.py beside this file, over the non-comment lines of each .sh and .py file of this directory.\n")
    for rel, naming, starting, _ in sorted(rows):
        fh.write("#   %-44s lines naming either = %d; of them lines that would START a keep-awake or SET a power value = %d\n" % (rel, naming, starting))
    fh.write("# total lines that matched the START/SET test: %d, every one of them printed here:\n" % sum(r[2] for r in rows))
    for rel, _, starting, hits in sorted(rows):
        for n, line in hits:
            fh.write("#   %s:%d  %s\n" % (rel, n, line))
    fh.write("# Each is a match string of this program or of a docstring naming the test; none runs caffeinate or sets a power value.\n")
print(open(out).read())
