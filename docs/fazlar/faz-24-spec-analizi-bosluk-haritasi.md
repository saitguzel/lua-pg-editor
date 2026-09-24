# ═══ FAZ 24 — SPEC ANALİZİ & BOŞLUK HARİTASI ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7, error kodları §5, env §6, dict §9.

## Amaç

"Tek PostgreSQL'e bağlanan web SQL editörü" spec'ini mevcut pgLua ile karşılaştırmak; hangi maddenin zaten var
olduğunu, hangisinin eksik/kısmi olduğunu dosya:satır kanıtıyla sabitlemek ve eksikleri F25–F30 fazlarına dağıtmak.
Bu faz **kod üretmez**; sonraki fazların tek girdisidir.

## Önkoşullar

- F0–F23 tamamlanmış (mevcut ürün).

## Mimari Karar (spec ile çelişen maddeler)

| Spec maddesi | Karar | Gerekçe |
|---|---|---|
| Tek DB, `.env` içinde `DATABASE_URL`, bağlantı yönetimi yok | **Reddedildi.** Çoklu bağlantı (F6) korunur. | Çalışan özellik sökülmez; spec "bir bağlantı seçildikten sonraki" editör deneyimi olarak yorumlanır. Kullanıcı tek bağlantı tanımlayınca spec'teki deneyim birebir sağlanır. |
| Kullanıcı/yetki sistemi yok | **Reddedildi.** JWT auth (F5) + RBAC (F11) korunur. | Aynı gerekçe. Yeni fazlar yeni page key **eklemez**; `schema.browser`, `structure.view`, `script.generate`, `query.execute`, `export.csv` yeniden kullanılır. |
| `POST /api/query` `{ sql }` | Mevcut `POST /api/v1/query/execute` `{ connection_id, database?, sql, row_limit? }` kalır. | Zarf ve hata modeli 00 §15/§5 ile uyumlu. |
| React.memo / useMemo / useCallback | Uygulanmaz. | Frontend Lua-WASM; karşılığı `dom.lua` keyed diff + `app.schedule_render` birleştirmesi (F17). |
| Bağlantı kullanıcısı read-only önerisi | Kabul; F30'da `security-checklist.md`'ye madde. | Uygulama zorlamaz, operatör kararı. |

## Boşluk Haritası

Durum: ✅ var · ◐ kısmi · ❌ yok. Kanıt sütunu mevcut koddur.

### Nesne Gezgini (spec §2)

| Madde | Durum | Kanıt | Faz |
|---|---|---|---|
| Hiyerarşi Şema → Kategori → Nesne | ❌ Şema → düz nesne listesi + 3 alt grup (fonksiyon/prosedür/trigger) | `web/src/views/schema_sidebar.lua:26-30,222-246` | F26 |
| Şemalar `pg_namespace`, `pg_catalog`/`information_schema` hariç | ✅ | `api/src/repositories/target_schema_repo.lua:12-13` | — |
| Tables / Views / Matviews / Foreign Tables | ✅ listeleniyor, kategori klasörü yok | `target_schema_repo.lua:14-17` (relkind r,p,v,m,f) | F26 |
| Functions (skaler, tablo değerli) / Procedures | ◐ `prokind IN ('f','p')`; **aggregate/window yok** | `target_schema_repo.lua:160-168` | F25 |
| Sequences | ❌ | — | F25 |
| Types (composite/enum/range/base) | ❌ (`pg_type` yalnız kolon enum değerleri için okunuyor) | `target_schema_repo.lua:52-55` | F25 |
| Domains | ❌ | — | F25 |
| Extensions | ❌ (extension fonksiyonları bilinçli filtreleniyor) | `target_schema_repo.lua:166` | F25 |
| Operators / Collations | ❌ | — | F25 |
| FTS Configurations / Dictionaries / Parsers / Templates | ❌ | — | F25 |
| Tablo altı: Columns / Indexes / Constraints / Triggers | ✅ structure sayfasında; ağaçta alt düğüm yok | `api/src/services/schema_service.lua:76-87`, `web/src/views/structure.lua` | F25 (API) / F26 (ağaç) |
| Tablo altı: Rules / Policies | ❌ (`pg_rewrite`, `pg_policy` sorgusu yok) | — | F25 |
| Katlanabilir kategori + sayaç `Tables (24)` | ◐ şema başlığında toplam sayı var, kategori yok | `schema_sidebar.lua:246` | F26 |
| Lazy loading | ❌ tüm katalog tek `GET /completion` ile | `schema_sidebar.lua:45-61` | F25 + F26 |
| Arama çubuğu (anlık) | ✅ substring | `schema_sidebar.lua:262-266` | — |
| Hızlı filtreler ("sadece tablolar") | ❌ | — | F26 |
| Nesneye tıklayınca sağda detay | ◐ tablo/view → tarayıcı; rutin → DDL sekmesi; diğer türler yok | `schema_sidebar.lua:84-86,129-131` | F26 |
| Sağ tık: SELECT ile getir | ✅ | `web/src/views/object_actions.lua:112-134` | — |
| Sağ tık: CREATE script'i göster | ◐ yalnız tablo (API view/matview üretebiliyor) | `object_actions.lua:120-128`, `api/src/db/target/script.lua:98-133` | F26 |
| Sağ tık: Yenile (düğüm bazlı) | ❌ yalnız global F5 | `schema_sidebar.lua:204-205` | F26 |

### SQL Editörü (spec §3)

| Madde | Durum | Kanıt | Faz |
|---|---|---|---|
| Çoklu sekme: yeni / kapat | ✅ | `web/src/views/query_editor.lua:72,401` | — |
| Sekme yeniden adlandırma | ❌ başlık SQL'in ilk 4 kelimesi | `query_editor.lua:39-49` | F27 |
| Syntax highlighting, satır numarası | ✅ CodeMirror 6 + `lang-sql` PostgreSQL | `web/js/glue.js:10-32,399` | — |
| Otomatik tamamlama (şema/tablo/kolon) | ✅ | `glue.js:37-47,81-100` | — |
| `Ctrl+Enter` tümünü çalıştır | ✅ (seçim varsa seçimi çalıştırır) | `glue.js:407`, `web/src/keyboard.lua:29-53` | — |
| `Ctrl+Shift+Enter` seçili kısmı çalıştır | ❌ | — | F27 |
| Sorgu geçmişi | ✅ sunucu tablosu, arama, popover | `web/src/views/query_history.lua` | — |
| Geçmişten tekrar çalıştırma (tek tık) | ◐ "Uygula" yalnız editöre yükler | `query_history.lua:84-96` | F27 |
| Sorgu kaydetme | ✅ sunucu `snippets` + yerleşik taslaklar | `web/src/components/snippet_picker.lua` | — |
| Formatlama | ❌ | — | F27 (isteğe bağlı) |

### Sorgu Çalıştırma & Sonuçlar (spec §4)

| Madde | Durum | Kanıt | Faz |
|---|---|---|---|
| Sonuç grid'i: başlık, satır | ✅ | `web/src/components/result_grid.lua:135-154` | — |
| Sayfalama / virtual scrolling | ❌ tek `<table>` | `result_grid.lua` | F28 |
| Hücre kopyalama | ✅ sağ tık (hücre/satır/kolon/tümü TSV), çift tık görüntüleyici | `result_grid.lua:71-102,170` | F29 (ipucu) |
| DML/DDL etkilenen satır | ◐ "N satır etkilendi"; komut adı yok | `result_grid.lua:130-133` | F28 |
| Hata: mesaj + SQLSTATE | ✅ rozet | `result_grid.lua:104-113` | — |
| Hata: pozisyon | ❌ `parse_error` position'ı düşürüyor | `api/src/db/pool_manager.lua:33-38` | F27 |
| Süre (ms) + satır sayısı | ✅ | `result_grid.lua:174-180` | — |
| Yıkıcı komut onayı (DROP/TRUNCATE/DELETE) | ❌ | `api/src/utils/sql_parser.lua` yalnız `changes_schema` | F27 |
| Zaman aşımı yapılandırılabilir | ◐ `QUERY_TIMEOUT_MS` yalnız socket timeout; `statement_timeout` yok | `pool_manager.lua:135,174-177` | F30 |
| Varsayılan 1000 satır | ✅ | `query_editor.lua:17`, `config.lua:50` | — |
| "Tümünü getir" | ❌ (limit girişi var, tavan 50.000) | `result_grid.lua:156-162` | F27 |

### UI/UX (spec §5)

| Madde | Durum | Kanıt | Faz |
|---|---|---|---|
| Sol gezgin / üst araç çubuğu / editör / alt sonuç, yeniden boyutlandırılabilir | ✅ iki splitter, klavye ile de | `query_editor.lua:619-665`, `glue.js:135-181` | — |
| Karanlık/aydınlık tema | ✅ light/dark/system | `web/src/app.lua:397,477-479` | — |
| Nesne türü ikonları | ◐ 7 tür | `schema_sidebar.lua:14-21` | F26 |
| Yükleniyor / boş durum | ✅ | `layout.empty_state`, `query_editor.lua:603-606` | — |
| Responsive (≥1280 optimize) | ✅ mobilde rail | `web/src/views/layout.lua:57-66` | — |
| Görünmeyen özellikler için ipuçları | ❌ `?` modalı var ama görünür buton yok; sağ tık/çift tık/Esc/Tab/splitter ok tuşları duyurulmuyor | `keyboard.lua`, `web/src/components/modal.lua:162-188` | F29 |

### Güvenlik & Performans (spec §8–§9)

| Madde | Durum | Kanıt | Faz |
|---|---|---|---|
| `.env` frontend'e sızmaz | ✅ web bundle env okumaz | `web/build-wasm.sh` | F30 (DoD kontrolü) |
| CORS yalnız frontend origin | ✅ prod'da `*` reddedilir | `api/src/config.lua:37,140-141` | — |
| Rate limiting | ◐ sorgu için `query_rate_limit` dict (kullanıcı+bağlantı); nginx `limit_req` yok | `api/src/services/query_service.lua:26`, `api/conf/nginx.conf` | F30 |
| Nesne listelerinde lazy + sayfalama | ❌ | — | F25/F26 |
| Export diyaloğu: Excel/JSON'da gereksiz alanlar | ❌ **hata doğrulandı**, F28'de düzeltildi | `web/src/components/csv_dialog.lua` | F28 |

## Yeni Faz Haritası

| Faz | Ad | Efor | Bağımlılık |
|---|---|---|---|
| 25 | Nesne Gezgini Backend (kategori endpoint'leri) | L | F7 |
| 26 | Nesne Gezgini Frontend (ağaç, lazy, filtre, sağ tık, detay) | L | F25 |
| 27 | SQL Editör Geliştirmeleri | M | F8, F18 (F25'ten bağımsız) |
| 28 | Sonuç Paneli & Dışa Aktarma | M | F8, F10 (F25'ten bağımsız) |
| 29 | İpuçları & Keşfedilebilirlik | S–M | F21, F27, F28 |
| 30 | Performans, Zaman Aşımı & Güvenlik | M | F25, F27 |

```
F23 ─► F24 ─► F25 ─► F26 ─┐
         ├──► F27 ────────┼─► F29 ─► F30
         └──► F28 ────────┘
```

## Kayıt Gereksinimleri (00'a eklenecekler)

- Yeni page key: **yok**. Yeni error kodu: **yok** (`RATE_LIMITED` 429 zaten var).
- Yeni env (F30): `QUERY_STATEMENT_TIMEOUT_MS` (varsayılan `30000`), `RATE_LIMIT_RPS` (varsayılan `10`).
- Yeni dict anahtarı (F25): `completion_cache` içinde `categories:<connection_id>:<database>:<schema>`.

## DoD

- [ ] Bu tablodaki her ❌/◐ satırının bir faz numarası var.
- [ ] F25–F30 dosyaları `docs/fazlar/` altında ve `docs/README.md` + `00-genel-bakis.md` §12–§13 güncel.
- [ ] Mimari karar (auth + çoklu bağlantı korunur) ekipçe onaylı; aksi karar bu dosyada revize edilir.
