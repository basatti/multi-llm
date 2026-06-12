from contextlib import asynccontextmanager

import httpx
import redis.asyncio as redis
from fastapi import FastAPI

from .config import Settings
from .routers import apps, health, sessions
from .services.gateway_client import GatewayClient
from .services.langfuse_client import LangfuseClient
from .services.litellm_admin import LiteLLMAdminClient
from .stores.app_registry import PostgresAppRegistry
from .stores.redis_store import RedisSessionStore


def create_app(
    settings: Settings | None = None,
    store=None,
    gateway=None,
    registry=None,
    litellm_admin=None,
    langfuse=None,
) -> FastAPI:
    """App factory. Keyword overrides exist for tests."""
    app_settings = settings or Settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.settings = app_settings
        app.state.redis = None if store is not None else redis.from_url(app_settings.redis_url)
        app.state.store = store or RedisSessionStore(
            app.state.redis, ttl_seconds=app_settings.session_ttl_seconds
        )

        app.state.http = httpx.AsyncClient(
            base_url=app_settings.gateway_base_url,
            timeout=httpx.Timeout(300, connect=10),
        )
        app.state.gateway = gateway or GatewayClient(
            app.state.http, app_settings.gateway_virtual_key
        )
        app.state.litellm_admin = litellm_admin or LiteLLMAdminClient(
            app.state.http, app_settings.gateway_admin_key
        )

        app.state.langfuse_http = httpx.AsyncClient(
            base_url=app_settings.langfuse_host,
            auth=(app_settings.langfuse_public_key, app_settings.langfuse_secret_key),
            timeout=httpx.Timeout(30, connect=10),
        )
        app.state.langfuse = langfuse or LangfuseClient(
            app.state.langfuse_http, cache_ttl_seconds=app_settings.prompt_cache_ttl_seconds
        )

        # Empty DSN disables the registry endpoints (503) — keeps the service
        # bootable without Postgres for session-only deployments and tests.
        app.state.registry = registry
        pg_registry = None
        if registry is None and app_settings.database_url:
            pg_registry = PostgresAppRegistry(app_settings.database_url)
            await pg_registry.connect()
            app.state.registry = pg_registry

        try:
            yield
        finally:
            await app.state.http.aclose()
            await app.state.langfuse_http.aclose()
            if pg_registry is not None:
                await pg_registry.close()
            if app.state.redis is not None:
                await app.state.redis.aclose()

    app = FastAPI(title="orchestration", lifespan=lifespan)
    app.include_router(health.router)
    app.include_router(sessions.router)
    app.include_router(apps.router)
    return app


app = create_app()
