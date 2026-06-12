"""App registry endpoints (architecture.md §6.4).

Registration fans out to three systems: LiteLLM (virtual key), Langfuse
(prompt namespace), and the app-profile table here. Fan-out is sequential and
not transactional — a mid-flight failure can leave an orphan key/prompt; rerun
registration after fixing the cause (create is idempotent-safe: it 409s before
re-issuing a key if the profile row already landed).
"""

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from ..services.langfuse_client import compile_template
from ..stores.app_registry import AgentConfig, AppProfile

router = APIRouter(prefix="/v1/apps")

SEED_TEMPLATE = (
    "You are the assistant for {{app_name}}. "
    "Answer in the user's language (Arabic or English)."
)


class RegisterAppRequest(BaseModel):
    app_id: str = Field(pattern=r"^[a-z0-9][a-z0-9-]*$")
    # Owner and cost center are mandatory governance metadata (§6.4)
    owner: str = Field(min_length=1)
    cost_center: str = Field(min_length=1)
    models: list[str] = Field(default_factory=lambda: ["chat-default"])
    max_budget: float | None = None
    budget_duration: str | None = "30d"
    agent_config: AgentConfig = Field(default_factory=AgentConfig)


class InvokeRequest(BaseModel):
    template_id: str
    variables: dict[str, str] = Field(default_factory=dict)
    input: str | None = None
    tenant_id: str | None = None


def _registry(request: Request):
    registry = request.app.state.registry
    if registry is None:
        raise HTTPException(status_code=503, detail="app registry not configured")
    return registry


@router.post("", status_code=201)
async def register_app(body: RegisterAppRequest, request: Request):
    state = request.app.state
    registry = _registry(request)

    if await registry.get(body.app_id) is not None:
        raise HTTPException(status_code=409, detail=f"app '{body.app_id}' already registered")

    key_resp = await state.litellm_admin.generate_key(
        key_alias=body.app_id,
        models=body.models,
        metadata={
            "app_id": body.app_id,
            "owner": body.owner,
            "cost_center": body.cost_center,
        },
        max_budget=body.max_budget,
        budget_duration=body.budget_duration,
    )

    namespace = body.app_id
    await state.langfuse.create_prompt(
        name=f"{namespace}/system",
        prompt=SEED_TEMPLATE,
        labels=["production"],
    )

    profile = AppProfile(
        app_id=body.app_id,
        owner=body.owner,
        cost_center=body.cost_center,
        virtual_key_alias=body.app_id,
        langfuse_prompt_namespace=namespace,
        agent_config=body.agent_config,
    )
    await registry.create(profile)

    return {
        "app_id": body.app_id,
        "langfuse_prompt_namespace": namespace,
        "virtual_key": key_resp["key"],
        "note": "Store the virtual key now — it stays in the gateway and is not retrievable here.",
    }


@router.get("/{app_id}")
async def get_app(app_id: str, request: Request):
    profile = await _registry(request).get(app_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="app not found")
    return profile


@router.post("/{app_id}/invoke")
async def invoke(
    app_id: str,
    body: InvokeRequest,
    request: Request,
    authorization: str | None = Header(default=None),
):
    """Runtime contract (§6.4): apps send their virtual key, a template_id, and
    variables — never raw prompts. Orchestration resolves the profile, fetches
    the production-labeled template from Langfuse (cached), compiles, and
    streams from the gateway under the app's own key."""
    state = request.app.state
    profile = await _registry(request).get(app_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="app not found")
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="virtual key required")
    virtual_key = authorization.split(" ", 1)[1]

    template = await state.langfuse.get_prompt(
        f"{profile.langfuse_prompt_namespace}/{body.template_id}"
    )
    system_prompt = compile_template(template, body.variables)

    messages = [{"role": "system", "content": system_prompt}]
    if body.input:
        messages.append({"role": "user", "content": body.input})

    metadata = {"app_id": app_id}
    if body.tenant_id:
        metadata["tenant_id"] = body.tenant_id

    async def event_stream():
        async for sse_event in state.gateway.stream_chat(
            model=profile.agent_config.logical_model,
            messages=messages,
            metadata=metadata,
            api_key=virtual_key,
            extra=profile.agent_config.sampling_defaults,
        ):
            yield sse_event

    return StreamingResponse(event_stream(), media_type="text/event-stream")
