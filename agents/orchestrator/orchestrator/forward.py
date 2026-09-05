"""Forward mode: send the message on to a downstream agent with the a2a-python client.

The httpx client is built by hand with connection retries off; the a2a-python
client has no retry option of its own. One SendMessage per forward().
"""
from __future__ import annotations

import uuid

import httpx
from a2a.client import ClientConfig, create_client
from a2a.types import Message, Part, Role, SendMessageRequest, Task, TaskState


def text_of(obj: Task | Message) -> str:
    if isinstance(obj, Task):
        for artifact in obj.artifacts:
            for part in artifact.parts:
                if part.HasField("text"):
                    return part.text
        if obj.status.HasField("message"):
            return text_of(obj.status.message)
        return ""
    return "".join(part.text for part in obj.parts if part.HasField("text"))


class Forwarder:
    def __init__(self, *, url: str, http_client: httpx.AsyncClient | None = None, caller: str = "orchestrator",
                 timeout: float = 90.0) -> None:
        self.url = url
        self.transport_retries = 0
        self._http = http_client or httpx.AsyncClient(
            transport=httpx.AsyncHTTPTransport(retries=self.transport_retries), timeout=timeout,
            headers={"X-Caller": caller},
        )
        self._client = None

    async def _get_client(self):
        if self._client is None:
            self._client = await create_client(self.url, client_config=ClientConfig(httpx_client=self._http, streaming=False))
        return self._client

    async def forward(self, text: str, work_item: str) -> str:
        client = await self._get_client()
        msg = Message(message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text=text)],
                      metadata={"logical_work_item_id": work_item})
        last = None
        async for response in client.send_message(SendMessageRequest(message=msg)):
            last = response
        if last is None:
            raise RuntimeError("downstream returned no response")
        if last.HasField("task"):
            task = last.task
            if task.status.state != TaskState.TASK_STATE_COMPLETED:
                raise RuntimeError(f"downstream task {task.id} ended in {TaskState.Name(task.status.state)}: {text_of(task)}")
            return text_of(task)
        if last.HasField("message"):
            return text_of(last.message)
        raise RuntimeError("downstream response carried neither task nor message")
