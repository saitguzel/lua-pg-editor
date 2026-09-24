# ═══ FAZ 18 — FRONTEND VIEWS I (BAĞLANTILAR & SORGU EDİTÖRÜ) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — page keys §7.

## Amaç

Çekirdek kullanıcı yolculuğu: login → bağlantı listesi/CRUD → çok sekmeli SQL editörü + şema sidebar + sonuç tablosu + geçmiş.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/src/views/login.lua` | login, forgot, reset |
| `web/src/views/connections.lua` | liste, form, test, sil |
| `web/src/views/query_editor.lua` | tab bar, CodeMirror, run/cancel, result grid, export csv |
| `web/src/views/schema_sidebar.lua` | veritabanı seçici, şema → tablo/view ağacı |
| `web/src/views/query_history.lua` | geçmiş liste, yeniden çalıştır, kopyala |
| `web/src/components/result_grid.lua` | tablo render, pagination, copy cell |
| `web/src/components/toast.lua` | toast queue |

## Login View

- Form: email, password, `validation.schemas.login` (frontend aynı kurallar).
- `POST /auth/login` → storage `access_token`/`refresh_token` → `LOGIN_SUCCEEDED` → `#/connections`.
- `Forgot password` → `POST /auth/forgot-password` → `202` toast "E-posta gönderildiyse …".
- Demo hesap banner (dev: `admin@pgeditor.local / Admin123!`), prod'da yok.

## Connections View

- `GET /connections` → liste: kartlar (name, host:port/database, user, has_password rozeti, last_test badge).
- Yeni/Düzenle modal: `validation.schemas.connection_create` + `host/port` type-aware, SSH accordion (collapsed default).
- Test butonu: `POST /connections/:id/test` → spinner → `latency_ms` toast.
- Sil: confirm dialog → `DELETE /connections/:id`.
- Arama: `?search` (frontend filters, server ILIKE).

## Query Editor (ana)

Çok sekmeli: `query.tabs = [{ id, title="Sorgu 1", sql="SELECT ...", result=nil, status="idle", connection_id, database }]`

- Sidebar: `schema_sidebar.lua` → `GET /connections/:id/schemas` → ağaç. Tablo adını tıklayınca editöre `SELECT * FROM "schema"."table" LIMIT 100;` insert.
- Editor: `editor.create(container, { value=tab.sql, schema=catalog })`. `Ctrl-Enter` → `RUN_REQUESTED`.
- `POST /query/execute { connection_id, database, sql, row_limit }` → `result = { columns, rows, row_count, truncated, duration_ms }`.
- Result grid: header + `rows` (limit 1000, truncated uyarısı). Hücre çift tık → modal detail (JSON pretty).
- Sekme bar: `+` yeni, `x` kapat, `title` düzenlenebilir.
- Row limit select: 100/1000/5000/50000.
- Export CSV: `POST /query/csv` → `js.http.download` → `export.csv`.
- Hata: `QUERY_FAILED` → `details.db_message` kod blokta (`sqlstate` rozeti).

## Query History

- `GET /query/history?connection_id=&database=` → liste (sql preview 80ch, duration, truncated rozeti).
- "Yeniden çalıştır" → editöre sql'i yükle.
- "Kopyala" → `js.clipboard(sql)`.

## Desen

Her view:

```lua
local _M={}
function _M.render(state, dispatch)
  -- state.connections.status → loading/skeleton, error/empty, ready/list
  -- form validation → inline errors
  -- optimistic: test butonu pending
end
function _M.mounted(dispatch) -- ROute_changed sonrası veri çek
  fetch.get("/connections", ...):next(function(res) dispatch({type="CONNECTIONS_LOADED", items=res.data}) end)
end
return _M
```

## DoD

- [ ] Login doğru → `#/connections`, yanlış → `INVALID_CREDENTIALS` toast.
- [ ] Yeni bağlantı → liste anında, test → latency toast.
- [ ] Şema sidebar public → customers/orders görünür.
- [ ] Editörde `cust` yazınca completion `customers` önerir.
- [ ] `SELECT * FROM customers` Run → grid 8 satır, `duration_ms` footer.
- [ ] Hatalı SQL → `QUERY_FAILED` kırmızı blok.
- [ ] Geçmişte son sorgu en üstte, "Yeniden çalıştır" çalışır.
