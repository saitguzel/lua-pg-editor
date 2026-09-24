# ═══ FAZ 19 — FRONTEND VIEWS II (TABLO TARAYICI & YAPI) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — FILTER_OPS, PAGE_SIZE_OPTIONS.

## Amaç

Tablo tarayıcı + yapı inceleme ekranları: sayfalı/filtreli satır listesi, satır CRUD ve 6 sekmeli yapı inspector.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/src/views/table_browser.lua` | rows grid, pagination, filters, sort, custom_where, row actions |
| `web/src/views/row_form.lua` | insert/edit modal (type-aware inputs) |
| `web/src/views/structure.lua` | columns/indexes/constraints/fk/triggers/size sekmeleri |
| `web/src/components/filter_bar.lua` | kolon + operator + value, custom SQL |
| `web/src/components/pagination.lua` | page/per_page/size options |

## Table Browser

Route: `#/browse/:schema/:table?connection_id=&database=&page=&per_page=&sort=&filters=&custom_where=`

- Header: `schema.table` başlık + yapı linki (`#/structure/:schema/:table`) + script dropdown + export csv + truncate/drop (admin).
- Toolbar: `filter_bar` → her filtre `column operator value`; `+ Filtre ekle` → kolon seç → operator listesi `FilterOperator.for_column`'e göre dinamik.
  - boolean: `=, !=, IS NULL`
  - text: `=, !=, LIKE, ILIKE, IS NULL`
  - numeric/datetime: `=, !=, >, >=, <, <=, IS NULL`
- `Custom SQL filtre` input: `total_amount > 100` → `custom_where` (server `safe_sql`).
- Grid: kolon header tıklayınca `sort` toggle (`col` → `-col`). Hücre inline edit: çift tık → input (tip'e göre).
  - text → `<input>`
  - boolean → checkbox
  - enum → select
  - json → textarea (JSON validate)
  - binary → "Düzenlenemez" rozeti
- Pagination: `page`/`per_page` (50/100/250/500), `has_next` → ileri/geri, total rozeti.
- Row actions: checkbox seç → `Sil` (bulk `DELETE /rows {ids}`), tek satır `⋯` menü → `Düzenle`, `Çoğalt` (`POST /rows/:rid/duplicate`), `Sil`.
- Insert: `+ Satır ekle` → `row_form` modal → required kolonlar vurgulu, `has_default` olanlar placeholder "varsayılan".
- Optimistic: insert → `TABLE_ROW_OPTIMISTIC_CREATE` (geçici id), success → `CONFIRMED`, failure → `ROLLBACK` + toast.

## Row Form (type-aware)

```lua
-- columns meta'dan input tipi
if column.type_group=="boolean" then h("input", {type="checkbox", checked=value})
elseif column.uses_text_display then h("input", {type="text", value=value})
elseif column.type_name=="jsonb" then h("textarea", {value=pretty_json(value)})
elseif column.enum_values and #column.enum_values>0 then h("select", ..., options=enum_values)
```

Validasyon: `is_required_for_insert` → boşsa `zorunlu alan`.

## Structure View

Route: `#/structure/:schema/:name`

- `GET /connections/:id/objects/:schema/:name/structure` → 6 sekmeli panel:
  1. **Kolonlar**: tablo `name | type | nullable | default | PK | identity | generated | enum?` (badge).
  2. **Indexler**: `name | def | unique | primary`.
  3. **Constraintler**: `name | type | def`.
  4. **Foreign Keys**: `column → foreign_schema.foreign_table.foreign_column (ON DELETE ...)`.
  5. **Triggerler**: `name | timing | event | statement`.
  6. **İstatistik**: `size_bytes` (pg_total_relation_size), `live tuples`.
- Her sekme `GET` sonrası skeleton; hata `OBJECT_NOT_FOUND` → "Tablo bulunamadı".
- "Script üret" butonu her sekmede: `GET /script?kind=select|create` → modal.

## Filter Bar Detail

- `filters` state array → `encodeURIComponent(cjson.encode(filters))` → URL query (deep-link).
- `custom_where` için `FILTER_OPS` değil, ham SQL; `;` içeren giriş frontend'de engellenir.

## DoD

- [ ] `#/browse/public/customers` → grid 100 satır, header sort çalışır.
- [ ] Filtre `status = paid` → yalnızca paid, `custom_where` `total_amount>100` → ikinci filtre AND.
- [ ] Hücre edit `tier` enum → select `enterprise` → `PATCH /rows/:rid` → grid güncellenir.
- [ ] `+ Satır ekle` → modal, required boş → validasyon, başarılı → yeni satır en üstte.
- [ ] `Çoğalt` → PK hariç kopya, yeni satır.
- [ ] Bulk seç 2 satır → Sil → confirm → `DELETE /rows` → grid -2.
- [ ] `#/structure/public/customers` → 6 sekme dolu, FK `orders.customer_id → customers.id`.
