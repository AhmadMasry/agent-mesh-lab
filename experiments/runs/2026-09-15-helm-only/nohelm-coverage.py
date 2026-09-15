#!/usr/bin/env python3
"""Follow-ups 11: object-by-object coverage of deploy/step-3-stress-nohelm by the Helm route.

Called by nohelm-coverage.sh with the directory holding the JSON renders and the telemetry
namespace. Standard library only; YAML embedded in ConfigMaps is parsed by yq through a pipe.

A manifest object is COVERED when the Helm route renders an object of the same kind that does
the same job, and every property the brief names holds: the same pipelines (collector), the same
five scrape jobs (Prometheus), the same images, and the same hardening, where "the same
hardening" is checked as: every securityContext and token setting the manifest declares is
declared with the same value on the Helm route. Anything the Helm route has beyond the manifest
is listed as a difference, never hidden. An object with no counterpart is printed as
NOT COVERED, and the exit status is 1.
"""
import json
import os
import subprocess
import sys

D, NS = sys.argv[1], sys.argv[2]


def load(name):
    with open(os.path.join(D, name + ".json")) as f:
        return json.load(f)


def yaml_text(s):
    return json.loads(subprocess.run(["yq", "-p=yaml", "-o=json", "."], input=s, capture_output=True,
                                     text=True, check=True).stdout)


def key(o):
    md = o.get("metadata", {})
    cluster_scoped = o["kind"] in ("ClusterRole", "ClusterRoleBinding", "Namespace")
    return (o["kind"], "" if cluster_scoped else md.get("namespace", NS), md["name"])


def fmt(k):
    return "%s %s" % (k[0], k[2] if not k[1] else k[1] + "/" + k[2])


out = []
p = out.append
uncovered = 0

nohelm, step3 = load("nohelm"), load("step3")
chart = load("chart-collector") + load("chart-jaeger") + load("chart-prometheus")
manifests = load("manifest-otel-collector") + load("manifest-jaeger") + load("manifest-prometheus")
# helm template leaves metadata.namespace off some namespaced objects; `helm upgrade -i -n` puts them
# in that namespace, so the key defaults to it (see key()).
N = {key(o): o for o in nohelm}
S = {key(o): o for o in step3}
C = {key(o): o for o in chart}
M = {key(o): o for o in manifests}

# ---------------------------------------------------------------------------------------------- 1
p("## 1. what the retired overlay adds to deploy/step-3-stress")
added = sorted(set(N) - set(S))
removed = sorted(set(S) - set(N))
changed = sorted(k for k in set(N) & set(S) if N[k] != S[k])
p("   objects in the nohelm render: %d; in the step-3-stress render: %d" % (len(N), len(S)))
p("   in nohelm and not in step-3-stress: %d" % len(added))
for k in added:
    p("      + %s" % fmt(k))
p("   in step-3-stress and not in nohelm: %d" % len(removed))
p("   in both but not byte-identical as JSON: %d" % len(changed))
p("   objects declared by the three manifest files: %d; equal to the added set: %s" % (
    len(M), "yes" if sorted(M) == added and all(M[k] == N[k] for k in added) else "NO"))
p("")

# ---------------------------------------------------------------------------------------------- 2
p("## 2. what the three charts render")
for k in sorted(C):
    p("      %s" % fmt(k))
p("")

# counterpart map: manifest key -> chart key
CP = {
    ("ConfigMap", NS, "otel-collector"): ("ConfigMap", NS, "otel-collector"),
    ("Deployment", NS, "otel-collector"): ("Deployment", NS, "otel-collector"),
    ("Service", NS, "otel-collector"): ("Service", NS, "otel-collector"),
    ("Deployment", NS, "jaeger"): ("Deployment", NS, "jaeger"),
    ("Service", NS, "jaeger"): ("Service", NS, "jaeger"),
    ("ServiceAccount", NS, "prometheus"): ("ServiceAccount", NS, "prometheus"),
    ("ClusterRole", "", "lab-prometheus"): ("ClusterRole", "", "prometheus"),
    ("ClusterRoleBinding", "", "lab-prometheus"): ("ClusterRoleBinding", "", "prometheus"),
    ("ConfigMap", NS, "prometheus"): ("ConfigMap", NS, "prometheus"),
    ("Deployment", NS, "prometheus"): ("Deployment", NS, "prometheus"),
    ("Service", NS, "prometheus"): ("Service", NS, "prometheus"),
}


def container(dep):
    cs = dep["spec"]["template"]["spec"]["containers"]
    assert len(cs) == 1, "expected one container in %s" % dep["metadata"]["name"]
    return cs[0]


def port_number(c, ref):
    if isinstance(ref, int):
        return ref
    for pt in c.get("ports") or []:
        if pt.get("name") == ref:
            return pt["containerPort"]
    return ref


def hardening(dep):
    ps = dep["spec"]["template"]["spec"]
    c = container(dep)
    h = {}
    for k, v in (ps.get("securityContext") or {}).items():
        h["pod.securityContext." + k] = v
    for k, v in (c.get("securityContext") or {}).items():
        h["container.securityContext." + k] = v
    if "automountServiceAccountToken" in ps:
        h["pod.automountServiceAccountToken"] = ps["automountServiceAccountToken"]
    return h


def sa_token(dep, objs):
    ps = dep["spec"]["template"]["spec"]
    if "automountServiceAccountToken" in ps:
        return "pod: %s" % ps["automountServiceAccountToken"]
    sa = ps.get("serviceAccountName", "default")
    o = objs.get(("ServiceAccount", NS, sa))
    if o is not None and "automountServiceAccountToken" in o:
        return "ServiceAccount %s: %s" % (sa, o["automountServiceAccountToken"])
    return "not set (ServiceAccount %s%s)" % (sa, "" if o is not None else ", not rendered by this route")


def config_file(dep, objs):
    """Resolve the --config/--config.file argument to (ConfigMap name, key)."""
    ps = dep["spec"]["template"]["spec"]
    c = container(dep)
    arg = next(a for a in c.get("args") or [] if a.startswith("--config=") or a.startswith("--config.file="))
    path = arg.split("=", 1)[1]
    for vm in c.get("volumeMounts") or []:
        if path.startswith(vm["mountPath"].rstrip("/") + "/"):
            rel = path[len(vm["mountPath"].rstrip("/")) + 1:]
            vol = next(v for v in ps["volumes"] if v["name"] == vm["name"])
            cm = vol["configMap"]
            items = {i["path"]: i["key"] for i in cm.get("items") or []}
            return arg, cm["name"], items.get(rel, rel)
    return arg, None, None


def show(v):
    return json.dumps(v, separators=(",", ":"), sort_keys=True)


def verdict(ok):
    return "same" if ok else "DIFFERENT"


def rename_otlp(cfg):
    """The collector chart's rewriteDeprecatedComponentNames turns exporter otlp into otlp_grpc."""
    cfg = json.loads(json.dumps(cfg))
    ex = cfg.get("exporters", {})
    if "otlp" in ex and "otlp_grpc" not in ex:
        ex["otlp_grpc"] = ex.pop("otlp")
    for pl in cfg.get("service", {}).get("pipelines", {}).values():
        pl["exporters"] = ["otlp_grpc" if e == "otlp" else e for e in pl.get("exporters", [])]
    return cfg


def diff_paths(a, b, path=""):
    """Leaf paths where a and b differ (a key missing on one side counts)."""
    if isinstance(a, dict) and isinstance(b, dict):
        r = []
        for k in sorted(set(a) | set(b)):
            if k not in a:
                r.append((path + "." + k, "<absent>", show(b[k])))
            elif k not in b:
                r.append((path + "." + k, show(a[k]), "<absent>"))
            else:
                r.extend(diff_paths(a[k], b[k], path + "." + k))
        return r
    return [] if a == b else [(path, show(a), show(b))]


# ---------------------------------------------------------------------------------------------- 3
p("## 3. object by object")
for mk in added:
    m = N[mk]
    ck = CP.get(mk)
    c = C.get(ck) if ck else None
    p("")
    p("### %s  ->  %s" % (fmt(mk), fmt(ck) if c is not None else "NO COUNTERPART"))
    if c is None:
        p("   NOT COVERED")
        uncovered += 1
        continue
    ok = True
    kind = mk[0]

    if kind == "ConfigMap" and mk[2] == "otel-collector":
        md = container(N[("Deployment", NS, "otel-collector")])
        _, m_cm, m_key = config_file(N[("Deployment", NS, "otel-collector")], N)
        _, c_cm, c_key = config_file(C[("Deployment", NS, "otel-collector")], C)
        mc, cc = yaml_text(m["data"][m_key]), yaml_text(c["data"][c_key])
        p("   config key the Deployment reads: manifest %s[%s], chart %s[%s]" % (m_cm, m_key, c_cm, c_key))
        for sec in ("receivers", "processors", "exporters", "extensions", "connectors"):
            a, b = sorted((mc.get(sec) or {}).keys()), sorted((cc.get(sec) or {}).keys())
            p("   %-11s manifest=%-46s chart=%-46s %s" % (sec, show(a), show(b), verdict(a == b)))
        for pl in sorted(set(mc["service"]["pipelines"]) | set(cc["service"]["pipelines"])):
            for part in ("receivers", "processors", "exporters"):
                a = mc["service"]["pipelines"].get(pl, {}).get(part)
                b = cc["service"]["pipelines"].get(pl, {}).get(part)
                p("   pipeline %-8s %-10s manifest=%-32s chart=%-32s %s" % (pl, part, show(a), show(b), verdict(a == b)))
        norm = rename_otlp(mc)
        d = diff_paths(norm, cc)
        p("   whole configuration, manifest with exporter otlp renamed otlp_grpc, against the chart: %s" % (
            "identical" if not d else "%d difference(s)" % len(d)))
        for path, a, b in d:
            p("      %s  manifest=%s  chart=%s" % (path, a, b))
        ok = not d
        extra = sorted(set(c["data"]) - {c_key})
        p("   other ConfigMap keys on the chart route: %s" % (show(extra) if extra else "none"))

    elif kind == "ConfigMap" and mk[2] == "prometheus":
        _, _, m_key = config_file(N[("Deployment", NS, "prometheus")], N)
        _, _, c_key = config_file(C[("Deployment", NS, "prometheus")], C)
        mc, cc = yaml_text(m["data"][m_key]), yaml_text(c["data"][c_key])
        mj, cj = [j["job_name"] for j in mc["scrape_configs"]], [j["job_name"] for j in cc["scrape_configs"]]
        p("   config key the Deployment reads: manifest [%s], chart [%s]" % (m_key, c_key))
        p("   scrape jobs manifest (%d): %s" % (len(mj), show(mj)))
        p("   scrape jobs chart    (%d): %s" % (len(cj), show(cj)))
        p("   same names, same order: %s" % ("yes" if mj == cj else "NO"))
        for a, b in zip(mc["scrape_configs"], cc["scrape_configs"]):
            d = diff_paths(a, b)
            p("   job %-26s whole job body %s" % (a["job_name"], "identical" if not d else "DIFFERENT %s" % d))
            ok = ok and not d
        ok = ok and mj == cj
        for gk, gv in sorted(mc.get("global", {}).items()):
            cv = cc.get("global", {}).get(gk)
            p("   global.%-20s manifest=%-8s chart=%-8s %s" % (gk, gv, cv, verdict(gv == cv)))
            ok = ok and gv == cv
        for gk in sorted(set(cc.get("global", {})) - set(mc.get("global", {}))):
            p("   global.%-20s manifest=<absent> chart=%s   (on the chart route only)" % (gk, cc["global"][gk]))
        for tk in sorted((set(cc) | set(mc)) - {"global", "scrape_configs"}):
            p("   top-level %-18s manifest=%s chart=%s" % (tk, show(mc.get(tk, "<absent>")), show(cc.get(tk, "<absent>"))))
        extra = sorted(set(c["data"]) - {c_key})
        p("   other ConfigMap keys on the chart route: %s" % show(extra))

    elif kind == "Deployment":
        mc_, cc_ = container(m), container(c)
        a, b = mc_["image"], cc_["image"]
        p("   image         manifest=%s chart=%s %s" % (a, b, verdict(a == b)))
        ok = ok and a == b
        a, b = m["spec"].get("replicas"), c["spec"].get("replicas")
        p("   replicas      manifest=%s chart=%s %s" % (a, b, verdict(a == b)))
        ok = ok and a == b
        mh, ch = hardening(m), hardening(c)
        p("   hardening declared by the manifest: %s" % (show(mh) if mh else "none"))
        missing = {k: v for k, v in mh.items() if ch.get(k) != v}
        p("   hardening declared on the chart route: %s" % show(ch))
        p("   every manifest hardening setting present with the same value on the chart route: %s" % (
            "yes" if not missing else "NO %s" % show(missing)))
        ok = ok and not missing
        p("   service account token   manifest: %s; chart: %s" % (sa_token(m, N), sa_token(c, C)))
        mp = sorted(pt["containerPort"] for pt in mc_.get("ports") or [])
        cp = sorted(pt["containerPort"] for pt in cc_.get("ports") or [])
        p("   containerPorts manifest=%s chart=%s; manifest ports not declared on the chart: %s" % (
            show(mp), show(cp), show(sorted(set(mp) - set(cp))) or "[]"))
        for pr in ("readinessProbe", "livenessProbe"):
            def probe(x):
                h = (x.get(pr) or {}).get("httpGet")
                return None if h is None else "%s on %s" % (h["path"], port_number(x, h["port"]))
            p("   %-14s manifest=%s chart=%s" % (pr, probe(mc_), probe(cc_)))
        p("   args          manifest=%s" % show(mc_.get("args")))
        p("                 chart=   %s" % show(cc_.get("args")))
        if mk[2] in ("otel-collector", "prometheus"):
            ma, mcm, mkey = config_file(m, N)
            ca, ccm, ckey = config_file(c, C)
            p("   config file   manifest %s -> ConfigMap %s key %s; chart %s -> ConfigMap %s key %s" % (ma, mcm, mkey, ca, ccm, ckey))
        mv = sorted((v["name"], "configMap:" + v["configMap"]["name"] if "configMap" in v else "emptyDir" if "emptyDir" in v else "other")
                    for v in m["spec"]["template"]["spec"].get("volumes") or [])
        cv = sorted((v["name"], "configMap:" + v["configMap"]["name"] if "configMap" in v else "emptyDir" if "emptyDir" in v else "other")
                    for v in c["spec"]["template"]["spec"].get("volumes") or [])
        p("   volumes       manifest=%s chart=%s" % (show([x[1] for x in mv]), show([x[1] for x in cv])))
        me = [e["name"] for e in mc_.get("env") or []]
        ce = [e["name"] for e in cc_.get("env") or []]
        p("   env names     manifest=%s chart=%s" % (show(me), show(ce)))
        p("   serviceAccountName manifest=%s chart=%s" % (
            m["spec"]["template"]["spec"].get("serviceAccountName", "<default>"),
            c["spec"]["template"]["spec"].get("serviceAccountName", "<default>")))

    elif kind == "Service":
        def ports(svc, dep):
            dc = container(dep)
            return sorted((pt["port"], port_number(dc, pt.get("targetPort", pt["port"]))) for pt in svc["spec"]["ports"])
        md, cd = N[("Deployment", NS, mk[2])], C[("Deployment", NS, mk[2])]
        mp, cp = ports(m, md), ports(c, cd)
        miss = sorted(set(mp) - set(cp))
        p("   name          manifest=%s chart=%s %s" % (m["metadata"]["name"], c["metadata"]["name"], verdict(m["metadata"]["name"] == c["metadata"]["name"])))
        p("   (port, targetPort) manifest=%s" % show(mp))
        p("   (port, targetPort) chart=   %s" % show(cp))
        p("   manifest ports missing on the chart route: %s; chart-only ports: %s" % (show(miss), show(sorted(set(cp) - set(mp)))))
        sel = c["spec"]["selector"]
        labels = cd["spec"]["template"]["metadata"]["labels"]
        selects = all(labels.get(k) == v for k, v in sel.items())
        p("   the chart Service's selector selects the chart Deployment's pods: %s" % ("yes" if selects else "NO"))
        ok = ok and not miss and selects and m["metadata"]["name"] == c["metadata"]["name"]

    elif kind == "ServiceAccount":
        used = C[("Deployment", NS, "prometheus")]["spec"]["template"]["spec"].get("serviceAccountName")
        p("   name manifest=%s chart=%s; used by the chart Deployment: %s" % (m["metadata"]["name"], c["metadata"]["name"], used))
        p("   automountServiceAccountToken manifest=%s chart=%s" % (m.get("automountServiceAccountToken", "<unset>"), c.get("automountServiceAccountToken", "<unset>")))
        ok = ok and used == c["metadata"]["name"] and m.get("automountServiceAccountToken") == c.get("automountServiceAccountToken")

    elif kind == "ClusterRole":
        def triples(r):
            return {(g, res, v) for rule in r.get("rules", []) for g in rule.get("apiGroups", [""])
                    for res in rule.get("resources", []) for v in rule.get("verbs", [])}
        mt, ct = triples(m), triples(c)
        miss = sorted(mt - ct)
        p("   (apiGroup, resource, verb) manifest: %d; chart: %d; manifest triples missing on the chart route: %s" % (len(mt), len(ct), show(miss)))
        extra = sorted({(g if g else "core", r) for g, r, _ in ct - mt})
        p("   chart-only (apiGroup, resource): %s" % show(extra))
        nr = [rule for rule in c.get("rules", []) if "nonResourceURLs" in rule]
        p("   chart-only nonResourceURLs rules: %s" % show(nr))
        ok = ok and not miss

    elif kind == "ClusterRoleBinding":
        def binding(b):
            return (b["roleRef"]["kind"], b["roleRef"]["name"], sorted((s["kind"], s.get("namespace"), s["name"]) for s in b["subjects"]))
        mb, cb = binding(m), binding(c)
        p("   manifest binds %s %s to %s" % (mb[0], mb[1], show(mb[2])))
        p("   chart    binds %s %s to %s" % (cb[0], cb[1], show(cb[2])))
        good = mb[2] == cb[2] and cb[1] == CP[("ClusterRole", "", mb[1])][2]
        p("   same subjects, bound to the counterpart ClusterRole: %s" % ("yes" if good else "NO"))
        ok = ok and good

    p("   => %s" % ("COVERED" if ok else "NOT COVERED"))
    if not ok:
        uncovered += 1

# ---------------------------------------------------------------------------------------------- 4
p("")
p("## 4. chart-route objects with no manifest counterpart (differences, not gaps)")
mapped = set(CP.values())
for k in sorted(set(C) - mapped):
    p("      %s" % fmt(k))
p("")
p("## result: %d manifest object(s); %d covered; %d not covered" % (len(added), len(added) - uncovered, uncovered))
print("\n".join(out))
sys.exit(1 if uncovered else 0)
