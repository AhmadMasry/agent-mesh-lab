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
from datetime import datetime, timezone
from typing import Any, TextIO


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


def parse_ingress(*, method: str, path: str, headers: dict[str, str], remote: str, body: bytes) -> dict[str, Any]:
    """Build one ingress line. Tolerant: a body that does not parse still yields a line."""
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
        return line
    if method != "POST" or not body:
        line["method"] = f"{method} {path}"
    return line


class IngressMiddleware:
    """Pure ASGI middleware: reads and restores the body, writes the arrival
    line, serves the request, then writes the response line with the status.
    Never rejects. Paths in skip_paths (the readiness probe) are not ledgered."""

    def __init__(self, app, out: TextIO | None = None, skip_paths: tuple[str, ...] = ("/healthz",)) -> None:
        self.app = app
        self.writer = LineWriter(out)
        self.skip_paths = skip_paths

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path", "") in self.skip_paths:
            await self.app(scope, receive, send)
            return
        chunks: list[bytes] = []
        while True:
            message = await receive()
            if message["type"] == "http.request":
                chunks.append(message.get("body", b""))
                if not message.get("more_body", False):
                    break
            else:
                break
        body = b"".join(chunks)
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        client = scope.get("client") or ("", 0)
        line = parse_ingress(method=scope.get("method", ""), path=scope.get("path", ""), headers=headers,
                             remote=f"{client[0]}:{client[1]}", body=body)
        self.writer.write(line)
        status = {"code": 0}

        replayed = {"done": False}

        async def receive_replay():
            if not replayed["done"]:
                replayed["done"] = True
                return {"type": "http.request", "body": body, "more_body": False}
            return {"type": "http.disconnect"}

        async def send_capture(message):
            if message["type"] == "http.response.start":
                status["code"] = int(message.get("status", 0))
            await send(message)

        try:
            await self.app(scope, receive_replay, send_capture)
        finally:
            response = dict(line)
            response["phase"] = "response"
            response["status"] = status["code"]
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
