# ═══ FAZ 30 — PERFORMANS, ZAMAN AŞIMI & GÜVENLİK SERTLEŞTİRME ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — env §6, dict §9 (`query_rate_limit`, `completion_cache`), error §5 (`RATE_LIMITED` 429, `QUERY_FAILED`), §11 madde 23.
> Analiz: [faz-24](faz-24-spec-analizi-bosluk-haritasi.md) §Güvenlik & Performans.

## Amaç

Spec §4 (yapılandırılabilir sorgu zaman aşımı), §8 (CORS, rate limiting, `.env` sızıntısı, read-only bağlantı kullanıcısı)
ve §9 (nesne listelerinde performans) maddelerini kapatmak; F25 kategori endpoint'lerini bench'lemek.

## Önkoşullar

- F25 (kategori endpoint'leri), F27 (hata eşlemesi), F15 (bench altyapısı `api/bench`).

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `api/src/config.lua` | `QUERY_STATEMENT_TIMEOUT_MS` (int, default 30000), `RATE_LIMIT_RPS` (int, default 10) |
| `api/src/db/pool_manager.lua` | bağlantı açılışında `SET statement_timeout` |
| `api/src/db/target/query.lua` | `57014` + "statement timeout" → mesaj "Sorgu zaman aşımına uğradı (N sn)" |
| `api/conf/nginx.conf` | `limit_req_zone` + `/api/v1/query/execute`, `/api/v1/query/csv` için `limit_req` |
| `api/src/middleware/error_handler.lua` | nginx 429 → `RATE_LIMITED` zarfı (`error_page 429`) |
| `.env.example`, `docs/fazlar/00-genel-bakis.md` §6 | yeni env'ler |
| `docs/security-checklist.md`, `docs/operations.md` | read-only hedef rol, CORS kontrolü |
| `api/bench/schema_categories.lua` | wrk senaryosu |
| `api/spec/config_spec.lua`, `api/spec/integration/timeout_spec.lua` | testler |

## Sorgu Zaman Aşımı

Bugün `QUERY_TIMEOUT_MS` yalnız socket timeout'tur (`pool_manager.lua:135,174-177`): sunucu sorguyu sürdürür, istemci kopar.

- `pool_manager` yeni bağlantı açılışında (`connect` sonrası, `SET application_name` ile aynı yerde):
  `SET statement_timeout = <QUERY_STATEMENT_TIMEOUT_MS>`; havuzdan gelen bağlantıda tekrar set edilmez (oturum kalıcı).
- Sorgu iptali/timeout SQLSTATE `57014`: `db_message` "canceling statement due to statement timeout" içeriyorsa mesaj
  `Sorgu zaman aşımına uğradı (30 sn)`; aksi halde mevcut "Sorgu iptal edildi".
- Socket timeout `QUERY_TIMEOUT_MS` ≥ `QUERY_STATEMENT_TIMEOUT_MS` olmalı; `config.load` ihlalde WARN loglar
  (`c.warnings[]`). Varsayılanlar eşit (30000) olduğu için `+1000` payı istenmedi.
- Katalog sorguları (F25) aynı oturumda koştuğundan aynı limite tabidir (istenen davranış).
- `.env.example`: `QUERY_STATEMENT_TIMEOUT_MS=30000`.

## Rate Limiting

Mevcut: `query_rate_limit` dict — kullanıcı+bağlantı başına dakikalık sayaç (`query_service.lua:26`), uygulama seviyesi.
Eksik: IP bazlı, kimliksiz istekler (login'de ayrı `rate_limit` var) ve export akışı için nginx seviyesi.

```nginx
# http {}
limit_req_zone $binary_remote_addr zone=api_exec:10m rate=${RATE_LIMIT_RPS}r/s;
# location /api/v1/query/execute ve /api/v1/query/csv
limit_req zone=api_exec burst=20 nodelay;
limit_req_status 429;
error_page 429 = @rate_limited;   # error_handler zarfı: { error: { code: "RATE_LIMITED", ... } }
```

`RATE_LIMIT_RPS` `conf.env` ile nginx'e geçer (mevcut `make conf.env` mekanizması). `0` → `limit_req` satırları
şablondan düşer (dev/test).

## CORS ve `.env` Sızıntısı

- `CORS_ORIGINS` zaten frontend origin listesi; prod `*` reddediliyor (`config.lua:140-141`). DoD'a doğrulama.
- Web bundle env okumaz; DoD: `grep -rE "DB_PASSWORD|JWT_SECRET|ENCRYPTION_KEY" web/public/` boş; `make web.size` raporunda `.env` yok.
- API `/api/v1/config` benzeri bir endpoint **yoktur**; frontend `js.config()` yalnız `build`/`version` verir (`layout` Sistem kartı).

## Read-only Hedef Kullanıcı (öneri)

`docs/security-checklist.md`'ye madde; `docs/operations.md`'ye örnek:

```sql
CREATE ROLE pgeditor_ro LOGIN PASSWORD '…';
GRANT CONNECT ON DATABASE app TO pgeditor_ro;
GRANT USAGE ON SCHEMA public TO pgeditor_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgeditor_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO pgeditor_ro;
ALTER ROLE pgeditor_ro SET default_transaction_read_only = on;
```

Uygulama zorlamaz; bağlantı formunda (F6) "Salt okunur öneri" bilgi metni ve `default_transaction_read_only` tespitinde
bağlantı kartında `RO` rozeti (mevcut `test` endpoint'i `SHOW default_transaction_read_only` ekler).

## Performans

- Kategori sayaçları (`categories:` cache) `COMPLETION_CACHE_TTL` ile; bench hedefi: cache hit p95 < 10 ms, miss < 150 ms
  (500 tablolu demo şema).
- `GET …/objects?category=` `limit` tavanı 500; bench p95 < 80 ms.
- `api/bench/schema_categories.lua` (wrk): `/categories` + `/objects?category=tables` karışık; `make bench` raporuna eklenir.
- Frontend: ağaçta 1.000 nesne render'ı < 50 ms (`dom.lua` keyed diff; kategori kapalıyken DOM'da yok).

## Test

- `api/spec/config_spec.lua` (mevcut `validation`/`connection` spec deseni): env varsayılanları; `QUERY_TIMEOUT_MS <
  QUERY_STATEMENT_TIMEOUT_MS` uyarısı; `RATE_LIMIT_RPS=0` şablonu.
- `api/spec/integration/timeout_spec.lua` (**yalnız `make up.e2e`**): `QUERY_STATEMENT_TIMEOUT_MS=1000` ile
  `SELECT pg_sleep(3)` → 400/`QUERY_FAILED`, `details.sqlstate="57014"`, mesaj "zaman aşımı".
- e2e (`up.e2e` yığını): 30 hızlı `execute` isteği → en az biri 429 `RATE_LIMITED`; UI toast "Çok fazla istek".
- Bench çıktısı `docs/operations.md`'de tablo.

## DoD

- [ ] `SET statement_timeout` her yeni hedef bağlantıda; `pg_sleep(35)` 30 sn'de `57014` + "zaman aşımı" mesajı.
- [ ] `QUERY_STATEMENT_TIMEOUT_MS` `.env.example`, `config.lua`, 00 §6'da; `QUERY_TIMEOUT_MS` ile tutarlılık uyarısı.
- [ ] nginx `limit_req` execute/csv'de; 429 zarfı `RATE_LIMITED`; `RATE_LIMIT_RPS=0` ile devre dışı.
- [ ] Prod config'de `CORS_ORIGINS=*` reddedilir (mevcut testle kanıt).
- [ ] `web/public` içinde gizli env değeri yok (grep DoD).
- [ ] Read-only rol reçetesi `operations.md`'de; bağlantı kartında `RO` rozeti.
- [ ] Bench: kategori sayaç cache hit p95 < 10 ms; `objects?category=` p95 < 80 ms.
- [ ] `make lint && make test`; entegrasyon spec'i e2e yığınında yeşil.
