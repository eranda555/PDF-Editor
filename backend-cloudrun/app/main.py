import hmac
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from app.config import get_settings
from app.db import Database
from app.routers import auth, jobs
from app.security.rate_limit import Redis
from app.storage.r2_client import R2


@asynccontextmanager
async def lifespan(application):
    settings = get_settings()
    application.state.settings = settings
    application.state.db = Database(settings.database_url.get_secret_value())
    application.state.redis = Redis(settings.upstash_redis_rest_url, settings.upstash_redis_rest_token.get_secret_value())
    application.state.storage = R2(settings)
    await application.state.db.pool.open()
    try:
        yield
    finally:
        await application.state.storage.close()
        await application.state.db.pool.close()
        await application.state.redis.client.aclose()


app = FastAPI(title='100% PDF Suite', version='0.2.0', lifespan=lifespan, docs_url=None, redoc_url=None)
app.include_router(auth.router)
app.include_router(jobs.router)
SECURITY_HEADERS = {'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'",
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains'}


@app.middleware('http')
async def security_headers(request: Request, call_next):
    if request.headers.get('content-length', '0').isdigit() and int(request.headers.get('content-length', '0')) > 65536:
        from fastapi.responses import JSONResponse
        return JSONResponse({'detail': 'Request body too large'}, status_code=413, headers=SECURITY_HEADERS)
    if request.method in ('POST', 'PUT', 'PATCH'):
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > 65536:
                from fastapi.responses import JSONResponse
                return JSONResponse({'detail': 'Request body too large'}, status_code=413, headers=SECURITY_HEADERS)
        request._body = bytes(body)
    try:
        response = await call_next(request)
    except Exception:
        from fastapi.responses import JSONResponse
        return JSONResponse({'detail':'Service operation failed'},status_code=500,headers=SECURITY_HEADERS)
    response.headers.update(SECURITY_HEADERS)
    return response


@app.get('/healthz')
async def health():
    return {'status': 'ok'}


@app.post('/internal/drain')
async def drain(request: Request):
    expected = 'Bearer '+request.app.state.settings.internal_token.get_secret_value()
    if not hmac.compare_digest(request.headers.get('authorization', ''), expected):
        raise HTTPException(401, 'Internal authentication required')
    from app.queue.procrastinate_app import app as queue, drain_outbox, sweep
    # Operator invokes this authenticated request at least once/minute. Work stays
    # inside its request lifetime; Cloud Run CPU is not assumed to run when idle.
    state = request.app.state
    async with queue.open_async():
        await sweep(state.db, state.storage, state.redis)
        await drain_outbox(state.db)
        await queue.run_worker_async(wait=False, concurrency=1, queues=['pdf'])
    return {'status': 'drained'}


@app.post('/internal/purge')
async def purge(request: Request):
    expected = 'Bearer '+request.app.state.settings.internal_token.get_secret_value()
    if not hmac.compare_digest(request.headers.get('authorization', ''), expected):
        raise HTTPException(401, 'Internal authentication required')
    from app.queue.procrastinate_app import sweep
    state = request.app.state
    await sweep(state.db, state.storage, state.redis)
    return {'status': 'purged'}
