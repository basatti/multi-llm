from .base import Message, Session


class PostgresSessionStore:
    """Durable session store for recovery and audit (architecture.md §6.3).

    Stub: Redis is the only functional store in the Phase 0 skeleton.
    """

    def __init__(self, dsn: str):
        self._dsn = dsn

    async def create(self, session: Session) -> None:
        raise NotImplementedError("PostgresSessionStore arrives with Phase 2 (durable sessions)")

    async def get(self, session_id: str) -> Session | None:
        raise NotImplementedError("PostgresSessionStore arrives with Phase 2 (durable sessions)")

    async def append(self, session_id: str, message: Message) -> None:
        raise NotImplementedError("PostgresSessionStore arrives with Phase 2 (durable sessions)")
