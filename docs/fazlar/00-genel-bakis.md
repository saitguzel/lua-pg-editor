# ═══ 00 — GENEL BAKIŞ VE ORTAK SÖZLEŞMELER ═══

> Bu doküman tüm faz dokümanlarının **tek doğruluk kaynağıdır** (single source of truth).
> Error kodları, ortam değişkenleri, audit olay adları, shared dict'ler, sayfa anahtarları
> ve katman kuralları burada tanımlanır; faz dokümanları bunlara referans verir, yeniden tanımlamaz.
> Bir faz dokümanı ile bu doküman çelişirse **bu doküman geçerlidir** ve faz dokümanı düzeltilir.

---

## 1. Ürün Özeti

**lua-pg-editor (pgLua)**, OpenResty/Lapis + Wasmoon (Lua 5.4 WASM) + Tailwind + CodeMirror 6 ile sıfırdan tasarlanmış özgün bir **PostgreSQL web istemcisi** ve **SQL editörüdür**.

| Bileşen | Teknoloji | Çalıştığı yer | Sorumluluk |
|---|---|---|---|
| `pg-api` | OpenResty 1.25+ / LuaJIT / Lapis / pgmoon | Sunucu (Docker) | REST API, auth, RBAC, audit, zamanlanmış işler, sorgu motoru, DDL ajanları, Swagger |
| `pg-web` | Lua 5.4 (Wasmoon, WASM) + ince JS glue | Tarayıcı | SPA: kendi render motoru, reducer tabanlı state, hash router, çok sekmeli editör |
| `pg-shared` | Saf Lua (5.1 ∩ 5.4 alt kümesi) | Her ikisi | Tipler/enum'lar, doğrulama şemaları, protokol (error kodları, HTTP map) |
| `pg-meta` | PostgreSQL `information_schema` + `pg_catalog` | Sunucu | Şema keşfi, yapı incelemesi |

### Çekirdek Özellikler

| # | Özellik | Açıklama |
|---|---|---|
| 1 | PostgreSQL bağlantılarını kaydet / yeniden aç | `connections` CRUD + test + şifreli saklama (vault yerine AES-GCM) |
| 2 | Parolayı Keyring'de güvenli saklama | Vault: Argon2id ile türetilmiş anahtar → AES-256-GCM ile kolon seviyesi şifreleme + `*_FILE` secret |
| 3 | Tablo ve view'ları listele | `GET /databases/:id/schemas` — `information_schema.tables` (BASE TABLE, VIEW) |
| 4 | Tablo yapısını incele (kolonlar, index, constraint, FK, trigger) | `GET /objects/:schema/:name/structure` — 6 ayrı sorgu birleştirilir |
| 5 | Sözdizimi vurgulama, satır numarası, şema duyarlı tamamlama | Frontend: `GtkSourceView` yerine **CodeMirror 6** (JS) ↔ Lua köprüsü + `/completion` katalogu |
| 6 | Veritabanı başına otomatik sorgu geçmişi | `query_history` tablosu + `POST /query/history` (otomatik), `GET /query/history` |
| 7 | Tablo satırlarını sayfala / filtrele / özel SQL filtresi / hücre düzenle | `GET /objects/.../rows?page&per_page&sort&filter&custom_where` + `PATCH /rows` |
| 8 | Tablo tarayıcıdan ekle / çoğalt / sil | `POST /objects/.../rows` (insert), `POST /rows/:id/duplicate`, `DELETE /rows` |
| 9 | Sonuçları CSV olarak dışa aktar | `POST /query/csv` → `BEGIN READ ONLY` + `COPY ... TO STDOUT CSV` → streaming |
| 10 | Obje kenar çubuğundan yaygın tablo scriptleri üret | `GET /objects/:schema/:name/script?kind=select|insert|create|drop` |
| 11 | Kenar çubuğundan yeniden adlandır / truncate / sil | `POST /objects/:schema/:name/rename|truncate|drop` (transaction + audit) |
| 12 | SSH tünel (opsiyonel) | Faz-06'da **stub**: kolonlar var, validasyon var, tünel kurulumu Faz-10+'da veya `future` olarak işaretli |
| 13 | Çoklu DB, çoklu sekme, demolar | `pgeditor_demo` demo DB (customers/orders) migrate/seeds içinde; sekme state Lua store'da |

**Olmayan / farklı hedefler:**
- Tek motor: yalnızca **PostgreSQL** (odaklı tasarım), MySQL/Maria/SQLite yok.
- Native menüler, Tray yok — web header + sidebar + command palette ile karşılanır.
- Electron yok — Wasmoon WASM (~300 KB) + Tailwind (~30 KB) toplamı son derece hafif ve hızlı.

Kullanıcı rolleri: `admin`, `editor` (sayfa bazlı RBAC).

---

## 2. Mimari Diyagram

```
            ┌───────────────────────────── Tarayıcı ──────────────────────────────┐
            │  index.html → boot.js → glue.js → Wasmoon (Lua 5.4 VM, WASM)         │
            │    main.lua → app.lua (store/reducer) → router.lua → views/*.lua      │
            │    dom.lua ←→ JS DOM     fetch.lua ←→ window.fetch (Promise→coroutine)│
            │    editor.lua ←→ CodeMirror 6 (vurgulama, completion)                │
            │    shared/{types,validation,protocol}.lua  (backend ile AYNI kod)     │
            └──────────────────────────────┬───────────────────────────────────────┘
                                           │ HTTPS · JSON · Authorization: Bearer <jwt>
            ┌──────────────────────────────▼───────────────────────────────────────┐
            │ OpenResty (nginx)                                                     │
            │  init_by_lua        → config.load() + assert                          │
            │  init_worker_by_lua → jobs.*.start() (yalnızca worker 0 + advisory lock)│
            │  content_by_lua     → lapis.serve("app")                              │
            │                                                                       │
            │  Middleware zinciri:                                                  │
            │   cors → logger → audit_context → auth → authorization → handler      │
            │                                                                       │
            │  handlers/* → services/* → repositories/* → db/query → pgmoon         │
            │                   └→ audit_service.record(...)                        │
            │                   └→ connections_service → crypto (AES-GCM)           │
            │                   └→ query_service → pool_manager (hedef DB'ye)       │
            │  lua_shared_dict: rbac_cache | jwt_denylist | rate_limit | job_locks  │
            │  connection pool: (1) meta DB (pgmoon keepalive)                      │
            │                  (2) hedef DB havuzları (pool_manager, LRU)           │
            └──────────────┬───────────────────────────┬───────────────────────────┘
                           │ meta DB (kullanıcılar,    │ hedef PostgreSQL'ler
                           │  bağlantılar, audit,      │ (kullanıcının tanımladığı
                           │  query_history)           │  herhangi bir PG)
                 ┌─────────▼─────────┐       ┌─────────▼─────────┐
                 │ PostgreSQL 15+    │       │ PostgreSQL *      │
                 │ (meta)            │       │ (harici)          │
                 └───────────────────┘       └───────────────────┘
```

**İki tür DB bağlantısı:**

1. **Meta DB** (`DB_HOST/DB_NAME`): uygulamanın kendi Postgres'i — kullanıcılar, kayıtlı bağlantılar, RBAC, audit, sorgu geçmişi.
2. **Hedef DB(ler)**: kullanıcının eklediği harici Postgres sunucuları — şema keşfi, sorgu çalıştırma, tablo tarayıcı, DDL. Her kayıtlı bağlantı için **ayrı bir pgmoon havuzu** (host+port+db+user anahtarlı, LRU 32 giriş, idle 5 dk).

---

## 3. İstek Yaşam Döngüsü (Backend)

Örnek: `POST /api/v1/query/execute` (SQL çalıştırma)

1. **nginx** → `content_by_lua_block { require("lapis").serve("app") }`.
2. **Lapis** route eşleşmesi; route `router.lua`'da `chain(middlewares, handler)` ile sarılı.
3. **cors**: `OPTIONS` preflight → `204`/`403`; diğer header'lar `header_filter_by_lua`da.
4. **logger**: `ngx.ctx.req_id = uuid4()`, `ngx.ctx.started_at = ngx.now()`; `X-Request-Id` header.
5. **audit_context**: `ngx.ctx.audit = { ip, user_agent }`.
6. **auth**: `Bearer` → `jwt.verify` → `typ=="access"` → denylist → `ngx.ctx.identity`.
7. **authorization(`"query.execute"`)**: `rbac_service.can(role, page_key)` → değilse `403` + `access.denied` audit.
8. **handler**: `errors.read_json_body()` → `validation.validate(schema, body)` → `query_service.execute(identity, input)`.
9. **service**: iş kuralları, bağlantı sahipliği kontrolü, `crypto.decrypt(connection.password_encrypted)` → `pool_manager.acquire(connection)` → `query_target(...)` → `audit_service.record(...)` + `query_history_repo.insert(...)` (RECOMPILE: şema değişti mi → `completion` invalidation).
10. **repository (meta)**: parametreli SQL `$1,$2` → `db/query.lua` → pgmoon (meta DB).
11. **pool_manager (hedef)**: hedef DB'ye doğrudan pgmoon `connect()` → sorgu → `keepalive`.
12. **error_handler**: `xpcall` → `protocol.http_status(code)` → JSON `{ error = { code, message, details, req_id } }`.
13. **logger (log fazı)**: `log_by_lua` tek satır log (`req_id, method, path, status, duration_ms, user_id`); query string loglanmaz.

---

## 4. Katman Kuralları (İhlal = Code Review Red)

| Katman | Yapabilir | Yapamaz |
|---|---|---|
| `handlers/` | `self.params`, body parse, validation, service çağrısı, HTTP response şekli | SQL yazmak, repo çağırmak, hedef DB'ye bağlanmak |
| `services/` | İş kuralı, transaction sınırı, audit, birden fazla repo + `pool_manager` orkestrasyonu | HTTP status seçmek (sadece error code), `self` görmek, ham SQL |
| `repositories/` | Parametreli SQL (meta DB), satır → model dönüşümü | İş kuralı, audit, HTTP, hedef DB |
| `models/` | Saf veri: `from_row`, `serialize`, maskeleme | I/O |
| `db/` | Bağlantı, havuz, transaction, migration (meta), `pool_manager` hedef | Tablo bilgisi |
| `db/target/` | Hedef DB'ye pgmoon ile sorgu (read-only guard, limit, export) | Meta DB |
| `security/` | Kripto primitifleri (AES-GCM, JWT, Argon2) | DB, HTTP |
| `middleware/` | `ngx.ctx` yazmak, erken dönüş | İş kuralı |

**Service sözleşmesi:** `return result` | `return nil, errors.new(code, message, details)` — handler `errors.respond(err)`.

---

## 5. Hata Modeli ve Error Kodları (Kanonik Liste)

Tüm hatalar:

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Girdi doğrulanamadı",
    "details": { "title": ["zorunlu alan"] },
    "req_id": "5b1d9c-..."
  }
}
```

`shared/src/protocol.lua` tanımlıdır:

| Kod | HTTP | Kullanım |
|---|---|---|
| `VALIDATION_FAILED` | 422 | Şema hatası; `details` = alan → mesaj listesi |
| `BAD_REQUEST` | 400 | JSON parse, bozuk parametre, custom_where parse |
| `UNAUTHORIZED` | 401 | Token yok / geçersiz imza |
| `TOKEN_EXPIRED` | 401 | Access süresi doldu (frontend refresh) |
| `TOKEN_REVOKED` | 401 | Denylist |
| `INVALID_CREDENTIALS` | 401 | Login başarısız (email/parola ayrımı yok) |
| `ACCOUNT_DISABLED` | 403 | `is_active = false` |
| `FORBIDDEN` | 403 | RBAC reddi |
| `NOT_FOUND` | 404 | Genel |
| `CONNECTION_NOT_FOUND` | 404 | Bağlantı yok **veya başkasına ait** (sızıntı önleme) |
| `DATABASE_NOT_FOUND` | 404 | Hedef DB listesinde yok |
| `OBJECT_NOT_FOUND` | 404 | Tablo/view yok |
| `USER_NOT_FOUND` | 404 | |
| `QUERY_FAILED` | 422 | Hedef DB sorgu hatası; `details.sqlstate`, `details.db_message` (maskeli) |
| `READONLY_VIOLATION` | 422 | Export/read-only ihlali (`BEGIN READ ONLY` guard) |
| `ROW_NOT_FOUND` | 404 | Satır yok |
| `EMAIL_TAKEN` | 409 | Unique |
| `CONFLICT` | 409 | Genel çakışma |
| `LAST_ADMIN` | 409 | Son admin silinemez |
| `SELF_ACTION_FORBIDDEN` | 409 | Kendini silme/düşürme |
| `RESET_TOKEN_INVALID` | 400 | Reset token |
| `CONNECTION_FAILED` | 502 | Hedef DB'ye bağlanılamadı |
| `RATE_LIMITED` | 429 | `Retry-After` |
| `PAYLOAD_TOO_LARGE` | 413 | Body > 1 MiB, Sorgu > 100 KB, Row limit aşımı |
| `INTERNAL_ERROR` | 500 | Beklenmeyen |
| `MAIL_FAILED` | 502 | SMTP (forgot yine 202) |
| `DB_UNAVAILABLE` | 503 | Meta DB down |

İstemci-yerel (`protocol.lua`ya **eklenmez**): `NETWORK_ERROR`, `INVALID_RESPONSE`.

`QUERY_FAILED` detayında `sqlstate` (örn. `42P01` undefined_table) ve `constraint` map edilir; `CONNECTION_FAILED` hedef DB hatasıdır, `DB_UNAVAILABLE` meta DB hatasıdır.

---

## 6. Ortam Değişkenleri (Kanonik Liste)

`api/src/config.lua` bu listeyi okur; `.env.example` birebir aynıdır.

| Değişken | Varsayılan | Tip | Not |
|---|---|---|---|
| `APP_ENV` | `development` | enum | `development\|test\|production` |
| `APP_PORT` | `8080` | int | konteyner içi listen |
| `APP_BASE_URL` | `http://localhost:28080` | url | Swagger servers |
| `WEB_BASE_URL` | `http://localhost:28000` | url | Reset link |
| `DB_HOST` | `postgres` | string | meta DB host |
| `DB_PORT` | `5432` | int | |
| `DB_NAME` | `pgeditor` | string | meta DB adı |
| `DB_USER` | `pgeditor` | string | |
| `DB_PASSWORD` | — | string | zorunlu; prod ≥16 |
| `DB_SSL` | `false` | bool | |
| `DB_POOL_SIZE` | `20` | int | meta havuz (worker başına) |
| `DB_POOL_IDLE_TIMEOUT_MS` | `60000` | int | |
| `DB_CONNECT_TIMEOUT_MS` | `3000` | int | |
| `DB_QUERY_TIMEOUT_MS` | `10000` | int | |
| `JWT_SECRET` | — | string | ≥32 byte; prod örnek reddedilir |
| `JWT_ISSUER` | `pg-api` | string | |
| `JWT_ACCESS_TTL` | `900` | int |  |
| `JWT_REFRESH_TTL` | `604800` | int | |
| `ARGON2_T_COST` | `3` | int | |
| `ARGON2_M_COST` | `12` | int | |
| `ARGON2_PARALLELISM` | `1` | int | |
| `PASSWORD_RESET_TTL` | `3600` | int | |
| `LOGIN_RATE_LIMIT` | `5` | int | IP+email / dk |
| `SMTP_HOST` | `mailhog` | string | |
| `SMTP_PORT` | `1025` | int | |
| `SMTP_USER` | (boş) | string | |
| `SMTP_PASSWORD` | (boş) | string | |
| `SMTP_FROM` | `no-reply@pgeditor.local` | email | |
| `SMTP_TLS` | `false` | bool | |
| `CORS_ORIGINS` | `http://localhost:28000,http://127.0.0.1:28000` | csv | prod `*` reddedilir |
| `TRUSTED_PROXIES` | `127.0.0.1` | csv | X-Forwarded-For |
| `LOG_FORMAT` | `json` | enum | `json\|text` |
| `LOG_LEVEL` | `info` | enum | |
| `AUDIT_LOG_RETENTION_DAYS` | `30` | int | ≥1 |
| `AUDIT_CLEANUP_ENABLED` | `true` | bool | |
| `AUDIT_CLEANUP_HOUR` | `3` | int | 0–23 UTC |
| `AUDIT_CLEANUP_BATCH_SIZE` | `1000` | int | |
| `SEED_DEFAULTS` | `false` | bool | prod uyarı |
| `RBAC_CACHE_TTL` | `60` | int | |
| `ENCRYPTION_KEY` | — | string | **yeni**: AES-256 için 32 byte base64/hex; bağlantı parolalarını şifreler |
| `TARGET_POOL_SIZE` | `5` | int | **yeni**: hedef DB havuz başına (her bağlantı) keepalive |
| `TARGET_POOL_MAX` | `32` | int | **yeni**: LRU havuz sayısı |
| `QUERY_ROW_LIMIT_DEFAULT` | `1000` | int | **yeni**: `DEFAULT_QUERY_RESULT_ROW_LIMIT` |
| `QUERY_ROW_LIMIT_MAX` | `50000` | int | sorgu sonuç limiti üst sınırı |
| `QUERY_TIMEOUT_MS` | `30000` | int | **yeni**: hedef sorgu timeout |
| `QUERY_MAX_BYTES` | `102400` | int | **yeni**: sorgu gövdesi max (100 KB) |
| `QUERY_HISTORY_RETENTION_DAYS` | `30` | int | **yeni**: sorgu geçmişi temizliği |
| `CSV_MAX_ROWS` | `100000` | int | **yeni**: CSV export limit |
| `COMPLETION_CACHE_TTL` | `300` | int | **yeni**: şema katalog cache (sn) |

**`_FILE` konvansiyonu:** `DB_PASSWORD_FILE`, `JWT_SECRET_FILE`, `SMTP_PASSWORD_FILE`, `ENCRYPTION_KEY_FILE`.

### 6.1 Host Port Eşlemeleri (yalnızca docker-compose)

| Değişken | Varsayılan | Not |
|---|---|---|
| `API_HOST_PORT` | `28080` | → api 8080 |
| `WEB_HOST_PORT` | `28000` | → web 80, `/api/` proxy |
| `DB_HOST_PORT` | `25432` | → postgres 5432, loopback |
| `MAILHOG_UI_HOST_PORT` | `28025` | → mailhog 8025 |

### 6.2 Erişim Adresi (aynı origin)

`apiBase = ${location.origin}/api/v1` (boot.js) — localhost/IP/domain ek ayar olmadan çalışır.

---

## 7. Sayfa Anahtarları ve Varsayılan RBAC Matrisi

`shared/src/types.lua` → `PAGES`:

| page_key | admin | editor | Açıklama | Korunan endpoint örnekleri |
|---|---|---|---|---|
| `dashboard` | ✅ | ✅ | Özet | `GET /stats` |
| `connections.list` | ✅ | ✅ | Bağlantıları listele | `GET /connections` |
| `connections.create` | ✅ | ✅ | Bağlantı ekle/düzenle/test | `POST /connections`, `POST /connections/:id/test` |
| `query.execute` | ✅ | ✅ | SQL çalıştır | `POST /query/execute` |
| `query.history` | ✅ | ✅ | Sorgu geçmişi | `GET /query/history` |
| `schema.browser` | ✅ | ✅ | Şema/tablo listesi | `GET /databases/:id/schemas` |
| `table.browser` | ✅ | ✅ | Tablo satırlarını gör | `GET /objects/:schema/:name/rows` |
| `table.edit` | ✅ | ✅ | Satır ekle/düzenle/sil/çoğalt | `POST /objects/.../rows`, `PATCH /rows` |
| `structure.view` | ✅ | ✅ | Yapı incele | `GET /objects/:schema/:name/structure` |
| `object.actions` | ✅ | ❌ | Rename/truncate/drop | `POST /objects/.../rename` |
| `script.generate` | ✅ | ✅ | DDL script üret | `GET /objects/.../script` |
| `export.csv` | ✅ | ✅ | CSV dışa aktar | `POST /query/csv`, `POST /objects/.../export` |
| `users.list` | ✅ | ❌ | Kullanıcı listesi | `GET /users` |
| `users.create` | ✅ | ❌ | Kullanıcı yarat/sil | `POST /users` |
| `rbac.matrix` | ✅ | ❌ | Yetki matrisi | `/rbac/*` |
| `audit.logs` | ✅ | ❌ | Denetim | `/audit/*` |
| `settings` | ✅ | ❌ | Ayarlar | frontend |

**Kilit:** `admin` rolünün `rbac.matrix` izni değiştirilemez → `CONFLICT`.

---

## 8. Audit Olayları (Kanonik Liste)

| action | entity_type | Tetikleyen | old_value | new_value |
|---|---|---|---|---|
| `auth.login.success` | `user` | auth_service.login | — | `{ email }` |
| `auth.login.failure` | `user` | auth_service.login | — | `{ email, reason }` |
| `auth.logout` | `user` | logout | — | — |
| `auth.token.refresh` | `user` | refresh | — | — |
| `auth.password.reset.request` | `user` | forgot | — | `{ email }` |
| `auth.password.reset.success` | `user` | reset | — | — |
| `connection.create` | `connection` | connections_service.create | — | `{ host, port, database, username }` |
| `connection.update` | `connection` | update | önceki (maskeli) | yeni (maskeli) |
| `connection.delete` | `connection` | delete | silinen (maskeli) | — |
| `connection.test` | `connection` | test | — | `{ success, latency_ms }` |
| `query.execute` | `query` | query_service.execute | — | `{ connection_id, row_count, duration_ms, truncated }` |
| `query.export.csv` | `query` | export | — | `{ connection_id, rows, format }` |
| `table.row.create` | `table_row` | table_browser_service.insert | — | `{ schema, table, row }` |
| `table.row.update` | `table_row` | update | önceki | yeni |
| `table.row.delete` | `table_row` | delete | silinen | — |
| `table.row.duplicate` | `table_row` | duplicate | kaynak | yeni |
| `object.rename` | `table` | object_actions | `{ old_name }` | `{ new_name }` |
| `object.truncate` | `table` | truncate | `{ schema, table }` | — |
| `object.drop` | `table` | drop | `{ schema, table }` | — |
| `script.generate` | `table` | script | — | `{ kind }` |
| `user.create` | `user` | user_service | — | maskeli |
| `user.update` | `user` | update | önceki maskeli | yeni maskeli |
| `user.delete` | `user` | delete | maskeli | — |
| `rbac.matrix.update` | `rbac` | rbac_service | eski hücreler | yeni hücreler |
| `access.denied` | `page` | authorization | — | `{ page_key, method, path }` |

Maskelenen alanlar: `password`, `password_hash`, `secret`, `token`, `pg_password_encrypted` → `"***"`.

---

## 9. lua_shared_dict Haritası

| Dict | Boyut | Anahtar | TTL | Kullanan |
|---|---|---|---|---|
| `rbac_cache` | 1m | `rbac:<role>` → JSON | `RBAC_CACHE_TTL` | rbac_service |
| `jwt_denylist` | 10m | `jti:<jti>` → `1` | kalan ömür | auth |
| `rate_limit` | 10m | `login:<ip>:<email>` | 60 sn | auth_service |
| `query_rate_limit` | 10m | `query:<user_id>:<connection_id>` | 60 sn | query_service |
| `completion_cache` | 5m | `completion:<connection_id>:<database>` → JSON | `COMPLETION_CACHE_TTL` | query_service |
| `job_locks` | 1m | `lock:*` | 3600 sn | jobs |
| `metrics` | 1m | `req_total`, `req:2xx`, `latency_sum_ms` | — | logger, /metrics |

---

## 10. ngx.ctx Haritası

| Anahtar | Yazan | Okuyan |
|---|---|---|
| `req_id` | logger | error_handler, audit |
| `started_at` | logger | log fazı |
| `audit` = `{ ip, user_agent }` | audit_context | audit_service |
| `identity` = `{ user_id, email, role, jti, exp }` | auth | authorization, handler |
| `tx_conn` | query.with_transaction | db/query |

---

## 11. Teknik Düzeltmeler (Prompt'taki Sorunlar ve Kararlar)

| # | Kaynak | Sorun | Karar |
|---|---|---|---|
| 1 | Wasmoon | Lua→WASM derleme sanılır | Wasmoon VM hazır WASM; Lua kaynakları JSON bundle |
| 2 | Shared | LuaJIT (5.1) vs 5.4 | Ortak alt küme; `unpack`, `//` yasak |
| 3 | lua-resty-http SMTP | SMTP konuşmaz | `lua-resty-mail` |
| 4 | lua-resty-argon2 | paket yok | `argon2` rock (thibaultcha) |
| 5 | Connection pool min/max | Worker başına keepalive, min yok | `keepalive(timeout, pool_size)` + init_worker warm 5 |
| 6 | Prepared statement | Lapis escape ≠ bind | `pgmoon` extended protocol `$1` |
| 7 | Middleware sırası | `authorization` audit'ten önce IP ister | `cors → logger → audit_context → auth → authorization` |
| 8 | PATCH param `page-key` | Lapis `-` sorun | `page_key` |
| 9 | JWT payload | jti/typ yok | `{ sub, user_id, email, role, iat, exp, jti, typ, iss }` |
| 10 | swagger-cli | deprecated | `@redocly/cli` |
| 11 | WASM -O3 | biz derlemiyoruz | minify + gzip/brotli + preload |
| 12 | Tailwind CDN | prod önerilmez | dev CDN, prod CLI derlemesi |
| 13 | ngx.timer.at her saat | her worker N kez | `worker.id()==0` + advisory lock |
| 14 | /stats vs /:id | route çakışması | literal önce, `:id` UUID regex |
| 15 | gen_random_uuid | pgcrypto gerek | 001'de `CREATE EXTENSION pgcrypto` |
| 16 | ngx.thread.spawn | gerek yok | yalnızca stats sayfasında paralel aggregate (F7) |
| 17 | Bağlantı parolası güvenliği | Keyring yok (web) | `ENCRYPTION_KEY` → AES-256-GCM, kolon `password_encrypted` |
| 18 | Hedef DB havuzu | Tek havuz meta DB için yeterli sanılır | `pool_manager` LRU, per-connection havuz |
| 19 | SQL enjeksiyonu (custom_where, ORDER BY, script) | Dinamik SQL | Whitelist + parametreli; `custom_where` → `sqlancer` parse + allow-list |
| 20 | Çoklu ifade yürütme | Tek statement varsayılır | özel `sql_statements` parser; çoklu → her biri ayrı `fetch_many` |
| 21 | Kod vurgusu | Lua içinde syntax highlight zor | CodeMirror 6 JS köprüsü; Lua yalnızca katalog sağlar |
| 22 | CSV export transaction | `COPY` + `BEGIN READ ONLY` gerekir | `execute_read_only` → `BEGIN READ ONLY` + `ROLLBACK` |
| 23 | Büyük sonuç bellek | 50k satır RAM'i doldurur | `row_limit` default 1000, max `QUERY_ROW_LIMIT_MAX`, streaming CSV |

---

## 12. Faz Bağımlılık Grafiği

```
F0 ─► F1 ─► F2 ─► F3 ─► F4 ─► F5 ─► F6 ─► F7 ─► F8 ─► F9 ─► F10 ─► F11 ─► F12 ─► F13 ─► F14 ─► F15 ──┐
                                 │                                                               ├─► F23
                                 └─► F16 ─► F17 ─► F18 ─► F19 ─► F20 ─► F21 ─► F22 ──────────────┘
```

- F16 (frontend iskelet) F5'ten sonra paralel başlayabilir.
- F8 (sorgu) F6 (bağlantılar) ve F7 (şema) ister.
- F9 (tablo tarayıcı) F7 ve F8 ister.
- F10 (obje/script/csv) F7, F8, F9 ister.

## 13. Faz Özet Tablosu

| Faz | Ad | Doküman | Efor | Özet |
|---|---|---|---|---|
| 0 | Monorepo Altyapı | faz-00 | S | docker-compose, Makefile, lint, git hooks |
| 1 | Shared Kütüphane | faz-01 | M | types, validation, protocol |
| 2 | Veritabanı & Migration | faz-02 | M | users, connections, query_history, audit, rbac |
| 3 | Backend Core | faz-03 | L | config, nginx, Lapis, query, router, error |
| 4 | Security | faz-04 | M | jwt, argon2, random, AES-GCM crypto |
| 5 | Auth Endpointleri | faz-05 | L | login, refresh, logout, me, forgot/reset |
| 6 | Bağlantı Yönetimi | faz-06 | L | CRUD + test + pool_manager + şifreleme |
| 7 | Şema & Yapı | faz-07 | L | schemas, objects, structure (6 sorgu) |
| 8 | Sorgu Motoru & Geçmiş | faz-08 | L | execute, history, completion, limit |
| 9 | Tablo Tarayıcı | faz-09 | L | rows pagination, filter, insert/duplicate/delete, edit |
| 10 | Obje & Script & CSV | faz-10 | M | rename/truncate/drop, DDL script, CSV export |
| 11 | Users & RBAC | faz-11 | L | user CRUD, matrix, page list |
| 12 | Audit & Middleware | faz-12 | M | audit repo, context, export |
| 13 | Swagger/OpenAPI 3.1 | faz-13 | M | spec, redocly |
| 14 | Scheduled Jobs | faz-14 | S | audit/history cleanup, vacuum |
| 15 | Backend Test & Bench | faz-15 | L | busted + wrk + integration |
| 16 | Frontend İskelet | faz-16 | M | Wasmoon, glue, bundling, index.html |
| 17 | Frontend Core | faz-17 | L | store, dom, fetch, router, editor bridge |
| 18 | Frontend Views I | faz-18 | L | connections, query editor, schema sidebar |
| 19 | Frontend Views II | faz-19 | L | table browser, structure inspector |
| 20 | Frontend Views III (Admin) | faz-20 | M | users, rbac, audit, settings |
| 21 | Frontend UX | faz-21 | M | tema, klavye, a11y, empty/skeleton, toast |
| 22 | Frontend Test & Opt | faz-22 | M | busted (lua5.4), playwright, wasm opt |
| 23 | Deployment | faz-23 | L | docker multi-stage, prod compose, TLS, backup |

Efor: S 0.5–1d, M 1–2d, L 2–4d (tek geliştirici).

---

## 14. Kod Konvansiyonları

- Yorumlar **Türkçe**, tanımlayıcılar İngilizce `snake_case`.
- Her modül `local _M = {} … return _M`; global yok (`luacheck` `std="ngx_lua"`).
- Sık fonksiyonlar local'e alınır (`local ngx_now = ngx.now`).
- Sıcak path'lerde `table.new(narr,nrec)` + `table.clear`.
- Döngüde `..` değil `table.concat`.
- Beklenen hata `return nil, err`; beklenmeyen `error(...)` (altyapı).
- 2–4 satır Türkçe modül başlığı.
- Satır 120, girinti 2 boşluk, `.editorconfig`.
- `collectgarbage("collect")` yalnızca CSV export ve log_cleanup sonunda.

## 15. API Yanıt Zarfı

| Durum | Şekil |
|---|---|
| Tekil | `{ "data": { ... } }` |
| Liste | `{ "data": [ ... ], "meta": { "page", "per_page", "total", "total_pages" } }` |
| Sayfalı + filtreli | `{ "data": [...], "meta": { page, per_page, total, has_next } }` |
| Sorgu sonucu | `{ "data": { columns: [...], rows: [[...]], row_count, truncated, duration_ms } }` |
| Boş başarı | `204 No Content` |
| Hata | `{ "error": { code, message, details, req_id } }` |

Sayfalama: `page` ≥1 (default 1), `per_page` 1–100 (default 20, tarayıcıda 100). Sıralama: `sort=field` / `sort=-field` whitelist.

## 16. Sözlük

| Terim | Anlam |
|---|---|
| Connection | Kullanıcının kaydettiği harici PostgreSQL bağlantısı (host/port/db/user + şifreli parola) |
| Meta DB | Uygulamanın kendi Postgres'i (users, connections, audit...) |
| Target DB / Hedef DB | Kullanıcının bağlandığı harici Postgres |
| Pool Manager | Hedef DB için LRU pgmoon havuz yöneticisi |
| Completion Catalog | Şema/tablo/kolon adları, tipleri, constraint'ler (otocomplete için) |
| Table Structure | Kolonlar, indexler, constraintler, FK, trigger'lar (6 sorgu) |
| Table Script | Kenar çubuğundan üretilen DDL (SELECT/INSERT/CREATE/DROP) |
| Identity | `ngx.ctx.identity` (JWT'den) |
| Page key | RBAC yetki anahtarı (`query.execute`) |
| Denylist | İptal edilmiş JWT `jti` kümesi |
| Reducer | `(state, action) → new_state` saf fonksiyon |
| Optimistic UI | Sunucuyu beklemeden state güncelleme, hata olursa rollback |
| Keepalive pool | OpenResty cosocket yeniden kullanım havuzu |

