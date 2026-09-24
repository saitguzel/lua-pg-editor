# ═══ FAZ 09 — TABLO TARAYICI & SATIR DÜZENLEME ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7 (`table.browser`, `table.edit`).

## Amaç

Tablo satır yönetimi: hedef DB'de bir tablonun satırlarını sayfalı/filtreli listelemek ve satır CRUD işlemleri.

## Önkoşullar

- F6, F7 (structure → kolon meta), F8 (target query helpers).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/table_browser.lua` | 6 handler |
| `api/src/services/table_browser_service.lua` | fetch, filter, insert, update, delete, duplicate |
| `api/src/db/target/table_browser.lua` | `SELECT ... WHERE ... ORDER BY ... LIMIT/OFFSET`, `INSERT/UPDATE/DELETE` |
| `api/src/models/table_browser.lua` | TablePage, TableColumn, TableFilter DTO |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `GET` | `/connections/:id/objects/:schema/:table/rows` | ✅ | `table.browser` | Satır listesi `?page&per_page&sort&filters&custom_where` |
| `POST` | `/connections/:id/objects/:schema/:table/rows` | ✅ | `table.edit` | Satır ekle `{ values: { col: value } }` |
| `PATCH` | `/connections/:id/objects/:schema/:table/rows/:rid` | ✅ | `table.edit` | Hücre düzenle `{ values: {...} }` (tek/çok kolon) |
| `DELETE` | `/connections/:id/objects/:schema/:table/rows` | ✅ | `table.edit` | Sil `body { ids: [rid, ...] }` veya `?rid=` |
| `POST` | `/connections/:id/objects/:schema/:table/rows/:rid/duplicate` | ✅ | `table.edit` | Satırı çoğalt (PK hariç) |

`rid` = primary key'in satır tanıtıcısı. Tek kolon PK ise değer, bileşik PK ise `col1:val1,col2:val2` (handler `decode_rid` → `WHERE pk1=$1 AND pk2=$2`). PK yoksa `ctid` kullanılır (riskli, uyarı).

Query params `GET /rows`:

- `page` 1.., `per_page` 50|100|250|500 default 100
- `sort` `col` veya `-col` (whitelist kolon adları)
- `filters` JSON: `[{ column:"status", operator:"=", value:"paid" }, ...]`
- `custom_where` — ham SQL ifade (`safe_sql` + allow-list kolonlar)

## Handler Öz

```lua
local function list_rows(self)
  local id, err = errors.require_uuid_param(self,"id","CONNECTION_NOT_FOUND"); if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.table_rows_query, self.params); if not clean then return errors.respond(errors.validation(v)) end
  local page, err = table_browser_service.list(ngx.ctx.identity, id, self.params.schema, self.params.table, clean); if not page then return errors.respond(err) end
  return { status=200, json={ data=page.rows, meta={ page=page.page, per_page=page.per_page, total=page.total, has_next=page.has_next } } }
end
```

## Service

`list(identity, connection_id, schema, table, query)`:

1. ownership + `structure` kolon meta'yı al (cache veya `target_schema_repo.columns`).
2. `filters` validate: her `operator` `FilterOperator.for_column(column)` içinde mi? `LIke` binary kolonda yasak → `VALIDATION_FAILED`.
3. `custom_where` varsa `sql_parser.validate_expression(custom_where, allowed_columns)` (basit: `;` yasak, `SELECT` yasak).
4. `target_table_browser.fetch_rows(pool, schema, table, columns, query)`:
   ```sql
   SELECT * FROM "schema"."table"
   WHERE (col = $1) AND (custom_where)
   ORDER BY "col" ASC LIMIT $n OFFSET $m
   ```
   - `WHERE` builder `$?` → `$1..`
   - `ORDER BY` whitelist kolon adları `pg_quote_identifier`.
   - `COUNT(*) OVER()` veya ayrı `SELECT COUNT(*)` → total.
5. satırları `TableCell` DTO'ya çevir (null → `{ value="NULL", is_null=true }`).

`insert(identity, ...)`:

- `is_insertable` kolonlar: `!is_identity && !is_generated && is_editable_value_type()` (binary hariç).
- `is_required_for_insert`: `!nullable && !has_default && !is_identity`
- eksik required → `VALIDATION_FAILED`.
- `INSERT INTO "s"."t" ("a","b") VALUES ($1,$2) RETURNING *` → `table.row.create` audit.

`update`:

- `PATCH /rows/:rid` body `values` → yalnızca gönderilen kolonlar.
- `uses_text_display` kolonlar için text input, diğerleri tip duyarlı (boolean checkbox, date picker).
- `UPDATE ... SET "col"=$1 WHERE pk=$2 RETURNING *` → audit.

`delete`:

- `DELETE FROM "s"."t" WHERE pk IN ($1,$2,...)` → `affected_rows`.

`duplicate`:

- `SELECT * WHERE pk=$1` → `INSERT` PK hariç tüm kolonlarla.

Tüm yazma işlemleri audit + `completion_cache` invalidate yok (satır, şemayı değiştirmez).

## Target Table Browser (SQL)

```lua
function _M.fetch_rows(pool, schema, table, columns, opts)
  -- columns schema'dan
  -- build where: filters → column operator value
  --   =, !=, >, >=, <, <=, LIKE, ILIKE, IS NULL, IS NOT NULL
  --   LIKE → like_pattern(value)
  -- custom_where → doğrudan `AND (<expr>)` (validate edilmiş)
  -- order → sort whitelist
  -- limit/offset
end
```

`FilterOperator` (pg_shared.types): `Equal("=")`, `NotEqual`, `GreaterThan`, `Like`, `ILike`, `IsNull` … `needs_value`, `for_column` (boolean: `=,!=,IS NULL`; datetime/numeric: `=,!=,>,>=,<,<=,IS NULL`; text: `=,!=,LIKE,ILIKE,IS NULL`).

## Teknik Kararlar

| Karar | Neden |
|---|---|
| PK rid encoding `col:val` | URL-safe, bileşik PK desteği |
| `ctid` fallback | PK'sız tabloda tarama ve delete/update uyarısı |
| `LIKE`/`ILIKE` desteği | filtrelerde mevcut |
| `custom_where` ayrı param | Kullanıcı `a=1 AND b ILIKE '%x%'` yazabilsin; ama `;` yasak |
| Binary kolonlar `IS NULL` yalnızca | bytea edit stabilize değil |

## DoD

- [ ] `GET /rows?page=1&per_page=2&sort=-placed_at` → 2 satır, total 7, has_next true.
- [ ] `GET /rows?filters=[{"column":"status","operator":"=","value":"paid"}]` → yalnızca paid.
- [ ] `GET /rows?custom_where=total_amount>100` → filtre çalışır; `custom_where=1; DROP` → `400 BAD_REQUEST`.
- [ ] `POST /rows {values:{customer_id:1,status:"draft",...}}` → `201`, `GET /rows` total+1.
- [ ] `PATCH /rows/:rid {values:{status:"paid"}}` → satır güncellenir, audit `table.row.update`.
- [ ] `DELETE /rows {ids:[...]}` → total-1.
- [ ] `POST /rows/:rid/duplicate` → PK hariç kopya, yeni PK otomatik.
