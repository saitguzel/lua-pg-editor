-- Connection validation ve model testleri (pg-editor F15)
local v = require("pg_shared.validation")

describe("connection_create schema", function()
  it("unix socket host geçerli", function()
    assert.is_not_nil(v.validate(v.schemas.connection_create, { name = "sock", host = "/var/run/postgresql", port = 5432, database = "mydb", username = "user" }))
  end)

  it("host cok uzun reddedilir", function()
    assert.is_nil(v.validate(v.schemas.connection_create, { name = "t", host = string.rep("a", 256), port = 5432, database = "mydb", username = "user" }))
  end)

  it("PostgreSQL adlari (rezerve kelime, tire, Unicode) kabul, 63 bayt ustu red", function()
    local base = { name = "t", host = "localhost", port = 5432, database = "my-db.prod", username = "table" }
    assert.is_not_nil(v.validate(v.schemas.connection_create, base))
    base.username = "kullanıcı"
    assert.is_not_nil(v.validate(v.schemas.connection_create, base))
    base.username = string.rep("a", 64)
    local _, e = v.validate(v.schemas.connection_create, base)
    assert.truthy(e and e.username)
  end)

  it("ssh_enabled true ise ssh_host zorunlu degil (servis kontrolu) - schema izin verir", function()
    local c = v.validate(v.schemas.connection_create, { name = "t", host = "localhost", port = 5432, database = "mydb", username = "user", ssh_enabled = true })
    assert.is_not_nil(c)
  end)
end)

describe("connection model serialize", function()
  it("password maskelenir", function()
    local conn_model = require("models.connection")
    local row = { id = "1", user_id = "u1", name = "test", host = "localhost", port = 5432, database = "mydb", username = "user", password_encrypted = "enc", save_password = true, ssh_enabled = false, created_at = "2026-09-18T10:00:00Z", updated_at = "2026-09-18T10:00:00Z" }
    local s = conn_model.serialize(row)
    assert.is_true(s.has_password)
    assert.equal("***", s.password)
    assert.is_nil(s.password_encrypted)
  end)
end)
