import json
from typing import Literal, Protocol

import asyncpg
from pydantic import BaseModel, Field


class AgentConfig(BaseModel):
    # The behavioral policy Langfuse does not model (architecture.md §6.4)
    logical_model: str = "chat-default"
    allowed_tools: list[str] = Field(default_factory=list)
    memory_policy: Literal["none", "session", "long-term"] = "session"
    sampling_defaults: dict = Field(default_factory=dict)


class AppProfile(BaseModel):
    app_id: str
    owner: str
    cost_center: str
    # Reference only — the key itself stays in the gateway (§6.4)
    virtual_key_alias: str
    langfuse_prompt_namespace: str
    agent_config: AgentConfig


class AppRegistry(Protocol):
    async def create(self, profile: AppProfile) -> None: ...

    async def get(self, app_id: str) -> AppProfile | None: ...


class PostgresAppRegistry:
    """The one custom table §6.4 allows: governance glue, nothing more."""

    _SCHEMA = """
    CREATE TABLE IF NOT EXISTS app_profiles (
        app_id TEXT PRIMARY KEY,
        owner TEXT NOT NULL,
        cost_center TEXT NOT NULL,
        virtual_key_alias TEXT NOT NULL,
        langfuse_prompt_namespace TEXT NOT NULL,
        agent_config JSONB NOT NULL
    )
    """

    def __init__(self, dsn: str):
        self._dsn = dsn
        self._pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        self._pool = await asyncpg.create_pool(self._dsn, min_size=1, max_size=5)
        async with self._pool.acquire() as conn:
            await conn.execute(self._SCHEMA)

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()

    async def create(self, profile: AppProfile) -> None:
        assert self._pool is not None
        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    """
                    INSERT INTO app_profiles
                        (app_id, owner, cost_center, virtual_key_alias,
                         langfuse_prompt_namespace, agent_config)
                    VALUES ($1, $2, $3, $4, $5, $6::jsonb)
                    """,
                    profile.app_id,
                    profile.owner,
                    profile.cost_center,
                    profile.virtual_key_alias,
                    profile.langfuse_prompt_namespace,
                    profile.agent_config.model_dump_json(),
                )
        except asyncpg.UniqueViolationError as exc:
            raise ValueError(f"app '{profile.app_id}' already registered") from exc

    async def get(self, app_id: str) -> AppProfile | None:
        assert self._pool is not None
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT * FROM app_profiles WHERE app_id = $1", app_id
            )
        if row is None:
            return None
        return AppProfile(
            app_id=row["app_id"],
            owner=row["owner"],
            cost_center=row["cost_center"],
            virtual_key_alias=row["virtual_key_alias"],
            langfuse_prompt_namespace=row["langfuse_prompt_namespace"],
            agent_config=AgentConfig(**json.loads(row["agent_config"])),
        )
