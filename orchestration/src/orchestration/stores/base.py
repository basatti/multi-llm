from typing import Literal, Protocol

from pydantic import BaseModel, Field

Role = Literal["system", "user", "assistant"]


class Message(BaseModel):
    role: Role
    content: str


class Session(BaseModel):
    # Sessions are keyed by product + tenant + session id (architecture.md §6.1)
    id: str
    product: str
    tenant_id: str
    messages: list[Message] = Field(default_factory=list)


class SessionStore(Protocol):
    async def create(self, session: Session) -> None: ...

    async def get(self, session_id: str) -> Session | None: ...

    async def append(self, session_id: str, message: Message) -> None: ...
