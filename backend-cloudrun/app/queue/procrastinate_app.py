import asyncio
import tempfile
import contextlib
import base64
import json
from uuid import uuid4
from pathlib import Path
import httpx
import procrastinate
from psycopg.types.json import Jsonb
from app.config import get_settings
from app.db import Database
from app.pipeline.phase3_light_engines import HEAVY_FORMATS, convert_light
from app.pipeline.phase1_triage import inspect_document
from app.security.file_validator import validate_file
from app.security.hmac_signer import signed_headers
from app.security.rate_limit import Redis
from app.storage.r2_client import R2

settings = get_settings()
app = procrastinate.App(connector=procrastinate.PsycopgConnector(conninfo=settings.database_url.get_secret_value()))


async def heartbeat(db, job_id, lease):
    while True:
        await asyncio.sleep(20)
        row=await db.one("UPDATE jobs SET lease_expires_at=now()+interval '5 minutes' WHERE id=%s AND lease_token=%s AND state='running' RETURNING id", (job_id,lease))
        if not row:
            return


@app.task(name='pdf.convert', queue='pdf')
async def convert(job_id: str):
    from uuid import UUID
    UUID(job_id)
    db = Database(settings.database_url.get_secret_value())
    await db.pool.open()
    storage = R2(settings)
    redis = Redis(settings.upstash_redis_rest_url, settings.upstash_redis_rest_token.get_secret_value())
    owner = None
    pulse = None
    lease = uuid4()
    release = False
    try:
        row = await db.one("UPDATE jobs SET state='running',progress=10,attempt=attempt+1,lease_token=%s,lease_expires_at=now()+interval '5 minutes' WHERE id=%s AND state='queued' AND expires_at>now() RETURNING *", (lease,job_id))
        if not row:
            return
        owner = str(row['device_id'])
        pulse = asyncio.create_task(heartbeat(db,job_id,lease))
        await redis.publish(job_id,'running',10)
        # TemporaryDirectory removes all inputs, renderings and profiles on failure.
        with tempfile.TemporaryDirectory(prefix=f'pdf-{job_id}-') as folder:
            root = Path(folder)
            source = root/('input.'+row['extension'])
            output = root/('output.'+row['output_format'])
            await storage.download(job_id, source, row['byte_length'])
            await asyncio.to_thread(validate_file, source, row['extension'], row['byte_length'], row['sha256'])
            await db.execute('UPDATE jobs SET progress=25 WHERE id=%s AND lease_token=%s AND state=\'running\'', (job_id,lease))
            await redis.publish(job_id,'running',25)
            visual_heavy=False
            if row['extension']=='pdf' and row['output_format'] in {'txt','md','json','xml','docx','xlsx','csv','html','pptx'}:
                triage=await asyncio.to_thread(inspect_document,source)
                visual_heavy=any(page.route!='digital_vector' for page in triage)
            if row['extension'] != 'pdf' or row['output_format'] in HEAVY_FORMATS or visual_heavy:
                if not settings.worker_url:
                    raise ValueError('Heavy worker is not configured')
                # Transfer through authenticated HTTPS, not worker-controlled object keys.
                # The worker returns raw output to the gateway; it never receives R2 credentials.
                body = {'job_id': job_id, 'input_url': storage.get_url(job_id, seconds=300),
                        'input_extension': row['extension'], 'output_format': row['output_format'],
                        'sha256': row['sha256'], 'byte_length': row['byte_length'],'options':row['options']}
                encoded = json.dumps(body, separators=(',', ':')).encode()
                async with httpx.AsyncClient(timeout=240, follow_redirects=False) as client:
                    async with client.stream('POST', settings.worker_url.rstrip('/')+'/convert', content=encoded,
                        headers=signed_headers(settings.worker_hmac_secret.get_secret_value(), settings.hf_token.get_secret_value(), encoded)) as response:
                        response.raise_for_status()
                        header=response.headers.get('X-Conversion-Report','')
                        if not header or len(header)>16000:
                            raise ValueError('Missing or oversized heavy-worker QA report')
                        report=json.loads(base64.urlsafe_b64decode(header))
                        size = 0
                        with output.open('wb') as stream:
                            async for chunk in response.aiter_bytes():
                                size += len(chunk)
                                if size > 50_000_000:
                                    raise ValueError('Heavy output size exceeded')
                                stream.write(chunk)
            else:
                report = await convert_light(source, output, row['output_format'], settings,row['options'])
            # Delete and late completion serialize on the row lock. A deleted job
            # cannot be resurrected by a worker finishing after the delete request.
            async with db.connection() as conn:
                current = await (await conn.execute('SELECT state,lease_token,expires_at>now() AS alive FROM jobs WHERE id=%s FOR UPDATE', (job_id,))).fetchone()
                if not current or current['state'] != 'running' or current['lease_token']!=lease or not current['alive']:
                    return
                await storage.upload(job_id, output)
                await conn.execute("UPDATE jobs SET state='done',progress=100,report=%s,lease_expires_at=NULL WHERE id=%s", (Jsonb(report), job_id))
                release=True
            await redis.publish(job_id,'done',100)
    except Exception:
        # Exception strings may contain signed URLs, paths or document text.
        # Only a fixed public code is persisted or returned.
        async with db.connection() as conn:
            current=await (await conn.execute('SELECT state,attempt,lease_token,expires_at>now() AS alive FROM jobs WHERE id=%s FOR UPDATE',(job_id,))).fetchone()
            if current and current['state']=='running' and current['lease_token']==lease:
                retry=current['attempt']<3 and current['alive']
                await conn.execute('UPDATE jobs SET state=%s,error_code=%s,lease_expires_at=NULL WHERE id=%s',
                    ('queued' if retry else 'failed',None if retry else 'CONVERSION_FAILED',job_id))
                if retry:
                    await conn.execute('INSERT INTO job_outbox(job_id) VALUES(%s) ON CONFLICT DO NOTHING',(job_id,))
                else:
                    await storage.purge(job_id)
                    release=True
                await redis.publish(job_id,'queued' if retry else 'failed',0)
    finally:
        try:
            if pulse:
                pulse.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pulse
            if owner and release:
                await redis.release(owner, job_id)
        finally:
            await storage.close()
            await redis.client.aclose()
            await db.pool.close()


async def drain_outbox(db):
    async with db.connection() as conn:
        rows = await (await conn.execute('SELECT job_id FROM job_outbox ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 50')).fetchall()
        for row in rows:
            identity = str(row['job_id'])
            await convert.configure(lock=identity).defer_async(job_id=identity)
            await conn.execute('DELETE FROM job_outbox WHERE job_id=%s', (row['job_id'],))


async def sweep(db, storage, redis):
    async with db.connection() as conn:
        recovered=await (await conn.execute("UPDATE jobs SET state=CASE WHEN attempt<3 THEN 'queued' ELSE 'failed' END,lease_token=NULL,lease_expires_at=NULL,error_code=CASE WHEN attempt>=3 THEN 'WORKER_LOST' ELSE NULL END WHERE state='running' AND lease_expires_at<now() AND expires_at>now() RETURNING id,state,device_id")).fetchall()
        for job in recovered:
            if job['state']=='queued':
                await conn.execute('INSERT INTO job_outbox(job_id) VALUES(%s) ON CONFLICT DO NOTHING',(job['id'],))
            else:
                await storage.purge(str(job['id']))
                await redis.release(str(job['device_id']),str(job['id']))
            await redis.publish(str(job['id']),job['state'],0)
        rows = await (await conn.execute("SELECT id,device_id FROM jobs WHERE expires_at<=now() OR state='deleted' ORDER BY last_purged_at ASC NULLS FIRST,expires_at FOR UPDATE SKIP LOCKED LIMIT 100")).fetchall()
        for row in rows:
            await storage.purge(str(row['id']))
            await redis.release(str(row['device_id']), str(row['id']))
            await conn.execute("UPDATE jobs SET state='deleted',extension=NULL,output_format=NULL,byte_length=NULL,sha256=NULL,report=NULL,options='{}',error_code=NULL,last_purged_at=now() WHERE id=%s", (row['id'],))
            # Presigned upload lifetime has elapsed. The row lock also fences any
            # in-flight completion, so this tombstone can now be removed safely.
            await conn.execute("DELETE FROM jobs WHERE id=%s AND state='deleted' AND created_at<now()-interval '6 minutes'", (row['id'],))
        await conn.execute('DELETE FROM challenges WHERE expires_at<now()')
        await conn.execute('DELETE FROM refresh_tokens WHERE expires_at<now()')


async def serve_worker():
    db = Database(settings.database_url.get_secret_value())
    await db.pool.open()
    redis = Redis(settings.upstash_redis_rest_url, settings.upstash_redis_rest_token.get_secret_value())
    storage=R2(settings)
    try:
        async with app.open_async():
            while True:
                await sweep(db, storage, redis)
                await drain_outbox(db)
                await app.run_worker_async(wait=False, concurrency=1, queues=['pdf'])
                await asyncio.sleep(5)
    finally:
        await storage.close()
        await db.pool.close()
        await redis.client.aclose()


if __name__ == '__main__':
    asyncio.run(serve_worker())
