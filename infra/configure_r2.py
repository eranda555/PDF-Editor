"""Apply Cloudflare's bucket lifecycle API (seconds), not S3's day-only schema."""
import json
import os
from pathlib import Path
import httpx


def main():
    account, bucket, token = (os.environ[key] for key in ('CLOUDFLARE_ACCOUNT_ID', 'R2_BUCKET', 'CLOUDFLARE_API_TOKEN'))
    payload = json.loads(Path(__file__).with_name('r2_lifecycle_policy.json').read_text())
    response = httpx.put(f'https://api.cloudflare.com/client/v4/accounts/{account}/r2/buckets/{bucket}/lifecycle',
        headers={'Authorization': 'Bearer '+token}, json=payload, timeout=30)
    response.raise_for_status()
    if not response.json().get('success'):
        raise RuntimeError('Lifecycle configuration rejected')
    print('Lifecycle policy applied. Provider deletion is asynchronous; deploy the explicit purge scheduler too.')


if __name__ == '__main__':
    main()
