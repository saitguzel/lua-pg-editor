-- F17: fetch.lua testleri — coroutine köprüsü, hata eşleme, tek-uçuş refresh.
local fake = require("helper") -- js mock'unu yükler
local json = require("json")

-- api.configure resetlenebilir olması için fetch.lua fresh require edilir
package.loaded["fetch"] = nil
local api = require("fetch")

local function in_coroutine(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then error(err, 2) end
end

local tokens = nil
local forbidden_calls = 0

api.configure({
  base = "http://test/api/v1",
  get_tokens = function() return tokens end,
  set_tokens = function(a, r) tokens = { access_token = a, refresh_token = r } end,
  on_logout = function() tokens = nil end,
  on_forbidden = function() forbidden_calls = forbidden_calls + 1 end,
})

describe("api request", function()
  before_each(function()
    fake.reset()
    tokens = nil
  end)

  it("200 JSON data döner", function()
    fake.queue_response(200, json.encode({ data = { id = "c1", name = "pg" } }))
    in_coroutine(function()
      local data, err = api.get("/connections/c1")
      assert.is_nil(err)
      assert.equal("c1", data.id)
    end)
  end)

  it("liste yanıtı items+meta ile döner", function()
    fake.queue_response(200, json.encode({ data = { { id = "c1" } }, meta = { total = 1, page = 1 } }))
    in_coroutine(function()
      local data, err = api.get("/connections")
      assert.is_nil(err)
      assert.equal(1, #data.items)
      assert.equal(1, data.meta.total)
    end)
  end)

  it("422 VALIDATION_FAILED details ile döner", function()
    fake.queue_response(422, json.encode({ error = { code = "VALIDATION_FAILED",
      message = "Girdi doğrulanamadı", details = { name = { "zorunlu alan" } } } }))
    in_coroutine(function()
      local data, err = api.post("/connections", { name = "" })
      assert.is_nil(data)
      assert.equal("VALIDATION_FAILED", err.code)
      assert.same({ name = { "zorunlu alan" } }, err.details)
    end)
  end)

  it("ağ hatası NETWORK_ERROR üretir (frontend'e özel kod)", function()
    fake.queue_response(0, "", { net_err = "fetch failed" })
    in_coroutine(function()
      local data, err = api.get("/connections")
      assert.is_nil(data)
      assert.equal("NETWORK_ERROR", err.code)
    end)
  end)

  it("Authorization header token varsa eklenir", function()
    tokens = { access_token = "abc", refresh_token = "r" }
    fake.queue_response(200, json.encode({ data = true }))
    in_coroutine(function()
      api.get("/connections")
    end)
    assert.matches("Bearer abc", fake.calls[1].headers)
  end)

  it("login'de Authorization eklenmez", function()
    tokens = { access_token = "abc", refresh_token = "r" }
    fake.queue_response(200, json.encode({ data = { access_token = "a2", refresh_token = "r2", user = {} } }))
    in_coroutine(function()
      api.post("/auth/login", { email = "a@b.c", password = "x12345678A" })
    end)
    assert.not_matches("Bearer", fake.calls[1].headers or "")
  end)

  it("401 TOKEN_EXPIRED → refresh → istek tekrarlanır (tek-uçuş)", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    -- 1) orijinal istek 401, 2) refresh 200, 3) tekrar 200
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_EXPIRED", message = "Oturum süresi doldu" } }))
    fake.queue_response(200, json.encode({ data = { access_token = "yeni", refresh_token = "r2" } }))
    fake.queue_response(200, json.encode({ data = { id = "c1" } }))
    in_coroutine(function()
      local data, err = api.get("/connections/c1")
      assert.is_nil(err)
      assert.equal("c1", data.id)
    end)
    -- çağrı sırası: GET, POST /auth/refresh, GET (tekrar)
    assert.equals(3, #fake.calls)
    assert.equal("http://test/api/v1/auth/refresh", fake.calls[2].url)
    assert.equal("GET", fake.calls[3].method)
    -- yeni token kullanıldı
    assert.matches("Bearer yeni", fake.calls[3].headers)
    assert.equal("yeni", tokens.access_token)
  end)

  it("refresh başarısız → on_logout çağrılır", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_EXPIRED" } }))
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_REVOKED" } }))
    in_coroutine(function()
      local data = api.get("/connections")
      assert.is_nil(data)
    end)
    assert.is_nil(tokens) -- on_logout çalıştı
  end)

  it("aynı anda 3 istek 401 → TEK /auth/refresh, üçü de tekrarlanır", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    fake.async = true
    local expired = json.encode({ error = { code = "TOKEN_EXPIRED" } })
    for _ = 1, 3 do fake.queue_response(401, expired) end
    fake.queue_response(200, json.encode({ data = { access_token = "yeni", refresh_token = "r2" } }))
    for i = 1, 3 do fake.queue_response(200, json.encode({ data = { id = "c" .. i } })) end
    local results = {}
    for i = 1, 3 do
      coroutine.resume(coroutine.create(function()
        local data = api.get("/connections/c" .. i)
        results[#results + 1] = data and data.id
      end))
    end
    fake.flush()
    local refreshes = 0
    for _, c in ipairs(fake.calls) do
      if c.url:find("/auth/refresh", 1, true) then refreshes = refreshes + 1 end
    end
    assert.equal(1, refreshes)
    assert.equal(3, #results)
    assert.equal("yeni", tokens.access_token)
  end)

  it("TOKEN_REVOKED refresh denemeden oturumu kapatır", function()
    tokens = { access_token = "eski", refresh_token = "r" }
    fake.queue_response(401, json.encode({ error = { code = "TOKEN_REVOKED" } }))
    in_coroutine(function()
      local _, err = api.get("/connections")
      assert.equal("TOKEN_REVOKED", err.code)
    end)
    assert.equal(1, #fake.calls)
    assert.is_nil(tokens)
  end)

  it("403 FORBIDDEN izin tazeleme kancasını çağırır", function()
    forbidden_calls = 0
    fake.queue_response(403, json.encode({ error = { code = "FORBIDDEN" } }))
    in_coroutine(function() api.get("/users") end)
    assert.equal(1, forbidden_calls)
  end)

  it("429 Retry-After err.retry_after olarak döner", function()
    fake.queue_response(429, json.encode({ error = { code = "RATE_LIMITED" } }), { retry_after = "42" })
    in_coroutine(function()
      local _, err = api.post("/auth/login", {})
      assert.equal("RATE_LIMITED", err.code)
      assert.equal(42, err.retry_after)
    end)
  end)

  it("tekil yanıt meta'yı üçüncü değer olarak döner", function()
    fake.queue_response(200, json.encode({ data = { matrix = { admin = {} } }, meta = { cache_ttl = 60 } }))
    in_coroutine(function()
      local data, err, meta = api.get("/rbac/matrix")
      assert.is_nil(err)
      assert.is_table(data.matrix)
      assert.equal(60, meta.cache_ttl)
    end)
  end)

  it("coroutine dışında çağrı açık hata verir", function()
    assert.has_error(function() api.get("/connections") end)
  end)

  it("204 → true döner", function()
    fake.queue_response(204, "")
    in_coroutine(function()
      local ok, err = api.delete("/connections/c1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  it("query encoder url-encode yapar", function()
    assert.equal("?page=2&q=fatura%20%C3%B6de", api._encode_query({ q = "fatura öde", page = 2 })) -- sıralı
  end)

  it("download body verilince JSON gövdeli POST gönderir", function()
    in_coroutine(function()
      assert.is_true(api.download("/query/csv", "q.csv", nil, { sql = "SELECT 1" }))
    end)
    local c = fake.calls[#fake.calls]
    assert.equal("DOWNLOAD", c.method)
    assert.equal('{"sql":"SELECT 1"}', c.body)
  end)

  it("download sunucu hatasını API hatası olarak döner", function()
    fake.download_error = "download 400"
    fake.download_error_body = '{"error":{"code":"READONLY_VIOLATION","message":"x"}}'
    in_coroutine(function()
      local ok, err = api.download("/query/csv", "q.csv", nil, { sql = "DELETE FROM t" })
      assert.is_nil(ok)
      assert.equal("READONLY_VIOLATION", err.code)
      assert.equal(400, err.status)
    end)
    fake.download_error, fake.download_error_body = nil, nil
  end)

  it("delete body gönderebilir", function()
    fake.queue_response(200, '{"data":{"deleted":2}}')
    in_coroutine(function() api.delete("/x/rows", { ids = { "a", "b" } }) end)
    assert.equal('{"ids":["a","b"]}', fake.calls[#fake.calls].body)
  end)
end)
