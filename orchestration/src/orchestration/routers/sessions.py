import uuid

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from ..services.gateway_client import extract_delta
from ..stores.base import Message, Session

router = APIRouter(prefix="/v1/sessions")


class CreateSessionRequest(BaseModel):
    product: str
    tenant_id: str


class SendMessageRequest(BaseModel):
    content: str
    model: str | None = None


@router.post("", status_code=201)
async def create_session(body: CreateSessionRequest, request: Request):
    session = Session(id=uuid.uuid4().hex, product=body.product, tenant_id=body.tenant_id)
    await request.app.state.store.create(session)
    return {"session_id": session.id}


@router.get("/{session_id}")
async def get_session(session_id: str, request: Request):
    session = await request.app.state.store.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")
    return session


@router.post("/{session_id}/messages")
async def send_message(session_id: str, body: SendMessageRequest, request: Request):
    state = request.app.state
    session = await state.store.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")

    user_message = Message(role="user", content=body.content)
    await state.store.append(session_id, user_message)
    session.messages.append(user_message)
    model = body.model or state.settings.default_model

    async def event_stream():
        parts: list[str] = []
        async for sse_event in state.gateway.stream_chat(
            model=model,
            messages=[m.model_dump() for m in session.messages],
            # tenant attribution is mandatory on tenant-scoped routes (§5.1/§9)
            metadata={"tenant_id": session.tenant_id, "product": session.product},
        ):
            parts.append(extract_delta(sse_event))
            yield sse_event
        # Reached only on normal completion. On client disconnect (barge-in)
        # the generator is closed instead, which closes the upstream stream and
        # propagates cancellation to the serving engine (§7.1); the interrupted
        # turn persists no assistant message.
        content = "".join(parts)
        if content:
            await state.store.append(session_id, Message(role="assistant", content=content))

    return StreamingResponse(event_stream(), media_type="text/event-stream")
