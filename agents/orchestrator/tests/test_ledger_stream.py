"""The ingress ledger on a streamed delivery: the same line as a unary one, plus
when and how the stream ended."""
import asyncio
import hashlib
import io
import json
import re
from datetime import datetime

import pytest

from orchestrator.ledger import IngressMiddleware, parse_ingress
from tests.test_ledger import GO_BODY, _scripted

# Hand-written from specification v1.0.1 §9.4.6: the request names a task and
# carries no Message at all.
SUBSCRIBE_BODY = b'{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"task-uuid-1"},"id":"sub-1"}'

SSE_START = {"type": "http.response.start", "status": 200,
             "headers": [(b"content-type", b"text/event-stream; charset=utf-8")]}


def _lines(out: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def _stamp(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def test_streamed_response_that_ended_normally_records_complete():
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def app(scope, receive, send):
        await send(SSE_START)
        await send({"type": "http.response.body", "body": b"data: {}\n\n", "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))

    lines = _lines(out)
    assert [line["phase"] for line in lines] == ["arrival", "response"]
    assert "stream_end" not in lines[0] and "ts_end" not in lines[0]
    assert lines[1]["stream_end"] == "complete"
    # Parsed, not compared as text. This receiver's stamps are fixed-width, but
    # the Go receiver's are RFC3339Nano, which drops trailing zeros, so anything
    # that reads these two fields from either ledger has to parse them.
    assert _stamp(lines[1]["ts_end"]) >= _stamp(lines[1]["ts_arrival"])


def test_stream_cut_by_the_client_records_client_gone():
    """The client goes away mid-stream: the application learns it from receive(),
    which is the message this middleware passes on and notes."""
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def app(scope, receive, send):
        assert (await receive())["type"] == "http.request"  # the body, replayed
        await send(SSE_START)
        await send({"type": "http.response.body", "body": b"data: {}\n\n", "more_body": True})
        # What sse-starlette does: it watches receive() for the disconnect and
        # stops the response when it arrives. Nothing here reconnects or re-sends.
        message = await receive()
        assert message["type"] == "http.disconnect"

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))

    lines = _lines(out)
    assert lines[0]["phase"] == "arrival" and lines[0]["method"] == "SendMessage"
    assert lines[1]["stream_end"] == "client-gone"
    assert lines[1]["ts_end"]
    # The status was sent before the cut, so the response line carries it.
    assert lines[1]["status"] == 200


def test_stream_that_stopped_without_a_final_body_records_incomplete():
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def app(scope, receive, send):
        await send(SSE_START)
        await send({"type": "http.response.body", "body": b"data: {}\n\n", "more_body": True})

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))
    assert _lines(out)[1]["stream_end"] == "incomplete"


def test_a_failed_send_is_recorded_and_raised():
    out = io.StringIO()
    got, _, receive, _, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def send(message):
        if message["type"] == "http.response.body":
            raise OSError("broken pipe")

    async def app(scope, receive, send):
        await send(SSE_START)
        await send({"type": "http.response.body", "body": b"data: {}\n\n", "more_body": True})

    with pytest.raises(OSError):
        asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))
    assert _lines(out)[1]["stream_end"] == "send-failed"


def test_unary_response_records_no_stream_ending():
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"application/json")]})
        await send({"type": "http.response.body", "body": b'{"jsonrpc":"2.0"}', "more_body": False})

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))
    line = _lines(out)[1]
    assert "stream_end" not in line and "ts_end" not in line


def test_subscribe_to_task_takes_its_work_item_from_the_header():
    line = parse_ingress(method="POST", path="/", headers={"x-logical-work-item-id": "w-sub"},
                         remote="10.0.0.1:1234", body=SUBSCRIBE_BODY)
    assert (line["method"], line["id"], line["taskId"]) == ("SubscribeToTask", "sub-1", "task-uuid-1")
    assert line["messageId"] == "", "the request carries no Message"
    assert line["logical_work_item_id"] == "w-sub" and line["lwi_source"] == "header"


def test_card_fetch_keeps_its_empty_work_item():
    """The fallback is for JSON-RPC deliveries only: the card fetch carries the
    same header and stays outside the work item's collection."""
    line = parse_ingress(method="GET", path="/.well-known/agent-card.json",
                         headers={"x-logical-work-item-id": "w-card"}, remote="r", body=b"")
    assert line["logical_work_item_id"] == "" and "lwi_source" not in line


def test_body_work_item_is_not_marked_as_a_header_one():
    line = parse_ingress(method="POST", path="/", headers={"x-logical-work-item-id": "w-other"},
                         remote="r", body=GO_BODY)
    assert line["logical_work_item_id"] == "go-dump" and "lwi_source" not in line


def test_unary_lines_are_byte_for_byte_what_they_were():
    """Streaming added keys to the record; this is the assertion that it added
    none to a unary delivery's. Only ts_arrival varies between runs."""
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])
    scope["headers"].append((b"x-logical-work-item-id", b"go-dump"))

    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"application/json")]})
        await send({"type": "http.response.body", "body": b'{"jsonrpc":"2.0"}', "more_body": False})

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))

    head = ('{"ledger":"ingress","phase":"%s","ts_arrival":"<TS>","remote":"10.0.0.1:1234","method":"SendMessage",'
            '"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869","messageId":"01a06f19-cf55-7daf-af2b-a251c81a0375",'
            '"taskId":"","logical_work_item_id":"go-dump","a2a_version":"","content_type":"application/json",'
            '"body_sha256":"' + hashlib.sha256(GO_BODY).hexdigest() + '","body_len":' + str(len(GO_BODY)))
    want = [head % "arrival" + "}", head % "response" + ',"status":200}']
    got_lines = [re.sub(r'"ts_arrival":"[^"]*"', '"ts_arrival":"<TS>"', line)
                 for line in out.getvalue().splitlines() if line.strip()]
    assert got_lines == want


def test_a_stream_that_was_fully_sent_is_complete_even_with_a_disconnect_after_it():
    """The shape sse-starlette produces at the end of every request: the final
    body message goes out and a disconnect arrives behind it. Ranking the
    disconnect first made a completed stream read client-gone with the socket
    still open; the socket harness measures the same case for real."""
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([{"type": "http.request", "body": GO_BODY, "more_body": False}])

    async def app(scope, receive, send):
        assert (await receive())["type"] == "http.request"
        await send(SSE_START)
        await send({"type": "http.response.body", "body": b"data: {}\n\n", "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})
        assert (await receive())["type"] == "http.disconnect"

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))
    assert _lines(out)[1]["stream_end"] == "complete"
