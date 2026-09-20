"""The execution ledger on a streamed request, and the card that lets one in."""
import asyncio
import io
import json
import uuid

import pytest
from a2a.server.context import ServerCallContext
from a2a.types import Message, Part, Role, SendMessageRequest, SubscribeToTaskRequest, Task
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
    """A model that holds its answer until the test releases it. entries counts
    calls as they arrive, where FakeModel.calls counts them as they are
    answered, so a call still in flight is countable."""

    def __init__(self) -> None:
        super().__init__()
        self.entries = 0
        self.called = asyncio.Event()
        self.release = asyncio.Event()

    async def handle(self, request):
        self.entries += 1
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
    # The state on a streamed result line is the submitted Task the stream opened
    # with, not the task's final state: a Task object is sent once and the
    # transitions after it are status updates. A reader that wants the final state
    # reads the executor's state lines.
    assert result[0]["state"] == "TASK_STATE_SUBMITTED"
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
    # No exception was raised, so the line carries no error string: the same
    # shape the Go receiver writes for a cut stream.
    assert "error" not in result[0]
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
async def test_subscribe_to_task_is_a_counted_arrival_and_reattaches_to_the_running_task():
    """The shape B needs: a stream is cut mid-flight and one SubscribeToTask
    names the task it left."""
    out = io.StringIO()
    model = BlockingModel()
    handler = build_handler(name="orchestrator", model=model.client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    stream = handler.on_message_send_stream(_request("w-resub"), ServerCallContext())
    first = await stream.__anext__()
    task_id = first.id
    await asyncio.wait_for(model.called.wait(), timeout=10)
    await stream.aclose()  # the cut

    resub = handler.on_subscribe_to_task(SubscribeToTaskRequest(id=task_id), ServerCallContext())
    answered = await resub.__anext__()
    assert isinstance(answered, Task) and answered.id == task_id

    received = _events(out, "received")
    assert len(received) == 2 and received[1]["method"] == "SubscribeToTask"
    assert received[1]["taskId"] == task_id
    # The request carries no Message, so the line claims no messageId, no
    # contextId and no work item (specification v1.0.1 §9.4.6).
    assert received[1]["messageId"] == "" and received[1]["logical_work_item_id"] == ""
    assert "contextId" not in received[1]
    # What the server answered first.
    delivered_after = [line for line in _events(out, "delivered") if line["method"] == "SubscribeToTask"]
    assert delivered_after and delivered_after[0]["result_kind"] == "task"
    assert delivered_after[0]["taskId"] == task_id
    # A resubscription starts no execution and no second model call.
    assert len(_events(out, "execute")) == 1
    assert model.entries == 1

    model.release.set()
    await resub.aclose()


@pytest.mark.asyncio
async def test_subscribe_to_a_finished_task_is_still_recorded():
    """Whatever the SDK answers, the ledger holds the arrival and the answer.
    What a2a-sdk 1.1.4 answers for a finished task is a cluster row of its own
    (B-3); here the assertion is that the delivery is not lost."""
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    task_id = ""
    async for event in handler.on_message_send_stream(_request("w-done"), ServerCallContext()):
        if isinstance(event, Task):
            task_id = event.id
    assert task_id

    answer = None
    with pytest.raises(Exception) as raised:  # noqa: PT011 - the SDK's own error is the subject
        async for event in handler.on_subscribe_to_task(SubscribeToTaskRequest(id=task_id), ServerCallContext()):
            answer = event

    received = _events(out, "received")
    assert len(received) == 2 and received[1]["method"] == "SubscribeToTask"
    result = _events(out, "result")
    assert len(result) == 2 and result[1]["error"]
    # The ending is the server's error, not a lost transport: this consumer was
    # still reading when the SDK raised. The Go receiver records the same ending
    # by the same name for its own refusal of a finished task.
    assert result[1]["stream_end"] == "error"
    assert answer is None, "the SDK yielded nothing before it raised"
    # The text comes from ActiveTask.subscribe (a2a-sdk 1.1.4,
    # server/agent_execution/active_task.py l.625-627), which raises when the
    # ActiveTask is still registered and finished. The other path, an evicted
    # task re-created by get_or_create and then started, raises "... is already
    # completed. Cannot start it again." at l.443-445.
    print(f"a2a-sdk 1.1.4 answered a resubscription to a finished task with: "
          f"{type(raised.value).__name__}: {raised.value}")


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
    assert model.entries == 1
