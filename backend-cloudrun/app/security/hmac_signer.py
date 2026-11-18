import hashlib
import hmac
import secrets
import time
from fastapi import HTTPException


def signature(secret: str, timestamp: str, nonce: str, body: bytes) -> str:
    return hmac.new(secret.encode(), timestamp.encode()+b'\n'+nonce.encode()+b'\n'+body, hashlib.sha256).hexdigest()


def signed_headers(secret: str, token: str, body: bytes) -> dict[str, str]:
    timestamp, nonce = str(int(time.time())), secrets.token_hex(24)
    return {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json',
            'X-Timestamp': timestamp, 'X-Nonce': nonce,
            'X-Worker-Signature': signature(secret, timestamp, nonce, body)}


async def verify_dispatch(headers, body: bytes, secret: str, redis):
    timestamp, nonce = headers.get('x-timestamp', ''), headers.get('x-nonce', '')
    try:
        if abs(time.time()-int(timestamp)) > 60 or len(nonce) != 48:
            raise ValueError('Invalid freshness')
        bytes.fromhex(nonce)
    except ValueError as exc:
        raise HTTPException(401, 'Stale or invalid dispatch') from exc
    if not hmac.compare_digest(signature(secret, timestamp, nonce, body), headers.get('x-worker-signature', '')):
        raise HTTPException(401, 'Invalid worker signature')
    if await redis.command('SET', 'nonce:'+nonce, '1', 'NX', 'EX', 121) != 'OK':
        raise HTTPException(401, 'Replayed dispatch')
