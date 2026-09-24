-- 005_password_resets: parola sıfırlama token tablosu
-- Token hash SHA256 ile saklanır, ham token asla yazılmaz.
return {
  version = 5,
  name = "password_resets",
  up = {
    [[CREATE TABLE password_reset_tokens (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash VARCHAR(64) NOT NULL UNIQUE,
      expires_at TIMESTAMPTZ NOT NULL,
      used_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX password_reset_tokens_user_id_idx ON password_reset_tokens(user_id)]],
    [[CREATE INDEX password_reset_tokens_expires_at_idx ON password_reset_tokens(expires_at)]],
  },
  down = {
    [[DROP TABLE IF EXISTS password_reset_tokens]],
  },
}
