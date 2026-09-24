# ═══ FAZ 13 — SWAGGER / OPENAPI 3.1 ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — API_PREFIX, error kodları, env APP_BASE_URL.

## Amaç

Tüm endpoint'lerin OpenAPI 3.1 spec'ini üretmek, Swagger UI servis etmek, spec'i `redocly lint` ile doğrulamak. `route_list()` tek kaynak.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/openapi/spec.lua` | Lua tablosundan OpenAPI 3.1 üret |
| `api/public/swagger.json` | **üretilen** spec (commit, CI kontrol) |
| `api/public/swagger/index.html` | Swagger UI (cdn veya vendor) |
| `api/src/handlers/swagger.lua` | `GET /swagger.json`, `GET /swagger` |
| `redocly.yaml` | lint config |
| `Makefile` | `openapi.dump`, `spec.lint` |

## spec.lua Tasarım

`router.route_list()` → her route için `method, path, auth, page`.

```lua
local types = require("pg_shared.types")
local protocol = require("pg_shared.protocol")
local config = require("config")
local _M = {}
function _M.build()
  return {
    openapi="3.1.0",
    info={ title="pg-editor API", version="0.1.0", description="PostgreSQL Web Editor" },
    servers={{ url=config.get().app.base_url .. "/api/v1" }},
    paths=build_paths(),
    components=build_components(),
    security={ { bearerAuth={} } },
  }
end
local function build_paths()
  -- her route için operationId, summary, tags, x-page-key, responses
  -- path param: :id → {id}, :schema → {schema}
  -- requestBody $ref: #/components/schemas/...
  -- responses: 200 + error refs (protocol.http_status)
end
local function build_components()
  -- schemas: Error, PaginationMeta, Uuid, Timestamp, Role, PageKey,
  --          User, Connection, DatabaseObject, TableStructure, QueryResult, QueryHistory,
  --          TablePage, ScriptKind, AuditLog
  -- parameters: page, per_page, sort, search
  -- securitySchemes: bearerAuth (JWT)
  -- responses: her ERR için ref
end
```

Örnek endpoint spec:

```lua
["/connections/{id}/schemas"] = {
  get = op({
    summary="Şemaları listele",
    tags={"schema"}, ["x-page-key"]="schema.browser",
    parameters={ qp("id"), qp_database },
    responses={ ["200"]=resp("Şema listesi", ref("SchemaList")) },
    errors={ "UNAUTHORIZED","FORBIDDEN","CONNECTION_NOT_FOUND","CONNECTION_FAILED" },
  })
}
```

Helper `op(o)`: `errors` → her code için `responses[status]` ekler; `x-page-key` → description'a "Yetki: ..." ekler; her op `500` ve `503` otomatik.

## Swagger Handler

```lua
-- swagger.lua
function _M.json(self) -- GET /api/v1/swagger.json
  ngx.header["Content-Type"]="application/json"
  return { status=200, layout=false, body=cjson.encode(spec.build()) }
end
function _M.ui(self) -- GET /api/v1/swagger
  -- redirect veya static index.html
end
```

`api/public/swagger/index.html` — Swagger UI 5.x CDN (`unpkg.com/swagger-ui-dist`) veya vendor kopyası; `url: "./swagger.json"` ile.

## Makefile

```makefile
openapi.dump:
	docker compose exec -T api resty -I /app/src -I /app/lib -e 'local c=require("config"); c.current=c.load(); print(require("cjson").encode(require("openapi.spec").build()))' > api/public/swagger.json
openapi.lint spec.lint: openapi.dump
	npx --yes @redocly/cli@1 lint api/public/swagger.json --config redocly.yaml
```

`redocly.yaml`:

```yaml
extends: [recommended]
rules:
  operation-summary: error
  operation-operationId: error
  no-unused-components: warn
```

## DoD

- [ ] `GET /api/v1/swagger.json` valid JSON 3.1, `jq .` parse.
- [ ] `npx @redocly/cli lint` 0 hata.
- [ ] Swagger UI `http://localhost:28000/api/v1/swagger` açılır, "Authorize" ile Bearer test edilebilir.
- [ ] Her route `route_list()` içinde ve spec'te var (coverage test `spec/openapi_spec.lua`).
- [ ] `APP_BASE_URL` değişince `servers[0].url` değişir.
