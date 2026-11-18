import time
import json
import httpx
from fastapi import HTTPException

# All three sets change in one Redis transaction; active leases expire with retention.
RESERVE = """
local t=tonumber(ARGV[1]); local id=ARGV[2]
redis.call('ZREMRANGEBYSCORE',KEYS[1],'-inf',t-3600)
redis.call('ZREMRANGEBYSCORE',KEYS[2],'-inf',t)
redis.call('ZREMRANGEBYSCORE',KEYS[3],'-inf',t-86400)
if redis.call('ZCARD',KEYS[1])>=15 then return 1 end
if redis.call('ZCARD',KEYS[2])>=3 then return 2 end
if redis.call('ZCARD',KEYS[3])>=tonumber(ARGV[3]) then return 3 end
redis.call('ZADD',KEYS[1],t,id)
redis.call('ZADD',KEYS[2],t+3600,id)
redis.call('ZADD',KEYS[3],t,id)
redis.call('EXPIRE',KEYS[1],3601); redis.call('EXPIRE',KEYS[2],3601)
redis.call('EXPIRE',KEYS[3],86401); return 0
"""
WINDOW = """
local n=redis.call('INCR',KEYS[1])
if n==1 then redis.call('EXPIRE',KEYS[1],ARGV[1]) end
return n
"""


class Redis:
    def __init__(self, url: str, token: str):
        self.client = httpx.AsyncClient(base_url=url.rstrip('/'), headers={'Authorization': f'Bearer {token}'}, timeout=10)

    async def command(self, *args):
        response = await self.client.post('/', json=list(args))
        response.raise_for_status()
        payload = response.json()
        if payload.get('error'):
            raise RuntimeError('Redis command failed')
        return payload['result']

    async def reserve(self, device_id: str, job_id: str, global_limit: int):
        code = await self.command('EVAL', RESERVE, 3, f'{{pdfquota}}:rate:{device_id}',
                                  f'{{pdfquota}}:active:{device_id}', '{pdfquota}:global:jobs', int(time.time()), job_id, global_limit)
        if code:
            raise HTTPException(429, ['','Hourly quota exceeded','Three jobs already active','Daily service quota reached'][code])

    async def release(self, device_id: str, job_id: str):
        await self.command('ZREM', f'{{pdfquota}}:active:{device_id}', job_id)

    async def throttle(self, key: str, limit: int, seconds: int):
        count = await self.command('EVAL', WINDOW, 1, key, seconds)
        if count > limit:
            raise HTTPException(429, 'Request rate exceeded')

    async def publish(self, job_id: str, state: str, progress: int):
        await self.command('PUBLISH', f'progress:{job_id}', json.dumps({'state':state,'progress':progress}))

    async def subscribe(self, job_id: str):
        # Upstash's REST Pub/Sub stream is SSE. Subscription acknowledgement is
        # consumed before the caller reads the authoritative DB snapshot.
        async with self.client.stream('GET', f'/subscribe/progress:{job_id}', timeout=None) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if not line.startswith('data:'):
                    continue
                payload=line[5:].strip()
                try:
                    value=json.loads(payload)
                except json.JSONDecodeError:
                    value=payload.split(',',2)
                if isinstance(value,list) and value[0]=='subscribe':
                    yield None
                elif isinstance(value,list) and len(value)>2 and value[0]=='message':
                    yield json.loads(value[2])
