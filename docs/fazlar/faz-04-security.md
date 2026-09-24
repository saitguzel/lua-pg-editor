# ═══ FAZ 04 — SECURITY ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltme #3, #4, #17.

## Amaç

Kripto primitiflerini izole etmek: JWT (HS256), Argon2id parola hash, kriptografik rasgele, ve bağlantı parolaları için AES-256-GCM.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/security/jwt.lua` | sign_access, sign_refresh, verify, sha256_hex |
| `api/src/security/password.lua` | hash, verify |
| `api/src/security/random.lua` | hex, uuid4, base64url |
| `api/src/security/crypto.lua` | **yeni**: AES-256-GCM encrypt/decrypt (ENCRYPTION_KEY) |
| `api/spec/security_spec.lua` | busted spec |

## security/random.lua

```lua
local resty_random = require("resty.random")
local str = require("resty.string")
function _M.hex(n) return str.to_hex(assert(resty_random.bytes(n, true))) end
function _M.uuid4() -- v4 RFC4122: 16 byte → variant+version
function _M.base64url(n) -- n byte → base64url (reset token)
```

Bağımlılık: `resty.random` + `resty.string`. Test: `is_uuid`, `hex(16)` uzunluk 32, farklı çağrılarda farklı.

## security/jwt.lua

Payload: `{ sub, user_id, email, role, iat, exp, jti, typ="access"|"refresh", iss }`

```lua
local resty_jwt = require("resty.jwt")
local config = require("config")
local random = require("security.random")
local function sign(user, typ, ttl)
  local now=ngx.time()
  local payload={ sub=user.id, user_id=user.id, email=user.email, role=user.role,
    iat=now, exp=now+ttl, jti=random.uuid4(), typ=typ, iss=config.get().jwt.issuer }
  return resty_jwt:sign(config.get().jwt.secret, { header={typ="JWT",alg="HS256"}, payload=payload }), payload
end
function _M.sign_access(user) return sign(user,"access", config.get().jwt.access_ttl) end
function _M.sign_refresh(user) return sign(user,"refresh", config.get().jwt.refresh_ttl) end
function _M.verify(token, expected_typ) -- 4096 byte limit, pcall, alg HS256, iss, exp, jti check
function _M.remaining_ttl(payload) return math.max((payload.exp or 0)-ngx.time(),1) end
function _M.sha256_hex(s) -- resty.sha256
```

Verify hata kodu: `TOKEN_EXPIRED` (expired), diğer → `UNAUTHORIZED`. `expected_typ` mismatch → `UNAUTHORIZED`.

## security/password.lua (Argon2id)

```lua
local argon2 = require("argon2")
local config = require("config")
-- argon2.hash_encoded(pass, t_cost, m_cost, parallelism) → PHC string
-- argon2.verify(hash, pass) → bool
function _M.hash(password) -- t_cost,m_cost,parallelism config.argon2'dan
function _M.verify(password, hash) -- pcall korumalı
```

Not: `argon2` rock'u C binding; worker'ı ~15-100 ms bloklar → login rate limit (00 §9) zorunlu. `m_cost=12` (4 MiB) dev; prod `15` (32 MiB). Hash PHC `$argon2id$v=19$m=4096,t=3,p=1$...` saklanır; `password_hash` kolonu.

## security/crypto.lua (AES-256-GCM) — yeni

Meta DB'de `connections.password_encrypted` → iv:cipher:tag (base64) formatı.

```lua
local aes = require("resty.aes") -- lua-resty-aes veya luaossl
local cjson = require("cjson.safe")
local config = require("config")
local random = require("security.random")
-- ENCRYPTION_KEY: 32 byte ham; config'te base64/hex olabilr → decode
local function get_key() -- 32 byte doğrula
function _M.encrypt(plaintext) -- plaintext "" ise nil döner
-- iv 12 byte, aes_gcm_256_encrypt(key, iv, plaintext) → ct, tag
-- return base64(iv)..":"..base64(ct)..":"..base64(tag)
function _M.decrypt(blob) -- nil → nil; parse, decrypt, tag verify
-- hata → nil, "decrypt failed" (log, istemciye INTERNAL_ERROR)
function _M.reencrypt(old_key, new_key) -- key rotation helper (job)
```

Alternatif implementasyon `luaossl`: `openssl.cipher.new("aes-256-gcm")`. Karar: `luaossl` tercih (OpenResty'de yaygın, AEAD destekler). `resty.aes` yoksa fallback.

Anahtar yönetimi: `ENCRYPTION_KEY` 32 byte; üretimi `openssl rand -base64 32`. Prod secrets `secrets/encryption_key`. `_FILE` desteği.

Güvenlik: `password_encrypted` loglara `***`; `audit` `old_value/new_value`'de maskelenir.

## Middleware Entegrasyonu

- `auth.lua`: `jwt.verify` + denylist (`jwt_denylist` dict) → `ngx.ctx.identity`
- `audit_context.lua`: `X-Forwarded-For` (TRUSTED_PROXIES) gerçek IP.
- `rate_limit`: `login:<ip>:<email>` sayaç.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| HS256 (simetrik) | Tek instance, key rotasyonu kolay; RS256 JWK gerekmez |
| PHC format saklama | Algoritma parametreleri hash içinde → doğrulama sırasında config'e gerek yok |
| AES-GCM (AEAD) | CBC'den güvenli, tag doğrulaması, tek passo |
| ENCRYPTION_KEY 32 byte | AES-256; 16 byte (128) zayıf |
| Random: resty.random.bytes(true) | `getrandom()` (blocking) → kriptografik |

## DoD

- [ ] `password.hash` → `verify` true, yanlış parola false.
- [ ] Aynı parola iki hash'i farklı (salt).
- [ ] `jwt.sign_access` → `verify` true, `expected_typ` mismatch → `UNAUTHORIZED`.
- [ ] Expired token → `TOKEN_EXPIRED`.
- [ ] `crypto.encrypt` → `decrypt` == plaintext; yanlış key → decrypt nil + log.
- [ ] `random.uuid4` geçerli UUID v4.
- [ ] `luacheck` temiz, spec 100% yeşil.
