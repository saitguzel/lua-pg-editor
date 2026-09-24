# ═══ FAZ 05 — AUTH ENDPOINTLERİ ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — error kodları §5, env §6, audit §8.

## Amaç

Kimlik doğrulama yaşam döngüsü: register/login/refresh/logout/me + parola sıfırlama (forgot/reset) + mail.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/handlers/auth.lua` | 7 handler + read_json_body + validation |
| `api/src/services/auth_service.lua` | login, refresh, logout, me, forgot, reset |
| `api/src/repositories/user_repo.lua` | find_by_email, find_by_id, update_last_login, update_password |
| `api/src/repositories/password_reset_repo.lua` | create, find_by_hash, mark_used, delete_expired |
| `api/src/mail/smtp.lua` | lua-resty-mail ile SMTP gönderim |
| `api/src/middleware/auth.lua` | Bearer doğrulama |
| `api/src/middleware/authorization.lua` | RBAC can() |
| `api/spec/integration/auth_flow_spec.lua` | entegrasyon |

## Endpointler

| Metod | Path | Auth | Page | Açıklama |
|---|---|---|---|---|
| `POST` | `/auth/login` | ❌ | — | email+password → access+refresh |
| `POST` | `/auth/refresh` | ❌ | — | refresh_token → yeni access+refresh (rotation) |
| `POST` | `/auth/logout` | ✅ | — | access jti denylist, refresh de |
| `GET` | `/auth/me` | ✅ | — | `{ user, permissions }` |
| `POST` | `/auth/forgot-password` | ❌ | — | email → token oluştur, mail at, hep `202` |
| `POST` | `/auth/reset-password` | ❌ | — | token+new_password → 204 |
| `GET` | `/auth/verify-reset-token` | ❌ | — | token valid mi? (frontend ön kontrol) |

Rate limit: `POST /auth/login` ve `forgot-password` → `rate_limit` dict `5/dk` IP+email. Aşınca `429` + `Retry-After`.

## Handler Taslağı (auth.lua)

```lua
local errors = require("middleware.error_handler")
local validation = require("pg_shared.validation")
local auth_service = require("services.auth_service")
local function login(self)
  local body, err = errors.read_json_body(); if not body then return errors.respond(err) end
  local clean, v_err = validation.validate(validation.schemas.login, body); if not clean then return errors.respond(errors.validation(v_err)) end
  local tokens, svc_err = auth_service.login(clean.email, clean.password, ngx.ctx.audit.ip)
  if not tokens then return errors.respond(svc_err) end
  return { status=200, json={ data=tokens } }
end
-- refresh: body.refresh_token → jwt.verify(refresh) → jti denylist check → new pair
-- logout: header token jti → denylist (TTL = kalan ömür)
-- me: ngx.ctx.identity → user_repo.find_by_id + rbac_service.permissions(role)
-- forgot: her durumda 202, mail hatası → log, audit `auth.password.reset.request` failure status
-- reset: token sha256 → repo find → expiry → argon2 hash → user_repo.update_password → mark_used → audit success
```

Validation şemaları (pg_shared):
- `login`: `email`, `password` (min1)
- `refresh`: `refresh_token` string 1..4096
- `forgot_password`: `email`
- `reset_password`: `token` 64 hex, `new_password` password()

## Service Detayı (auth_service.lua)

- `login(email, password, ip)`:
  1. rate_limit check → `RATE_LIMITED` + `Retry-After: 60`
  2. `user_repo.find_by_email(lower(email))` → yoksa sleep(100ms) + `INVALID_CREDENTIALS` (timing attack mitigasyon)
  3. `is_active=false` → `ACCOUNT_DISABLED` + audit failure
  4. `password.verify(password, hash)` → false → `INVALID_CREDENTIALS` + audit failure + incr rate_limit
  5. `user_repo.update_last_login`
  6. `jwt.sign_access(user)`, `jwt.sign_refresh(user)`
  7. audit `auth.login.success`, metrics

- `refresh(refresh_token)`:
  1. `jwt.verify(token, "refresh")` → `TOKEN_EXPIRED`/`UNAUTHORIZED`
  2. denylist check → `TOKEN_REVOKED`
  3. `user_repo.find_by_id(payload.user_id)` → is_active
  4. eski jti denylist'e ekle (TTL)
  5. yeni pair üret

- `logout(identity)` → jti denylist (`jwt_denylist` dict `jti:<jti>` →1, TTL kalan ömür)

- `forgot_password(email)`:
  1. kullanıcı var mı bak (yoksa yine 202 — enumeration önleme)
  2. `random.base64url(32)` → token, `sha256_hex(token)` → DB
  3. `expires_at = now + PASSWORD_RESET_TTL`
  4. `mail.smtp.send_password_reset(email, WEB_BASE_URL .. "/#reset?token=" .. token)`
  5. hata → `MAIL_FAILED` log, ama response 202

- `reset_password(token, new_password)`:
  1. `sha256_hex(token)` → repo find → expiry/used check → `RESET_TOKEN_INVALID`
  2. `password.hash(new_password)` → update
  3. `mark_used`

## RBAC Middleware (authorization.lua)

```lua
function _M.requires(page_key)
  return function(self)
    local identity = ngx.ctx.identity
    if not identity then return errors.respond(errors.new("UNAUTHORIZED")) end
    local ok, err = rbac_service.can(identity.role, page_key)
    if not ok then audit_service.record("access.denied", "page", page_key, nil, {page_key=page_key}) return errors.respond(errors.new("FORBIDDEN")) end
  end
end
```

`rbac_service.can` → `jwt_denylist` değil `rbac_cache` dict (`rbac:<role>` JSON). Cache miss → DB `rbac_permissions` → dict'e koy (TTL RBAC_CACHE_TTL).

## DoD

- [ ] `POST /auth/login` doğru → `200` access+refresh, yanlış → `401 INVALID_CREDENTIALS` (email enumeration yok).
- [ ] `GET /auth/me` valid token → `200 {user,permissions}`, expired → `401 TOKEN_EXPIRED` (fetch refresh tetikler).
- [ ] `POST /auth/refresh` rotation → eski refresh `TOKEN_REVOKED`.
- [ ] `POST /auth/logout` → token denylist, sonraki istek `TOKEN_REVOKED`.
- [ ] `POST /auth/forgot-password` hep `202`, mailhog'da mail görülür.
- [ ] `POST /auth/reset-password` token tek kullanımlık, expiry sonrası `RESET_TOKEN_INVALID`.
- [ ] Rate limit 6. istek → `429`.
- [ ] Audit: login success/failure, logout, token.refresh, reset.request/success kayıtlı.
