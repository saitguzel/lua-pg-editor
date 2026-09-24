# ═══ FAZ 06 — BAĞLANTI YÖNETİMİ ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7, audit §8, env §6 (ENCRYPTION_KEY, TARGET_POOL).

## Amaç

PostgreSQL bağlantı yönetimi: kullanıcı başına CRUD, parolanın AES-GCM ile şifreli saklanması, `POST /connections/:id/test` ile gerçek bağlantı testi ve hedef DB havuz yönetimi.

## Önkoşullar

- F2 (connections tablosu, pool), F4 (crypto), F5 (auth).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/connections.lua` | REST handler 5 endpoint |
| `api/src/services/connections_service.lua` | iş kuralları, sahiplik, decrypt/pool |
| `api/src/repositories/connection_repo.lua` | find_by_id, find_by_user, create, update, delete |
| `api/src/db/pool_manager.lua` | (F3'te iskelet, burada tam) LRU havuz |
| `api/src/models/connection.lua` | from_row, serialize (parola maskeli) |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `GET` | `/connections` | ✅ | `connections.list` | Kendi bağlantıları listele (page/per_page/search) |
| `POST` | `/connections` | ✅ | `connections.create` | Yeni bağlantı oluştur + test opsiyonel |
| `GET` | `/connections/:id` | ✅ | `connections.list` | Tek bağlantı (sahiplik kontrol) |
| `PUT` | `/connections/:id` | ✅ | `connections.create` | Güncelle (parola boşsa dokunma) |
| `DELETE` | `/connections/:id` | ✅ | `connections.create` | Sil |
| `POST` | `/connections/:id/test` | ✅ | `connections.create` | Gerçek TCP connect + `SELECT 1` (timeout 3s) |
| `GET` | `/connections/:id/databases` | ✅ | `connections.list` | Hedefte DB listesi (`SELECT datname FROM pg_database WHERE datistemplate=false`) |

`PUT` gövdesi `connection_create` şemasının `partial`'ı (validate_partial). `password` alanı gönderilmezse mevcut şifreli değer korunur; `password: ""` + `save_password:false` → şifreyi temizle.

## Handler (connections.lua öz)

```lua
local function list(self)
  local q = validation.validate(validation.schemas.pagination, self.params)
  local rows, meta = connections_service.list(ngx.ctx.identity, q)
  return { status=200, json={ data=rows, meta=meta } }
end
local function create(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.connection_create, body); if not clean then return errors.respond(errors.validation(v)) end
  local conn, e = connections_service.create(ngx.ctx.identity, clean); if not conn then return errors.respond(e) end
  return { status=201, json={ data=conn } }
end
local function test(self)
  local id, e = errors.require_uuid_param(self,"id","CONNECTION_NOT_FOUND"); if not id then return errors.respond(e) end
  local res, err = connections_service.test_connection(ngx.ctx.identity, id); if not res then return errors.respond(err) end
  return { status=200, json={ data=res } } -- { success, latency_ms, pg_version }
end
```

## Service (connections_service.lua)

```lua
function _M.list(identity, q)
  -- q.search → ILIKE %search% (host/name/database/username)
  -- RBAC: editor kendi bağlantılarını, admin kendi + ?all=true ile hepsi (opsiyonel)
  return connection_repo.find_by_user(identity.user_id, q)
end
function _M.create(identity, input)
  -- name unique per user → CONFLICT
  -- crypto.encrypt(input.password) → password_encrypted
  -- ssh validasyonu: ssh_enabled true ise host/port/username required
  -- with_transaction: insert + audit connection.create
  -- pool_manager.invalidate değil (yeni)
end
function _M.update(identity, id, input)
  -- find + ownership (yoksa CONNECTION_NOT_FOUND 404, sızıntı yok)
  -- name değiştiyse unique check
  -- password: input.password == nil → dokunma; "" → temizle; dolu → re-encrypt
  -- audit old/new maskeli
  -- pool_manager.invalidate(id) (sifreli parola değişti)
end
function _M.test_connection(identity, id)
  -- find + ownership
  -- decrypt → pool_manager.acquire (connect + SELECT 1)
  -- latency ölçüm: ngx.now()
  -- update last_tested_at, last_test_success
  -- audit connection.test failure da kaydedilir
  -- hata → CONNECTION_FAILED (502) + details.db_message (maskeli, parola yok)
end
```

**Parola akışı:**

- Giriş: `input.password` (düz) → `crypto.encrypt` → `password_encrypted` (iv:ct:tag base64).
- Okuma: `serialize` → `has_password = password_encrypted ~= nil`, `password = "***"` maskeli, düz asla dönmez. Frontend formda `password` input boş bırakılırsa "değiştirme" demek.
- SSH `ssh_password`, `ssh_key_passphrase` için aynı kolon yok — şimdilik `ssh_save_secret` true ise `crypto.encrypt` ile aynı mekanizma; stub (F6'da validasyon, F10+ tünel).

**Pool Manager (hedef):**

```lua
local pools = lru.new(TARGET_POOL_MAX, COMPLETION_CACHE_TTL) -- key = connection.id
function pool_manager.acquire(conn) -- conn = row (host/port/db/user + decrypted)
  local key = conn.id
  local pool = pools:get(key)
  if pool then return pool end
  -- yeni pgmoon instance → connect_options: host, port, database, user, password (decrypted)
  -- pg:connect() → pool = { pg=pg, last_used=ngx.now(), connection_id=key }
  -- pools:set(key, pool)
end
function pool_manager.release(conn_id, pool, broken)
  if broken then pool.pg:close(); pools:delete(conn_id) else pool.pg:keepalive(TARGET_POOL_IDLE, TARGET_POOL_SIZE) end
end
```

Keepalive: `TARGET_POOL_IDLE = 60_000`, `TARGET_POOL_SIZE` 5. Toplam hedef bağlantı bütçesi: `replicas * workers * TARGET_POOL_SIZE * active_connections` ≤ dış PG `max_connections`. Harici DB'lerde limit bizde değil; bu yüzden `TARGET_POOL_SIZE` küçük (5).

## Validation (pg_shared)

`connection_create`:
- `name`: string 1..100 trim required
- `host`: host() required (unix socket `/var/run/...` de geçerli)
- `port`: integer 1..65535
- `database`: sql_identifier required
- `username`: sql_identifier required
- `password`: optional string 0..255 (boş izin → sil)
- `save_password`: boolean default false
- `ssh_enabled`: boolean default false
- `ssh_host` … `ssh_host_key_fingerprint`: nullable, ssh_enabled true ise required

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Parola AES-GCM (app layer) | pgcrypto yerine key rotation, backup şifreleme bağımsız |
| Test endpoint ayrı | Create sırasında test zorunlu değil (offline host), ama UI "Test Et" butonu için lazım |
| has_password boolean dönmek | Frontend "Kayıtlı parola var" rozeti |
| LRU havuz | Sınırsız havuz bellek sızdırır; 32 giriş yeterli |
| Unix socket host | `/var/run/postgresql` gibi path → pool host direkt socket path |

## DoD

- [ ] `POST /connections` → `201`, `GET /connections` listeler, başkası `GET /connections/:id` → `404 CONNECTION_NOT_FOUND`.
- [ ] `PUT /connections/:id` parola boş → eski şifre korunur; yeni parola → `password_encrypted` değişir, `pool_manager` invalid.
- [ ] Aynı user aynı `name` ikinci kez → `409 CONFLICT`.
- [ ] `POST /connections/:id/test` doğru → `{ success:true, latency_ms, pg_version }`, yanlış host → `502 CONNECTION_FAILED`.
- [ ] `GET /connections/:id/databases` → `["postgres","pg-editor_demo", ...]`.
- [ ] Audit `connection.(create|update|delete|test)` kayıtlı, parolalar `***`.
- [ ] `ENCRYPTION_KEY` yanlış → `decrypt` log `decrypt failed`, test `CONNECTION_FAILED` değil `INTERNAL_ERROR` değil.
