"""The agent's model client: exactly one chat-completions call per complete().

Retries are off at both layers the openai client has: its own request retries
(max_retries, documented default 2) and the connection retries of the httpx2
transport it uses (retries, default 0). Both values are recorded in the
baseline findings entry.
"""
from __future__ import annotations

from dataclasses import dataclass

import httpx2
from openai import AsyncOpenAI


@dataclass(frozen=True)
class Identity:
    work_item: str = ""
    message_id: str = ""
    task_id: str = ""
    caller: str = ""


class ModelClient:
    def __init__(self, *, base_url: str, model: str, api_key: str, max_retries: int = 0,
                 http_client: httpx2.AsyncClient | None = None, timeout: float = 60.0) -> None:
        self.model = model
        self.max_retries = max_retries
        self.transport_retries = 0
        if http_client is None:
            http_client = httpx2.AsyncClient(
                transport=httpx2.AsyncHTTPTransport(retries=self.transport_retries), timeout=timeout
            )
        self._client = AsyncOpenAI(base_url=base_url, api_key=api_key, max_retries=max_retries, http_client=http_client)

    async def complete(self, identity: Identity, text: str) -> str:
        response = await self._client.chat.completions.create(
            model=self.model,
            messages=[{"role": "user", "content": text}],
            extra_headers={
                "X-Logical-Work-Item-Id": identity.work_item,
                "X-A2A-Message-Id": identity.message_id,
                "X-A2A-Task-Id": identity.task_id,
                "X-Caller": identity.caller,
            },
        )
        content = response.choices[0].message.content
        return content or ""
