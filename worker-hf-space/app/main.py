import asyncio
import hmac
import tempfile
import base64
import json
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID
import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from worker_app.config import WorkerSettings
from app.models import OutputFormat, StrictModel, JobOptions
from pydantic import Field
from app.security.file_validator import validate_file
from app.security.hmac_signer import verify_dispatch
from app.security.rate_limit import Redis
from worker_app.converters import convert


class Conversion(StrictModel):
    job_id: UUID
    input_url: str = Field(max_length=4096)
    input_extension: str = Field(pattern=r'^(pdf|docx|xlsx|pptx|doc|xls|ppt|html|txt|md|tex|png|jpg|jpeg|webp|tif|tiff)$')
    output_format: OutputFormat
    sha256: str = Field(pattern=r'^[a-f0-9]{64}$')
    byte_length: int = Field(gt=0, le=15_728_640)
    options: JobOptions = Field(default_factory=JobOptions)


@asynccontextmanager
async def lifespan(application):
    settings = WorkerSettings()
    application.state.settings = settings
    application.state.redis = Redis(settings.upstash_redis_rest_url, settings.upstash_redis_rest_token.get_secret_value())
    application.state.semaphore = asyncio.Semaphore(1)
    try:
        yield
    finally:
        await application.state.redis.client.aclose()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)


@app.get('/healthz')
async def health():
    return {'status': 'ok'}


@app.post('/convert')
async def handle(request: Request):
    settings = request.app.state.settings
    if not hmac.compare_digest(request.headers.get('authorization', ''), 'Bearer '+settings.hf_token.get_secret_value()):
        raise HTTPException(401, 'Worker authorization required')
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 16384:
            raise HTTPException(413, 'Dispatch too large')
    await verify_dispatch(request.headers, bytes(body), settings.worker_hmac_secret.get_secret_value(), request.app.state.redis)
    payload = Conversion.model_validate_json(body)
    url = urlsplit(payload.input_url)
    expected = urlsplit(settings.r2_endpoint)
    if url.scheme != 'https' or url.netloc != expected.netloc or url.username or url.password:
        raise HTTPException(422, 'Untrusted input storage origin')
    # Includes queue wait in the overall request deadline; no detached jobs.
    try:
        async with asyncio.timeout(230):
            async with request.app.state.semaphore:
                with tempfile.TemporaryDirectory(prefix=f'pdf-{payload.job_id}-') as folder:
                    root = Path(folder)
                    source = root/('input.'+payload.input_extension)
                    suffix = 'pdf' if payload.output_format.value in {'pdf','pdfa','searchable_pdf','flattened_pdf'} else payload.output_format.value
                    output = root/('output.'+suffix)
                    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
                        async with client.stream('GET', payload.input_url) as response:
                            response.raise_for_status()
                            size = 0
                            with source.open('wb') as stream:
                                async for chunk in response.aiter_bytes():
                                    size += len(chunk)
                                    if size > payload.byte_length:
                                        raise ValueError('Oversized upload')
                                    stream.write(chunk)
                    await asyncio.to_thread(validate_file, source, payload.input_extension, payload.byte_length, payload.sha256)
                    report=await convert(source, output, payload.output_format.value, settings,payload.options.model_dump())
                    if output.stat().st_size > 50_000_000:
                        raise ValueError('Output size limit exceeded')
                    result = output.read_bytes()
                # Carry measured QA alongside the binary, without a second object
                # store or a misleading generic success report in the gateway.
                summary={key:report[key] for key in ('engine','visual_qa','qa','archival_validation') if key in report}
                summary['warnings']=[str(value)[:200] for value in report.get('warnings',[])[:10]]
                encoded=base64.urlsafe_b64encode(json.dumps(summary,separators=(',',':')).encode()).decode()
                if len(encoded)>16000:
                    raise ValueError('Conversion report exceeded response limit')
                return Response(result, media_type='application/octet-stream', headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff','X-Conversion-Report':encoded})
    except (ValueError, RuntimeError, TimeoutError, httpx.HTTPError) as exc:
        raise HTTPException(422, 'Conversion failed validation or exceeded resource limits') from exc
