# Güvenlik Kontrol Listesi — pgLua (Canlıya Çıkış)

> Bu checklist `faz-23` ve `00-genel-bakis`'ın yaşayan kopyasıdır; her release öncesi işaretlenmelidir.

## 1. Kimlik Doğrulama & Parola

- [ ] `JWT_SECRET` prod örneği değil (dev-secret... reddedilir).
- [ ] `JWT_SECRET` ≥32 byte, `ENCRYPTION_KEY` 32 byte (base64 decode 32).
- [ ] `Argon2` prod `M_COST=15` (32 MiB) veya daha yüksek; login rate limit aktif (5/dk).
- [ ] `PASSWORD_RESET_TTL` ≤3600, token tek kullanımlık + sha256 saklanır.
- [ ] `LOGIN_RATE_LIMIT` prod'da 5, `LOCKOUT` sonrası `Retry-After` header döner.
- [ ] `is_active=false` hesaplar login 403 `ACCOUNT_DISABLED`.

## 2. Yetkilendirme (RBAC)

- [ ] `rbac.matrix` admin kilidi test edildi (`admin→rbac.matrix false` → 409).
- [ ] `LAST_ADMIN` guard (son admin sil/pasif/düşür → 409).
- [ ] `SELF_ACTION_FORBIDDEN` (kendi sil/düşür → 409).
- [ ] `authorization` middleware her yazma endpointinde `requires(page_key)` var (grep).
- [ ] `CONNECTION_NOT_FOUND` 404 başkasının bağlantısı için de 404 (enumeration yok).

## 3. Veri Koruma & Şifreleme

- [ ] `connections.password_encrypted` AES-256-GCM, düz parola hiçbir yerde (log, audit, response) yok.
- [ ] `ENCRYPTION_KEY` `_FILE` ile secrets, düz env'ye fallback yok (warn log).
- [ ] Backup dump'ları şifreli veya volume şifreli diskte; `backups/` izin 700.
- [ ] `audit_logs.old_value/new_value` maskeli (`password`, `secret`, `token` → `***`).
- [ ] Query string loglanmıyor (`GET /audit/logs?search=` logda yok).

## 4. Ağ & TLS

- [ ] `CORS_ORIGINS` prod `*` değil, yalnızca `https://pg.example.com`.
- [ ] `TRUSTED_PROXIES` proxy IP, `X-Forwarded-For` spoof engelli.
- [ ] TLS `proxy/nginx.conf` `TLS1.2+1.3`, `HSTS` 63072000, `X-Content-Type-Options nosniff`, `X-Frame-Options DENY`.
- [ ] CSP `default-src 'self'; script-src 'self' 'wasm-unsafe-eval';` (unsafe-eval yok).
- [ ] `client_max_body_size 1m` (nginx) + `PAYLOAD_TOO_LARGE` 413.
- [ ] `DB_SSL` prod `true` (meta DB), hedef DB'ler `sslmode=prefer` (kullanıcı host'una bağlı).

## 5. SQL & Enjeksiyon

- [ ] Meta DB tüm sorgular parametreli `$1..` (grep `..sql..` → `$` yoksa red).
- [ ] Hedef DB `WHERE` builder whitelist + `$?` → `$n`; `ORDER BY` kolon whitelist.
- [ ] `custom_where` `safe_sql` + `;` yasak + `SELECT` yasak; `sql_parser` testli.
- [ ] `quote_ident` ile DDL (`ALTER TABLE`, `DROP`) — ham interpolate yok.
- [ ] `CSV export` `BEGIN READ ONLY` + `COPY` → yazma engelli; `READONLY_VIOLATION` 422.

## 6. Rate Limit & DoS

- [ ] `login` 5/dk, `query` 30/dk per connection (query_rate_limit dict).
- [ ] F30: `RATE_LIMIT_RPS` prod'da > 0 (varsayılan 10 r/s, burst 20) — `execute`/`csv` IP başına 429 `RATE_LIMITED`.
- [ ] F30: `QUERY_STATEMENT_TIMEOUT_MS` ≤ 30000 ve `QUERY_TIMEOUT_MS` ondan küçük değil (açılış logunda uyarı yok).
- [ ] F30: hedef bağlantılar salt okunur rol ile (operations.md §8); bağlantı testinde `read_only=true` → kartta `RO` rozeti.
- [ ] `QUERY_ROW_LIMIT_MAX` 50000 clamp, `QUERY_MAX_BYTES` 100KB, `CSV_MAX_ROWS` 100k.
- [ ] `DB_POOL_SIZE` × `worker_processes` × `replicas` ≤ `max_connections-10` (00 §11 #5).
- [ ] `TARGET_POOL_SIZE` 5, `TARGET_POOL_MAX` 32 LRU → harici DB DoS yok.

## 7. Log & İzleme

- [ ] `LOG_FORMAT=json` prod, her satır `req_id`, `user_id`, `ip`.
- [ ] `audit_logs` retention 30 gün, `query_history` 30 gün, job her gün 03:00 UTC.
- [ ] `/metrics` proxy `deny all`, `/health/ready` Uptime Kuma'da.
- [ ] `trivy fs` + `trivy image` HIGH/CRITICAL 0, `gitleaks` secret 0.

## 8. Operasyon

- [ ] `.env.prod` 600, `secrets/*` 600, `TRUSTED_PROXIES` doğru.
- [ ] Backup günlük + pre-deploy, restore tatbikatı yapıldı (`operations.md` §4).
- [ ] `SEED_DEFAULTS` prod `false` (demo kullanıcı yok).
- [ ] `LOG_LEVEL` prod `info` (debug değil).

## 9. Frontend

- [ ] `innerHTML` yok, `textContent` + `createTextNode` → XSS yok.
- [ ] `Wasmoon` `injectObjects:false` (js null → nil).
- [ ] `localStorage` şifresiz; token `httpOnly` cookie değil — XSS sonrası token theft riski kabul edildi, CSP ile mitigasyon.
- [ ] `autocomplete` katalogu yetkisiz isteğe 403 döner.

## İmza

- [ ] İnceleyen: ________  Tarih: ________
- [ ] Onay: ________
