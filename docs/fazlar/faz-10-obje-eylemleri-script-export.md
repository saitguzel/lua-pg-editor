# ═══ FAZ 10 — OBJE EYLEMLERİ, SCRIPT & CSV EXPORT ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7 (`object.actions`, `script.generate`, `export.csv`), teknik düzeltme #22.

## Amaç

Obje eylemleri: Rename/Truncate/Delete tablo/view + DDL script üretimi + CSV dışa aktarma (BEGIN READ ONLY + COPY).

## Önkoşullar

- F7 (structure), F8 (query), F9 (rows).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/object_actions.lua` | rename, truncate, drop |
| `api/src/handlers/script.lua` | generate |
| `api/src/handlers/export.lua` | query csv + table csv |
| `api/src/services/object_actions_service.lua` | DDL yürütme + audit + guard |
| `api/src/services/script_service.lua` | DDL şablonları |
| `api/src/services/csv_export_service.lua` | streaming CSV |
| `api/src/db/target/object_actions.lua` | rename/truncate/drop SQL |
| `api/src/db/target/script.lua` | pg_get_* ile DDL |
| `api/src/db/target/csv.lua` | COPY TO STDOUT CSV |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `POST` | `/connections/:id/objects/:schema/:name/rename` | ✅ | `object.actions` | `{ new_name }` → 200 |
| `POST` | `/connections/:id/objects/:schema/:name/truncate` | ✅ | `object.actions` | `{ cascade: bool }` |
| `DELETE` | `/connections/:id/objects/:schema/:name` | ✅ | `object.actions` | Drop (table/view) `?cascade=` |
| `GET` | `/connections/:id/objects/:schema/:name/script` | ✅ | `script.generate` | `?kind=select|insert|create|drop|truncate` |
| `POST` | `/query/csv` | ✅ | `export.csv` | `{ connection_id, sql, delimiter, include_header }` → `text/csv` |
| `POST` | `/connections/:id/objects/:schema/:table/export` | ✅ | `export.csv` | Tablo tamamını CSV `?filters&custom_where&columns` |

## Handler Öz

```lua
local function rename(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_rename, body); if not clean then return errors.respond(errors.validation(v)) end
  local res, e = object_actions_service.rename(ngx.ctx.identity, self.params.id, self.params.schema, self.params.name, clean.new_name, self.params.database); if not res then return errors.respond(e) end
  return { status=200, json={ data=res } }
end
local function script(self)
  local kind = self.params.kind; if not pg_shared.types.is_member(pg_shared.types.SCRIPT_KINDS, kind) then return errors.respond(errors.new("VALIDATION_FAILED")) end
  local s, e = script_service.generate(ngx.ctx.identity, self.params.id, self.params.schema, self.params.name, kind); if not s then return errors.respond(e) end
  return { status=200, json={ data={ sql=s } } }
end
local function query_csv(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.csv_export, body); if not clean then return errors.respond(errors.validation(v)) end
  -- streaming: ngx.header["Content-Type"]="text/csv"; ngx.header["Content-Disposition"]...
  -- csv_export_service.stream_query_csv(ngx, identity, clean)
  -- handler streaming modunda: ngx.print + ngx.flush
end
```

## Service Detayı

**object_actions_service.rename**:

1. ownership + `new_name` `sql_identifier` (max 63, reserved değil).
2. `pool:query("ALTER TABLE \"s\".\"t\" RENAME TO \""..quote_ident(new_name).."\"")` — `quote_ident` whitespace değil, identifier quote.
3. hata: `42P07` (duplicate_table) → `CONFLICT` + details, `42501` insufficient_privilege → `FORBIDDEN`?
4. audit `object.rename` (`old_name`→`new_name`), `completion_cache` invalidate, `structure` cache clear.

**truncate**: `TRUNCATE TABLE "s"."t" [CASCADE]` — `cascade` bool.

**drop**: `DROP TABLE|VIEW "s"."t" [CASCADE]` — `pg_class.relkind` ile tip ayırt et (`r` table, `v` view). View ise `DROP VIEW`.

**script_service.generate**:

| kind | Üretilen SQL |
|---|---|
| `select` | `SELECT "col1","col2" FROM "s"."t";` (kolonlar `ordinal_position` sırası) |
| `insert` | `INSERT INTO "s"."t" ("col1", ...) VALUES (...);` (type hint'li) |
| `create` | `SELECT pg_get_tabledef(...)` veya `pg_get_viewdef` → `CREATE TABLE ...` |
| `drop` | `DROP TABLE "s"."t";` |
| `truncate` | `TRUNCATE TABLE "s"."t";` |

`TableScriptKind::Select|Insert|Create|Drop` için Lua uygulamasında `pg_get_tabledef` yok; alternatif: `SELECT 'CREATE TABLE ' || quote_ident(...) || ' (' || string_agg(... )` veya `pg_dump` tarzı query. Karar: `information_schema.columns` + `pg_constraint` ile `CREATE` şablonu kur (F7 colon meta'yı yeniden kullan).

**csv_export_service.stream_query_csv**:

```lua
function _M.stream_query_csv(ngx, identity, input)
  -- pool_manager.acquire
  -- validate_read_only(input.sql) → transaction control içermemeli
  -- BEGIN READ ONLY → ngx header → COPY (input.sql) TO STDOUT WITH (FORMAT csv, HEADER include_header)
  -- loop: pg:query("FETCH ...") veya `COPY ... TO STDOUT` streaming
  -- ngx.print(chunk); ngx.flush(true)
  -- ROLLBACK
  -- audit query.export.csv
end
```

Hedef sorgu `SELECT ...` ise `COPY (SELECT ...) TO STDOUT CSV HEADER`. `CSV_MAX_ROWS` aşılırsa `PAYLOAD_TOO_LARGE`? Karar: `LIMIT CSV_MAX_ROWS+1` kontrol, aşınca `truncated` flag + `Content-Disposition: attachment; filename="export.csv"` yine döner ama frontend uyarı gösterir.

## Validasyon

- `object_rename`: `new_name` `sql_identifier` 1..63.
- `csv_export`: `sql` 1..QUERY_MAX_BYTES, `delimiter` optional enum `, ; \t |`, `include_header` bool default true.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Streaming via `ngx.print` | Büyük CSV belleğe sığmaz; keepalive değil, connection close |
| `BEGIN READ ONLY` | `execute_read_only` ile yanlışlıkla `DELETE` engellenir |
| `quote_ident` whitelist + pg_quote_ident | SQL enjeksiyon engeli |
| `CASCADE` opsiyonel | truncate/drop bağımlı objeler |
| Script üretim backend'de | Frontend kolon listesini zaten bilse de DDL tek kaynak backend olsun |

## DoD

- [ ] `POST /rename {new_name:"customers2"}` → `200`, sonraki `GET /schemas/public/objects` listede `customers2`.
- [ ] Var olan isme rename → `409 CONFLICT`.
- [ ] `POST /truncate` → `200`, `GET /rows` 0 satır.
- [ ] `GET /script?kind=select` → `SELECT "id", "name" FROM "public"."customers";`.
- [ ] `GET /script?kind=create` → `CREATE TABLE ...` içinde `customer_tier` enum tipi görünür.
- [ ] `POST /query/csv {sql:"SELECT * FROM customers"}` → `200 text/csv`, `Content-Disposition`, satırlar CSV, `,;"` escape doğru.
- [ ] `sql:"DELETE FROM customers"` → `422 READONLY_VIOLATION`.
- [ ] Audit `object.(rename|truncate|drop)`, `script.generate`, `query.export.csv` kayıtlı.
