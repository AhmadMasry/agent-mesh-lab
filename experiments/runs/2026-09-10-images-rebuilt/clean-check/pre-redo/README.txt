The clean check of the FIRST rollout of this branch, kept as the record of what was
measured then: images built on digest-pinned bases, with a venv chown'd to 65532, no
OS-upgrade layer, the Go binaries on distroless Debian 12, and the ServiceAccount
token still mounted.
The findings entry cites the top-level clean check only -- the redo, taken after the
second rollout. Both read 1/1/1/1/1 per receiver with a completed Task, which is the
point of keeping this one.
