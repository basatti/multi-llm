"""Tests for the app registration fan-out and invoke path (§6.4).

The Postgres registry is an in-memory fake here — the integration with real
Postgres is exercised by the compose harness. The LiteLLM admin and Langfuse
clients are httpx-MockTransport stubs so the fan-out logic itself is verified.
"""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from orchestration.config import Settings
from orchestration.main import create_app
from orchestration.services.gateway_client import GatewayClient
from orchestration.services.langfuse_client import LangfuseClient
from orchestration.services.litellm_admin import LiteLLMAdminClient
from orchestration.stores.app_registry import AppProfile


class InMemoryAppRegistry:
    def __init__(self):
        self.profiles: dict[str, AppProfile] = {}

    async def create(self, profile: AppProfile) -> None:
        if profile.app_id in self.profiles:
            raise ValueError("exists")
        self.profiles[profile.app_id] = profile

    async def get(self, app_id: str) -> AppProfile | None:
        return self.profiles.get(app_id)


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

    return ("".join(
        [chunk({"role": "assistant", "content": ""})]
        + [chunk({"content": w + " "}) for w in words]
        + [chunk({}, finish="stop"), "data: [DONE]\n\n"]
    )).encode()


@pytest.fixture
def gateway_calls() -> list[dict]:
    return []


@pytest.fixture
def langfuse_calls() -> list[tuple[str, str]]:
    return []


@pytest.fixture
def client(gateway_calls, langfuse_calls) -> TestClient:
    prompts: dict[str, str] = {}

    def gateway_handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/key/generate":
            body = json.loads(request.content)
            assert request.headers["authorization"] == "Bearer admin-key"
            return httpx.Response(
                200,
                json={"key": f"sk-vk-{body['key_alias']}", "key_alias": body["key_alias"]},
            )
        if path == "/v1/chat/completions":
            body = json.loads(request.content)
            gateway_calls.append(
                {
                    "model": body["model"],
                    "messages": body["messages"],
                    "auth": request.headers.get("authorization"),
                    "metadata": body.get("metadata"),
                    "temperature": body.get("temperature"),
                }
            )
            return httpx.Response(
                200,
                content=sse_payload(body["model"], ["compiled"]),
                headers={"content-type": "text/event-stream"},
            )
        return httpx.Response(404)

    def langfuse_handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/api/public/v2/prompts":
            body = json.loads(request.content)
            prompts[body["name"]] = body["prompt"]
            langfuse_calls.append(("create", body["name"]))
            return httpx.Response(200, json={"name": body["name"], "version": 1})
        if request.method == "GET":
            name = request.url.path.rsplit("/", 1)[-1]
            langfuse_calls.append(("get", name))
            if name in prompts:
                return httpx.Response(200, json={"prompt": prompts[name]})
            # Seed a default for explicit fetches in the invoke test
            return httpx.Response(
                200,
                json={"prompt": "You are {{persona}}. Reply concisely."},
            )
        return httpx.Response(404)

    gateway_http = httpx.AsyncClient(
        transport=httpx.MockTransport(gateway_handler),
        base_url="http://gateway.test",
    )
    langfuse_http = httpx.AsyncClient(
        transport=httpx.MockTransport(langfuse_handler),
        base_url="http://langfuse.test",
    )

    settings = Settings(default_model="chat-default")
    app = create_app(
        settings=settings,
        store=object(),  # session store unused in these tests
        gateway=GatewayClient(gateway_http, virtual_key="service-key"),
        litellm_admin=LiteLLMAdminClient(gateway_http, admin_key="admin-key"),
        langfuse=LangfuseClient(langfuse_http, cache_ttl_seconds=0),
        registry=InMemoryAppRegistry(),
    )
    with TestClient(app) as test_client:
        yield test_client


def test_register_fans_out_to_gateway_langfuse_and_registry(client, langfuse_calls):
    resp = client.post(
        "/v1/apps",
        json={
            "app_id": "app-quality",
            "owner": "ai-team",
            "cost_center": "app-quality-prod",
            "models": ["chat-default", "quality-rag"],
            "agent_config": {"logical_model": "quality-rag"},
        },
    )
    assert resp.status_code == 201
    payload = resp.json()
    assert payload["virtual_key"].startswith("sk-vk-app-quality")
    assert payload["langfuse_prompt_namespace"] == "app-quality"
    assert ("create", "app-quality/system") in langfuse_calls

    profile = client.get("/v1/apps/app-quality").json()
    assert profile["owner"] == "ai-team"
    assert profile["cost_center"] == "app-quality-prod"
    assert profile["agent_config"]["logical_model"] == "quality-rag"


def test_register_rejects_duplicate(client):
    body = {"app_id": "app-ops", "owner": "ops", "cost_center": "app-ops-prod"}
    assert client.post("/v1/apps", json=body).status_code == 201
    assert client.post("/v1/apps", json=body).status_code == 409


def test_invoke_compiles_template_and_uses_app_virtual_key(client, gateway_calls):
    client.post(
        "/v1/apps",
        json={
            "app_id": "app-realtime",
            "owner": "voice-team",
            "cost_center": "app-realtime-prod",
            "agent_config": {
                "logical_model": "realtime-chat",
                "sampling_defaults": {"temperature": 0.2},
            },
        },
    )

    with client.stream(
        "POST",
        "/v1/apps/app-realtime/invoke",
        headers={"Authorization": "Bearer sk-vk-app-realtime-from-caller"},
        json={
            "template_id": "system",
            "variables": {"persona": "a polite assistant"},
            "input": "hi",
            "tenant_id": "acme",
        },
    ) as resp:
        assert resp.status_code == 200
        body = "".join(resp.iter_text())
    assert "data: [DONE]" in body

    call = gateway_calls[-1]
    assert call["model"] == "realtime-chat"
    assert call["auth"] == "Bearer sk-vk-app-realtime-from-caller"
    assert call["metadata"] == {"app_id": "app-realtime", "tenant_id": "acme"}
    assert call["temperature"] == 0.2
    # Template was compiled before the call (no {{persona}} placeholder leaks)
    system_msg = next(m for m in call["messages"] if m["role"] == "system")
    assert "a polite assistant" in system_msg["content"]
    assert "{{" not in system_msg["content"]


def test_invoke_requires_virtual_key(client):
    client.post(
        "/v1/apps",
        json={"app_id": "pms2", "owner": "x", "cost_center": "y"},
    )
    resp = client.post(
        "/v1/apps/pms2/invoke",
        json={"template_id": "system", "input": "hi"},
    )
    assert resp.status_code == 401


def test_invoke_unknown_app_404s(client):
    resp = client.post(
        "/v1/apps/nope/invoke",
        headers={"Authorization": "Bearer sk-x"},
        json={"template_id": "system", "input": "hi"},
    )
    assert resp.status_code == 404
