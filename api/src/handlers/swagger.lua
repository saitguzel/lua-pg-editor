-- Swagger/OpenAPI handler'lar: spec JSON ve UI (pg-editor F13)
local cjson = require("cjson.safe")
local spec = require("openapi.spec")

local _M = {}
local cached_json
local cached_html
local cached_csp

-- try to use resty.sha256 if available for CSP, else dummy
local function csp_for(html)
  local ok, sha256_mod = pcall(require, "resty.sha256")
  if not ok or not sha256_mod then
    return "default-src 'none'; script-src https://cdn.jsdelivr.net 'unsafe-inline'; style-src https://cdn.jsdelivr.net 'unsafe-inline'; img-src 'self' data: https://cdn.jsdelivr.net; connect-src 'self'; font-src https://cdn.jsdelivr.net; frame-ancestors 'none'"
  end
  local hashes = {}
  for body in html:gmatch("<script>(.-)</script>") do
    local h = sha256_mod:new()
    h:update(body)
    hashes[#hashes + 1] = "'sha256-" .. ngx.encode_base64(h:final()) .. "'"
  end
  local tpl = "default-src 'none'; script-src https://cdn.jsdelivr.net %s; style-src https://cdn.jsdelivr.net 'unsafe-inline'; img-src 'self' data: https://cdn.jsdelivr.net; connect-src 'self'; font-src https://cdn.jsdelivr.net; frame-ancestors 'none'"
  return tpl:format(table.concat(hashes, " "))
end

function _M.spec_json()
  if not cached_json then
    cached_json = assert(cjson.encode(spec.build()))
  end
  ngx.header["Content-Type"] = "application/json; charset=utf-8"
  ngx.header["Cache-Control"] = "public, max-age=300"
  ngx.header["Content-Length"] = tostring(#cached_json)
  ngx.print(cached_json)
  return { status = 200, layout = false }
end

-- also support alias spec_json vs json per router naming
_M.json = _M.spec_json

function _M.ui()
  if not cached_html then
    local prefix = ngx.config.prefix() or "/app/"
    local path = prefix .. "public/swagger/index.html"
    local f = io.open(path, "rb")
    if not f then f = io.open("/app/public/swagger/index.html", "rb") end
    if not f then f = io.open("api/public/swagger/index.html", "rb") end
    if f then
      cached_html = f:read("*a")
      f:close()
    else
      cached_html = "<html><body>Swagger UI not found</body></html>"
    end
    cached_csp = csp_for(cached_html)
  end
  ngx.header["Content-Type"] = "text/html; charset=utf-8"
  ngx.header["Content-Security-Policy"] = cached_csp
  ngx.header["Content-Length"] = tostring(#cached_html)
  ngx.print(cached_html)
  return { status = 200, layout = false }
end

return _M
