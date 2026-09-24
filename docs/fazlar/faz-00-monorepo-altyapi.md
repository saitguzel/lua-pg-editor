# ═══ FAZ 00 — MONOREPO + ALTYAPI ═══

> Kanonik referans: [00-genel-bakis.md](00-genel-bakis.md) — env değişkenleri (§6), shared dict'ler (§9), teknik düzeltmeler.

## Amaç

Tek bir `git clone` + `cp .env.example .env` + `make up` ile PostgreSQL (meta), API (boş OpenResty) ve Web (statik nginx) konteynerlerinin ayağa kalktığı, lint'in pre-commit'te zorunlu olduğu monorepo iskeletini kurmak. Henüz iş mantığı yok; ancak sonraki her fazın kullandığı komutlar (`make db.migrate`, `make test`, `make api.reload`…) tanımlı ve (gövdesi boş olsa bile) çalışır.

## Önkoşullar

- Yok (ilk faz).
- İhtiyaç: Docker 24+, Compose v2, GNU Make, git; opsiyonel `luarocks`+`luacheck`, Node 20+.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `lua-pg-editor/` (repo kökü) | Monorepo kökü |
| `build.sh` | Tüm bileşenleri sırayla derleyen tek giriş (CI/yerel) |
| `Makefile` | Geliştirici komutları (`db.*`, `api.*`, `web.*`, `test`, `lint`, `bench`) |
| `scripts/check-ports.sh` | `make up` öncesi host port çakışma kontrolü |
| `README.md` | İskelet: hızlı başlangıç, dizin yapısı, komut listesi (F23'te tamamlanır) |
| `docker-compose.yml` | Dev: `postgres` (meta), `mailhog`, `api`, `web` |
| `docker-compose.prod.yml` | Boş iskelet (F23'te doldurulur) |
| `.env.example` | 00 §6'daki **tüm** değişkenler birebir (pg-editor adlarıyla) |
| `.gitignore` | Lua/Node/Docker/OS artıkları, `.env`, `web/public/app.wasm`, `bundle.json` |
| `.editorconfig` | 2 boşluk, LF, UTF-8, trim trailing whitespace |
| `.luacheckrc` | `ngx_lua` std, busted için ayrı |
| `.githooks/pre-commit` | Staged `.lua` dosyalarında `luacheck` |
| `rockspecs/` | Boş dizin (F1) |
| `api/`, `web/`, `shared/` | Prompt ağacına göre boş dizinler + `.gitkeep` |
| `api/Dockerfile` | Dev (OpenResty + LuaRocks); F23'te çok aşamalı |
| `web/Dockerfile` | Dev (nginx:alpine statik); F23'te çok aşamalı |
| `api/conf/nginx.conf` | Geçici minimal: `/health` → `200 ok` (F3'te gerçek hali) |

## Dizin Ağacı

```
lua-pg-editor/
├── .editorconfig  .env.example  .gitignore  .luacheckrc  .githooks/pre-commit
├── build.sh  Makefile  README.md  docker-compose.yml  docker-compose.prod.yml
├── docs/
├── rockspecs/.gitkeep
├── api/
│   ├── Dockerfile
│   ├── conf/nginx.conf (geçici)
│   ├── src/{middleware,handlers,services,models,repositories,db,security,jobs,mail,openapi}/.gitkeep
│   ├── migrations/.gitkeep  seeds/.gitkeep  public/swagger/.gitkeep  bench/.gitkeep  spec/integration/.gitkeep
├── web/
│   ├── Dockerfile
│   ├── src/{views,components}/.gitkeep  public/.gitkeep  js/.gitkeep  spec/.gitkeep
└── shared/
    ├── src/.gitkeep  spec/.gitkeep
```

## Dosya Tasarımları (özet)

### docker-compose.yml

```yaml
name: pg-editor
services:
  postgres:
    image: postgres:15-alpine
    environment: { POSTGRES_DB: ${DB_NAME}, POSTGRES_USER: ${DB_USER}, POSTGRES_PASSWORD: ${DB_PASSWORD} }
    ports: ["127.0.0.1:${DB_HOST_PORT:-25432}:5432"]
    volumes: [pgdata:/var/lib/postgresql/data]
    command: ["postgres", "-c", "max_connections=200"]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"], interval: 5s, retries: 20 }
  mailhog: { image: mailhog/mailhog:v1.0.1, ports: ["127.0.0.1:${MAILHOG_UI_HOST_PORT:-28025}:8025"] }
  api:
    build: { context: ., dockerfile: api/Dockerfile, target: dev }
    env_file: .env
    ports: ["${API_HOST_PORT:-28080}:8080"]
    environment: { TRUSTED_PROXIES: "127.0.0.1,172.32.251.10" }
    depends_on: { postgres: { condition: service_healthy } }
    volumes:
      - ./api/src:/app/src
      - ./api/conf:/app/conf
      - ./api/migrations:/app/migrations
      - ./api/seeds:/app/seeds
      - ./api/public:/app/public
      - ./shared/src:/app/lib/pg_shared
  web:
    image: nginx:1.27-alpine
    ports: ["${WEB_HOST_PORT:-28000}:80"]
    volumes: ["./web/public:/usr/share/nginx/html:ro", "./deploy/web/dev.conf:/etc/nginx/conf.d/default.conf:ro"]
    depends_on: [api]
    networks: { default: { ipv4_address: 172.32.251.10 } }
networks: { default: { ipam: { config: [{ subnet: 172.32.251.0/24 }] } } }
volumes: { pgdata: {} }
```

Meta DB `max_connections=200`; hedef DB'ler bu compose'da yok (harici). `shared/src` → `/app/lib/pg_shared` mount (`require("pg_shared.types")`).

### .env.example (00 §6 tam liste, pg-editor defaults)

```dotenv
APP_ENV=development
APP_PORT=8080
APP_BASE_URL=http://localhost:28080
WEB_BASE_URL=http://localhost:28000
API_HOST_PORT=28080
WEB_HOST_PORT=28000
DB_HOST_PORT=25432
MAILHOG_UI_HOST_PORT=28025
DB_HOST=postgres
DB_PORT=5432
DB_NAME=pgeditor
DB_USER=pgeditor
DB_PASSWORD=change-me-dev-only
DB_SSL=false
DB_POOL_SIZE=20
DB_POOL_IDLE_TIMEOUT_MS=60000
DB_CONNECT_TIMEOUT_MS=3000
DB_QUERY_TIMEOUT_MS=10000
JWT_SECRET=dev-secret-change-me-dev-secret-change-me
JWT_ISSUER=pg-api
JWT_ACCESS_TTL=900
JWT_REFRESH_TTL=604800
ARGON2_T_COST=3
ARGON2_M_COST=12
ARGON2_PARALLELISM=1
PASSWORD_RESET_TTL=3600
LOGIN_RATE_LIMIT=5
SMTP_HOST=mailhog
SMTP_PORT=1025
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=no-reply@pgeditor.local
SMTP_TLS=false
CORS_ORIGINS=http://localhost:28000,http://127.0.0.1:28000
TRUSTED_PROXIES=127.0.0.1
LOG_FORMAT=json
LOG_LEVEL=info
AUDIT_LOG_RETENTION_DAYS=30
AUDIT_CLEANUP_ENABLED=true
AUDIT_CLEANUP_HOUR=3
AUDIT_CLEANUP_BATCH_SIZE=1000
SEED_DEFAULTS=true
RBAC_CACHE_TTL=60
ENCRYPTION_KEY=dev-encryption-key-32-bytes-long!!
TARGET_POOL_SIZE=5
TARGET_POOL_MAX=32
QUERY_ROW_LIMIT_DEFAULT=1000
QUERY_ROW_LIMIT_MAX=50000
QUERY_TIMEOUT_MS=30000
QUERY_MAX_BYTES=102400
QUERY_HISTORY_RETENTION_DAYS=30
CSV_MAX_ROWS=100000
COMPLETION_CACHE_TTL=300
```

Not: `SEED_DEFAULTS=true` dev kolaylığı; `config.lua` default `false`. `ENCRYPTION_KEY` prod'da 32 byte; `*_FILE` varyantı desteklenir.

### .gitignore / .editorconfig / .luacheckrc / pre-commit

Monorepo iskeleti (`pgeditor`/`pg_shared` adları ile):

```gitignore
.env
*.rock
/lua_modules/
/.luarocks/
luacov.*.out
node_modules/
web/public/app.wasm
web/public/bundle.json
web/dist/
web/public/glue.js
api/logs/
playwright-report/
.DS_Store
```

`.luacheckrc`:
```lua
std = "ngx_lua"
max_line_length = 120
codes = true
exclude_files = { "lua_modules/", "web/node_modules/" }
files["shared/src/"] = { std = "lua51+lua54" }
files["web/src/"] = { std = "lua54", read_globals = { "js" } }
files["**/spec/"] = { std = "+busted" }
```

`pre-commit`: staged `.lua` → `luacheck`; yoksa hata. Kurulum `make setup` → `git config core.hooksPath .githooks`.

### Makefile (iskelet)

| Hedef | Açıklama |
|---|---|
| `setup` | `cp -n .env.example .env; make hooks` |
| `hooks` | `git config core.hooksPath .githooks` |
| `ports.check` | `scripts/check-ports.sh` |
| `up` / `down` / `logs` | `docker compose up -d --build` … |
| `db.migrate` | `resty /app/src/db/migrations.lua up` (F2) |
| `lint` | `luacheck api/src shared web/src` |
| `test` | `test.shared test.api` (F15) |
| `web.build` | `cd web && ./build-wasm.sh` (F16) |

Henüz gövdesi olmayan hedefler tanımlanmaz (YAGNI).

### scripts/check-ports.sh / build.sh / Dockerfiles

Temel farklar:
- `build.sh`: `luacheck api/src shared/src web/src` + `busted shared/spec` + `web/build-wasm.sh` + `docker compose build`
- `api/Dockerfile` ek `lua-resty-string` gerekmez, fakat `luaossl` (AES-GCM) eklenir (F4):
```dockerfile
FROM openresty/openresty:1.25.3.2-alpine-fat
RUN apk add --no-cache build-base libargon2-dev openssl-dev git
RUN luarocks install lapis 1.16.0 && luarocks install pgmoon 1.16.0 && luarocks install lua-resty-jwt 0.2.3 \
 && luarocks install argon2 3.0.1 && luarocks install lua-resty-mail 1.1.0 && luarocks install luaossl \
 && luarocks install penlight && luarocks install busted && luarocks install luacheck
WORKDIR /app
EXPOSE 8080
CMD ["openresty", "-p", "/app", "-c", "conf/nginx.conf", "-g", "daemon off;"]
```

## Teknik Kararlar

| Karar | Neden |
|---|---|
| 28xxx host port bloğu | 8080/3000/5432 çakışmasını önler; `check-ports.sh` erken hata |
| `shared/src` → `/app/lib/pg_shared` | Backend `require("pg_shared.*")`, frontend `pg_shared.*` bundle |
| `lua_code_cache on` hep | Ayrı dev/prod conf yok; `make api.reload` |
| `pgdata` volume | Meta DB kalıcı; hedef DB'ler harici |

## DoD

- [ ] `make setup && make up` → 4 servis `healthy`/running, `curl localhost:28100/api/v1/health` → `200 ok` (veya .env.example 28000/28080).
- [ ] `JWT_SECRET` eksikken api başlamaz, logda `Konfigürasyon hatası`.
- [ ] `luacheck` staged dosyalarda pre-commit'te koşar.
- [ ] `.env.example` ile `config.lua` SPEC birebir (CI `make conf.env` diff).
- [ ] `make ports.check` dolu portta fail, hangi konteyner tutuyor yazar.
- [ ] Yerel .env 28100/28180/25532/28125 ile varsayılan 28000/28080 çakışması önlenir (host port bloğu 28xxx, yerel override 281xx).
