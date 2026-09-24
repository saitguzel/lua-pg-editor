# ═══ FAZ 15 — BACKEND TEST & LOAD TEST ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — test altyapısı.

## Amaç

Yüksek güvenilirlik: birim + entegrasyon + e2e öncesi bench. `busted` (unit/integration), `wrk` bench, `redocly` lint.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/spec/helpers/init.lua` | bootstrap (config mock, pgmoon stub) |
| `api/spec/validation_spec.lua` | shared validation spec |
| `api/spec/connection_spec.lua` | bağlantı validasyon |
| `api/spec/query_parser_spec.lua` | sql_statements parser |
| `api/spec/integration/*.lua` | gerçek API'ye karşı (running) |
| `api/bench/run.sh` | wrk senaryoları |
| `api/bench/query_execute.lua` | bench script |

## Test Matrisi

| Suite | Komut | Ne çalışır |
|---|---|---|
| lint | `make lint` | luacheck tüm src |
| shared | `make test.shared` | busted shared/spec (LuaJIT + lua5.4) |
| api unit | `make test.api` | `busted api/spec --exclude-tags=integration` (stub DB) |
| integration | `make test.integration` | `busted api/spec/integration` (canlı API + meta DB) |
| e2e | `make web.e2e` | Playwright (F22) |
| bench | `make bench` | wrk (threshold kontrollü) |

## Helpers (spec/helpers/init.lua)

```lua
-- config mock
local config = require("config")
config.current = {
  app={ env="test" }, jwt={ secret="test-secret-32-bytes-long-test-secret-", issuer="pg-api", access_ttl=900, refresh_ttl=604800 },
  db={ pool_size=20 }, audit={ retention_days=30 }, encryption_key="test-key-32-bytes-long-test-key-"
}
-- pgmoon stub: query/query.lua mock return
-- ngx stub: ngx.shared dict mock, ngx.ctx = {}
```

## Birim Test Örnekleri

- `validation_spec.lua`: her kurucu için ok/err.
- `crypto_spec.lua`: encrypt/decrypt, wrong key fail.
- `query_parser_spec.lua`: `sql_statements("SELECT 1; SELECT 2 -- comment")` → 2 statement, `contains_transaction_control("BEGIN")` true.
- `connection_spec.lua`: `connection_create` valid/invalid host, port, duplicate name.

## Entegrasyon Testleri

`api/spec/integration/auth_flow_spec.lua`:

```lua
describe("auth flow", function()
  it("login success", function()
    local res = http_post("/api/v1/auth/login", {email="admin@pgeditor.local", password="Admin123!"})
    assert.are.equal(200, res.status)
  end)
  it("connection CRUD + test", function()
    local token = login()
    local conn = http_post("/api/v1/connections", {name="test-pg", host="postgres", port=5432, database="pgeditor", username="pgeditor", password="secret"}, token)
    assert.are.equal(201, conn.status)
    local test = http_post("/api/v1/connections/"..conn.body.data.id.."/test", {}, token)
    assert.are.equal(200, test.status)
  end)
end)
```

`query_spec.lua`: `POST /query/execute` select, hatalı sorgu, history.

`table_browser_spec.lua`: list_rows, insert, patch, delete, duplicate.

## Bench (wrk)

`api/bench/query_execute.lua`:

```lua
-- wrk script: login → token al → her thread'de POST /query/execute
wrk.method="POST"
wrk.headers["Authorization"]="Bearer "..token
wrk.headers["Content-Type"]="application/json"
wrk.body=cjson.encode({connection_id=CONN_ID, sql="SELECT * FROM customers LIMIT 100"})
```

`bench/run.sh`:

```bash
#!/usr/bin/env bash
set -e
API=http://localhost:${API_HOST_PORT:-28080}/api/v1
echo "==> health"
wrk -t4 -c64 -d30s http://localhost:${API_HOST_PORT}/api/v1/health
echo "==> query execute (mixed)"
wrk -t4 -c64 -d30s -s api/bench/query_execute.lua $API/query/execute
```

## Eşikler (4 vCPU, worker auto, yerel PG)

| Senaryo | Hedef RPS | p99 | Hata |
|---|---|---|---|
| `/health` | ≥10k | <10ms | 0 |
| `GET /connections` | ≥3k | <50ms | 0 |
| mixed (70% SELECT /20% POST query /10% rows) | ≥1.5k | <100ms | 0 |
| `/auth/login` | ≥100 | <300ms | 0 (Argon2) |

## DoD

- [ ] `make lint && make test` зел, iki Lua yorumlayıcı.
- [ ] `make test.integration` API ayakta iken yeşil.
- [ ] `make spec.lint` redocly 0 hata.
- [ ] `make bench` eşikleri karşılar, logda 5xx yok.
- [ ] CI `ci.yml` lint+test+bench koşar, coverage `luacov` 80%+.
