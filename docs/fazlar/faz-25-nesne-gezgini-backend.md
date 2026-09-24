# ═══ FAZ 25 — NESNE GEZGİNİ BACKEND (KATEGORİ ENDPOINT'LERİ) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7 (`schema.browser`, `structure.view`, `script.generate`), dict §9 (`completion_cache`), error §5.
> Analiz: [faz-24](faz-24-spec-analizi-bosluk-haritasi.md) §Nesne Gezgini.

## Amaç

Nesne gezgininin **Şema → Kategori → Nesne** hiyerarşisini lazy yükleyebilmesi için kategori bazlı katalog
endpoint'leri; spec'teki tüm kategorileri (sequence, type, domain, extension, operator, collation, FTS, aggregate/window)
ve tablo altı `rules`/`policies` bölümlerini sunmak. `GET /completion` autocomplete için **değişmeden** kalır.

## Önkoşullar

- F7 (schema_service, target_schema_repo), F10 (script_service).
- F24 kararı: page key eklenmez; tüm yeni endpoint'ler `schema.browser` / `structure.view` / `script.generate` altında.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/repositories/target_schema_repo.lua` | `CATEGORY_SQL` tablosu, `count_categories`, `list_category`, `list_rules`, `list_policies`, `object_detail` |
| `api/src/services/schema_service.lua` | `list_categories` (cache'li), `list_objects` (category/q/limit/offset), `get_structure` genişlemesi |
| `api/src/handlers/schema.lua` | `categories` handler; `objects` handler query param'ları |
| `api/src/models/database_object.lua` | `kind` kümesi genişler; ölü `m → view` dalı silinir |
| `api/src/models/table_structure.lua` | `RuleInfo`, `PolicyInfo`, `ObjectDetail` DTO |
| `api/src/db/target/script.lua` | view/matview/sequence/type/domain/foreign için `CREATE` |
| `shared/src/types.lua` | `OBJECT_CATEGORIES`, `OBJECT_KINDS` |
| `shared/src/validation.lua` | `schema_objects_query` şeması |
| `api/src/openapi/spec.lua` | yeni route + şemalar |
| `api/spec/schema_catalog_spec.lua` | birim testleri |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `GET` | `/connections/:id/schemas/:schema/categories` | ✅ | `schema.browser` | `[{category, count}]` — tek sorgu, cache'li |
| `GET` | `/connections/:id/schemas/:schema/objects?category=&q=&limit=&offset=` | ✅ | `schema.browser` | Kategori nesneleri. `category` yoksa **mevcut davranış** (tablo/view/matview/foreign) — geri uyumlu |
| `GET` | `/connections/:id/objects/:schema/:name/structure?kind=` | ✅ | `structure.view` | Mevcut yanıt + `rules[]`, `policies[]`; tablo dışı `kind` için `detail{}` |
| `GET` | `/connections/:id/objects/:schema/:name/script?kind=create` | ✅ | `script.generate` | view, matview, sequence, type, domain, foreign için CREATE |

Query params: `?database=` (mevcut). `q` ≤ 64 karakter, ILIKE `%q%`; `limit` 1–500 (varsayılan 200); `offset` ≥ 0.

Yanıt zarfı 00 §15: `{ data: [...], meta: { total, limit, offset } }` (objects için `meta` yalnız `category` verildiğinde).

## Kategori Kataloğu

`shared/src/types.lua`:

```lua
_M.OBJECT_CATEGORIES = {
  "tables", "views", "matviews", "foreign_tables", "sequences",
  "functions", "procedures", "types", "domains", "extensions",
  "operators", "collations", "fts_configs", "fts_dicts", "fts_parsers", "fts_templates",
}
-- kind değerleri (database_object.kind): table, partitioned, view, matview, foreign, sequence,
-- function, aggregate, window, procedure, type_base, type_composite, type_enum, type_range,
-- domain, extension, operator, collation, fts_config, fts_dict, fts_parser, fts_template
```

`target_schema_repo.lua` — her kategori `(schema, name, kind, extra)` döner; `USER_SCHEMAS` filtresi (mevcut satır 12-13)
her sorguda ortak, `$1` = şema adı, `$2` = `%q%` (nil ise `TRUE`):

```sql
-- tables
SELECT n.nspname, c.relname, CASE c.relkind WHEN 'p' THEN 'partitioned' ELSE 'table' END, NULL
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = $1 AND c.relkind IN ('r','p') AND NOT c.relispartition AND ($2 IS NULL OR c.relname ILIKE $2)
-- views: relkind='v' · matviews: 'm' · foreign_tables: 'f' · sequences: 'S'
-- functions (aggregate/window dahil)
SELECT n.nspname, p.proname,
       CASE p.prokind WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window' ELSE 'function' END,
       jsonb_build_object('oid', p.oid, 'args', pg_get_function_identity_arguments(p.oid),
                          'returns', pg_get_function_result(p.oid), 'language', l.lanname)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = $1 AND p.prokind IN ('f','a','w') AND ($2 IS NULL OR p.proname ILIKE $2)
-- procedures: prokind = 'p'
-- types (base/composite/enum/range; dizi ve tablo satır tipleri hariç)
SELECT n.nspname, t.typname,
       CASE t.typtype WHEN 'b' THEN 'type_base' WHEN 'c' THEN 'type_composite' WHEN 'e' THEN 'type_enum' WHEN 'r' THEN 'type_range' END,
       NULL
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
LEFT JOIN pg_class c ON c.oid = t.typrelid
WHERE n.nspname = $1 AND t.typtype IN ('b','c','e','r') AND t.typelem = 0
  AND (t.typrelid = 0 OR c.relkind = 'c') AND ($2 IS NULL OR t.typname ILIKE $2)
-- domains: typtype = 'd'  (extra: format_type(typbasetype, typtypmod))
-- extensions
SELECT n.nspname, e.extname, 'extension', jsonb_build_object('version', e.extversion)
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE n.nspname = $1
-- operators
SELECT n.nspname, o.oprname, 'operator',
       jsonb_build_object('left', o.oprleft::regtype, 'right', o.oprright::regtype, 'result', o.oprresult::regtype)
FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace WHERE n.nspname = $1
-- collations: pg_collation (collnamespace) · fts_configs: pg_ts_config (cfgnamespace)
-- fts_dicts: pg_ts_dict (dictnamespace) · fts_parsers: pg_ts_parser (prsnamespace) · fts_templates: pg_ts_template (tmplnamespace)
```

Sayaç sorgusu (`count_categories`): yukarıdaki 16 sorgunun `SELECT '<category>' AS category, count(*)` biçimi
`UNION ALL` ile tek round-trip. Extension fonksiyonları `functions` sayısına **dahil edilmez** (mevcut `pg_depend` filtresi korunur).

Tablo altı ek bölümler (`get_structure`):

```sql
-- rules
SELECT r.rulename AS name, r.ev_type, r.is_instead, pg_get_ruledef(r.oid) AS def
FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = $1 AND c.relname = $2 AND r.rulename <> '_RETURN'
-- policies
SELECT p.polname AS name, p.polcmd AS command, p.polpermissive AS permissive,
       ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles)) AS roles,
       pg_get_expr(p.polqual, p.polrelid) AS using_expr, pg_get_expr(p.polwithcheck, p.polrelid) AS check_expr
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = $1 AND c.relname = $2
```

`detail{}` (tablo dışı kind, `object_detail(kind, schema, name)`):

| kind | detail alanları |
|---|---|
| sequence | `data_type, start, increment, min, max, cache, cycle, last_value, owned_by` (`pg_sequences` + `pg_depend`) |
| type_enum | `labels[]` (`pg_enum` sırasıyla) |
| type_composite | `attributes[{name,type}]` (`pg_attribute` relkind='c') |
| type_range | `subtype, collation` (`pg_range`) |
| domain | `base_type, not_null, default, constraints[{name,def}]` (`pg_constraint contypid`) |
| extension | `version, relocatable, description` |
| operator | `left, right, result, function` |
| collation | `provider, lc_collate, lc_ctype` |
| fts_* | `description` (`obj_description`) |

## Handler Öz

```lua
local function categories(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND"); if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.schema_ref, { schema = self.params.schema, database = self.params.database })
  if not clean then return errors.respond(errors.validation(v)) end
  local list, svc_err = schema_service.list_categories(ngx.ctx.identity, id, clean.schema, clean.database)
  if not list then return errors.respond(svc_err) end
  return { status = 200, json = { data = list } }
end

local function objects(self) -- mevcut handler genişler
  local clean, v = validation.validate(validation.schemas.schema_objects_query, {
    schema = self.params.schema, database = self.params.database, category = self.params.category,
    q = self.params.q, limit = self.params.limit, offset = self.params.offset })
  if not clean then return errors.respond(errors.validation(v)) end
  local list, meta_or_err = schema_service.list_objects(ngx.ctx.identity, id, clean)
  if not list then return errors.respond(meta_or_err) end
  return { status = 200, json = { data = list, meta = clean.category and meta_or_err or nil } }
end
```

## Service & Repository

`schema_service.list_categories(identity, conn_id, schema, db)`:
1. ownership check (`CONNECTION_NOT_FOUND`).
2. `completion_cache` anahtarı `categories:<conn_id>:<db>:<schema>` — hit ise JSON decode.
3. miss: `target_schema_repo.count_categories(pool, schema)` → dict'e `COMPLETION_CACHE_TTL` ile yaz.

`schema_service.list_objects(identity, conn_id, opts)`: `opts.category` yoksa mevcut `list_objects`; varsa
`target_schema_repo.list_category(pool, category, schema, q, limit + 1, offset)` → `limit+1` ile `has_more`;
`meta = { total = count (sayaçtan), limit, offset, has_more }`. Cache **yok** (liste küçük, `q` değişken).

`invalidate_completion(conn, db)` genişler: `completion:` ve `categories:<conn>:<db>:*` anahtarları. `lua_shared_dict` prefix
silme desteklemediği için şema listesi `get_keys()` ile taranır (dict 5m, anahtar sayısı düşük).

`script_service.generate(kind="create")` → `db/target/script.lua`:
- view/matview: `CREATE [MATERIALIZED] VIEW s.n AS <pg_get_viewdef>` (+ matview için `WITH [NO] DATA` ve index'ler).
- sequence: `CREATE SEQUENCE s.n AS <type> START/INCREMENT/MINVALUE/MAXVALUE/CACHE/[CYCLE]` (+ `OWNED BY`).
- type_enum: `CREATE TYPE s.n AS ENUM ('a','b')`; type_composite: `AS (col type, …)`; type_range: `AS RANGE (subtype = …)`.
- domain: `CREATE DOMAIN s.n AS <base> [DEFAULT] [NOT NULL] [CONSTRAINT …]`.
- foreign: mevcut tablo yolu + `SERVER <srv> OPTIONS (…)` (`pg_foreign_table`).

## Modeller

```lua
DatabaseObject = { schema, name, kind, extra? }      -- extra: kategoriye özel jsonb (args/returns, version, …)
CategoryCount  = { category, count }
RuleInfo       = { name, event, is_instead, def }
PolicyInfo     = { name, command, permissive, roles, using_expr, check_expr }
Structure      = { object, kind, columns, indexes, constraints, foreign_keys, triggers, rules, policies, size_bytes, stats, detail? }
```

## Validasyon

- `schema_ref`: `schema` sql_identifier, `database` optional sql_identifier.
- `schema_objects_query`: `schema_ref` + `category` ∈ `OBJECT_CATEGORIES` (optional), `q` string ≤ 64 (optional),
  `limit` int 1–500 (default 200), `offset` int ≥ 0 (default 0).
- `script?kind=` mevcut `SCRIPT_KINDS`; `create` için nesne türü sunucuda `pg_class`/`pg_type`'tan tespit edilir.
- `handlers/script.lua:19` — `database` param'ı **sql_identifier ile validate edilir** (mevcut eksik).

## Güvenlik

- Tüm katalog sorguları `$1,$2` parametreli; `q` yalnız ILIKE deseni, `%`/`_` kaçışlanır (`escape_like`).
- `limit` tavanı 500: kötü niyetli `offset` taraması yok (katalog sorguları hafif).
- Cache anahtarı kullanıcı içermez ama ownership check cache'ten önce (mevcut F7 davranışı).

## Test

- `api/spec/schema_catalog_spec.lua` (birim, DB gerektirmez):
  - `CATEGORY_SQL` her `OBJECT_CATEGORIES` için tanımlı; bilinmeyen kategori `nil` döner.
  - `escape_like("a%b_")` → `a\%b\_`.
  - `count_categories_sql()` 16 `UNION ALL` parçası içerir.
  - `script.create_sql({kind="type_enum", labels={"a","b'c"}})` → tek tırnak kaçışlı çıktı.
- `api/spec/openapi_spec.lua` mevcut kural: router ↔ spec eşleşmesi (yeni route eklenince spec zorunlu).
- Entegrasyon (`api/spec/integration/schema_catalog_spec.lua`): demo DB'de sequence/enum/domain/policy oluşturup
  sayaç ve listeyi doğrular. **Yalnız `make up.e2e` yığınında** — `busted --run=integration` metadata DB'yi TRUNCATE eder,
  geliştirme yığınında çalıştırılmaz.

## Adımlar

1. `types.lua` `OBJECT_CATEGORIES`/kind listesi + `validation.lua` şemaları → `shared/spec` yeşil (LuaJIT + 5.4).
2. `target_schema_repo.lua`: `CATEGORY_SQL`, `escape_like`, `count_categories`, `list_category` → birim spec.
3. `schema_service.list_categories` + cache + invalidation genişlemesi.
4. `handlers/schema.lua` `categories` + `objects` param'ları; `router.lua` route; `openapi/spec.lua`.
5. `get_structure`: rules/policies + `object_detail`; `table_structure.lua` DTO'lar.
6. `script.lua` CREATE üreticileri; `routines_spec` benzeri kaçış testleri.
7. `database_object.lua` ölü dal temizliği; `handlers/script.lua` database validasyonu.
8. `make lint && make test`; e2e yığınında entegrasyon spec.

## DoD

- [ ] `GET /connections/:id/schemas/public/categories` → 16 satır, ör. `{category:"tables",count:24}`; ikinci istek cache hit.
- [ ] `GET …/objects?category=sequences` → `[{schema:"public",name:"orders_id_seq",kind:"sequence"}]`, `meta.total` sayaçla eşit.
- [ ] `GET …/objects?category=functions` → aggregate `kind:"aggregate"`, window `kind:"window"` ayrı görünür.
- [ ] `GET …/objects?category=types` → enum `type_enum`, composite `type_composite`; dizi tipleri ve tablo satır tipleri **yok**.
- [ ] `GET …/objects` (category'siz) → F7 yanıtıyla birebir aynı (geri uyumluluk; `parity.spec.ts` yeşil).
- [ ] `?q=ord&limit=1&offset=0` → 1 satır + `meta.has_more=true`.
- [ ] `GET …/objects/public/orders/structure` → `rules`, `policies` dizileri (RLS'li tabloda dolu).
- [ ] `GET …/objects/public/status/structure?kind=type_enum` → `detail.labels=["new","paid"]`.
- [ ] `GET …/objects/public/v_orders/script?kind=create` → `CREATE VIEW public.v_orders AS SELECT …`.
- [ ] `ALTER`/`CREATE` sonrası (query_service) `categories:` anahtarları silinir; sonraki sayaç güncel.
- [ ] `openapi_spec` yeşil; `make lint && make test` yeşil.
