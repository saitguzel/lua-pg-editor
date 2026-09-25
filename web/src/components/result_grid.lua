-- F18: Sorgu sonuc tablosu — tipe gore renkli hucreler, NULL rozeti, hucre goruntuleyici (cift tik),
-- sag tik kopyalama menusu (hucre/satır/kolon/tumu TSV), satır limiti ve "N+ satır" isareti.
-- Olaylar tbody'de tek dinleyiciyle (data-cell="satır:kolon") dagitilir: satır basina closure yok.
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

-- hucre degerini metne cevir; NULL → nil (cagiran gösterimi secer)
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

-- TSV hucresi: NULL bos, sekme/satır sonu bosluga
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
    items[#items + 1] = { label = "Dışa aktar (CSV / Excel / JSON)…", onclick = opts.on_export }
  end
  require("components.context_menu").open(e, items)
end

-- F28: satır döndürmeyen komut mesajı — DML: "INSERT: 3 satır etkilendi", DDL: "CREATE TABLE tamamlandı"
local DML = { INSERT = true, UPDATE = true, DELETE = true, MERGE = true, COPY = true }
function result_grid.command_message(command, row_count)
  local cmd = type(command) == "string" and command ~= "affected" and command or nil
  if not cmd or DML[cmd] then
    return (cmd and (cmd .. ": ") or "") .. tostring(row_count or 0) .. " satır etkilendi"
  end
  return cmd .. " tamamlandı"
end

-- F28: istemci sayfalama yardımcıları (saf)
function result_grid.page_count(n, size)
  return math.max(1, math.ceil((tonumber(n) or 0) / math.max(1, tonumber(size) or 100)))
end
function result_grid.page_slice(n, page, size)
  size = math.max(1, tonumber(size) or 100)
  page = math.max(1, math.min(tonumber(page) or 1, result_grid.page_count(n, size)))
  local first = (page - 1) * size + 1
  return first, math.min(n, first + size - 1)
end

-- sayfa durumu: sonuç nesnesi değişince 1. sayfaya döner
local paging = { result = nil, page = 1 }
local function current_page(result)
  if paging.result ~= result then paging.result, paging.page = result, 1 end
  return paging.page
end
local function page_size()
  local n = tonumber(require("storage").get("result_page_size"))
  return n and n >= 1 and math.floor(n) or 100
end

-- opts.on_goto_line(line): hata satırı rozetine tıklanınca editörde vurgu (F27)
local function render_error(err, opts)
  local msg = err and (err.message or err.details and err.details.db_message or err.code) or "Sorgu hatası"
  local d = err and err.details or {}
  local sqlstate = d.sqlstate
  local pos = d.line and (" · satır " .. tostring(d.line) .. ", sütun " .. tostring(d.column or "?")) or ""
  return dom.div({ role = "alert",
    class = "p-3 bg-[color-mix(in_srgb,var(--danger)_12%,transparent)] border border-[var(--danger)] rounded-[var(--radius)]" },
    (sqlstate or d.line) and dom.button({ type = "button",
      class = "inline-flex px-2 py-0.5 text-xs rounded bg-[var(--danger)] text-white mb-2",
      title = d.line and "Editörde satıra git" or nil, ["aria-label"] = "Hata konumu",
      onclick = function() if d.line and opts and opts.on_goto_line then opts.on_goto_line(d.line) end end },
      (sqlstate or "hata") .. pos) or nil,
    dom.pre({ class = "text-sm text-[var(--danger)] whitespace-pre-wrap break-words" }, tostring(msg)),
    err and err.details and err.details.db_message and err.details.db_message ~= msg
      and dom.pre({ class = "text-xs text-[var(--fg-muted)] mt-2 whitespace-pre-wrap" }, tostring(err.details.db_message)) or nil)
end

-- opts: { row_limit, on_row_limit(n), on_export(), scroll_class, on_goto_line(line), on_fetch_all(), max_row_limit }
function result_grid.render(result, opts)
  opts = opts or {}
  if not result then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)]" },
      "Henüz sonuç yok. Ctrl+Enter çalıştırır; sonuç hücresine sağ tık kopyalar, çift tık tam içeriği açar.")
  end
  if result.error then return render_error(result.error, opts) end

  local columns = result.columns or {}
  local types = result.column_types or {}
  local rows = result.rows or {}
  local row_count = result.row_count or #rows
  local duration = result.duration_ms

  -- satır tanimi olmayan komut (INSERT/UPDATE/DDL): komut + etkilenen satır mesaji
  if #columns == 0 then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)] flex items-center gap-2", role = "status" },
      require("icons").get("check", "w-4 h-4 text-[var(--success,#16a34a)]"),
      result_grid.command_message(result.command, row_count)
        .. (duration and (" · " .. tostring(duration) .. " ms") or ""))
  end

  -- F28: istemci sayfalama — yalnız görünen sayfa DOM'a girer; kopyala/dışa aktar tüm satırları kapsar
  local size = page_size()
  local page = current_page(result)
  local first, last = result_grid.page_slice(#rows, page, size)
  local paged = #rows > size

  local header_cells = {}
  for j, name in ipairs(columns) do
    header_cells[j] = dom.th({ scope = "col", title = types[j],
      class = "py-2 px-3 text-left font-semibold border-b border-[var(--border)] whitespace-nowrap bg-[var(--bg)] sticky top-0" },
      tostring(name))
  end

  local body_rows = {}
  for i = first, (#rows > 0 and last or 0) do
    local row = rows[i]
    local cells = {}
    for j = 1, #columns do
      local text = cell_text(row[j])
      local shown = text
      if shown and #shown > 120 then shown = shown:sub(1, 120) .. "…" end
      cells[j] = dom.td({ ["data-cell"] = i .. ":" .. j, title = text and #text > 120 and text:sub(1, 500) or nil,
        class = "py-1.5 px-3 border-b border-[var(--border)] text-sm max-w-60 truncate " .. type_class(types[j]) },
        text == nil and dom.span({ class = "italic text-[var(--fg-muted)] text-xs" }, "NULL") or shown)
    end
    body_rows[#body_rows + 1] = dom.tr({ key = i, class = "hover:bg-[var(--bg-elev)]" }, dom.list(cells))
  end

  local pager = paged and require("components.pagination").render(
    { page = page, per_page = size, total = #rows, sizes = { 50, 100, 250, 500, 1000 } },
    function(p)
      if p.per_page ~= size then require("storage").set("result_page_size", p.per_page) end
      paging.page = p.page
      require("app").schedule_render()
    end) or nil
  local fetch_all = result.truncated and opts.on_fetch_all and (opts.row_limit or 0) < (opts.max_row_limit or 50000)
    and dom.button({ type = "button", class = "btn btn-secondary btn-sm",
      title = "Aynı sorguyu sunucu tavanıyla yeniden çalıştır", onclick = opts.on_fetch_all },
      "Tümünü getir (maks " .. tostring(opts.max_row_limit or 50000) .. ")") or nil

  local limit_input = opts.on_row_limit and dom.label({ class = "flex items-center gap-1" }, "Satır limiti",
    dom.input({ type = "number", min = "1", max = "50000", value = tostring(opts.row_limit or 1000),
      class = "w-24 px-2 py-0.5 border border-[var(--border)] rounded bg-[var(--bg)]",
      onchange = function(e)
        local n = math.floor(tonumber(e.value) or 1000)
        opts.on_row_limit(math.max(1, math.min(50000, n)))
      end })) or nil

  return dom.div({ class = "space-y-2" },
    dom.div({ class = "overflow-auto border border-[var(--border)] rounded-[var(--radius)] -mx-3 sm:mx-0 "
      .. (opts.scroll_class or "max-h-[32rem]") },
      dom.table({ class = "w-full text-sm border-collapse min-w-[480px]" },
        dom.thead({}, dom.tr({}, dom.list(header_cells))),
        dom.tbody({
          ondblclick = function(e) local r, c = parse_cell(e); if r then result_grid.show_cell(result, r, c) end end,
          oncontextmenu = function(e) cell_menu(e, result, opts) end,
        }, dom.list(body_rows)))),
    #rows == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)] p-2" }, "Sorgu satır döndürmedi") or nil,
    pager,
    dom.div({ class = "flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3 flex-wrap text-xs text-[var(--fg-muted)]", role = "status" },
      dom.div({ class = "flex items-center gap-2 flex-wrap" },
        dom.span({}, (paged and (first .. "–" .. last .. " / ") or "")
          .. tostring(row_count) .. (result.truncated and "+" or "") .. " satır"),
        duration and dom.span({}, tostring(duration) .. " ms") or nil,
        result.truncated and dom.span({ class = "px-2 py-0.5 rounded bg-[var(--warning)] text-white shrink-0" },
          "satır limitine ulaşıldı") or nil),
      dom.div({ class = "flex items-center gap-2 flex-wrap" },
        fetch_all,
        limit_input),
      dom.span({ class = "hidden sm:inline" }, "Çift tık: değeri görüntüle · Sağ tık: kopyala")))
end

return result_grid
