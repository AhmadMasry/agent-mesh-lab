# Image for the Python agent (Agent A, a2a-python). Three stages. The root filesystem
# that reaches the cluster is assembled from Amazon Linux 2023 packages and copied onto
# `scratch`, so the image carries an interpreter, the libraries it links, the CA bundle,
# this project's virtual environment and this project's sources -- and no shell, no
# package manager and no coreutils.
#
# Author's decision of 2026-09-10 ("if all good, let's adopt this"), replacing the
# two-stage python:3.14-slim image of the same morning, after a throwaway evaluation
# build was measured on this host. What that evaluation counted, and what
# experiments/runs/2026-09-10-orchestrator-al2023/ re-counts for this file: a smaller
# root filesystem, an interpreter of the same minor version, the same tests passing, the
# agent card answered by a container started read-only as uid 65532, and a package-level
# vulnerability scan of the finished image.
#
# ---------------------------------------------------------------------------------
# THE THREE STAGES
#
#   builder  An ordinary AL2023 container, dnf and all, none of which reaches the final
#            image. It installs python3.14, copies in the uv binary, and resolves
#            /app/.venv from the lockfile. UV_PYTHON names /usr/bin/python3.14 so uv
#            builds the environment against the same interpreter file the final stage
#            runs; that is what makes the venv's `python` symlink and its console-script
#            shebangs resolve in an image that has no other Python.
#
#   rootfs   A second AL2023 container which never runs the root it builds. It installs
#            into /rootfs with `dnf --installroot`, which is the route the AL2023 user
#            guide documents for exactly this -- "Using the --installroot option to dnf
#            in this manner is how we create the other AL2023 images" -- together with
#            the `--releasever=$(rpm -q system-release --qf '%{VERSION}')` idiom used
#            below, which pins the assembled root to the release of the base image that
#            is assembling it, and `--setopt=install_weak_deps=False`, which "tells dnf
#            to only install dependencies that are *required* rather than recommended or
#            suggested". Both quotations from
#            https://docs.aws.amazon.com/linux/al2023/ug/barebones-containers.html, read
#            whole on 2026-09-10.
#
#   scratch  The image: /rootfs, then the virtual environment, then the agent package,
#            and nothing else at all.
#
# Three packages are asked for by name -- python3.14, system-release, ca-certificates.
# Everything else in the assembled root arrived because the dependency graph pulled it;
# the build log's `rpm --root=/rootfs -qa | sort` is the list, and
# experiments/runs/2026-09-10-orchestrator-al2023/packages.txt keeps it beside its count.
#
# ---------------------------------------------------------------------------------
# WHY bash AND coreutils LEAVE THROUGH rpm -e RATHER THAN rm, AND WHERE THAT STOPS
#
# Whole packages leave through `rpm -e`. `rm` would take their files and leave the RPM
# database saying they are installed, and every later reader of that root -- a
# vulnerability scanner, an SBOM generator, a person running `rpm -qa` against the
# exported filesystem -- would be told the image contains a shell and a coreutils it
# does not contain, and would go on matching those versions against advisories. `rpm -e`
# takes the files and the database entries in one operation, so for what is removed as a
# package, the database and the filesystem make one statement. `--nodeps` is needed
# because other packages declare a dependency on bash and coreutils; that is the point of
# doing it deliberately here rather than hoping the graph never pulls them.
#
# That is the rule for whole packages, and it is deliberately NOT the rule applied to the
# content trees the same RUN prunes with `rm -rf`. Those are removed BY PATH and their
# owning packages stay in the database. Measured, not assumed -- `rpm -ql` over each of
# the 45 packages of the assembled root, in
# experiments/runs/2026-09-10-orchestrator-al2023/locale-and-ownership.txt:
# /etc/yum.repos.d and /etc/dnf are claimed by `amazon-linux-repo-cdn` and
# `system-release`; /usr/share/{man,doc,info,locale} by `filesystem` and a dozen others;
# /var/lib/dnf by none of the 45, `dnf-data` never being installed into this root. Every
# one of those packages except the last is something the interpreter or the distribution
# identity needs, so they cannot be erased and what goes is their content rather than
# their entry. /usr/lib/locale, claimed by `filesystem` and `glibc-common`, was on that
# list until 2026-09-11 and is now KEPT; the RUN below says what that costs and buys.
#
# This is stated rather than glossed because the paragraph above would otherwise read as
# absolute and it is not. What it does still hold for is the claim that matters: no
# package VERSION in the database is falsified, so a scanner -- which matches versions --
# counts this image correctly, and no package that was erased is still listed as present.
# Nothing in the image can act on the difference in any case; there is no rpm and no dnf
# binary here.
#
# WHY THE RPM DATABASE AND system-release STAY
#
# They are how the image says what it is. A scanner reads /etc/os-release (owned by
# system-release) to identify the distribution and its release, then reads
# /var/lib/rpm to enumerate installed packages and versions; with neither, an assembled
# root scans as an unidentifiable pile of files and every package in it goes uncounted.
# Keeping both is what makes `make scan-images` a measurement of this image rather than
# a measurement of nothing. They are also what lets the package list above be read back
# out of the finished image at any later date, without the build log.
#
# ---------------------------------------------------------------------------------
# BASE IMAGES ARE REFERENCED BY TAG, NOT BY DIGEST
#
# The author's decision of 2026-09-10, unchanged by this rewrite: `public.ecr.aws/
# amazonlinux/amazonlinux:2023` in both AL2023 stages and `ghcr.io/astral-sh/uv:latest`
# for the installer. The AL2023 tag is documented as the floating one -- "To get the
# latest version of the AL2023 container image, use the `:2023` tag"
# (https://docs.aws.amazon.com/linux/al2023/ug/base-container.html, read 2026-09-10) --
# so the lab takes the current AL2023 release at every build. What replaces a digest pin
# is a record: the Makefile passes `docker build --pull` so both tags re-resolve, the
# builder prints `uv --version`, the rootfs stage prints the release it pinned itself to
# and the whole package list, and each run record under experiments/runs/ keeps the
# digests and versions that build actually produced. versions.yaml holds the tags as the
# pins, with the decision dated and the observed values beside them.
#
# The tag lives in exactly one place, this ARG, so the two Amazon Linux stages cannot
# drift apart. Dockerfile.reference wrote it out literally in both `FROM` lines; this is
# the one structural difference between them and it is recorded here, in the commit
# message and in report.md rather than left to be discovered. Being an ARG, it is
# overridable with `--build-arg`, which would move the base without changing a tracked
# file; nothing does. `make orchestrator-image` passes no `--build-arg`
# (`docker build --pull --platform linux/$(go env GOARCH) -t orchestrator:dev -f ...`),
# so in every build this repository performs it is a constant, and the build log records
# the digest that actually resolved either way.
ARG AL2023_BASE=public.ecr.aws/amazonlinux/amazonlinux:2023

FROM ${AL2023_BASE} AS builder

# The interpreter the environment is resolved against. Nothing else of this stage
# survives: the final image takes /app/.venv and leaves dnf, rpm, bash and the rest here.
RUN dnf -y install python3.14 && dnf clean all

# uv floats to its latest release at every build (author's decision, 2026-09-10), so this
# is the :latest tag with no digest and no version. The version actually used is not left
# to inference: the RUN below prints it into the build log and the run record keeps the
# line. The binary is copied from the official distroless image rather than installed,
# on uv's own instruction ("install uv by copying the binary from the official distroless
# Docker image", https://docs.astral.sh/uv/guides/integration/docker/).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN uv --version

# UV_COMPILE_BYTECODE, UV_LINK_MODE=copy and UV_PYTHON_DOWNLOADS=0 are from the same
# guide. UV_PYTHON is this image's own: it forbids uv from reaching for any interpreter
# but the distribution one, which is the file the final stage will run.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    UV_PYTHON=/usr/bin/python3.14

# The interpreter's minor version is asserted rather than assumed. `python3.14` is a
# distribution package name, not a promise about what it contains, and the lockfile and
# the tests are resolved against 3.14; a base that moved under us fails the build here
# instead of at some later count.
RUN python3.14 -c 'import sys; assert sys.version_info[:2] == (3, 14), sys.version'

WORKDIR /app

# Dependencies first, from the lockfile alone, so a change to the agent's own sources
# does not re-resolve or re-download anything. --locked asserts the lockfile is current
# and fails rather than rewriting it. --no-dev leaves out the `dev` group (pytest,
# pytest-asyncio), which the tests use and the agent does not. uv.lock and pyproject.toml
# are bind-mounted rather than copied, so neither becomes a layer of this stage.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

COPY . /app

# The second sync, with the project present. Measured on 2026-09-10 rather than assumed:
# agents/orchestrator/pyproject.toml declares no [build-system], so uv treats it as a
# virtual project and installs its dependencies without installing the project itself.
# So this sync adds no package to the environment; what it does is assert the lockfile
# against the whole project, and --no-editable makes the "copy the virtual environment
# alone" step below correct for the day the project does gain a build backend. Until
# then the final stage copies the package as source, next to the environment.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-editable

FROM ${AL2023_BASE} AS rootfs

# Assemble the runtime root under /rootfs: the interpreter, whatever it depends on, the
# distro identity (system-release, which owns /etc/os-release) and the CA bundle. Then
# the upgrade, in the same RUN, because the author's rule is that an image upgrades its
# operating system at build time rather than shipping whatever the base tag was built
# with; on a floating `:2023` tag it has nothing to apply on most days, and the day it
# does is the day the rule earns its place. What it applied at this build is in the run
# record. Then bash and coreutils leave through the RPM database, for the reason in the
# header. Then dnf's own caches, the dnf configuration and the repository definitions go,
# so nothing in the final image can be talked into fetching a package, followed by the
# documentation, message-catalogue and man trees, which an image with no shell cannot
# display.
#
# GLIBC'S LOCALE ARCHIVE IS KEPT, AND THE SECOND `rm -rf` STOPS SHORT OF IT
#
# /rootfs/usr/lib/locale was on that second `rm -rf` until 2026-09-11, when the author
# decided to keep it ("go ahead") after the cost was measured. What the archive holds in
# this root, read out of the finished image: one locale directory, C.utf8, 12 files and
# 351817 bytes of content. What keeping it costs: the exported root filesystem goes from
# 186213888 to 186577920 bytes, **+364032 bytes**, an increase of 0.20%. What it buys:
# `locale.setlocale(LC_ALL, "C.UTF-8")` returns "C.UTF-8" instead of raising
# "unsupported locale setting", and `setlocale(LC_ALL, "")` resolves LC_CTYPE to
# C.UTF-8 rather than to C. `en_US.UTF-8` still raises -- the root carries
# glibc-minimal-langpack and no language pack -- so this buys the C.UTF-8 setting, not
# locale support in general.
#
# Both sides are measured rather than argued, and the removed side is a record rather
# than a memory: experiments/runs/2026-09-10-orchestrator-al2023/locale-and-ownership.txt
# for the image as it now ships, and that run's pre-locale/ directory for the same
# measurements taken while the tree was removed. Nothing this lab counts reads a locale
# either way -- no .py file under /app, the agent's own sources or any installed
# dependency, so much as mentions setlocale, and CPython runs in UTF-8 mode under the C
# locale in both -- so this is not a fix for a counted failure. It is 364032 bytes spent
# so that a later locale-sensitive result is one less thing to have to rule out.
#
# /rootfs/usr/share/locale is still removed, and it is a different tree: message
# catalogues, the translations of program messages, which an image with no shell and no
# command-line tools has nothing to display. The archive above is the character and
# collation data the C library itself reads.
#
# /etc/passwd and /etc/group are written by hand with two entries and a nologin shell
# that does not exist in this root: uid 65532 needs a name for the tools that ask, and
# nothing here needs a login.
RUN dnf -y --installroot=/rootfs --releasever="$(rpm -q --qf '%{VERSION}' system-release)" --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        install python3.14 system-release ca-certificates \
    && dnf -y --installroot=/rootfs --releasever="$(rpm -q --qf '%{VERSION}' system-release)" --setopt=install_weak_deps=False --setopt=tsflags=nodocs upgrade \
    && rpm --root=/rootfs -e --nodeps bash coreutils $(rpm --root=/rootfs -q coreutils-common >/dev/null 2>&1 && echo coreutils-common) \
    && dnf -y --installroot=/rootfs --releasever="$(rpm -q --qf '%{VERSION}' system-release)" clean all \
    && rm -rf /rootfs/var/cache/* /rootfs/var/log/* /rootfs/var/lib/dnf /rootfs/etc/dnf /rootfs/etc/yum.repos.d \
    && rm -rf /rootfs/usr/share/man /rootfs/usr/share/doc /rootfs/usr/share/info /rootfs/usr/share/locale \
    && printf 'root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532::/nonexistent:/sbin/nologin\n' > /rootfs/etc/passwd \
    && printf 'root:x:0:\nnonroot:x:65532:\n' > /rootfs/etc/group \
    && rpm --root=/rootfs -qa | sort

FROM scratch

COPY --from=rootfs /rootfs /

# The same assertion as the builder's, on the root that actually ships, in exec form
# because there is no shell here to parse a command line. If these two ever disagree the
# venv was resolved against one interpreter and would run on another.
RUN ["/usr/bin/python3.14", "-c", "import sys; assert sys.version_info[:2] == (3, 14), sys.version"]

# Deliberately NO --chown: these stay owned by root with the default permissions,
# world-readable and not writable by uid 65532, which is the user the process runs as.
# The application cannot modify its own code or its own dependencies even if the root
# filesystem were writable. Nothing needs to write there: UV_COMPILE_BYTECODE=1 compiled
# the venv's bytecode at build time and PYTHONDONTWRITEBYTECODE=1 below stops the
# interpreter writing any more.
COPY --from=builder /app/.venv /app/.venv
COPY orchestrator /app/orchestrator

# PATH is written out in full rather than appended to: `scratch` inherits no environment,
# so there is no $PATH here to extend.
ENV PATH="/app/.venv/bin:/usr/bin" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# uid:gid 65532:65532 is the uid of the distroless static nonroot base that .ko.yaml pins
# for the Go images, so every workload of ours in the cluster runs as one uid.
USER 65532:65532
EXPOSE 8080

CMD ["opentelemetry-instrument", "python", "-m", "orchestrator.server"]
