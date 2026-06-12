"""OpenAI-compatible mock backend for the local compose harness.

Lets the gateway's routing, virtual keys, streaming, and fallback chains be
exercised with no GPUs, no AWS, and no frontier spend.

- The reply text embeds the served model name and the number of input messages,
  so fallback resolution and conversation-history growth are observable.
- MOCK_FAIL_MODELS (comma-separated model names) makes those models return 500,
  which triggers the gateway's fallback chain.
"""

import asyncio
import json
import os
import time
import uuid

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse

app = FastAPI(title="mock-openai")

MODELS = [
    "base-bilingual-14b-awq",
    "kleem-summarize-lora-v1",
    "mock-frontier-fast",
    "mock-frontier-default",
    "mock-frontier-quality",
]


def _fail_models() -> set[str]:
    return {m.strip() for m in os.environ.get("MOCK_FAIL_MODELS", "").split(",") if m.strip()}


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{"id": m, "object": "model", "created": 0, "owned_by": "mock"} for m in MODELS],
    }


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    model = body.get("model", "unknown")
    messages = body.get("messages", [])

    if model in _fail_models():
        raise HTTPException(status_code=500, detail=f"mock failure injected for model {model}")

    reply = f"mock reply from {model} (received {len(messages)} messages)"
    completion_id = f"chatcmpl-mock-{uuid.uuid4().hex[:12]}"
    created = int(time.time())

    if body.get("stream"):
        return StreamingResponse(
            _stream(completion_id, created, model, reply), media_type="text/event-stream"
        )

    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": sum(len(str(m.get("content", "")).split()) for m in messages),
            "completion_tokens": len(reply.split()),
            "total_tokens": 0,
        },
    }


async def _stream(completion_id: str, created: int, model: str, reply: str):
    def chunk(delta: dict, finish_reason: str | None = None) -> str:
        payload = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
        }
        return f"data: {json.dumps(payload)}\n\n"

    yield chunk({"role": "assistant", "content": ""})
    for word in reply.split(" "):
        yield chunk({"content": word + " "})
        await asyncio.sleep(0.01)
    yield chunk({}, finish_reason="stop")
    yield "data: [DONE]\n\n"
