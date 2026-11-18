import hashlib
import secrets
from uuid import UUID, uuid4
from fastapi import APIRouter, HTTPException, Request, Depends
from typing import Literal
from pydantic import Field
from app.models import StrictModel
from app.security.auth import access_token, decode_bytes, new_refresh, verify_proof, current_device

router = APIRouter(prefix='/v1/auth', tags=['auth'])


class Registration(StrictModel):
    challenge_id: UUID
    public_key: str = Field(max_length=128)
    algorithm: Literal['ed25519','p256'] = 'ed25519'
    signature: str = Field(max_length=128)


class Refresh(StrictModel):
    challenge_id: UUID
    refresh_token: str = Field(min_length=32, max_length=128)
    signature: str = Field(max_length=128)


async def challenge_nonce(conn, challenge_id):
    row = await (await conn.execute('DELETE FROM challenges WHERE id=%s AND expires_at>now() RETURNING nonce', (challenge_id,))).fetchone()
    if not row:
        raise HTTPException(401, 'Challenge expired or used')
    return row['nonce']


@router.post('/challenge')
async def challenge(request: Request):
    ip = request.client.host if request.client else 'unknown'
    await request.app.state.redis.throttle('auth:'+hashlib.sha256(ip.encode()).hexdigest(), 30, 60)
    identity, nonce = uuid4(), secrets.token_urlsafe(32)
    await request.app.state.db.execute('INSERT INTO challenges(id,nonce) VALUES(%s,%s)', (identity, nonce))
    return {'challenge_id': str(identity), 'nonce': nonce, 'expires_in': 60}


@router.post('/register')
async def register(payload: Registration, request: Request):
    ip=request.client.host if request.client else 'unknown'
    await request.app.state.redis.throttle('register:'+hashlib.sha256(ip.encode()).hexdigest(),30,60)
    public_key = decode_bytes(payload.public_key, 65 if payload.algorithm=='p256' else 32)
    state = request.app.state
    async with state.db.connection() as conn:
        nonce = await challenge_nonce(conn, payload.challenge_id)
        verify_proof(public_key, payload.signature, f'register\n{payload.challenge_id}\n{nonce}\n{payload.public_key}',payload.algorithm)
        row = await (await conn.execute('INSERT INTO devices(id,public_key,key_algorithm) VALUES(%s,%s,%s) ON CONFLICT(public_key) DO UPDATE SET public_key=excluded.public_key RETURNING id,token_version', (uuid4(), public_key,payload.algorithm))).fetchone()
        device = row['id']
        token, digest = new_refresh()
        await conn.execute('INSERT INTO refresh_tokens(token_hash,device_id) VALUES(%s,%s)', (digest, device))
    return {'access_token': access_token(state.settings, device,row['token_version']), 'refresh_token': token,
            'device_id': str(device), 'expires_in': 900}


@router.post('/refresh')
async def refresh(payload: Refresh, request: Request):
    ip=request.client.host if request.client else 'unknown'
    await request.app.state.redis.throttle('refresh:'+hashlib.sha256(ip.encode()).hexdigest(),60,60)
    state = request.app.state
    digest = hashlib.sha256(payload.refresh_token.encode()).hexdigest()
    async with state.db.connection() as conn:
        nonce = await challenge_nonce(conn, payload.challenge_id)
        row = await (await conn.execute('SELECT r.device_id,d.public_key,d.key_algorithm,d.token_version FROM refresh_tokens r JOIN devices d ON d.id=r.device_id WHERE r.token_hash=%s AND r.expires_at>now() FOR UPDATE OF r', (digest,))).fetchone()
        if not row:
            raise HTTPException(401, 'Refresh token expired or revoked')
        verify_proof(bytes(row['public_key']), payload.signature, f'refresh\n{payload.challenge_id}\n{nonce}\n{digest}',row['key_algorithm'])
        token, new_digest = new_refresh()
        await conn.execute('DELETE FROM refresh_tokens WHERE token_hash=%s', (digest,))
        await conn.execute('INSERT INTO refresh_tokens(token_hash,device_id) VALUES(%s,%s)', (new_digest, row['device_id']))
    return {'access_token': access_token(state.settings, row['device_id'],row['token_version']), 'refresh_token': token,
            'device_id': str(row['device_id']), 'expires_in': 900}


@router.post('/revoke',status_code=204)
async def revoke(request: Request, device: UUID = Depends(current_device)):
    async with request.app.state.db.connection() as conn:
        await conn.execute('UPDATE devices SET token_version=token_version+1 WHERE id=%s',(device,))
        await conn.execute('DELETE FROM refresh_tokens WHERE device_id=%s',(device,))
