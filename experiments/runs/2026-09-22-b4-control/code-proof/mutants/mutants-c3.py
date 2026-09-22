# B-4, the Host setting (CLIENT_HOST): one mutant or more for each behaviour, among them the four the controller's
# ruling names -- the Host on the card GET but not the POST (H10), the reverse (H11), the Host applied when the
# setting is empty (H01), and a second request (H13).
# Run on a copy of the tree (MUTANT_TREE), never on the checkout: each mutant is applied, the package's tests run,
# and the file is put back. A verdict is KILLED only when the package built and a test failed.
import os, subprocess, sys
os.chdir(os.environ["MUTANT_TREE"])
S = "fixtures/loadgen/stream.go"; M = "fixtures/loadgen/main.go"
muts = [
("H01 empty reads as a default host", M, 'v := os.Getenv("CLIENT_HOST")\n\tif v == "" {\n\t\treturn "", nil\n\t}', 'v := os.Getenv("CLIENT_HOST")\n\tif v == "" {\n\t\treturn "worker.lab.internal", nil\n\t}'),
("H02 any value is taken", M, 'if !bareHostName(v) {', 'if false {'),
("H03 a port is taken", M, "c >= '0' && c <= '9' || c == '-')", "c >= '0' && c <= '9' || c == '-' || c == ':')"),
("H04 an IP address is taken", M, 'if len(v) > 253 || net.ParseIP(v) != nil {', 'if len(v) > 253 || (net.ParseIP(v) != nil && false) {'),
("H05 upper case is taken", M, "c >= 'a' && c <= 'z'", "c >= 'A' && c <= 'z'"),
("H06 a label may start or end with a hyphen", M, " || label[0] == '-' || label[len(label)-1] == '-' {", " {"),
("H07 configFromEnv drops hostFromEnv's refusal", M, 'host, err := hostFromEnv()\n\tif err != nil {', 'host, err := hostFromEnv()\n\tif false && err != nil {'),
("H08 configFromEnv does not carry the value", M, 'cancelAfter: cancelAfter, host: host}', 'cancelAfter: cancelAfter, host: host[:0]}'),
("H09 clientFor (main's client) drops the host", M, 'c.workItem, c.host)\n}', 'c.workItem, "")\n}'),
("H10 the Host on the card GET only", M, '\tif t.host != "" {\n', '\tif t.host != "" && req.Method == http.MethodGet {\n'),
("H11 the Host on the POST only", M, '\tif t.host != "" {\n', '\tif t.host != "" && req.Method == http.MethodPost {\n'),
("H12 the Host set as a header, not as req.Host", M, '\t\tnext.Host = t.host\n', '\t\tnext.Header.Set("Host", t.host)\n'),
("H13 a second request: the request first sent without the Host", M, '\treturn t.base.RoundTrip(next)\n}\n\n// instrument wraps',
 '\tif t.host != "" {\n\t\textra := req.Clone(req.Context())\n\t\tif req.GetBody != nil {\n\t\t\textra.Body, _ = req.GetBody()\n\t\t}\n\t\tif r, err := t.base.RoundTrip(extra); err == nil {\n\t\t\t_ = r.Body.Close()\n\t\t}\n\t}\n\treturn t.base.RoundTrip(next)\n}\n\n// instrument wraps'),
("H14 the Host also rewrites the URL dialled", M, '\t\tnext.Host = t.host\n', '\t\tnext.Host = t.host\n\t\tnext.URL.Host = t.host\n'),
("H15 the stream end line does not record the host", S, 'StreamEnd: streamEndNotSent, Host: c.host}', 'StreamEnd: streamEndNotSent}'),
("H16 the unary line does not record the host", M, 'A2AVersion: string(a2a.Version), Host: c.host}', 'A2AVersion: string(a2a.Version)}'),
("H17 the Host applied in the stream mode only", M, 'c.workItem, c.host)\n}', 'c.workItem, map[bool]string{true: c.host}[c.mode.mode == modeStream])\n}'),
("H18a the unary line carries a host key when off", M, '`json:"host,omitempty"`', '`json:"host"`'),
("H18b the stream end line carries a host key when off", S, '`json:"host,omitempty"`', '`json:"host"`'),
]
only = sys.argv[1:]
for name, f, old, new in muts:
    if only and name.split()[0] not in only:
        continue
    orig = open(f).read()
    n = orig.count(old)
    if n != 1:
        print(f"{name}: NOT-APPLIED count={n}", flush=True)
        continue
    open(f, "w").write(orig.replace(old, new))
    try:
        r = subprocess.run(["go", "test", "-count=1", "./fixtures/loadgen/"], capture_output=True, text=True, timeout=900)
        out = r.stdout + r.stderr
        if "[build failed]" in out or "setup failed" in out:
            verdict = "BUILD-FAILED (not a kill)\n" + "\n".join(out.splitlines()[:6])
        elif r.returncode != 0:
            fails = sorted(set(l.split()[2] for l in out.splitlines() if l.startswith("--- FAIL:")))
            verdict = "KILLED by " + ",".join(fails)
        else:
            verdict = "SURVIVED"
    finally:
        open(f, "w").write(orig)
    print(f"{name}: {verdict}", flush=True)
