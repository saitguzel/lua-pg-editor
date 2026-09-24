-- F29: ipuçları — where süzgeci ve görülmemiş ilk ipucu.
require("helper")
local tips = require("tips")

describe("tips", function()
  it("for_where yalnız ilgili yerdekileri döner", function()
    for _, t in ipairs(tips.for_where("dash")) do assert.is_true(t.where.dash) end
    assert.equal(#tips.TIPS, #tips.for_where("help")) -- hepsi yardımda listelenir
    assert.is_true(#tips.for_where("dash") < #tips.TIPS)
  end)

  it("next_tip görülmemiş ilkini döner, hepsi görüldüyse nil", function()
    local first = tips.next_tip({})
    assert.equal(tips.for_where("dash")[1].id, first.id)
    assert.equal(tips.for_where("dash")[2].id, tips.next_tip({ first.id }).id)
    local all = {}
    for _, t in ipairs(tips.TIPS) do all[#all + 1] = t.id end
    assert.is_nil(tips.next_tip(all))
  end)
end)
