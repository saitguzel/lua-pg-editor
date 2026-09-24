# ═══ FAZ 26 — NESNE GEZGİNİ FRONTEND (AĞAÇ, LAZY, FİLTRE, SAĞ TIK, DETAY) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7; F17 store/dom; F18 schema_sidebar; F19 structure.
> API: [faz-25](faz-25-nesne-gezgini-backend.md).

## Amaç

Sol paneli spec'teki ağaca dönüştürmek: **Şema → Kategori (sayaçlı, katlanabilir) → Nesne → (tablo) Columns / Indexes /
Constraints / Triggers / Rules / Policies**. Kategori açılınca lazy yükleme; anlık arama + hızlı filtre; her nesne türü için
ikon; sağ tık menüsünde "SELECT ile getir", "CREATE script'i göster", "Yenile"; tıklamada sağda detay.

## Önkoşullar

- F25 endpoint'leri.
- Autocomplete `GET /completion` ile beslenmeye **devam eder** (`query_editor.lua:139-142`); ağaç artık ona bağımlı değildir.

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `web/src/views/schema_sidebar.lua` | ağaç durumu, lazy yükleme, kategori/alt düğüm render, hızlı filtre, düğüm yenile |
| `web/src/views/schema_tree.lua` (**yeni**) | saf yardımcılar: `filter_nodes`, `quick_filter_matches`, `format_count`, `node_key` — test edilebilir |
| `web/src/views/object_actions.lua` | `menu_items`: CREATE script view/matview/sequence/type/domain; "Yenile"; sequence için SELECT |
| `web/src/views/structure.lua` | tablo dışı `kind` için `detail` paneli; `rules`/`policies` sekmeleri |
| `web/src/icons.lua` | `sequence`, `type`, `domain`, `extension`, `operator`, `collation`, `fts` ikonları |
| `web/src/storage.lua` | `sidebar.expanded:<conn>` (kalıcı açık düğümler), `sidebar.filter` |
| `web/src/router.lua` | `#/structure/:schema/:name?kind=` (mevcut route, `kind` query) |
| `web/spec/schema_tree_spec.lua` | birim testleri |
| `web/e2e/explorer.spec.ts` | uçtan uca |

## Ağaç Modeli

```lua
-- schema_sidebar.lua modül durumu (bağlantı+DB başına)
tree = {
  key = "<conn>|<db>",
  schemas = { status = "idle|loading|ready|error", items = { "public", ... } },
  categories = { [schema] = { status, items = { { category="tables", count=24 }, ... } } },
  objects    = { [schema .. ":" .. category] = { status, items = { DatabaseObject... }, has_more, offset } },
  children   = { [schema .. "." .. name] = { status, structure = Structure } }, -- tablo alt düğümleri
}
expanded = storage.get("sidebar.expanded:" .. conn) or { public = true }  -- key: "public", "public:tables", "public.orders"
```

Yükleme sırası (hepsi `app.spawn` ile, `fetch` üzerinden):
1. Panel açılınca `GET /connections/:id/schemas` → şema düğümleri; `public` (ya da seçili nesnenin şeması) açık.
2. Şema açılınca `GET …/schemas/:schema/categories` → 16 kategori; `count == 0` olanlar gri, tıklanamaz (`aria-disabled`).
3. Kategori açılınca `GET …/objects?category=&limit=200` → nesneler; `has_more` ise sonda "Daha fazla yükle (N kalan)".
4. Tablo/partitioned/foreign düğümü açılınca `GET …/structure` → 6 sabit alt düğüm: Columns (n) / Indexes (n) /
   Constraints (n) / Triggers (n) / Rules (n) / Policies (n); her biri açılınca satırlar (kolon: `ad tip`, index: ad, …).
5. Aynı anahtar için tekrar istek atılmaz (`status == "loading"` guard); F5/yenile `force` ile.

Kategori etiketi: `format_count("Tables", 24)` → `Tables (24)`. Etiketler spec'teki İngilizce adlarla
(Tables, Views, Materialized Views, Foreign Tables, Functions, Procedures, Sequences, Types, Domains, Extensions,
Operators, Collations, FTS Configurations, FTS Dictionaries, FTS Parsers, FTS Templates).

## Arama ve Hızlı Filtre

- `input#sidebar-search` (mevcut, Ctrl+F) — anlık istemci filtresi: `filter_nodes(tree, q)` yüklü nesneleri ad ile
  (case-insensitive substring) süzer, eşleşen düğümlerin ataları otomatik açılır.
- `#q ≥ 2` ise 300 ms debounce ile **açık şemalar** için `GET …/objects?category=<her kategori>&q=` (sayaç > 0 olanlar);
  sonuç geçici `search_results[schema]` içinde, arama temizlenince ağaç eski haline döner.
- Hızlı filtre çipleri (arama kutusunun altında, `role="radiogroup"`):

```lua
QUICK_FILTERS = {
  { id = "all",       label = "Tümü" },
  { id = "tables",    label = "Sadece tablolar", categories = { tables = true, foreign_tables = true } },
  { id = "views",     label = "View'lar",        categories = { views = true, matviews = true } },
  { id = "routines",  label = "Fonksiyonlar",    categories = { functions = true, procedures = true } },
  { id = "other",     label = "Diğer",           categories = { sequences=true, types=true, domains=true, extensions=true,
                                                                 operators=true, collations=true, fts_configs=true,
                                                                 fts_dicts=true, fts_parsers=true, fts_templates=true } },
}
-- quick_filter_matches(filter_id, category) → bool ; "all" her zaman true
```

Seçim `storage` `sidebar.filter` ile kalıcı; gizlenen kategoriler DOM'a girmez.

## İkonlar

| kind | icon | renk |
|---|---|---|
| table, partitioned | `table` | sky |
| view, matview | `eye` | emerald |
| foreign | `plug` | slate |
| function, aggregate, window | `function` | violet |
| procedure | `procedure` | amber |
| trigger | `zap` | rose |
| sequence | `sequence` (123 rozeti) | orange |
| type_* | `type` (küme) | teal |
| domain | `domain` (kalkan) | teal |
| extension | `extension` (puzzle) | fuchsia |
| operator | `operator` (±) | slate |
| collation | `collation` (Aa) | slate |
| fts_* | `fts` (büyüteç-metin) | lime |

`icons.lua`'ya 7 yeni SVG (lucide seti, 24px viewBox); `KIND_LABEL` tooltip'leri Türkçe.

## Sağ Tık Menüsü

`object_actions.menu_items(ctx, obj)` genişler (`context_menu` bileşeni mevcut):

| Öğe | Türler | Eylem |
|---|---|---|
| Tarayıcıda aç / Yapıyı aç | table, partitioned, foreign, view, matview | mevcut |
| Detayı aç | sequence, type_*, domain, extension, operator, collation, fts_* | `#/structure/:schema/:name?kind=` |
| SELECT ile getir | ilişkiler + sequence | `SELECT * FROM s.n LIMIT 100` / sequence: `SELECT * FROM s.seq` → aktif sekme |
| CREATE script'i göster | table, view, matview, sequence, type_*, domain, foreign | `GET …/script?kind=create` → yeni sekme (`script.generate` yetkisi) |
| Yenile | **her düğüm** (şema, kategori, nesne) | yalnız o düğümün alt verisini `force` ile yeniden çeker |
| Adı kopyala / Nitelikli adı kopyala | hepsi | mevcut |
| Yeniden adlandır / Truncate / Drop | mevcut kapsam (F10) | mevcut |

Kategori başlığında sağ tık: "Yenile", "Hepsini daralt". Şema başlığında: "Yenile", "Tüm kategorileri aç/kapat".
Rutin gruplarındaki "+" (CREATE şablonu) `functions`/`procedures` kategorilerine taşınır.

## Detay Paneli (`structure.lua`)

- `kind` tablo/ilişki ise mevcut sekmeler + **Rules (n)** ve **Policies (n)** sekmeleri
  (`RuleInfo.def`, `PolicyInfo.command/roles/using_expr/check_expr` tablo olarak).
- Tablo dışı `kind` için tek "Detay" sekmesi: `detail` alanları `dl` listesi; enum `labels` rozet; composite
  `attributes` tablo; domain `constraints` tablo. Üstte "CREATE script" ve "Kopyala" butonları.
- Boyut/istatistik bölümü yalnız `table/partitioned/matview` için (view'da sıfır gösterme).

## Klavye ve Erişilebilirlik

- Ağaç `role="tree"`, düğümler `role="treeitem" aria-expanded aria-level`; ↑/↓ gezinme, →/← aç/kapat, Enter tıklama,
  `*` kardeşleri aç (F21 a11y kuralları).
- Yükleniyor düğümü `aria-busy="true"` + skeleton satırı; hata düğümü "Yeniden dene" butonu.

## Test

- `web/spec/schema_tree_spec.lua`:
  - `format_count("Tables", 24)` → `"Tables (24)"`; `format_count("Tables", 0)` → `"Tables (0)"`.
  - `quick_filter_matches("tables", "foreign_tables")` true, `("tables", "views")` false, `("all", x)` true.
  - `filter_nodes` "ord" → `orders`, `orders_id_seq` kalır, `customers` düşer; eşleşen nesnenin şema/kategori anahtarı açık listesine girer.
  - `node_key("public", "tables")` = `"public:tables"`, `node_key("public", nil, "orders")` = `"public.orders"`.
  - Reducer/istek: `helper.queue_response` ile `/categories` → 16 satır; `status=="ready"`; ikinci açılış yeni istek atmaz (`#fake.calls` sabit).
- `web/e2e/explorer.spec.ts`: şema aç → `Tables (N)` görünür → kategori aç → ağ isteği `category=tables` → arama "ord" →
  hızlı filtre "Sadece tablolar" view'ları gizler → sağ tık view → "CREATE script'i göster" yeni sekme `CREATE VIEW` →
  sağ tık kategori → "Yenile" yeni istek → tablo aç → Columns (n) → Policies (n).
- Mevcut `parity.spec.ts` "F7 sidebar ve nesne eylemleri" yeşil kalır (rename/truncate/drop menüde).

## DoD

- [ ] Sol panelde `public ▸ Tables (24) ▸ orders ▸ Columns (10)` hiyerarşisi; her seviye katlanabilir.
- [ ] Kategori açılana kadar o kategori için ağ isteği yok (Network sekmesinde doğrulanır); açılınca tek istek.
- [ ] 200'den fazla nesnede "Daha fazla yükle" çalışır; sayaç `meta.total` ile tutarlı.
- [ ] Arama kutusuna "ord" → yalnız eşleşenler, ataları açık; temizleyince eski görünüm.
- [ ] "Sadece tablolar" çipi view/fonksiyon kategorilerini gizler; sayfa yenilenince seçim korunur.
- [ ] Her kind için farklı ikon; tooltip'te Türkçe tür adı.
- [ ] Sağ tık: SELECT ile getir (tablo, sequence) / CREATE script (view, sequence, enum) / Yenile (şema, kategori, nesne) çalışır.
- [ ] Sequence'e tıklayınca sağda `start/increment/last_value` detayı; enum'a tıklayınca label listesi.
- [ ] Ağaç klavye ile gezilebilir (axe testinde ihlal yok).
- [ ] `make test.web` ve `explorer.spec.ts` + `parity.spec.ts` yeşil.
