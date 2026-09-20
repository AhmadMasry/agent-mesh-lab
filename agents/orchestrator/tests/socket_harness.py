"""A real transport for the Python receiver's tests.

Every other test in this project drives the ASGI app with a hand-written
receive/send pair, or the request handler in process. Neither carries the two
things a streamed request's ledger lines are read from: the ASGI server's own
disconnect message, and sse-starlette's response lifecycle. This harness serves
the app with the same uvicorn the image runs and talks to it over a socket the
test opens and closes itself, so a cut is a cut.

It adds no dependency: uvicorn is already the orchestrator's server.
"""
from __future__ import annotations

import asyncio
import io
import json
import socket
import struct
import threading
import time
from typing import Any

import uvicorn

from orchestrator.server import SERVER_SETTINGS
from tests.test_model import FakeModel


class ServedApp:
    """Serves an ASGI app on a loopback port for the life of a with-block."""

    def __init__(self, app: Any) -> None:
        # The same arguments server.py serves this agent with, so a setting that
        # matters cannot drift away from what the tests measure. Only the
        # binding is the harness's own: a loopback port the kernel chooses.
        config = uvicorn.Config(app, host="127.0.0.1", port=0, lifespan="off", **SERVER_SETTINGS)
        self._server = uvicorn.Server(config)
        self._thread = threading.Thread(target=self._server.run, daemon=True)
        self.port = 0

    def __enter__(self) -> ServedApp:
        self._thread.start()
        deadline = time.monotonic() + 15
        while not self._server.started:
            if time.monotonic() > deadline:
                raise RuntimeError("uvicorn did not start")
            time.sleep(0.01)
        self.port = self._server.servers[0].sockets[0].getsockname()[1]
        return self

    def __exit__(self, *_: object) -> None:
        self._server.should_exit = True
        self._thread.join(timeout=15)


class StreamClient:
    """One request on one socket the test controls.

    The events are read as they arrive and the socket is closed when the test
    says so, which is the only way to produce the disconnect the middleware and
    sse-starlette both read. Nothing here retries, resends or reconnects.
    """

    def __init__(self, port: int, body: str, headers: str = "") -> None:
        self._sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        request = (f"POST / HTTP/1.1\r\nHost: orchestrator\r\nContent-Type: application/json\r\n"
                   f"{headers}Content-Length: {len(body)}\r\n\r\n{body}")
        self._sock.sendall(request.encode("utf-8"))
        self._buffer = b""

    def _read_line(self) -> bytes:
        while b"\n" not in self._buffer:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise EOFError("the server closed the connection")
            self._buffer += chunk
        line, _, self._buffer = self._buffer.partition(b"\n")
        return line

    def status_line(self) -> str:
        return self._read_line().decode("latin-1").strip()

    def next_event(self) -> dict[str, Any]:
        """Return the JSON payload of the next SSE data block."""
        while True:
            line = self._read_line().decode("utf-8").strip()
            if line.startswith("data:"):
                return json.loads(line[len("data:"):].strip())

    def read_unary_response(self) -> tuple[str, str]:
        """Read a whole non-streamed answer: its status line and its body.

        The body is read by Content-Length rather than to end-of-file, because
        this server keeps the connection alive and an answer that is not a
        stream would otherwise be read until the socket timed out.
        """
        status = self.status_line()
        length = 0
        while True:
            header = self._read_line().decode("latin-1").strip()
            if not header:
                break
            name, _, value = header.partition(":")
            if name.strip().lower() == "content-length":
                length = int(value.strip())
        while len(self._buffer) < length:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise EOFError("the server closed the connection mid-body")
            self._buffer += chunk
        body, self._buffer = self._buffer[:length], self._buffer[length:]
        return status, body.decode("utf-8")

    def close(self, reset: bool = False) -> None:
        if reset:
            # A zero linger makes close send a reset instead of a FIN.
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self._sock.close()


class HeldModel(FakeModel):
    """A model endpoint that holds its answer until the test releases it.

    The server runs in another thread with its own event loop, so the gate is a
    threading.Event polled from the coroutine: an asyncio one could only be set
    from the loop that owns it. entries counts calls as they arrive, where
    FakeModel.calls counts them as they are answered.
    """

    def __init__(self) -> None:
        super().__init__()
        self._gate = threading.Event()
        self._entered = threading.Event()
        self.entries = 0

    async def handle(self, request: Any) -> Any:
        self.entries += 1
        self._entered.set()
        while not self._gate.is_set():
            await asyncio.sleep(0.01)
        return await super().handle(request)

    def wait_until_called(self, timeout: float = 15.0) -> None:
        if not self._entered.wait(timeout):
            raise AssertionError("the model was never called")

    def release(self) -> None:
        self._gate.set()


def lines(out: io.StringIO) -> list[dict[str, Any]]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def wait_for(out: io.StringIO, predicate, what: str, timeout: float = 15.0) -> list[dict[str, Any]]:
    """Poll the ledger until it has the shape the test is waiting for.

    The later lines of a streamed request are written after the client is gone,
    by the server's own task, so a test that read once would race them.
    """
    deadline = time.monotonic() + timeout
    while True:
        current = lines(out)
        if predicate(current):
            return current
        if time.monotonic() > deadline:
            raise AssertionError(f"the ledger never reached {what}: {out.getvalue()}")
        time.sleep(0.02)


def ledger(out: io.StringIO, ledger_name: str, **match: Any) -> list[dict[str, Any]]:
    """Select ledger lines by name and by any field the caller names."""
    return [line for line in lines(out)
            if line.get("ledger") == ledger_name and all(line.get(k) == v for k, v in match.items())]
