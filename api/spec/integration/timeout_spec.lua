-- F30 entegrasyon: statement_timeout oturumda set edilir; asilinca 57014 + "zaman asimi" mesaji;
-- execute/csv rate limit 429 RATE_LIMITED. YALNIZ `make up.e2e` yiginda (reset_db meta DB'yi TRUNCATE eder).
-- Zaman asimi senaryosu icin yigin QUERY_STATEMENT_TIMEOUT_MS=1000 ile ayaga kaldirilmali; degilse SHOW ile
-- yalnizca ayarin uygulandigi dogrulanir.
local h = require("helpers.init")

describe("statement_timeout & rate limit (integration)", function()
  local admin, conn_id
  setup(function()
    h.reset_db()
    admin = h.login_admin()
    local list = h.request("GET", "/connections", nil, admin.access_token)
    conn_id = assert(list.body.data[1] and list.body.data[1].id, "seed baglantisi yok")
  end)

  local function execute(sql)
    return h.request("POST", "/query/execute", { connection_id = conn_id, sql = sql }, admin.access_token)
  end

  it("statement_timeout oturumda QUERY_STATEMENT_TIMEOUT_MS", function()
    -- SHOW '30s' gibi birimli doner; ms'ye cevirerek karsilastir
    local res = execute("SELECT extract(epoch FROM current_setting('statement_timeout')::interval) * 1000")
    assert.equal(200, res.status)
    local expected = tonumber(os.getenv("QUERY_STATEMENT_TIMEOUT_MS") or "30000")
    assert.equal(expected, tonumber(res.body.data.rows[1][1]))
  end)

  it("statement_timeout asimi → 57014 ve zaman asimi mesaji (QUERY_STATEMENT_TIMEOUT_MS <= 2000 ise)", function()
    local st = tonumber(os.getenv("QUERY_STATEMENT_TIMEOUT_MS") or "30000")
    if st > 2000 then return pending("yigin QUERY_STATEMENT_TIMEOUT_MS=1000 ile kaldirilmadi") end
    local res = execute("SELECT pg_sleep(" .. math.ceil(st / 1000) + 1 .. ")")
    assert.equal(400, res.status)
    assert.equal("QUERY_FAILED", h.code(res))
    assert.equal("57014", res.body.error.details.sqlstate)
    assert.truthy(res.body.error.message:find("zaman asimi", 1, true))
  end)

  it("hizli ardisik execute → en az bir 429 RATE_LIMITED (RATE_LIMIT_RPS > 0 ise)", function()
    local rps = tonumber(os.getenv("RATE_LIMIT_RPS") or "10")
    if rps <= 0 then return pending("RATE_LIMIT_RPS=0") end
    local limited = false
    for _ = 1, rps + 25 do
      local res = execute("SELECT 1")
      if res.status == 429 then
        assert.equal("RATE_LIMITED", h.code(res))
        limited = true
        break
      end
    end
    assert.is_true(limited)
  end)
end)
