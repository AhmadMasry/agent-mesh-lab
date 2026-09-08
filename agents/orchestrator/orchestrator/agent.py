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
    Task,
    TaskState,
    TaskStatus,
)

from orchestrator.forward import Forwarder
from orchestrator.ledger import LineWriter, execution_line
from orchestrator.model import Identity, ModelClient


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
    """DefaultRequestHandler with the execution ledger around the two send methods."""

    def __init__(self, *args: Any, writer: LineWriter, card: AgentCard, **kwargs: Any) -> None:
        super().__init__(*args, agent_card=card, **kwargs)
        self.writer = writer
        self.card = card

    def _received(self, method: str, params: SendMessageRequest) -> dict[str, Any]:
        """Record that the SDK accepted this request, before the inner handler runs.

        The executor's "execute" line, not this one, says agent behaviour started.
        """
        msg = params.message
        line = execution_line("received", method=method, message_id=msg.message_id, task_id=msg.task_id,
                              context_id=msg.context_id, work_item=struct_get(msg.metadata, "logical_work_item_id"))
        self.writer.write(line)
        return line

    def _result(self, base: dict[str, Any], result: Any, error: str = "") -> None:
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
        self.writer.write(line)

    async def on_message_send(self, params: SendMessageRequest, context: ServerCallContext) -> Message | Task:
        base = self._received("SendMessage", params)
        try:
            result = await super().on_message_send(params, context)
        except Exception as exc:
            self._result(base, None, error=str(exc))
            raise
        self._result(base, result)
        return result

    async def on_message_send_stream(self, params: SendMessageRequest, context: ServerCallContext) -> AsyncGenerator[Event]:
        base = self._received("SendStreamingMessage", params)
        last: Any = None
        async for event in super().on_message_send_stream(params, context):
            if isinstance(event, (Task, Message)):
                last = event
            yield event
        self._result(base, last)


def build_card(name: str, public_url: str) -> AgentCard:
    return AgentCard(
        name=name,
        description="agent-mesh-lab agent: one model call per message",
        version="0.0.0",
        supported_interfaces=[AgentInterface(url=public_url, protocol_binding="JSONRPC", protocol_version="1.0")],
        capabilities=AgentCapabilities(streaming=False),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[AgentSkill(id="answer", name="answer", description="returns the model's answer to the message text", tags=["lab"])],
    )


def build_handler(*, name: str, model: ModelClient | None, forwarder: Forwarder | None, out: TextIO | None,
                  public_url: str, plan_model_call: bool = False) -> LedgerRequestHandler:
    writer = LineWriter(out)
    executor = LabExecutor(name=name, model=model, forwarder=forwarder, writer=writer, plan_model_call=plan_model_call)
    return LedgerRequestHandler(agent_executor=executor, task_store=InMemoryTaskStore(),
                                card=build_card(name, public_url), writer=writer)
