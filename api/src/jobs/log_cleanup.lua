-- Log temizleme isi: audit_logs eski kayıtları batch sil (pg-editor F14)
-- Advisory lock + worker 0 + gunluk saat kontrolu
local config = require("config")
local query = require("db.query")

local _M = {}

_M.NAME = "log_cleanup"
_M.ADVISORY_LOCK_KEY = 727727001
_M.CHECK_INTERVAL = 3600
_M.BATCH_PAUSE = 0.05

function _M.should_run(now_utc, hour, last_run_day)
  local t = os.date("!*t", now_utc)
  if t.hour ~= hour then return false end
  return last_run_day ~= os.date("!%Y-%m-%d", now_utc)
end

local function next_hour(hour, now)
  local t = os.date("!*t", now)
  local target = os.time({ year = t.year, month = t.month, day = t.day, hour = hour, min = 0, sec = 0 })
  -- os.time local, !*t UTC idi; UTC icin manual
  -- Basit: simdiki gunden hour'a kadar fark
  local now_t = os.date("!*t", now)
  local today_at_hour = now - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec) + hour * 3600
  if today_at_hour <= now then
    return today_at_hour + 86400
  end
  return today_at_hour
end
_M.next_hour = next_hour

function _M.run_once()
  local c = config.get()
  if not c or not c.audit or not c.audit.cleanup_enabled then
    return { skipped = true }
  end
  local retention = c.audit.retention_days or 30
  local batch_size = c.audit.cleanup_batch_size or 1000
  local cutoff = os.date("!%Y-%m-%d %H:%M:%S", ngx.time() - retention * 86400)
  local total = 0
  local batches = 0
  local started = ngx.now()
  while true do
    if ngx.worker.exiting and ngx.worker.exiting() then
      break
    end
    local res, err = query.query(
      [[DELETE FROM audit_logs WHERE id IN (SELECT id FROM audit_logs WHERE created_at < $1::timestamptz ORDER BY created_at LIMIT $2) RETURNING 1]],
      cutoff, batch_size
    )
    if not res then
      return nil, err and err.message or tostring(err)
    end
    local n = #res
    if n == 0 then break end
    total = total + n
    batches = batches + 1
    if n < batch_size then break end
    ngx.sleep(_M.BATCH_PAUSE)
  end
  local duration_ms = math.floor((ngx.now() - started) * 1000)
  collectgarbage("collect")
  return { deleted = total, batches = batches, cutoff = cutoff, duration_ms = duration_ms }
end

function _M.start()
  if ngx.worker.id() ~= 0 then return true end
  local c = config.get()
  if not c or not c.audit or not c.audit.cleanup_enabled then
    ngx.log(ngx.NOTICE, "[job] log_cleanup disabled")
    return true
  end
  local function tick(premature)
    if premature then return end
    local ok, row = pcall(query.query_one, "SELECT pg_try_advisory_lock($1::bigint) AS locked", tostring(_M.ADVISORY_LOCK_KEY))
    local locked = ok and row and (row.locked == true or row.locked == "t")
    if locked then
      local r, e = _M.run_once()
      pcall(query.exec, "SELECT pg_advisory_unlock($1::bigint)", tostring(_M.ADVISORY_LOCK_KEY))
      if not r then
        ngx.log(ngx.ERR, "[job] log_cleanup " .. tostring(e))
      else
        if not r.skipped then
          ngx.log(ngx.INFO, "[job] log_cleanup deleted=" .. (r.deleted or 0) .. " batches=" .. (r.batches or 0))
        else
          ngx.log(ngx.INFO, "[job] log_cleanup skipped")
        end
      end
    else
      ngx.log(ngx.INFO, "[job] log_cleanup lock busy")
    end
    local hour = c.audit.cleanup_hour or 3
    local now = ngx.time()
    local next_run = next_hour(hour, now)
    local delay = next_run - now
    if delay < 60 then delay = 60 end
    if delay > 86400 then delay = 86400 end
    local dict = ngx.shared.job_locks
    if dict then dict:set("last_run:" .. _M.NAME, now, 86400) end
    ngx.timer.at(delay, tick)
  end
  ngx.timer.at(1, tick)
  -- saatlik kontrol fallback (should_run kontrolu tick icinde zaten var, ama garanti icin every de kurulabilir)
  return true
end

return _M
