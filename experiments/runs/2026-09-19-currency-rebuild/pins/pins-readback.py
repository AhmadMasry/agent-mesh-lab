"""Follow-ups 19, task 3, reading (a): every row of the currency pass's pins.csv beside what this proof read back.

One output row per pins.csv row (84): where its value was read on the rebuilt cluster, in a built image or in
the build log, the value read, and `matched`, `DIFFERS`, or `not read back: <why>` for a pin that has no
cluster-side or build-side value (a document, a dev-only package, a host application). A second file lists what
runs on the cluster and has no pin row of its own, each with why. Reads this run directory's files and
pins.csv with a CSV parser; touches no cluster.

  python3 pins-readback.py <run-dir> <pins.csv> <go.mod-modules-from `go list -m all`>
"""
import csv
import json
import os
import re
import sys

run, pins_path, golist = sys.argv[1:4]
pins = list(csv.DictReader(l for l in open(pins_path) if not l.startswith("#")))
containers = list(csv.DictReader(open(os.path.join(run, "pins/containers.csv"))))
images = sorted({c["spec_image"] for c in containers})
helm = {r["name"]: r for r in json.load(open(os.path.join(run, "pins/helm-list.json")))}
installed = dict(l.strip().split("==", 1) for l in open(os.path.join(run, "pins/orchestrator-installed.txt")) if "==" in l)
gomods = {}
for r in csv.DictReader(open(os.path.join(run, "scan/go-binary-modules.csv"))):
    gomods.setdefault(r["module"], {}).setdefault(r["version"], set()).add(r["binary"])
gotool = sorted({r["go"] for r in csv.DictReader(open(os.path.join(run, "scan/go-binary-modules.csv")))})
graph = dict(l.split()[:2] for l in open(golist) if len(l.split()) >= 2)
readback = open(os.path.join(run, "pins/readback.txt")).read()
build = open(os.path.join(run, "build.txt")).read()
checks = open(os.path.join(run, "checks.txt")).read()
hosttools = open(os.path.join(run, "pins/host-tools.txt")).read()
scanctx = open(os.path.join(run, "scan/scan-context.txt")).read() if os.path.exists(os.path.join(run, "scan/scan-context.txt")) else ""


def image(prefix):
    hit = [i for i in images if i.startswith(prefix)]
    return "|".join(hit)


def chart(release):
    r = helm[release]
    return "%s (app %s)" % (r["chart"], r["app_version"])


def gomod(mod):
    v = gomods.get(mod)
    if v:
        return "; ".join("%s in %s" % (ver, "+".join(sorted(b))) for ver, b in sorted(v.items())), "go version -m of the scanned binaries (scan/go-binary-modules.csv)"
    if mod in graph:
        return graph[mod], "not linked into any of the four binaries; `go list -m all` at the built tree selects it (pins/go-list-m-all.txt)"
    return "", ""


def header(tool):
    m = re.search(r"^# %s:\s+(.*)$" % re.escape(tool), build, re.M)
    return m.group(1).strip() if m else ""


def first(pattern, text, group=1):
    m = re.search(pattern, text, re.M)
    return m.group(group) if m else ""


out = []
for p in pins:
    c, want = p["component"], p["latest_stable_found"]
    where = got = ""
    why = ""
    if c == "kind":
        where, got = "build.txt header, `kind version`", header("kind")
    elif c.startswith("kind node image"):
        where, got = "docker inspect of both node containers; kubectl version; kubelet on both nodes (pins/readback.txt)", "%s; server %s" % (
            first(r"agent-mesh-lab-worker image=(\S+)", readback), first(r"server (v[\d.]+)", readback))
    elif c == "Istio":
        where, got = "running images; istioctl version (pins/readback.txt)", "%s; control plane %s, data plane %s" % (
            image("docker.io/istio/"), first(r"control plane version: (\S+)", readback), first(r"data plane version: (\S+)", readback))
    elif c.startswith("Istio chart"):
        rel = {"base": "istio-base", "istiod": "istiod", "cni": "istio-cni", "ztunnel": "ztunnel"}[c.split()[-1]]
        where, got = "helm list -A, release %s" % rel, chart(rel)
    elif c == "agentgateway proxy image":
        where, got = "running image of both proxies (agw-central, agentgateway-ingress)", image("cr.agentgateway.dev/agentgateway:")
    elif c == "agentgateway controller image":
        where, got = "running image of the controller", image("cr.agentgateway.dev/controller:")
    elif c == "agentgateway chart":
        where, got = "helm list -A, release agentgateway", chart("agentgateway")
    elif c == "agentgateway-crds chart":
        where, got = "helm list -A, release agentgateway-crds", chart("agentgateway-crds")
    elif c.startswith("agentgateway's stated Istio range"):
        why = "a recorded document, not a deployed value; the pairing it speaks of is read back in the two rows above and the Istio row (v1.5.0 on Istio 1.31.0)"
    elif c == "Gateway API CRDs":
        where, got = "annotations of the gateways and httproutes CRDs (pins/readback.txt)", first(r"httproutes\.gateway\.networking\.k8s\.io: (.*)$", readback)
    elif c == "A2A specification":
        why = "a document commit; what the wire carries is reading (b): A2A-Version 1.0 from both SDKs"
    elif c == "a2a-go":
        got, where = gomod("github.com/a2aproject/a2a-go/v2")
    elif c in ("pytest", "pytest-asyncio"):
        why = "dev group of the lock, left out of the image by `uv sync --no-dev`; the preflight's pytest ran under the lock (63 passed)"
        got, where = "", ""
    elif c.startswith("OpenTelemetry Python") or c.startswith("uv.lock") or c in ("a2a-python (a2a-sdk)", "openai-python", "uvicorn"):
        name = {"a2a-python (a2a-sdk)": "a2a-sdk", "openai-python": "openai", "uvicorn": "uvicorn",
                "OpenTelemetry Python distro": "opentelemetry-distro",
                "OpenTelemetry Python instrumentation-starlette": "opentelemetry-instrumentation-starlette",
                "OpenTelemetry Python instrumentation-httpx": "opentelemetry-instrumentation-httpx",
                "OpenTelemetry Python OTLP/HTTP exporter": "opentelemetry-exporter-otlp-proto-http",
                "OpenTelemetry Python instrumentation-openai-v2": "opentelemetry-instrumentation-openai-v2",
                "OpenTelemetry Python util-genai": "opentelemetry-util-genai"}.get(c, c.replace("uv.lock, ", "").replace("uv.lock ", ""))
        if name.startswith("the other"):
            where = "every distribution installed in the running orchestrator container against uv.lock (pins/lock-vs-installed.csv)"
            lv = list(csv.DictReader(open(os.path.join(run, "pins/lock-vs-installed.csv"))))
            got = "%d installed, %d equal to the lock, %d differing" % (
                sum(1 for r in lv if r["installed_in_running_container"]), sum(1 for r in lv if r["verdict"] == "equal"),
                sum(1 for r in lv if r["verdict"] == "DIFFERS"))
            want = "equal to the lock"
        else:
            where, got = "importlib.metadata inside the running orchestrator container (pins/orchestrator-installed.txt)", installed.get(name, "")
    elif c == "OpenTelemetry GenAI semantic conventions":
        why = "a document commit named in two code comments; what the spans carry is the GenAI summary: 0 missing on 4 of 4"
    elif c == "Go toolchain":
        where, got = "go version -m of the scanned binaries; build.txt header", "%s; host %s" % ("|".join(gotool), header("go"))
    elif c.startswith("OpenTelemetry Go (otel"):
        got, where = gomod("go.opentelemetry.io/otel")
    elif c == "OpenTelemetry Go contrib otelhttp":
        got, where = gomod("go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp")
    elif c.startswith("go.mod ") or c.startswith("module graph "):
        got, where = gomod(c.split(" ", 2)[-1] if c.startswith("module graph ") else c[len("go.mod "):])
        if c == "go.mod google.golang.org/grpc":
            want = p["previous"] + " (held; " + want + " not taken)"
    elif c == "OpenTelemetry Collector contrib image":
        where, got = "running image, telemetry/otel-collector", image("otel/opentelemetry-collector-contrib:")
    elif c == "OpenTelemetry Collector chart":
        where, got = "helm list -A, release otel-collector", chart("otel-collector")
    elif c == "Jaeger image":
        where, got = "running image, telemetry/jaeger", image("jaegertracing/jaeger:")
    elif c == "Jaeger chart":
        where, got = "helm list -A, release jaeger", chart("jaeger")
    elif c == "Prometheus image":
        where, got = "running image, telemetry/prometheus", image("prom/prometheus:")
    elif c == "Prometheus chart":
        where, got = "helm list -A, release prometheus", chart("prometheus")
    elif c.startswith("Amazon Linux 2023 base tag"):
        where, got = "build.txt, the image build's FROM line and the dnf transaction", "%s release %s" % (
            first(r"FROM public\.ecr\.aws/amazonlinux/amazonlinux:2023@(sha256:[0-9a-f]{64})", build), first(r"system-release\s+noarch\s+(\S+?)-", build))
    elif c.startswith("Amazon Linux 2023 python3.14"):
        where, got = "build.txt, the dnf transaction; python inside the running container (rule-4/running-pods.txt)", first(r"Installing\s+: (python3\.14-3\S+?)\.aarch64", build)
    elif c.startswith("uv (image tag floats)"):
        where, got = "build.txt, the builder stage's FROM line and `uv --version`", "%s %s" % (
            first(r"^#\d+ [\d.]+ uv (\S+) \(", build), first(r"FROM ghcr\.io/astral-sh/uv:latest@(sha256:[0-9a-f]{64})", build))
    elif c.startswith("distroless base"):
        where, got = "ko's `Using base` line in build.txt and checks.txt", first(r"Using base gcr\.io/distroless/(static-debian13:nonroot@sha256:[0-9a-f]{64})", build)
    elif c.startswith("Python on this host"):
        where, got = "pins/host-tools.txt, the interpreter uv runs the orchestrator's tests on", first(r"uv-managed python of the orchestrator project: Python (\S+)", hosttools)
    elif c.startswith("curlimages/curl"):
        where, got = "the image string of the scripts' control and probe pods as they ran (checks.sh probe; committed scripts' CURL_IMAGE)", first(r"(curlimages/curl:[\d.]+)", open(os.path.join(run, "checks.sh")).read())
    elif c == "Kubescape CLI":
        where, got = "scan/scan-context.txt, `kubescape version`", first(r"Your current version is: (\S+)", scanctx)
    elif c == "Helm":
        where, got = "build.txt header, `helm version --short`", header("helm")
    elif c == "ko":
        where, got = "build.txt header, `ko version`", header("ko")
    elif c.startswith("istioctl"):
        where, got = "build.txt header; istioctl version (pins/readback.txt)", "%s; %s" % (header("istioctl"), first(r"^(client version: \S+)", readback))
    elif c == "kubectl":
        where, got = "build.txt header; kubectl version (pins/readback.txt)", first(r"kubectl client (v[\d.]+)", readback)
    elif c.startswith("Docker Desktop"):
        where, got = "pins/host-tools.txt, `docker version` (server platform name and engine)", "%s; engine %s" % (
            first(r"docker server platform: Docker Desktop (\S+)", hosttools), first(r"docker engine: client \S+ server (\S+)", hosttools))
    out.append([c, p["versions_yaml_key"], p["action"], want, where, got, why])


def verdict(row):
    c, key, action, want, where, got, why = row
    if why:
        return "not read back: " + why
    if not got:
        return "NOT FOUND"
    if want == "equal to the lock":  # the aggregate lock row: matched only when no installed distribution differs from the lock
        return "matched" if ", 0 differing" in got else "DIFFERS"
    core = re.split(r"[ ,(]", want.strip())[0]
    toks = [t for t in re.findall(r"[0-9a-f]{12,}|v?\d+(?:\.\d+)+(?:b\d+)?(?:-[0-9a-z.]+)?", want)]
    ok = all(t.lstrip("v") in got.replace("v", "") or t in got for t in toks[:1]) if toks else core in got
    return "matched" if ok else "DIFFERS"


with open(os.path.join(run, "pins/readback-vs-pins.csv"), "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["component", "versions_yaml_key", "action", "pinned", "read_where", "read_value", "verdict"])
    counts = {}
    for row in out:
        v = verdict(row)
        counts[v.split(":")[0]] = counts.get(v.split(":")[0], 0) + 1
        w.writerow(row[:6] + [v])
print("%d pins.csv rows: %s" % (len(out), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
for row in out:
    v = verdict(row)
    if not v.startswith("matched") and not v.startswith("not read back"):
        print("   %s | pinned %s | read %s -> %s" % (row[0], row[3], row[5], v))

# what runs and has no pin row of its own
pinned_prefixes = ("docker.io/istio/", "cr.agentgateway.dev/", "otel/opentelemetry-collector-contrib:", "jaegertracing/jaeger:", "prom/prometheus:")
rest = []
for i in images:
    if i.startswith(pinned_prefixes):
        continue
    if i.startswith(("registry.k8s.io/", "docker.io/kindest/")):
        whyi = "part of the kind node image kindest/node:v1.37.0 (the kubernetes pin); kind preloads it, the lab does not choose it"
    elif i.startswith("kind.local/") or i == "orchestrator:dev":
        whyi = "the lab's own build from the built tree (ko / the Dockerfile); identified by the tree, its module versions are the go.mod and uv.lock rows"
    elif i.startswith("curlimages/curl"):
        whyi = "the curl-image pin (a script's control pod alive at the moment of the listing)"
    else:
        whyi = "UNEXPLAINED"
    rest.append([i, sum(1 for c in containers if c["spec_image"] == i), whyi])
with open(os.path.join(run, "pins/running-images-without-a-pin-row.csv"), "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["spec_image", "containers", "why_it_has_no_pin_row_of_its_own"])
    w.writerows(rest)
print("running images %d; with a pin row %d; without one %d (unexplained %d)" % (
    len(images), len(images) - len(rest), len(rest), sum(1 for r in rest if r[2] == "UNEXPLAINED")))
