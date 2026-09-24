# ═══ FAZ 08 — SORGU MOTORU & GEÇMİŞ ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7 (`query.execute`, `query.history`), audit §8, env §6 (QUERY_*).

## Amaç

SQL yürütme çekirdeği: sözdizimi vurgulama, şema duyarlı tamamlama, çoklu ifade, satır limiti, salt-okunur guard ve veritabanı başına sorgu geçmişi.

## Önkoşullar

- F6 (connections), F7 (completion cache).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/query.lua` | execute, history list, completion |
| `api/src/services/query_service.lua` | execute, validate, history insert, catalog invalidate |
| `api/src/repositories/query_history_repo.lua` | insert, find_by_connection_db, delete_old |
| `api/src/db/target/query.lua` | **hedef** execute, execute_read_only, parse helpers |
| `api/src/models/query_result.lua` | QueryResult DTO |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `POST` | `/query/execute` | ✅ | `query.execute` | SQL çalıştır → `{ columns, rows, row_count, truncated, duration_ms }` |
| `GET` | `/query/history` | ✅ | `query.history` | Geçmiş listele `?connection_id=&database=&limit=50` |
| `DELETE` | `/query/history` | ✅ | `query.history` | Geçmişi temizle `?connection_id=&database=` |
| `GET` | `/connections/:id/completion` | ✅ | `query.execute` | (F7, burada tamamlanır) Katalog |

`POST /query/execute` gövdesi:
```json
{ "connection_id": "uuid", "database": "postgres", "sql": "SELECT ...", "row_limit": 1000 }
```
`row_limit` opsiyonel; yoksa `QUERY_ROW_LIMIT_DEFAULT`, clamp `1..QUERY_ROW_LIMIT_MAX`. `sql` `1..QUERY_MAX_BYTES`.

## Handler

```lua
local function execute(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.query_execute, body); if not clean then return errors.respond(errors.validation(v)) end
  if #clean.sql > config.get().query.max_bytes then return errors.respond(errors.new("PAYLOAD_TOO_LARGE")) end
  local res, svc_err = query_service.execute(ngx.ctx.identity, clean); if not res then return errors.respond(svc_err) end
  return { status=200, json={ data=res } }
end
local function history(self)
  local q = validation.validate(validation.schemas.query_history_query, self.params)
  local rows, meta = query_service.list_history(ngx.ctx.identity, q); return { status=200, json={ data=rows, meta=meta } }
end
```

Rate limit: `query_rate_limit` dict `query:<user_id>:<connection_id>` 30/dk; aşınca `RATE_LIMITED`.

## Service (query_service.lua)

```lua
function _M.execute(identity, input)
  -- 1. ownership: connection_repo.find_by_id(input.connection_id) → user_id check
  -- 2. rate limit
  -- 3. with_transaction(meta): history insert rezervasyonu?
  -- 4. pool_manager.acquire(conn, input.database or conn.database)
  -- 5. t0 = ngx.now()
  -- 6. target_query.execute(pool, input.sql, row_limit) → QueryExecutionResult
  --    - `sql_statements` parser: çoklu ifade say, her biri için fetch_many
  --    - son ifade Rows ise onu döndür, değilse AffectedRows
  --    - hata → sqlstate map: 42P01→OBJECT_NOT_FOUND (as QUERY_FAILED wrapper), 42601→BAD_REQUEST
  -- 7. duration_ms = (ngx.now()-t0)*1000
  -- 8. with_transaction: query_history_repo.insert(user_id, connection_id, database, sql, row_count, duration_ms, truncated)
  --    auto-save: her yürütme otomatik kaydedilir
  -- 9. changes_schema(sql) → true ise completion_cache:delete(key) (F7 invalidation)
  -- 10. audit query.execute (success/failure) — failure da history yazılmaz mı? yazılır ama row_count nil
  -- 11. return result
end
```

`changes_schema(sql)`: `ALTER|CREATE|DROP|COMMENT|GRANT|REVOKE|REINDEX` keyword'ü literal dışında geçiyor mu?

## Target Query (db/target/query.lua)

```lua
local sql_statements = require("utils.sql_parser") -- sql_statements ayristirici
function _M.execute(pool, sql, row_limit)
  local safe_limit = clamp(row_limit, MIN, MAX)
  local stream = pool:fetch_many(sql) -- pgmoon raw_sql fetch_many
  return collect_stream(stream, sql, safe_limit, "display")
end
function _M.execute_read_only(pool, sql, row_limit)
  -- validate_read_only: BEGIN/COMMIT/ROLLBACK içermemeli
  -- BEGIN READ ONLY → stream → ROLLBACK
end
-- helpers: sql_statements, count_statements, has_multiple, leading_keywords, strip_comments,
--          contains_keyword_outside_literals, exceeds limit → row_limit_reached flag
```

Özgün uygulamadan:

- `safe_row_limit` clamp
- `last_sql_statement` → `expects_rows_when_empty` (SELECT/WITH/SHOW/EXPLAIN/VALUES/RETURNING)
- `contains_transaction_control` → export guard
- `strip_leading_sql_comments` loop
- `sql_statements` state machine: `'`, `"`, `--`, `/*`, `$tag$`.

## Query History Repo

```sql
INSERT INTO query_history(user_id, connection_id, database, sql, row_count, duration_ms, truncated)
VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *;
SELECT * FROM query_history WHERE user_id=$1 AND connection_id=$2 AND database=$3 ORDER BY executed_at DESC LIMIT $4 OFFSET $5;
```

`list_history` params: `connection_id` required, `database` optional (yoksa tüm DB'ler), `limit` 1..100 default 50.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Her yürütme otomatik history | kullanıcı "Save" demez, otomatik kaydedilir |
| `changes_schema` ile cache invalidation | DDL sonrası completion stalesın |
| `row_limit` server clamp | istemci 1M istese DB öldürmesin |
| Çoklu ifade: son Rows'u döndür | `SELECT 1; SELECT 2` → ikinci sonuc döner |
| `QUERY_FAILED` 422 | SQL hatası validasyon gibi; 500 değil |

## DoD

- [ ] `POST /query/execute { sql:"SELECT * FROM customers" }` → `200 { columns:[...], rows:[[...]], row_count, truncated:false }`.
- [ ] `row_limit=2` → `truncated:true`, `rows` 2 satır.
- [ ] Hatalı SQL `SELECT * FROM yok` → `422 QUERY_FAILED` + `details.sqlstate=42P01`.
- [ ] Çoklu `SELECT 1; SELECT 2` → ikinci sonuç.
- [ ] Her execute sonrası `GET /query/history?connection_id=...` listede en üstte.
- [ ] DDL `CREATE TABLE tmp ...` sonrası `GET /completion` katalogda yeni tablo var (invalidate).
- [ ] Rate limit aşınca `429`.
