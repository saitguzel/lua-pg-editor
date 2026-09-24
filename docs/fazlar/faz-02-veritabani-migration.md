# ═══ FAZ 02 — VERİTABANI & MIGRATION ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — env §6, audit §8.

## Amaç

Meta DB (pgeditor) şemasını ve kendi migration runner'ımızı kurmak: users, connections, query_history, audit_logs, rbac, password_resets; pgcrypto, pg_advisory_lock, schema_migrations. Seed: rbac varsayılanları + pgeditor_demo demo verisi.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/migrations/001_users.lua` | pgcrypto + user_role enum + users |
| `002_connections.lua` | connection tablosu + index |
| `003_rbac.lua` | rbac_permissions + pages |
| `004_audit_logs.lua` | audit_logs + indexes |
| `005_password_resets.lua` | token_hash + ttl |
| `006_query_history.lua` | sorgu geçmişi (per connection/db) |
| `007_demo_seed_support.lua` | pgeditor_demo tabloları için helper (opsiyonel) |
| `api/seeds/rbac_defaults.lua` | types.default_matrix() → rbac_permissions seed |
| `api/seeds/default_users.lua` | admin/editor demo hesapları (SEED_DEFAULTS=true) |
| `api/seeds/demo_data.lua` | pgeditor_demo: customers/orders/analytics.page_views |
| `api/src/db/migrations.lua` | runner: up/down/status/seed, advisory lock |
| `api/src/db/pool.lua` | meta pool configure + warm |
| `Makefile` | `db.migrate` vb. |

## Migration Runner (db/migrations.lua)

- Tablo `schema_migrations (version int PK, name text, applied_at timestamptz)`.
- Her migration `{ version, name, up={sql}, down={sql} }`.
- `up`: `SELECT pg_try_advisory_lock(727727727)` → sıralı `version` için `SELECT ... FOR UPDATE` → her `up` tek transaction; `lock` alınamazsa `CONFLICT` log, exit 1.
- `down STEPS`: ters sırada.
- `status`: applied / pending listesi.
- CLI: `resty -I src -I lib src/db/migrations.lua up|down [n]|status|seed`.
- `seed`: her seed dosyası idempotent (`ON CONFLICT DO NOTHING` / `WHERE NOT EXISTS`).

## Şema Detayı

### 001_users.lua

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TYPE user_role AS ENUM ('admin','editor');
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  full_name VARCHAR(255),
  role user_role NOT NULL DEFAULT 'editor',
  is_active BOOLEAN DEFAULT true,
  last_login_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE users ADD CONSTRAINT users_email_lower CHECK (email = lower(email));
CREATE INDEX users_email_idx ON users(lower(email));
CREATE INDEX users_role_idx ON users(role);
```

Trigger `006`'da `updated_at` için `updated_at_trigger()`.

### 002_connections.lua

```sql
CREATE TABLE connections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  host VARCHAR(255) NOT NULL,
  port INT NOT NULL CHECK (port BETWEEN 1 AND 65535),
  database VARCHAR(63) NOT NULL,
  username VARCHAR(63) NOT NULL,
  password_encrypted TEXT, -- AES-GCM base64 (iv:cipher:tag)
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
);
CREATE INDEX connections_user_id_idx ON connections(user_id);
CREATE INDEX connections_host_idx ON connections(host);
```

Karar: `password_encrypted` → `save_password=false` ise NULL. SSH alanları `ssh_enabled=false` ise NULL. Parola düz metin asla saklanmaz.

### 003_rbac.lua

```sql
CREATE TABLE rbac_permissions (
  role user_role NOT NULL,
  page_key VARCHAR(64) NOT NULL,
  can_access BOOLEAN NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (role, page_key)
);
-- Seed: types.default_matrix() ile doldurulur
```

### 004_audit_logs.lua

```sql
CREATE TABLE audit_logs (
  id BIGSERIAL PRIMARY KEY,
  request_id UUID,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action VARCHAR(64) NOT NULL,
  entity_type VARCHAR(32) NOT NULL,
  entity_id TEXT,
  old_value JSONB,
  new_value JSONB,
  ip INET,
  user_agent TEXT,
  status VARCHAR(16) NOT NULL DEFAULT 'success' CHECK (status IN ('success','failure')),
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX audit_logs_user_id_idx ON audit_logs(user_id);
CREATE INDEX audit_logs_action_idx ON audit_logs(action);
CREATE INDEX audit_logs_entity_idx ON audit_logs(entity_type, entity_id);
CREATE INDEX audit_logs_created_at_idx ON audit_logs(created_at);
-- retention job için BRIN
CREATE INDEX audit_logs_created_at_brin ON audit_logs USING brin(created_at);
```

### 005_password_resets.lua

```sql
CREATE TABLE password_reset_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash VARCHAR(64) NOT NULL UNIQUE, -- sha256 hex
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX password_reset_tokens_user_id_idx ON password_reset_tokens(user_id);
CREATE INDEX password_reset_tokens_expires_at_idx ON password_reset_tokens(expires_at);
```

### 006_query_history.lua

```sql
CREATE TABLE query_history (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  connection_id UUID NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  database VARCHAR(63) NOT NULL,
  sql TEXT NOT NULL,
  row_count INT,
  duration_ms INT,
  truncated BOOLEAN DEFAULT false,
  executed_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX query_history_user_conn_idx ON query_history(user_id, connection_id, database);
CREATE INDEX query_history_executed_at_idx ON query_history(executed_at);
-- per-db son N sorgu hızlı
CREATE INDEX query_history_lookup_idx ON query_history(connection_id, database, executed_at DESC);
```

Retention: 30 gün (config `QUERY_HISTORY_RETENTION_DAYS`).

### Triggers (006_triggers.lua veya 001 içinde)

```sql
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER connections_updated_at BEFORE UPDATE ON connections FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

## Pool (db/pool.lua)

```lua
local pgmoon = require("pgmoon")
local _M = {}
local cfg
function _M.configure(c) cfg = c end
function _M.acquire() -- cosocket pool get
function _M.release(pg, broken) -- keepalive veya close
function _M.warm(n) -- init_worker'da n bağlantı açıp iada et
```

Ayarlar: `convert_null=true`, json deserializer, `TEXT[]` için `encode_array`.

## Seed

- `rbac_defaults.lua`: `INSERT INTO rbac_permissions ... ON CONFLICT DO NOTHING`
- `default_users.lua`: `admin@pgeditor.local / Admin123!`, `editor@pgeditor.local / Editor123!` (sadece SEED_DEFAULTS)
- `demo_data.lua`: pgeditor_demo.sql'den uyarlı — `customers`, `orders`, `audit_events`, `analytics.page_views` **hedef demo DB** için değil, meta demo bağlantısı değil; test için meta'da demo bağlantı `host=postgres db=pgeditor_demo` yaratılır, oraya uygulanır (ayrı migrate adımı).

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Kendi runner (Lapis migration değil) | pgmoon extended protocol, advisory lock |
| password_encrypted TEXT (iv:ct:tag) | pgcrypto `pgp_sym_encrypt` yerine app seviyesi AES-GCM → key rotation kolay |
| query_history ayrı tablo | audit_logs'tan ayrı (farklı retention, farklı index) |
| BRIN audit_logs | Zaman serisi, küçük index |
| Advisory lock | Çok instance migration çakışması önlenir |

## DoD

- [ ] `make db.migrate` → `schema_migrations` 6 satır, `make db.status` pending 0.
- [ ] `make db.migrate` ikinci kez idempotent (değişiklik yok).
- [ ] `make db.rollback STEPS=1 && make db.migrate` → 006 geri gelir.
- [ ] `SEED_DEFAULTS=true make db.seed` → 2 kullanıcı, RBAC 2×PAGES satır.
- [ ] `password_encrypted` kolonunda düz parola yok.
- [ ] Concurrent `migrate up` iki terminalde biri lock hatası (logda `advisory lock`).
