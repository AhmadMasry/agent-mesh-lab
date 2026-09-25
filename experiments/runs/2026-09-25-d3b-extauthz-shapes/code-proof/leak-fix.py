# The test-only fix, applied to a tree: the started child is stopped and waited on by t.Cleanup however the test
# ends, and the child never takes the worker's default gRPC port :8081 (GRPC_LISTEN_ADDR=127.0.0.1:0).
import sys, os
os.chdir(sys.argv[1])
def sub(p, old, new):
    s=open(p).read(); assert s.count(old)==1,(p,old[:60]); open(p,'w').write(s.replace(old,new))
for p in ['agents/worker/headers_test.go','agents/worker/refuse_test.go']:
    sub(p, '"LISTEN_ADDR=127.0.0.1:0", "OTEL_EXPORTER_OTLP_ENDPOINT=", "OTEL_SDK_DISABLED=true")',
           '"LISTEN_ADDR=127.0.0.1:0", "GRPC_LISTEN_ADDR=127.0.0.1:0", "OTEL_EXPORTER_OTLP_ENDPOINT=", "OTEL_SDK_DISABLED=true")')
sub('agents/worker/headers_test.go',
'''		cmd.Env = append(cmd.Env, "LISTEN_ADDR="+addr)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
''','''		cmd.Env = append(cmd.Env, "LISTEN_ADDR="+addr)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		// Stopped and waited on however the test ends: a t.Fatalf below would
		// otherwise leave the child serving, re-parented to init.
		t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
''')
sub('agents/worker/refuse_test.go',
'''	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
''','''	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
''')
