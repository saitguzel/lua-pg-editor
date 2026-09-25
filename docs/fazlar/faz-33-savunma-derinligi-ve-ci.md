# ═══ FAZ 33 — SAVUNMA DERİNLİĞİ & CI (ORTA) ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — teknik kararlar §11 (#19 SQLi), checklist `docs/security-checklist.md` §5.
> Önceki: Faz-31, Faz-32.

## Amaç
Kod seviyesi fix’lerin gerilemesini önlemek: CI grep kuralları, güvenlik testleri, WAF/rate-limit dokümantasyonu ve operatör runbook.

## Çıktılar
| Yol | Değişiklik |
|---|---|
| `.githooks/pre-commit` veya `Makefile` `lint` | `grep -r "where_raw\|pg:query(.*\.\.\|LIMIT.*\.\. math.floor" api/src` → fail |
| `.github/workflows/ci.yml` (varsa) veya `Makefile` `test` | `make test.security` hedefi: `busted api/spec/query_parser_spec.lua shared/spec/sql_guard_spec.lua` + yeni `security_spec.lua` |
| `api/spec/security_spec.lua` | ek: `custom_where` yasak kelime / kolon allow-list testleri (opsiyonel, yoksa query_parser_spec’e ekle) |
| `docs/security-checklist.md` | §5 maddeleri işaretli: `where_raw yok`, `LIMIT parametreli`, `custom_where allow-list` |
| `docs/operations.md` | WAF (ModSecurity CRS) + `sqlmap` manuel test adımları + read-only rol reçetesi (F30’dan referans) |
| `api/src/db/query.lua` header | yorum: “Tüm SQL parametreli; ham concat yasak — bkz faz-31” |

## CI Grep Kuralları
```bash
# Meta DB ham concat yasağı
! grep -rn 'pg:query(".*\.\.' api/src/repositories api/src/db/query.lua
! grep -rn 'where_raw' api/src
# LIMIT concat yasağı
! grep -rn 'LIMIT " \.\.' api/src/repositories/target_schema_repo.lua
```

## Güvenlik Testleri
- `query_parser_spec.lua` zaten `validate_expression` red testleri içeriyor; Faz-31 yasak kelimeleri ekle.
- `sql_guard_spec.lua` backend destructive guard ile eşlenik doğrulanır.
- Manuel: `sqlmap -u "http://localhost:28080/api/v1/connections/<id>/objects/public/users/rows?custom_where=1" --batch` → 400.

## DoD
- [ ] `grep where_raw` boş; `grep 'LIMIT " \.\. math.floor'` boş (CI fail değil).
- [ ] `make lint && make test` yeşil; `docs/security-checklist.md` §5 tüm maddeler yeşil.
- [ ] `docs/operations.md` WAF + sqlmap adımları mevcut.
