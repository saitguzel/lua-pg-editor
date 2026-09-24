-- CSV dışa aktarma seçenekleri (codd): ayraç (virgül/noktalı virgül/sekme), satır limiti (1–50.000,
-- varsayılan 1000), başlık satırı. Satır sonu CRLF (sunucu). on_export({ delimiter, limit, include_header })
local dom = require("dom")

local csv_dialog = {}

local last = { delimiter = ",", limit = 1000, include_header = true } -- oturum içinde hatırlanır

function csv_dialog.open(title, on_export)
  local cls = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm"
  local function opt(v, label) return dom.option({ value = v, selected = last.delimiter == v and "selected" or nil }, label) end
  require("components.modal").show({
    id = "csv-dialog", title = title or "CSV dışa aktar",
    content = dom.div({ class = "space-y-3" },
      dom.label({ class = "block text-sm space-y-1" }, "Ayraç",
        dom.select({ id = "csv-delimiter", class = cls }, opt(",", "Virgül (,)"), opt(";", "Noktalı virgül (;)"), opt("\t", "Sekme"))),
      dom.label({ class = "block text-sm space-y-1" }, "Satır limiti (1–50.000)",
        dom.input({ id = "csv-limit", type = "number", min = "1", max = "50000", value = tostring(last.limit), class = cls })),
      dom.label({ class = "flex items-center gap-2 text-sm" },
        dom.input({ id = "csv-header", type = "checkbox", checked = last.include_header and "checked" or nil }), "Başlık satırı")),
    actions = { { label = "Dışa aktar", class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
      onclick = function()
        last = {
          delimiter = dom.value("csv-delimiter") or ",",
          limit = math.max(1, math.min(50000, math.floor(tonumber(dom.value("csv-limit")) or 1000))),
          include_header = dom.checked("csv-header") == true,
        }
        on_export({ delimiter = last.delimiter, limit = last.limit, include_header = last.include_header })
      end } },
  })
end

return csv_dialog
