# ═══ FAZ 14 — SCHEDULED JOBS ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — env AUDIT_* , QUERY_HISTORY_*, job_locks.

## Amaç

Periyodik bakım: audit log temizliği, sorgu geçmişi temizliği, eski password_reset token temizliği, bağlantı test sonuçlarının eskimesi. `init_worker(worker 0)` + advisory lock ile çok instance güvenli.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `api/src/jobs/log_cleanup.lua` | audit_logs eski kayıtları batch sil |
| `api/src/jobs/query_history_cleanup.lua` | query_history retention |
| `api/src/jobs/password_reset_cleanup.lua` | expired token temizliği |
| `api/src/jobs/init.lua` | tüm job'ları timer'a bağla |

## Ortak Desen (job template)

```lua
local ngx = ngx
local config = require("config")
local query = require("db.query")
local log = require("middleware.logger")
local _M = {}
_M.NAME = "log_cleanup"
function _M.run_once()
  local c = config.get()
  if not c.audit.cleanup_enabled then return { skipped=true } end
  local cutoff = os.date("!%Y-%m-%d %H:%M:%S", ngx.time() - c.audit.retention_days*86400)
  local total = 0
  while true do
    local res, err = query.exec("DELETE FROM audit_logs WHERE id IN (SELECT id FROM audit_logs WHERE created_at < $1 LIMIT $2)", cutoff, c.audit.cleanup_batch_size)
    if not res then return nil, err end
    if res == 0 then break end
    total = total + res
    if res < c.audit.cleanup_batch_size then break end
    ngx.sleep(0.05) -- DB nefes alsın
  end
  collectgarbage("collect")
  return { deleted=total, cutoff=cutoff }
end
function _M.start()
  if ngx.worker.id() ~= 0 then return end
  local function tick(premature)
    if premature then return end
    -- advisory lock: pg_try_advisory_lock(hashtext('log_cleanup'))
    local ok = query.query_one("SELECT pg_try_advisory_lock($1) AS locked", 727727001)
    if not ok or not ok.locked then ngx.log(ngx.INFO, "[job] log_cleanup lock busy"); goto resched end
    local r, e = _M.run_once()
    query.exec("SELECT pg_advisory_unlock($1)", 727727001)
    if not r then ngx.log(ngx.ERR, "[job] ".._M.NAME.." "..tostring(e)) else ngx.log(ngx.INFO, "[job] ".._M.NAME.." deleted="..(r.deleted or 0)) end
    ::resched::
    local hour = config.get().audit.cleanup_hour -- UTC 0-23
    local now = ngx.time(); local next_run = next_hour(hour, now)
    local delay = next_run - now
    ngx.shared.job_locks:set("last_run:".._M.NAME, now)
    ngx.timer.at(delay, tick)
  end
  -- ilk çalıştırma: init_worker 1 sn sonra, sonraki her gün aynı saat
  ngx.timer.at(1, tick)
end
return _M
```

`query_history_cleanup`:

```sql
DELETE FROM query_history WHERE executed_at < NOW() - INTERVAL '1 day' * $1 LIMIT $2
-- $1 = QUERY_HISTORY_RETENTION_DAYS
```

`password_reset_cleanup`:

```sql
DELETE FROM password_reset_tokens WHERE expires_at < NOW() OR used_at IS NOT NULL AND created_at < NOW() - INTERVAL '7 days'
```

`connection_test_stale`: opsiyonel — `last_tested_at < NOW() - INTERVAL '7 days'` olanları istatistik için flagler.

## lua.conf entegrasyonu

```nginx
init_worker_by_lua_block {
  require("db.pool").warm(5)
  require("jobs.log_cleanup").start()
  require("jobs.query_history_cleanup").start()
  require("jobs.password_reset_cleanup").start()
}
```

`job_locks` dict `lock:log_cleanup` ve `last_run:...` için.

## Makefile

```makefile
job.cleanup:
	docker compose exec -T api resty -I /app/src -I /app/lib --shdict 'job_locks 1m' -e 'local c=require("config"); c.current=c.load(); require("db.pool").configure(c.current.db); local r,e=require("jobs.log_cleanup").run_once(); print(require("cjson").encode(r or {error=e}))'
```

## DoD

- [ ] `make job.cleanup` → `{ deleted: N }`, DB'de eski audit yok.
- [ ] `AUDIT_CLEANUP_ENABLED=false` → job skip, log "skipped".
- [ ] İki api replika → yalnızca biri `pg_try_advisory_lock` alır (diğer log "lock busy").
- [ ] `QUERY_HISTORY_RETENTION_DAYS=1` + job → eski sorgular silinir.
- [ ] Prod `AUDIT_CLEANUP_HOUR=3` UTC → timer doğru saate kurulur.
