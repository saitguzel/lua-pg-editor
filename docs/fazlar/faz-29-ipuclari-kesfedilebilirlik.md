# ═══ FAZ 29 — İPUÇLARI & KEŞFEDİLEBİLİRLİK ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — F21 klavye/a11y/toast; `shortcuts.lua` scope kayıtları.
> Analiz: [faz-24](faz-24-spec-analizi-bosluk-haritasi.md) §UI/UX.

## Amaç

Uygulamada var olan ama **görünmeyen** özellikleri (sağ tık menüleri, çift tık, Esc iptal, Tab tamamlama, splitter ok
tuşları, `g` dizileri, Ctrl+K, tek tuş kısayolları) kullanıcıya duyurmak; yardımı tek tuşa değil görünür bir butona bağlamak.

## Önkoşullar

- F21 (shortcuts registry, `?` yardım modalı), F27/F28 (yeni kısayollar ve grid davranışları listeye girer).

## Envanter: bugün duyurulmayan özellikler

| Özellik | Nerede | Kanıt |
|---|---|---|
| `?` yardım modalı | yalnız klavye ile | `web/src/components/modal.lua:162-188`, görünür buton yok |
| Sağ tık menüleri | sidebar nesnesi, grid hücresi, sekme, tablo satırı, yapı satırı | `schema_sidebar.lua:102,121`, `result_grid.lua:171`, `query_editor.lua:475`, `table_browser.lua:285`, `structure.lua:134` |
| Çift tık | grid hücre görüntüleyici, tarayıcıda hücre düzenleme | `result_grid.lua:170`, `table_browser.lua:281` |
| Esc | çalışan sorguyu iptal | `keyboard.lua:56` |
| Tab | tamamlamayı kabul / 4 boşluk | `glue.js:412` |
| Splitter | sürükle + ok tuşları (16 px) | `glue.js:135-181` |
| `g d` / `g c` / `g q` | sayfa geçişleri | `keyboard.lua:44-46` |
| `Ctrl+K` | palet (yalnız bağlantı/tablo arar; komut yok) | `command_palette.lua:15-54` |
| Tek tuş kısayollarını kapatma | Profil sayfası | `profile.lua:59-67` |
| Sidebar gizle / rail | Ctrl+B, bağlantı başına gizleme | `layout.lua:49-55`, `schema_sidebar.lua:183-198` |
| Alt+L temizle + Ctrl+Z geri al | editör | `keyboard.lua:66` |

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `web/src/views/layout.lua` | header'a `?` **Yardım** butonu (`title="Yardım ve kısayollar (?)"`) |
| `web/src/components/modal.lua` | yardım modalı: scope'a göre gruplu tablo + "Gizli özellikler" bölümü |
| `web/src/shortcuts.lua` | `register` → `scope_label`; `list()` gruplu döner |
| `web/src/keyboard.lua` | açıklamalar tutarlı Türkçe; F27 kısayolları |
| `web/src/tips.lua` (**yeni**) | `TIPS` statik listesi (`snippets_builtin` gibi) + `next_tip(seen)` |
| `web/src/views/dashboard.lua` | kapatılabilir "İpucu" kartı |
| `web/src/components/command_palette.lua` | `kind="command"` öğeleri |
| `web/src/views/profile.lua` | statik kısayol tablosu `shortcuts.list()`'ten türetilir |
| `web/src/views/query_editor.lua`, `result_grid.lua`, `schema_sidebar.lua` | tooltip'lere kısayol ekleri, boş durum metinlerinde ipucu |
| `web/spec/tips_spec.lua`, `web/spec/shortcuts_spec.lua` | testler |

## Yardım Butonu ve Modal

- Header'da tema düğmesinin solunda `icons.button{icon="help-circle", label="Yardım"}`; tıklayınca mevcut yardım modalı.
- Modal içeriği:
  1. **Kısayollar** — scope'a göre gruplu: Genel / Sorgu editörü / Editör içi (CodeMirror) / Tablo tarayıcı / Yapı.
     `shortcuts.list()` `{ scope, label, key, description }` döner; scope etiketleri `SCOPE_LABEL = { global="Genel", query="Sorgu", browse="Tablo tarayıcı", structure="Yapı", editor="Editör içi" }`.
     CodeMirror kısayolları (`Mod-Enter`, `Mod-Shift-Enter`, `Mod-i`, `Tab`) registry'de `scope="editor"` ile **yalnız listeleme için** kayıtlıdır (`noop=true`).
  2. **Gizli özellikler** — statik liste (aşağıdaki `TIPS`'ten `where="help"` olanlar).
  3. Alt not: "Tek tuş kısayollarını Profil'den kapatabilirsiniz."
- Açıklamalar tek biçim: Türkçe, karakter kaçışsız (mevcut "Kisayol yardimi (? -> yardim)" gibi ASCII metinler düzeltilir).

## İpucu Kartı (Dashboard)

```lua
-- web/src/tips.lua
return {
  { id = "ctx-sidebar",  where = { "help", "dash" }, text = "Nesne gezgininde bir nesneye sağ tıklayın: SELECT, CREATE script, yeniden adlandır, drop." },
  { id = "ctx-grid",     where = { "help", "dash" }, text = "Sonuç hücresine sağ tık: hücre/satır/kolon/tümünü TSV kopyalar; çift tık tam içeriği açar." },
  { id = "esc-cancel",   where = { "help", "dash" }, text = "Uzun süren sorguyu Esc ile iptal edin (pg_cancel_backend)." },
  { id = "run-sel",      where = { "help", "dash" }, text = "Sadece seçili SQL'i Ctrl+Shift+Enter ile çalıştırın." },
  { id = "tab-complete", where = { "help" },         text = "Tab tamamlamayı kabul eder; öneri yoksa 4 boşluk ekler." },
  { id = "splitter",     where = { "help" },         text = "Panel ayırıcılarını sürükleyin ya da odaklayıp ok tuşlarıyla 16 px adımlarla taşıyın." },
  { id = "g-seq",        where = { "help", "dash" }, text = "g d / g c / g q: Dashboard, Bağlantılar, Sorgu sayfalarına atlayın." },
  { id = "palette",      where = { "help", "dash" }, text = "Ctrl+K paletinden bağlantı, tablo ve komutlara ulaşın." },
  { id = "tab-rename",   where = { "help", "dash" }, text = "Sekme başlığına çift tıklayarak yeniden adlandırın." },
  { id = "dblclick-edit",where = { "help", "browse" },text = "Tablo tarayıcıda hücreye çift tık düzenler; Delete odaklı satırı siler." },
  { id = "sidebar-hide", where = { "help" },         text = "Ctrl+B kenar çubuğunu daraltır; nesne panelini bağlantı başına gizleyebilirsiniz." },
  { id = "clear-undo",   where = { "help" },         text = "Alt+L ekranı temizler, Ctrl+Z geri alır." },
}
```

- Dashboard kartı: `next_tip(seen)` görülmemiş ilk ipucunu seçer; "Sonraki" ve "Kapat" (`storage` `tips.seen[]`, `tips.dismissed`).
- Boş durum metinleri ipucu taşır: sonuç paneli "Ctrl+Enter ile çalıştır · Ctrl+Shift+Enter seçimi çalıştırır";
  nesne gezgini boş şema "Sağ tık ile yenileyin"; tablo tarayıcı "Çift tık düzenler".

## Tooltip'ler

Her toolbar butonunda kısayol: Çalıştır `(Ctrl+Enter)`, Seçimi çalıştır `(Ctrl+Shift+Enter)`, Yeni sekme `(Alt+N)`,
Temizle `(Alt+L)`, Taslaklar `(Ctrl+J · Alt+S)`, AI `(Ctrl+I)`, Formatla `(Ctrl+Shift+F)`, Dışa aktar, Yenile `(F5)`,
Ara `(Ctrl+F)`, Tema (`title="Tema: açık/koyu/sistem"` — bugün yok, `layout.lua:68-87`).

## Command Palette Komutları

`command_palette.lua` liste kaynağına `kind="command"`:
`Yeni sekme`, `Seçimi çalıştır`, `Formatla`, `Dışa aktar…`, `Tema: açık/koyu/sistem`, `Yardım`, `Nesne gezginini yenile`,
`Kenar çubuğunu daralt`. Her komut mevcut `shortcuts` eylemini çağırır (tekrar yazılmaz); footer metni korunur.

## Test

- `web/spec/tips_spec.lua`: `next_tip({})` ilk ipucu; `next_tip({all})` → nil; `where` filtresi.
- `web/spec/shortcuts_spec.lua`: `list()` gruplu; `noop` kayıt tetiklenmez; scope etiketi var.
- e2e `keyboard.spec.ts`: header "Yardım" butonu modalı açar; modalda "Gizli özellikler" başlığı; palette'te "Formatla"
  komutu; dashboard ipucu kartı "Kapat" sonrası yenilemede görünmez.
- a11y (`a11y.spec.ts`): yeni buton/kart axe ihlali üretmez.

## DoD

- [ ] Header'da görünür Yardım butonu; modal scope'a göre gruplu, tüm kayıtlı kısayollar listede (Profil ile aynı kaynak).
- [ ] "Gizli özellikler" bölümü envanterdeki 11 maddeyi kapsar.
- [ ] Dashboard ipucu kartı döner, kapatılınca kalıcı olarak gizlenir.
- [ ] Toolbar tooltip'lerinde kısayollar; tema düğmesinin `title`'ı var.
- [ ] Ctrl+K paletinde en az 6 komut.
- [ ] `make test.web`, `keyboard.spec.ts`, `a11y.spec.ts` yeşil.
