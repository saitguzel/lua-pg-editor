-- Tum job'lari baslatir (pg-editor F14)
local _M = {}

function _M.start_all()
  local jobs = {
    "jobs.log_cleanup",
    "jobs.query_history_cleanup",
    "jobs.password_reset_cleanup",
  }
  for _, name in ipairs(jobs) do
    local ok, mod = pcall(require, name)
    if not ok then
      ngx.log(ngx.ERR, "job yuklenemedi: " .. name .. " " .. tostring(mod))
    else
      local ok2, started, err = pcall(mod.start)
      if not ok2 or not started then
        ngx.log(ngx.ERR, "job start hatasi: " .. name .. " " .. tostring(ok2 and err or started))
      end
    end
  end
  return true
end

return _M
