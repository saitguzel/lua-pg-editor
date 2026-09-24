# ═══ FAZ 12 — AUDIT LOG & MIDDLEWARE ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — audit olayları §8, ngx.ctx §10.

## Amaç

Tüm yazma ve auth eylemlerini izlenebilir kılmak: context, kayıt, listeleme, filtre, export, ve `access.denied` otomatiği.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/middleware/audit_context.lua` | ip, user_agent → ngx.ctx.audit |
| `api/src/services/audit_service.lua` | record, list, stats, export |
| `api/src/repositories/audit_repo.lua` | insert, find, stats, export_cursor |
| `api/src/handlers/audit.lua` | list, get, stats, export |
| `api/src/models/audit.lua` | serialize, mask |

## Middleware

```lua
-- audit_context.lua (zincir 3. halka, logger'dan sonra, auth'tan önce)
function _M.handle(self)
  local ip = ngx.var.remote_addr
  -- TRUSTED_PROXIES içindeyse X-Forwarded-For ilk IP
  local xff = ngx.var.http_x_forwarded_for
  if xff and trusted(ngx.var.remote_addr) then ip = xff:match("^[^,]+") or ip end
  ngx.ctx.audit = { ip = ip, user_agent = ngx.var.http_user_agent or "-" }
end
```

`middleware/logger.lua` zaten `req_id`, `started_at` yazar.

## audit_service.record

```lua
function _M.record(action, entity_type, entity_id, old_value, new_value, opts)
  -- opts.status = "success"|"failure", opts.error_message
  -- mask: recursive, case-insensitive, keys: password, password_hash, token, secret, password_encrypted
  -- old/new JSONB (pgmoon json deserializer)
  -- user_id = ngx.ctx.identity.user_id (yoksa nil)
  -- ip, user_agent = ngx.ctx.audit
  -- req_id = ngx.ctx.req_id
  -- INSERT audit_logs (...) VALUES (...)
  -- failure da kaydedilir (status failure)
end
```

Her service çağrısı `audit_service.record` yapar; middleware `authorization` reddi otomatik `access.denied`.

## Endpointler

| Metod | Path | Page | Açıklama |
|---|---|---|---|
| `GET` | `/audit/logs` | `audit.logs` | Liste `?page&per_page&action&entity_type&user_id&from&to&search` |
| `GET` | `/audit/logs/:id` | `audit.logs` | Detay |
| `GET` | `/audit/stats` | `audit.logs` | Aggregate: by_action, by_user, by_day |
| `GET` | `/audit/export` | `audit.logs` | CSV streaming `?from&to&action...` |

`GET /audit/logs` params: `action` enum `AUDIT_ACTIONS`, `entity_type` enum, `from`/`to` ISO8601, `search` ILIKE `payload`.

`stats` için paralel `ngx.thread.spawn` 3 sorgu:

```sql
SELECT action, count(*) FROM audit_logs WHERE created_at BETWEEN $1 AND $2 GROUP BY action;
SELECT user_id, count(*) ... GROUP BY user_id;
SELECT date_trunc('day', created_at), count(*) ... GROUP BY 1 ORDER BY 1;
```

## Masking & PII

- `old_value`/`new_value` JSONB içinde `password` → `"***"`.
- `ip` INET tipinde, `user_agent` text.

## Teknik Kararlar

| Karar | Neden |
|---|---|
| Audit sync (transaction içinde) | Kayıp audit → compliance ihlali; performans feda |
| Failure da kaydet | `auth.login.failure` brute force analizi |
| X-Forwarded-For yalnızca TRUSTED_PROXIES | Spoof önleme |
| Export streaming | Büyük audit CSV bellek değil |

## DoD

- [ ] `POST /connections` → `audit_logs`te `connection.create` success satırı.
- [ ] `POST /auth/login` yanlış parola → `auth.login.failure` failure status.
- [ ] RBAC reddi → `access.denied` + `403 FORBIDDEN`.
- [ ] `GET /audit/logs?action=connection.create` filtreler.
- [ ] `GET /audit/logs/:id` detay `old_value`/`new_value` maskeli.
- [ ] `GET /audit/stats` paralel 3 sorgu <50ms.
- [ ] `GET /audit/export` CSV streaming, `Content-Disposition: attachment`.
