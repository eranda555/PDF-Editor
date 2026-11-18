import asyncio
import json
import contextlib
import time
from datetime import datetime, timezone
from uuid import UUID, uuid4
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from app.models import Dispatch, JobInit
from app.security.auth import current_device
from psycopg.types.json import Jsonb

router = APIRouter(prefix='/v1/jobs', tags=['jobs'])


async def owned(state, job_id, device_id):
    row = await state.db.one('SELECT * FROM jobs WHERE id=%s AND device_id=%s AND expires_at>now()', (job_id, device_id))
    if not row:
        raise HTTPException(404, 'Job not found')
    return row


@router.post('/init', status_code=201)
async def init(payload: JobInit, request: Request, device: UUID = Depends(current_device)):
    state = request.app.state
    if not state.settings.cloud_enabled:
        raise HTTPException(503, 'Cloud processing is disabled by the service operator')
    identity = uuid4()
    await state.redis.reserve(str(device), str(identity), state.settings.global_daily_jobs)
    try:
        await state.db.execute('INSERT INTO jobs(id,device_id,extension,output_format,byte_length,sha256,options) VALUES(%s,%s,%s,%s,%s,%s,%s)',
            (identity, device, payload.extension, payload.output_format.value, payload.byte_length, payload.sha256,Jsonb(payload.options.model_dump())))
        url = state.storage.put_url(str(identity), payload.byte_length)
    except Exception:
        await state.redis.release(str(device), str(identity))
        raise
    return {'job_id': str(identity), 'upload_url': url, 'expires_in': 300,
            'headers': {'Content-Type': 'application/octet-stream', 'Content-Length': str(payload.byte_length)}}


@router.post('/dispatch', status_code=202)
async def dispatch(payload: Dispatch, request: Request, device: UUID = Depends(current_device)):
    state = request.app.state
    async with state.db.connection() as conn:
        row = await (await conn.execute('SELECT state FROM jobs WHERE id=%s AND device_id=%s AND expires_at>now() FOR UPDATE', (payload.job_id, device))).fetchone()
        if not row:
            raise HTTPException(404, 'Job not found')
        if row['state'] == 'uploading':
            await conn.execute("UPDATE jobs SET state='queued' WHERE id=%s", (payload.job_id,))
            await conn.execute('INSERT INTO job_outbox(job_id) VALUES(%s) ON CONFLICT DO NOTHING', (payload.job_id,))
        elif row['state'] not in ('queued', 'running', 'done'):
            raise HTTPException(409, 'Job cannot be dispatched')
    return {'job_id': str(payload.job_id), 'state': row['state'] if row['state'] != 'uploading' else 'queued'}


@router.get('/{job_id}')
async def status(job_id: UUID, request: Request, device: UUID = Depends(current_device)):
    state = request.app.state
    row = await owned(state, job_id, device)
    result = {'job_id': str(job_id), 'state': row['state'], 'progress': row['progress'],
              'error_code': row['error_code'], 'report': row['report'], 'output_format': row['output_format']}
    if row['state'] == 'done':
        seconds = int((row['expires_at']-datetime.now(timezone.utc)).total_seconds())
        result['download_url'] = state.storage.get_url(str(job_id), True, min(60, seconds))
    return result


@router.get('/{job_id}/stream')
async def stream(job_id: UUID, request: Request, device: UUID = Depends(current_device)):
    state = request.app.state
    await owned(state, job_id, device)
    await state.redis.throttle(f'sse:{device}', 30, 60)

    async def events():
        previous = ''
        subscription=state.redis.subscribe(str(job_id))
        pending=asyncio.create_task(anext(subscription))
        deadline=time.monotonic()+50
        last_snapshot=0.
        try:
            while time.monotonic()<deadline:
                if await request.is_disconnected():
                    return
                ready,_=await asyncio.wait({pending},timeout=2)
                if ready:
                    try:
                        pending.result()
                    except StopAsyncIteration:
                        return
                    pending=asyncio.create_task(anext(subscription))
                if ready or time.monotonic()-last_snapshot>10:
                    row = await state.db.one('SELECT state,progress,error_code FROM jobs WHERE id=%s AND device_id=%s AND expires_at>now()', (job_id, device))
                    last_snapshot=time.monotonic()
                    if not row:
                        yield 'event: expired\ndata: {}\n\n'
                        return
                    value=json.dumps(row)
                    if value!=previous:
                        yield f'event: progress\ndata: {value}\n\n'
                        previous=value
                    if row['state'] in ('done','failed','deleted'):
                        return
                yield ': keepalive\n\n'
        finally:
            pending.cancel()
            with contextlib.suppress(asyncio.CancelledError,StopAsyncIteration):
                await pending
            await subscription.aclose()
    return StreamingResponse(events(), media_type='text/event-stream', headers={'X-Accel-Buffering': 'no'})


@router.delete('/{job_id}', status_code=204)
async def delete(job_id: UUID, request: Request, device: UUID = Depends(current_device)):
    state = request.app.state
    async with state.db.connection() as conn:
        row = await (await conn.execute('SELECT id FROM jobs WHERE id=%s AND device_id=%s FOR UPDATE', (job_id, device))).fetchone()
        if not row:
            raise HTTPException(404, 'Job not found')
        await state.storage.purge(str(job_id))
        # Keep an opaque tombstone until the sweeper's grace period: a still-valid
        # upload URL can recreate input.bin, and must be purged again after expiry.
        await conn.execute("UPDATE jobs SET state='deleted',extension=NULL,output_format=NULL,byte_length=NULL,sha256=NULL,report=NULL,options='{}',error_code=NULL WHERE id=%s", (job_id,))
        await conn.execute('DELETE FROM job_outbox WHERE job_id=%s', (job_id,))
    await state.redis.release(str(device), str(job_id))
