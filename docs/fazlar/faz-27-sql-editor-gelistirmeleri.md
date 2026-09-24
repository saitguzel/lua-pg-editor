# ═══ FAZ 27 — SQL EDİTÖR GELİŞTİRMELERİ ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — error §5 (`QUERY_FAILED`, `BAD_REQUEST`), env §6 (`QUERY_ROW_LIMIT_MAX`), klavye F21.
> Analiz: [faz-24](faz-24-spec-analizi-bosluk-haritasi.md) §SQL Editörü, §Sorgu Çalıştırma.

## Amaç

Spec §3–§4'ün editör tarafındaki eksiklerini kapatmak: `Ctrl+Shift+Enter`, sekme yeniden adlandırma, yıkıcı komut onayı,
hata pozisyonu, geçmişten tek tıkla çalıştırma, "tümünü getir", isteğe bağlı SQL formatlama.

## Önkoşullar

- F8 (query_service, sql_parser), F18 (query_editor, editor köprüsü), F21 (shortcuts).
- F25'ten bağımsız; F26 ile paralel yürütülebilir.

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `web/js/glue.js` | `Mod-Shift-Enter` keymap; `editor.highlightError(line)`; (isteğe bağlı) `sql-formatter` dinamik chunk |
| `web/src/editor.lua` | `run_selection`, `highlight_error`, `format` köprüleri |
| `web/src/keyboard.lua` | `Ctrl+Shift+Enter`, `Ctrl+Shift+F` kayıtları |
| `web/src/views/query_editor.lua` | sekme başlığı düzenleme, yıkıcı onay akışı, hata satırı, "tümünü getir" |
| `web/src/views/query_history.lua` | satırda "Çalıştır" |
| `shared/src/sql_guard.lua` (**yeni**) | `destructive_kind(sql)` — istemci + sunucu ortak |
| `api/src/db/pool_manager.lua` | `parse_error` → `position` |
| `api/src/db/target/query.lua` | `details.position`, `details.line`, `details.column` |
| `shared/spec/sql_guard_spec.lua`, `web/spec/query_editor_spec.lua`, `api/spec/query_error_spec.lua` | testler |

## Kısayollar

| Kısayol | Eylem | Yer |
|---|---|---|
| `Ctrl+Enter` | Seçim varsa seçimi, yoksa tüm sekmeyi çalıştır (**mevcut**, korunur) | `glue.js:407`, `keyboard.lua:29-53` |
| `Ctrl+Shift+Enter` | **Yalnız seçimi** çalıştır; seçim yoksa `toast("info","Önce bir SQL parçası seçin")` | yeni |
| `Ctrl+Shift+F` | Formatla (isteğe bağlı görev) | yeni |
| Çift tık sekme başlığı / sağ tık "Yeniden adlandır" | Sekme adı düzenleme | yeni |

`glue.js` keymap'e `{ key: "Mod-Shift-Enter", run: () => bridge("run_selection") }` **`Mod-Enter`'dan önce** eklenir
(CodeMirror ilk eşleşeni çalıştırır). `keyboard.lua`'da textarea fallback için aynı kayıt.

## Sekme Yeniden Adlandırma

- `tab.title` (string|nil). `auto_title(sql)` yalnız `title == nil` iken kullanılır (`query_editor.lua:39-49`).
- Çift tık → `modal.prompt({ title="Sekmeyi yeniden adlandır", value=current, validate=len≤40 })`; boş → `title=nil` (otomatik başlığa dön).
- Oturum kaydı `pg.query_session` şemasına `title` eklenir (geri uyumlu; eski kayıtlar `nil`).
- Sağ tık menüsü (`query_editor.lua:416-427`): "Yeniden adlandır" ilk öğe.

## Yıkıcı Komut Onayı

`shared/src/sql_guard.lua` (LuaJIT + Lua 5.4; bağımlılığı yok):

```lua
local _M = {}
-- literal/yorumları soyar (api sql_parser.strip_comments ile aynı kurallar; shared'a taşınır)
-- döner: nil | { kind = "DROP"|"TRUNCATE"|"DELETE"|"ALTER_DROP", statement = "<ilk 80 kr>" }
function _M.destructive_kind(sql)
  for _, stmt in ipairs(_M.statements(sql)) do
    local head = stmt:upper():gsub("^%s+", "")
    if head:match("^DROP%s") then return { kind = "DROP", statement = stmt } end
    if head:match("^TRUNCATE%s") then return { kind = "TRUNCATE", statement = stmt } end
    if head:match("^DELETE%s") and not head:match("%sWHERE%s") then return { kind = "DELETE", statement = stmt } end
    if head:match("^ALTER%s.*%sDROP%s") then return { kind = "ALTER_DROP", statement = stmt } end
  end
end
return _M
```

Karar: `DELETE … WHERE` onay **istemez** (spec "DELETE gibi yıkıcı" — WHERE'siz DELETE yıkıcıdır; WHERE'li olan olağan DML).
Ekipçe "her DELETE" isteniyorsa `WHERE` koşulu kaldırılır (tek satır).

Akış (`query_editor.lua run()`): `sql_guard.destructive_kind(sql_to_run)` → varsa
`modal.confirm({ title="Yıkıcı sorgu", message=kind .. " içeriyor:\n" .. statement, confirm_label="Çalıştır", danger=true })`
→ hayır ise iptal. Onay penceresi coroutine ile bekler (mevcut `modal.confirm`).
Sunucu tarafı zorlamaz (spec: frontend modal); `sql_parser.strip_comments` `shared`'a taşındığı için api tarafı `pg_shared.sql_guard`'ı require eder (tek kopya).

## Hata Pozisyonu

- `pool_manager.parse_error` (satır 33-38): pgmoon `data.position` alanı `position = tonumber(data.position)` olarak taşınır.
- `db/target/query.lua` hata eşlemesi: `details = { sqlstate, db_message, position, line, column }`; `line/column`
  gönderilen SQL üzerinde `position`'dan hesaplanır (1 tabanlı, `\n` sayımı).
- Grid hata kutusu (`result_grid.lua:104-113`): rozet `42601 · satır 3, sütun 12`; tıklayınca `editor.highlight_error(line)`.
- `glue.js`: `highlightError(line)` → `EditorView.decorations` ile `cm-error-line` sınıfı (1 kez, sonraki düzenlemede kalkar).
- Çoklu statement'ta pozisyon **son** statement'a göredir (mevcut "yalnız son sonuç" davranışı; DoD'a not).

## Geçmişten Çalıştır

`query_history.lua` satır eylemleri: "Uygula" (mevcut) + **"Çalıştır"** (`icons.button{icon="play"}`): SQL'i aktif sekmeye
yükler ve `run()` çağırır; yıkıcı onay akışı aynen uygulanır. Popover kapanır.

## "Tümünü Getir"

`result_grid` durum satırındaki "satır limitine ulaşıldı" rozetinin yanına buton: **"Tümünü getir (maks 50.000)"** →
`row_limit = QUERY_ROW_LIMIT_MAX` (istemcide `config` köprüsünden okunur; yoksa 50000) ile aynı SQL yeniden çalıştırılır.
Tavan üstü için toast: "Sunucu limiti 50.000; daha fazlası için CSV dışa aktarın (akış)". Bu, spec'in "tümünü getir"
seçeneğinin bellek-güvenli karşılığıdır (00 §11 madde 23).

## SQL Formatlama (isteğe bağlı)

- `web/package.json` → `sql-formatter` (yalnız bu görevde yeni bağımlılık). `glue.js`'de `import("sql-formatter")` dinamik
  chunk (canvas-confetti gibi, `build-wasm.sh:47-48`), `language: "postgresql"`, `keywordCase: "upper"`.
- `editor.format()` seçim varsa seçimi, yoksa tümünü değiştirir; tek undo adımı.
- Toolbar butonu `title="Formatla (Ctrl+Shift+F)"`; yükleme başarısızsa buton gizli, toast.
- `make web.size` bütçesi: ana bundle **büyümez** (chunk ayrı).

## Test

- `shared/spec/sql_guard_spec.lua`: `DROP TABLE x` → DROP; `-- drop\nSELECT 1` → nil; `DELETE FROM t` → DELETE;
  `DELETE FROM t WHERE id=1` → nil; `'DROP'` literal → nil; `ALTER TABLE t DROP COLUMN c` → ALTER_DROP; `$$ DROP $$` → nil.
- `web/spec/query_editor_spec.lua`: `auto_title` `title` varsa kullanılmaz; oturum kaydı `title` taşır; `run_selection`
  seçim yokken toast dispatch eder.
- `api/spec/query_error_spec.lua`: `parse_error` `position="15"` → `details.position=15`, `line/column` doğru (`"SELECT 1\nFROM"`).
- e2e `query.spec.ts`: sekme yeniden adlandır → yenilemede korunur; seçim + `Ctrl+Shift+Enter` yalnız seçimi çalıştırır;
  `DROP TABLE` → onay modalı → İptal → çalışmadı; hatalı SQL → rozet `satır N` → editörde vurgulu satır; geçmişte "Çalıştır".

## DoD

- [ ] `Ctrl+Shift+Enter` seçimsizken toast, seçimliyken yalnız seçim çalışır; `Ctrl+Enter` davranışı değişmedi.
- [ ] Sekme adı çift tıkla değişir, `pg.query_session`'da saklanır, boş bırakınca otomatik başlığa döner.
- [ ] `DROP`/`TRUNCATE`/WHERE'siz `DELETE`/`ALTER … DROP` çalıştırmadan önce onay; literal/yorum içindeki kelimeler tetiklemez.
- [ ] Sözdizimi hatasında `details.position` döner; grid `satır:sütun` gösterir; editörde satır vurgulanır.
- [ ] Geçmiş popover'ında "Çalıştır" tek tıkla çalıştırır.
- [ ] "Tümünü getir" 50.000 satıra kadar getirir, üstünde toast.
- [ ] (isteğe bağlı) Formatla çalışır; ana bundle boyutu artmaz.
- [ ] `make test` (shared spec LuaJIT + 5.4), `make test.web`, e2e `query.spec.ts` yeşil.
