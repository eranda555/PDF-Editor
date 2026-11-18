ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_public_key_check;
ALTER TABLE devices ADD CONSTRAINT devices_public_key_check CHECK(octet_length(public_key) IN (32,65));
ALTER TABLE devices ADD COLUMN IF NOT EXISTS key_algorithm text NOT NULL DEFAULT 'ed25519' CHECK(key_algorithm IN ('ed25519','p256'));
ALTER TABLE devices ADD COLUMN IF NOT EXISTS token_version integer NOT NULL DEFAULT 0;
