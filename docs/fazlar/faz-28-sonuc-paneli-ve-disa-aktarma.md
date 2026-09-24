# ═══ FAZ 28 — SONUÇ PANELİ & DIŞA AKTARMA ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — §11 madde 23 (büyük sonuç bellek), page key `export.csv` §7.
> Analiz: [faz-24](faz-24-spec-analizi-bosluk-haritasi.md) §Sorgu Çalıştırma, §Güvenlik & Performans.

## Amaç

Sonuç grid'ini binlerce satırda akıcı tutmak (sayfalama, gerekirse virtual scrolling), DML/DDL geri bildirimini
netleştirmek ve **dışa aktarma diyaloğundaki hatayı** (Excel/JSON seçilince CSV'ye özel alanların görünmesi) kapatmak.

## Önkoşullar

- F8 (query_result), F10 (export handler, csv/xlsx/json render), F18 (result_grid).
- F25/F26'dan bağımsız.

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `web/src/components/csv_dialog.lua` | **düzeltildi**: `fields(format)`, `content` fonksiyon, format `onchange` |
| `web/spec/csv_dialog_spec.lua` | **eklendi**: format başına alan görünürlüğü |
| `web/src/components/result_grid.lua` | istemci sayfalama (`pagination` bileşeni), komut mesajı, (opsiyonel) pencereli render |
| `web/js/glue.js` | (opsiyonel) `grid.onScroll(handle, cb)` köprüsü |
| `web/src/views/settings.lua` | "Sonuç sayfa boyutu" ayarı (`result_page_size`) |
| `web/spec/result_grid_spec.lua` | sayfa hesapları, komut mesajı |

## Dışa Aktarma Diyaloğu (hata düzeltmesi)

**Belirti:** Format `Excel` veya `JSON` seçilince "Ayraç (yalnızca CSV)" ve "Başlık satırı" alanları görünmeye devam ediyordu.

**Kök neden:** `csv_dialog.open` içeriği statik vnode olarak veriyordu; `select#export-format` için `onchange` yoktu;
hiçbir alan seçili formata bakmıyordu (`csv_dialog.lua:16-30` eski hali).

**Sunucunun gerçekten kullandığı alanlar** (`api/src/db/target/csv.lua:51-59`, `xlsx.lua:72-85`, `to_json`):

| Alan | CSV | XLSX | JSON |
|---|---|---|---|
| `delimiter` | kullanılır | yok sayılır | yok sayılır |
| `include_header` | kullanılır | kullanılır | yok sayılır |
| `limit` | kullanılır | kullanılır | kullanılır |

**Düzeltme (uygulandı):**

```lua
function csv_dialog.fields(format)
  return { delimiter = format == "csv", header = format ~= "json" }
end
-- open(): local fmt = last.format; content = function() ... end  (modal.show her render'da çağırır)
-- select#export-format onchange = function(e) fmt = e.value or fmt; require("app").schedule_render() end
-- ayraç etiketi f.delimiter, başlık satırı f.header koşuluyla render edilir; gizli alan gönderim sırasında
-- dom.value → nil olur ve mevcut varsayılanlara (",", false) düşer; sunucu zaten yok saydığı için yan etki yok.
```

Test (`web/spec/csv_dialog_spec.lua`): `fields("csv")` → `{delimiter=true, header=true}`, `fields("xlsx")` →
`{false, true}`, `fields("json")` → `{false, false}`. E2E `query.spec.ts:36` ayracı format CSV iken seçtiği için değişmez.

## Sonuç Grid'i: Sayfalama

Mevcut grid tek `<table>` (`result_grid.lua`), 1000 satırda yeterli; 50.000 satırda ("Tümünü getir", F27) DOM 50k×N hücre
olur. Önce en ucuz çözüm: **istemci tarafı sayfalama**, `components/pagination.lua` yeniden kullanılır
(bugün yalnız `table_browser.lua:11` kullanıyor).

- Durum: `grid.page` (1 tabanlı), `grid.page_size` (`storage` `result_page_size`, varsayılan 100, seçenekler 50/100/500/1000).
- Sonuç değişince `page = 1`. Sayfa hesapları saf: `page_slice(rows, page, size)` → `first, last`; `page_count(n, size)`.
- Durum satırı: `1–100 / 4.312 satır · 12.4 ms` + pagination kontrolü (mevcut bileşen: ilk/önceki/sonraki/son).
- Sağ tık "Tümünü kopyala" ve dışa aktarma **tüm** satırları kapsar (sayfa değil).
- Sıralama yok (sunucu sonucu sırası korunur); spec istemiyor.

## Sonuç Grid'i: Virtual Scrolling (opsiyonel, ölçüme bağlı)

Sayfalama 50.000 satırı 500'lük sayfada zaten akıcı yapar. Yine de spec "virtual scrolling" istiyor; şu durumda eklenir:
sayfalama açıkken 1000 satırlık sayfa render'ı > 100 ms (Chrome Performance ile ölçülür).

- `glue.js`: `grid.onScroll(handle, cb)` → `scrollTop`, `clientHeight` ile `cb(first, last)`; `rowHeight` sabit 28 px
  (`--row-h` CSS değişkeni); dinleyici `requestAnimationFrame` ile birleştirilir.
- `result_grid` yalnız `[first-20, last+20]` aralığını render eder; üst/alt `div` spacer `height = n*rowHeight`.
- `dom.lua` keyed diff satır anahtarı `row index` → yalnız pencere farkı patch'lenir.
- Sayfalama ve virtual scroll birlikte: sayfa boyutu "Tümü" seçilince virtual, aksi halde sayfa.

## DML/DDL Geri Bildirimi

`query_result.command` (ör. `INSERT`, `UPDATE`, `CREATE TABLE`, `ALTER TABLE`) + `row_count`:

| command | mesaj |
|---|---|
| INSERT/UPDATE/DELETE | `UPDATE: 3 satır etkilendi` |
| CREATE/ALTER/DROP/TRUNCATE/… | `CREATE TABLE tamamlandı` |
| SELECT (0 satır) | `Sorgu satır döndürmedi` (mevcut) |

`result_grid.command_message(command, row_count)` saf fonksiyon; ikon `check` yeşil; süre yanında.

## Test

- `web/spec/csv_dialog_spec.lua` (mevcut, 3 senaryo).
- `web/spec/result_grid_spec.lua`: `page_count(4312, 100)` = 44; `page_slice(rows, 44, 100)` → 4301–4312;
  `command_message("INSERT", 3)` → `"INSERT: 3 satır etkilendi"`; `("CREATE TABLE", 0)` → `"CREATE TABLE tamamlandı"`.
- e2e `query.spec.ts`: `generate_series(1, 2500)` → durum satırı `1–100 / 2.500`, son sayfa 2401–2500; sayfa boyutu 500'e
  geçince 5 sayfa; export XLSX diyaloğunda "Ayraç" **görünmez**, JSON'da "Başlık satırı" **görünmez**.

## DoD

- [x] Export diyaloğu: CSV'de ayraç+başlık, XLSX'te yalnız başlık, JSON'da ikisi de yok; `make test.web` yeşil.
- [ ] 2.500 satırlık sonuçta sayfalama kontrolü; sayfa boyutu ayarı Settings'te ve kalıcı.
- [ ] "Tümünü kopyala"/dışa aktar tüm satırları kapsar.
- [ ] DML sonrası `INSERT: N satır etkilendi`, DDL sonrası `… tamamlandı`.
- [ ] (opsiyonel) 50.000 satırda kaydırma 60 fps'e yakın; DOM'daki `tr` sayısı ≤ 100.
- [ ] `make lint && make test.web`, e2e `query.spec.ts` yeşil.
