"""Model client: one chat-completions call with the four identity headers, no retry path."""
import json

import httpx2
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from orchestrator.model import Identity, ModelClient

COMPLETION = {
    "id": "chatcmpl-x", "object": "chat.completion", "created": 1, "model": "mock",
    "choices": [{"index": 0, "message": {"role": "assistant", "content": "the fixed answer"}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
}


class FakeModel:
    """In-process OpenAI-compatible endpoint that counts calls and records headers."""

    def __init__(self, status: int = 200) -> None:
        self.status = status
        self.calls = 0
        self.headers: list[dict[str, str]] = []
        self.bodies: list[dict] = []
        self.app = Starlette(routes=[Route("/v1/chat/completions", self.handle, methods=["POST"])])

    async def handle(self, request: Request) -> Response:
        self.calls += 1
        self.headers.append({k.lower(): v for k, v in request.headers.items()})
        self.bodies.append(json.loads(await request.body()))
        if self.status != 200:
            return Response(status_code=self.status)
        return JSONResponse(COMPLETION)

    def client(self, retries: int = 0) -> ModelClient:
        http = httpx2.AsyncClient(transport=httpx2.ASGITransport(app=self.app), base_url="http://fake")
        return ModelClient(base_url="http://fake/v1", model="mock", api_key="unused", max_retries=retries, http_client=http)


@pytest.mark.asyncio
async def test_complete_sends_identity_headers_and_returns_text():
    fake = FakeModel()
    text = await fake.client().complete(Identity(work_item="w1", message_id="m1", task_id="t1", caller="orchestrator"), "lwi:w1 hi")
    assert text == "the fixed answer"
    h = fake.headers[0]
    assert h["x-logical-work-item-id"] == "w1" and h["x-a2a-message-id"] == "m1"
    assert h["x-a2a-task-id"] == "t1" and h["x-caller"] == "orchestrator"
    assert h["authorization"] == "Bearer unused"
    assert fake.bodies[0]["model"] == "mock" and not fake.bodies[0].get("stream")


@pytest.mark.asyncio
async def test_complete_does_not_retry_on_500_when_max_retries_is_zero():
    fake = FakeModel(status=500)
    with pytest.raises(Exception):
        await fake.client(retries=0).complete(Identity(work_item="w1"), "x")
    assert fake.calls == 1


@pytest.mark.asyncio
async def test_control_openai_default_retries_do_retry_on_500():
    """Positive control for Task 6: with the openai client's documented default, retries happen."""
    fake = FakeModel(status=500)
    with pytest.raises(Exception):
        await fake.client(retries=2).complete(Identity(work_item="w1"), "x")
    assert fake.calls == 3


def test_default_transport_has_connection_retries_disabled():
    mc = ModelClient(base_url="http://fake/v1", model="mock", api_key="unused")
    assert mc.max_retries == 0
    assert mc.transport_retries == 0
