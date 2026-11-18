CREATE TABLE IF NOT EXISTS devices (
 id uuid PRIMARY KEY,
 public_key bytea UNIQUE NOT NULL CHECK(octet_length(public_key)=32),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS challenges (
 id uuid PRIMARY KEY,
 nonce text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT now()+interval '60 seconds'
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
 token_hash text PRIMARY KEY,
 device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
 expires_at timestamptz NOT NULL DEFAULT now()+interval '30 days'
);
CREATE TABLE IF NOT EXISTS jobs (
 id uuid PRIMARY KEY,
 device_id uuid NOT NULL REFERENCES devices(id),
 extension text,
 output_format text,
 byte_length integer,
 sha256 text,
 state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','queued','running','done','failed','deleted')),
 progress integer NOT NULL DEFAULT 0 CHECK(progress BETWEEN 0 AND 100),
 error_code text,
 report jsonb,
 last_purged_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '1 hour'
);
CREATE INDEX IF NOT EXISTS jobs_expiry ON jobs(expires_at);
CREATE INDEX IF NOT EXISTS jobs_owner ON jobs(device_id,state);
CREATE TABLE IF NOT EXISTS job_outbox (
 job_id uuid PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
