"""The execution ledger on a streamed request, and the card that lets one in."""
import asyncio
import io
import json
import uuid

import pytest
from a2a.server.context import ServerCallContext
from a2a.types import Message, Part, Role, SendMessageRequest
from starlette.testclient import TestClient

from orchestrator.agent import build_handler
from orchestrator.server import build_app
from tests.test_model import FakeModel


def _request(lwi: str) -> SendMessageRequest:
    msg = Message(message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text=f"lwi:{lwi} hello")],
                  metadata={"logical_work_item_id": lwi})
    return SendMessageRequest(message=msg)


def _events(out: io.StringIO, kind: str) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines()
            if line.strip() and json.loads(line).get("event") == kind]


class BlockingModel(FakeModel):
    """A model that holds its answer until the test releases it."""

    def __init__(self) -> None:
        super().__init__()
        self.called = asyncio.Event()
        self.release = asyncio.Event()

    async def handle(self, request):
        self.called.set()
        await self.release.wait()
        return await super().handle(request)


@pytest.mark.asyncio
async def test_streamed_send_records_what_was_delivered():
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    seen = 0
    async for _ in handler.on_message_send_stream(_request("w-stream"), ServerCallContext()):
        seen += 1

    received, delivered, result = _events(out, "received"), _events(out, "delivered"), _events(out, "result")
    assert len(received) == 1 and received[0]["method"] == "SendStreamingMessage"
    assert len(delivered) == seen, "one delivered line per event the caller saw"
    assert delivered[0]["result_kind"] == "task" and delivered[0]["taskId"]
    assert len(result) == 1 and result[0]["stream_end"] == "complete"
    # The executor writes the Task's state lines from inside its own task. A
    # wrapper that wrote them too would count every transition twice as soon as
    # a second stream read the same task.
    assert [line["state"] for line in _events(out, "state")] == [
        "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"]


@pytest.mark.asyncio
async def test_stream_cut_by_the_consumer_records_consumer_gone():
    """Closing the generator is what a consumer that went away does to this
    chain. Until the result line moved into a finally, a cut stream wrote none."""
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    stream = handler.on_message_send_stream(_request("w-cut"), ServerCallContext())
    await stream.__anext__()
    await stream.aclose()  # the cut: nothing here reconnects or re-sends

    result = _events(out, "result")
    assert len(result) == 1, "a cut stream left no result line"
    assert result[0]["stream_end"] == "consumer-gone"
    assert len(_events(out, "delivered")) == 1


@pytest.mark.asyncio
async def test_unary_send_is_unchanged():
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    await handler.on_message_send(_request("w-unary"), ServerCallContext())
    assert _events(out, "delivered") == []
    result = _events(out, "result")
    assert len(result) == 1 and "stream_end" not in result[0]


def test_card_declares_streaming():
    """Read back the way a client reads it: over HTTP, from the SDK's own route."""
    app = build_app(name="orchestrator", model=FakeModel().client(), forwarder=None, out=io.StringIO(),
                    public_url="http://orchestrator")
    with TestClient(app) as client:
        card = client.get("/.well-known/agent-card.json")
    assert card.status_code == 200, card.text
    assert card.json()["capabilities"]["streaming"] is True


@pytest.mark.asyncio
async def test_task_continues_after_the_consumer_is_gone():
    """The stream is cut while the model call is in flight. The Task is then
    counted to completion from the executor's own state lines, not inferred from
    a stream that stopped."""
    out = io.StringIO()
    model = BlockingModel()
    handler = build_handler(name="orchestrator", model=model.client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    stream = handler.on_message_send_stream(_request("w-continue"), ServerCallContext())
    await stream.__anext__()
    await asyncio.wait_for(model.called.wait(), timeout=10)

    await stream.aclose()  # the cut, with the model call in flight
    assert _events(out, "result")[0]["stream_end"] == "consumer-gone"

    model.release.set()
    for _ in range(1000):
        if [line for line in _events(out, "state") if line["state"] == "TASK_STATE_COMPLETED"]:
            break
        await asyncio.sleep(0.01)

    states = [line["state"] for line in _events(out, "state")]
    assert states == ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"], states
    # One dispatch, one model call: the cut stream started nothing again.
    assert len(_events(out, "execute")) == 1
    assert model.calls == 1
