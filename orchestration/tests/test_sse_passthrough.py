"""End-to-end session flow against a mocked gateway.

The mock gateway streams SSE chunks whose text embeds the number of messages it
received — proving that conversation history grows in the store between turns
and that SSE events pass through orchestration unmodified.
"""

import json

import fakeredis.aioredis
import httpx
import pytest
from fastapi.testclient import TestClient

from orchestration.config import Settings
from orchestration.main import create_app
from orchestration.services.gateway_client import GatewayClient, extract_delta
from orchestration.stores.redis_store import RedisSessionStore


def sse_payload(model: str, words: list[str]) -> bytes:
    def chunk(delta: dict, finish: str | None = None) -> str:
        return "data: " + json.dumps(
            {
                "id": "chatcmpl-test",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
        ) + "\n\n"

    events = [chunk({"role": "assistant", "content": ""})]
    events += [chunk({"content": w + " "}) for w in words]
    events += [chunk({}, finish="stop"), "data: [DONE]\n\n"]
    return "".join(events).encode()


def mock_gateway_handler(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content)
    assert request.headers["authorization"] == "Bearer sk-test"
    assert body["metadata"]["tenant_id"] == "t1"
    words = [f"reply-with-{len(body['messages'])}-messages"]
    return httpx.Response(
        200,
        content=sse_payload(body["model"], words),
        headers={"content-type": "text/event-stream"},
    )


@pytest.fixture
def client() -> TestClient:
    store = RedisSessionStore(fakeredis.aioredis.FakeRedis(), ttl_seconds=60)
    http = httpx.AsyncClient(
        transport=httpx.MockTransport(mock_gateway_handler),
        base_url="http://gateway.test",
    )
    app = create_app(
        settings=Settings(default_model="chat-default"),
        store=store,
        gateway=GatewayClient(http, virtual_key="sk-test"),
    )
    with TestClient(app) as test_client:
        yield test_client


def send_and_collect(client: TestClient, session_id: str, content: str) -> str:
    with client.stream(
        "POST", f"/v1/sessions/{session_id}/messages", json={"content": content}
    ) as resp:
        assert resp.status_code == 200
        return "".join(resp.iter_text())


def test_session_flow_streams_and_persists_history(client: TestClient):
    session_id = client.post(
        "/v1/sessions", json={"product": "demo-app", "tenant_id": "t1"}
    ).json()["session_id"]

    # Turn 1: gateway sees exactly 1 message (the user's)
    body = send_and_collect(client, session_id, "hello")
    assert "data:" in body and "data: [DONE]" in body
    assert "reply-with-1-messages" in body

    # Turn 2: history grew — user, assistant, user = 3 messages at the gateway
    body = send_and_collect(client, session_id, "again")
    assert "reply-with-3-messages" in body

    session = client.get(f"/v1/sessions/{session_id}").json()
    roles = [m["role"] for m in session["messages"]]
    assert roles == ["user", "assistant", "user", "assistant"]
    assert "reply-with-1-messages" in session["messages"][1]["content"]


def test_message_to_missing_session_404s(client: TestClient):
    resp = client.post("/v1/sessions/nope/messages", json={"content": "hi"})
    assert resp.status_code == 404


def test_extract_delta():
    event = 'data: {"choices": [{"delta": {"content": "hi "}, "index": 0}]}'
    assert extract_delta(event) == "hi "
    assert extract_delta("data: [DONE]") == ""
    assert extract_delta(": keepalive") == ""
    assert extract_delta('data: {"choices": []}') == ""
