-- Entegrasyon test yardimcilari: HTTP client, login, DB reset (pgmoon/luasocket), MailHog okuma
-- Testler container disindan kosar: API http://localhost:28080, PG 127.0.0.1:25432, MailHog :28025
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local mime = require("mime")
local cjson = require("cjson.safe")
local pgmoon = require("pgmoon")

local _M = {}
_M.base = os.getenv("API_URL") or ("http://localhost:" .. (os.getenv("API_HOST_PORT") or "28080") .. "/api/v1")
_M.mailhog = os.getenv("MAILHOG_URL") or ("http://localhost:" .. (os.getenv("MAILHOG_UI_HOST_PORT") or "28025"))

_M.ADMIN = { email = "admin@pgeditor.local", password = "Admin123!" }
_M.USER = { email = "editor@pgeditor.local", password = "Editor123!" }

function _M.request(method, path, body, token, extra_headers)
  local headers = { ["User-Agent"] = "busted-it" }
  for k, v in pairs(extra_headers or {}) do headers[k] = v end
  if token then headers["Authorization"] = "Bearer " .. token end
  local body_str
  if body ~= nil then
    body_str = type(body) == "string" and body or cjson.encode(body)
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    headers["Content-Length"] = tostring(#body_str)
  end
  local chunks = {}
  local _, status, resp_headers = http.request({
    url = _M.base .. path, method = method, headers = headers,
    source = body_str and ltn12.source.string(body_str) or nil,
    sink = ltn12.sink.table(chunks),
  })
  local raw = table.concat(chunks)
  return { status = status, body = #raw > 0 and cjson.decode(raw) or nil, raw = raw, headers = resp_headers or {} }
end

function _M.code(res)
  return res.body and res.body.error and res.body.error.code
end

function _M.login(email, password)
  local res = _M.request("POST", "/auth/login", { email = email, password = password })
  if res.status == 200 and res.body and res.body.data then return res.body.data end
  return nil, res
end

function _M.login_admin() return assert(_M.login(_M.ADMIN.email, _M.ADMIN.password)) end
function _M.login_user() return assert(_M.login(_M.USER.email, _M.USER.password)) end

function _M.db()
  local pg = pgmoon.new({
    host = os.getenv("TEST_DB_HOST") or "127.0.0.1",
    port = tonumber(os.getenv("TEST_DB_PORT") or os.getenv("DB_HOST_PORT") or "25432"),
    database = os.getenv("DB_NAME") or "pgeditor",
    user = os.getenv("DB_USER") or "pgeditor",
    password = os.getenv("DB_PASSWORD"),
  })
  assert(pg:connect())
  return pg
end

function _M.sql(q, ...)
  local pg = _M.db()
  local res, err = pg:query(q, ...)
  pg:disconnect()
  if res == nil then error("sql hatasi: " .. tostring(err), 2) end
  return res
end

local function restore_rbac()
  local types = require("pg_shared.types")
  local token = _M.login_admin().access_token
  for _, role in ipairs(types.ROLES) do
    for _, page in ipairs(types.PAGES) do
      local res = _M.request("PATCH", "/rbac/matrix/" .. role .. "/" .. page,
        { can_access = types.default_permission(role, page) }, token)
      assert(res.status == 200, "rbac restore " .. role .. "/" .. page .. ": " .. tostring(res.status) .. " " .. res.raw)
    end
  end
end

function _M.reset_db()
  if os.getenv("APP_ENV") ~= "test" then error("reset_db yalnizca APP_ENV=test iken calisir", 2) end
  -- Asil koruma: hedef API test yigininda mi (make up.e2e: tmpfs DB)? Degilse gelistirme verisi silinirdi.
  local health = _M.request("GET", "/health")
  if not (health.body and health.body.test_mode == true) then
    error("reset_db: API test modunda degil (gelistirme yigini?) — veri korunuyor. "
      .. "Once 'make up.e2e', ya da 'make test.integration' kullanin.", 2)
  end
  local pg = _M.db()
  assert(pg:query("TRUNCATE audit_logs, query_history, password_reset_tokens RESTART IDENTITY CASCADE"))
  assert(pg:query("TRUNCATE connections RESTART IDENTITY CASCADE"))
  assert(pg:query("DELETE FROM users WHERE email NOT IN ($1, $2)", _M.ADMIN.email, _M.USER.email))
  assert(pg:query("UPDATE users SET is_active = true, role = 'admin' WHERE email = $1", _M.ADMIN.email))
  assert(pg:query("UPDATE users SET is_active = true, role = 'editor' WHERE email = $1", _M.USER.email))
  pg:disconnect()
  restore_rbac()
end

local seq = 0
function _M.unique_email(prefix)
  seq = seq + 1
  return string.format("%s-%d-%d@pgeditor.local", prefix or "it", os.time(), seq + math.random(1e6))
end

function _M.unique_ip()
  return string.format("10.%d.%d.%d", math.random(0, 255), math.random(0, 255), math.random(1, 254))
end

function _M.create_user(admin_token, fields)
  local body = { email = _M.unique_email("u"), password = "Test1234!", role = "editor", full_name = "IT" }
  for k, v in pairs(fields or {}) do body[k] = v end
  local res = _M.request("POST", "/users", body, admin_token)
  assert(res.status == 201, "create_user: " .. tostring(res.status) .. " " .. res.raw)
  res.body.data.password = body.password
  return res.body.data
end

function _M.audit(admin_token, qs)
  local res = _M.request("GET", "/audit/logs?per_page=100&" .. (qs or ""), nil, admin_token)
  assert(res.status == 200, "audit list: " .. tostring(res.status) .. " " .. res.raw)
  return res.body.data
end

local function mh_get(path)
  local chunks = {}
  http.request({ url = _M.mailhog .. path, sink = ltn12.sink.table(chunks) })
  return cjson.decode(table.concat(chunks))
end

function _M.mail_count(to)
  local d = mh_get("/api/v2/search?kind=to&query=" .. to)
  return d and d.total or 0
end

function _M.mail_body(to, timeout)
  local deadline = socket.gettime() + (timeout or 2)
  repeat
    local d = mh_get("/api/v2/search?kind=to&query=" .. to)
    if d and d.items and d.items[1] then
      local raw = d.items[1].Content.Body
      local out = { (raw:gsub("=\r?\n", ""):gsub("=3D", "=")) }
      for b64 in raw:gmatch("Content%-Transfer%-Encoding: base64\r?\n\r?\n([%w%+/=\r\n]+)") do
        out[#out + 1] = mime.unb64((b64:gsub("%s", ""))) or ""
      end
      return table.concat(out, "\n")
    end
    socket.sleep(0.1)
  until socket.gettime() > deadline
  return nil
end

function _M.reset_token_from_mail(to)
  local body = _M.mail_body(to)
  return body and body:match("reset%-password%?token=(%x+)"), body
end

_M.now = socket.gettime
_M.null = cjson.null

return _M
