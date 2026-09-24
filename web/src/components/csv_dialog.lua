-- Dışa aktarma seçenekleri (codd): format (CSV/Excel/JSON), ayraç (yalnız CSV), satır limiti (1–50.000,
-- varsayılan 1000), başlık satırı. on_export({ format, ext, delimiter, limit, include_header })
local dom = require("dom")

local csv_dialog = {}

local last = { format = "csv", delimiter = ",", limit = 1000, include_header = true } -- oturum içinde hatırlanır

csv_dialog.FORMATS = { { "csv", "CSV (.csv)" }, { "xlsx", "Excel (.xlsx)" }, { "json", "JSON (.json)" } }

function csv_dialog.open(title, on_export)
  local cls = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm"
  local function opt(v, label) return dom.option({ value = v, selected = last.delimiter == v and "selected" or nil }, label) end
  require("components.modal").show({
    id = "csv-dialog", title = title or "Dışa aktar",
    content = dom.div({ class = "space-y-3" },
      dom.label({ class = "block text-sm space-y-1" }, "Format",
        dom.select({ id = "export-format", class = cls }, (function()
          local o = {}
          for i, f in ipairs(csv_dialog.FORMATS) do
            o[i] = dom.option({ value = f[1], selected = last.format == f[1] and "selected" or nil }, f[2])
          end
          return o
        end)())),
      dom.label({ class = "block text-sm space-y-1" }, "Ayraç (yalnızca CSV)",
        dom.select({ id = "csv-delimiter", class = cls }, opt(",", "Virgül (,)"), opt(";", "Noktalı virgül (;)"), opt("\t", "Sekme"))),
      dom.label({ class = "block text-sm space-y-1" }, "Satır limiti (1–50.000)",
        dom.input({ id = "csv-limit", type = "number", min = "1", max = "50000", value = tostring(last.limit), class = cls })),
      dom.label({ class = "flex items-center gap-2 text-sm" },
        dom.input({ id = "csv-header", type = "checkbox", checked = last.include_header and "checked" or nil }), "Başlık satırı")),
    actions = { { label = "İndir", class = "btn btn-accent",
      onclick = function()
        last = {
          format = dom.value("export-format") or "csv",
          delimiter = dom.value("csv-delimiter") or ",",
          limit = math.max(1, math.min(50000, math.floor(tonumber(dom.value("csv-limit")) or 1000))),
          include_header = dom.checked("csv-header") == true,
        }
        on_export({ format = last.format, ext = last.format, delimiter = last.delimiter, limit = last.limit,
          include_header = last.include_header })
      end } },
  })
end

return csv_dialog
