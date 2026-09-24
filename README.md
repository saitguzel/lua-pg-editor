# pgLua — PostgreSQL Web Editor

OpenResty/Lapis API + Wasmoon (Lua 5.4 WASM) frontend + ortak Lua kütüphanesinden oluşan özgün PostgreSQL web istemcisi ve SQL editörü.

> **Stack**: OpenResty 1.25+/LuaJIT/Lapis/pgmoon + Wasmoon Lua 5.4 + Tailwind + CodeMirror 6 — özgün, hafif ve hızlı PostgreSQL yönetim platformu.

## Özellikler

- Bağlantıları kaydet/yeniden aç, parolayı AES-GCM ile güvenli sakla
- Şemaları, tablo/view'ları listele; yapıyı incele (kolon, index, constraint, FK, trigger)
- SQL'i CodeMirror 6 ile yaz (vurgulama, satır no, şema duyarlı otocomplete)
- Veritabanı başına otomatik sorgu geçmişi
- Tablo satırlarını sayfala/filtrele/özel SQL filtresi + hücre düzenle
- Satır ekle/çoğalt/sil
- Sonuçları CSV dışa aktar
- Tablo scriptleri üret (SELECT/INSERT/CREATE/DROP)
- Tablo/view'ı yeniden adlandır/truncate/sil

+ RBAC (admin/editor), audit log, sorgu geçmişi, scheduled jobs, Swagger.

## Mimari

| Bileşen | Teknoloji |
|---|---|
| `pg-api` | OpenResty / Lapis / pgmoon |
| `pg-web` | Lua 5.4 Wasmoon WASM + CodeMirror 6 |
| `pg-shared` | Saf Lua (5.1∩5.4) |
| `pg-meta` | PostgreSQL 15+ (meta DB) |

Diyagram ve katman kuralları: [00-genel-bakis](docs/fazlar/00-genel-bakis.md).

## Dizin yapısı

```
api/            OpenResty + Lapis backend (handlers→services→repositories→db)
  conf/         nginx.conf, lua.conf, env.conf
  src/          db, middleware, security, openapi, jobs, mail
  migrations/   001…007 (runner: src/db/migrations.lua)
  seeds/        rbac_defaults, default_users, demo_data
  spec/         busted
shared/src/     pg_shared.{types,validation,protocol}
web/            Wasmoon SPA: src/views, components, js/glue.js, public/, e2e/
deploy/         prod: proxy/, backup/, deploy.sh
docs/           fazlar/ (spesifikasyon), operations.md, security-checklist.md
```

## Hızlı başlangıç

```bash
make setup && make up && make db.migrate db.seed
# Web:     http://localhost:28100               (/api/v1 → web nginx proxy)
# API:     http://localhost:28180/api/v1/health
# Swagger: http://localhost:28100/api/v1/swagger
# MailHog: http://localhost:28125
# (varsayılan .env.example 28000/28080 kullanır; yerel .env 28100/28180 ile çakışma önlenir)
```

Sunucu IP/domain:

```bash
APP_BASE_URL=http://<ip>:28100
WEB_BASE_URL=http://<ip>:28100
docker compose up -d --force-recreate api
```

Varsayılan hesaplar (SEED_DEFAULTS=true):

- `admin@pgeditor.local / Admin123!`
- `editor@pgeditor.local / Editor123!`

## Make komutları

| Hedef | Açıklama |
|---|---|
| `make up/down/logs` | ayağa kaldır/durdur/log |
| `make db.migrate/rollback/status/seed/reset/psql` | migration |
| `make lint` | luacheck |
| `make test` | tüm testler |
| `make test.integration` | entegrasyon (API ayakta) |
| `make web.build/dev` | frontend bundle / dev |
| `make web.test/e2e` | frontend birim / Playwright |
| `make bench` | wrk yük testi |
| `make spec.lint` | redocly lint |
| `make job.cleanup` | audit temizliği elle |
| `make backup.verify` | yedek doğrulama |

## Ortam değişkenleri

Kanonik liste: [00-genel-bakis §6](docs/fazlar/00-genel-bakis.md). `.env.example` birebir aynı. Gizli değerler `_FILE` ile secrets.

## API

Swagger: `/api/v1/swagger` · JSON: `/api/v1/swagger.json` · Health: `/api/v1/health` + `/health/ready` + `/metrics`.

## Production

```bash
cp .env.prod.example .env.prod && chmod 600 .env.prod
mkdir -p secrets && openssl rand -base64 32 > secrets/jwt_secret && openssl rand -base64 32 > secrets/encryption_key && openssl rand -hex 16 > secrets/db_password
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --wait
docker compose --env-file .env.prod -f docker-compose.prod.yml run --rm api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up
```

Sonraki sürümler `TAG=vX.Y.Z sh deploy/deploy.sh` — detay [docs/operations.md](docs/operations.md), checklist [docs/security-checklist.md](docs/security-checklist.md).

## Test

```bash
make lint && make test
make up.e2e && make web.e2e
make bench
```

## Lisans

MIT
