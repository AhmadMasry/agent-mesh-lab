"""Follow-ups 19, task 3, reading (a): one row per container of every pod, from `kubectl get pods -A -o json`.

spec_image is what the pod spec names; status_image and image_id are what the node resolved and runs.
Reads a file and writes a file; touches no cluster.

  python3 containers.py <pods.json> <containers.csv>
"""
import csv
import json
import sys

pods = json.load(open(sys.argv[1]))["items"]
rows = []
for p in pods:
    ns, name, phase = p["metadata"]["namespace"], p["metadata"]["name"], p["status"].get("phase", "")
    spec = {c["name"]: c["image"] for k in ("initContainers", "containers") for c in p["spec"].get(k, [])}
    for kind in ("initContainerStatuses", "containerStatuses"):
        for c in p["status"].get(kind, []):
            started = ""
            for st in ("running", "terminated"):
                if st in c.get("state", {}):
                    started = c["state"][st].get("startedAt", "")
            rows.append([ns, name, phase, "init" if kind.startswith("init") else "main", c["name"],
                         spec.get(c["name"], ""), c.get("image", ""), c.get("imageID", ""),
                         str(c.get("ready", "")).lower(), c.get("restartCount", ""), started])
rows.sort()
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["namespace", "pod", "phase", "kind", "container", "spec_image", "status_image", "image_id",
                "ready", "restarts", "started_at"])
    w.writerows(rows)
running_main = [r for r in rows if r[3] == "main" and r[2] == "Running"]
print("%d containers in %d pods; main containers of Running pods: %d, of them not ready: %d; containers with restarts: %d" % (
    len(rows), len(pods), len(running_main), sum(1 for r in running_main if r[8] != "true"),
    sum(1 for r in rows if str(r[9]) not in ("0", ""))))
