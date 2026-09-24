-- json.lua: dizi içindeki null json.null olarak korunur, nesne alanındaki null nil olur
require("helper")
local json = require("json")

describe("json.decode null", function()
  it("sonuç satırındaki NULL hücreyi korur (ipairs kesilmez)", function()
    local d = json.decode('{"rows":[[null,2,"x"],[1,null,null]],"extra":null}')
    assert.equal(json.null, d.rows[1][1])
    assert.equal(2, d.rows[1][2])
    local n = 0
    for _ in ipairs(d.rows[2]) do n = n + 1 end
    assert.equal(3, n)
    assert.is_nil(d.extra)
  end)

  it("encode json.null'u null yazar", function()
    assert.equal('[null,1]', json.encode({ json.null, 1 }))
  end)
end)
