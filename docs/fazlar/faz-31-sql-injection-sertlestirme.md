# ═══ FAZ 31 — SQL INJECTION SERTLEŞTİRME (KRİTİK) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — katman kuralları §4, hata §5, env §6.
> Önceki: Faz-30, faz-09 (table_browser), faz-01 (shared validation), `docs/security-checklist.md` §5.

## Amaç
Meta DB ve Hedef DB'de parametreli sorgu dışındaki tek açık yüzeyleri kapatmak:
`custom_where` (tablo tarayıcı + CSV export), `safe_sql`/`validate_expression` tutarsızlığı,
`builder.where_raw` ölü kodu, ve sayısal `LIMIT/OFFSET` string-concat kalıntıları.

## Önkoşullar
- F1 (validation), F3 (db/query builder), F9 (table_browser), F10 (csv export).

## Kapsam Dışı
- Rol bazlı yıkıcı sorgu onayı (Faz-32), WAF/CI (Faz-33).

## Çıktılar
| Yol | Değişiklik |
|---|---|
| `shared/src/validation.lua` | `safe_sql` güçlendir: `; -- /* $n` + `transaction` + yasak kelimeler (`SELECT/UNION/INSERT/UPDATE/DELETE/DROP/TRUNCATE/CREATE/ALTER/COPY` vb.) aynı `sql_parser.validate_expression` kurallarıyla; `max 5000` korunur |
| `api/src/utils/sql_parser.lua` | `validate_expression(expr, allowed_columns?)` genişlet: (a) yasak kelime listesi, (b) `allowed_columns` set'i varsa kolon allow-list, (c) ham fonksiyon/parantez derinliği limiti, (d) `pg_` prefix bloğu; `; -- /* $n transaction` korunur |
| `api/src/services/table_browser_service.lua` | `validate_expression(custom_where, meta.by_name)` kolon set'i ile çağır |
| `api/src/services/csv_export_service.lua` | aynı — `validate_expression(custom_where, allowed?)` |
| `api/src/db/query.lua` | `where_raw` kaldır (ölü kod); `like_pattern` korunur |
| `api/src/repositories/target_schema_repo.lua` | `category_sql` ve `count_categories_sql` LIMIT/OFFSET'i string-concat yerine parametreli `$n` ile üret; `limit/offset` `math.floor` + `1..500` clamp zaten var |
| `api/src/db/target/table_browser.lua` + `api/src/db/target/csv.lua` | zaten parametreli — değişiklik yok, sadece teyit |
| `api/spec/query_parser_spec.lua` + `shared/spec/sql_guard_spec.lua` | yeni red/accept testleri |

## Tasarım — `validate_expression` Yeni Kurallar

```lua
-- Yasak kelimeler (literal/yorum dışında, lower + %f[%w_] sınır):
local FORBIDDEN = {
  "select","insert","update","delete","drop","truncate","create","alter",
  "grant","revoke","comment","reindex","vacuum","cluster","copy","union",
  "into","exec","execute","declare","fetch","with","having","window"
}
-- Ek: "pg_" ile başlayan identifier reddedilir (pg_sleep, pg_catalog).
-- allowed_columns ~= nil ise: expr içindeki "[a-zA-Z_][a-zA-Z0-9_]*" token'ları
-- toplanır, keywords dışındakiler allowed set'te olmalı; aksi halde false.
-- Derinlik limiti: parantez derinliği > 10 → false.
```

`safe_sql` ise `validate_expression` ile aynı çekirdeği kullanır — shared katman `pg_shared.sql_parser`’ı
gerektiremez (pure), bu yüzden bağımsız aynı yasak listesini içerir; drift’i önlemek için testte ikisi eşlenik doğrulanır.

## LIMIT/OFFSET Parametreleştirme
`target_schema_repo.category_sql(category, with_q, limit, offset)` → dönüş:
```sql
SELECT ... WHERE n.nspname = $1 AND ... [AND col ILIKE $2 ESCAPE '\'] ORDER BY col LIMIT $3 OFFSET $4
```
`limit/offset` `math.floor` + clamp zaten var; şimdi placeholder. `list_category` çağıran yer
parametre sırasını buna göre günceller. `count_categories_sql` zaten parametresiz — dokunulmaz.

## where_raw Kaldırma
`api/src/db/query.lua:158` `where_raw` hiç kullanılmıyor (`grep -r where_raw` tek tanım).
Kaldır, yerine yorum: "ham SQL gerekirse parametreli builder kullan".

## Güvenlik Matrisi (custom_where)
| Girdi | Beklenen |
|---|---|
| `total_amount > 100` | ✅ |
| `status = 'paid' AND total > 100` | ✅ |
| `name ILIKE '%x%'` | ✅ |
| `1=1; DROP TABLE t` | ❌ `;` |
| `1=1 -- x` | ❌ yorum |
| `id = $1` | ❌ parametre |
| `a > 1) OR (1=1` | ❌ dengesiz parantez |
| `id IN (SELECT id FROM t)` | ❌ SELECT yasak |
| `pg_sleep(5)` | ❌ pg_ |
| `bilinmeyen_kolon > 1` | ❌ kolon allow-list |

## DoD
- [ ] `custom_where="1=1; DROP"` → 400 `BAD_REQUEST`; `SELECT`, `UNION`, `pg_sleep` içeren ifade reddedilir.
- [ ] `custom_where` bilinmeyen kolon içeriyorsa 400 (allow-list).
- [ ] `safe_sql` kuralı `; -- /* $n transaction SELECT UNION` hepsini reddeder (unit test).
- [ ] `category_sql` çıktısı `LIMIT $` placeholder içerir; `LIMIT 200` string concat kalmaz.
- [ ] `builder.where_raw` repo’da yok (`grep where_raw` boş).
- [ ] `make lint && make test` (busted LuaJIT + Lua 5.4 shared) yeşil; mevcut e2e `browse.spec.ts` “custom_where kaçış reddedilir” yeşil.
