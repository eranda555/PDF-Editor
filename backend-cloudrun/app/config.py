from functools import lru_cache
from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', extra='ignore')
    database_url: SecretStr
    jwt_secret: SecretStr
    jwt_issuer: str = '100-percent-pdf-suite'
    r2_endpoint: str
    r2_bucket: str
    r2_access_key_id: SecretStr
    r2_secret_access_key: SecretStr
    upstash_redis_rest_url: str
    upstash_redis_rest_token: SecretStr
    worker_url: str = ''
    hf_token: SecretStr = SecretStr('')
    worker_hmac_secret: SecretStr
    internal_token: SecretStr
    gemini_api_key: SecretStr = SecretStr('')
    gemini_model: str = 'gemini-3.8-flash'
    gemini_fallback: str = 'gemini-3.5-flash-lite'
    cloud_enabled: bool = False
    ai_enabled: bool = False
    global_daily_jobs: int = Field(default=100, ge=1, le=10000)
    max_bytes: int = 15_728_640
    max_pages: int = 20
    retention_seconds: int = 3600
    subprocess_timeout: int = 180

    @model_validator(mode='after')
    def strong_secrets(self):
        for key in ('jwt_secret', 'worker_hmac_secret', 'internal_token'):
            if len(getattr(self, key).get_secret_value()) < 32:
                raise ValueError(f'{key} must contain at least 32 characters')
        if not self.upstash_redis_rest_url.startswith(('https://', 'http://redis:')):
            raise ValueError('Redis REST URL must use HTTPS outside local Compose')
        if self.worker_url and not self.worker_url.startswith(('https://','http://heavy:')):
            raise ValueError('Worker URL must use HTTPS outside local Compose')
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
