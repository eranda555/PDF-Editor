from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class WorkerSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', extra='ignore')
    r2_endpoint: str
    upstash_redis_rest_url: str
    upstash_redis_rest_token: SecretStr
    worker_hmac_secret: SecretStr = Field(min_length=32)
    hf_token: SecretStr = Field(min_length=16)
    ai_enabled: bool = False
    gemini_api_key: SecretStr = SecretStr('')
    gemini_model: str = 'gemini-3.8-flash'
    gemini_fallback: str = 'gemini-3.5-flash-lite'
