import time

import httpx


def compile_template(template: str, variables: dict) -> str:
    """Langfuse text-prompt convention: {{variable}} placeholders."""
    for key, value in variables.items():
        template = template.replace("{{" + key + "}}", str(value))
        template = template.replace("{{ " + key + " }}", str(value))
    return template


class LangfuseClient:
    """Prompt templates live in Langfuse — versioned, labeled, audited (§6.4).
    Orchestration only fetches and compiles; it never stores prompt content."""

    def __init__(self, http: httpx.AsyncClient, cache_ttl_seconds: int = 60):
        self._http = http
        self._cache_ttl = cache_ttl_seconds
        self._cache: dict[tuple[str, str], tuple[float, str]] = {}

    async def create_prompt(
        self, name: str, prompt: str, labels: list[str] | None = None
    ) -> dict:
        resp = await self._http.post(
            "/api/public/v2/prompts",
            json={
                "name": name,
                "type": "text",
                "prompt": prompt,
                "labels": labels if labels is not None else ["production"],
            },
        )
        resp.raise_for_status()
        return resp.json()

    async def get_prompt(self, name: str, label: str = "production") -> str:
        cached = self._cache.get((name, label))
        if cached and time.monotonic() - cached[0] < self._cache_ttl:
            return cached[1]
        resp = await self._http.get(
            f"/api/public/v2/prompts/{name}", params={"label": label}
        )
        resp.raise_for_status()
        prompt = resp.json()["prompt"]
        self._cache[(name, label)] = (time.monotonic(), prompt)
        return prompt
