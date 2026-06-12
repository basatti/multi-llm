from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    gateway_base_url: str = "http://litellm:4000"
    gateway_virtual_key: str = ""
    # Admin key for the registration fan-out (LiteLLM /key/generate) — §6.4
    gateway_admin_key: str = ""
    redis_url: str = "redis://redis:6379/0"
    # App-registry Postgres DSN; empty disables the registry endpoints
    database_url: str = ""
    langfuse_host: str = "http://langfuse-web:3000"
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""
    prompt_cache_ttl_seconds: int = 60
    default_model: str = "chat-default"
    session_ttl_seconds: int = 3600

    model_config = {"env_prefix": "ORCH_"}
