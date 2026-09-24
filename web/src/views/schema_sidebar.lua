-- F18: Nesne kenar cubugu (codd sidebar) — semaya gore gruplu tablo/view/matview agaci, arama (Ctrl+F),
-- yenile (F5), baglanti basina gizle/goster, nesne menusu (sag tik / "⋯"). Tiklama tablo tarayicisini acar.
-- Veri: GET /connections/:id/completion (sunucuda onbellekli tek katalog; autocomplete ile ortak).
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local storage = require("storage")
local object_actions = require("views.object_actions")

local _M = {}

local ICON = { table = "▭", partitioned = "▦", view = "◫", matview = "◧", foreign = "⇄" }
local KIND_LABEL = { table = "tablo", partitioned = "bölümlü tablo", view = "view", matview = "materialized view",
  foreign = "foreign table" }

local cache = { key = nil, catalog = nil, status = "idle", error = nil }
local expanded = {} -- sema -> true/false (kullanici secimi)
local search = ""

-- aktif baglanti/DB: sorgu sekmesi ya da tarayici/yapi sayfasinin URL'i
local function context(state)
  local r = state.route
  if r.name == "browse" or r.name == "structure" then
    local q = r.query or {}
    return q.connection_id, q.database, r.params and r.params.schema, r.params and (r.params.table or r.params.name)
  end
  local tab = state.query.tabs[state.query.active_tab]
  local conn = tab and tab.connection_id or (state.connections.items[1] and state.connections.items[1].id)
  return conn, tab and tab.database
end

local function load(conn, db, force)
  if not conn or conn == "" then return end
  local key = conn .. "|" .. (db or "")
  if not force and cache.key == key and cache.status ~= "error" then return end
  cache = { key = key, catalog = cache.key == key and cache.catalog or nil, status = "loading" }
  app.schedule_render()
  local q = db and db ~= "" and { database = db } or nil
  local data, err = api.get("/connections/" .. router.urlencode(conn) .. "/completion", q)
  if cache.key ~= key then return end -- bu arada baglanti degisti
  if err then
    cache.status, cache.error = "error", err
  else
    cache.catalog, cache.status = data, "ready"
    app.dispatch({ type = "COMPLETION_LOADED", catalog = data })
  end
  app.schedule_render()
end

function _M.load_for_connection(conn, db) app.spawn(load, conn, db, true) end

function _M.reload()
  local conn, db = context(app.get_state())
  app.spawn(load, conn, db, true)
end

function _M.focus_search()
  js.dom.focusFirst("#sidebar-search")
  return true
end

local function hidden_key(conn) return "sidebar_hidden:" .. tostring(conn) end

local function object_row(ctx, selected)
  local href = "#/browse/" .. router.urlencode(ctx.schema) .. "/" .. router.urlencode(ctx.name)
    .. "?connection_id=" .. router.urlencode(ctx.connection_id)
    .. (ctx.database and ctx.database ~= "" and ("&database=" .. router.urlencode(ctx.database)) or "")
  local function menu(e)
    require("components.context_menu").open(e, object_actions.menu_items(ctx, {
      { label = "Tarayıcıda aç", onclick = function() router.navigate(href) end },
      { label = "Yapıyı aç", onclick = function() router.navigate((href:gsub("^#/browse/", "#/structure/"))) end },
      { label = "SELECT'i editöre ekle", onclick = function()
        require("views.query_editor").append_sql('SELECT * FROM "' .. ctx.schema:gsub('"', '""') .. '"."'
          .. ctx.name:gsub('"', '""') .. '" LIMIT 100;')
        if app.get_state().route.name ~= "query" then router.navigate("#/query") end
      end },
      { separator = true },
    }))
  end
  return dom.li({ key = ctx.schema .. "." .. ctx.name,
    class = "group flex items-center gap-1 pl-5 pr-1 rounded text-sm "
      .. (selected and "bg-[color-mix(in_srgb,var(--primary)_14%,transparent)] font-medium" or "hover:bg-[var(--bg)]"),
    oncontextmenu = menu },
    dom.span({ class = "text-xs w-4 text-center text-[var(--fg-muted)]", title = KIND_LABEL[ctx.kind],
      ["aria-hidden"] = "true" }, ICON[ctx.kind] or "▭"),
    dom.a({ href = href, class = "flex-1 truncate py-1", title = ctx.schema .. "." .. ctx.name .. " (" .. (KIND_LABEL[ctx.kind] or "") .. ")",
      ["aria-current"] = selected and "page" or nil }, ctx.name),
    dom.button({ type = "button", ["aria-label"] = ctx.name .. " menüsü", ["aria-haspopup"] = "menu",
      class = "px-1.5 text-[var(--fg-muted)] opacity-60 group-hover:opacity-100 focus:opacity-100",
      onclick = menu }, "⋯"))
end

function _M.render(state, dispatch)
  local conn, db, sel_schema, sel_name = context(state)
  if conn and conn ~= "" then
    local key = conn .. "|" .. (db or "")
    if cache.key ~= key and cache.status ~= "loading" then app.spawn(load, conn, db, false) end
  end

  local hidden = conn and storage.get(hidden_key(conn)) == true
  local toggle = dom.button({ type = "button", class = "text-xs px-2 py-1 border border-[var(--border)] rounded",
    ["aria-expanded"] = hidden and "false" or "true",
    onclick = function()
      if hidden then storage.remove(hidden_key(conn)) else storage.set(hidden_key(conn), true) end
      app.schedule_render()
    end }, hidden and "Nesneleri göster" or "Gizle")
  if hidden then
    return dom.aside({ ["aria-label"] = "Veritabanı nesneleri", class = "flex lg:block" }, toggle)
  end

  local header = dom.div({ class = "flex items-center justify-between gap-1" },
    dom.h2({ class = "text-sm font-semibold" }, "Nesneler"),
    dom.div({ class = "flex gap-1" },
      dom.button({ type = "button", class = "text-xs px-2 py-1 border border-[var(--border)] rounded",
        title = "Nesneleri yenile (F5)", onclick = _M.reload }, "Yenile"),
      toggle))

  local body
  local catalog = cache.catalog
  if not conn or conn == "" then
    body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "PostgreSQL'e bağlanın: bir bağlantı seçin")
  elseif not catalog and cache.status == "error" then
    body = dom.p({ role = "alert", class = "text-xs text-[var(--danger)] p-2" },
      tostring(cache.error and (cache.error.message or cache.error.code) or "Şema yüklenemedi"))
  elseif not catalog then
    body = require("components.skeleton").lines(4)
  else
    local needle = search:lower()
    local groups, any = {}, false
    for _, sch in ipairs(catalog.schemas or {}) do
      local rows = {}
      for _, t in ipairs(sch.tables or {}) do
        if needle == "" or t.name:lower():find(needle, 1, true) then
          rows[#rows + 1] = object_row({ connection_id = conn, database = db, schema = sch.name, name = t.name, kind = t.kind },
            sch.name == sel_schema and t.name == sel_name)
        end
      end
      if #rows > 0 or needle == "" then
        any = any or #rows > 0
        -- codd: public, secili nesnenin semasi ve arama sirasinda tum semalar acik
        local open = expanded[sch.name]
        if open == nil then open = sch.name == "public" or sch.name == sel_schema end
        if needle ~= "" then open = true end
        groups[#groups + 1] = dom.li({ key = sch.name },
          dom.button({ type = "button", ["aria-expanded"] = open and "true" or "false",
            class = "w-full flex items-center gap-1 px-1 py-1 text-sm hover:bg-[var(--bg)] text-left rounded",
            onclick = function() expanded[sch.name] = not open; app.schedule_render() end },
            dom.span({ class = "text-xs w-3", ["aria-hidden"] = "true" }, open and "▾" or "▸"),
            dom.span({ class = "font-medium" }, sch.name),
            dom.span({ class = "ml-auto text-[10px] text-[var(--fg-muted)]" }, tostring(#rows))),
          open and dom.ul({ class = "space-y-0.5" }, dom.list(rows)) or nil)
      end
    end
    if needle ~= "" and not any then
      body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "Eşleşen nesne yok")
    elseif #groups == 0 then
      body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "Tablo veya view bulunamadı")
    else
      body = dom.ul({ class = "space-y-0.5", ["aria-busy"] = cache.status == "loading" and "true" or nil }, dom.list(groups))
    end
  end

  return dom.aside({ ["aria-label"] = "Veritabanı nesneleri",
    class = "border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] p-2 space-y-2 self-start" },
    header,
    dom.input({ id = "sidebar-search", type = "search", value = search, placeholder = "Nesne ara (Ctrl+F)",
      ["aria-label"] = "Nesne ara",
      class = "w-full px-2 py-1 text-sm border border-[var(--border)] rounded bg-[var(--bg)]",
      oninput = function(e) search = e.value or ""; app.schedule_render() end }),
    dom.div({ class = "max-h-[70vh] overflow-auto" }, body))
end

return _M
