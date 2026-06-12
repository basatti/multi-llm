from fastapi import APIRouter, Request, Response

router = APIRouter()


@router.get("/healthz")
async def healthz():
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(request: Request, response: Response):
    state = request.app.state
    checks: dict[str, str] = {}

    if state.redis is None:
        checks["redis"] = "skipped"
    else:
        try:
            await state.redis.ping()
            checks["redis"] = "ok"
        except Exception as exc:  # noqa: BLE001 - readiness reports any failure
            checks["redis"] = f"error: {exc}"

    checks["gateway"] = "ok" if await state.gateway.healthy() else "error"

    if any(v.startswith("error") for v in checks.values()):
        response.status_code = 503
    return checks
