-- 002_connections: harici PostgreSQL bağlantı tablosu (password_encrypted, ssh alanlari)
return {
  version = 2,
  name = "connections",
  up = {
    [[CREATE TABLE connections (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name VARCHAR(100) NOT NULL,
      host VARCHAR(255) NOT NULL,
      port INT NOT NULL CHECK (port BETWEEN 1 AND 65535),
      database VARCHAR(63) NOT NULL,
      username VARCHAR(63) NOT NULL,
      password_encrypted TEXT,
      save_password BOOLEAN NOT NULL DEFAULT false,
      ssh_enabled BOOLEAN NOT NULL DEFAULT false,
      ssh_host VARCHAR(255),
      ssh_port INT CHECK (ssh_port BETWEEN 1 AND 65535),
      ssh_username VARCHAR(255),
      ssh_auth_method VARCHAR(20) CHECK (ssh_auth_method IN ('password','private_key','agent')),
      ssh_private_key_path TEXT,
      ssh_save_secret BOOLEAN DEFAULT false,
      ssh_host_key_fingerprint TEXT,
      last_tested_at TIMESTAMPTZ,
      last_test_success BOOLEAN,
      last_test_latency_ms INT,
      created_at TIMESTAMPTZ DEFAULT now(),
      updated_at TIMESTAMPTZ DEFAULT now(),
      UNIQUE(user_id, name)
    )]],
    [[CREATE INDEX connections_user_id_idx ON connections(user_id)]],
    [[CREATE INDEX connections_host_idx ON connections(host)]],
  },
  down = {
    [[DROP TABLE IF EXISTS connections]],
  },
}
