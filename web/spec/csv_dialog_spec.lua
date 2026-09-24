-- F28: Dışa aktarma diyaloğu — format başına gösterilen alanlar (ayraç yalnız CSV, başlık CSV+XLSX).
require("helper")
local csv_dialog = require("components.csv_dialog")

describe("csv_dialog.fields", function()
  it("csv: ayraç ve başlık satırı gösterilir", function()
    assert.same({ delimiter = true, header = true }, csv_dialog.fields("csv"))
  end)

  it("xlsx: ayraç gizli, başlık satırı gösterilir", function()
    assert.same({ delimiter = false, header = true }, csv_dialog.fields("xlsx"))
  end)

  it("json: ayraç ve başlık satırı gizli", function()
    assert.same({ delimiter = false, header = false }, csv_dialog.fields("json"))
  end)
end)
