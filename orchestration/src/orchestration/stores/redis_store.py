import redis.asyncio as redis

from .base import Message, Session


class RedisSessionStore:
    """Hot session store (architecture.md §6.3).

    Read-modify-write on append is safe under the platform's single active
    turn per session; revisit with WATCH/Lua if concurrent turns ever appear.
    """

    def __init__(self, client: redis.Redis, ttl_seconds: int = 3600):
        self._redis = client
        self._ttl = ttl_seconds

    @staticmethod
    def _key(session_id: str) -> str:
        return f"session:{session_id}"

    async def create(self, session: Session) -> None:
        await self._redis.set(self._key(session.id), session.model_dump_json(), ex=self._ttl)

    async def get(self, session_id: str) -> Session | None:
        raw = await self._redis.get(self._key(session_id))
        return Session.model_validate_json(raw) if raw else None

    async def append(self, session_id: str, message: Message) -> None:
        session = await self.get(session_id)
        if session is None:
            raise KeyError(session_id)
        session.messages.append(message)
        await self._redis.set(self._key(session_id), session.model_dump_json(), ex=self._ttl)
