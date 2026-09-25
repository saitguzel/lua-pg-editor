# ═══ FAZ 32 — BACKEND YIKICI SORGU & ROL BAZLI KORUMA (YÜKSEK) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — rbac §7, audit §8, error §5, types `DEFAULT_PERMISSIONS`.
> Önceki: Faz-27 (`shared/src/sql_guard.lua`), Faz-08 (query_service), Faz-31.

## Amaç
Frontend-only `sql_guard.destructive_kind` uyarısını backend’de zorunlu hale getirmek ve
by-design ham SQL yüzeyini (`POST /query/execute`) rol bazlı kısıtlamak.

## Çıktılar
| Yol | Değişiklik |
|---|---|
| `shared/src/protocol.lua` | yeni error kodu `DESTRUCTIVE_REQUIRES_CONFIRM` (409) — yıkıcı sorgu onaysız |
| `shared/src/sql_guard.lua` | değişiklik yok (zaten backend’de require edilebilir); sadece doc |
| `api/src/services/query_service.lua` | `execute` başına: (1) editor rolü için read-only guard, (2) tüm roller için destructive guard (`sql_guard.destructive_kind`) → `confirm=true` yoksa 409 |
| `api/src/handlers/query.lua` | `query_execute` şemasına `confirm` (boolean, optional) ekle; service’e geçir |
| `shared/src/validation.lua` | `query_execute` şemasına `confirm = optional(boolean)` ekle |
| `api/src/db/target/query.lua` | değişiklik yok; `READONLY_VIOLATION` korunur |
| `web/src/views/query_editor.lua` | destructive modal “Onayla” → `confirm=true` ile retry |
| `api/spec/query_error_spec.lua` + `shared/spec/sql_guard_spec.lua` | yeni backend testleri |

## Tasarım — Rol Bazlı Guard
```lua
-- api/src/services/query_service.lua (execute başı, ownership + rate_limit sonrası)
local guard = require("pg_shared.sql_guard")
local READONLY_KW = { ["select"]=true, ["with"]=true, ["show"]=true, ["explain"]=true, ["values"]=true, ["table"]=true }

function _M.execute(identity, input)
  -- 1) editor ise sadece okuma
  if identity.role == "editor" then
    local lead = require("utils.sql_parser").lead_keyword(input.sql)
    if not READONLY_KW[lead or ""] then
      return nil, errors.new("FORBIDDEN", "Editor rolu yalnizca okuma sorgulari çalıştırabilir")
    end
    -- editor için yıkıcı da zaten bu kümede değil, ama ikinci guard yine çalışır
  end
  -- 2) yıkıcı sorgu → confirm zorunlu
  local hit = guard.destructive_kind(input.sql)
  if hit and not input.confirm then
    return nil, errors.new("DESTRUCTIVE_REQUIRES_CONFIRM",
      "Yikici sorgu ("..hit.kind.."): "..hit.statement.." — confirm=true ile tekrar gonderin",
      { kind=hit.kind, statement=hit.statement })
  end
  -- ... mevcut pool acquire / execute
end
```

`lead_keyword` `utils/sql_parser.lua:282` zaten var; `READONLY_KW` set’i `db/target/query.lua:94` `ROW_STATEMENTS` ile uyumlu tutulur.
`confirm` alanı audit log’a yazılmaz (sadece guard).

`DESTRUCTIVE_REQUIRES_CONFIRM` 409 döner; frontend 409’u yakalayıp modal gösterir,
kullanıcı “Çalıştır” derse `body.confirm = true` ile ikinci istek.

## Editor Read-Only Davranışı
- `editor` → `SELECT/WITH/SHOW/EXPLAIN/VALUES/TABLE` dışındaki her lead keyword 403 `FORBIDDEN`.
- `admin` → serbest, ama yine `confirm` gerekir (DROP/TRUNCATE/WHERE’siz DELETE/ALTER DROP).

## Frontend Akış
`web/src/views/query_editor.lua:run()` mevcut `sql_guard.destructive_kind` ön kontrolünü korur
(erken modal), ama son söz backend’dir. Backend 409 dönerse aynı modal tekrar gösterilir
ve onayda `fetch("/query/execute", { sql, confirm=true })`.

## DoD
- [ ] `editor` ile `DROP TABLE t` → 403 `FORBIDDEN` (lead guard).
- [ ] `admin` ile `DROP TABLE t` (`confirm` yok) → 409 `DESTRUCTIVE_REQUIRES_CONFIRM`, `details.kind="DROP"`.
- [ ] `admin` ile `DROP TABLE t` + `confirm=true` → yürütülür (hedef DB’ye gider, audit `query.execute`).
- [ ] `DELETE FROM t WHERE id=1` → 200 (WHERE’li DELETE yıkıcı sayılmaz); `DELETE FROM t` → 409.
- [ ] `make lint && make test` yeşil; e2e `query.spec.ts` yıkıcı modal + confirm retry yeşil.
