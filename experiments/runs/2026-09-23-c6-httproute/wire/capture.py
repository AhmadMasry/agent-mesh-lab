# One-connection-at-a-time raw TCP capture: serves an A2A card that advertises
# itself, answers a POST with a completed Task, and writes every request's raw
# bytes to <outdir>/req-<n>.bin. It answers; it never sends anything unprompted.
import socket, sys, json, os
outdir = sys.argv[1]; port_file = sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(8)
port = s.getsockname()[1]; open(port_file, "w").write(str(port))
n = 0
s.settimeout(20)
while n < 2:
    try:
        c, _ = s.accept()
    except socket.timeout:
        break
    c.settimeout(5)
    while True:
        buf = b""
        try:
            while b"\r\n\r\n" not in buf:
                d = c.recv(65536)
                if not d: raise EOFError
                buf += d
        except (EOFError, socket.timeout, ConnectionResetError):
            break
        head, _, rest = buf.partition(b"\r\n\r\n")
        cl = 0
        for line in head.split(b"\r\n")[1:]:
            k, _, v = line.partition(b":")
            if k.strip().lower() == b"content-length": cl = int(v.strip())
        while len(rest) < cl:
            rest += c.recv(65536)
        n += 1
        open(os.path.join(outdir, "req-%d.bin" % n), "wb").write(head + b"\r\n\r\n" + rest)
        if head.startswith(b"GET"):
            body = json.dumps({"name": "capture", "description": "raw capture", "version": "0.0.1",
                "capabilities": {"streaming": True},
                "supportedInterfaces": [{"url": "http://127.0.0.1:%d" % port, "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}]}).encode()
        else:
            rid = json.loads(rest).get("id")
            body = json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"task": {"id": "task-1", "contextId": "ctx-1", "status": {"state": "TASK_STATE_COMPLETED"}}}}).encode()
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        if n >= 2: break
    c.close()
