# Operasyon Runbook — pgLua

> Prod `docker-compose.prod.yml` ile çalışan sistem için. Dev için `README.md`'deki `make` komutlarına bak.

## 1. Ortam Değişkenleri & Secrets

Prod env ` .env.prod` (izin 600) + `secrets/`:

```
secrets/
  db_password        # 32+ char
  jwt_secret         # ≥32 byte
  smtp_password
  encryption_key     # 32 byte base64
```

Oluştur:

```bash
mkdir -p secrets && chmod 700 secrets
openssl rand -base64 32 > secrets/jwt_secret
openssl rand -base64 32 > secrets/encryption_key
openssl rand -hex 16 > secrets/db_password
printf '%s' 'smtp-pass' > secrets/smtp_password
chmod 600 secrets/*
cp .env.prod.example .env.prod && chmod 600 .env.prod
# .env.prod içini doldur: TAG, GHCR_OWNER, domain, SMTP, APP_BASE_URL=https://pg.example.com
```

`config.lua` `_FILE` varyantını okur; düz env varsa uyarı basar.

## 2. İlk Kurulum

```bash
TAG=v0.1.0 docker compose --env-file .env.prod -f docker-compose.prod.yml pull
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --wait postgres
docker compose --env-file .env.prod -f docker-compose.prod.yml run --rm api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up
docker compose --env-file .env.prod -f docker-compose.prod.yml run --rm api resty -I /app/src -I /app/lib /app/src/db/migrations.lua seed
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --wait
curl -fsS https://pg.example.com/api/v1/health/ready && echo "OK"
```

## 3. Deploy (sürüm yükseltme)

`deploy/deploy.sh` (Sunucuda `/srv/pg-editor`):

```bash
#!/usr/bin/env bash
set -euo pipefail
TAG=${TAG:?TAG gerekli, ör. v0.2.0}
compose="docker compose --env-file .env.prod -f docker-compose.prod.yml"
$compose pull
./deploy/backup/backup.sh pre-deploy
$compose run --rm api resty -I /app/src -I /app/lib /app/src/db/migrations.lua up
$compose up -d --no-deps api
$compose up -d --wait
curl -fsS https://pg.example.com/api/v1/health/ready
curl -fsS -X POST https://pg.example.com/api/v1/auth/login -H 'Content-Type: application/json' -d '{"email":"admin@pgeditor.local","password":"Admin123!"}' | jq .
echo "Deploy $TAG tamam"
```

CI `release.yml` bu scripti `appleboy/ssh-action` ile çağırır (GitHub environment `production` onay kapısı).

Rollback:

```bash
TAG=v0.1.0 docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --wait
# migration geri alınmaz (expand-only); veri bozulduysa restore:
./deploy/backup/restore.sh backups/pgeditor-pre-deploy-*.dump.gz
```

## 4. Yedekleme

Cron (backup servisi içinde `crond`):

```
0 2 * * * /scripts/backup.sh daily      # 02:00 UTC, log cleanup'tan önce
```

Manuel:

```bash
./deploy/backup/backup.sh daily
./deploy/backup/backup.sh pre-deploy
ls -lh backups/
```

Restore:

```bash
./deploy/backup/restore.sh backups/pgeditor-2026-09-23.dump.gz
# doğrulama:
docker compose --env-file .env.prod -f docker-compose.prod.yml exec postgres psql -U pgeditor -d pgeditor -c "SELECT count(*) FROM users; SELECT count(*) FROM connections;"
```

Rotasyon: `backup.sh` içinde `find backups -mtime +7 -name 'daily-*' -delete` + haftalık/aylık kopyalar.

Verify (CI'da da):

```bash
make backup.verify # dev'de: pg_dump | pg_restore --dry-run
```

## 5. İzleme

- `GET /health` (liveness) ve `/health/ready` (DB SELECT 1) → Uptime Kuma / Prometheus.
- `GET /metrics` → Prometheus `metrics` dict (req_total, latency_sum) — proxy'de `deny all`, backend ağından scrap.
- Loglar: `docker logs pg-prod-api-1` → `LOG_FORMAT=json` → `jq .`, Loki opsiyonel.

Uyarılar (öneri):

| Uyarı | Koşul |
|---|---|
| API down | `/health/ready` 2 dk fail |
| 5xx spike | `rate(5xx)/rate(total)>2%` 5m |
| Backup eksik | son backup >26h |
| Disk | volume >80% |
| Sertifika | <14 gün |

## 6. Sık Sorunlar

| Sorun | Neden | Çözüm |
|---|---|---|
| `Config hatası: ENCRYPTION_KEY: en az 32` | key kısa | `openssl rand -base64 32` ile yeniden |
| `/health/ready` 503 | meta DB down | `docker compose logs postgres`, `pg_isready` |
| `CONNECTION_FAILED` hedef DB'ye | hedef firewall / parola | `docker compose exec api resty` ile `pool_manager.test` logu, `connections/:id/test` |
| `429 RATE_LIMITED` | brute force | `rate_limit` dict reset: `docker compose restart api` veya bekle 60s |
| `PAYLOAD_TOO_LARGE` sorgu | `QUERY_MAX_BYTES` aşıldı | sorguyu küçült veya env artır + `docker compose up -d api` |
| `row_limit truncated` | 50k limiti | `row_limit` param küçült, CSV export kullan |
| `CORS` hatası prod | `CORS_ORIGINS` yanlış | `.env.prod` domain ekle + `docker compose up -d api` |

## 7. Bakım Pencereleri

- `AUDIT_CLEANUP_HOUR=3` UTC → log cleanup. `VACUUM (ANALYZE) audit_logs;` büyük ilk silmeden sonra.
- `QUERY_HISTORY_RETENTION_DAYS=30` → history cleanup aynı pencerede.
- `VACUUM FULL audit_logs` yalnızca `maintenance` penceresinde (tablo kilitler).
