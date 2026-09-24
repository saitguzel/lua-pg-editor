# ═══ FAZ 03 — BACKEND CORE ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — yaşam döngüsü §3, katman kuralları §4, env §6, shared dict §9.

## Amaç

Tüm endpoint'lerin üzerine oturacağı çekirdek: doğrulanmış config, gerçek nginx.conf, Lapis iskeleti, middleware zinciri, parametreli sorgu + transaction, merkezi hata yönetimi, CORS, loglama, `GET /api/v1/health`.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/config.lua` | env SPEC, coercion, cross_validate, _FILE |
| `api/conf/nginx.conf` | worker, shared dicts, include |
| `api/conf/lua.conf` | lua_package_path, init_by_lua, server/location |
| `api/conf/mime.types` | nginx mime (kopya) |
| `api/src/app.lua` | lapis Application, register |
| `api/src/router.lua` | ROUTES tablosu + chain() |
| `api/src/db/query.lua` | query, query_one, exec, with_transaction, ping, like_pattern, builder |
| `api/src/db/pool.lua` | (F2 ile, burada genişletilir) |
| `api/src/db/pool_manager.lua` | **yeni**: hedef DB LRU havuz yöneticisi |
| `api/src/middleware/error_handler.lua` | errors.new/respond/guard |
| `api/src/middleware/cors.lua` | preflight + header_filter |
| `api/src/middleware/logger.lua` | req_id, access log, metrics |
| `api/src/security/random.lua` | minimal uuid4/hex (F4'te tamamlanır) |
| `api/conf/env.conf` | üretilmiş `env NAME;` (commit) |

## config.lua (SPEC)

00 §6'daki tüm değişkenler; `ENCRYPTION_KEY` required, min_len 32; yeni target/query değişkenleri ekli.

```lua
local SPEC = {
  APP_ENV = { type="enum", values={"development","test","production"}, default="development" },
  DB_PASSWORD = { type="string", required=true, secret=true },
  JWT_SECRET = { type="string", required=true, secret=true, min_len=32 },
  ENCRYPTION_KEY = { type="string", required=true, secret=true, min_len=32 },
  TARGET_POOL_SIZE = { type="int", default=5, min=1, max=20 },
  QUERY_ROW_LIMIT_DEFAULT = { type="int", default=1000, min=1, max=50000 },
  -- ... tüm §6
}
function _M.load(getenv) -- read_env + coerce + cross_validate → immutable proxy
function _M.get() return _M.current end
function _M.redacted(c) -- secret "***"
```

Cross_validate: prod `JWT_SECRET` örnek değil, `DB_PASSWORD >=16`, `CORS_ORIGINS` `*` içeremez, `ENCRYPTION_KEY` base64 decode edince 32 byte olmalı.

`_FILE` desteği: `DB_PASSWORD_FILE` varsa dosyadan oku, düz değişkeni yok say (warn).

`env.conf` üretimi: `make conf.env` → `for _,k in ipairs(spec_keys()) do print("env "..k..";")`

## nginx.conf

```nginx
worker_processes auto;
error_log stderr info;
pid logs/nginx.pid;
include env.conf;
events { worker_connections 4096; }
http {
  include mime.types;
  default_type application/octet-stream;
  server_tokens off; access_log off;
  client_max_body_size 1m; client_body_buffer_size 1m; keepalive_timeout 65;
  resolver 127.0.0.11 ipv6=off valid=30s;
  lua_shared_dict rbac_cache 1m;
  lua_shared_dict jwt_denylist 10m;
  lua_shared_dict rate_limit 10m;
  lua_shared_dict query_rate_limit 10m;
  lua_shared_dict completion_cache 5m;
  lua_shared_dict job_locks 1m;
  lua_shared_dict metrics 1m;
  lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
  include lua.conf;
}
```

## lua.conf

```nginx
lua_package_path "/app/src/?.lua;/app/src/?/init.lua;/app/lib/?.lua;;";
lua_code_cache on;
lua_socket_log_errors off;
init_by_lua_block {
  local config = require("config"); config.current = config.load();
  require("db.pool").configure(config.current.db);
  require("cjson.safe").encode_empty_table_as_object(false);
  require("app")
}
init_worker_by_lua_block {
  require("db.pool").warm(5);
}
server {
  listen 8080;
  location /api/ {
    default_type application/json;
    content_by_lua_block { require("lapis").serve("app") }
    log_by_lua_block { require("middleware.logger").log_phase() }
  }
  header_filter_by_lua_block { require("middleware.cors").header_filter() }
  location / { return 404; }
}
```

## app.lua / router.lua

```lua
-- app.lua
local lapis = require("lapis")
local router = require("router")
local errors = require("middleware.error_handler")
local app = lapis.Application(); app.layout=false
router.register(app)
app.handle_404 = function(self) return errors.respond(errors.new("NOT_FOUND","Kaynak bulunamadı")) end
app.handle_error = function(self,err,trace) return errors.on_unhandled(err,trace) end
return app

-- router.lua
local _M = {}
_M.API_PREFIX = "/api/v1"
function _M.chain(mws, handler) return function(self) return errors.guard(function() for i=1,#mws do local r=mws[i](self) if r then return r end end return handler(self) end) end end
_M.ROUTES = {
  { "GET", "/health", health, auth=false },
  -- F5+ eklenecek: auth, connections, query, schema, table, objects, users, rbac, audit
}
function _M.register(app) -- her route için cors,logger,audit_context + auth? + authorization?
-- OPTIONS preflight
```

Health handler (router içinde local):
```lua
local function health(self)
  local ok = query.ping()
  return { status = ok and 200 or 503, json = { status = ok and "ok" or "degraded", db = ok and "up" or "down", version=VERSION, uptime_s=math.floor(ngx.now()-STARTED) } }
end
```

Route sırası: literal `/query/history` önce, `/query/:id` sonra; UUID parametresi handler'da `errors.require_uuid_param`.

## db/query.lua (meta)

```lua
local pool = require("db.pool")
function _M.query(sql,...) -- tx_conn varsa onu kullan
function _M.query_one(sql,...) -- tek satır
function _M.exec(sql,...) -- affected_rows
function _M.with_transaction(fn) -- BEGIN/COMMIT/ROLLBACK, iç içe → dış
function _M.ping() -- SELECT 1
function _M.like_pattern(s) -- % ve _ kaçış
function _M.builder() -- $?, where, build
```

pgmoon hata → AppError `map_pg_error`: 23505→CONFLICT/EMAIL_TAKEN, 23503→NOT_FOUND, 22P02→BAD_REQUEST, connect→DB_UNAVAILABLE.

`db/pool_manager.lua` (hedef DB):

```lua
local lru = require("utils.lru") -- 32 giriş, 5 dk idle
local pools = lru.new(32, 300)
function _M.acquire(conn) -- key = host:port/database:username → pgmoon pool
-- şifre decrypt: crypto.decrypt(conn.password_encrypted)
-- connect_options: ssl Prefer, timeouts QUERY_TIMEOUT_MS
-- ping + keepalive(TARGET_POOL_SIZE)
function _M.release(pool, broken)
function _M.invalidate(connection_id) -- şifre değişince
function _M.stats()
```

Her havuz ayrı keepalive limiti; `TARGET_POOL_MAX` LRU limiti.

## middleware/error_handler.lua

```lua
function _M.new(code, message, details) return { code=code, message=message or protocol.message(code), details=details, __app_error=true } end
function _M.respond(err) local status=protocol.http_status(err.code); return { status=status, json=protocol.error_body(err, ngx.ctx.req_id), headers=err.headers } end
function _M.guard(fn) -- xpcall + headers_sent kontrol
function _M.read_json_body() -- 413, BAD_REQUEST
function _M.validation(errors) return _M.new("VALIDATION_FAILED", nil, errors) end
function _M.require_uuid_param(self, name, not_found_code)
```

## middleware/cors.lua / logger.lua

CORS: `handle()` yalnızca OPTIONS preflight; `header_filter()` her yanıta `Allow-Origin` basar (404/413 de).

Logger: `handle()` req_id (X-Request-Id header UUID ise kullan, yoksa random.uuid4), `X-Request-Id` response; `log_phase()` json/text satır, query_string loglanmaz, metrics incr.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| İki havuz türü | Meta ve hedef izolasyonu; hedef havuz LRU |
| `env.conf` üretilir | nginx env geçirmez |
| Route tablosu veri | Lapis + Swagger + RBAC tek kaynak |
| `with_transaction` iç içe = dış | SAVEPOINT YAGNI |
| UUID 404 | bilgi sızdırmaz |

## DoD

- [ ] Eksik env → api başlamaz, tüm hatalar tek mesajda.
- [ ] `GET /api/v1/health` → `200`, `X-Request-Id` UUID.
- [ ] Postgres down → `/health` 503, API çökmez.
- [ ] 404 → JSON `NOT_FOUND` + `req_id`.
- [ ] `OPTIONS` izinli origin → 204 + CORS, izinsiz → 403.
- [ ] Hata 500'de stack istemciye gitmez, logda var.
