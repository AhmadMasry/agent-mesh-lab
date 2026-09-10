# Image for the Python agent (Agent A, a2a-python). Two stages, built with uv,
# following uv's own Docker guide, https://docs.astral.sh/uv/guides/integration/docker/,
# read whole on 2026-09-10. The guide's own words for the choices below:
#
#   "install uv by copying the binary from the official distroless Docker image"
#   "you can set the UV_COMPILE_BYTECODE environment variable to ensure that all
#    commands within the Dockerfile compile bytecode"
#   "Changing the UV_LINK_MODE silences warnings about not being able to link
#    files since the cache and sync target are on separate file systems."
#   "uv sync --no-install-project will install the dependencies of the project but
#    not the project itself. Since the project changes frequently, but its
#    dependencies are generally static, this can be a big time saver."
#   "--no-editable can be used to include the project in the synced virtual
#    environment from one stage, then copy the virtual environment alone (and not
#    the source code) into the final image."
#   "It is best practice to add .venv to a .dockerignore file"
#
# Every base image here is referenced BY TAG, not by digest. That is the author's
# decision of 2026-09-10, taken knowingly against the same guide's advice to pin a
# digest for reproducible builds: the lab wants the latest patched base and the
# latest uv at every build, and what is written down instead is the digest and the
# version observed at each build. The Makefile passes `docker build --pull` so both
# tags re-resolve every time, the builder stage prints `uv --version` into the build
# log, and each run record captures the base digest, the uv version and the Python
# version the image ended up with. versions.yaml records the tags as the pins with
# that decision dated, beside the values observed here.
#
# Base: python:3.14-slim. Read from the registry on 2026-09-10 with
# `docker buildx imagetools inspect python:3.14-slim`: the tag is an OCI index over
# linux/amd64 and linux/arm64 whose manifests annotate
# org.opencontainers.image.version = 3.14.7-slim-trixie and
# org.opencontainers.image.base.name = debian:trixie-slim. trixie is Debian 13, the
# current stable release (https://www.debian.org/releases/), so this tag already
# follows the latest Debian and the latest 3.14.x.
#
# slim rather than alpine: alpine is musl, and a musl interpreter takes the
# musllinux wheel of every compiled dependency or none at all, while the whole
# manylinux set this lock needs (pydantic-core, jiter, cffi, cryptography, wrapt,
# charset-normalizer, protobuf) is what a glibc base installs without a compiler --
# counted for 63 of the 64 lock entries in
# experiments/runs/2026-09-10-images-rebuilt/py314-support.txt -- the 64th is the
# project itself, which has no PyPI record. uv's guide leads with
# the Debian slim bases in every example it gives for building an application.
ARG PYTHON_BASE=python:3.14-slim

FROM ${PYTHON_BASE} AS builder

# uv floats to its latest release at every build (author's decision, 2026-09-10),
# so this is the :latest tag with no digest and no version. The version that was
# actually used is not left to inference: the RUN below prints it into the build log
# and the run record keeps the line.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN uv --version

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

# Dependencies first, from the lockfile alone, so a change to the agent's own
# sources does not re-resolve or re-download anything. --locked asserts the
# lockfile is current and fails rather than rewriting it. --no-dev leaves out the
# `dev` group (pytest, pytest-asyncio), which the tests use and the agent does not;
# it replaces the UV_NO_DEFAULT_GROUPS build variable the buildpack descriptor
# carried. uv.lock and pyproject.toml are bind-mounted rather than copied, so
# neither becomes a layer of this stage.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

COPY . /app

# The second sync, with the project present. Measured on 2026-09-10 rather than
# assumed: agents/orchestrator/pyproject.toml declares no [build-system], so uv
# treats it as a virtual project and installs its dependencies without installing
# the project itself -- `ls .venv/lib/python3.14/site-packages` holds no
# `orchestrator` entry after either sync. So this sync adds no package to the
# environment; what it does is assert the lockfile against the whole project, and
# --no-editable makes the "copy the virtual environment alone" step below correct
# for the day the project does gain a build backend. Until then the final stage
# copies the package as source, next to the environment.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-editable

FROM ${PYTHON_BASE}

# The OS packages of the final image are upgraded in one layer, before the user
# exists and before anything of ours is copied in, so the image carries the base
# distribution's current patch level rather than whatever the tag was built with.
# One RUN, and the lists are removed in the same layer so they do not survive into
# the image. --no-install-recommends keeps the upgrade from pulling in packages the
# base image deliberately does not have. The builder stage is NOT upgraded: none of
# its operating system reaches the final image, the venv holding only wheels
# resolved from the lockfile. The packages this upgraded, and the size it cost, are
# in experiments/runs/2026-09-10-images-rebuilt/upgrade.txt, read from a
# --progress=plain build.
RUN apt-get update \
    && apt-get -y upgrade --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# uid:gid 65532:65532 is the uid of the distroless static nonroot base that
# .ko.yaml pins for the Go images (read from that image's config in this session:
# User=65532), so every workload of ours in the cluster runs as one uid.
RUN groupadd --gid 65532 nonroot \
    && useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin nonroot

WORKDIR /app

# Only the environment and the agent package. No uv, no build tools, no package
# manager runs after this point, and no pip beyond what the base image ships.
#
# Deliberately NO --chown: these files stay owned by root with the default
# permissions, world-readable and not writable by uid 65532, which is the user the
# process runs as. The application cannot modify its own code or its own
# dependencies even if the root filesystem were writable. Nothing needs to write
# there: UV_COMPILE_BYTECODE=1 compiled the venv's bytecode at build time and
# PYTHONDONTWRITEBYTECODE=1 below stops the interpreter writing any more.
COPY --from=builder /app/.venv /app/.venv
COPY orchestrator /app/orchestrator

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 65532:65532
EXPOSE 8080

# The command the buildpack Procfile carried ("web: opentelemetry-instrument
# python -m orchestrator.server"), now the image's own.
CMD ["opentelemetry-instrument", "python", "-m", "orchestrator.server"]
