-- Query parser birim testleri (pg-editor F15)
local parser = require("utils.sql_parser")

describe("sql_statements", function()
  it("iki ifade ayirir", function()
    local stmts = parser.sql_statements("SELECT 1; SELECT 2 -- comment")
    assert.equal(2, #stmts)
  end)

  it("literal icindeki noktali virgul ayirmaz", function()
    local stmts = parser.sql_statements("SELECT 'a; b'; SELECT 2")
    assert.equal(2, #stmts)
  end)

  it("contains_transaction_control", function()
    assert.is_true(parser.contains_transaction_control("BEGIN"))
    assert.is_true(parser.contains_transaction_control("commit"))
    assert.is_false(parser.contains_transaction_control("SELECT * FROM t"))
  end)

  it("strip_leading_sql_comments", function()
    assert.equal("SELECT 1", parser.strip_leading_sql_comments("-- comment\n SELECT 1"):match("^%s*(.-)%s*$"))
  end)

  it("changes_schema", function()
    assert.is_true(parser.changes_schema("CREATE TABLE t (id int)"))
    assert.is_false(parser.changes_schema("SELECT 1"))
  end)

  it("safe_row_limit", function()
    assert.equal(100, parser.safe_row_limit(100, 1000, 50000))
    assert.equal(50000, parser.safe_row_limit(99999, 1000, 50000))
  end)
end)

describe("validate_expression (custom_where)", function()
  it("geçerli ifadeyi kabul eder", function()
    assert.is_true(parser.validate_expression("status = 'x' AND (a > 1 OR b IS NULL)"))
    assert.is_true(parser.validate_expression("name = ')'"))
  end)

  it("WHERE'den kacis denemelerini reddeder", function()
    for _, bad in ipairs({ "1=1; DROP TABLE t", "1=1 -- x", "1=1 /* x */", "id = $1",
                           "1=1) OR (1=1", "(1=1", "BEGIN", "" }) do
      assert.is_false(parser.validate_expression(bad), bad)
    end
  end)
end)

describe("table_browser.build_where", function()
  local tb = require("db.target.table_browser")

  it("izinli operatorleri parametreli uretir", function()
    local w, p = tb.build_where({ { column = "a", operator = ">=", value = "5" },
      { column = "b", operator = "IS NULL" } })
    assert.equal('WHERE "a" >= $1 AND "b" IS NULL', w)
    assert.same({ "5" }, p)
  end)

  it("bilinmeyen operatoru reddeder (SQL'e eklenmez)", function()
    local w, err = tb.build_where({ { column = "a", operator = "= 1 OR 1=1 --", value = "x" } })
    assert.is_nil(w)
    assert.truthy(err:find("gecersiz filtre", 1, true))
  end)
end)

describe("pool_manager havuz adi", function()
  it("DB/host/kullanıcı/güncelleme degisince farkli havuz", function()
    local pm = require("db.pool_manager")
    local base = { id = "c1", host = "h", port = 5432, database = "a", username = "u", updated_at = "t1" }
    local other = {}
    for k, v in pairs(base) do other[k] = v end
    other.database = "b"
    assert.are_not.equal(pm._pool_name(base), pm._pool_name(other))
    other.database = "a"; other.updated_at = "t2"
    assert.are_not.equal(pm._pool_name(base), pm._pool_name(other))
  end)
end)

describe("ssh_tunnel.command", function()
  local t = require("db.ssh_tunnel")
  local conn = { host = "db", port = 5432, ssh_host = "bastion", ssh_port = 2222, ssh_username = "u" }
  local files = { known_hosts = "/tmp/kh", key = "/tmp/k" }

  it("parola: sshpass -e, parola ortamda (komut satırinda degil), strict host key", function()
    conn.ssh_auth_method = "password"
    local args, env = t.command(conn, 40001, files, { password = "gizli" })
    local line = table.concat(args, " ")
    assert.equal("sshpass", args[1])
    assert.truthy(line:find("-L 127.0.0.1:40001:db:5432", 1, true))
    assert.truthy(line:find("StrictHostKeyChecking=yes", 1, true))
    assert.truthy(line:find("UserKnownHostsFile=/tmp/kh", 1, true))
    assert.is_nil(line:find("gizli", 1, true))
    assert.truthy(table.concat(env, " "):find("SSHPASS=gizli", 1, true))
    assert.equal("u@bastion", args[#args])
  end)

  it("ozel anahtar: -i dosya, parolasizsa BatchMode", function()
    conn.ssh_auth_method = "private_key"
    local args = t.command(conn, 40002, files, {})
    local line = table.concat(args, " ")
    assert.equal("ssh", args[1])
    assert.truthy(line:find("-i /tmp/k", 1, true))
    assert.truthy(line:find("BatchMode=yes", 1, true))
  end)
end)
