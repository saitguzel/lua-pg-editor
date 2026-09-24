-- AI servis saf yardımcıları + sahte HTTP ile model testi (gerçek sağlayıcıya istek atılmaz)
local cjson = require("cjson.safe")
local ai = require("services.ai_service")

describe("ai.extract_sql", function()
  it("```sql bloğunu alır, açıklamayı atar", function()
    assert.are.equal("SELECT 1;", ai.extract_sql("Açıklama\n```sql\nSELECT 1;\n```\nson"))
  end)
  it("dil etiketsiz blok ve kapanmamış blok", function()
    assert.are.equal("SELECT 2", ai.extract_sql("```\nSELECT 2\n```"))
    assert.are.equal("SELECT 3", ai.extract_sql("```sql\nSELECT 3\n"))
  end)
  it("<think> bloğu atılır, düz metin kırpılır, boş → nil", function()
    assert.are.equal("SELECT 4", ai.extract_sql("<think>düşün ```sql\nSELECT 0\n```</think>\n  SELECT 4  "))
    assert.is_nil(ai.extract_sql("   "))
    assert.is_nil(ai.extract_sql(nil))
  end)
end)

describe("ai.rank_models (otomatik mod)", function()
  it("görünür + başarılı hızlıdan yavaşa, sonra test edilmemiş; başarısız ve gizli dışarıda", function()
    local ids = ai.rank_models({
      { id = "yavas", visible = true, last_test = { ok = true, latency_ms = 900 } },
      { id = "hizli", visible = true, last_test = { ok = true, latency_ms = 120 } },
      { id = "bozuk", visible = true, last_test = { ok = false, latency_ms = 50 } },
      { id = "yeni", visible = true },
      { id = "gizli", visible = false, last_test = { ok = true, latency_ms = 1 } },
    })
    assert.are.same({ "hizli", "yavas", "yeni" }, ids)
  end)
end)

describe("ai.merge_models", function()
  it("görünürlük/test korunur, listede olmayan düşer, hariç tutulan eklenmez, sıralı", function()
    local out = ai.merge_models({ { id = "b", visible = true, last_test = { ok = true } }, { id = "eski" } },
      { "c", "b", "x" }, { "x" })
    assert.are.equal(2, #out)
    assert.are.equal("b", out[1].id)
    assert.is_true(out[1].visible)
    assert.are.same({ id = "c", visible = false }, out[2])
  end)
end)

describe("ai.schema_context", function()
  local catalog = { schemas = { { name = "public",
    tables = { { name = "orders", kind = "table", columns = { { name = "id", type = "integer" } } },
               { name = "customers", kind = "view", columns = { { name = "ad", type = "text" } } } },
    routines = { { name = "f", kind = "function", args = "a integer", returns = "text" } } } } }

  it("istemde geçen tablo önce, view işaretli, fonksiyon imzalı", function()
    local ctx = ai.schema_context(catalog, "müşteri customers listesi")
    assert.truthy(ctx:find("^public%.customers %[view%]%(ad text%)"))
    assert.truthy(ctx:find("public.orders(id integer)", 1, true))
    assert.truthy(ctx:find("FUNCTION public.f(a integer) RETURNS text", 1, true))
  end)

  it("limit aşılınca kesilir ve not düşülür", function()
    local ctx = ai.schema_context(catalog, "", 30)
    assert.truthy(ctx:find("nesne daha", 1, true))
  end)
end)

describe("ai.provider_message", function()
  it("NVIDIA/OpenAI hata biçimleri", function()
    assert.are.equal("410: model gone", ai.provider_message(410, cjson.encode({ title = "Gone", detail = "model gone" })))
    assert.are.equal("503: overloaded", ai.provider_message(503, cjson.encode({ error = { message = "overloaded" } })))
    assert.are.equal("500: düz metin", ai.provider_message(500, "düz metin"))
  end)
end)

describe("ai.test_request (sahte HTTP)", function()
  local real = ai._http
  after_each(function() ai._http = real end)

  local function reply(status, body, err)
    ai._http = function(method, url, key, payload)
      assert.are.equal("POST", method)
      assert.truthy(url:find("/chat/completions$"))
      assert.are.equal("k", key)
      assert.are.equal("m", payload.model)
      return status, body and cjson.encode(body), err
    end
  end

  it("içerikte ya da reasoning'de SELECT → ok", function()
    reply(200, { choices = { { message = { content = "SELECT 42 AS answer;" } } } })
    assert.is_true(ai.test_request("https://x/v1", "k", "m").ok)
    reply(200, { choices = { { message = { content = cjson.null, reasoning_content = "so: select 42 as answer" } } } })
    assert.is_true(ai.test_request("https://x/v1", "k", "m").ok)
  end)

  it("SQL üretmeyen model (ör. içerik güvenliği 'safe' ya da çeviri) → ok=false", function()
    reply(200, { choices = { { message = { content = "PostgreSQL sorgusu yazın: 42 döndüren" } } } })
    assert.is_false(ai.test_request("https://x/v1", "k", "m").ok)
    reply(200, { choices = { { message = { content = "User Safety: safe" } } } })
    local r = ai.test_request("https://x/v1", "k", "m")
    assert.is_false(r.ok)
    assert.truthy(r.error:find("SQL üretmedi", 1, true))
  end)

  it("boş yanıt, HTTP hatası ve zaman aşımı → ok=false + mesaj", function()
    reply(200, { choices = { { message = { content = "" } } } })
    assert.are.equal("boş yanıt", ai.test_request("https://x/v1", "k", "m").error)
    reply(404, { detail = "Not found for account" })
    local r = ai.test_request("https://x/v1", "k", "m")
    assert.is_false(r.ok)
    assert.are.equal("404: Not found for account", r.error)
    reply(nil, nil, "timeout")
    assert.are.equal("zaman aşımı", ai.test_request("https://x/v1", "k", "m").error)
  end)
end)
