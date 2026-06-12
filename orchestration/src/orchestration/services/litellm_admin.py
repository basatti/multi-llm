import httpx


class LiteLLMAdminClient:
    """Key issuance via LiteLLM's management API — config-only engagement,
    no custom gateway code (architecture.md §5.2/§6.4)."""

    def __init__(self, http: httpx.AsyncClient, admin_key: str):
        self._http = http
        self._admin_key = admin_key

    async def generate_key(
        self,
        key_alias: str,
        models: list[str],
        metadata: dict,
        max_budget: float | None = None,
        budget_duration: str | None = None,
    ) -> dict:
        payload: dict = {
            "key_alias": key_alias,
            "models": models,
            "metadata": metadata,
        }
        if max_budget is not None:
            payload["max_budget"] = max_budget
        if budget_duration is not None:
            payload["budget_duration"] = budget_duration
        resp = await self._http.post(
            "/key/generate",
            json=payload,
            headers={"Authorization": f"Bearer {self._admin_key}"},
        )
        resp.raise_for_status()
        return resp.json()
