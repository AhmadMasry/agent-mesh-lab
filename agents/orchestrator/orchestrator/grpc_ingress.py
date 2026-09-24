"""The gRPC binding (follow-on D-2): a2a-sdk's GrpcHandler on a grpc.aio server
on its own port, with the pre-dispatch ingress ledger as a server interceptor.

Why its own port (GRPC_PORT, 8081): grpcio serves HTTP/2 from its own core and
does not run inside the ASGI app, so it cannot share uvicorn's port. The Go
worker serves gRPC on 8081 too, so both receivers' Services carry the same two
ports.

Where the ledger sits (CLAUDE.md rule 5). grpcio hands a request to Python
already de-framed, so there is no HTTP boundary to read it at, as the ASGI
middleware reads JSON-RPC and REST. The earliest Python-visible point is the
method handler grpcio resolves for the call: the interceptor below replaces it
with one whose request deserializer and behaviour are wrapped. The
deserializer wrapper keeps the request's bytes as they arrived; the behaviour
wrapper writes the arrival line on entry, BEFORE it calls the SDK's servicer,
and the response line when the servicer is done. A request whose bytes do not
deserialize never reaches the behaviour, and its arrival line is written by the
deserializer wrapper instead. Either way every request of a method the servicer
serves is counted before the SDK sees it (test_grpc.py).

What a line here carries, against the Go worker's gRPC line:
  * body_sha256 and body_len are over the request's bytes framed as they
    travelled -- one uncompressed gRPC frame, a zero flag byte and the 4-byte
    big-endian length before the protobuf -- so the two receivers hash the
    same bytes for the same request. grpcio does not hand over the frame; it is
    rebuilt here, and a compressed request would be hashed as if it had not
    been (the lab's clients do not compress).
  * status is None: grpcio sends the HTTP/2 :status itself and this layer never
    sees it. grpc_status is the gRPC status the servicer ended the call with.
  * remote is grpcio's peer string without its "ipv4:"/"ipv6:" prefix, taken
    from the call's context, which the behaviour has and the deserializer does
    not; an arrival written by the deserializer wrapper carries "".
  * A method the servicer does not serve is answered UNIMPLEMENTED by grpcio
    with no handler to wrap, and is not on this ledger.

No server span is emitted for a gRPC arrival: the launcher's instrumentations
cover Starlette and httpx, and no gRPC instrumentation is installed. That is a
recorded limit of this binding in this lab, not an omission to fill.
"""
from __future__ import annotations

import hashlib
import struct
from typing import Any, AsyncIterator, Callable, TextIO

import grpc
import grpc.aio
from a2a.server.request_handlers.grpc_handler import GrpcHandler
from a2a.types import a2a_pb2_grpc

from orchestrator.headers import read_headers
from orchestrator.ledger import LineWriter, now, work_item_of

GRPC_PORT_ENV = "GRPC_PORT"
SERVICE_PREFIX = "/lf.a2a.v1.A2AService/"
STREAMING = frozenset({"SendStreamingMessage", "SubscribeToTask"})

STREAM_END_COMPLETE = "complete"
STREAM_END_CLIENT_GONE = "client-gone"
STREAM_END_ERROR = "error"


def _peer(context: grpc.aio.ServicerContext | None) -> str:
    if context is None:
        return ""
    peer = context.peer() or ""
    for prefix in ("ipv4:", "ipv6:"):
        if peer.startswith(prefix):
            return peer[len(prefix):]
    return peer


def _framed(raw: bytes) -> bytes:
    return b"\x00" + struct.pack(">I", len(raw)) + raw


def _metadata(details: grpc.HandlerCallDetails) -> dict[str, str]:
    return {k.lower(): v for k, v in (details.invocation_metadata or ()) if isinstance(v, str)}


def _struct_work_item(message: Any) -> str:
    try:
        from google.protobuf.json_format import MessageToDict
        return work_item_of(MessageToDict(message.metadata)) if message.HasField("metadata") else ""
    except Exception:
        return ""


def arrival_line(*, op: str, path: str, metadata: dict[str, str], remote: str, raw: bytes | None,
                 request: Any) -> dict[str, Any]:
    """One gRPC arrival line, keyed as the ASGI ledger's lines are, with
    "binding" right after "method" as on the Go worker's line."""
    body = _framed(raw) if raw is not None else b""
    line: dict[str, Any] = {
        "ledger": "ingress", "phase": "arrival", "ts_arrival": now(), "remote": remote,
        "method": op if op else f"POST {path}", "binding": "grpc",
        "id": "", "messageId": "", "taskId": "", "logical_work_item_id": "",
        "a2a_version": metadata.get("a2a-version", ""), "content_type": metadata.get("content-type", "application/grpc"),
        "body_sha256": hashlib.sha256(body).hexdigest(), "body_len": len(body),
    }
    if request is not None:
        if op in ("SendMessage", "SendStreamingMessage") and request.HasField("message"):
            m = request.message
            line["messageId"] = m.message_id
            line["taskId"] = m.task_id
            if m.context_id:
                line["contextId"] = m.context_id
            line["logical_work_item_id"] = _struct_work_item(m)
        elif hasattr(request, "id") and isinstance(getattr(request, "id"), str):
            line["taskId"] = request.id
    if not line["logical_work_item_id"] and metadata.get("x-logical-work-item-id"):
        line["logical_work_item_id"] = metadata["x-logical-work-item-id"]
        line["lwi_source"] = "header"
    return line


class IngressInterceptor(grpc.aio.ServerInterceptor):
    """The pre-dispatch ingress ledger for the gRPC binding (module docstring)."""

    def __init__(self, out: TextIO | None = None, read_headers: bool = False) -> None:
        self.writer = LineWriter(out)
        self.read_headers = read_headers

    async def intercept_service(self, continuation: Callable, details: grpc.HandlerCallDetails):
        handler = await continuation(details)
        if handler is None or handler.request_streaming:
            return handler
        path = details.method or ""
        op = path[len(SERVICE_PREFIX):] if path.startswith(SERVICE_PREFIX) else ""
        metadata = _metadata(details)
        call: dict[str, Any] = {"raw": None, "request": None, "written": None}

        def write_arrival(context: grpc.aio.ServicerContext | None) -> dict[str, Any]:
            line = arrival_line(op=op, path=path, metadata=metadata, remote=_peer(context), raw=call["raw"],
                                request=call["request"])
            if self.read_headers:
                pairs = [(k.encode("latin-1"), v.encode("latin-1")) for k, v in (details.invocation_metadata or ())
                         if isinstance(v, str)]
                self.writer.write({**line, "headers": read_headers(pairs)})
            else:
                self.writer.write(line)
            call["written"] = line
            return line

        inner_deserializer = handler.request_deserializer

        def deserializer(raw: bytes):
            call["raw"] = raw
            try:
                request = inner_deserializer(raw) if inner_deserializer else raw
            except BaseException:
                # The servicer will never see this request; it is counted here.
                write_arrival(None)
                raise
            call["request"] = request
            return request

        def response(line: dict[str, Any], code: grpc.StatusCode | None, stream_end: str = "") -> None:
            out = dict(line)
            out["phase"] = "response"
            out["status"] = None
            out["grpc_status"] = (code or grpc.StatusCode.OK).value[0]
            if op in STREAMING:
                out["ts_end"] = now()
                out["stream_end"] = stream_end
            self.writer.write(out)

        def code_of(context: grpc.aio.ServicerContext) -> grpc.StatusCode | None:
            try:
                return context.code()
            except Exception:
                return None

        if handler.response_streaming:
            inner = handler.unary_stream

            async def unary_stream(request, context: grpc.aio.ServicerContext) -> AsyncIterator[Any]:
                line = write_arrival(context)
                end = STREAM_END_COMPLETE
                try:
                    async for item in inner(request, context):
                        yield item
                except grpc.aio.AbortError:
                    raise
                except BaseException as exc:
                    end = STREAM_END_CLIENT_GONE if context.cancelled() else STREAM_END_ERROR
                    if isinstance(exc, (GeneratorExit,)):
                        end = STREAM_END_CLIENT_GONE
                    raise
                finally:
                    code = code_of(context)
                    if code not in (None, grpc.StatusCode.OK) and end == STREAM_END_COMPLETE:
                        end = STREAM_END_ERROR
                    response(line, code, end)

            return grpc.unary_stream_rpc_method_handler(unary_stream, request_deserializer=deserializer,
                                                        response_serializer=handler.response_serializer)

        inner_unary = handler.unary_unary

        async def unary_unary(request, context: grpc.aio.ServicerContext):
            line = write_arrival(context)
            try:
                return await inner_unary(request, context)
            finally:
                response(line, code_of(context))

        return grpc.unary_unary_rpc_method_handler(unary_unary, request_deserializer=deserializer,
                                                   response_serializer=handler.response_serializer)


def build_grpc_server(request_handler, *, out: TextIO | None = None, read_headers: bool = False,
                      address: str = "0.0.0.0:8081") -> tuple[grpc.aio.Server, int]:
    """The gRPC binding's server over the same request handler the ASGI app
    serves, so the execution ledger and REFUSE_OPERATION sit under it as under
    JSON-RPC and REST. No option is set: the server has no retry to turn off.
    Returns the server and the port it bound."""
    server = grpc.aio.server(interceptors=[IngressInterceptor(out=out, read_headers=read_headers)])
    a2a_pb2_grpc.add_A2AServiceServicer_to_server(GrpcHandler(request_handler), server)
    port = server.add_insecure_port(address)
    return server, port
