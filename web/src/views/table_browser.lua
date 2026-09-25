-- F19: Tablo tarayıcı (codd) — sayfali/filtreli/siralanabilir satırlar, hucre düzenleme (NULL dahil),
-- ekle/çoğalt/sil, sag tik menusu, CSV, Delete tusu. Satır işlemleri yalnizca PK'li tablolarda
-- (sunucu meta.editable + _rid verir); view ve PK'siz tablolar salt okunur.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local json = require("json")
local protocol = require("pg_shared.protocol")
local filter_bar = require("components.filter_bar")
local pagination = require("components.pagination")
local row_form = require("views.row_form")
local result_grid = require("components.result_grid")

local _M = {}
_M.title = "Tablo Tarayıcı"
_M.layout = true

local selected = {} -- rid -> true (toplu secim)
local focused = nil -- satır indeksi (tek secim: çoğalt/sil/Delete)
local form = nil -- { mode = "insert"|"duplicate", values, state = { modes, errors } }

local GROUP_CLASS = {
  numeric = "text-right tabular-nums text-[var(--cell-number)]", boolean = "text-[var(--cell-bool)]",
  datetime = "text-[var(--cell-date)]", json = "font-mono text-[var(--cell-json)]",
  binary = "font-mono text-[var(--cell-binary)]",
}

local function parse_filters(raw)
  if type(raw) ~= "string" or raw == "" then return {} end
  local ok, dec = pcall(json.decode, raw)
  return ok and type(dec) == "table" and dec or {}
end

local function current_params()
  local cur = router.current() or {}
  local p, q = cur.params or {}, cur.query or {}
  local st = app.get_state()
  return {
    connection_id = q.connection_id or (st.connections.items[1] and st.connections.items[1].id) or "",
    database = q.database,
    schema = p.schema or "public",
    table = p.table or p.name or "",
    page = tonumber(q.page) or 1,
    per_page = tonumber(q.per_page) or tonumber(require("storage").get("per_page")) or 100,
    sort = q.sort,
    filters = parse_filters(q.filters),
    custom_where = q.custom_where or "",
  }
end

local function rows_path(p)
  return "/connections/" .. router.urlencode(p.connection_id) .. "/objects/" .. router.urlencode(p.schema)
    .. "/" .. router.urlencode(p.table) .. "/rows"
end

local function db_query(p) return p.database and ("?database=" .. router.urlencode(p.database)) or "" end

local function load_rows(p)
  if p.connection_id == "" or p.table == "" then return end
  app.dispatch({ type = "TABLE_ROWS_REQUESTED", filters = p.filters, sort = p.sort })
  local q = { page = p.page, per_page = p.per_page, sort = p.sort, database = p.database }
  if #p.filters > 0 then q.filters = json.encode(p.filters) end
  if p.custom_where ~= "" then q.custom_where = p.custom_where end
  local data, err = api.get(rows_path(p), q)
  if err then
    app.dispatch({ type = "TABLE_ROWS_FAILED", error = err })
    app.toast("error", err.message or protocol.message(err.code))
    return
  end
  local meta = data.meta or {}
  app.dispatch({ type = "TABLE_ROWS_LOADED", rows = data.items or {}, columns = meta.columns or {}, meta = meta })
end

local function reload() app.spawn(load_rows, current_params()) end
_M.reload = reload

function _M.enter(route)
  local p = current_params()
  if p.connection_id == "" then
    local data = api.get("/connections", { per_page = 100 })
    if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
    p = current_params()
  end
  local obj = app.get_state().table_browser.object
  if not obj or obj.schema ~= p.schema or obj.name ~= p.table or obj.connection_id ~= p.connection_id then
    selected, focused, form = {}, nil, nil
    filter_bar.close()
    app.dispatch({ type = "TABLE_BROWSER_OBJECT_SET",
      object = { schema = p.schema, name = p.table, connection_id = p.connection_id } })
  end
  load_rows(p)
end

local function set_query(patch) router.replace_query(patch) end -- hashchange → enter → load_rows

-- codd: basliga tiklama artan → azalan → kapali
local function toggle_sort(name)
  local s = current_params().sort
  local nxt = (s == name and "-" .. name) or (s == "-" .. name and "") or name
  set_query({ sort = nxt, page = "1" })
end

local function can_edit(meta) return meta.editable == true and app.can("table.edit") end

-- --- satır işlemleri ---------------------------------------------------------------
local function delete_rows(rids)
  if #rids == 0 then return end
  app.spawn(function()
    local ok = require("components.modal").confirm({ title = #rids > 1 and "Satırlar silinsin mi?" or "Satır silinsin mi?",
      message = tostring(#rids) .. " satır kalıcı olarak silinecek.", confirm_label = "Sil", danger = true })
    if not ok then return end
    local p = current_params()
    local data, err = api.delete(rows_path(p) .. db_query(p), { ids = rids })
    if err then app.toast("error", err.message or protocol.message(err.code)); return end
    app.toast("success", tostring(data and data.deleted or #rids) .. " satır silindi")
    selected, focused = {}, nil
    load_rows(current_params())
  end)
end

local function save_cell(row, col, value)
  local p = current_params()
  app.spawn(function()
    local _, err = api.patch(rows_path(p) .. "/" .. router.urlencode(row._rid) .. db_query(p),
      { values = { [col.name] = value } })
    if err then app.toast("error", err.message or protocol.message(err.code)); return end
    load_rows(current_params())
  end)
end

local function open_form(mode, values)
  form = { mode = mode, values = values, state = { modes = {}, errors = {} } }
  app.schedule_render()
end

local function submit_form(values)
  local p = current_params()
  app.spawn(function()
    local _, err = api.post(rows_path(p) .. db_query(p), { values = values })
    if err then
      form.state.errors = type(err.details) == "table" and err.details or {}
      app.toast("error", err.message or protocol.message(err.code))
      app.schedule_render()
      return
    end
    app.toast("success", form.mode == "duplicate" and "Satır çoğaltıldı" or "Satır eklendi")
    form = nil
    load_rows(current_params())
  end)
end

local function edit_or_view(tb, r, c)
  local row, col = tb.rows[r], tb.columns[c]
  if not row or not col then return end
  if can_edit(tb.meta) and row._rid and not col.read_only then
    row_form.edit_cell(col, row[col.name] == nil and json.null or row[col.name], function(v) save_cell(row, col, v) end)
  else
    local shown = row_form.to_text(row[col.name])
    require("components.modal").show({ id = "cell-viewer", wide = true, title = "Hücre değeri — " .. col.name,
      content = dom.pre({ class = "text-xs p-3 bg-[var(--bg)] rounded overflow-auto max-h-[60vh] whitespace-pre-wrap break-words" },
        row[col.name] == nil and "NULL" or shown) })
  end
end

-- sayfadaki satırlari result_grid kopyalama bicimine cevir
local function as_result(tb)
  local cols, rows = {}, {}
  for j, c in ipairs(tb.columns) do cols[j] = c.name end
  for i, r in ipairs(tb.rows) do
    local row = {}
    for j, c in ipairs(tb.columns) do row[j] = r[c.name] == nil and json.null or r[c.name] end
    rows[i] = row
  end
  return { columns = cols, rows = rows }
end

local function export_csv()
  local p = current_params()
  require("components.csv_dialog").open(p.table .. " → dışa aktar", function(o)
    app.spawn(function()
      local ok, err = api.download((rows_path(p):gsub("/rows$", "/export")), p.table .. "." .. o.ext, nil, {
        format = o.format,
        database = p.database, filters = p.filters, custom_where = p.custom_where ~= "" and p.custom_where or nil,
        sort = p.sort, delimiter = o.delimiter, limit = o.limit, include_header = o.include_header })
      if not ok then app.toast("error", err and err.message or "Dosya indirilemedi") end
    end)
  end)
end

local function copy(text, label) js.clipboard(text); app.toast("success", label .. " kopyalandı") end

local function row_menu(e, tb)
  local r, c = (e.cell or ""):match("^(%d+):(%d+)$")
  r, c = tonumber(r), tonumber(c)
  if not r then return end
  focused = r
  local row, col = tb.rows[r], tb.columns[c]
  local editable = can_edit(tb.meta) and row._rid
  local res = as_result(tb)
  local items = {
    { label = "Değeri düzenle", disabled = not editable or col.read_only, onclick = function() edit_or_view(tb, r, c) end },
    { label = "Satırı çoğalt", disabled = not editable, onclick = function() open_form("duplicate", row) end },
    { separator = true },
    { label = "Hücreyi kopyala", onclick = function() copy(result_grid.copy_text(res, "cell", r, c), "Hücre") end },
    { label = "Satırı kopyala", onclick = function() copy(result_grid.copy_text(res, "row", r, c), "Satır") end },
    { label = "Kolonu kopyala", onclick = function() copy(result_grid.copy_text(res, "column", r, c), "Kolon") end },
    { label = "Sayfayı kopyala", onclick = function() copy(result_grid.copy_text(res, "all"), "Sayfa") end },
  }
  if app.can("export.csv") then items[#items + 1] = { label = "CSV dışa aktar…", onclick = export_csv } end
  if editable then
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Satırı sil…", danger = true, onclick = function() delete_rows({ row._rid }) end }
  end
  require("components.context_menu").open(e, items)
end

-- Delete tusu (klavye kisayolu): odakli satıri sil
function _M.delete_focused()
  local tb = app.get_state().table_browser
  local row = focused and tb.rows[focused]
  if not (row and row._rid and can_edit(tb.meta)) then return false end
  delete_rows({ row._rid })
  return true
end

-- --- render --------------------------------------------------------------------------

local function render_grid(tb, cur)
  local columns, rows, meta = tb.columns, tb.rows, tb.meta
  local selectable = can_edit(meta)
  local head = {}
  if selectable then
    head[1] = dom.th({ class = "py-1 px-2 border-b border-[var(--border)] bg-[var(--bg)] sticky top-0" },
      dom.input({ type = "checkbox", ["aria-label"] = "Sayfadaki tüm satırları seç",
        onchange = function(e)
          for _, r in ipairs(rows) do if r._rid then selected[r._rid] = e.checked == true or nil end end
          app.schedule_render()
        end }))
  end
  for _, col in ipairs(columns) do
    local dir = (cur.sort == col.name and "ascending") or (cur.sort == "-" .. col.name and "descending") or nil
    head[#head + 1] = dom.th({ scope = "col", ["aria-sort"] = dir,
      class = "py-2 px-3 text-left text-xs font-semibold border-b border-[var(--border)] whitespace-nowrap bg-[var(--bg)] sticky top-0" },
      dom.button({ type = "button", class = "inline-flex items-center gap-1 hover:underline", title = col.display_type,
        onclick = function() toggle_sort(col.name) end },
        col.name, col.is_primary_key and dom.span({ class = "text-[10px] text-[var(--primary)]" }, "PK") or nil,
        dom.span({ class = "text-[10px]", ["aria-hidden"] = "true" }, dir == "ascending" and "▲" or dir == "descending" and "▼" or "↕")))
  end
  local body = {}
  for i, row in ipairs(rows) do
    local cells = {}
    if selectable then
      cells[1] = dom.td({ class = "py-1 px-2 border-b border-[var(--border)]" },
        row._rid and dom.input({ type = "checkbox", ["aria-label"] = "Satır " .. i .. " seç",
          checked = selected[row._rid] and "checked" or nil,
          onchange = function(e) selected[row._rid] = e.checked == true or nil; app.schedule_render() end }) or nil)
    end
    for j, col in ipairs(columns) do
      local v = row[col.name]
      local text = v ~= nil and row_form.to_text(v) or nil
      if text and #text > 80 then text = text:sub(1, 80) .. "…" end
      cells[#cells + 1] = dom.td({ ["data-cell"] = i .. ":" .. j,
        class = "py-1.5 px-3 border-b border-[var(--border)] text-sm max-w-60 truncate cursor-default "
          .. (GROUP_CLASS[col.type_group] or "") },
        text == nil and dom.span({ class = "italic text-[var(--fg-muted)] text-xs" }, "NULL") or text)
    end
    body[i] = dom.tr({ key = row._rid or i, ["aria-selected"] = focused == i and "true" or nil,
      class = (focused == i and "outline outline-2 outline-[var(--focus)] " or "")
        .. (row._rid and selected[row._rid] and "bg-[color-mix(in_srgb,var(--primary)_8%,transparent)]" or "hover:bg-[var(--bg-elev)]") },
      dom.list(cells))
  end
  return dom.div({ class = "overflow-auto border border-[var(--border)] rounded max-h-[50vh] sm:max-h-[60vh] -mx-3 sm:mx-0" },
    dom.table({ class = "w-full text-sm border-collapse min-w-[640px]" },
      dom.thead({}, dom.tr({}, dom.list(head))),
      dom.tbody({ ["aria-busy"] = tb.status == "loading" and "true" or nil,
        onclick = function(e)
          local r = tonumber((e.cell or ""):match("^(%d+):"))
          if r and r ~= focused then focused = r; app.schedule_render() end
        end,
        ondblclick = function(e)
          local r, c = (e.cell or ""):match("^(%d+):(%d+)$")
          if r then edit_or_view(tb, tonumber(r), tonumber(c)) end
        end,
        oncontextmenu = function(e) row_menu(e, tb) end,
      }, dom.list(body))),
    #rows == 0 and dom.p({ class = "p-6 text-center text-sm text-[var(--fg-muted)]" }, "Satır yok") or nil)
end

function _M.render(state, dispatch)
  local tb = state.table_browser
  local cur = current_params()
  local meta = tb.meta or {}
  local editable = can_edit(meta)
  local sel_rids = {}
  for rid in pairs(selected) do sel_rids[#sel_rids + 1] = rid end
  local focus_row = focused and tb.rows[focused]
  local nfilters = #cur.filters + (cur.custom_where ~= "" and 1 or 0)

  local header = dom.div({ class = "flex flex-col sm:flex-row sm:items-center justify-between gap-3" },
    dom.h1({ class = "text-lg sm:text-xl font-bold flex flex-wrap items-center gap-2", tabindex = "-1" },
      dom.span({ class = "flex items-center gap-1 min-w-0" },
        dom.span({ class = "font-normal text-[var(--fg-muted)] text-sm sm:text-base" }, cur.schema .. "."),
        dom.span({ class = "truncate" }, cur.table)),
      meta.kind and meta.kind ~= "table" and dom.span({ class = "text-xs px-2 py-0.5 border rounded align-middle shrink-0" }, meta.kind) or nil,
      tb.status == "ready" and not meta.editable and dom.span({ class = "text-xs text-[var(--fg-muted)] align-middle hidden sm:inline" },
        "salt okunur" .. (meta.kind == "table" and " (birincil anahtar yok)" or "")) or nil),
    dom.div({ class = "flex gap-1.5 sm:gap-2 flex-wrap items-center" },
      editable and require("icons").button({ icon = "plus", label = "+ Satır ekle", variant = "accent", class = "btn-sm",
        title = "Yeni satır ekle", onclick = function() open_form("insert", nil) end }) or nil,
      editable and require("icons").button({ icon = "copy", label = "Çoğalt", variant = "secondary", class = "btn-sm",
        disabled = not (focus_row and focus_row._rid), title = "Odaklı satırı çoğalt",
        onclick = function() open_form("duplicate", focus_row) end }) or nil,
      editable and require("icons").button({ icon = "trash", class = "btn-sm",
        label = #sel_rids > 0 and ("Sil (" .. #sel_rids .. ")") or "Sil", variant = "danger",
        disabled = #sel_rids == 0 and not (focus_row and focus_row._rid), title = "Seçili satırları sil",
        onclick = function() delete_rows(#sel_rids > 0 and sel_rids or { focus_row._rid }) end }) or nil,
      require("icons").button({ icon = "filter", label = nfilters > 0 and ("Filtreler (" .. nfilters .. ")") or "Filtreler", class = "btn-sm",
        variant = nfilters > 0 and "accent" or "secondary",
        title = nfilters > 0 and (nfilters .. " filtre aktif") or "Filtreleri aç/kapat",
        ["aria-expanded"] = filter_bar.is_open() and "true" or "false",
        onclick = function()
          if filter_bar.is_open() then filter_bar.close() else filter_bar.open(cur.filters, cur.custom_where) end
          app.schedule_render()
        end }),
      app.can("export.csv") and require("icons").button({ icon = "download", label = "Dışa aktar", class = "btn-sm",
        title = "Dışa aktar (CSV / Excel / JSON)", onclick = export_csv }) or nil,
      require("icons").button({ icon = "refresh", label = "Yenile", variant = "secondary", class = "btn-sm",
        title = "Yenile (Ctrl+R)", onclick = reload }),
      dom.a({ href = "#/structure/" .. router.urlencode(cur.schema) .. "/" .. router.urlencode(cur.table)
          .. "?connection_id=" .. router.urlencode(cur.connection_id) .. (cur.database and ("&database=" .. router.urlencode(cur.database)) or ""),
        class = "inline-flex items-center gap-1.5 px-2.5 sm:px-3 py-1.5 text-xs sm:text-sm border border-[var(--border)] rounded hover:bg-[var(--bg-elev)] hover:border-[var(--primary)] transition-colors" },
        require("icons").get("code", "w-4 h-4"), dom.span({ class = "hidden sm:inline" }, "Yapı"))))

  local body
  if tb.status == "loading" and #tb.rows == 0 then
    body = require("components.skeleton").lines(6)
  elseif tb.status == "error" then
    body = dom.div({ role = "alert", class = "p-4 border border-[var(--danger)] rounded text-sm text-[var(--danger)] flex items-start gap-2" },
      require("icons").get("alert-triangle", "w-5 h-5 shrink-0"), dom.span({}, tostring(tb.error and (tb.error.message or tb.error.code) or "Satırlar yüklenemedi")))
  else
    body = render_grid(tb, cur)
  end

  local form_modal = form and require("components.modal").dialog("row-form",
    form.mode == "duplicate" and "Satırı çoğalt" or "Yeni satır",
    row_form.render({ columns = tb.columns, values = form.values, state = form.state,
      on_submit = submit_form,
      on_cancel = function() form = nil; app.schedule_render() end }),
    function() form = nil; app.schedule_render() end) or nil

  local main = dom.div({ class = "space-y-3 min-w-0" },
    header,
    filter_bar.render({ columns = tb.columns,
      on_apply = function(filters, cw)
        set_query({ filters = #filters > 0 and json.encode(filters) or "", custom_where = cw, page = "1" })
      end }),
    body,
    pagination.render({ page = cur.page, per_page = cur.per_page, total = meta.total }, function(pg)
      set_query({ page = tostring(pg.page), per_page = tostring(pg.per_page) })
    end),
    form_modal)
  return dom.div({ class = "grid grid-cols-1 lg:grid-cols-[260px_1fr] gap-3" },
    require("views.schema_sidebar").render(state, dispatch), main)
end

return _M
