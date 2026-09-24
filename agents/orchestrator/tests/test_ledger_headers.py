"""LEDGER_HEADERS on the Python receiver: off by default and byte for byte
today's lines when off; with it on, the arrival line records every header name,
the values of a fixed list, and whether Authorization was present, never its
value; a stop at start on any other value."""
from __future__ import annotations

import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

from orchestrator.headers import HEADER_VALUES_READ, LEDGER_HEADERS_ENV, ledger_headers_from, read_headers
from orchestrator.server import app_from_env, build_app
from tests.socket_harness import ServedApp
from tests.test_model import FakeModel
from tests.test_refuse import BODIES, SEND_BODY, STREAM_BODY, SUBSCRIBE_BODY

SECRET = "Bearer do-not-record-this-value"

# The Go worker's list, headerValuesRead in agents/worker/headers.go, written out
# again so a change to either list fails a test.
GO_LIST = ("host", "user-agent", "x-caller", "forwarded", "x-forwarded-for", "x-forwarded-proto",
           "x-forwarded-host", "x-real-ip", "via", "x-forwarded-client-cert")

IDENTITY_HEADERS = [
    ("Content-Type", "application/json"),
    ("A2A-Version", "1.0"),
    ("Authorization", SECRET),
    ("X-Forwarded-For", "10.0.0.1"),
    ("X-Forwarded-For", "10.0.0.2"),
    ("X-Forwarded-Proto", "http"),
    ("X-Forwarded-Client-Cert", "By=spiffe://cluster.local/ns/lab/sa/worker;URI=spiffe://cluster.local/ns/lab/sa/default"),
    ("X-Caller", "orchestrator"),
    ("X-Logical-Work-Item-Id", "lwi-headers"),
    ("Traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
    ("User-Agent", "lab-test/1"),
]


def _raw_lines(out: io.StringIO) -> list[str]:
    return [line for line in out.getvalue().splitlines() if line.strip()]


def _masked(line: str) -> str:
    for key in ("ts_arrival", "ts_end", "remote", "ts"):
        line = re.sub(f'"{key}":"[^"]*"', f'"{key}":"-"', line)
    return line


def _send(port: int, body: str, headers=IDENTITY_HEADERS) -> None:
    """One POST over a raw socket, so repeated headers go out as sent; read to
    the end of the response, no retry."""
    head = "".join(f"{k}: {v}\r\n" for k, v in headers)
    raw = (f"POST / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{head}Content-Length: {len(body.encode())}\r\n"
           f"Connection: close\r\n\r\n{body}").encode()
    with socket.create_connection(("127.0.0.1", port), timeout=15) as s:
        s.sendall(raw)
        while s.recv(65536):
            pass


def _served_lines(body: str, *, ledger_headers: bool | None, headers=IDENTITY_HEADERS) -> list[str]:
    """The raw ledger lines of one request, as the process serves it. None builds
    the app without passing the setting at all, which is how it was built before
    the setting existed."""
    out, model = io.StringIO(), FakeModel()
    kwargs = {} if ledger_headers is None else {"ledger_headers": ledger_headers}
    app = build_app(name="orchestrator", model=model.client(), forwarder=None, out=out,
                    public_url="http://orchestrator", **kwargs)
    with ServedApp(app) as served:
        _send(served.port, body, headers)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if any('"phase":"response"' in line for line in _raw_lines(out)):
                break
            time.sleep(0.02)
        if body is STREAM_BODY:
            # the executor's last state line is written as the stream ends
            while time.monotonic() < deadline and '"TASK_STATE_COMPLETED"' not in out.getvalue():
                time.sleep(0.02)
    return _raw_lines(out)


def test_default_off(monkeypatch):
    monkeypatch.delenv(LEDGER_HEADERS_ENV, raising=False)
    assert ledger_headers_from(os.environ.get(LEDGER_HEADERS_ENV, "")) is False
    monkeypatch.setenv("DOWNSTREAM_A2A_URL", "")
    app = app_from_env()
    middleware = [m for m in app.user_middleware if m.cls.__name__ == "IngressMiddleware"]
    assert len(middleware) == 1 and middleware[0].kwargs["read_headers"] is False


def test_on_is_read_by_app_from_env(monkeypatch):
    monkeypatch.setenv(LEDGER_HEADERS_ENV, "on")
    monkeypatch.setenv("DOWNSTREAM_A2A_URL", "")
    middleware = [m for m in app_from_env().user_middleware if m.cls.__name__ == "IngressMiddleware"]
    assert middleware[0].kwargs["read_headers"] is True


def test_only_on_turns_it_on():
    assert ledger_headers_from("on") is True


@pytest.mark.parametrize("value", ["ON", "On", " on", "on ", "1", "true", "yes", "off", "0", "false",
                                   "${LEDGER_HEADERS}", "on,values", "authorization"])
def test_anything_else_is_refused_as_a_value(value):
    with pytest.raises(ValueError, match=LEDGER_HEADERS_ENV):
        ledger_headers_from(value)


@pytest.mark.parametrize("value", ["ON", "true"])
def test_app_from_env_raises_on_any_other_value(monkeypatch, value):
    monkeypatch.setenv(LEDGER_HEADERS_ENV, value)
    monkeypatch.setenv("DOWNSTREAM_A2A_URL", "")
    with pytest.raises(ValueError, match=LEDGER_HEADERS_ENV):
        app_from_env()


def test_the_list_is_the_go_workers():
    assert HEADER_VALUES_READ == GO_LIST
    assert "authorization" not in HEADER_VALUES_READ


@pytest.mark.parametrize("op", ["SendMessage", "SendStreamingMessage", "SubscribeToTask"])
def test_off_lines_are_byte_for_byte_today(op):
    """With the setting off every line, ingress and execution, is the line the
    app wrote before the setting existed: the setting not passed and the setting
    off write the same bytes, stamps, ports and minted ids aside, and no line
    carries a headers key or the authorization value."""
    absent = _served_lines(BODIES[op], ledger_headers=None)
    off = _served_lines(BODIES[op], ledger_headers=False)
    ids = re.compile(r'"(taskId|contextId)":"[^"]*"')
    assert [ids.sub(r'"\1":"-"', _masked(line)) for line in off] == \
           [ids.sub(r'"\1":"-"', _masked(line)) for line in absent]
    assert len(off) >= 2
    for line in off:
        assert '"headers"' not in line and "do-not-record" not in line, line


def test_off_arrival_keys_are_todays():
    """The arrival line's keys, in order, as they were on 2026-09-24 before this
    change, for the widest arrival: a SubscribeToTask with the work-item header."""
    lines = _served_lines(SUBSCRIBE_BODY, ledger_headers=False)
    arrival = json.loads(lines[0])
    assert list(arrival) == ["ledger", "phase", "ts_arrival", "remote", "method", "id", "messageId", "taskId",
                             "logical_work_item_id", "a2a_version", "content_type", "body_sha256", "body_len",
                             "lwi_source"]
    response = next(json.loads(line) for line in lines if '"phase":"response"' in line)
    assert list(response) == list(arrival) + ["status"]


def test_on_records_names_the_listed_values_and_authorization_presence():
    lines = _served_lines(SEND_BODY, ledger_headers=True)
    assert all("do-not-record" not in line for line in lines)
    arrival = json.loads(lines[0])
    assert arrival["phase"] == "arrival"
    assert list(arrival)[-1] == "headers"
    reading = arrival["headers"]
    assert list(reading) == ["names", "values", "authorization_present"]
    assert reading["names"] == ["a2a-version", "authorization", "connection", "content-length", "content-type",
                                "host", "traceparent", "user-agent", "x-caller", "x-forwarded-client-cert",
                                "x-forwarded-for", "x-forwarded-proto", "x-logical-work-item-id"]
    assert reading["authorization_present"] is True
    values = dict(reading["values"])
    assert values.pop("host").startswith("127.0.0.1:")
    assert values == {
        "user-agent": "lab-test/1",
        "x-caller": "orchestrator",
        "x-forwarded-client-cert": "By=spiffe://cluster.local/ns/lab/sa/worker;URI=spiffe://cluster.local/ns/lab/sa/default",
        "x-forwarded-for": "10.0.0.1, 10.0.0.2",
        "x-forwarded-proto": "http",
    }
    assert list(reading["values"]) == sorted(reading["values"])
    for line in lines[1:]:
        assert '"headers"' not in line, line


def test_on_with_no_authorization():
    lines = _served_lines(SEND_BODY, ledger_headers=True, headers=[("Content-Type", "application/json")])
    reading = json.loads(lines[0])["headers"]
    assert reading["authorization_present"] is False
    assert set(reading["values"]) == {"host"}


def test_read_headers_on_an_empty_list():
    assert read_headers([]) == {"names": [], "values": {}, "authorization_present": False}


def test_on_moves_no_other_line():
    """The execution lines and the ingress response line are the same with the
    setting on as off, stamps, ports and minted ids aside; only the arrival line
    gains the reading."""
    off = _served_lines(STREAM_BODY, ledger_headers=False)
    on = _served_lines(STREAM_BODY, ledger_headers=True)
    ids = re.compile(r'"(taskId|contextId)":"[^"]*"')
    strip = re.compile(r',"headers":\{.*\}\}$')
    norm = lambda line: ids.sub(r'"\1":"-"', _masked(strip.sub("}", line)))
    assert [norm(line) for line in on] == [norm(line) for line in off]
    assert '"headers":{' in on[0] and all('"headers":{' not in line for line in on[1:])


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _process(value: str, port: int) -> subprocess.Popen:
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    env.update({LEDGER_HEADERS_ENV: value, "PORT": str(port), "DOWNSTREAM_A2A_URL": ""})
    return subprocess.Popen([sys.executable, "-m", "orchestrator.server"], cwd=Path(__file__).parent.parent,
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


@pytest.mark.parametrize("value", ["ON", "true", "on "])
def test_the_process_stops_at_start_on_any_other_value(value):
    port = _free_port()
    proc = _process(value, port)
    try:
        _, stderr = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        pytest.fail(f"{value!r}: the process was still running after 30 s")
    assert proc.returncode != 0
    assert LEDGER_HEADERS_ENV in stderr
    with socket.socket() as s:
        assert s.connect_ex(("127.0.0.1", port)) != 0, "nothing may be listening"


@pytest.mark.parametrize("value", ["", "on"])
def test_the_process_writes_the_reading_only_when_on(value):
    port = _free_port()
    proc = _process(value, port)
    try:
        deadline = time.monotonic() + 30
        while True:
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    break
            assert proc.poll() is None, proc.stderr.read()
            assert time.monotonic() < deadline, "the process never listened"
            time.sleep(0.05)
        req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=SUBSCRIBE_BODY.encode(), method="POST",
                                     headers={"Content-Type": "application/json", "A2A-Version": "1.0"})
        urllib.request.urlopen(req, timeout=15).read()
    finally:
        proc.kill()
        stdout, _ = proc.communicate()
    arrival = next(json.loads(line) for line in stdout.splitlines() if '"phase":"arrival"' in line)
    assert ("headers" in arrival) is (value == "on"), arrival


def test_read_headers_lower_cases_names_itself():
    """The ASGI specification has the server lower-case header names and uvicorn
    does, so over a socket this is never exercised; read_headers does not rely on
    it, and this is the one test that says so."""
    reading = read_headers([(b"X-Forwarded-For", b"10.0.0.1"), (b"Authorization", b"secret"), (b"HOST", b"h")])
    assert reading == {"names": ["authorization", "host", "x-forwarded-for"],
                       "values": {"host": "h", "x-forwarded-for": "10.0.0.1"}, "authorization_present": True}
