import fakeredis.aioredis
import pytest

from orchestration.stores.base import Message, Session
from orchestration.stores.redis_store import RedisSessionStore


def make_store() -> RedisSessionStore:
    return RedisSessionStore(fakeredis.aioredis.FakeRedis(), ttl_seconds=60)


async def test_create_append_round_trip():
    store = make_store()
    await store.create(Session(id="s1", product="kleem", tenant_id="t1"))
    await store.append("s1", Message(role="user", content="hi"))
    await store.append("s1", Message(role="assistant", content="hello"))

    loaded = await store.get("s1")
    assert loaded is not None
    assert loaded.product == "kleem"
    assert loaded.tenant_id == "t1"
    assert [(m.role, m.content) for m in loaded.messages] == [
        ("user", "hi"),
        ("assistant", "hello"),
    ]


async def test_get_missing_returns_none():
    store = make_store()
    assert await store.get("missing") is None


async def test_append_to_missing_session_raises():
    store = make_store()
    with pytest.raises(KeyError):
        await store.append("missing", Message(role="user", content="x"))
