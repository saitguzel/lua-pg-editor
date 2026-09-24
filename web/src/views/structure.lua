-- F19: Yapi inceleme ve duzenleme (codd Structure) — kolonlar, indexler, constraint'ler, FK'ler, trigger'lar,
-- istatistik. Her oge icin sag tik: adi kopyala / yeniden adlandir / sil (bagimlilik hatasinda CASCADE onerisi).
-- Constraint'e bagli index'ler constraint uzerinden yonetilir (salt okunur).
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local protocol = require("pg_shared.protocol")
local object_actions = require("views.object_actions")
local icons = require("icons")

local _M = {}
_M.title = "Yapı"
_M.layout = true

local TABS = {
  { key = "columns", label = "Kolonlar", item = "column" },
  { key = "indexes", label = "Indexler", item = "index" },
  { key = "constraints", label = "Constraint'ler", item = "constraint" },
  { key = "foreign_keys", label = "Foreign Keys", item = "constraint" },
  { key = "triggers", label = "Trigger'lar", item = "trigger" },
  { key = "rules", label = "Rules", read_only = true },
  { key = "policies", label = "Policies", read_only = true },
  { key = "stats", label = "İstatistik" },
}
local active_tab = "columns"
local tree = require("views.schema_tree")

local function params()
  local cur = router.current() or {}
  local p, q = cur.params or {}, cur.query or {}
  local st = app.get_state()
  return { connection_id = q.connection_id or (st.connections.items[1] and st.connections.items[1].id) or "",
    database = q.database, schema = p.schema or "public", name = p.name or "", kind = q.kind }
end

local function base_path(c)
  return "/connections/" .. router.urlencode(c.connection_id) .. "/objects/" .. router.urlencode(c.schema)
    .. "/" .. router.urlencode(c.name)
end

local function db_q(c, extra)
  local parts = {}
  if c.database and c.database ~= "" then parts[#parts + 1] = "database=" .. router.urlencode(c.database) end
  if extra then parts[#parts + 1] = extra end
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function load(c)
  if c.connection_id == "" or c.name == "" then return end
  app.dispatch({ type = "STRUCTURE_REQUESTED", selected = { schema = c.schema, name = c.name } })
  local data, err = api.get(base_path(c) .. "/structure"
    .. db_q(c, c.kind and c.kind ~= "" and ("kind=" .. router.urlencode(c.kind)) or nil))
  if err then app.dispatch({ type = "STRUCTURE_FAILED", error = err }); return end
  app.dispatch({ type = "STRUCTURE_LOADED", data = data })
end

function _M.enter(route)
  local tab = route.query and route.query.tab
  for _, t in ipairs(TABS) do if t.key == tab then active_tab = tab end end
  load(params())
end

local function fail(err) app.toast("error", err and err.message or protocol.message(err and err.code)) end

-- oge eylemleri (kind: column|index|constraint|trigger)
local function rename_item(c, kind, item)
  app.spawn(function()
    local new_name = require("components.modal").prompt({ title = "Yeniden adlandır: " .. item, label = "Yeni ad",
      value = item, validate = function(v)
        if v == "" then return "Ad boş olamaz" end
        if #v > 63 then return "En fazla 63 bayt" end
        if v == item then return "Ad aynı" end
      end })
    if not new_name then return end
    local _, err = api.post(base_path(c) .. "/structure/" .. kind .. "/" .. router.urlencode(item) .. "/rename" .. db_q(c),
      { new_name = new_name })
    if err then return fail(err) end
    app.toast("success", item .. " → " .. new_name)
    load(c)
    pcall(function() require("views.schema_sidebar").reload() end)
  end)
end

local function drop_item(c, kind, item)
  app.spawn(function()
    local modal = require("components.modal")
    if not modal.confirm({ title = "Silinsin mi?", danger = true, confirm_label = "Sil",
      message = item .. " (" .. kind .. ") silinecek." }) then return end
    local path = base_path(c) .. "/structure/" .. kind .. "/" .. router.urlencode(item)
    local _, err = api.delete(path .. db_q(c))
    -- codd: bagimli nesne hatasinda (2BP01) "CASCADE ile sil" onerilir
    if err and err.details and err.details.sqlstate == "2BP01" then
      if not modal.confirm({ title = "Bağımlı nesneler var", danger = true, confirm_label = "CASCADE ile sil",
        message = tostring(err.details.db_message or "Başka nesneler bu öğeye bağlı.") }) then return end
      _, err = api.delete(path .. db_q(c, "cascade=true"))
    end
    if err then return fail(err) end
    app.toast("success", item .. " silindi")
    load(c)
    pcall(function() require("views.schema_sidebar").reload() end)
  end)
end

local function item_menu(e, c, kind, item, read_only)
  local items = { { label = "Adı kopyala", onclick = function() js.clipboard(item); app.toast("success", "Kopyalandı") end } }
  if app.can("object.actions") and not read_only then
    items[#items + 1] = { label = "Yeniden adlandır…", onclick = function() rename_item(c, kind, item) end }
    items[#items + 1] = { label = "Sil…", danger = true, onclick = function() drop_item(c, kind, item) end }
  end
  require("components.context_menu").open(e, items)
end

local TH = "py-2 px-3 text-left text-xs font-semibold text-[var(--fg-muted)] bg-[var(--bg)] border-b border-[var(--border)]"
local TD = "py-1.5 px-3 text-sm border-b border-[var(--border)] align-top"

local function badge(text, cls)
  return dom.span({ class = "inline-flex px-1.5 py-0.5 mr-1 text-[10px] rounded " .. (cls or "border border-[var(--border)]") }, text)
end

-- satirlar: rows = { { name, cells = {...}, read_only } }; sag tik ve "⋯" menusu satir basina
local function section(c, tab, headers, rows)
  if #rows == 0 then
    return dom.p({ class = "p-6 text-center text-sm text-[var(--fg-muted)] border border-dashed border-[var(--border)] rounded" },
      tab.label .. " yok")
  end
  local head = {}
  for i, h in ipairs(headers) do head[i] = dom.th({ scope = "col", class = TH }, h) end
  head[#head + 1] = dom.th({ class = TH }, dom.span({ class = "sr-only" }, "Eylemler"))
  local body = {}
  for i, r in ipairs(rows) do
    local cells = {}
    for j, v in ipairs(r.cells) do cells[j] = dom.td({ class = TD .. (j == 1 and " font-mono" or "") }, v) end
    local function menu(e) item_menu(e, c, tab.item, r.name, r.read_only or tab.read_only) end
    cells[#cells + 1] = dom.td({ class = TD .. " text-right" },
      dom.button({ type = "button", ["aria-label"] = r.name .. " menüsü", ["aria-haspopup"] = "menu",
        class = "px-2 text-[var(--fg-muted)] hover:text-[var(--fg)]", onclick = menu }, "⋯"))
    body[i] = dom.tr({ key = r.name, class = "hover:bg-[var(--bg-elev)]", oncontextmenu = menu }, dom.list(cells))
  end
  return dom.div({ class = "overflow-auto border border-[var(--border)] rounded" },
    dom.table({ class = "w-full text-sm border-collapse" },
      dom.thead({}, dom.tr({}, dom.list(head))), dom.tbody({}, dom.list(body))))
end

local function mono(s) return dom.code({ class = "text-xs whitespace-pre-wrap break-all" }, tostring(s or "")) end

local RENDER = {
  columns = function(d)
    local rows = {}
    for i, col in ipairs(d.columns or {}) do
      local default = col.column_default and mono(col.column_default)
        or (col.is_identity and ("Identity (" .. (col.identity_kind == "ALWAYS" and "Always" or "By default") .. ")"))
        or (col.is_generated and dom.span({}, "Generated: ", mono(col.generation_expression))) or "—"
      rows[i] = { name = col.name, cells = { col.name, col.display_type, col.is_nullable and "Evet" or "Hayır", default,
        col.is_primary_key and badge("PK", "bg-[var(--primary)] text-[var(--primary-fg)]") or "" } }
    end
    return { "Ad", "Tip", "Nullable", "Varsayılan", "Anahtar" }, rows
  end,
  indexes = function(d)
    local rows = {}
    for i, ix in ipairs(d.indexes or {}) do
      rows[i] = { name = ix.name, read_only = ix.constraint_name ~= nil, cells = { ix.name, mono(ix.def),
        dom.span({}, ix.is_primary and badge("Primary") or nil, ix.is_unique and badge("Unique") or nil,
          ix.is_partial and badge("Partial") or nil,
          not ix.is_valid and badge("Invalid", "bg-[var(--danger)] text-white") or nil,
          ix.constraint_name and badge("constraint: " .. ix.constraint_name) or nil) } }
    end
    return { "Ad", "Tanım", "Özellikler" }, rows
  end,
  constraints = function(d)
    local rows = {}
    for i, con in ipairs(d.constraints or {}) do
      rows[i] = { name = con.name, cells = { con.name, con.type, mono(con.def),
        dom.span({}, not con.validated and badge("NOT VALID", "bg-[var(--warning)] text-white") or nil,
          con.deferrable and badge(con.deferred and "Deferred" or "Deferrable") or nil) } }
    end
    return { "Ad", "Tür", "Tanım", "Durum" }, rows
  end,
  foreign_keys = function(d)
    local rows = {}
    for i, fk in ipairs(d.foreign_keys or {}) do
      rows[i] = { name = fk.name, cells = { fk.name, table.concat(fk.columns or {}, ", "),
        fk.ref_schema .. "." .. fk.ref_table .. " (" .. table.concat(fk.ref_columns or {}, ", ") .. ")",
        fk.on_update or "", fk.on_delete or "", fk.deferrable and "Evet" or "Hayır" } }
    end
    return { "Ad", "Kolonlar", "Referans", "ON UPDATE", "ON DELETE", "Deferrable" }, rows
  end,
  triggers = function(d)
    local rows = {}
    for i, tg in ipairs(d.triggers or {}) do
      rows[i] = { name = tg.name, cells = { tg.name, tg.state or "", mono(tg["function"]), mono(tg.def) } }
    end
    return { "Ad", "Durum", "Fonksiyon", "Tanım" }, rows
  end,
  rules = function(d)
    local rows = {}
    for i, r in ipairs(d.rules or {}) do
      rows[i] = { name = r.name, cells = { r.name, tostring(r.event or ""), r.is_instead and "INSTEAD" or "ALSO",
        mono(r.def) } }
    end
    return { "Ad", "Olay", "Tür", "Tanım" }, rows
  end,
  policies = function(d)
    local rows = {}
    for i, p in ipairs(d.policies or {}) do
      rows[i] = { name = p.name, cells = { p.name, tostring(p.command or ""),
        p.permissive == false and "RESTRICTIVE" or "PERMISSIVE", table.concat(p.roles or {}, ", "),
        mono(p.using_expr), mono(p.check_expr) } }
    end
    return { "Ad", "Komut", "Tür", "Roller", "USING", "WITH CHECK" }, rows
  end,
}

-- tablo dışı nesneler (sequence/type/domain/…): detail{} alanları — dizi → rozet/tablo, skaler → metin
local function render_detail(d)
  local det = d.detail or {}
  local keys = {}
  for k in pairs(det) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then
    return dom.p({ class = "p-6 text-center text-sm text-[var(--fg-muted)] border border-dashed "
      .. "border-[var(--border)] rounded" }, "Detay yok")
  end
  local cells = {}
  for i, k in ipairs(keys) do
    local v = det[k]
    local content
    if type(v) == "table" and v[1] ~= nil and type(v[1]) == "table" then
      -- nesne dizisi (attributes, constraints): anahtarlar başlık
      local cols, seen = {}, {}
      for _, row in ipairs(v) do
        for ck in pairs(row) do if not seen[ck] then seen[ck] = true; cols[#cols + 1] = ck end end
      end
      table.sort(cols)
      local head, body = {}, {}
      for j, ck in ipairs(cols) do head[j] = dom.th({ scope = "col", class = TH }, ck) end
      for j, row in ipairs(v) do
        local tds = {}
        for jj, ck in ipairs(cols) do tds[jj] = dom.td({ class = TD }, tostring(row[ck] == nil and "" or row[ck])) end
        body[j] = dom.tr({}, dom.list(tds))
      end
      content = dom.table({ class = "w-full text-sm border-collapse" },
        dom.thead({}, dom.tr({}, dom.list(head))), dom.tbody({}, dom.list(body)))
    elseif type(v) == "table" and v[1] ~= nil then
      local b = {}
      for j, s in ipairs(v) do b[j] = badge(tostring(s)) end
      content = dom.span({}, dom.list(b))
    elseif type(v) == "table" then
      content = mono(require("json").encode(v))
    else
      content = dom.span({ class = "font-mono text-sm break-all" }, tostring(v))
    end
    cells[i] = dom.div({ class = "p-3 border border-[var(--border)] rounded bg-[var(--bg-elev)]" },
      dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, k), dom.dd({ class = "mt-1" }, content))
  end
  return dom.dl({ class = "grid grid-cols-1 md:grid-cols-2 gap-3" }, dom.list(cells))
end

local function human_bytes(n)
  n = tonumber(n)
  if not n then return "—" end
  local units, i = { "B", "KB", "MB", "GB", "TB" }, 1
  while n >= 1024 and i < #units do n, i = n / 1024, i + 1 end
  return (i == 1 and string.format("%d", n) or string.format("%.1f", n)) .. " " .. units[i]
end

local function render_stats(d)
  local s = d.stats or {}
  local items = {
    { "Toplam boyut", human_bytes(d.size_bytes) }, { "Tablo", human_bytes(d.table_bytes) },
    { "Indexler", human_bytes(d.index_bytes) }, { "Canlı satır (tahmini)", s.n_live_tup },
    { "Ölü satır", s.n_dead_tup }, { "Sıralı tarama", s.seq_scan }, { "Index tarama", s.idx_scan },
    { "Son VACUUM", s.last_vacuum or s.last_autovacuum }, { "Son ANALYZE", s.last_analyze or s.last_autoanalyze },
  }
  local cells = {}
  for i, it in ipairs(items) do
    cells[i] = dom.div({ class = "p-3 border border-[var(--border)] rounded bg-[var(--bg-elev)]" },
      dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, it[1]),
      dom.dd({ class = "text-base font-semibold" }, it[2] ~= nil and tostring(it[2]) or "—"))
  end
  return dom.dl({ class = "grid grid-cols-2 md:grid-cols-3 gap-3" }, dom.list(cells))
end

function _M.render(state, dispatch)
  local c = params()
  local s = state.structure
  local d = s.data or {}
  local kind = d.kind or c.kind
  local ctx = { connection_id = c.connection_id, database = c.database, schema = c.schema, name = c.name, kind = kind }
  local relation = kind == nil or tree.RELATION_KINDS[kind] == true

  local header = dom.div({ class = "flex items-center justify-between gap-2 flex-wrap" },
    dom.h1({ class = "text-xl font-bold flex items-center gap-2", tabindex = "-1" },
      icons.get(tree.ICON[kind] or "table", "w-5 h-5 text-[var(--primary)]"),
      dom.span({ class = "font-normal text-[var(--fg-muted)]" }, c.schema .. "."), c.name,
      kind and kind ~= "table" and dom.span({ class = "ml-2 text-xs px-2 py-0.5 border rounded align-middle" },
        tree.KIND_LABEL[kind] or kind) or nil),
    dom.div({ class = "flex gap-2 flex-wrap items-center" },
      relation and dom.a({ href = "#/browse/" .. router.urlencode(c.schema) .. "/" .. router.urlencode(c.name)
        .. "?connection_id=" .. router.urlencode(c.connection_id) .. (c.database and ("&database=" .. router.urlencode(c.database)) or ""),
        class = "inline-flex items-center gap-1.5 px-3 py-1.5 text-sm border border-[var(--border)] rounded hover:bg-[var(--bg-elev)] hover:border-[var(--primary)] transition-colors" },
        icons.get("table", "w-4 h-4"), "İçerik") or nil,
      not relation and app.can("script.generate") and icons.button({ icon = "code", label = "CREATE script",
        variant = "secondary", title = "CREATE script'ini yeni sekmede aç",
        onclick = function() object_actions.script(ctx, "create") end }) or nil,
      icons.button({ icon = "refresh", label = "Yenile", variant = "secondary",
        title = "Yapıyı yenile", onclick = function() app.spawn(load, c) end }),
      d.kind and icons.button({ icon = "settings", label = "Eylemler", variant = "secondary",
        title = "Nesne eylemleri", ["aria-haspopup"] = "menu",
        onclick = function(e) require("components.context_menu").open(e, object_actions.menu_items(ctx)) end }) or nil))

  local body
  if s.status == "loading" and not s.data then
    body = require("components.skeleton").lines(6)
  elseif s.status == "error" then
    body = dom.div({ role = "alert", class = "p-6 text-center border border-[var(--danger)] rounded space-y-3" },
      dom.div({ class = "flex justify-center text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
      dom.p({ class = "mb-3" }, s.error and s.error.code == "OBJECT_NOT_FOUND" and (c.schema .. "." .. c.name .. " bulunamadı")
        or tostring(s.error and s.error.message or "Yapı yüklenemedi")),
      icons.button({ icon = "refresh", label = "Tekrar dene", variant = "secondary",
        onclick = function() app.spawn(load, c) end }))
  elseif not relation then
    body = render_detail(d)
  else
    local tab_buttons, current = {}, TABS[1]
    for i, t in ipairs(TABS) do
      if t.key == active_tab then current = t end
      local count = t.key ~= "stats" and #(d[t.key] or {}) or nil
      local tab_icon = ({ columns = "table", indexes = "list", constraints = "shield", foreign_keys = "link",
        triggers = "zap", rules = "code", policies = "key", stats = "info" })[t.key]
      tab_buttons[i] = dom.button({ type = "button", ["aria-pressed"] = t.key == active_tab and "true" or "false",
        class = t.key == active_tab
          and "inline-flex items-center gap-1.5 px-3 py-1.5 text-sm rounded bg-[var(--primary)] text-[var(--primary-fg)]"
          or "inline-flex items-center gap-1.5 px-3 py-1.5 text-sm rounded border border-[var(--border)] hover:bg-[var(--bg-elev)]",
        onclick = function()
          active_tab = t.key
          router.replace_query({ tab = t.key }, { silent = true })
          app.schedule_render()
        end }, tab_icon and icons.get(tab_icon, "w-3.5 h-3.5") or nil, t.label .. (count and (" (" .. count .. ")") or ""))
    end
    local content
    if current.key == "stats" then
      content = render_stats(d)
    else
      local headers, rows = RENDER[current.key](d)
      content = section(c, current, headers, rows)
    end
    body = dom.div({ class = "space-y-3" },
      dom.div({ class = "flex gap-1.5 flex-wrap", role = "group", ["aria-label"] = "Yapı bölümleri" }, dom.list(tab_buttons)),
      content)
  end

  return dom.div({ class = "grid grid-cols-1 lg:grid-cols-[260px_1fr] gap-3" },
    require("views.schema_sidebar").render(state, dispatch),
    dom.div({ class = "space-y-4 min-w-0" }, header, body))
end

return _M
