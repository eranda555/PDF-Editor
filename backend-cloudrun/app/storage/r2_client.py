import asyncio
from pathlib import Path
import boto3
from botocore.config import Config
from app.security.file_validator import InvalidFile


class R2:
    def __init__(self, settings):
        self.bucket = settings.r2_bucket
        self.client = boto3.client('s3', endpoint_url=settings.r2_endpoint,
            aws_access_key_id=settings.r2_access_key_id.get_secret_value(),
            aws_secret_access_key=settings.r2_secret_access_key.get_secret_value(),
            region_name='auto', config=Config(signature_version='s3v4', retries={'max_attempts': 3}))

    def put_url(self, job_id: str, size: int, output: bool = False) -> str:
        return self.client.generate_presigned_url('put_object', Params={
            'Bucket': self.bucket, 'Key': f'jobs/{job_id}/{"output" if output else "input"}.bin',
            'ContentLength': size, 'ContentType': 'application/octet-stream'}, ExpiresIn=300)

    def get_url(self, job_id: str, output: bool = False, seconds: int = 60) -> str:
        return self.client.generate_presigned_url('get_object', Params={'Bucket': self.bucket,
            'Key': f'jobs/{job_id}/{"output" if output else "input"}.bin'}, ExpiresIn=max(1, min(seconds, 300)))

    async def download(self, job_id: str, destination: Path, expected_size: int):
        def transfer():
            response = self.client.get_object(Bucket=self.bucket, Key=f'jobs/{job_id}/input.bin')
            body = response['Body']
            try:
                if response['ContentLength'] != expected_size or expected_size > 15_728_640:
                    raise InvalidFile('Object size mismatch')
                total = 0
                with destination.open('wb') as stream:
                    while chunk := body.read(64*1024):
                        total += len(chunk)
                        if total > expected_size:
                            raise InvalidFile('Object grew during transfer')
                        stream.write(chunk)
                if total != expected_size:
                    raise InvalidFile('Truncated object')
            finally:
                body.close()
        await asyncio.to_thread(transfer)

    async def upload(self, job_id: str, source: Path):
        if source.stat().st_size > 50_000_000:
            raise InvalidFile('Output size limit exceeded')
        await asyncio.to_thread(self.client.upload_file, str(source), self.bucket, f'jobs/{job_id}/output.bin')

    async def purge(self, job_id: str):
        result=await asyncio.to_thread(self.client.delete_objects, Bucket=self.bucket,
            Delete={'Objects': [{'Key': f'jobs/{job_id}/{part}.bin'} for part in ('input', 'output')], 'Quiet': True})
        if result.get('Errors'):
            raise RuntimeError('Object deletion could not be confirmed')

    async def close(self):
        await asyncio.to_thread(self.client.close)
