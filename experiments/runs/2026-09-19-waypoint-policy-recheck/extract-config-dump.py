#!/usr/bin/env python3
"""extract-config-dump.py <full-dump.json> <extract.json>

Cuts one agentgateway admin /config_dump down to the three parts this run reads, and
prints the same parts as text. The full dumps are about 46 KB each and are left out of
the commit by this directory's .gitignore; the extract is what is committed.

Kept:
  policies        the whole list, as the proxy holds it (length 0 on a proxy that was
                  sent none)
  config.tracing  the proxy's own tracing block, null unless --config carried one
  config.xds      which control plane the proxy is a client of

Also recorded: the full dump's byte count and sha256, so an extract can be matched to the
dump it was cut from while that dump still exists on the host that took it.

The full dumps were searched before anything was committed (2026-09-19): no PEM block, no
JWT, no key or password field. The `token` and `caCert` entries under config.xds and
config.ca are file paths inside the pod, not their contents, and `sessionEncoder` is a
mode name. Nothing is masked here because nothing needed it.
"""
import hashlib
import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    raw = open(src, "rb").read()
    dump = json.loads(raw)
    config = dump.get("config") or {}
    policies = dump.get("policies") or []
    extract = {
        "source_bytes": len(raw),
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "agentgateway_version": dump.get("version"),
        "policies_count": len(policies),
        "policies": policies,
        "config": {"tracing": config.get("tracing"), "xds": config.get("xds")},
    }
    with open(dst, "w") as out:
        json.dump(extract, out, indent=2, sort_keys=True)
        out.write("\n")

    print(f"policies: {len(policies)}")
    for policy in policies:
        print(f"  key= {policy.get('key')} name= {json.dumps(policy.get('name'))} target= {json.dumps(policy.get('target'))}")
    print(f"config.tracing: {json.dumps(config.get('tracing'))}")
    print(f"config.xds.address: {json.dumps((config.get('xds') or {}).get('address'))}")
    print(f"config.xds.gateway: {json.dumps((config.get('xds') or {}).get('gateway'))} namespace: {json.dumps((config.get('xds') or {}).get('namespace'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
