"""Executor behaviour through the real a2a-python request handler: model mode and forward mode."""
import io
import json
import uuid

import httpx
import pytest
from a2a.server.agent_execution import RequestContext
from a2a.server.context import ServerCallContext
from a2a.server.events import EventQueue
from a2a.types import Message, Part, Role, SendMessageRequest

from orchestrator.agent import LabExecutor, build_handler
from orchestrator.forward import Forwarder
from orchestrator.ledger import LineWriter
from orchestrator.server import build_app
from tests.test_model import FakeModel


def _request(lwi: str, text: str = "hello") -> SendMessageRequest:
    msg = Message(message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text=f"lwi:{lwi} {text}")],
                  metadata={"logical_work_item_id": lwi})
    return SendMessageRequest(message=msg)


def _states(out: io.StringIO) -> list[str]:
    return [json.loads(l)["state"] for l in out.getvalue().splitlines() if l.strip() and json.loads(l).get("event") == "state"]


def _events(out: io.StringIO, kind: str) -> list[dict]:
    return [json.loads(l) for l in out.getvalue().splitlines() if l.strip() and json.loads(l).get("event") == kind]


def _lines(out: io.StringIO) -> list[dict]:
    return [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]


class RecordingQueue(EventQueue):
    """The SDK's queue interface has one abstract method; record what the executor emits."""

    def __init__(self) -> None:
        self.events: list = []

    async def enqueue_event(self, event) -> None:
        self.events.append(event)


# "Dispatched" must mean the executor ran, so the executor writes its own entry
# line before the first Task state it emits. Driving the executor directly keeps
# the assertion about what the executor wrote, not the handler's lines around it.
@pytest.mark.asyncio
async def test_execute_writes_execute_line_before_submitted_state():
    out = io.StringIO()
    fake = FakeModel()
    executor = LabExecutor(name="orchestrator", model=fake.client(), forwarder=None, writer=LineWriter(out))
    req = _request("w-exec")
    ctx = RequestContext(request=req, task_id="t-exec", context_id="c-exec", call_context=ServerCallContext())
    await executor.execute(ctx, RecordingQueue())

    lines = _lines(out)
    assert lines, "the executor wrote no ledger lines"
    assert lines[0]["event"] == "execute", lines
    assert lines[0]["messageId"] == req.message.message_id
    assert lines[0]["taskId"] == "t-exec" and lines[0]["contextId"] == "c-exec"
    assert lines[0]["logical_work_item_id"] == "w-exec"
    assert lines[1]["event"] == "state" and lines[1]["state"] == "TASK_STATE_SUBMITTED"
    assert len(_events(out, "execute")) == 1
    assert fake.calls == 1


# The handler's entry line says the SDK accepted a request, so it is named
# "received"; "dispatched" is now the executor's own "execute" line.
@pytest.mark.asyncio
async def test_request_handler_writes_received_not_dispatch():
    fake = FakeModel()
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=fake.client(), forwarder=None, out=out,
                            public_url="http://orchestrator")
    await handler.on_message_send(_request("w-received"), ServerCallContext())
    assert len(_events(out, "received")) == 1
    assert _events(out, "dispatch") == []
    received = _events(out, "received")[0]
    assert received["method"] == "SendMessage" and received["logical_work_item_id"] == "w-received"
    assert _lines(out)[0]["event"] == "received"


@pytest.mark.asyncio
async def test_model_mode_completes_task_with_model_text_and_records_states():
    fake = FakeModel()
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=fake.client(), forwarder=None, out=out,
                            public_url="http://orchestrator.lab.svc.cluster.local:8080")
    req = _request("w1")
    task = await handler.on_message_send(req, ServerCallContext())
    from a2a.types import TaskState
    assert task.status.state == TaskState.TASK_STATE_COMPLETED
    assert task.artifacts and task.artifacts[0].parts[0].text == "the fixed answer"
    assert fake.calls == 1
    h = fake.headers[0]
    assert h["x-a2a-task-id"] == task.id and h["x-a2a-message-id"] == req.message.message_id
    assert h["x-logical-work-item-id"] == "w1" and h["x-caller"] == "orchestrator"
    assert _states(out) == ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"]
    assert len(_events(out, "received")) == 1 and len(_events(out, "result")) == 1
    assert _events(out, "result")[0]["result_kind"] == "task" and _events(out, "result")[0]["taskId"] == task.id


@pytest.mark.asyncio
async def test_model_mode_fails_task_on_model_error_without_retry():
    from a2a.types import TaskState
    fake = FakeModel(status=500)
    out = io.StringIO()
    handler = build_handler(name="orchestrator", model=fake.client(), forwarder=None, out=out,
                            public_url="http://orchestrator.lab.svc.cluster.local:8080")
    task = await handler.on_message_send(_request("w2"), ServerCallContext())
    assert task.status.state == TaskState.TASK_STATE_FAILED
    assert task.status.message.parts[0].text
    assert fake.calls == 1
    assert _states(out) == ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_FAILED"]


@pytest.mark.asyncio
async def test_forward_mode_sends_one_downstream_message_with_new_id_and_same_work_item():
    from a2a.types import TaskState
    # Downstream: a model-mode agent app, reachable in-process over ASGI.
    fake = FakeModel()
    down_out = io.StringIO()
    downstream = build_app(name="worker", model=fake.client(), forwarder=None, out=down_out,
                           public_url="http://downstream")
    down_http = httpx.AsyncClient(transport=httpx.ASGITransport(app=downstream), base_url="http://downstream",
                                  headers={"X-Caller": "orchestrator"})
    forwarder = Forwarder(url="http://downstream", http_client=down_http)

    up_out = io.StringIO()
    handler = build_handler(name="orchestrator", model=None, forwarder=forwarder, out=up_out,
                            public_url="http://orchestrator")
    req = _request("w3")
    task = await handler.on_message_send(req, ServerCallContext())
    assert task.status.state == TaskState.TASK_STATE_COMPLETED
    assert task.artifacts[0].parts[0].text == "the fixed answer"
    assert fake.calls == 1

    ingress = [json.loads(l) for l in down_out.getvalue().splitlines() if '"ledger":"ingress"' in l]
    sends = [l for l in ingress if l["method"] == "SendMessage" and l["phase"] == "arrival"]
    assert len(sends) == 1
    assert sends[0]["a2a_version"] == "1.0"
    assert sends[0]["logical_work_item_id"] == "w3"
    assert sends[0]["messageId"] and sends[0]["messageId"] != req.message.message_id
    assert forwarder.transport_retries == 0


@pytest.mark.asyncio
async def test_forward_mode_with_plan_call_makes_one_model_call_then_forwards():
    from a2a.types import TaskState
    fake = FakeModel()
    down_out = io.StringIO()
    downstream = build_app(name="worker", model=fake.client(), forwarder=None, out=down_out, public_url="http://downstream")
    down_http = httpx.AsyncClient(transport=httpx.ASGITransport(app=downstream), base_url="http://downstream")
    forwarder = Forwarder(url="http://downstream", http_client=down_http)
    up_out = io.StringIO()
    handler = build_handler(name="orchestrator", model=fake.client(), forwarder=forwarder, out=up_out,
                            public_url="http://orchestrator", plan_model_call=True)
    task = await handler.on_message_send(_request("w4"), ServerCallContext())
    assert task.status.state == TaskState.TASK_STATE_COMPLETED
    callers = [h["x-caller"] for h in fake.headers]
    assert callers == ["orchestrator", "worker"], callers


@pytest.mark.asyncio
async def test_forward_mode_fails_when_downstream_task_fails_without_retry():
    from a2a.types import TaskState
    fake = FakeModel(status=500)  # downstream's model fails, so the downstream Task fails
    down_out = io.StringIO()
    downstream = build_app(name="worker", model=fake.client(), forwarder=None, out=down_out, public_url="http://downstream")
    down_http = httpx.AsyncClient(transport=httpx.ASGITransport(app=downstream), base_url="http://downstream")
    forwarder = Forwarder(url="http://downstream", http_client=down_http)
    up_out = io.StringIO()
    handler = build_handler(name="orchestrator", model=None, forwarder=forwarder, out=up_out, public_url="http://orchestrator")
    task = await handler.on_message_send(_request("w5"), ServerCallContext())
    assert task.status.state == TaskState.TASK_STATE_FAILED
    assert "TASK_STATE_FAILED" in task.status.message.parts[0].text
    assert fake.calls == 1
    downstream_sends = [l for l in down_out.getvalue().splitlines() if '"method":"SendMessage"' in l and '"ledger":"ingress"' in l and '"phase":"arrival"' in l]
    assert len(downstream_sends) == 1


@pytest.mark.asyncio
async def test_plan_call_failure_fails_task_without_forwarding():
    from a2a.types import TaskState
    fake = FakeModel(status=500)
    down_out = io.StringIO()
    downstream = build_app(name="worker", model=FakeModel().client(), forwarder=None, out=down_out, public_url="http://downstream")
    down_http = httpx.AsyncClient(transport=httpx.ASGITransport(app=downstream), base_url="http://downstream")
    forwarder = Forwarder(url="http://downstream", http_client=down_http)
    handler = build_handler(name="orchestrator", model=fake.client(), forwarder=forwarder, out=io.StringIO(),
                            public_url="http://orchestrator", plan_model_call=True)
    task = await handler.on_message_send(_request("w6"), ServerCallContext())
    assert task.status.state == TaskState.TASK_STATE_FAILED
    assert fake.calls == 1
    assert '"method":"SendMessage"' not in down_out.getvalue()


@pytest.mark.asyncio
async def test_cancel_emits_canceled_state():
    from a2a.types import TaskState, TaskStatusUpdateEvent

    out = io.StringIO()
    executor = LabExecutor(name="orchestrator", model=FakeModel().client(), forwarder=None, writer=LineWriter(out))
    queue = RecordingQueue()
    ctx = RequestContext(request=_request("w7"), task_id="t-cancel", context_id="c-cancel", call_context=ServerCallContext())
    await executor.cancel(ctx, queue)
    assert '"state":"TASK_STATE_CANCELED"' in out.getvalue()
    assert len(queue.events) == 1 and isinstance(queue.events[0], TaskStatusUpdateEvent)
    assert queue.events[0].status.state == TaskState.TASK_STATE_CANCELED
