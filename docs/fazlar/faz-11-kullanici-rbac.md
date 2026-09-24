# ═══ FAZ 11 — KULLANICI & RBAC ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — sayfa anahtarları §7, audit §8, shared dict §9.

## Amaç

Yönetim düzlemi: kullanıcı CRUD (admin), profil/me, ve sayfa bazlı yetki matrisi (editor/admin). RBAC matrisi `PAGES` tanımına göre genişletildi.

## Önkoşullar

- F2 (users, rbac_permissions), F3 (router), F4 (random), F5 (auth).

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/users.lua` | list, get, create, update, delete, me extras |
| `api/src/handlers/rbac.lua` | list_pages, get_matrix, put_matrix, patch_cell |
| `api/src/services/user_service.lua` | create, update, delete, list, last_admin guard |
| `api/src/services/rbac_service.lua` | can, matrix, update_matrix, cache invalidate |
| `api/src/repositories/user_repo.lua` | (F5'te) + list, count_active_admins |
| `api/src/repositories/rbac_repo.lua` | find_all, upsert, bulk_upsert |
| `api/src/models/user.lua` | serialize (public), from_row |

## Endpointler

| Metod | Path | Page | Açıklama |
|---|---|---|---|
| `GET` | `/users` | `users.list` | Liste `?page&per_page&search&role&is_active` |
| `GET` | `/users/:id` | `users.list` | Tek kullanıcı |
| `POST` | `/users` | `users.create` | Yarat `{email,password,full_name,role,is_active}` |
| `PUT` | `/users/:id` | `users.create` | Tam güncelle |
| `PATCH` | `/users/:id` | `users.create` | Kısmi (password optional) |
| `DELETE` | `/users/:id` | `users.create` | Sil (soft değil, hard) |
| `GET` | `/rbac/pages` | `rbac.matrix` | Tüm sayfa meta listesi |
| `GET` | `/rbac/matrix` | `rbac.matrix` | Matris `{ permissions: [{role,page_key,can_access}] }` |
| `PUT` | `/rbac/matrix` | `rbac.matrix` | Tam matris replace |
| `PATCH` | `/rbac/matrix/:role/:page_key` | `rbac.matrix` | Tek hücre ` { can_access }` |
| `POST` | `/rbac/matrix/reset` | `rbac.matrix` | Varsayılana sıfırla |

`page_key` paramı `pg_shared.types.PAGE_SET` içinde olmalı; `role` `ROLE_SET`.

## Business Rules

- `LAST_ADMIN`: `users.role=admin AND is_active=true` sayısı 1 ise → son admin silinemez, pasifleştirilemez, role düşürülemez → `409 LAST_ADMIN`.
- `SELF_ACTION_FORBIDDEN`: `identity.user_id == target_id` → kendini silemez, kendi rolünü `admin→editor` düşüremez → `409`.
- `LOCKED`: `rbac.matrix` admin satırı `false` yapılamaz → `409 CONFLICT`.
- `EMAIL_TAKEN`: unique ihlali → `409`.
- Password: `argon2.hash` → sakla; `password` boşsa dokunma.
- `PUT /rbac/matrix` → tüm `ROLES × PAGES` kombinasyonları gönderilmeli; eksik → `VALIDATION_FAILED`.
- `PATCH /rbac/matrix/:role/:page_key` → tek hücre optimistic; `can_access` boolean.

## Handler Öz

```lua
local function create_user(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.user_create, body); if not clean then return errors.respond(errors.validation(v)) end
  local user, e = user_service.create(clean); if not user then return errors.respond(e) end
  return { status=201, json={ data=user } }
end
local function put_matrix(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.rbac_matrix, body); if not clean then return errors.respond(errors.validation(v)) end
  local mat, e = rbac_service.update_matrix(ngx.ctx.identity, clean); if not mat then return errors.respond(e) end
  return { status=200, json={ data=mat } }
end
```

## Service & Cache

`rbac_service.can(role, page_key)`:

```lua
local key="rbac:"..role
local cached = ngx.shared.rbac_cache:get(key)
if cached then return cjson.decode(cached)[page_key] end
local rows = rbac_repo.find_by_role(role) -- DB
local map = {}; for _,r in ipairs(rows) do map[r.page_key]=r.can_access end
ngx.shared.rbac_cache:set(key, cjson.encode(map), RBAC_CACHE_TTL)
return map[page_key]
```

`update_matrix` → `with_transaction` içinde `rbac_repo.bulk_upsert` + `rbac_cache:delete` her role için + audit `rbac.matrix.update` (old/new diff).

## DoD

- [ ] `GET /users` editor → `403 FORBIDDEN`.
- [ ] Admin `POST /users` → `201`, duplicate email → `409 EMAIL_TAKEN`.
- [ ] Son admin silme → `409 LAST_ADMIN`.
- [ ] Admin kendi rolünü düşürme → `409 SELF_ACTION_FORBIDDEN`.
- [ ] `GET /rbac/matrix` → 2×PAGES satır, `PUT` → değişir, `PATCH /rbac/matrix/editor/object.actions` → `200`.
- [ ] `PUT` admin rbac.matrix false → `409 CONFLICT`.
- [ ] RBAC değişince `rbac_cache` invalid, sonraki `can()` DB'den.
