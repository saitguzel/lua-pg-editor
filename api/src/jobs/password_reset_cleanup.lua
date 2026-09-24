-- Password reset token temizligi (pg-editor F14)
local config = require("config")
local query = require("db.query")

local _M = {}

_M.NAME = "password_reset_cleanup"
_M.ADVISORY_LOCK_KEY = 727727003
_M.CHECK_INTERVAL = 3600

function _M.run_once()
  local started = ngx.now()
  -- expired veya kullanilmis 7 gunden eski tokenlari sil
  local res, err = query.query(
    [[DELETE FROM password_reset_tokens WHERE expires_at < NOW() OR (used_at IS NOT NULL AND created_at < NOW() - INTERVAL '7 days') RETURNING 1]]
  )
  if not res then return nil, err and err.message or tostring(err) end
  local total = #res
  local duration_ms = math.floor((ngx.now() - started) * 1000)
  collectgarbage("collect")
  return { deleted = total, duration_ms = duration_ms }
end

function _M.start()
  if ngx.worker.id() ~= 0 then return true end
  local function tick(premature)
    if premature then return end
    local ok, row = pcall(query.query_one, "SELECT pg_try_advisory_lock($1::bigint) AS locked", tostring(_M.ADVISORY_LOCK_KEY))
    local locked = ok and row and (row.locked == true or row.locked == "t")
    if locked then
      local r, e = _M.run_once()
      pcall(query.exec, "SELECT pg_advisory_unlock($1::bigint)", tostring(_M.ADVISORY_LOCK_KEY))
      if not r then ngx.log(ngx.ERR, "[job] password_reset_cleanup " .. tostring(e))
      else ngx.log(ngx.INFO, "[job] password_reset_cleanup deleted=" .. (r.deleted or 0)) end
    else
      ngx.log(ngx.INFO, "[job] password_reset_cleanup lock busy")
    end
    local delay = 86400
    -- her gun ayni saatte calis (cleanup_hour)
    local c = config.get()
    local hour = c and c.audit and c.audit.cleanup_hour or 3
    local now = ngx.time()
    local now_t = os.date("!*t", now)
    local today_at_hour = now - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec) + hour * 3600
    if today_at_hour > now then delay = today_at_hour - now else delay = today_at_hour + 86400 - now end
    if delay < 60 then delay = 60 end
    ngx.timer.at(delay, tick)
  end
  ngx.timer.at(1, tick)
  return true
end

return _M
