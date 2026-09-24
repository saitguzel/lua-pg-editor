# ═══ FAZ 01 — SHARED KÜTÜPHANE ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — error kodları (§5), sayfa anahtarları (§7), teknik düzeltme #2.

## Amaç

Backend (LuaJIT) ve frontend (Wasmoon 5.4) tarafından **aynı kaynak**tan kullanılan `pg-shared` kütüphanesini yazmak: enum'lar/RBAC (`types`), şema DSL (`validation`), error map ve zarf (`protocol`). Busted spec'leri **iki yorumlayıcıda** yeşil.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `shared/src/types.lua` | `ROLES`, `PAGES`, `PAGE_META`, `AUDIT_ACTIONS`, `CONNECTION_STATUS`, `SCRIPT_KINDS`, `FILTER_OPS` |
| `shared/src/validation.lua` | DSL + `validate(schema, input, opts)` |
| `shared/src/protocol.lua` | `ERR`, `HTTP_STATUS`, `http_status()`, `error_body()`, `API_PREFIX` |
| `rockspecs/pg-shared-0.1.0-1.rockspec` | `pg_shared.*` modülleri |
| `shared/spec/shared_spec.lua` | busted spec |
| `Makefile` | `test.shared` eklendi |

Modül adları: `require("pg_shared.types")` her iki tarafta aynı. Backend mount `/app/lib/pg_shared`, frontend bundle `pg_shared.*`.

## Lua 5.1 ∩ 5.4 Uyumluluk

Yasak: `//`, `goto`, `<const>`, bit op `&|`, `math.type`, `utf8.*`, `table.unpack` tek; → `math.floor(a/b)`, `unpack = table.unpack or unpack`, `utf8_len` helper.

## shared/src/types.lua (özet)

```lua
local _M = {}
_M.ROLES = { "admin", "editor" }
_M.PAGES = {
  "dashboard",
  "connections.list", "connections.create",
  "query.execute", "query.history",
  "schema.browser", "table.browser", "table.edit",
  "structure.view", "object.actions", "script.generate", "export.csv",
  "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
}
_M.PAGE_META = {
  dashboard = { label = "Gösterge Paneli", group = "genel" },
  ["connections.list"] = { label = "Bağlantılar", group = "connections" },
  ["connections.create"] = { label = "Bağlantı Yönetimi", group = "connections" },
  ["query.execute"] = { label = "Sorgu Çalıştır", group = "query" },
  ["query.history"] = { label = "Sorgu Geçmişi", group = "query" },
  ["schema.browser"] = { label = "Şema Tarayıcı", group = "browse" },
  ["table.browser"] = { label = "Tablo Tarayıcı", group = "browse" },
  ["table.edit"] = { label = "Satır Düzenleme", group = "browse" },
  ["structure.view"] = { label = "Yapı İnceleme", group = "browse" },
  ["object.actions"] = { label = "Obje Eylemleri", group = "admin" },
  ["script.generate"] = { label = "Script Üretimi", group = "browse" },
  ["export.csv"] = { label = "CSV Dışa Aktar", group = "query" },
  -- admin grubu ...
}
_M.DEFAULT_PERMISSIONS = {
  admin = { ["*"] = true },
  editor = {
    dashboard = true, ["connections.list"] = true, ["connections.create"] = true,
    ["query.execute"] = true, ["query.history"] = true,
    ["schema.browser"] = true, ["table.browser"] = true, ["table.edit"] = true,
    ["structure.view"] = true, ["script.generate"] = true, ["export.csv"] = true,
  },
}
_M.LOCKED_PERMISSIONS = { { role = "admin", page_key = "rbac.matrix" } }
_M.AUDIT_ACTIONS = {
  "auth.login.success", "auth.login.failure", "auth.logout", "auth.token.refresh",
  "auth.password.reset.request", "auth.password.reset.success",
  "connection.create", "connection.update", "connection.delete", "connection.test",
  "query.execute", "query.export.csv",
  "table.row.create", "table.row.update", "table.row.delete", "table.row.duplicate",
  "object.rename", "object.truncate", "object.drop", "script.generate",
  "user.create", "user.update", "user.delete",
  "rbac.matrix.update", "access.denied",
}
-- Yeni: Filter operator enum
_M.FILTER_OPS = { "=", "!=", ">", ">=", "<", "<=", "LIKE", "ILIKE", "IS NULL", "IS NOT NULL" }
_M.OBJECT_KINDS = { "table", "view" }
_M.SCRIPT_KINDS = { "select", "insert", "create", "drop", "truncate" }
_M.COLUMN_TYPE_GROUPS = { "boolean", "binary", "datetime", "json", "numeric", "text", "other" }
_M.DEFAULT_PAGE_SIZE = 100
_M.PAGE_SIZE_OPTIONS = { 50, 100, 250, 500 }
return _M
```

Helpers: `to_set(list)`, `ROLE_SET`, `PAGE_SET`, `is_member`, `default_permission(role,page)`, `default_matrix()`, `is_locked`.

## shared/src/protocol.lua

```lua
_M.API_PREFIX = "/api/v1"
_M.ERR = {
  VALIDATION_FAILED="VALIDATION_FAILED", BAD_REQUEST="BAD_REQUEST",
  UNAUTHORIZED="UNAUTHORIZED", TOKEN_EXPIRED="TOKEN_EXPIRED", TOKEN_REVOKED="TOKEN_REVOKED",
  INVALID_CREDENTIALS="INVALID_CREDENTIALS", ACCOUNT_DISABLED="ACCOUNT_DISABLED",
  FORBIDDEN="FORBIDDEN", NOT_FOUND="NOT_FOUND",
  CONNECTION_NOT_FOUND="CONNECTION_NOT_FOUND", DATABASE_NOT_FOUND="DATABASE_NOT_FOUND",
  OBJECT_NOT_FOUND="OBJECT_NOT_FOUND", USER_NOT_FOUND="USER_NOT_FOUND",
  QUERY_FAILED="QUERY_FAILED", READONLY_VIOLATION="READONLY_VIOLATION", ROW_NOT_FOUND="ROW_NOT_FOUND",
  EMAIL_TAKEN="EMAIL_TAKEN", CONFLICT="CONFLICT", LAST_ADMIN="LAST_ADMIN",
  SELF_ACTION_FORBIDDEN="SELF_ACTION_FORBIDDEN", RESET_TOKEN_INVALID="RESET_TOKEN_INVALID",
  CONNECTION_FAILED="CONNECTION_FAILED", RATE_LIMITED="RATE_LIMITED",
  PAYLOAD_TOO_LARGE="PAYLOAD_TOO_LARGE", INTERNAL_ERROR="INTERNAL_ERROR", MAIL_FAILED="MAIL_FAILED",
  DB_UNAVAILABLE="DB_UNAVAILABLE",
}
_M.HTTP_STATUS = {
  VALIDATION_FAILED=422, BAD_REQUEST=400, UNAUTHORIZED=401, TOKEN_EXPIRED=401, TOKEN_REVOKED=401,
  INVALID_CREDENTIALS=401, ACCOUNT_DISABLED=403, FORBIDDEN=403,
  NOT_FOUND=404, CONNECTION_NOT_FOUND=404, DATABASE_NOT_FOUND=404, OBJECT_NOT_FOUND=404, USER_NOT_FOUND=404, ROW_NOT_FOUND=404,
  QUERY_FAILED=422, READONLY_VIOLATION=422,
  EMAIL_TAKEN=409, CONFLICT=409, LAST_ADMIN=409, SELF_ACTION_FORBIDDEN=409,
  RESET_TOKEN_INVALID=400, CONNECTION_FAILED=502, RATE_LIMITED=429, PAYLOAD_TOO_LARGE=413,
  INTERNAL_ERROR=500, MAIL_FAILED=502, DB_UNAVAILABLE=503,
}
_M.CODE_LIST = { "VALIDATION_FAILED", ... } -- 00 §5 sırası
function _M.http_status(code) return _M.HTTP_STATUS[code] or 500 end
function _M.error_body(err, req_id) return { error = { code=err.code, message=err.message, details=err.details, req_id=req_id } } end
```

`DEFAULT_MESSAGES` Türkçe: `QUERY_FAILED="Sorgu çalıştırılamadı"`, `CONNECTION_FAILED="Bağlantı kurulamadı"` …

## shared/src/validation.lua (DSL)

Kurucu tablo: `string(opts: min,max,pattern,trim,lower)`, `integer(min,max)`, `boolean()`, `enum(list)`, `email()`, `uuid()`, `datetime()`, `password()`, `array_of(rule,opts)`, `optional(rule)`, `nullable(rule)`, `schema(fields,opts)`.

pg-editor'a özgü yeni kurucular:
- `host()` — boş değil, `^[%w%.%-]+$` veya `/var/run/...` unix socket
- `port()` — integer 1–65535
- `sql_identifier()` — `^[%a_][%w_]*$` + `max 63` + reserved word kontrolü (basit liste)
- `safe_sql()` — `;` + `--` + `/*` içermez (custom_where için ham SQL değil, ifade)
- `connection_name()` — trim, 1–100

API: `validate(schema, input, opts?) → clean | nil, errors`, `validate_partial`, `is_uuid`, `utf8_len`.

Hazır şemalar (`validation.schemas`):
- `login`, `forgot_password`, `reset_password`, `refresh`
- `connection_create` (name, host, port, database, username, password, save_password, ssh_*)
- `query_execute` (connection_id uuid, sql string 1..102400, row_limit optional, database optional)
- `rows_filter` (filters array, custom_where optional safe_sql)
- `row_insert` (dinamik: kolonlara göre)
- `object_rename` (new_name sql_identifier), `script_generate` (kind enum)

Strict mod: bilinmeyen alan → `bilinmeyen alan`.

## rockspec

```lua
package = "pg-shared"; version = "0.1.0-1"
source = { url = "." }
description = { summary = "pg-shared: pg-editor ortak kütüphane" }
build = { type = "builtin", modules = {
  ["pg_shared.types"] = "shared/src/types.lua",
  ["pg_shared.validation"] = "shared/src/validation.lua",
  ["pg_shared.protocol"] = "shared/src/protocol.lua",
} }
```

Prod imajında `luarocks make`.

## DoD

- [ ] `busted shared/spec` LuaJIT ve lua5.4'te yeşil (iki run).
- [ ] `luacheck shared/src` temiz (`lua51+lua54`).
- [ ] `ERR` ↔ `HTTP_STATUS` ↔ `DEFAULT_MESSAGES` eşleşmesi spec ile.
- [ ] `is_locked("admin","rbac.matrix")==true`, diğer false.
- [ ] `validate(connection_create, {host=""})` → `host: zorunlu alan` değil `host: metin…`
