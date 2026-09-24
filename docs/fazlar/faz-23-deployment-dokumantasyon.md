# ═══ FAZ 23 — DEPLOYMENT & DOKÜMANTASYON ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — env §6, shared dict §9, teknik düzeltmeler.

## Amaç

Üretim: küçük güvenli imajlar, prod compose (TLS reverse proxy, secrets, limitler, healthcheck), CI/CD, izleme, yedek/geri yükleme, ve tamamlanmış dokümantasyon.

## Çıktılar

| Dosya | Sorumluluk |
|---|---|
| `api/Dockerfile` | çok aşamalı: build → runtime (non-root) |
| `web/Dockerfile` | Node bundle + nginx statik |
| `docker-compose.prod.yml` | postgres+api+web+proxy+backup, secrets |
| `deploy/proxy/nginx.conf` | TLS, güvenlik header, /api→api, /→web, rate limit |
| `deploy/backup/backup.sh` | pg_dump -Fc + rotasyon |
| `deploy/backup/restore.sh` | restore + doğrulama |
| `api/src/router.lua` | + `/health/ready`, `/metrics` |
| `.github/workflows/ci.yml` | build+lint+test+trivy |
| `.github/workflows/release.yml` | tag → GHCR push, SBOM, deploy |
| `README.md` | tam kullanım |
| `docs/operations.md` | runbook |
| `docs/security-checklist.md` | güvenlik checklist |

## api/Dockerfile (çok aşamalı)

```dockerfile
FROM openresty/openresty:1.25.3.2-alpine-fat AS build
RUN apk add --no-cache build-base git openssl-dev argon2-dev
WORKDIR /build
COPY rockspecs/ rockspecs/
COPY shared/ shared/
RUN luarocks install lapis 1.16.0 && luarocks install pgmoon 1.16.0 \
 && luarocks install lua-resty-jwt 0.2.3 && luarocks install argon2 3.0.1 \
 && luarocks install lua-resty-mail 1.1.0 && luarocks install luaossl \
 && luarocks make rockspecs/pg-shared-0.1.0-1.rockspec

FROM openresty/openresty:1.25.3.2-alpine
RUN apk add --no-cache argon2-libs libgcc tini && addgroup -S app && adduser -S -G app -H app
COPY --from=build /usr/local/openresty/luajit /usr/local/openresty/luajit
WORKDIR /app
COPY --chown=app:app api/conf/ conf/
COPY --chown=app:app api/src/ src/
COPY --chown=app:app api/migrations/ migrations/
COPY --chown=app:app api/seeds/ seeds/
COPY --chown=app:app api/public/ public/
RUN mkdir -p logs temp && chown app:app logs temp
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8080/api/v1/health || exit 1
ENTRYPOINT ["/sbin/tini","--"]
CMD ["openresty","-p","/app","-c","conf/nginx.conf","-g","daemon off;"]
```

## web/Dockerfile

```dockerfile
FROM node:20-alpine AS build
RUN apk add --no-cache bash brotli lua5.4
WORKDIR /build
COPY web/package.json web/package-lock.json web/
RUN cd web && npm ci
COPY shared/ shared/
COPY web/ web/
RUN cd web && npx tailwindcss -i public/styles.css -o public/dist/tailwind.css --minify && MODE=production ./build-wasm.sh

FROM nginx:1.27-alpine
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/web/public/ /usr/share/nginx/html/
HEALTHCHECK CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
```

`deploy/web/nginx.conf`: `gzip_static on; types { application/wasm wasm; } location /dist/ { Cache-Control immutable; }`

## docker-compose.prod.yml (öz)

```yaml
name: pg-prod
services:
  postgres:
    image: postgres:16-alpine
    environment: { POSTGRES_DB: pgeditor, POSTGRES_USER: pgeditor, POSTGRES_PASSWORD_FILE: /run/secrets/db_password }
    secrets: [db_password]
    volumes: [pgdata:/var/lib/postgresql/data]
    command: ["postgres","-c","max_connections=100","-c","shared_buffers=256MB","-c","log_min_duration_statement=500"]
    healthcheck: { test: ["CMD-SHELL","pg_isready -U pgeditor -d pgeditor"], interval:10s, retries:5 }
  api:
    image: ghcr.io/OWNER/pg-api:${TAG:?}
    env_file: .env.prod
    environment: { APP_ENV: production, DB_HOST: postgres }
    secrets: [db_password, jwt_secret, smtp_password, encryption_key]
    depends_on: { postgres:{ condition:service_healthy } }
    read_only:true; tmpfs: [/app/temp, /app/logs]; cap_drop:[ALL]; security_opt:["no-new-privileges:true"]
    deploy: { replicas:2, resources:{ limits:{ cpus:"1.0", memory:512m } } }
  web: { image: ghcr.io/OWNER/pg-web:${TAG}, read_only:true }
  proxy:
    image: nginx:1.27-alpine
    ports: ["${HTTP_PORT:-80}:80","${HTTPS_PORT:-443}:443"]
    volumes: ["./deploy/proxy/nginx.conf:/etc/nginx/nginx.conf:ro","./deploy/proxy/certs:/etc/nginx/certs:ro"]
    depends_on: [api, web]
  backup:
    image: postgres:16-alpine
    entrypoint: ["/bin/sh","-c","crond -f -l 8"]
    volumes: ["./deploy/backup:/scripts:ro","backups:/backups"]
    secrets: [db_password]
secrets: { db_password:{ file:./secrets/db_password }, jwt_secret:{ file:./secrets/jwt_secret }, smtp_password:{ file:./secrets/smtp_password }, encryption_key:{ file:./secrets/encryption_key } }
volumes: { pgdata:{}, backups:{} }
```

## proxy nginx.conf (öz)

```
limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;
upstream api { server api:8080; keepalive 32; }
server { listen 80; return 301 https://$host$request_uri; }
server {
  listen 443 ssl; http2 on;
  ssl_certificate /etc/nginx/certs/fullchain.pem;
  ssl_certificate_key /etc/nginx/certs/privkey.pem;
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  add_header X-Content-Type-Options nosniff always;
  add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; ..." always;
  client_max_body_size 1m;
  location /api/ { limit_req zone=api burst=40 nodelay; proxy_pass http://api; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Request-Id $request_id; }
  location = /api/v1/metrics { deny all; }
  location / { proxy_pass http://web; }
}
```

## İzleme

| Endpoint | Amaç |
|---|---|
| `GET /health` | liveness (DB yok) |
| `GET /health/ready` | readiness (DB SELECT 1) |
| `GET /metrics` | Prometheus (req_total, latency_sum) — proxy deny |

## Yedekleme

| Katman | Yöntem | Sıklık |
|---|---|---|
| pg_dump -Fc | `pg_dump -Fc pgeditor | gzip > /backups/pgeditor-$(date).dump.gz` | Günlük 02:00 UTC |
| Deploy öncesi | `backup.sh pre-deploy` | Her deploy |
| Retention | 7 günlük + 4 haftalık + 6 aylık |  |

`backup.sh`, `restore.sh`, `verify.sh` yedekleme betikleri.

## CI/CD

`release.yml` tag `v*` → build matrix api/web → GHCR push + trivy + SBOM → ssh deploy `TAG=vX.Y.Z ./deploy.sh` (yedek → migrate → api → web/proxy → smoke).

## DoD

- [ ] `docker compose -f docker-compose.prod.yml up -d` → HTTPS, login çalışır.
- [ ] `curl https://host/api/v1/health/ready` 200.
- [ ] Secrets `_FILE` ile okunur, düz env yok.
- [ ] Backup/restore tatbikatı başarılı.
- [ ] Trivy HIGH/CRITICAL 0.
