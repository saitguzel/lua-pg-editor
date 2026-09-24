-- Export formatları: CSV / JSON / XLSX (db.target.csv.render + db.target.xlsx)
local cjson = require("cjson.safe")
local target_csv = require("db.target.csv")
local xlsx = require("db.target.xlsx")

-- zip yerel başlıklarını gezer: { [ad] = veri }, CRC doğrulanır
local function unzip(bytes)
  local files, pos = {}, 1
  local function u16(p) local a, b = bytes:byte(p, p + 1); return a + b * 256 end
  local function u32(p) return u16(p) + u16(p + 2) * 65536 end
  while bytes:sub(pos, pos + 3) == "PK\3\4" do
    local crc, size, nlen, xlen = u32(pos + 14), u32(pos + 18), u16(pos + 26), u16(pos + 28)
    local name = bytes:sub(pos + 30, pos + 29 + nlen)
    local data = bytes:sub(pos + 30 + nlen + xlen, pos + 29 + nlen + xlen + size)
    assert.are.equal(crc, ngx.crc32_long(data), "CRC " .. name)
    files[name] = data
    pos = pos + 30 + nlen + xlen + size
  end
  return files, pos
end

describe("xlsx", function()
  it("geçerli zip: tüm OOXML parçaları, merkezi dizin ve bitiş kaydı", function()
    local bytes = xlsx.build({ "id", "ad" }, { { 1, "x" } })
    local files, pos = unzip(bytes)
    for _, n in ipairs({ "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
      "xl/styles.xml", "xl/worksheets/sheet1.xml" }) do
      assert.is_not_nil(files[n], n)
    end
    assert.are.equal("PK\1\2", bytes:sub(pos, pos + 3))
    assert.are.equal("PK\5\6", bytes:sub(-22, -19))
  end)

  it("sayı/boolean tipli, metin escape'li, NULL boş, başlık kalın", function()
    local files = unzip(xlsx.build({ "n", "s", "b", "z" }, { { 42.5, 'a<b>&"c"\1', true, cjson.null } }))
    local sheet = files["xl/worksheets/sheet1.xml"]
    assert.truthy(sheet:find('<c r="A1" s="1" t="inlineStr">', 1, true))
    assert.truthy(sheet:find('<c r="A2"><v>42.5</v></c>', 1, true))
    assert.truthy(sheet:find("a&lt;b&gt;&amp;&quot;c&quot;</t>", 1, true))
    assert.truthy(sheet:find('<c r="C2" t="b"><v>1</v></c>', 1, true))
    assert.is_nil(sheet:find('r="D2"', 1, true))
  end)

  it("kolon adları A..Z, AA, AB", function()
    assert.are.equal("A", xlsx.col_name(0))
    assert.are.equal("Z", xlsx.col_name(25))
    assert.are.equal("AA", xlsx.col_name(26))
    assert.are.equal("AB", xlsx.col_name(27))
    assert.are.equal("BA", xlsx.col_name(52))
  end)

  it("başlıksız seçenek", function()
    local sheet = unzip(xlsx.build({ "a" }, { { "v" } }, { include_header = false }))["xl/worksheets/sheet1.xml"]
    assert.truthy(sheet:find('<c r="A1" t="inlineStr"><is><t xml:space="preserve">v</t>', 1, true))
  end)
end)

describe("render", function()
  local cols, rows = { "a", "b" }, { { 1, cjson.null }, { "x,y", true } }

  it("csv varsayılan", function()
    assert.are.equal('a,b\r\n1,\r\n"x,y",true\r\n', target_csv.render(cols, rows))
  end)

  it("json: kolon sırası korunur, NULL null", function()
    local out = target_csv.render(cols, rows, { format = "json" })
    assert.truthy(out:find('{"a":1,"b":null}', 1, true))
    local dec = cjson.decode(out)
    assert.are.equal("x,y", dec[2].a)
    assert.is_true(dec[2].b)
  end)

  it("xlsx zip üretir", function()
    assert.are.equal("PK", target_csv.render(cols, rows, { format = "xlsx" }):sub(1, 2))
  end)
end)
