-- Uygulama giriş noktası: glue.js tarafından require("main") ile çağrılır.
-- Global hata yakalayıcıyı kurar, uygulamayı başlatır (F16/F17).

local function log(level, ...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  js.log(level, table.concat(parts, " "))
end

-- Lua 5.4 kontrolü: shared kod alt kümede yazıldı ama frontend 5.4 varsayar
assert(_VERSION == "Lua 5.4", "Beklenmeyen Lua sürümü: " .. tostring(_VERSION))

local ok, err = xpcall(function()
  local types = require("pg_shared.types") -- paketleme doğrulaması
  local app = require("app")
  local json = require("json")
  local cfg = js.config() and json.decode(js.config()) or {}
  app.start({ apiBase = cfg.apiBase or "/api/v1" })
  -- İlk yüklemede shared'in geldiğini göster (F16 stub kanıtı app.start içinde)
  log("info", "main.lua basladi, PAGES=", #types.PAGES)
end, debug.traceback)

if not ok then
  log("error", "Başlatma hatası: " .. tostring(err))
  local root = js.dom.byId("app")
  if root then js.dom.setText(root, "Beklenmeyen bir hata oluştu.") end
end
