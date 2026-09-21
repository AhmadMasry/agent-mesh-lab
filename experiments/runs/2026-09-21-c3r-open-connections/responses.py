#!/usr/bin/env python3
"""responses.py <file>: the HTTP/1.1 responses held in <file>, a byte-for-byte copy of
what `nc` received on the held connection. Prints one line: the number of COMPLETE
responses, then each one's status code (a response is complete when its header block
ended and its body is whole by Content-Length, or by the last chunk if chunked).
Reads only; used by rep.sh to wait on a response and by counts.sh to count them."""
import sys

data = open(sys.argv[1], "rb").read()
i, statuses = 0, []
while True:
    h = data.find(b"\r\n\r\n", i)
    if h < 0:
        break
    head = data[i:h].decode("latin-1").split("\r\n")
    status = head[0].split(" ")[1] if head and len(head[0].split(" ")) > 1 else "?"
    fields = {k.strip().lower(): v.strip() for k, _, v in (l.partition(":") for l in head[1:])}
    b = h + 4
    if "content-length" in fields:
        end = b + int(fields["content-length"])
        if end > len(data):
            break
    elif fields.get("transfer-encoding", "").lower() == "chunked":
        end, ok = b, False
        while True:
            nl = data.find(b"\r\n", end)
            if nl < 0:
                break
            size = int(data[end:nl].split(b";")[0], 16)
            end = nl + 2 + size + 2
            if size == 0:
                ok = end <= len(data)
                break
        if not ok:
            break
    else:
        end = b
    statuses.append(status)
    i = end
print(len(statuses), *statuses)
