# ═══ FAZ 20 — FRONTEND VIEWS III (ADMIN) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — RBAC §7, audit §8.

## Amaç

Admin düzlemi: kullanıcı yönetimi, RBAC matris, denetim logları, ayarlar.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/src/views/users.lua` | kullanıcı liste/form/sil |
| `web/src/views/rbac.lua` | matris tablosu, tek hücre patch, toplu put, reset |
| `web/src/views/audit.lua` | log liste, filtre, detay modal, stats, export |
| `web/src/views/settings.lua` | tema, per_page, row_limit varsayılan |

## Users View (`#/users`, `users.list`)

- `GET /users?search=&role=&is_active=` → tablo: avatar, email, full_name, role badge, is_active, last_login, actions.
- Yeni kullanıcı modal: email, full_name, password (generate button → `js.random_password`), role select, is_active toggle.
- Düzenle: password boş → dokunma.
- Sil: `DELETE /users/:id` → `USER_REMOVED`; son admin → `LAST_ADMIN` toast.
- Arama debounce 300ms.

## RBAC View (`#/rbac`, `rbac.matrix`)

- `GET /rbac/pages` → kolon başlıkları (label), `GET /rbac/matrix` → hücreler.
- Matris: satır `role` (admin/editor), sütun `page_key` (16 kolon, gruplu header: genel/connections/query/browse/admin).
- Hücre checkbox: `PATCH /rbac/matrix/:role/:page_key {can_access}` → optimistic toggle → `RBAC_CELL_TOGGLED` → success `CONFIRMED` / failure `ROLLBACK`.
- Toplu: `PUT /rbac/matrix` (tüm matris) → `RBAC_MATRIX_REPLACED`.
- `Reset` → `POST /rbac/matrix/reset` → `types.default_matrix()` → confirm.
- Locked hücre (`admin+rbac.matrix`) disabled + kilit ikonu.

## Audit View (`#/audit`, `audit.logs`)

- Filtre bar: `action` select (AUDIT_ACTIONS), `entity_type`, `user_id` (users select), `from`/`to` datetime-local, `search` text.
- `GET /audit/logs?page&per_page&action...` → tablo: `created_at | user | action | entity | status (success/failure badge) | ip`.
- Satır tık → modal detay: `old_value`/`new_value` JSON pretty, `error_message` kırmızı, `request_id` kopyala.
- Stats: üstte 3 kart `by_action` (bar), `by_user`, `by_day` (mini chart div).
- Export: `GET /audit/export?from&to&action...` → `js.http.download` → `audit.csv`.

## Settings View (`#/settings`)

- Tema: light/dark/system (system → `matchMedia` listener).
- Tablo varsayılan `per_page` (100), sorgu `row_limit` default (1000).
- "Versiyon" footer: `APP_VERSION` (boot.js config).

## DoD

- [ ] Admin `#/users` → liste, yeni user `editor` → `201`, duplicate → `EMAIL_TAKEN` toast.
- [ ] Son admin sil → `LAST_ADMIN` 409.
- [ ] RBAC matris editor `object.actions` toggle → `PATCH` → sayfa yenile `editor` artık truncate butonunu göremez.
- [ ] Locked hücre tıklanamaz.
- [ ] Audit filtre `action=connection.create` → yalnızca o eylemler.
- [ ] Audit detay maskeli `password: ***`.
- [ ] Audit export → `audit.csv` indirilir.
