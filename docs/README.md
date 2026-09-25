# docs — pgLua Dokümantasyon İndeksi

> Bu dizin `lua-pg-editor` (pgLua) projesinin tüm plan ve runbook dokümanlarını içerir.
> Faz dokümanları `fazlar/` altındadır; her faz kendi `DoD` (Definition of Done) ile bağımsız doğrulanabilir.

## Hızlı Başlangıç (planı okumak)

1. Önce [00-genel-bakis.md](fazlar/00-genel-bakis.md) — **tek doğruluk kaynağı** (SSOT). Env, error kodları, RBAC, audit, teknik kararlar burada.
2. Sonra fazlar sırasıyla — bağımlılık grafiği 00 §12.

## Faz Haritası

| Faz | Dosya | Ad | Efor | Özet |
|---|---|---|---|---|
| 00 | [00-genel-bakis.md](fazlar/00-genel-bakis.md) | Genel Bakış & SSOT | — | Mimari, sözleşmeler, tüm sözlük |
| 00 | [faz-00-monorepo-altyapı.md](fazlar/faz-00-monorepo-altyapı.md) | Monorepo Altyapı | S | docker-compose, Makefile, lint, git hooks |
| 01 | [faz-01-shared-kutuphane.md](fazlar/faz-01-shared-kutuphane.md) | Shared Kütüphane | M | types, validation, protocol |
| 02 | [faz-02-veritabani-migration.md](fazlar/faz-02-veritabani-migration.md) | Veritabanı & Migration | M | users, connections, query_history, audit, rbac |
| 03 | [faz-03-backend-core.md](fazlar/faz-03-backend-core.md) | Backend Core | L | config, nginx, Lapis, query, router, error |
| 04 | [faz-04-security.md](fazlar/faz-04-security.md) | Security | M | jwt, argon2, random, AES-GCM |
| 05 | [faz-05-auth-endpointleri.md](fazlar/faz-05-auth-endpointleri.md) | Auth Endpointleri | L | login/refresh/logout/me/forgot/reset |
| 06 | [faz-06-bağlantılar.md](fazlar/faz-06-bağlantılar.md) | Bağlantı Yönetimi | L | CRUD + test + pool_manager + şifreleme |
| 07 | [faz-07-şema-yapı.md](fazlar/faz-07-şema-yapı.md) | Şema & Yapı | L | schemas, objects, structure (6 sorgu) |
| 08 | [faz-08-sorgu-motoru-gecmis.md](fazlar/faz-08-sorgu-motoru-gecmis.md) | Sorgu Motoru & Geçmiş | L | execute, history, completion, limit |
| 09 | [faz-09-tablo-tarayıcı.md](fazlar/faz-09-tablo-tarayıcı.md) | Tablo Tarayıcı | L | pagination, filter, insert/duplicate/delete, edit |
| 10 | [faz-10-obje-eylemleri-script-export.md](fazlar/faz-10-obje-eylemleri-script-export.md) | Obje & Script & CSV | M | rename/truncate/drop, DDL script, CSV export |
| 11 | [faz-11-kullanıcı-rbac.md](fazlar/faz-11-kullanıcı-rbac.md) | Kullanıcı & RBAC | L | user CRUD, matrix |
| 12 | [faz-12-audit-middleware.md](fazlar/faz-12-audit-middleware.md) | Audit & Middleware | M | audit_context, record, export |
| 13 | [faz-13-swagger-openapi.md](fazlar/faz-13-swagger-openapi.md) | Swagger/OpenAPI 3.1 | M | spec, redocly |
| 14 | [faz-14-scheduled-jobs.md](fazlar/faz-14-scheduled-jobs.md) | Scheduled Jobs | S | audit/history cleanup |
| 15 | [faz-15-backend-test-load-test.md](fazlar/faz-15-backend-test-load-test.md) | Backend Test & Bench | L | busted + wrk |
| 16 | [faz-16-frontend-iskelet.md](fazlar/faz-16-frontend-iskelet.md) | Frontend İskelet | M | Wasmoon, glue, bundling |
| 17 | [faz-17-frontend-core.md](fazlar/faz-17-frontend-core.md) | Frontend Core | L | store, dom, fetch, router, editor |
| 18 | [faz-18-frontend-views-editor-bağlantılar.md](fazlar/faz-18-frontend-views-editor-bağlantılar.md) | Views I (Bağlantı & Editör) | L | login, connections, query editor |
| 19 | [faz-19-frontend-views-tarayıcı-yapı.md](fazlar/faz-19-frontend-views-tarayıcı-yapı.md) | Views II (Tarayıcı & Yapı) | L | table browser, structure |
| 20 | [faz-20-frontend-views-admin.md](fazlar/faz-20-frontend-views-admin.md) | Views III (Admin) | M | users, rbac, audit, settings |
| 21 | [faz-21-frontend-ux-polish.md](fazlar/faz-21-frontend-ux-polish.md) | UX Polish | M | tema, klavye, a11y |
| 22 | [faz-22-frontend-test-wasm-opt.md](fazlar/faz-22-frontend-test-wasm-opt.md) | Frontend Test & WASM Opt | M | busted, playwright, wasm opt |
| 23 | [faz-23-deployment-dokumantasyon.md](fazlar/faz-23-deployment-dokumantasyon.md) | Deployment & Dokümantasyon | L | prod compose, TLS, backup |
| 24 | [faz-24-spec-analizi-bosluk-haritasi.md](fazlar/faz-24-spec-analizi-bosluk-haritasi.md) | Spec Analizi & Boşluk Haritası | S | spec ↔ mevcut durum, mimari karar, F25–F30 haritası |
| 25 | [faz-25-nesne-gezgini-backend.md](fazlar/faz-25-nesne-gezgini-backend.md) | Nesne Gezgini Backend | L | kategori sayaç/liste endpoint'leri, rules/policies, CREATE script |
| 26 | [faz-26-nesne-gezgini-frontend.md](fazlar/faz-26-nesne-gezgini-frontend.md) | Nesne Gezgini Frontend | L | şema→kategori→nesne ağacı, lazy, hızlı filtre, sağ tık, detay |
| 27 | [faz-27-sql-editor-gelistirmeleri.md](fazlar/faz-27-sql-editor-gelistirmeleri.md) | SQL Editör Geliştirmeleri | M | Ctrl+Shift+Enter, sekme adı, yıkıcı onay, hata pozisyonu, tümünü getir |
| 28 | [faz-28-sonuc-paneli-ve-disa-aktarma.md](fazlar/faz-28-sonuc-paneli-ve-disa-aktarma.md) | Sonuç Paneli & Dışa Aktarma | M | export diyaloğu düzeltmesi, grid sayfalama/virtual scroll, DML mesajı |
| 29 | [faz-29-ipuclari-kesfedilebilirlik.md](fazlar/faz-29-ipuclari-kesfedilebilirlik.md) | İpuçları & Keşfedilebilirlik | S | yardım butonu, gizli özellikler, ipucu kartı, palet komutları |
| 30 | [faz-30-performans-zaman-asimi-guvenlik.md](fazlar/faz-30-performans-zaman-asimi-guvenlik.md) | Performans, Zaman Aşımı & Güvenlik | M | statement_timeout, nginx limit_req, read-only rol, bench |
| 31 | [faz-31-sql-injection-sertlestirme.md](fazlar/faz-31-sql-injection-sertlestirme.md) | SQL Injection Sertleştirme | M | safe_sql, validate_expression, where_raw kaldırma, LIMIT parametreleştirme |
| 32 | [faz-32-backend-yikici-sorgu-ve-rol-korumasi.md](fazlar/faz-32-backend-yikici-sorgu-ve-rol-korumasi.md) | Backend Yıkıcı Sorgu & Rol Koruması | M | destructive guard, editor read-only, confirm akışı |
| 33 | [faz-33-savunma-derinligi-ve-ci.md](fazlar/faz-33-savunma-derinligi-ve-ci.md) | Savunma Derinliği & CI | S | grep kuralları, güvenlik testleri, WAF/sqlmap runbook |

## Diğer Dokümanlar

- [operations.md](operations.md) — runbook (deploy, rollback, backup/restore, sık sorunlar)
- [security-checklist.md](security-checklist.md) — canlıya çıkış güvenlik kontrol listesi
- `../README.md` — proje kök README (hızlı başlangıç, Make komutları)

## Okuma Sırası Önerisi

- **Yeni başlayan**: 00 → 00 → 01 → 02 → 03 (çekirdeği anla).
- **Backendçi**: 00 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10.
- **Frontendçi**: 00 → 16 → 17 → 18 → 19 → 21.
- **DevOps**: 00 → 00 (env §6.1) → 14 → 15 (bench) → 23 → operations.md.

## Faz Bağımlılık Grafiği

```
F0 → F1 → F2 → F3 → F4 → F5 → F6 → F7 → F8 → F9 → F10 → F11 → F12 → F13 → F14 → F15
                         └────────────────────────────→ F16 → F17 → F18 → F19 → F20 → F21 → F22 → F23

F23 → F24 → F25 → F26 ─┐
        ├──→ F27 ──────┼→ F29 → F30
        └──→ F28 ──────┘
```

Paralel: F16 frontend iskelet F5'ten sonra başlayabilir. F27 ve F28, F25'ten bağımsızdır; F26 ile paralel yürür.

## Katkı

Her faz dokümanı `DoD` checkboxes içerir; faz "tamamlandı" sayılmadan önce tüm maddeler yeşil olmalı ve `make lint && make test` temiz olmalı.
