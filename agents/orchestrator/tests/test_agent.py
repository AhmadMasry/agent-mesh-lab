"""Executor behaviour through the real a2a-python request handler: model mode and forward mode."""
import io
import json
import uuid

import httpx
import pytest
from a2a.server.context import ServerCallContext
from a2a.types import Message, Part, Role, SendMessageRequest

from orchestrator.agent import build_handler
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
    assert len(_events(out, "dispatch")) == 1 and len(_events(out, "result")) == 1
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
    sends = [l for l in ingress if l["method"] == "SendMessage"]
    assert len(sends) == 1
    assert sends[0]["a2a_version"] == "1.0"
    assert sends[0]["logical_work_item_id"] == "w3"
    assert sends[0]["messageId"] and sends[0]["messageId"] != req.message.message_id
    assert forwarder.transport_retries == 0
