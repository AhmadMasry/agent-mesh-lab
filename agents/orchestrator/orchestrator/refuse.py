"""REFUSE_OPERATION: the one A2A operation this agent refuses in the application.

Experiment C, step C-10. The same setting name and values as the Go worker's
(agents/worker/refuse.go), so one setting reads the same on both receivers:

  unset or empty   off: nothing is refused
  SendMessage, SendStreamingMessage, SubscribeToTask
                   that operation is refused inside the lab's request handler,
                   after its execution ledger's "received" line and before the
                   SDK's handler is called; every other operation is served as
                   with the setting off
  anything else    the process stops at start (server.app_from_env raises
                   before the app exists), so a typo or another operation's
                   name cannot leave the agent serving what a run meant to
                   refuse

a2a-python 1.1.4 has no server-side interceptor ("interceptor" occurs 0 times in
its JSON-RPC dispatcher and request handler), so the hook is the request
handler's per-operation method. The three are the ones LedgerRequestHandler
wraps; any other operation's name is refused as a value, because no wrapper of
this agent would refuse it.
"""
from __future__ import annotations

from a2a.utils.errors import UnsupportedOperationError

REFUSE_OPERATION_ENV = "REFUSE_OPERATION"
REFUSABLE_OPERATIONS = ("SendMessage", "SendStreamingMessage", "SubscribeToTask")


def refuse_operation_from(value: str) -> str:
    """The setting's value: "" when off, the operation's name when it is one this
    agent can refuse; ValueError otherwise. Matched exactly: no trimming and no
    case folding, as the operation name on the wire is matched exactly."""
    if value == "":
        return ""
    if value in REFUSABLE_OPERATIONS:
        return value
    raise ValueError(f"{REFUSE_OPERATION_ENV}={value!r} is not an operation this agent can refuse; "
                     f"want one of {list(REFUSABLE_OPERATIONS)}, or empty for off")


def refusal(operation: str) -> UnsupportedOperationError:
    """The error a refused request gets: UnsupportedOperationError, -32004 on the
    JSON-RPC binding (A2A specification at 3303592, l.558 and l.1185), with the
    same text the Go worker's refusal carries."""
    return UnsupportedOperationError(
        message=f"this operation is not supported: {operation} is refused by this agent ({REFUSE_OPERATION_ENV})")
