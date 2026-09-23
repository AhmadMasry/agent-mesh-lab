"""The agent's behaviour: one Task per dispatched message, around exactly one
model call (model mode) or one downstream A2A call (forward mode)."""
from __future__ import annotations

from collections.abc import AsyncGenerator
from typing import Any, TextIO

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.context import ServerCallContext
from a2a.server.events import Event, EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    Message,
    Part,
    SendMessageRequest,
    SubscribeToTaskRequest,
    Task,
    TaskArtifactUpdateEvent,
    TaskState,
    TaskStatus,
    TaskStatusUpdateEvent,
)

from orchestrator.forward import Forwarder
from orchestrator.ledger import LineWriter, current_delivery, execution_line
from orchestrator.model import Identity, ModelClient
from orchestrator.refuse import refusal

# How a streamed sequence of events ended, as the handler can observe it:
# complete when the SDK's generator ran out, consumer-gone when the transport
# stopped reading it (which is what a cut stream looks like from in here), error
# when the generator raised. The Go receiver writes all three by these names.
# A consumer-gone line carries no error string here, because GeneratorExit is
# not an error; the Go receiver's may carry the cancellation its SDK answers a
# cut with. Both receivers agree on stream_end, which is the field to count.
#
# complete says the generator ran out, not that a terminal event was sent:
# whether the last state was terminal is read from the executor's state lines,
# and what the stream carried from the delivered lines.
STREAM_END_COMPLETE = "complete"
STREAM_END_CONSUMER_GONE = "consumer-gone"
STREAM_END_ERROR = "error"


def ended(stream_end: str) -> str:
    """The ending, corrected by what the ASGI boundary saw.

    A cut stream reaches this handler as nothing at all: measured over a socket,
    a real disconnect ends the SDK's generator normally, with no GeneratorExit
    and no exception, so the loop runs out and the ending would read complete —
    a lost transport recorded as a stream that finished, which is the count
    Experiment B exists to make. The middleware is the only part of this process
    that sees the ASGI server's http.disconnect, so its observation is what
    decides: a delivery whose client went away is consumer-gone whatever the
    generator did. An ending the handler observed itself (an exception, an
    explicit close) is kept, because it says more than the disconnect does.
    """
    if stream_end != STREAM_END_COMPLETE:
        return stream_end
    delivery = current_delivery()
    if delivery is not None and delivery.client_gone:
        return STREAM_END_CONSUMER_GONE
    return STREAM_END_COMPLETE


def struct_get(struct: Any, key: str) -> str:
    """Read a string value from a protobuf Struct (or dict) without failing on absence."""
    try:
        value = struct[key]
    except (KeyError, ValueError, TypeError):
        return ""
    return value if isinstance(value, str) else ""


def state_name(state: int) -> str:
    return TaskState.Name(state)


class LabExecutor(AgentExecutor):
    def __init__(self, *, name: str, model: ModelClient | None, forwarder: Forwarder | None,
                 writer: LineWriter, plan_model_call: bool = False) -> None:
        if model is None and forwarder is None:
            raise ValueError("an agent needs a model (model mode) or a downstream agent (forward mode)")
        self.name = name
        self.model = model
        self.forwarder = forwarder
        self.plan_model_call = plan_model_call
        self.writer = writer

    def _state(self, context: RequestContext, state: int, error: str = "") -> None:
        msg = context.message
        self.writer.write(execution_line(
            "state",
            message_id=msg.message_id if msg is not None else "",
            task_id=context.task_id or "",
            context_id=context.context_id or "",
            work_item=struct_get(msg.metadata, "logical_work_item_id") if msg is not None else "",
            state=state_name(state),
            error=error,
        ))

    def _entered(self, context: RequestContext) -> None:
        """Record that the SDK handed this message to the executor.

        The execution ledger's "received" line says the SDK accepted a request;
        this line says agent behaviour actually started for it, which is what
        the experiment scripts count as a dispatch.
        """
        msg = context.message
        self.writer.write(execution_line(
            "execute",
            message_id=msg.message_id if msg is not None else "",
            task_id=context.task_id or "",
            context_id=context.context_id or "",
            work_item=struct_get(msg.metadata, "logical_work_item_id") if msg is not None else "",
        ))

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        self._entered(context)
        msg = context.message
        work_item = struct_get(msg.metadata, "logical_work_item_id") if msg is not None else ""
        text = context.get_user_input()
        updater = TaskUpdater(event_queue, context.task_id or "", context.context_id or "")
        # The SDK requires a Task before any status update ("Agent should enqueue
        # Task before TaskStatusUpdateEvent"); enqueuing a submitted Task first is
        # what makes every dispatched message become a Task, so a taskId always exists.
        self._state(context, TaskState.TASK_STATE_SUBMITTED)
        await event_queue.enqueue_event(Task(
            id=context.task_id or "", context_id=context.context_id or "",
            status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED),
            history=[msg] if msg is not None else [],
        ))
        self._state(context, TaskState.TASK_STATE_WORKING)
        await updater.start_work()
        identity = Identity(work_item=work_item, message_id=msg.message_id if msg is not None else "",
                            task_id=context.task_id or "", caller=self.name)
        try:
            if self.forwarder is not None:
                if self.plan_model_call and self.model is not None:
                    await self.model.complete(identity, text)
                answer = await self.forwarder.forward(text, work_item)
            else:
                assert self.model is not None
                answer = await self.model.complete(identity, text)
            await updater.add_artifact([Part(text=answer)])
            self._state(context, TaskState.TASK_STATE_COMPLETED)
            await updater.complete()
        except Exception as exc:  # no retry: one attempt, recorded as failed
            self._state(context, TaskState.TASK_STATE_FAILED, error=str(exc))
            await updater.failed(updater.new_agent_message([Part(text=str(exc))]))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id or "", context.context_id or "")
        self._state(context, TaskState.TASK_STATE_CANCELED)
        await updater.cancel()


class LedgerRequestHandler(DefaultRequestHandler):
    """DefaultRequestHandler with the execution ledger around the two send
    methods and the resubscription.

    refuse names the one operation REFUSE_OPERATION refuses (orchestrator.refuse),
    "" for none. The refusal is in each of the three wrappers, after the
    "received" line and before the SDK's own handler is called, inside the same
    try as that call: a refused request keeps its "received" line and gains a
    "result" line carrying the refusal, as the Go worker's does, and the
    executor, which writes "execute", is never entered."""

    def __init__(self, *args: Any, writer: LineWriter, card: AgentCard, refuse: str = "", **kwargs: Any) -> None:
        super().__init__(*args, agent_card=card, **kwargs)
        self.writer = writer
        self.card = card
        self.refuse = refuse

    def _refuse_if(self, operation: str) -> None:
        if self.refuse == operation:
            raise refusal(operation)

    def _received(self, method: str, params: SendMessageRequest) -> dict[str, Any]:
        """Record that the SDK accepted this request, before the inner handler runs.

        The executor's "execute" line, not this one, says agent behaviour started.
        """
        msg = params.message
        line = execution_line("received", method=method, message_id=msg.message_id, task_id=msg.task_id,
                              context_id=msg.context_id, work_item=struct_get(msg.metadata, "logical_work_item_id"))
        self.writer.write(line)
        return line

    def _result(self, base: dict[str, Any], result: Any, error: str = "", stream_end: str = "") -> None:
        """Write the result line. On a streamed request its state is the last
        Task or Message the stream carried, which is the submitted Task the
        stream opens with, not the task's final state: a Task object is sent
        once and the transitions that follow are status updates. Final state is
        the executor's state lines."""
        line = dict(base)
        line["ts"] = execution_line("result")["ts"]
        line["event"] = "result"
        if isinstance(result, Task):
            line.update(result_kind="task", taskId=result.id, contextId=result.context_id,
                        state=state_name(result.status.state))
        elif isinstance(result, Message):
            line.update(result_kind="message", taskId=result.task_id, contextId=result.context_id)
        if error:
            line["error"] = error
        if stream_end:
            line["stream_end"] = stream_end
        self.writer.write(line)

    def _delivered(self, base: dict[str, Any], event: Any) -> None:
        """Record one event handed on for the transport to write.

        The line is written before the event reaches sse-starlette and before
        any byte leaves the socket, so it counts what this handler produced,
        never what a client received: a delivered line and a lost stream are not
        a contradiction.

        Not a Task state line either: the executor writes those from inside its
        own task, once per transition whether anyone is reading or not, and
        doubling them here would make "the Task continued" uncountable the
        moment a second stream reads the same task.
        """
        kind, task_id, context_id, state = "", base.get("taskId", ""), "", ""
        if isinstance(event, Task):
            kind, task_id, context_id = "task", event.id, event.context_id
            state = state_name(event.status.state)
        elif isinstance(event, Message):
            kind, task_id, context_id = "message", event.task_id, event.context_id
        elif isinstance(event, TaskStatusUpdateEvent):
            kind, task_id, context_id = "status-update", event.task_id, event.context_id
            state = state_name(event.status.state)
        elif isinstance(event, TaskArtifactUpdateEvent):
            kind, task_id, context_id = "artifact-update", event.task_id, event.context_id
        self.writer.write(execution_line(
            "delivered", method=base.get("method", ""), message_id=base.get("messageId", ""), task_id=task_id,
            context_id=context_id, work_item=base.get("logical_work_item_id", ""), result_kind=kind, state=state))

    async def on_message_send(self, params: SendMessageRequest, context: ServerCallContext) -> Message | Task:
        base = self._received("SendMessage", params)
        try:
            self._refuse_if("SendMessage")
            result = await super().on_message_send(params, context)
        except Exception as exc:
            self._result(base, None, error=str(exc))
            raise
        self._result(base, result)
        return result

    async def on_message_send_stream(self, params: SendMessageRequest, context: ServerCallContext) -> AsyncGenerator[Event]:
        """One "delivered" line per event that leaves for the transport, then
        one "result" line saying what the last Task or Message was and how the
        sequence ended.

        The result line is written from a finally, so a stream whose consumer
        went away leaves a record too. Until this, the line sat after the loop
        and a cut stream wrote none, where the Go receiver wrote one: the two
        execution ledgers would have disagreed on a cut stream for a reason that
        is this lab's, not either SDK's.

        The loop is written out here rather than delegated to a shared generator
        because a consumer closes *this* generator: an inner generator wrapped
        in an `async for` is not closed with it, and its finally would then run
        whenever the event loop finalised it. Nothing may be awaited after the
        GeneratorExit, and nothing is — the ledger writer is synchronous. It
        records; it does not repeat. When the consumer stops, so does this.
        """
        base = self._received("SendStreamingMessage", params)
        last: Any = None
        error = ""
        stream_end = STREAM_END_COMPLETE
        try:
            self._refuse_if("SendStreamingMessage")
            async for event in super().on_message_send_stream(params, context):
                self._delivered(base, event)
                if isinstance(event, (Task, Message)):
                    last = event
                yield event
        except GeneratorExit:
            stream_end = STREAM_END_CONSUMER_GONE
            raise
        except Exception as exc:
            error = str(exc)
            stream_end = STREAM_END_ERROR
            raise
        finally:
            self._result(base, last, error=error, stream_end=ended(stream_end))

    async def on_subscribe_to_task(self, params: SubscribeToTaskRequest, context: ServerCallContext) -> AsyncGenerator[Event]:
        """Record a resubscription as an arrival of its own.

        Without this the call goes straight to the SDK and the execution ledger
        holds no line for it at all, so a second stream onto a running task
        would be invisible here and countable only at the ingress boundary.

        The request carries no Message and so no messageId, contextId or work
        item (A2A v1.0, specification v1.0.1 §9.4.6): the taskId it names is the
        whole of its identity, and the line says only that. What the server
        answered first is the first "delivered" line after it — a Task for a
        task still running, an error on the result line otherwise. The loop is
        written out for the reason on_message_send_stream gives.
        """
        base = execution_line("received", method="SubscribeToTask", task_id=params.id)
        self.writer.write(base)
        last: Any = None
        error = ""
        stream_end = STREAM_END_COMPLETE
        try:
            self._refuse_if("SubscribeToTask")
            async for event in super().on_subscribe_to_task(params, context):
                self._delivered(base, event)
                if isinstance(event, (Task, Message)):
                    last = event
                yield event
        except GeneratorExit:
            stream_end = STREAM_END_CONSUMER_GONE
            raise
        except Exception as exc:
            error = str(exc)
            stream_end = STREAM_END_ERROR
            raise
        finally:
            self._result(base, last, error=error, stream_end=ended(stream_end))


def build_card(name: str, public_url: str) -> AgentCard:
    return AgentCard(
        name=name,
        description="agent-mesh-lab agent: one model call per message",
        version="0.0.0",
        supported_interfaces=[AgentInterface(url=public_url, protocol_binding="JSONRPC", protocol_version="1.0")],
        # This SDK gates both streaming operations on the card: V2's
        # on_message_send_stream and on_subscribe_to_task carry
        # @validate(lambda self: self._agent_card.capabilities.streaming)
        # (a2a-sdk 1.1.4, default_request_handler_v2.py l.335, l.426), so with
        # streaming=False this receiver refused them. A2A v1.0 requires the same
        # pairing from the other side (specification v1.0.1 l.574).
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[AgentSkill(id="answer", name="answer", description="returns the model's answer to the message text", tags=["lab"])],
    )


def build_handler(*, name: str, model: ModelClient | None, forwarder: Forwarder | None, out: TextIO | None,
                  public_url: str, plan_model_call: bool = False, refuse: str = "") -> LedgerRequestHandler:
    writer = LineWriter(out)
    executor = LabExecutor(name=name, model=model, forwarder=forwarder, writer=writer, plan_model_call=plan_model_call)
    return LedgerRequestHandler(agent_executor=executor, task_store=InMemoryTaskStore(),
                                card=build_card(name, public_url), writer=writer, refuse=refuse)
