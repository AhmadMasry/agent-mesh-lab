"""The Python receiver's ingress ledger over a real transport.

Every assertion here runs through uvicorn and sse-starlette with a socket the
test opens and closes itself, because that is the only way the signals a
streamed request's lines are read from actually occur: the ASGI server's
http.disconnect and sse-starlette's response lifecycle. The in-process tests
beside this file can produce neither.
"""
import io

from a2a.server.agent_execution import AgentExecutor
from a2a.server.request_handlers import DefaultRequestHandler  # noqa: F401  (the alias the handler subclasses)
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import Task, TaskState, TaskStatus
from starlette.applications import Starlette

from orchestrator.agent import LedgerRequestHandler, build_card
from orchestrator.ledger import IngressMiddleware, LineWriter
from orchestrator.server import build_app
from tests.socket_harness import HeldModel, ServedApp, StreamClient, ledger, wait_for
from tests.test_model import FakeModel

# The A2A-Version header is not decoration here: without it this SDK answers
# "A2A version '0.3' is not supported by this handler" as JSON-RPC error -32009
# and nothing streams at all (measured through this harness).
#
# The two receivers differ on this, which a later stimulus has to know. a2a-go
# v2.5.0 serves a streamed request that carries no A2A-Version at all — the Go
# tests in agents/worker send none, the ingress line's a2a_version reads empty
# and the stream delivers — where a2a-sdk 1.1.4 refuses it outright. The
# committed clients are safe (the load client asserts it sends the version its
# card names, the replay harness sets it), but a hand-rolled stimulus that
# forgot the header would produce a working Go arm and zero Python dispatches,
# and the difference would look like a receiver that lost its traffic. Rule 7
# asks for the version each SDK negotiates to be captured from a real request;
# this is that capture for the header's absence.
A2A_HEADERS = "A2A-Version: 1.0\r\n"

STREAM_BODY = ('{"jsonrpc":"2.0","method":"SendStreamingMessage","params":{"message":'
               '{"messageId":"m-socket","metadata":{"logical_work_item_id":"w-socket"},'
               '"parts":[{"text":"lwi:w-socket hello"}],"role":"ROLE_USER"}},"id":"rpc-1"}')


def app_for(out: io.StringIO, model=None):
    return build_app(name="orchestrator", model=(model or FakeModel()).client(), forwarder=None, out=out,
                     public_url="http://orchestrator")


def state_of(event: dict) -> str:
    """The Task state an SSE payload carries, if it carries one. a2a-sdk 1.1.4
    names the event inside the result: task, statusUpdate or artifactUpdate."""
    result = event.get("result", {})
    for key in ("task", "statusUpdate"):
        status = (result.get(key) or {}).get("status") or {}
        if status.get("state"):
            return status["state"]
    return ""


def response_lines(out: io.StringIO) -> list[dict]:
    return ledger(out, "ingress", phase="response")


def test_clean_stream_reads_complete_at_the_ingress_ledger():
    """The client reads every event, then closes.

    sse-starlette consumes an http.disconnect at the end of every request, so
    with the disconnect ranked ahead of the final body this line read
    client-gone for a stream that was sent to its last byte.
    """
    out = io.StringIO()
    with ServedApp(app_for(out)) as served:
        client = StreamClient(served.port, STREAM_BODY, headers=A2A_HEADERS)
        assert client.status_line().startswith("HTTP/1.1 200")
        states = []
        while "TASK_STATE_COMPLETED" not in states:
            states.append(state_of(client.next_event()))
        client.close()
        wait_for(out, lambda _: bool(response_lines(out)), "an ingress response line")

    response = response_lines(out)[0]
    assert response["stream_end"] == "complete", response
    assert response["ts_end"] and response["status"] == 200
    assert states[0] == "TASK_STATE_SUBMITTED"


def test_cut_stream_reads_client_gone_at_the_ingress_ledger():
    """The socket is closed mid-stream, with the model call still in flight."""
    out = io.StringIO()
    model = HeldModel()
    with ServedApp(app_for(out, model)) as served:
        client = StreamClient(served.port, STREAM_BODY, headers=A2A_HEADERS)
        assert client.status_line().startswith("HTTP/1.1 200")
        assert state_of(client.next_event()) == "TASK_STATE_SUBMITTED"
        model.wait_until_called()
        client.close()  # the cut, with the model call in flight
        model.release()
        wait_for(out, lambda _: bool(response_lines(out)), "an ingress response line")

    response = response_lines(out)[0]
    assert response["stream_end"] == "client-gone", response
    assert response["ts_end"]


def result_lines(out: io.StringIO) -> list[dict]:
    return [line for line in ledger(out, "execution") if line.get("event") == "result"]


def test_cut_stream_reads_consumer_gone_at_the_execution_ledger():
    """A cut reaches the request handler as nothing at all — the SDK's generator
    ends normally, with no GeneratorExit and no exception — so without the
    middleware's observation this line read complete: a lost transport recorded
    as a stream that finished."""
    out = io.StringIO()
    model = HeldModel()
    with ServedApp(app_for(out, model)) as served:
        client = StreamClient(served.port, STREAM_BODY, headers=A2A_HEADERS)
        assert state_of(client.next_event()) == "TASK_STATE_SUBMITTED"
        model.wait_until_called()
        client.close()  # the cut
        model.release()
        wait_for(out, lambda _: bool(result_lines(out)), "an execution result line")

    result = result_lines(out)[0]
    assert result["stream_end"] == "consumer-gone", result
    # The Task went on after the client was gone: counted from the executor's
    # own state lines, not inferred from the stream that stopped.
    states = [line["state"] for line in ledger(out, "execution") if line.get("event") == "state"]
    assert states == ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"], states
    assert len([line for line in ledger(out, "execution") if line.get("event") == "execute"]) == 1
    assert model.entries == 1


def test_clean_stream_never_reads_consumer_gone_at_the_execution_ledger():
    """The other direction of the same fix: a stream read to its end is complete
    even though sse-starlette consumes a disconnect at the end of the request."""
    out = io.StringIO()
    with ServedApp(app_for(out)) as served:
        client = StreamClient(served.port, STREAM_BODY, headers=A2A_HEADERS)
        states = []
        while "TASK_STATE_COMPLETED" not in states:
            states.append(state_of(client.next_event()))
        client.close()
        wait_for(out, lambda _: bool(result_lines(out)), "an execution result line")

    result = result_lines(out)[0]
    assert result["stream_end"] == "complete", result
    assert "error" not in result


class RaisingExecutor(AgentExecutor):
    """Opens a Task and then fails, which is how a producer error reaches the
    request handler in this SDK (a2a-sdk 1.1.4 surfaces producer errors to the
    subscriber)."""

    async def execute(self, context, event_queue) -> None:
        await event_queue.enqueue_event(Task(
            id=context.task_id or "", context_id=context.context_id or "",
            status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED)))
        raise RuntimeError("the executor could not finish this task")

    async def cancel(self, context, event_queue) -> None:  # pragma: no cover - not exercised here
        raise NotImplementedError


def app_with(executor, out: io.StringIO):
    """The same app server.py assembles, with a different executor."""
    writer = LineWriter(out)
    card = build_card("orchestrator", "http://orchestrator")
    handler = LedgerRequestHandler(agent_executor=executor, task_store=InMemoryTaskStore(),
                                   card=card, writer=writer)
    app = Starlette(routes=[*create_agent_card_routes(card), *create_jsonrpc_routes(handler, rpc_url="/")])
    app.add_middleware(IngressMiddleware, out=out)
    return app


def test_error_from_the_sdk_reads_error_at_the_execution_ledger():
    """A server error with the transport still up is its own ending, and must
    not be filed as a lost transport."""
    out = io.StringIO()
    with ServedApp(app_with(RaisingExecutor(), out)) as served:
        client = StreamClient(served.port, STREAM_BODY, headers=A2A_HEADERS)
        assert client.status_line().startswith("HTTP/1.1 200")
        wait_for(out, lambda _: bool(result_lines(out)), "an execution result line")
        client.close()

    result = result_lines(out)[0]
    assert result["stream_end"] == "error", result
    assert result["error"], result
    print(f"a2a-sdk 1.1.4 surfaced the producer error as: {result['error']}")
