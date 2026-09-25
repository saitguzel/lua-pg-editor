-- Validation şema testleri: shared validation'in API'deki kullanimi (pg-editor F15)
local v = require("pg_shared.validation")

local function errs(schema, input)
  local clean, e = v.validate(schema, input)
  return clean, e or {}
end

describe("connection_create", function()
  local S = v.schemas.connection_create

  it("minimal geçerli", function()
    local clean = assert(v.validate(S, { name = "test", host = "localhost", port = 5432, database = "mydb", username = "user" }))
    assert.equal("test", clean.name)
  end)

  it("bos name reddedilir", function()
    assert.is_nil(v.validate(S, { name = "", host = "localhost", port = 5432, database = "mydb", username = "user" }))
  end)

  it("gecersiz host", function()
    assert.truthy(select(2, errs(S, { name = "t", host = "", port = 5432, database = "mydb", username = "user" })).host)
  end)

  it("gecersiz port", function()
    assert.is_nil(v.validate(S, { name = "t", host = "localhost", port = 99999, database = "mydb", username = "user" }))
  end)

  it("database: rezerve kelime geçerli (tirnaklanir), bos ad red", function()
    assert.is_not_nil(v.validate(S, { name = "t", host = "localhost", port = 5432, database = "select", username = "user" }))
    local _, e = errs(S, { name = "t", host = "localhost", port = 5432, database = "", username = "user" })
    assert.truthy(e.database)
  end)

  it("bilinmeyen alan kabul edilmez", function()
    local clean = v.validate(S, { name = "t", host = "localhost", port = 5432, database = "mydb", username = "user", foo = 1 })
    assert.is_true(clean == nil or clean.foo == nil)
  end)
end)

describe("query_execute", function()
  local S = v.schemas.query_execute

  it("geçerli", function()
    assert.is_not_nil(v.validate(S, { connection_id = "11111111-2222-4333-8444-555555555555", sql = "SELECT 1" }))
  end)

  it("bos sql red", function()
    assert.is_nil(v.validate(S, { connection_id = "11111111-2222-4333-8444-555555555555", sql = "" }))
  end)

  it("uuid hatasi", function()
    assert.truthy(select(2, errs(S, { connection_id = "x", sql = "SELECT 1" })).connection_id)
  end)

  it("102400 byte sinir", function()
    assert.is_nil(v.validate(S, { connection_id = "11111111-2222-4333-8444-555555555555", sql = string.rep("a", 102401) }))
  end)
end)

describe("user şemalari", function()
  local S = v.schemas.user_create

  it("gecersiz email", function()
    assert.truthy(select(2, errs(S, { email = "bad", password = "Valid123!", role = "editor" })).email)
  end)

  it("zayif parola", function()
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "Ab1", role = "editor" })).password)
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "abcdefghij", role = "editor" })).password)
  end)

  it("role root reddedilir", function()
    assert.truthy(select(2, errs(S, { email = "a@b.co", password = "Valid123!", role = "root" })).role)
  end)

  it("user_update tum alanlar opsiyonel", function()
    assert.is_not_nil(v.validate(v.schemas.user_update, { full_name = "Ad" }))
  end)
end)

describe("auth şemalari", function()
  it("login email+password zorunlu", function()
    local _, e = errs(v.schemas.login, {})
    assert.truthy(e.email)
    assert.truthy(e.password)
  end)

  it("reset token + new_password", function()
    assert.is_not_nil(v.validate(v.schemas.reset_password, { token = string.rep("a", 64), new_password = "Valid123!" }))
    assert.is_nil(v.validate(v.schemas.reset_password, { token = "kisa", new_password = "Valid123!" }))
  end)

  it("forgot email zorunlu", function()
    assert.truthy(select(2, errs(v.schemas.forgot_password, {})).email)
  end)
end)

describe("rbac", function()
  it("rbac_matrix geçerli", function()
    assert.is_not_nil(v.validate(v.schemas.rbac_matrix, { permissions = { { role = "admin", page_key = "dashboard", can_access = true } } }))
    assert.is_nil(v.validate(v.schemas.rbac_matrix, { permissions = {} }))
  end)

  it("rbac_cell boolean", function()
    assert.is_nil(v.validate(v.schemas.rbac_cell, { can_access = "evet" }))
  end)
end)

describe("utf8", function()
  it("Turkce karakter bazli sayilir", function()
    assert.equal(20, v.utf8_len("Calisma plani gusioc"))
    -- connection name icin utf8 test
    assert.is_not_nil(v.validate(v.schemas.connection_create, { name = "Calisma", host = "localhost", port = 5432, database = "mydb", username = "user" }))
  end)
end)

describe("query_int", function()
  it("page default", function()
    local sch = v.schema({ page = v.optional(v.query_int({ min = 1, default = 1 })) })
    local c = v.validate(sch, {})
    assert.is_not_nil(c)
  end)
end)
