-- F22: pg_shared.validation testleri — connection ve diger şemalar
require("helper")
local validation = require("pg_shared.validation")

describe("validation connection_create", function()
  it("geçerli bağlantı kabul edilir", function()
    local clean, err = validation.validate(validation.schemas.connection_create, {
      name = "local pg", host = "localhost", port = 5432, database = "testdb", username = "postgres", password = "secret"
    })
    assert.is_not_nil(clean)
    assert.is_nil(err)
  end)

  it("port aralik disi reddedilir", function()
    local clean, err = validation.validate(validation.schemas.connection_create, {
      name = "a", host = "h", port = 99999, database = "db", username = "u"
    })
    assert.is_nil(clean)
    assert.is_not_nil(err.port)
  end)

  it("host bos reddedilir", function()
    local clean, err = validation.validate(validation.schemas.connection_create, {
      name = "a", host = "", port = 5432, database = "db", username = "u"
    })
    assert.is_nil(clean)
    assert.is_not_nil(err.host)
  end)

  it("unix socket host kabul edilir", function()
    local clean, err = validation.validate(validation.schemas.connection_create, {
      name = "sock", host = "/var/run/postgresql", port = 5432, database = "db", username = "u"
    })
    assert.is_not_nil(clean)
    assert.is_nil(err)
  end)

  it("validate_partial en az bir alan ister", function()
    local clean, err = validation.validate_partial(validation.schemas.connection_create, {})
    assert.is_nil(clean)
    assert.is_not_nil(err)
  end)

  it("safe_sql noktali virgul engeli", function()
    local rule = validation.safe_sql()
    local ok, _ = rule.check("SELECT * FROM t WHERE a=1; DROP TABLE t")
    assert.is_false(ok)
    local ok2, _ = rule.check("a=1 AND total > 100")
    assert.is_true(ok2)
  end)

  it("safe_sql yasak kelime ve pg_ engeli (faz-31)", function()
    local rule = validation.safe_sql()
    assert.is_false(rule.check("SELECT * FROM t"))
    assert.is_false(rule.check("a UNION SELECT b"))
    assert.is_false(rule.check("pg_sleep(5)"))
    assert.is_false(rule.check("1=1 -- yorum"))
    assert.is_false(rule.check("id = $1"))
    assert.is_true(rule.check("name = 'select'")) -- literal icindeki kelime sayilmaz
  end)

  it("sql_identifier rezerve kelimeyi reddeder", function()
    local rule = validation.sql_identifier()
    local ok, _ = rule.check("select")
    assert.is_false(ok)
    local ok2, out = rule.check("my_table")
    assert.is_true(ok2)
    assert.equal("my_table", out)
  end)
end)

describe("validation query_execute", function()
  it("geçerli sorgu kabul", function()
    local clean, err = validation.validate(validation.schemas.query_execute, {
      connection_id = "550e8400-e29b-41d4-a716-446655440000", sql = "SELECT 1"
    })
    assert.is_not_nil(clean)
    assert.is_nil(err)
  end)

  it("bos sql reddedilir", function()
    local clean, err = validation.validate(validation.schemas.query_execute, {
      connection_id = "550e8400-e29b-41d4-a716-446655440000", sql = ""
    })
    assert.is_nil(clean)
    assert.is_not_nil(err.sql)
  end)
end)
