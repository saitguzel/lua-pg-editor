-- F27: sql_guard — yıkıcı ifade tespiti (LuaJIT + Lua 5.4)
package.preload["pg_shared.sql_guard"] = function() return dofile("shared/src/sql_guard.lua") end
local guard = require("pg_shared.sql_guard")

local function kind(sql)
  local r = guard.destructive_kind(sql)
  return r and r.kind or nil
end

describe("sql_guard.destructive_kind", function()
  it("DROP / TRUNCATE / ALTER … DROP", function()
    assert.equal("DROP", kind("DROP TABLE x"))
    assert.equal("DROP", kind("  drop schema s cascade"))
    assert.equal("TRUNCATE", kind("TRUNCATE t"))
    assert.equal("ALTER_DROP", kind("ALTER TABLE t DROP COLUMN c"))
    assert.is_nil(kind("ALTER TABLE t ADD COLUMN c int"))
  end)

  it("DELETE yalnız WHERE'siz", function()
    assert.equal("DELETE", kind("DELETE FROM t"))
    assert.is_nil(kind("DELETE FROM t WHERE id = 1"))
    assert.is_nil(kind("DELETE FROM t WHERE name = 'x'"))
  end)

  it("yorum, literal ve dolar gövdesi tetiklemez", function()
    assert.is_nil(kind("-- drop\nSELECT 1"))
    assert.is_nil(kind("/* DROP TABLE x */ SELECT 1"))
    assert.is_nil(kind("SELECT 'DROP TABLE x'"))
    assert.is_nil(kind("SELECT $$ DROP $$"))
    assert.is_nil(kind("SELECT $fn$ TRUNCATE t; $fn$"))
    assert.is_nil(kind([[SELECT "drop"]]))
  end)

  it("çoklu ifadede ilk yıkıcı olanı bulur; DELETE literal içindeki WHERE'i saymaz", function()
    local r = guard.destructive_kind("SELECT 1; DROP TABLE  x; SELECT 2")
    assert.equal("DROP", r.kind)
    assert.equal("DROP TABLE x", r.statement)
    assert.equal("DELETE", kind("DELETE FROM t -- WHERE id = 1"))
  end)

  it("strip uzunluğu korur", function()
    local s = "SELECT 'a;b' /* x */ -- y\nFROM t"
    assert.equal(#s, #guard.strip(s))
    assert.equal(2, #guard.statements("SELECT 'a;b'; SELECT 2"))
  end)
end)
