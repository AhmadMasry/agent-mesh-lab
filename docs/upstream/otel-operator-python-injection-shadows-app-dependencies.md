# Draft issue — OpenTelemetry Operator: Python auto-instrumentation shadows the application's own dependencies

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: open-telemetry/opentelemetry-operator
Version observed: operator `v0.158.0` (Helm chart `opentelemetry-operator` 0.122.0), Python auto-instrumentation
images `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.64b0` and `:0.65b0`.
Deployment: Kubernetes 1.37.0 on kind; the application is a Python 3.13 service built with Cloud Native
Buildpacks, running `a2a-sdk` 1.1.2 (which declares `protobuf<7,>=5.29.5`) under uvicorn.

## Summary

The Operator injects its Python auto-instrumentation by copying a directory into the pod and putting that
directory on `PYTHONPATH`. `PYTHONPATH` is searched before a virtualenv's `site-packages`, and the directory
carries a full set of runtime dependencies of its own, so every package the two have in common resolves to the
injected copy rather than the application's. Two measured consequences, at two different image tags:

1. **The application's protobuf is replaced by an incompatible one.** `autoinstrumentation-python:0.64b0`
   carries `protobuf` 7.35.1 and `:0.65b0` carries 7.36.0, while the application carries 6.33.6 because its SDK
   declares `protobuf<7`. With the Operator's default `PYTHONPATH` the application's generated protobuf modules
   run under protobuf 7 and every request fails with
   `'FieldDescriptor' object has no attribute 'label'`. The application is not broken and the SDK's own
   constraint is not violated by anything the application installed: the incompatible runtime arrives with the
   instrumentation.
2. **Working around 1 exposes the mirror-image conflict.** The Operator composes the variable as
   `<prefix>:<the container's existing PYTHONPATH>:<suffix>` (`internal/instrumentation/python.go` at v0.158.0),
   so naming the application's `site-packages` in the container's own `PYTHONPATH` restores its protobuf. But
   `opentelemetry` is a namespace package, so its submodules are then resolved from whichever directory holds
   each one, and the two directories must agree on `opentelemetry-api`. With `:0.64b0` (which carries
   `opentelemetry-api` 1.43.0) against an application that resolves 1.44.0 transitively under `google-api-core`,
   auto-initialisation dies with
   `ImportError: cannot import name '_OTEL_PYTHON_EVENT_LOGGER_PROVIDER' from 'opentelemetry.environment_variables'`
   — a name opentelemetry-api 1.43.0 defines and 1.44.0 removed. The application runs but emits no telemetry
   at all, and the only visible sign is one log line, `Failed to auto initialize OpenTelemetry`.

The workaround that produced a working agent is the pair: set the container's `PYTHONPATH` to the application's
`site-packages`, *and* pin the injected image to the tag whose `opentelemetry-api` matches the application's
(`:0.65b0` here). Pinning the application's `opentelemetry-api` down to the injected image's version instead
works equally, and drags one unrelated transitive dependency back a minor version with it. Either way it is a
coupling between an application's lockfile and an injected image tag, which zero-code instrumentation is meant
to avoid, and it is why the lab this was found in dropped the injection route in favour of installing the
OpenTelemetry distro in its own image and starting it with `opentelemetry-instrument`.

## Reproduction

An application whose virtualenv holds `protobuf` 6.x and `opentelemetry-api` 1.44.0 — for example one
depending on `a2a-sdk==1.1.2`, which pulls `google-api-core`, which pulls `opentelemetry-api`. Annotate its pod
for injection from an `Instrumentation` resource:

```yaml
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-python: "<namespace>/<instrumentation>"
```

Case 1, the Operator's default `PYTHONPATH`: the application's own protobuf is shadowed.

```
$ kubectl exec deploy/<app> -- sh -c 'env | grep ^PYTHONPATH'
PYTHONPATH=/otel-auto-instrumentation-python/opentelemetry/instrumentation/auto_instrumentation:/otel-auto-instrumentation-python

$ kubectl exec deploy/<app> -- sh -c 'ls -d /otel-auto-instrumentation-python/protobuf-*.dist-info'
/otel-auto-instrumentation-python/protobuf-7.35.1.dist-info      # injected, wins

$ kubectl exec deploy/<app> -- sh -c 'ls -d <venv>/site-packages/protobuf-*.dist-info'
<venv>/site-packages/protobuf-6.33.6.dist-info                   # the application's, shadowed
```

Every request then fails inside the SDK. Counted over one clean request, from the application's own ledgers:
1 delivery, 0 dispatches, 0 tasks, 0 downstream calls, and the error text
`'FieldDescriptor' object has no attribute 'label'`.

Case 2, with `PYTHONPATH` set on the container to the application's `site-packages` and image `:0.64b0`:

```
$ kubectl logs deploy/<app> | tail
  File "/otel-auto-instrumentation-python/opentelemetry/_events/__init__.py", line 15, in <module>
    from opentelemetry.environment_variables import (
        _OTEL_PYTHON_EVENT_LOGGER_PROVIDER,
    )
ImportError: cannot import name '_OTEL_PYTHON_EVENT_LOGGER_PROVIDER' from 'opentelemetry.environment_variables' (<venv>/site-packages/opentelemetry/environment_variables/__init__.py)
Failed to auto initialize OpenTelemetry
```

The application serves traffic normally and exports nothing. With image `:0.65b0`, whose `opentelemetry-api` is
1.44.0 and so matches, the same pod exports 54 spans of its own for one request, in a trace of 64.

## What the image carries, read from the images themselves

```
$ docker run --rm --entrypoint ls ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.64b0 /autoinstrumentation
opentelemetry_api-1.43.0.dist-info
protobuf-7.35.1.dist-info

$ docker run --rm --entrypoint ls ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.65b0 /autoinstrumentation
opentelemetry_api-1.44.0.dist-info
protobuf-7.36.0.dist-info
```

## Two smaller observations from the same runs

- The repository is internally inconsistent about which image tag release v0.158.0 goes with: the release notes,
  `versions.txt` and the default in `internal/config/config.go` all say `0.64b0`, while
  `autoinstrumentation/python/requirements.txt` at the same tag pins the `0.65b0` packages. The two images differ
  in exactly the way that decides whether an application can be instrumented at all.
- The compiled extensions in the injected directory are built for the image's own platform and Python minor
  version, and are simply unusable when the application's differ. Observed:
  `ImportError: /otel-auto-instrumentation-python/psutil/_psutil_linux.abi3.so: cannot open shared object file`
  in a pod whose application runs `cpython-3.13.15-linux-x86_64`. Only the `system_metrics` instrumentor failed,
  and tracing was unaffected, so this one is a warning rather than a failure — but it is the same shadowing.

## Suggested direction

Either document the constraint plainly (the injected directory's `protobuf` and `opentelemetry-api` must be
compatible with the application's, and the recommended remedy is to name the application's `site-packages` in
`PYTHONPATH`), or make the injection not shadow: install into a directory that carries only the packages the
instrumentation itself needs and cannot be satisfied from the application, or append rather than prepend and let
the application's environment win.
