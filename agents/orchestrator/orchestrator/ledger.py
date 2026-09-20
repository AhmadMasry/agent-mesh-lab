"""Ledgers for the Python agent.

The ingress ledger records every physical HTTP delivery before the A2A SDK
sees it; the execution ledger records what the SDK dispatched and every Task
state the executor emits. Lines are JSON on stdout, one per event, with the
same field names as the Go worker's ledgers.
"""
from __future__ import annotations

import hashlib
import json
import sys
import threading
from contextvars import ContextVar
from datetime import datetime, timezone
from typing import Any, TextIO

from orchestrator.control import MODE_HTTP503_BEFORE_DISPATCH, Injector

# How a streamed response ended, as this boundary can observe it. complete and
# client-gone are the two the Go receiver also writes; send-failed is this
# receiver's counterpart to its write-failed, and incomplete is the case an ASGI
# application can produce and a net/http handler cannot: the application stopped
# without a final body message and without the client having gone away.
STREAM_END_COMPLETE = "complete"
STREAM_END_CLIENT_GONE = "client-gone"
STREAM_END_SEND_FAILED = "send-failed"
STREAM_END_INCOMPLETE = "incomplete"

SSE_CONTENT_TYPE = "text/event-stream"


class Delivery:
    """What the ASGI boundary observed about one delivery, readable by code
    further in.

    The ASGI server's http.disconnect is the authoritative word that the client
    went away, and only this middleware sees it: by the time a streamed request
    reaches the request handler, a disconnect has become an ended generator with
    no exception of any kind. The handler reads this object so its own ledger
    line can say a stream was cut rather than that it ran out.
    """

    __slots__ = ("client_gone",)

    def __init__(self) -> None:
        self.client_gone = False


_current_delivery: ContextVar[Delivery | None] = ContextVar("current_delivery", default=None)


def current_delivery() -> Delivery | None:
    """The Delivery of the request being served, or None outside one.

    The middleware sets it before the application is called, so every task the
    application starts inherits the same object; marking it is visible to all of
    them, which is what lets the disconnect reach the request handler.
    """
    return _current_delivery.get()


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


class LineWriter:
    """Serialises JSON lines to one stream; safe to share across tasks."""

    def __init__(self, out: TextIO | None = None) -> None:
        self._out = out or sys.stdout
        self._lock = threading.Lock()

    def write(self, line: dict[str, Any]) -> None:
        text = json.dumps(line, separators=(",", ":"))
        with self._lock:
            self._out.write(text + "\n")
            self._out.flush()


def work_item_of(metadata: Any) -> str:
    if isinstance(metadata, dict):
        v = metadata.get("logical_work_item_id")
        if isinstance(v, str):
            return v
    return ""


def _id_text(raw: Any) -> str:
    if raw is None:
        return ""
    if isinstance(raw, (bool, int, float)):
        return json.dumps(raw)
    return str(raw)


def parse_ingress(*, method: str, path: str, headers: dict[str, str], remote: str, body: bytes,
                  truncated: bool = False) -> dict[str, Any]:
    """Build one ingress line. Tolerant: a body that does not parse still yields a line.

    truncated says the client went away before the body was complete, so body,
    body_len and body_sha256 describe the bytes that arrived rather than the
    bytes that were sent. The field is written only when it is true, the way
    contextId and injection are, so a complete delivery's line is unchanged."""
    line: dict[str, Any] = {
        "ledger": "ingress",
        "phase": "arrival",
        "ts_arrival": now(),
        "remote": remote,
        "method": "",
        "id": "",
        "messageId": "",
        "taskId": "",
        "logical_work_item_id": "",
        "a2a_version": headers.get("a2a-version", ""),
        "content_type": headers.get("content-type", ""),
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "body_len": len(body),
    }
    if truncated:
        line["truncated"] = True
    env: Any = None
    if body:
        try:
            env = json.loads(body)
        except ValueError:
            env = None
    if isinstance(env, dict) and isinstance(env.get("method"), str) and env["method"]:
        line["method"] = env["method"]
        line["id"] = _id_text(env.get("id"))
        params = env.get("params") if isinstance(env.get("params"), dict) else {}
        message = params.get("message") if isinstance(params.get("message"), dict) else {}
        line["messageId"] = str(message.get("messageId") or message.get("message_id") or "")
        line["taskId"] = str(message.get("taskId") or params.get("id") or params.get("taskId") or "")
        if message.get("contextId"):
            line["contextId"] = str(message["contextId"])
        line["logical_work_item_id"] = work_item_of(message.get("metadata"))
        # Only a JSON-RPC delivery whose body carried no work item falls back to
        # the header, and it says so. A2A v1.0's SubscribeToTask carries no
        # Message and therefore no metadata (specification v1.0.1 §9.4.6), so the
        # header the load client puts on every request is the only identity it
        # can be collected by. A request that is not JSON-RPC — the agent card
        # fetch above all — keeps the empty work item it has always had, so what a
        # work item's collection contains does not change for any traffic that
        # existed before streaming was served.
        if not line["logical_work_item_id"]:
            from_header = headers.get("x-logical-work-item-id", "")
            if from_header:
                line["logical_work_item_id"] = from_header
                line["lwi_source"] = "header"
        return line
    if method != "POST" or not body:
        line["method"] = f"{method} {path}"
    return line


class IngressMiddleware:
    """Pure ASGI middleware: reads and restores the body, writes the arrival
    line, serves the request, then writes the response line with the status.
    It rejects a request only when the injector has an armed work item matching
    it, and then only after the delivery has been counted. Paths in skip_paths
    (the readiness probe and the control endpoints) are not ledgered."""

    def __init__(self, app, out: TextIO | None = None, skip_paths: tuple[str, ...] = ("/healthz",),
                 injector: Injector | None = None) -> None:
        self.app = app
        self.writer = LineWriter(out)
        self.skip_paths = skip_paths
        self.injector = injector

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path", "") in self.skip_paths:
            await self.app(scope, receive, send)
            return
        chunks: list[bytes] = []
        # Set when the client went away before the body was complete: an ASGI
        # server answers receive() with http.disconnect instead of the rest of
        # the body. What arrived is still a counted delivery, but it is not the
        # request the client meant to send, so the message that ended it is kept
        # rather than discarded, and both the ledger line and the application are
        # told. Treating it as end-of-body would hand a truncated body to the
        # application as a whole one and record its hash as if it were complete.
        disconnect: dict[str, Any] | None = None
        while True:
            message = await receive()
            if message["type"] == "http.request":
                chunks.append(message.get("body", b""))
                if not message.get("more_body", False):
                    break
            else:
                disconnect = message
                break
        body = b"".join(chunks)
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        client = scope.get("client") or ("", 0)
        line = parse_ingress(method=scope.get("method", ""), path=scope.get("path", ""), headers=headers,
                             remote=f"{client[0]}:{client[1]}", body=body, truncated=disconnect is not None)
        self.writer.write(line)

        # The arrival is on the ledger before this point, so an injected failure
        # is still a counted delivery. take disarms the work item, so one arming
        # fires once; nothing here repeats or retries.
        mode = self.injector.take(line["logical_work_item_id"]) if self.injector is not None else None
        if mode == MODE_HTTP503_BEFORE_DISPATCH:
            payload = b'{"error":"injected"}'
            await send({"type": "http.response.start", "status": 503, "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(payload)).encode("latin-1")),
            ]})
            await send({"type": "http.response.body", "body": payload})
            response = dict(line)
            response["phase"] = "response"
            response["status"] = 503
            response["injection"] = mode
            self.writer.write(response)
            return

        status = {"code": 0}

        # What this boundary saw of a streamed response. streamed is set from the
        # content type the application actually sent, so the ledger records the
        # response that left rather than the one the method name implies; the
        # other three are the observations stream_end is read from.
        seen: dict[str, bool] = {"streamed": False, "final_body": False, "client_gone": False,
                                 "send_failed": False}
        # Set before the application runs, so every task it starts inherits this
        # object and the request handler can read what this boundary saw.
        delivery = Delivery()
        _current_delivery.set(delivery)

        replayed = {"done": False}

        async def receive_replay():
            # The body was consumed here, so it is replayed once. Everything
            # after that is the real ASGI conversation: a streaming response
            # awaits receive() to watch for a client disconnect, and answering
            # that with a synthetic disconnect would cut the stream short.
            #
            # A body cut short is replayed as what it is. The bytes that arrived
            # go over with more_body True, so the application knows the body is
            # unfinished, and the message that ended the read follows, so the
            # application sees the disconnect it would have seen without this
            # middleware in the way. Every later call reports the disconnect
            # again, the way an ASGI server does once the client is gone, rather
            # than reaching for a receive that has nothing left to give.
            if not replayed["done"]:
                replayed["done"] = True
                return {"type": "http.request", "body": body, "more_body": disconnect is not None}
            if disconnect is not None:
                return disconnect
            # A streaming response awaits receive() to learn that the client
            # went away; that message is passed on untouched and noted, because
            # it is the one thing that says a stream ended at the client's end
            # and not at the agent's.
            message = await receive()
            if message["type"] == "http.disconnect":
                seen["client_gone"] = True
                delivery.client_gone = True
            return message

        async def send_capture(message):
            if message["type"] == "http.response.start":
                status["code"] = int(message.get("status", 0))
                for key, value in message.get("headers", []):
                    if key.decode("latin-1").lower() == "content-type":
                        seen["streamed"] = value.decode("latin-1").startswith(SSE_CONTENT_TYPE)
            try:
                await send(message)
            except BaseException:
                # The bytes did not leave. Recorded and re-raised: the ledger
                # says what happened, and nothing here turns a failed send into
                # a response the application thinks it sent.
                seen["send_failed"] = True
                raise
            if message["type"] == "http.response.body" and not message.get("more_body", False):
                seen["final_body"] = True

        def stream_end() -> str:
            # final_body is read before client_gone on purpose. sse-starlette
            # consumes an http.disconnect at the end of every request, so a
            # stream that was sent to its last byte reports both, and ranking
            # the disconnect first made a completed stream read client-gone with
            # the socket still open — a transport loss that never happened.
            # A response whose last body message went out is complete whatever
            # the client did afterwards.
            if seen["send_failed"]:
                return STREAM_END_SEND_FAILED
            if seen["final_body"]:
                return STREAM_END_COMPLETE
            if seen["client_gone"]:
                return STREAM_END_CLIENT_GONE
            return STREAM_END_INCOMPLETE

        try:
            await self.app(scope, receive_replay, send_capture)
        finally:
            # status is 0 when no http.response.start was sent, which is what a
            # truncated delivery's response line carries: the application raised on
            # the disconnect before it could answer. It is 0 for any application
            # exception raised that early, so it means "no status was sent" rather
            # than "the client went away"; truncated on the same line is what says
            # which. Counted alongside truncated: true in
            # test_receive_replay_passes_a_mid_body_disconnect_through.
            response = dict(line)
            response["phase"] = "response"
            response["status"] = status["code"]
            # A streamed response's line is written when the stream ended, which
            # ts_arrival cannot say; ts_end is that stamp, and stream_end says
            # how it ended. A unary response's line carries neither, so its
            # shape is what it was before streaming was served at all.
            if seen["streamed"]:
                response["ts_end"] = now()
                response["stream_end"] = stream_end()
            self.writer.write(response)


def execution_line(event: str, *, method: str = "", message_id: str = "", task_id: str = "",
                   context_id: str = "", work_item: str = "", result_kind: str = "", state: str = "",
                   error: str = "") -> dict[str, Any]:
    line: dict[str, Any] = {"ledger": "execution", "ts": now(), "event": event}
    if method:
        line["method"] = method
    line.update({"messageId": message_id, "taskId": task_id})
    if context_id:
        line["contextId"] = context_id
    line["logical_work_item_id"] = work_item
    if result_kind:
        line["result_kind"] = result_kind
    if state:
        line["state"] = state
    if error:
        line["error"] = error
    return line
