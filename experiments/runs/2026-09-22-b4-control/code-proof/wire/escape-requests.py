"""Experiment B, step B-4: the captured request bytes, written so a repository that converts CRLF can hold them.

Each raw file capture.py wrote (the bytes of one request as the load client sent them) is committed as
<name>.escaped.txt, every carriage return written <CR> and nothing else changed, and runs/originals.txt records each
raw file's size and sha256. The raw files stay in a scratch directory. This is B-3's practice, whose record explains
it (experiments/runs/2026-09-21-b3-streaming-client/reading-notes.txt).

    python3 escape-requests.py <scratch wire dir> <the runs directory to write>
"""
import hashlib
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
lines = ["# raw capture files, their size and sha256; the committed copies are the same bytes with CR written <CR>.\n"]
for label in sorted(os.listdir(src)):
    d = os.path.join(src, label)
    if not os.path.isdir(d) or not label.startswith(("parent-", "committed-")):
        continue
    os.makedirs(os.path.join(dst, label), exist_ok=True)
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if not os.path.isfile(p) or name.endswith((".masked", "port")):
            continue
        raw = open(p, "rb").read()
        lines.append("%-24s %-16s %8d bytes  sha256 %s\n" % (label, name, len(raw), hashlib.sha256(raw).hexdigest()))
        out = name + ".escaped.txt" if name.endswith(".bin") else name
        open(os.path.join(dst, label, out), "wb").write(raw.replace(b"\r", b"<CR>"))
open(os.path.join(dst, "originals.txt"), "w").writelines(lines)
print("".join(lines[1:]))
