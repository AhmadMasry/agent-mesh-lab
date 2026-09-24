"""LEDGER_HEADERS: the pre-dispatch ingress ledger reads the request's headers.

Experiment C's open thread after C-10: which headers reach the application, and
does any caller identity arrive in one. The same setting name, values and fields
as the Go worker's (agents/worker/headers.go), so one setting reads the same on
both receivers:

  unset or empty   off: every ledger line is byte for byte what it was before
                   the setting existed
  on               the arrival line gains one key, "headers", written last:
                     names                  every header name that arrived,
                                            lower-cased, each once, sorted
                     values                 name -> value for the names on
                                            HEADER_VALUES_READ that arrived; a
                                            header sent more than once is joined
                                            with ", " in arrival order; always an
                                            object, empty when none arrived
                     authorization_present  whether an Authorization header
                                            arrived; its value is never recorded
                   the response line does not carry it
  anything else    the process stops at start (server.app_from_env raises
                   before the app exists)

The ASGI server hands the application every header in one list, Host included,
so the names here are what arrived on the wire; the Go worker puts back the three
net/http moves out of its header map to read the same list.
"""
from __future__ import annotations

from typing import Any, Iterable

LEDGER_HEADERS_ENV = "LEDGER_HEADERS"

# The headers whose VALUES are read; every other header is read by name only.
# The reasons are the Go worker's, header by header (headers.go,
# headerValuesRead): the addressed host, the client library, the orchestrator's
# own caller declaration, the forwarding records a proxy may add, and the header a
# proxy passes a client certificate on in. authorization is not on it: only its
# presence is read.
HEADER_VALUES_READ = (
    "host", "user-agent", "x-caller",
    "forwarded", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "x-real-ip", "via",
    "x-forwarded-client-cert",
)


def ledger_headers_from(value: str) -> bool:
    """The setting's value: False when empty, True for exactly "on", ValueError
    otherwise. Matched exactly: no trimming and no case folding."""
    if value == "":
        return False
    if value == "on":
        return True
    raise ValueError(f"{LEDGER_HEADERS_ENV}={value!r} is not a value this agent reads; want on, or empty for off")


def read_headers(raw: Iterable[tuple[bytes, bytes]]) -> dict[str, Any]:
    """The reading, from an ASGI scope's header list."""
    names: set[str] = set()
    values: dict[str, list[str]] = {}
    authorization = False
    for key, value in raw:
        name = key.decode("latin-1").lower()
        names.add(name)
        if name == "authorization":
            authorization = True
        elif name in HEADER_VALUES_READ:
            values.setdefault(name, []).append(value.decode("latin-1"))
    return {
        "names": sorted(names),
        # Sorted by name, which is the order the Go worker's encoder writes a map's
        # keys in, so the two receivers write the same bytes for the same headers.
        "values": {name: ", ".join(values[name]) for name in sorted(values)},
        "authorization_present": authorization,
    }
