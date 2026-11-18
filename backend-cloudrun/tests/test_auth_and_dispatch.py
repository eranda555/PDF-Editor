import base64
import os
import time
import unittest
from uuid import uuid4
import jwt
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from fastapi import HTTPException
from app.config import Settings
from app.models import JobInit
from app.security.auth import access_token, verify_proof, decode_bytes, new_refresh
from app.security.hmac_signer import signature, signed_headers, verify_dispatch


def settings():
    return Settings(_env_file=None, database_url='postgresql://localhost/pdf', jwt_secret='a'*48,
        r2_endpoint='https://bucket.example', r2_bucket='pdf', r2_access_key_id='access',
        r2_secret_access_key='secret', upstash_redis_rest_url='https://redis.example',
        upstash_redis_rest_token='token', worker_hmac_secret='b'*48, internal_token='c'*48)


class AuthTests(unittest.TestCase):
    def test_native_p256_der_proof(self):
        private=ec.generate_private_key(ec.SECP256R1())
        public=private.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        message='hardware registration proof'
        signed=base64.b64encode(private.sign(message.encode(),ec.ECDSA(hashes.SHA256()))).decode()
        verify_proof(public,signed,message,'p256')
        with self.assertRaises(HTTPException):
            verify_proof(public,signed,message+' changed','p256')

    def test_real_ed25519_proof(self):
        key = Ed25519PrivateKey.generate()
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        message = 'register\nchallenge\nnonce\npublic-key'
        proof = base64.b64encode(key.sign(message.encode())).decode()
        verify_proof(public, proof, message)
        with self.assertRaises(HTTPException):
            verify_proof(public, proof, message+'tampered')

    def test_jwt_expiry_issuer_and_audience(self):
        config = settings()
        identity = uuid4()
        token = access_token(config, identity)
        claims = jwt.decode(token, config.jwt_secret.get_secret_value(), algorithms=['HS256'],
                            audience='pdf-mobile', issuer=config.jwt_issuer)
        self.assertEqual(claims['sub'], str(identity))
        self.assertEqual(claims['exp']-claims['iat'], 900)
        with self.assertRaises(jwt.InvalidAudienceError):
            jwt.decode(token, config.jwt_secret.get_secret_value(), algorithms=['HS256'], audience='other')

    def test_refresh_is_hashed_and_random(self):
        token, digest = new_refresh()
        self.assertNotEqual(token, digest)
        self.assertEqual(len(digest), 64)
        self.assertNotEqual(new_refresh()[0], token)

    def test_reject_malformed_key(self):
        for value in ('!', base64.b64encode(b'short').decode()):
            with self.assertRaises(HTTPException):
                decode_bytes(value, 32)

    def test_schema_rejects_oversized_or_unexpected_arguments(self):
        for changes in ({'byte_length': 15_728_641}, {'extension': '../../pdf'}, {'injected': True}):
            payload = {'extension': 'pdf', 'byte_length': 10, 'sha256': 'a'*64, 'output_format': 'docx'}
            payload.update(changes)
            with self.assertRaises(ValueError):
                JobInit.model_validate(payload)

    def test_secrets_fail_closed(self):
        data = settings().model_dump()
        data['jwt_secret'] = 'short'
        with self.assertRaises(ValueError):
            Settings(_env_file=None, **data)

    def test_signed_headers_bind_exact_body(self):
        headers = signed_headers('secret', 'token', b'{"a":1}')
        self.assertEqual(headers['Authorization'], 'Bearer token')
        self.assertEqual(headers['X-Worker-Signature'], signature('secret', headers['X-Timestamp'], headers['X-Nonce'], b'{"a":1}'))
        self.assertNotEqual(headers['X-Worker-Signature'], signature('secret', headers['X-Timestamp'], headers['X-Nonce'], b'{"a":2}'))


class DispatchTests(unittest.TestCase):
    def test_expired_requests_rejected_before_nonce_store(self):
        timestamp, nonce = str(int(time.time())-61), os.urandom(24).hex()
        headers = {'x-timestamp': timestamp, 'x-nonce': nonce,
                   'x-worker-signature': signature('secret', timestamp, nonce, b'payload')}
        with self.assertRaises(HTTPException) as caught:
            verify_dispatch(headers, b'payload', 'secret', None).send(None)
        self.assertEqual(caught.exception.status_code, 401)

    def test_altered_body_rejected_before_nonce_store(self):
        signed = signed_headers('secret', 'token', b'payload')
        with self.assertRaises(HTTPException):
            verify_dispatch({key.lower(): value for key, value in signed.items()}, b'changed', 'secret', None).send(None)


if __name__ == '__main__':
    unittest.main()
