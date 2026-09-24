-- F30: config.lua env okuma — yeni degiskenler, timeout tutarlilik uyarisi, prod CORS '*' reddi.
-- Diger spec'ler package.loaded["config"]'i sahte tabloyla degistirdigi icin gercek modul dofile ile yuklenir.
local config = dofile("src/config.lua")

local BASE = {
  DB_PASSWORD = "pw", JWT_SECRET = string.rep("j", 32), ENCRYPTION_KEY = string.rep("e", 32),
}

local function load_with(overrides)
  local env = {}
  for k, v in pairs(BASE) do env[k] = v end
  for k, v in pairs(overrides or {}) do env[k] = v end
  return config.load(function(k) return env[k] end)
end

describe("config F30", function()
  it("varsayilanlar: statement_timeout 30000, rate limit 10 r/s", function()
    local c = load_with()
    assert.equal(30000, c.query.statement_timeout_ms)
    assert.equal(10, c.rate_limit_rps)
    assert.same({}, c.warnings)
  end)

  it("RATE_LIMIT_RPS=0 kabul (kapali)", function()
    assert.equal(0, load_with({ RATE_LIMIT_RPS = "0" }).rate_limit_rps)
  end)

  it("QUERY_TIMEOUT_MS < QUERY_STATEMENT_TIMEOUT_MS → uyari, hata degil", function()
    local c = load_with({ QUERY_TIMEOUT_MS = "5000", QUERY_STATEMENT_TIMEOUT_MS = "6000" })
    assert.equal(1, #c.warnings)
    assert.truthy(c.warnings[1]:find("QUERY_TIMEOUT_MS", 1, true))
  end)

  it("QUERY_STATEMENT_TIMEOUT_MS 1000 altinda reddedilir", function()
    assert.has_error(function() load_with({ QUERY_STATEMENT_TIMEOUT_MS = "500" }) end)
  end)

  it("uretimde CORS_ORIGINS=* reddedilir", function()
    local ok, err = pcall(load_with, { APP_ENV = "production", CORS_ORIGINS = "*",
      DB_PASSWORD = string.rep("p", 16) })
    assert.is_false(ok)
    assert.truthy(tostring(err):find("CORS_ORIGINS", 1, true))
  end)
end)
