-- F18: Sorgu sonuc tablosu — tipe gore renkli hucreler, NULL rozeti, hucre goruntuleyici (cift tik),
-- sag tik kopyalama menusu (hucre/satir/kolon/tumu TSV), satir limiti ve "N+ satir" isareti.
-- Olaylar tbody'de tek dinleyiciyle (data-cell="satir:kolon") dagitilir: satir basina closure yok.
local dom = require("dom")
local json = require("json")

local result_grid = {}

-- column_types (pgmoon tip adi) → hucre sinifi
local NUM = "text-right tabular-nums text-[var(--cell-number)]"
local DATE = "text-[var(--cell-date)]"
local TYPE_CLASS = {
  number = NUM, int8 = NUM, numeric = NUM,
  boolean = "text-[var(--cell-bool)]",
  date = DATE, time = DATE, timetz = DATE, timestamp = DATE, timestamptz = DATE,
  json = "font-mono text-[var(--cell-json)]",
  bytea_hex = "font-mono text-[var(--cell-binary)]",
}
local function type_class(t)
  if not t then return "" end
  return TYPE_CLASS[t] or (t:find("^array_") and TYPE_CLASS.json) or ""
end

-- hucre degerini metne cevir; NULL → nil (cagiran gosterimi secer)
local function cell_text(v)
  if v == nil or v == json.null then return nil end
  if type(v) == "table" then
    local ok, s = pcall(json.encode, v)
    return ok and s or tostring(v)
  end
  if type(v) == "boolean" then return v and "true" or "false" end
  return tostring(v)
end
result_grid.cell_text = cell_text

-- TSV hucresi: NULL bos, sekme/satir sonu bosluga
local function tsv(v)
  return ((cell_text(v) or ""):gsub("[\t\r\n]", " "))
end

-- what: cell | row | column | all
function result_grid.copy_text(result, what, r, c)
  local cols, rows = result.columns or {}, result.rows or {}
  local function row_line(row)
    local out = {}
    for j = 1, #cols do out[j] = tsv(row[j]) end
    return table.concat(out, "\t")
  end
  if what == "cell" then return cell_text(rows[r] and rows[r][c]) or "NULL" end
  if what == "row" then return row_line(rows[r] or {}) end
  if what == "column" then
    local out = {}
    for i, row in ipairs(rows) do out[i] = tsv(row[c]) end
    return table.concat(out, "\n")
  end
  local out = { table.concat(cols, "\t") }
  for _, row in ipairs(rows) do out[#out + 1] = row_line(row) end
  return table.concat(out, "\n")
end

local function copy(text, label)
  js.clipboard(text)
  require("app").toast("success", label .. " kopyalandı")
end

local function parse_cell(e)
  local r, c = (e.cell or ""):match("^(%d+):(%d+)$")
  return tonumber(r), tonumber(c)
end

function result_grid.show_cell(result, r, c)
  local v = result.rows[r] and result.rows[r][c]
  local text = cell_text(v)
  local shown = "NULL"
  if text then
    shown = (type(v) == "table" or text:match("^%s*[%[{]")) and js.json.pretty(text) or text
  end
  require("components.modal").show({
    id = "cell-viewer", wide = true,
    title = "Hücre değeri — " .. tostring(result.columns[c] or ""),
    content = dom.pre({ class = "text-xs p-3 bg-[var(--bg)] rounded overflow-auto max-h-[60vh] whitespace-pre-wrap break-words" },
      shown),
    actions = { { label = "Kopyala", onclick = function() copy(text or "NULL", "Değer") end } },
  })
end

local function cell_menu(e, result, opts)
  local r, c = parse_cell(e)
  if not r then return end
  local items = {
    { label = "Hücreyi kopyala", onclick = function() copy(result_grid.copy_text(result, "cell", r, c), "Hücre") end },
    { label = "Satırı kopyala", onclick = function() copy(result_grid.copy_text(result, "row", r, c), "Satır") end },
    { label = "Kolonu kopyala", onclick = function() copy(result_grid.copy_text(result, "column", r, c), "Kolon") end },
    { label = "Görüntülenen sonuçları kopyala", onclick = function() copy(result_grid.copy_text(result, "all"), "Sonuçlar") end },
    { label = "Değeri görüntüle", onclick = function() result_grid.show_cell(result, r, c) end },
  }
  if opts.on_export then
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "CSV dışa aktar…", onclick = opts.on_export }
  end
  require("components.context_menu").open(e, items)
end

local function render_error(err)
  local msg = err and (err.message or err.details and err.details.db_message or err.code) or "Sorgu hatası"
  local sqlstate = err and err.details and err.details.sqlstate or nil
  return dom.div({ role = "alert",
    class = "p-3 bg-[color-mix(in_srgb,var(--danger)_12%,transparent)] border border-[var(--danger)] rounded-[var(--radius)]" },
    sqlstate and dom.div({ class = "inline-flex px-2 py-0.5 text-xs rounded bg-[var(--danger)] text-white mb-2" }, sqlstate) or nil,
    dom.pre({ class = "text-sm text-[var(--danger)] whitespace-pre-wrap break-words" }, tostring(msg)),
    err and err.details and err.details.db_message and err.details.db_message ~= msg
      and dom.pre({ class = "text-xs text-[var(--fg-muted)] mt-2 whitespace-pre-wrap" }, tostring(err.details.db_message)) or nil)
end

-- opts: { row_limit, on_row_limit(n), on_export() }
function result_grid.render(result, opts)
  opts = opts or {}
  if not result then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)]" }, "Henüz sonuç yok.")
  end
  if result.error then return render_error(result.error) end

  local columns = result.columns or {}
  local types = result.column_types or {}
  local rows = result.rows or {}
  local row_count = result.row_count or #rows
  local duration = result.duration_ms

  -- satir tanimi olmayan komut (INSERT/UPDATE/DDL): etkilenen satir mesaji
  if #columns == 0 then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)]", role = "status" },
      tostring(row_count) .. " satır etkilendi" .. (duration and (" · " .. tostring(duration) .. " ms") or ""))
  end

  local header_cells = {}
  for j, name in ipairs(columns) do
    header_cells[j] = dom.th({ scope = "col", title = types[j],
      class = "py-2 px-3 text-left font-semibold border-b border-[var(--border)] whitespace-nowrap bg-[var(--bg)] sticky top-0" },
      tostring(name))
  end

  local body_rows = {}
  for i, row in ipairs(rows) do
    local cells = {}
    for j = 1, #columns do
      local text = cell_text(row[j])
      local shown = text
      if shown and #shown > 120 then shown = shown:sub(1, 120) .. "…" end
      cells[j] = dom.td({ ["data-cell"] = i .. ":" .. j, title = text and #text > 120 and text:sub(1, 500) or nil,
        class = "py-1.5 px-3 border-b border-[var(--border)] text-sm max-w-60 truncate " .. type_class(types[j]) },
        text == nil and dom.span({ class = "italic text-[var(--fg-muted)] text-xs" }, "NULL") or shown)
    end
    body_rows[i] = dom.tr({ key = i, class = "hover:bg-[var(--bg-elev)]" }, dom.list(cells))
  end

  local limit_input = opts.on_row_limit and dom.label({ class = "flex items-center gap-1" }, "Satır limiti",
    dom.input({ type = "number", min = "1", max = "50000", value = tostring(opts.row_limit or 1000),
      class = "w-24 px-2 py-0.5 border border-[var(--border)] rounded bg-[var(--bg)]",
      onchange = function(e)
        local n = math.floor(tonumber(e.value) or 1000)
        opts.on_row_limit(math.max(1, math.min(50000, n)))
      end })) or nil

  return dom.div({ class = "space-y-2" },
    dom.div({ class = "overflow-auto border border-[var(--border)] rounded-[var(--radius)] max-h-[32rem]" },
      dom.table({ class = "w-full text-sm border-collapse" },
        dom.thead({}, dom.tr({}, dom.list(header_cells))),
        dom.tbody({
          ondblclick = function(e) local r, c = parse_cell(e); if r then result_grid.show_cell(result, r, c) end end,
          oncontextmenu = function(e) cell_menu(e, result, opts) end,
        }, dom.list(body_rows)))),
    #rows == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)] p-2" }, "Sorgu satır döndürmedi") or nil,
    dom.div({ class = "flex items-center gap-3 flex-wrap text-xs text-[var(--fg-muted)]", role = "status" },
      dom.span({}, tostring(row_count) .. (result.truncated and "+" or "") .. " satır"),
      duration and dom.span({}, tostring(duration) .. " ms") or nil,
      result.truncated and dom.span({ class = "px-2 py-0.5 rounded bg-[var(--warning)] text-white" },
        "satır limitine ulaşıldı") or nil,
      limit_input,
      dom.span({}, "Çift tık: değeri görüntüle · Sağ tık: kopyala")))
end

return result_grid
