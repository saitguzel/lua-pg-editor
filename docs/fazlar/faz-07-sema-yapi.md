# ═══ FAZ 07 — ŞEMA & YAPI İNCELEME ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7 (`schema.browser`, `structure.view`), audit §8.

## Amaç

Şema ve tablo yapısı inceleme: hedef DB'de veritabanı listesi, şema/tablo/view listesi, ve bir tablo/view için 6 eksenli yapı incelemesi.

## Önkoşullar

- F6 (connections + pool_manager).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/schema.lua` | 3 handler (schemas, objects, structure) |
| `api/src/services/schema_service.lua` | orchestration + cache invalidation |
| `api/src/repositories/target_schema_repo.lua` | hedef DB'ye SQL (information_schema + pg_catalog) |
| `api/src/models/database_object.lua` | `DatabaseObject` serialize |
| `api/src/models/table_structure.lua` | `Structure` DTO |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `GET` | `/connections/:id/databases` | ✅ | `schema.browser` | DB listesi |
| `GET` | `/connections/:id/schemas` | ✅ | `schema.browser` | Şema listesi (`SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema') ORDER BY`) |
| `GET` | `/connections/:id/schemas/:schema/objects` | ✅ | `schema.browser` | Tablo + view (`information_schema.tables` BASE TABLE/VIEW) |
| `GET` | `/connections/:id/objects/:schema/:name/structure` | ✅ | `structure.view` | Yapı (6 bölüm) |
| `GET` | `/connections/:id/completion` | ✅ | `schema.browser` | Autocomplete katalogu (tüm şemalar/tablo/kolon) |

Query params: `?database=postgres` (optional, default connection.database). `schema` ve `name` URL-encode; handler `sql_identifier` validate.

## Handler Öz

```lua
local function schemas(self)
  local id, err = errors.require_uuid_param(self,"id","CONNECTION_NOT_FOUND"); if not id then return errors.respond(err) end
  local db = self.params.database -- ?database=
  local list, svc_err = schema_service.list_schemas(ngx.ctx.identity, id, db); if not list then return errors.respond(svc_err) end
  return { status=200, json={ data=list } }
end
local function structure(self)
  local id, err = errors.require_uuid_param(self,"id","CONNECTION_NOT_FOUND"); if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema=self.params.schema, name=self.params.name }); if not clean then return errors.respond(errors.validation(v)) end
  local data, svc_err = schema_service.get_structure(ngx.ctx.identity, id, clean.schema, clean.name, self.params.database); if not data then return errors.respond(svc_err) end
  return { status=200, json={ data=data } }
end
```

## Service & Repository

`schema_service.list_schemas(identity, connection_id, database)`:

1. ownership check (`CONNECTION_NOT_FOUND` 404).
2. `pool_manager.acquire(conn)` → hedef pool
3. `completion_cache` dict `completion:<conn_id>:<db>` var mı? TTL henüz dolmadıysa → oradan (F8 ile paylaşılır).
4. yoksa `target_schema_repo.list_schemas(pool)` → `SELECT schema_name ... ORDER BY`.

`schema_service.get_structure`:

1. `with_audit("structure.view")` 
2. `target_schema_repo` 6 sorguyu **paralel** `ngx.thread.spawn` ile (her biri ayrı bağlantı alır):
   - **columns**: `information_schema.columns` + `pg_attribute` birleşimi (is_primary, has_default, is_identity, is_generated)
   ```sql
   SELECT c.column_name, c.data_type, c.udt_name, c.is_nullable, c.column_default,
          c.ordinal_position, pg_get_expr(adbin, adrelid) IS NOT NULL AS is_identity,
          ... FROM information_schema.columns c LEFT JOIN pg_attrdef ...
   ```
   - **indexes**: `pg_index` + `pg_class` + `pg_attribute`
   ```sql
   SELECT indexname, indexdef FROM pg_indexes WHERE schemaname=$1 AND tablename=$2
   ```
   - **constraints**: `information_schema.table_constraints` + `pg_constraint`
   - **foreign_keys**: `information_schema.key_column_usage` + `referential_constraints`
   - **triggers**: `information_schema.triggers`
   - **stats**: `pg_stat_user_tables` (live/dead tuples) + `pg_total_relation_size`
3. `QUERY_FAILED` mapping: `42P01` (undefined_table) → `OBJECT_NOT_FOUND` 404.
4. audit `structure.view`?

`load_schema` mantığı: `information_schema.tables WHERE table_type IN ('BASE TABLE','VIEW')` → `target_schema_repo.list_objects(schema)` ile aynı.

**Completion Catalog** (`/completion`): `list_schemas` + her şemada `list_objects` + her tabloda `columns` → `{ schemas: [{ name, tables: [{ name, kind, columns: [{ name, type, nullable }] }] }] }` → `completion_cache` dict'e JSON (5 dk).

## Modeller

```lua
DatabaseObject = { schema, name, kind="table"|"view" }
ColumnDetail = { name, display_type, type_name, type_group, is_array, is_range, is_nullable, is_primary_key, has_default, is_identity, is_generated, ordinal_position, enum_values }
IndexInfo = { name, def, is_primary, is_unique }
ConstraintInfo = { name, type, def }
FkInfo = { name, column, foreign_schema, foreign_table, foreign_column, on_delete, on_update }
TriggerInfo = { name, timing, event, statement }
Structure = { object, columns, indexes, constraints, foreign_keys, triggers, size_bytes }
```

## Validasyon

- `object_ref`: `schema` ve `name` `sql_identifier` (max 63, reserved değil).
- `database` query param `sql_identifier` optional.

## Güvenlik

- Hedef DB sorguları read-only guard yok (F7 sadece katalog), ama `schema`/`name` değerleri parametreli `$1,$2` ile gönderilir — asla string interpolate değil.
- `pool_manager` hata → `CONNECTION_FAILED` 502.

## DoD

- [ ] `GET /connections/:id/schemas` → `["public","analytics",...]` (pg_catalog hariç).
- [ ] `GET /connections/:id/schemas/public/objects` → `[{schema:"public",name:"customers",kind:"table"}, {name:"my_view",kind:"view"}]`.
- [ ] `GET /connections/:id/objects/public/customers/structure` → 6 bölüm dolu: columns 10, indexes 2, constraints 1, fk 0, triggers 0 (demo DB).
- [ ] Olmayan tablo → `404 OBJECT_NOT_FOUND`.
- [ ] `GET /completion` → katalog JSON, ikinci istek cache hit (latency <5ms).
- [ ] Audit `structure.view` yok (read-only, gürültü önleme) — karar, loglanmaz.
