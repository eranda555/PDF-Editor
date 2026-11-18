import base64
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4
import jwt
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

bearer = HTTPBearer(auto_error=False)


def decode_bytes(value: str, length: int) -> bytes:
    try:
        data = base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise HTTPException(422, 'Invalid base64') from exc
    if len(data) != length:
        raise HTTPException(422, 'Invalid key or signature length')
    return data


def verify_proof(key: bytes, signature: str, message: str, algorithm: str = 'ed25519'):
    try:
        if algorithm=='ed25519':
            Ed25519PublicKey.from_public_bytes(key).verify(decode_bytes(signature, 64), message.encode())
        elif algorithm=='p256':
            proof=base64.b64decode(signature,validate=True)
            if len(proof)>80:
                raise ValueError('Oversized ECDSA signature')
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),key).verify(proof,message.encode(),ec.ECDSA(hashes.SHA256()))
        else:
            raise ValueError('Unknown key algorithm')
    except (InvalidSignature, ValueError) as exc:
        raise HTTPException(401, 'Invalid device proof') from exc


def access_token(settings, device_id: UUID, version: int = 0) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode({'sub': str(device_id), 'iss': settings.jwt_issuer,
                       'aud': 'pdf-mobile', 'iat': now, 'exp': now+timedelta(minutes=15),
                       'jti': str(uuid4()),'ver':version}, settings.jwt_secret.get_secret_value(), algorithm='HS256')


def new_refresh() -> tuple[str, str]:
    token = secrets.token_urlsafe(48)
    return token, hashlib.sha256(token.encode()).hexdigest()


async def current_device(request: Request, credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> UUID:
    if not credentials:
        raise HTTPException(401, 'Bearer token required')
    settings = request.app.state.settings
    try:
        claims = jwt.decode(credentials.credentials, settings.jwt_secret.get_secret_value(),
                            algorithms=['HS256'], audience='pdf-mobile', issuer=settings.jwt_issuer,
                            options={'require': ['exp', 'iat', 'sub', 'jti']})
        device_id=UUID(claims['sub'])
        await request.app.state.redis.throttle(f'requests:{device_id}',240,60)
        device=await request.app.state.db.one('SELECT token_version FROM devices WHERE id=%s',(device_id,))
        if not device or device['token_version']!=claims.get('ver'):
            raise HTTPException(401,'Device session revoked')
        return device_id
    except (jwt.InvalidTokenError, ValueError, KeyError) as exc:
        raise HTTPException(401, 'Invalid or expired access token') from exc
