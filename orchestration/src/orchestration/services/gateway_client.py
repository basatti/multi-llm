import json
from collections.abc import AsyncIterator

import httpx


def extract_delta(sse_event: str) -> str:
    """Content delta from one SSE data event, or '' for non-content events."""
    if not sse_event.startswith("data:"):
        return ""
    data = sse_event[len("data:"):].strip()
    if not data or data == "[DONE]":
        return ""
    try:
        chunk = json.loads(data)
        return chunk["choices"][0]["delta"].get("content") or ""
    except (json.JSONDecodeError, LookupError, AttributeError, TypeError):
        return ""


class GatewayClient:
    """All model calls go through the gateway with a virtual key — orchestration
    never holds provider credentials and never addresses vLLM directly (§6.2)."""

    def __init__(self, http: httpx.AsyncClient, virtual_key: str):
        self._http = http
        self._key = virtual_key

    async def stream_chat(
        self,
        model: str,
        messages: list[dict],
        metadata: dict | None = None,
        api_key: str | None = None,
        extra: dict | None = None,
    ) -> AsyncIterator[str]:
        """Yield SSE events from the gateway as they arrive — never buffered
        (§4.1 platform invariant).

        Closing this iterator (client disconnect / barge-in) exits the stream
        context, which closes the upstream connection so cancellation
        propagates to the serving engine and the sequence is freed (§7.1).

        `api_key` overrides the service key for calls made on behalf of a
        registered app with its own virtual key (§6.4). `extra` carries
        sampling defaults from the app profile.
        """
        payload: dict = {"model": model, "messages": messages, "stream": True}
        if extra:
            payload.update(extra)
        if metadata:
            payload["metadata"] = metadata
        async with self._http.stream(
            "POST",
            "/v1/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {api_key or self._key}"},
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if line.strip():
                    yield f"{line}\n\n"

    async def healthy(self) -> bool:
        try:
            resp = await self._http.get("/health/liveliness")
            return resp.status_code == 200
        except httpx.HTTPError:
            return False
