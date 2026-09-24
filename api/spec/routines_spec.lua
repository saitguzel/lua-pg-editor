-- Fonksiyon/prosedür/trigger script üretimi (db.target.routines saf yardımcıları)
local routines = require("db.target.routines")

describe("routines.split_args", function()
  it("parantez içindeki virgüller bölünmez", function()
    assert.are.same({ "a integer", "b numeric(10,2)", "OUT c text" },
      routines.split_args("a integer, b numeric(10,2), OUT c text"))
  end)
  it("boş argüman listesi", function()
    assert.are.same({}, routines.split_args(""))
    assert.are.same({}, routines.split_args(nil))
  end)
end)

describe("routines scriptleri", function()
  local fn = { schema = "public", name = 'f"x', args = "a integer, b text" }

  it("fonksiyon çağrısı: NULL yer tutucular + tip yorumu, adlar quote'lu", function()
    assert.are.equal('SELECT * FROM "public"."f""x"(\n    NULL /* a integer */,\n    NULL /* b text */\n);',
      routines.call_script("function", fn))
  end)

  it("argümansız prosedür CALL", function()
    assert.are.equal('CALL "s"."p"();', routines.call_script("procedure", { schema = "s", name = "p", args = "" }))
  end)

  it("yorum kapatma dizisi argüman adında etkisizleştirilir", function()
    local sql = routines.call_script("function", { schema = "s", name = "f", args = "x */ text" })
    assert.is_nil(sql:find("x */", 1, true))
  end)

  it("DROP imzayla (overload güvenli) ve trigger tabloya göre", function()
    assert.are.equal('DROP FUNCTION "public"."f""x"(a integer, b text);', routines.drop_script("function", fn))
    assert.are.equal('DROP PROCEDURE "s"."p"();',
      routines.drop_script("procedure", { schema = "s", name = "p", args = "" }))
    assert.are.equal('DROP TRIGGER "trg" ON "s"."t";',
      routines.drop_script("trigger", { schema = "s", name = "trg", table_name = "t" }))
  end)
end)
