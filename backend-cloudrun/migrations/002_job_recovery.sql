ALTER TABLE jobs ADD COLUMN IF NOT EXISTS attempt integer NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS lease_token uuid;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS options jsonb NOT NULL DEFAULT '{}';
CREATE INDEX IF NOT EXISTS jobs_lease ON jobs(lease_expires_at) WHERE state='running';
