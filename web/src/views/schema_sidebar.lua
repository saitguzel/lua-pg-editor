-- F26: Nesne gezgini — Şema → Kategori (sayaçlı) → Nesne → (tablo) Columns/Indexes/… ağacı, lazy yükleme,
-- arama (Ctrl+F, sunucu tarafı q=), hızlı filtre çipleri, düğüm bazlı yenile, sağ tık menüsü.
-- Autocomplete kataloğu (GET /completion) eskisi gibi burada yüklenir ve COMPLETION_LOADED ile paylaşılır;
-- trigger'lar da o katalogdan gelir (kategori endpoint'i trigger içermez).
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local storage = require("storage")
local object_actions = require("views.object_actions")
local icons = require("icons")
local tree = require("views.schema_tree")

local _M = {}

local PAGE = 200

-- --- durum --------------------------------------------------------------------------
local cache = { key = nil, catalog = nil, status = "idle", error = nil } -- completion kataloğu (autocomplete + trigger)
-- ağaç verisi (bağlantı|DB başına): schemas, categories[schema], objects["schema:cat"], children["schema.name"],
-- search[schema]
local T = { key = nil, schemas = { status = "idle" }, categories = {}, objects = {}, children = {}, search = {} }
local search, debounced, search_timer = "", "", nil
local expanded_cache = { conn = nil, map = nil } -- storage "sidebar.expanded:<conn>"

local function key_of(conn, db) return conn .. "|" .. (db or "") end
local function reset_tree(key)
  T = { key = key, schemas = { status = "idle" }, categories = {}, objects = {}, children = {}, search = {} }
end
local function q_db(db) return db and db ~= "" and { database = db } or nil end
local function conn_path(conn) return "/connections/" .. router.urlencode(conn) end
local function schema_path(conn, schema) return conn_path(conn) .. "/schemas/" .. router.urlencode(schema) end
local function obj_path(conn, schema, name)
  return conn_path(conn) .. "/objects/" .. router.urlencode(schema) .. "/" .. router.urlencode(name)
end
-- fetch liste zarfını (meta varsa) { items, meta } olarak sarar
local function unwrap(data)
  if type(data) == "table" and data.items and data.meta then return data.items, data.meta end
  return type(data) == "table" and data or {}, nil
end

local function expanded_map(conn)
  if expanded_cache.conn ~= conn then
    local m = storage.get("sidebar.expanded:" .. tostring(conn))
    expanded_cache = { conn = conn, map = type(m) == "table" and m or {} }
  end
  return expanded_cache.map
end
local function is_open(conn, key, default)
  local v = expanded_map(conn)[key]
  if v == nil then return default == true end
  return v == true
end
local function set_open(conn, key, open)
  local m = expanded_map(conn)
  m[key] = open
  storage.set("sidebar.expanded:" .. tostring(conn), m)
  app.schedule_render()
end
local function quick_filter() return storage.get("sidebar.filter") or "all" end

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

-- --- yükleyiciler (coroutine; ilk yield'a kadar senkron: status "loading" render'da çift istek önler) -----
local function load_completion(conn, db, force)
  if not conn or conn == "" then return end
  local key = key_of(conn, db)
  if not force and cache.key == key and cache.status ~= "error" then return end
  cache = { key = key, catalog = cache.key == key and cache.catalog or nil, status = "loading" }
  app.schedule_render()
  local data, err = api.get(conn_path(conn) .. "/completion", q_db(db))
  if cache.key ~= key then return end -- bu arada baglanti degisti
  if err then
    cache.status, cache.error = "error", err
  else
    cache.catalog, cache.status = data, "ready"
    app.dispatch({ type = "COMPLETION_LOADED", catalog = data })
  end
  app.schedule_render()
end

local function load_schemas(conn, db)
  local key = key_of(conn, db)
  T.schemas = { status = "loading", items = T.schemas.items }
  local data, err = api.get(conn_path(conn) .. "/schemas", q_db(db))
  if T.key ~= key then return end
  if err then
    T.schemas = { status = "error", error = err }
  else
    T.schemas = { status = "ready", items = unwrap(data) }
  end
  app.schedule_render()
end

local function load_categories(conn, db, schema)
  local key = key_of(conn, db)
  T.categories[schema] = { status = "loading" }
  local data, err = api.get(schema_path(conn, schema) .. "/categories", q_db(db))
  if T.key ~= key then return end
  if err then
    T.categories[schema] = { status = "error", error = err }
  else
    local by_id = {}
    for _, c in ipairs(unwrap(data)) do by_id[c.category] = tonumber(c.count) or 0 end
    T.categories[schema] = { status = "ready", by_id = by_id }
  end
  app.schedule_render()
end

local function load_objects(conn, db, schema, category, more)
  local key, nk = key_of(conn, db), tree.node_key(schema, category)
  local cur = T.objects[nk]
  local offset = (more and cur and cur.offset) or 0
  T.objects[nk] = { status = "loading", items = more and cur and cur.items or nil, offset = offset }
  local q = q_db(db) or {}
  q.category, q.limit, q.offset = category, PAGE, offset > 0 and offset or nil
  local data, err = api.get(schema_path(conn, schema) .. "/objects", q)
  if T.key ~= key then return end
  if err then
    T.objects[nk] = { status = "error", error = err, items = T.objects[nk].items, offset = offset }
  else
    local items, meta = unwrap(data)
    local all = more and cur and cur.items or {}
    for _, it in ipairs(items) do all[#all + 1] = it end
    T.objects[nk] = { status = "ready", items = all, offset = offset + #items,
      has_more = meta and meta.has_more == true or false, total = meta and tonumber(meta.total) or #all }
  end
  app.schedule_render()
end

local function load_children(conn, db, schema, name)
  local key, nk = key_of(conn, db), tree.node_key(schema, nil, name)
  T.children[nk] = { status = "loading" }
  local data, err = api.get(obj_path(conn, schema, name) .. "/structure", q_db(db))
  if T.key ~= key then return end
  T.children[nk] = err and { status = "error", error = err } or { status = "ready", structure = data }
  app.schedule_render()
end

-- sunucu araması: şemanın sayacı > 0 olan her kategorisi için q= isteği (paralel)
local function load_search(conn, db, schema, needle)
  local key = key_of(conn, db)
  local cats = T.categories[schema]
  if not cats or cats.status ~= "ready" then return end
  local entry = { q = needle, status = "loading", groups = {}, pending = 0 }
  T.search[schema] = entry
  for _, c in ipairs(tree.CATEGORIES) do
    if (cats.by_id[c.id] or 0) > 0 then
      entry.pending = entry.pending + 1
      app.spawn(function()
        local q = q_db(db) or {}
        q.category, q.q, q.limit = c.id, needle, PAGE
        local data, err = api.get(schema_path(conn, schema) .. "/objects", q)
        if T.key ~= key or T.search[schema] ~= entry then return end
        entry.groups[c.id] = (not err) and unwrap(data) or {}
        entry.pending = entry.pending - 1
        if entry.pending == 0 then entry.status = "ready" end
        app.schedule_render()
      end)
    end
  end
  if entry.pending == 0 then entry.status = "ready" end
end

-- --- dış API (klavye, diğer view'lar) -------------------------------------------------------
function _M.load_for_connection(conn, db) app.spawn(load_completion, conn, db, true) end

function _M.reload()
  local conn, db = context(app.get_state())
  if not conn or conn == "" then return end
  reset_tree(key_of(conn, db)) -- açık düğümler korunur; render açık olanları yeniden çeker
  app.spawn(load_completion, conn, db, true)
  app.schedule_render()
end

function _M.focus_search()
  js.dom.focusFirst("#sidebar-search")
  return true
end

local function hidden_key(conn) return "sidebar_hidden:" .. tostring(conn) end

-- sorgu ekranı ızgarası panel gizliyken dar şerit kolonu kullanır
function _M.is_hidden(state)
  local conn = context(state)
  return conn ~= nil and conn ~= "" and storage.get(hidden_key(conn)) == true
end

-- --- satırlar ---------------------------------------------------------------------------------
local ROW = "group flex items-center gap-1 pr-1 rounded text-sm "
local MENU_BTN = "px-1.5 text-[var(--fg-muted)] opacity-60 group-hover:opacity-100 focus:opacity-100"

local function kind_icon(kind)
  return dom.span({ class = "w-4 flex justify-center " .. (tree.ICON_COLOR[kind] or ""), title = tree.KIND_LABEL[kind],
    ["aria-hidden"] = "true" }, icons.get(tree.ICON[kind] or "table", "w-3.5 h-3.5"))
end

local function menu_button(name, menu)
  return dom.button({ type = "button", ["aria-label"] = name .. " menüsü", ["aria-haspopup"] = "menu",
    class = MENU_BTN, onclick = menu }, "⋯")
end

local function db_query(db, extra)
  local parts = {}
  if db and db ~= "" then parts[#parts + 1] = "database=" .. router.urlencode(db) end
  if extra then parts[#parts + 1] = extra end
  return #parts > 0 and ("&" .. table.concat(parts, "&")) or ""
end

local function open_menu(e, items) require("components.context_menu").open(e, items) end

-- ok tuşları: → aç, ← kapat (aria-expanded düğmeleri)
local function arrow_keys(conn, key, open)
  return function(e)
    if e.key == "ArrowRight" and not open then set_open(conn, key, true); return true end
    if e.key == "ArrowLeft" and open then set_open(conn, key, false); return true end
  end
end

-- tablo alt düğümleri (Columns/Indexes/…): yapı endpoint'i lazy; satırlar yapı sayfası sekmesine bağlanır
local function children_node(conn, db, ctx)
  local nk = tree.node_key(ctx.schema, nil, ctx.name)
  local ch = T.children[nk]
  if not ch then app.spawn(load_children, conn, db, ctx.schema, ctx.name); ch = T.children[nk] end
  if ch.status == "loading" and not ch.structure then
    return dom.div({ class = "pl-9 py-1", ["aria-busy"] = "true" }, require("components.skeleton").lines(2))
  end
  if ch.status == "error" then
    return dom.div({ class = "pl-9 py-1 text-xs text-[var(--danger)]" },
      tostring(ch.error and (ch.error.message or ch.error.code) or "Yapı yüklenemedi"), " ",
      dom.button({ type = "button", class = "underline", onclick = function()
        app.spawn(load_children, conn, db, ctx.schema, ctx.name)
      end }, "Yeniden dene"))
  end
  local d = ch.structure or {}
  local base = "#/structure/" .. router.urlencode(ctx.schema) .. "/" .. router.urlencode(ctx.name)
    .. "?connection_id=" .. router.urlencode(conn) .. db_query(db)
  local sections = {}
  for _, s in ipairs(tree.CHILD_SECTIONS) do
    local items = d[s.key] or {}
    local skey = nk .. "#" .. s.key
    local open = #items > 0 and is_open(conn, skey, false)
    local rows = {}
    if open then
      for i, it in ipairs(items) do
        rows[i] = dom.li({ key = it.name or tostring(i) },
          dom.a({ href = base .. "&tab=" .. s.tab, class = "block truncate pl-3 py-0.5 text-xs hover:underline",
            title = tostring(it.name) .. (it.display_type and (" " .. it.display_type) or "") },
            tostring(it.name),
            -- erişilebilir ad "id integer" olsun diye boşluk metinde (yalnız ml-1 ile "idinteger" olurdu)
            it.display_type and dom.span({ class = "text-[var(--fg-muted)]" }, " " .. it.display_type) or nil))
      end
    end
    sections[#sections + 1] = dom.li({ key = s.key },
      dom.button({ type = "button", ["aria-expanded"] = open and "true" or "false",
        ["aria-disabled"] = #items == 0 and "true" or nil,
        class = "w-full flex items-center gap-1 pl-7 pr-1 py-0.5 text-xs text-left rounded "
          .. (#items == 0 and "text-[var(--fg-muted)] opacity-60" or "text-[var(--fg-muted)] hover:bg-[var(--bg)]"),
        onclick = function() if #items > 0 then set_open(conn, skey, not open) end end,
        onkeydown = arrow_keys(conn, skey, open) },
        icons.get(open and "chevron-down" or "chevron-right", "w-3 h-3"), tree.format_count(s.label, #items)),
      open and dom.ul({ class = "pl-6" }, dom.list(rows)) or nil)
  end
  return dom.ul({ class = "space-y-0.5" }, dom.list(sections))
end

-- ilişki satırı (tablo/view/…): bağlantı tarayıcıya; tablo türleri alt düğümlerle açılabilir
local function relation_row(conn, db, ctx, selected, refresh)
  local href = "#/browse/" .. router.urlencode(ctx.schema) .. "/" .. router.urlencode(ctx.name)
    .. "?connection_id=" .. router.urlencode(conn) .. db_query(db)
  local function menu(e)
    open_menu(e, object_actions.menu_items(ctx, {
      { label = "Tarayıcıda aç", onclick = function() router.navigate(href) end },
      { label = "Yapıyı aç", onclick = function() router.navigate((href:gsub("^#/browse/", "#/structure/"))) end },
      { label = "SELECT'i editöre ekle", onclick = function()
        require("views.query_editor").append_sql('SELECT * FROM "' .. ctx.schema:gsub('"', '""') .. '"."'
          .. ctx.name:gsub('"', '""') .. '" LIMIT 100;')
        if app.get_state().route.name ~= "query" then router.navigate("#/query") end
      end },
      { label = "Yenile", onclick = refresh },
      { separator = true },
    }))
  end
  local expandable = tree.EXPANDABLE_KINDS[ctx.kind]
  local nk = tree.node_key(ctx.schema, nil, ctx.name)
  local open = expandable and is_open(conn, nk, false)
  return dom.li({ key = ctx.category .. ":" .. ctx.name },
    dom.div({ class = ROW .. (expandable and "pl-3 " or "pl-7 ")
      .. (selected and "bg-[color-mix(in_srgb,var(--primary)_14%,transparent)] font-medium" or "hover:bg-[var(--bg)]"),
      oncontextmenu = menu },
      expandable and dom.button({ type = "button", ["aria-expanded"] = open and "true" or "false",
        ["aria-label"] = ctx.name .. " alt öğeleri", class = "w-4 flex justify-center text-[var(--fg-muted)]",
        onclick = function() set_open(conn, nk, not open) end, onkeydown = arrow_keys(conn, nk, open) },
        icons.get(open and "chevron-down" or "chevron-right", "w-3 h-3")) or nil,
      kind_icon(ctx.kind),
      dom.a({ href = href, class = "flex-1 truncate py-1",
        title = ctx.schema .. "." .. ctx.name .. " (" .. (tree.KIND_LABEL[ctx.kind] or "") .. ")",
        ["aria-current"] = selected and "page" or nil }, ctx.name),
      menu_button(ctx.name, menu)),
    open and children_node(conn, db, ctx) or nil)
end

-- sequence/type/domain/extension/… satırı: bağlantı detay (yapı) sayfasına
local function misc_row(conn, db, ctx, selected, refresh)
  local href = "#/structure/" .. router.urlencode(ctx.schema) .. "/" .. router.urlencode(ctx.name)
    .. "?connection_id=" .. router.urlencode(conn) .. db_query(db, "kind=" .. router.urlencode(ctx.kind))
  local function menu(e)
    local extra = { { label = "Detayı aç", onclick = function() router.navigate(href) end } }
    if ctx.kind == "sequence" then
      extra[#extra + 1] = { label = "SELECT ile getir", onclick = function()
        require("views.query_editor").append_sql('SELECT * FROM "' .. ctx.schema:gsub('"', '""') .. '"."'
          .. ctx.name:gsub('"', '""') .. '";')
        if app.get_state().route.name ~= "query" then router.navigate("#/query") end
      end }
    end
    extra[#extra + 1] = { label = "Yenile", onclick = refresh }
    extra[#extra + 1] = { separator = true }
    open_menu(e, object_actions.menu_items(ctx, extra))
  end
  local extra = ctx.extra or {}
  local hint = extra.version and ("v" .. tostring(extra.version)) or extra.base_type or nil
  return dom.li({ key = ctx.category .. ":" .. ctx.name },
    dom.div({ class = ROW .. "pl-7 "
      .. (selected and "bg-[color-mix(in_srgb,var(--primary)_14%,transparent)] font-medium" or "hover:bg-[var(--bg)]"),
      oncontextmenu = menu },
      kind_icon(ctx.kind),
      dom.a({ href = href, class = "flex-1 truncate py-1",
        title = ctx.schema .. "." .. ctx.name .. " (" .. (tree.KIND_LABEL[ctx.kind] or "") .. ")",
        ["aria-current"] = selected and "page" or nil }, ctx.name,
        hint and dom.span({ class = "text-[10px] text-[var(--fg-muted)] ml-1" }, hint) or nil),
      menu_button(ctx.name, menu)))
end

-- fonksiyon/prosedür/trigger satırı: tıklama DDL'i (düzenlenebilir) yeni sekmede açar
local function routine_row(ctx)
  local function menu(e) open_menu(e, object_actions.routine_menu_items(ctx)) end
  local label_kind = object_actions.ROUTINE_LABEL[ctx.subkind or ctx.kind] or ctx.kind
  local detail = ctx.kind == "trigger" and ("ON " .. tostring(ctx.table))
    or ("(" .. (ctx.args or "") .. ")" .. (ctx.returns and ctx.returns ~= "" and (" → " .. ctx.returns) or ""))
  local label = ctx.kind == "trigger" and ctx.name or (ctx.name .. "(" .. (ctx.args or "") .. ")")
  return dom.li({ key = ctx.kind .. ":" .. tostring(ctx.oid) },
    dom.div({ class = ROW .. "pl-7 hover:bg-[var(--bg)]", oncontextmenu = menu },
      kind_icon(ctx.subkind or ctx.kind),
      dom.button({ type = "button", class = "flex-1 min-w-0 truncate py-1 text-left"
          .. (ctx.kind == "trigger" and not ctx.enabled and " line-through text-[var(--fg-muted)]" or ""),
        title = ctx.schema .. "." .. ctx.name .. " " .. detail .. (ctx.language and (" · " .. ctx.language) or "")
          .. (ctx.kind == "trigger" and not ctx.enabled and " · devre dışı" or "") .. " — tıkla: düzenle",
        ["aria-label"] = label .. " (" .. label_kind .. ")",
        onclick = function()
          if app.can("script.generate") then object_actions.routine_script(ctx, "ddl") end
        end },
        ctx.name,
        ctx.kind ~= "trigger" and dom.span({ class = "text-[10px] text-[var(--fg-muted)] ml-1" },
          "(" .. (ctx.args or "") .. ")") or nil),
      menu_button(ctx.name, menu)))
end

-- sunucudan gelen nesne → satır
local function object_node(conn, db, category, obj, sel_schema, sel_name, refresh)
  local selected = obj.schema == sel_schema and obj.name == sel_name
  local rk = tree.routine_kind(obj.kind)
  if rk then
    local ex = obj.extra or {}
    return routine_row({ connection_id = conn, database = db, schema = obj.schema, name = obj.name, kind = rk,
      subkind = obj.kind ~= rk and obj.kind or nil, oid = ex.oid, args = ex.args, returns = ex.returns,
      language = ex.language })
  end
  local ctx = { connection_id = conn, database = db, schema = obj.schema, name = obj.name, kind = obj.kind,
    category = category, extra = obj.extra }
  if tree.RELATION_KINDS[obj.kind] then return relation_row(conn, db, ctx, selected, refresh) end
  return misc_row(conn, db, ctx, selected, refresh)
end

local function trigger_rows(conn, db, schema, needle)
  local rows = {}
  local sch
  for _, s in ipairs(cache.catalog and cache.catalog.schemas or {}) do if s.name == schema then sch = s end end
  for _, r in ipairs(tree.filter_items(sch and sch.triggers or {}, needle)) do
    rows[#rows + 1] = routine_row({ connection_id = conn, database = db, schema = schema, name = r.name,
      kind = "trigger", oid = r.oid, table = r.table, enabled = r.enabled ~= false })
  end
  return rows
end

local function skeleton(pl)
  return dom.div({ class = pl .. " py-1", ["aria-busy"] = "true" }, require("components.skeleton").lines(3))
end

local function error_box(pl, err, retry)
  return dom.div({ class = pl .. " py-1 text-xs text-[var(--danger)]" },
    tostring(err and (err.message or err.code) or "Yüklenemedi"), " ",
    dom.button({ type = "button", class = "underline", onclick = retry }, "Yeniden dene"))
end

-- "+" yeni fonksiyon/prosedür taslağı (kategori başlığında)
local function new_routine_button(conn, db, schema, kind)
  if not app.can("query.execute") then return nil end
  local label = object_actions.ROUTINE_LABEL[kind]
  return dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm",
    ["aria-label"] = "Yeni " .. label .. " (" .. schema .. ")", title = "Yeni " .. label .. " taslağı",
    onclick = function()
      require("views.query_editor").open_in_new_tab(require("snippets_builtin").create_template(kind, schema),
        { connection_id = conn, database = db })
    end }, icons.get("plus", "w-3 h-3"))
end

local function category_header(conn, key, label, count, open, opts)
  return dom.div({ class = "flex items-center pl-4 pr-1 rounded hover:bg-[var(--bg)]", oncontextmenu = opts.menu },
    dom.button({ type = "button", ["aria-expanded"] = open and "true" or "false",
      ["aria-disabled"] = count == 0 and "true" or nil,
      class = "flex-1 flex items-center gap-1 py-1 text-xs text-left "
        .. (count == 0 and "text-[var(--fg-muted)] opacity-60" or "text-[var(--fg-muted)]"),
      onclick = function() if count > 0 then set_open(conn, key, not open) end end,
      onkeydown = count > 0 and arrow_keys(conn, key, open) or nil },
      icons.get(open and "chevron-down" or "chevron-right", "w-3 h-3"),
      dom.span({ class = "font-medium" }, tree.format_count(label, count))),
    opts.action)
end

-- kategori düğümü: açılınca nesneler lazy gelir; sonda "Daha fazla yükle"
local function category_node(conn, db, schema, cat, count, sel_schema, sel_name)
  local key = tree.node_key(schema, cat.id)
  local open = count > 0 and is_open(conn, key, false)
  local function refresh() app.spawn(load_objects, conn, db, schema, cat.id, false) end
  local function menu(e)
    open_menu(e, {
      { label = "Yenile", onclick = refresh },
      { label = "Hepsini daralt", onclick = function()
        local m = expanded_map(conn)
        for _, c in ipairs(tree.CATEGORIES) do m[tree.node_key(schema, c.id)] = false end
        m[tree.node_key(schema, "triggers")] = false
        storage.set("sidebar.expanded:" .. tostring(conn), m)
        app.schedule_render()
      end },
    })
  end
  local action = (cat.id == "functions" and new_routine_button(conn, db, schema, "function"))
    or (cat.id == "procedures" and new_routine_button(conn, db, schema, "procedure")) or nil
  local body
  if open then
    local objs = T.objects[key]
    if not objs then refresh(); objs = T.objects[key] end
    if objs.status == "error" then
      body = error_box("pl-7", objs.error, refresh)
    elseif not objs.items then
      body = skeleton("pl-7")
    else
      local rows = {}
      for _, o in ipairs(objs.items) do
        rows[#rows + 1] = object_node(conn, db, cat.id, o, sel_schema, sel_name, refresh)
      end
      local more
      if objs.has_more then
        local left = math.max(0, (objs.total or 0) - #objs.items)
        more = dom.li({ key = "__more" }, dom.button({ type = "button",
          disabled = objs.status == "loading" and "disabled" or nil,
          class = "ml-7 my-1 text-xs underline text-[var(--fg-muted)]",
          onclick = function() app.spawn(load_objects, conn, db, schema, cat.id, true) end },
          objs.status == "loading" and "Yükleniyor…" or ("Daha fazla yükle (" .. left .. " kalan)")))
      end
      body = dom.ul({ class = "space-y-0.5", ["aria-busy"] = objs.status == "loading" and "true" or nil },
        dom.list(rows), more)
    end
  end
  return dom.li({ key = key },
    category_header(conn, key, cat.label, count, open, { menu = menu, action = action }), body)
end

local function triggers_node(conn, db, schema)
  local key = tree.node_key(schema, "triggers")
  local rows = cache.catalog and trigger_rows(conn, db, schema, "") or nil
  local count = rows and #rows or 0
  local open = count > 0 and is_open(conn, key, false)
  return dom.li({ key = key },
    category_header(conn, key, tree.TRIGGER_CATEGORY.label, count, open, { menu = function(e)
      open_menu(e, { { label = "Yenile", onclick = function() app.spawn(load_completion, conn, db, true) end } })
    end }),
    open and dom.ul({ class = "space-y-0.5" }, dom.list(rows)) or nil)
end

-- arama modu: açık şemalarda sunucu sonuçları kategoriye göre (trigger'lar katalogdan)
local function search_results(conn, db, schema, needle, sel_schema, sel_name, filter)
  local entry = T.search[schema]
  if not entry or entry.q ~= needle then
    load_search(conn, db, schema, needle)
    entry = T.search[schema]
  end
  if not entry then return skeleton("pl-4"), 0 end
  local groups, total = {}, 0
  for _, c in ipairs(tree.CATEGORIES) do
    local items = entry.groups[c.id]
    if items and #items > 0 and tree.quick_filter_matches(filter, c.id) then
      local rows = {}
      for _, o in ipairs(items) do
        rows[#rows + 1] = object_node(conn, db, c.id, o, sel_schema, sel_name,
          function() load_search(conn, db, schema, needle) end)
      end
      total = total + #rows
      groups[#groups + 1] = dom.li({ key = c.id },
        dom.div({ class = "pl-4 py-0.5 text-[10px] uppercase tracking-wide text-[var(--fg-muted)]" },
          tree.format_count(c.label, #rows)),
        dom.ul({ class = "space-y-0.5" }, dom.list(rows)))
    end
  end
  if tree.quick_filter_matches(filter, "triggers") then
    local rows = trigger_rows(conn, db, schema, needle)
    if #rows > 0 then
      total = total + #rows
      groups[#groups + 1] = dom.li({ key = "triggers" },
        dom.div({ class = "pl-4 py-0.5 text-[10px] uppercase tracking-wide text-[var(--fg-muted)]" },
          tree.format_count("Triggers", #rows)),
        dom.ul({ class = "space-y-0.5" }, dom.list(rows)))
    end
  end
  local busy = entry.status ~= "ready"
  return dom.ul({ class = "space-y-0.5", ["aria-busy"] = busy and "true" or nil }, dom.list(groups),
    busy and dom.li({ key = "__busy" }, skeleton("pl-4")) or nil), total, busy
end

local function schema_node(conn, db, schema, sel_schema, sel_name, needle, filter)
  local open = is_open(conn, schema, schema == "public" or schema == sel_schema)
  if needle ~= "" then open = true end
  local cats = T.categories[schema]
  if open and not cats then app.spawn(load_categories, conn, db, schema); cats = T.categories[schema] end
  local function refresh()
    T.categories[schema], T.search[schema] = nil, nil
    for k in pairs(T.objects) do if k:sub(1, #schema + 1) == schema .. ":" then T.objects[k] = nil end end
    app.schedule_render()
  end
  local function set_all(v)
    local m = expanded_map(conn)
    for _, c in ipairs(tree.CATEGORIES) do m[tree.node_key(schema, c.id)] = v end
    m[tree.node_key(schema, "triggers")] = v
    storage.set("sidebar.expanded:" .. tostring(conn), m)
    app.schedule_render()
  end
  local function menu(e)
    open_menu(e, { { label = "Yenile", onclick = refresh },
      { label = "Tüm kategorileri aç", onclick = function() set_all(true) end },
      { label = "Tüm kategorileri kapat", onclick = function() set_all(false) end } })
  end
  local body, total, hidden_empty = nil, nil, false
  if open then
    if not cats or (cats.status == "loading") then
      body = skeleton("pl-4")
    elseif cats.status == "error" then
      body = error_box("pl-4", cats.error, function() app.spawn(load_categories, conn, db, schema) end)
    elseif needle ~= "" then
      local n, busy
      body, n, busy = search_results(conn, db, schema, needle, sel_schema, sel_name, filter)
      total = n
      hidden_empty = n == 0 and not busy
    else
      local nodes = {}
      total = 0
      for _, c in ipairs(tree.CATEGORIES) do
        local n = cats.by_id[c.id] or 0
        total = total + n
        if tree.quick_filter_matches(filter, c.id) then
          nodes[#nodes + 1] = category_node(conn, db, schema, c, n, sel_schema, sel_name)
        end
      end
      if tree.quick_filter_matches(filter, "triggers") then nodes[#nodes + 1] = triggers_node(conn, db, schema) end
      body = dom.ul({ class = "space-y-0.5" }, dom.list(nodes))
    end
  end
  local node = dom.li({ key = schema },
    dom.button({ type = "button", ["aria-expanded"] = open and "true" or "false",
      class = "w-full flex items-center gap-1 px-1 py-1 text-sm hover:bg-[var(--bg)] text-left rounded",
      onclick = function() set_open(conn, schema, not open) end, oncontextmenu = menu,
      onkeydown = arrow_keys(conn, schema, open) },
      dom.span({ class = "text-xs w-3", ["aria-hidden"] = "true" }, open and "▾" or "▸"),
      dom.span({ class = "font-medium" }, schema),
      total and dom.span({ class = "ml-auto text-[10px] text-[var(--fg-muted)]" }, tostring(total)) or nil),
    body)
  return node, hidden_empty, total
end

local function filter_chips()
  local cur = quick_filter()
  local chips = {}
  for i, f in ipairs(tree.QUICK_FILTERS) do
    local on = f.id == cur
    chips[i] = dom.button({ type = "button", role = "radio", ["aria-checked"] = on and "true" or "false",
      class = "px-1.5 py-0.5 text-[10px] rounded border "
        .. (on and "bg-[var(--primary)] text-[var(--primary-fg)] border-transparent"
          or "border-[var(--border)] hover:bg-[var(--bg)]"),
      onclick = function() storage.set("sidebar.filter", f.id); app.schedule_render() end }, f.label)
  end
  return dom.div({ role = "radiogroup", ["aria-label"] = "Hızlı filtre", class = "flex flex-wrap gap-1" },
    dom.list(chips))
end

function _M.render(state)
  local conn, db, sel_schema, sel_name = context(state)
  if conn and conn ~= "" then
    local key = key_of(conn, db)
    if T.key ~= key then reset_tree(key) end
    if cache.key ~= key and cache.status ~= "loading" then app.spawn(load_completion, conn, db, false) end
    if T.schemas.status == "idle" then app.spawn(load_schemas, conn, db) end
  end

  local hidden = conn and storage.get(hidden_key(conn)) == true
  local toggle = dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm",
    ["aria-expanded"] = hidden and "false" or "true",
    ["aria-label"] = hidden and "Nesneleri göster" or "Gizle",
    title = hidden and "Nesne panelini göster" or "Nesne panelini gizle",
    onclick = function()
      if hidden then storage.remove(hidden_key(conn)) else storage.set(hidden_key(conn), true) end
      app.schedule_render()
    end }, icons.get(hidden and "chevron-right" or "chevron-left"))
  if hidden then
    -- dar şerit: editör kalan alanı kaplar
    return dom.aside({ ["aria-label"] = "Veritabanı nesneleri",
      class = "flex lg:flex-col items-center gap-2 lg:py-2 border border-[var(--border)] rounded-[var(--radius)] "
        .. "bg-[var(--bg-elev)] self-stretch" },
      toggle, dom.span({ class = "hidden lg:block text-[var(--fg-muted)]", title = "Nesneler" }, icons.get("database")))
  end

  local header = dom.div({ class = "flex items-center justify-between gap-1" },
    dom.h2({ class = "text-sm font-semibold flex items-center gap-1.5" },
      icons.get("database", "w-4 h-4 text-[var(--primary)]"), "Nesneler"),
    dom.div({ class = "flex gap-1" },
      dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", ["aria-label"] = "Yenile",
        title = "Nesneleri yenile (F5)", onclick = _M.reload }, icons.get("refresh")),
      toggle))

  local body
  local needle = debounced:lower()
  if not conn or conn == "" then
    body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "PostgreSQL'e bağlanın: bir bağlantı seçin")
  elseif T.schemas.status == "error" then
    body = dom.p({ role = "alert", class = "text-xs text-[var(--danger)] p-2" },
      tostring(T.schemas.error and (T.schemas.error.message or T.schemas.error.code) or "Şema yüklenemedi"), " ",
      dom.button({ type = "button", class = "underline", onclick = function() app.spawn(load_schemas, conn, db) end },
        "Yeniden dene"))
  elseif not T.schemas.items then
    body = require("components.skeleton").lines(4)
  else
    local filter = quick_filter()
    local nodes, any = {}, false
    for _, schema in ipairs(T.schemas.items) do
      local node, hidden_empty, total = schema_node(conn, db, schema, sel_schema, sel_name, needle, filter)
      if needle == "" or not hidden_empty then nodes[#nodes + 1] = node end
      any = any or (total or 0) > 0
    end
    if #nodes == 0 and needle ~= "" then
      body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "Eşleşen nesne yok")
    elseif #nodes == 0 then
      body = dom.p({ class = "text-xs text-[var(--fg-muted)] p-2" }, "Şema bulunamadı")
    else
      body = dom.ul({ class = "space-y-0.5", ["aria-busy"] = T.schemas.status == "loading" and "true" or nil },
        dom.list(nodes))
    end
  end

  return dom.aside({ ["aria-label"] = "Veritabanı nesneleri",
    class = "border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] p-2 space-y-2 self-start" },
    header,
    dom.input({ id = "sidebar-search", type = "search", value = search, placeholder = "Nesne ara (Ctrl+F)",
      ["aria-label"] = "Nesne ara",
      class = "w-full px-2 py-1 text-sm border border-[var(--border)] rounded bg-[var(--bg)]",
      oninput = function(e)
        search = e.value or ""
        if search_timer then js.timer.cancel(search_timer) end
        search_timer = js.timer.after(300, function() debounced = search; app.schedule_render() end)
        app.schedule_render()
      end }),
    conn and conn ~= "" and filter_chips() or nil,
    dom.div({ class = "max-h-[70vh] overflow-auto" }, body))
end

-- test: modül durumunu sıfırlar
function _M._reset()
  reset_tree(nil)
  cache = { key = nil, catalog = nil, status = "idle", error = nil }
  expanded_cache = { conn = nil, map = nil }
  search, debounced = "", ""
end

return _M
