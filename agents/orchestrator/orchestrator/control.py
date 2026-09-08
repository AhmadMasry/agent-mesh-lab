"""Receiver-side injection hooks.

An armed work item fails one delivery after the ingress ledger has already
counted it, which is what lets a later task tell an arrival apart from a
completed dispatch. There is no retry and no repetition here: take() returns a
mode once and disarms it, so one arming fires on exactly one delivery.
"""
from __future__ import annotations

import json
import threading

from starlette.requests import Request
from starlette.responses import JSONResponse, Response

# Answer 503 after the arrival line is written and before the A2A SDK sees the
# request.
MODE_HTTP503_BEFORE_DISPATCH = "http503-before-dispatch"
# Close the connection after the body has been read. Named here so the control
# endpoint can reject it with a reason: ASGI has no portable connection hijack,
# so this receiver cannot serve it.
MODE_CLOSE_AFTER_READ = "close-after-read"

SUPPORTED_MODES = (MODE_HTTP503_BEFORE_DISPATCH,)


class Injector:
    """Work items armed for one injection each."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._armed: dict[str, str] = {}

    def arm(self, mode: str, lwi: str) -> None:
        with self._lock:
            self._armed[lwi] = mode

    def take(self, lwi: str) -> str | None:
        """Return the mode armed for lwi and disarm it; None if nothing is armed.

        An empty work item never matches: the agent card fetch and any
        non-JSON-RPC delivery carry none.
        """
        if not lwi:
            return None
        with self._lock:
            return self._armed.pop(lwi, None)

    def reset(self) -> None:
        with self._lock:
            self._armed = {}

    async def handle_inject(self, request: Request) -> Response:
        try:
            body = json.loads(await request.body())
        except ValueError:
            return JSONResponse({"error": "invalid JSON"}, status_code=400)
        if not isinstance(body, dict):
            return JSONResponse({"error": "invalid JSON"}, status_code=400)
        mode = body.get("mode", "")
        lwi = body.get("lwi", "")
        if mode == MODE_CLOSE_AFTER_READ:
            return JSONResponse({"error": "close-after-read is not supported by this receiver"}, status_code=400)
        if mode not in SUPPORTED_MODES:
            return JSONResponse({"error": "unknown mode"}, status_code=400)
        if not isinstance(lwi, str) or not lwi:
            return JSONResponse({"error": "lwi is required"}, status_code=400)
        self.arm(mode, lwi)
        return Response(status_code=204)

    async def handle_reset(self, _request: Request) -> Response:
        self.reset()
        return Response(status_code=204)
