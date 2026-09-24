-- F25: kategori katalogu saf yardimcilari (SQL uretimi, ILIKE kacisi, CREATE scriptleri) — DB gerektirmez
local types = require("pg_shared.types")
local repo = require("repositories.target_schema_repo")
local script = require("db.target.script")

describe("target_schema_repo kategori SQL", function()
  it("her OBJECT_CATEGORIES icin liste SQL'i uretir; bilinmeyen kategori nil", function()
    assert.equal(16, #types.OBJECT_CATEGORIES)
    for _, cat in ipairs(types.OBJECT_CATEGORIES) do
      local sql = repo.category_sql(cat)
      assert.is_string(sql, cat)
      assert.truthy(sql:find("n.nspname = $1", 1, true), cat)
      assert.truthy(sql:find(" AS kind", 1, true), cat)
      assert.is_nil(sql:find("$2", 1, true), cat .. ": q yokken $2 olmamali")
    end
    assert.is_nil(repo.category_sql("bilinmeyen"))
  end)

  it("q/limit/offset SQL'e girer; offset 0 yazilmaz", function()
    local sql = repo.category_sql("tables", true, 200, 0)
    assert.truthy(sql:find("ILIKE $2 ESCAPE '\\'", 1, true))
    assert.truthy(sql:find("LIMIT 200", 1, true))
    assert.is_nil(sql:find("OFFSET", 1, true))
    assert.truthy(repo.category_sql("views", false, 10, 40):find("LIMIT 10 OFFSET 40", 1, true))
  end)

  it("escape_like % _ \\ kacislar", function()
    assert.equal("a\\%b\\_c\\\\d", repo.escape_like("a%b_c\\d"))
  end)

  it("sayac SQL'i 16 UNION ALL parcasi ve her kategori adi", function()
    local sql = repo.count_categories_sql()
    local _, n = sql:gsub("UNION ALL", "")
    assert.equal(15, n)
    for _, cat in ipairs(types.OBJECT_CATEGORIES) do
      assert.truthy(sql:find("'" .. cat .. "' AS category", 1, true), cat)
    end
  end)

  it("fonksiyon kategorisi aggregate/window icerir, eklenti fonksiyonlarini haric tutar", function()
    local sql = repo.category_sql("functions")
    assert.truthy(sql:find("'f', 'a', 'w'", 1, true))
    assert.truthy(sql:find("deptype = 'e'", 1, true))
    assert.truthy(repo.category_sql("procedures"):find("'p'", 1, true))
  end)

  it("tip kategorisi dizi ve tablo satir tiplerini haric tutar", function()
    local sql = repo.category_sql("types")
    assert.truthy(sql:find("t.typelem = 0", 1, true))
    assert.truthy(sql:find("c.relkind = 'c'", 1, true))
  end)
end)

describe("script.create_other_script", function()
  it("enum: etiketlerde tek tirnak kacisi", function()
    assert.equal([[CREATE TYPE "s"."st" AS ENUM ('a', 'b''c');]],
      script.create_other_script("type_enum", "s", "st", { labels = { "a", "b'c" } }))
  end)

  it("sequence: secenekler ve OWNED BY", function()
    local sql = script.create_other_script("sequence", "public", "orders_id_seq",
      { data_type = "bigint", start = 1, increment = 1, min = 1, max = 100, cache = 1, cycle = false,
        owned_by = "public.orders.id" })
    assert.truthy(sql:find('CREATE SEQUENCE "public"."orders_id_seq"', 1, true))
    assert.truthy(sql:find("MAXVALUE 100", 1, true))
    assert.truthy(sql:find("OWNED BY public.orders.id;", 1, true))
    assert.is_nil(sql:find("CYCLE", 1, true))
  end)

  it("domain: temel tip, NOT NULL, DEFAULT, constraint", function()
    local sql = script.create_other_script("domain", "s", "d",
      { base_type = "text", not_null = true, default = "'x'::text", constraints = { "d_check CHECK (VALUE <> '')" } })
    assert.equal("CREATE DOMAIN \"s\".\"d\" AS text\n    DEFAULT 'x'::text\n    NOT NULL"
      .. "\n    CONSTRAINT d_check CHECK (VALUE <> '');", sql)
  end)

  it("composite ve extension; bilinmeyen tur nil + hata", function()
    assert.equal('CREATE TYPE "s"."c" AS (\n    "a" integer,\n    "b" text\n);',
      script.create_other_script("type_composite", "s", "c", { attributes = { { name = "a", type = "integer" },
        { name = "b", type = "text" } } }))
    assert.equal([[CREATE EXTENSION IF NOT EXISTS "pgcrypto" SCHEMA "public" VERSION '1.3';]],
      script.create_other_script("extension", "public", "pgcrypto", { version = "1.3" }))
    local sql, err = script.create_other_script("operator", "s", "+", {})
    assert.is_nil(sql)
    assert.is_table(err)
  end)
end)

describe("database_object.serialize", function()
  local model = require("models.database_object")
  it("kind gecer, m artik view'a esitlenmez, bos extra nil", function()
    assert.same({ schema = "s", name = "n", kind = "matview" },
      model.serialize({ schema = "s", name = "n", kind = "m" }))
    assert.equal("sequence", model.serialize({ schema = "s", name = "n", kind = "sequence", extra = "" }).kind)
    assert.equal("(a integer)",
      model.serialize({ schema = "s", name = "f", kind = "function", extra = "(a integer)" }).extra)
  end)
end)
