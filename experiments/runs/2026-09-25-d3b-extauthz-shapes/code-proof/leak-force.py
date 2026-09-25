# Forced failure for the leak check, applied ONLY to a git archive copy in scratch: in each TestMain_ test the
# readiness dial goes to a closed port (127.0.0.1:1), so the test fails on "never accepted a connection" while the
# child it started is alive and listening; the deadline is cut to 1 s so the run is short.
import sys
for p in ['agents/worker/headers_test.go','agents/worker/refuse_test.go']:
    s=open(p).read()
    n=s.count('conn, err := net.Dial("tcp", addr)')
    assert n==1,(p,n)
    s=s.replace('conn, err := net.Dial("tcp", addr)','conn, err := net.Dial("tcp", "127.0.0.1:1")')
    s=s.replace('\tdeadline := time.Now().Add(10 * time.Second)\n\tfor !strings.Contains(stderr.String(), "listening")','\tdeadline := time.Now().Add(time.Second)\n\tfor !strings.Contains(stderr.String(), "listening")')
    s=s.replace('\t\tdeadline := time.Now().Add(10 * time.Second)\n\t\tfor !strings.Contains(stderr.String(), "listening")','\t\tdeadline := time.Now().Add(time.Second)\n\t\tfor !strings.Contains(stderr.String(), "listening")')
    open(p,'w').write(s)
