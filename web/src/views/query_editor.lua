-- F18: Sorgu editoru — cok sekmeli CodeMirror, sidebar, calistir, sonuc grid, CSV, gecmis.
-- Editor metni icin tek kaynak current_sql[tab.id]: state'e 300 ms debounce ile yazilir, render editoru ezmez.
-- Dis kaynaklar (sidebar, script, gecmis) metni _M.set_sql/_M.append_sql/_M.open_in_new_tab ile degistirir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local editor = require("editor")
local protocol = require("pg_shared.protocol")
local storage = require("storage")

local _M = {}
_M.title = "Sorgu Editörü"
_M.layout = true

local DEFAULT_ROW_LIMIT = 1000
local SESSION_KEY, MAX_TABS, MAX_SQL_BYTES = "query_session", 32, 256 * 1024

local editor_handles = {} -- tab.id -> CodeMirror handle
local editor_failed = false -- CodeMirror yuklenemezse textarea yedegi
local current_sql = {} -- tab.id -> editordeki son metin
local has_selection = {} -- tab.id -> bool
local sync_timers = {} -- tab.id -> bekleyen debounce
local run_ids = {} -- tab.id -> calisan sorgunun run_id'si (iptal icin)
local db_lists = {} -- connection_id -> { status, items } (veritabani secici; codd database switcher)
local database_picker -- ileri bildirim
local applied_catalog = nil -- editorlere en son uygulanan autocomplete katalogu
local run_seq = 0

local function active_tab(state)
  local q = (state or app.get_state()).query
  return q.tabs[q.active_tab]
end

local function sql_of(tab) return current_sql[tab.id] or tab.sql or "" end

-- codd: sekme basligi SQL'in ilk 4 kelimesi (en fazla 28 karakter), bos ise "Sorgu"
function _M.auto_title(sql)
  local words = {}
  for w in (sql or ""):gsub("%-%-[^\n]*", ""):gmatch("%S+") do
    words[#words + 1] = w
    if #words == 4 then break end
  end
  local t = table.concat(words, " ")
  if t == "" then return "Sorgu" end
  if #t > 28 then t = t:sub(1, 27) .. "…" end
  return t
end

-- --- oturum: sekmeler localStorage'da (codd session restore) -------------------------
local persist_pending = false
local function persist()
  persist_pending = false
  local st = app.get_state()
  local tabs = {}
  for i, t in ipairs(st.query.tabs) do
    if i > MAX_TABS then break end
    local sql = sql_of(t)
    if #sql > MAX_SQL_BYTES then sql = sql:sub(1, MAX_SQL_BYTES) end
    tabs[i] = { sql = sql, row_limit = t.row_limit, connection_id = t.connection_id, database = t.database }
  end
  storage.set(SESSION_KEY, { tabs = tabs, active = st.query.active_tab })
end

local function schedule_persist()
  if persist_pending then return end
  persist_pending = true
  js.timer.after(1000, persist)
end

local function new_tab(opts)
  opts = opts or {}
  local st = app.get_state()
  local cur = active_tab(st)
  local conn = opts.connection_id or (cur and cur.connection_id) or (st.connections.items[1] and st.connections.items[1].id)
  local db = opts.database
  if db == nil and cur and cur.connection_id == conn then db = cur.database end
  if db == false then db = nil end
  app.dispatch({ type = "QUERY_TAB_CREATED", sql = opts.sql or "", connection_id = conn, database = db,
    row_limit = opts.row_limit or tonumber(storage.get("row_limit")) })
  schedule_persist()
end

local function restore_session()
  local saved = storage.get(SESSION_KEY)
  if type(saved) ~= "table" or type(saved.tabs) ~= "table" or #saved.tabs == 0 then return false end
  for _, t in ipairs(saved.tabs) do
    app.dispatch({ type = "QUERY_TAB_CREATED", sql = t.sql, connection_id = t.connection_id,
      database = t.database, row_limit = t.row_limit })
  end
  local active = tonumber(saved.active)
  if active and active >= 1 and active <= #saved.tabs then
    app.dispatch({ type = "QUERY_TAB_SWITCHED", index = active })
  end
  return true
end

-- --- dis API: metni degistir -------------------------------------------------------
function _M.set_sql(tab_id, text)
  current_sql[tab_id] = text
  local h = editor_handles[tab_id]
  if h then editor.set_value(h, text) end
  app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab_id, patch = { sql = text } })
  schedule_persist()
end

-- aktif sekmeye (yoksa yeni sekmeye) metin ekler; yazilmis ama kaydedilmemis metin korunur
function _M.append_sql(text)
  local tab = active_tab()
  if not tab then new_tab({ sql = text }); return end
  local cur = sql_of(tab)
  if cur ~= "" and not cur:match("\n$") then cur = cur .. "\n" end
  _M.set_sql(tab.id, cur .. text)
end

-- script/gecmis: yeni sekmede ac ve sorgu sayfasina git
function _M.open_in_new_tab(sql, opts)
  opts = opts or {}
  new_tab({ sql = sql, connection_id = opts.connection_id, database = opts.database })
  if app.get_state().route.name ~= "query" then router.navigate("#/query") end
end

local function on_editor_change(tab_id, v)
  current_sql[tab_id] = v
  if sync_timers[tab_id] then return end
  sync_timers[tab_id] = true
  js.timer.after(300, function()
    sync_timers[tab_id] = nil
    if current_sql[tab_id] ~= nil then
      app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab_id, patch = { sql = current_sql[tab_id] } })
      schedule_persist()
    end
  end)
end

-- --- veri yukleme ------------------------------------------------------------------
-- katalog tek yerden yuklenir (sidebar, sunucuda onbellekli); editorler COMPLETION_LOADED'i render'da uygular
local function load_completion(connection_id, database)
  if not connection_id or connection_id == "" then return end
  require("views.schema_sidebar").load_for_connection(connection_id, database)
end
_M.load_completion = load_completion

local function refresh_history(tab)
  local q = { connection_id = tab.connection_id, limit = 50 }
  if tab.database then q.database = tab.database end
  local hdata = api.get("/query/history", q)
  if hdata and hdata.items then app.dispatch({ type = "QUERY_HISTORY_LOADED", items = hdata.items }) end
end

-- codd: bu komutlardan sonra sema (sidebar + autocomplete) yeniden yuklenir
local DDL_PATTERN = { "^%s*create", "^%s*alter", "^%s*drop", "^%s*comment", "^%s*grant", "^%s*revoke", "^%s*reindex" }
function _M.changes_schema(sql)
  for stmt in (sql:lower() .. ";"):gmatch("([^;]*);") do
    for _, p in ipairs(DDL_PATTERN) do if stmt:find(p) then return true end end
  end
  return false
end

-- codd: secim varsa yalnizca secili metin, yoksa tum editor calisir
local function sql_to_run(tab)
  local h = editor_handles[tab.id]
  local sel = h and has_selection[tab.id] and editor.get_selection(h) or ""
  if sel:match("%S") then return sel end
  return sql_of(tab)
end

local function run_query(tab)
  if not tab then return end
  if tab.status == "running" then app.toast("info", "Bir sorgu zaten çalışıyor"); return end
  if not tab.connection_id or tab.connection_id == "" then app.toast("error", "Bağlantı seçin"); return end
  local sql = sql_to_run(tab)
  if not sql:match("%S") then app.toast("error", "SQL boş"); return end
  app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id, patch = { sql = sql_of(tab) } })
  app.dispatch({ type = "QUERY_RUN_REQUESTED", id = tab.id })
  run_seq = run_seq + 1
  local run_id = tostring(js.timer.now()) .. "-" .. run_seq
  run_ids[tab.id] = run_id
  app.spawn(function()
    local data, err = api.post("/query/execute", {
      connection_id = tab.connection_id,
      database = tab.database,
      sql = sql,
      row_limit = tab.row_limit or DEFAULT_ROW_LIMIT,
      run_id = run_id,
    })
    run_ids[tab.id] = nil
    if err then
      app.dispatch({ type = "QUERY_RUN_FAILED", id = tab.id, error = err })
      local db_msg = err.details and err.details.db_message
      app.toast("error", db_msg and ("Sorgu hatası: " .. tostring(db_msg)) or protocol.message(err.code))
      return
    end
    app.dispatch({ type = "QUERY_RUN_SUCCEEDED", id = tab.id, result = data })
    refresh_history(tab)
    if _M.changes_schema(sql) then load_completion(tab.connection_id, tab.database) end
  end)
end

local function export_csv(tab)
  if not tab or not tab.connection_id or tab.connection_id == "" then app.toast("error", "Bağlantı seçin"); return end
  local sql = sql_to_run(tab)
  if not sql:match("%S") then app.toast("error", "SQL boş"); return end
  require("components.csv_dialog").open("Sorgu sonucunu CSV'ye aktar", function(o)
    app.spawn(function()
      local ok, err = api.download("/query/csv", "query.csv", nil, { connection_id = tab.connection_id,
        database = tab.database, sql = sql, delimiter = o.delimiter, limit = o.limit, include_header = o.include_header })
      if not ok then app.toast("error", err and err.message or protocol.message(err and err.code)) end
    end)
  end)
end

-- --- route ---------------------------------------------------------------------------
function _M.enter(route, state)
  state = state or app.get_state()
  if #state.query.tabs == 0 and not restore_session() then new_tab({ sql = "" }) end
  -- #/query?connection_id=… (baglanti kartindaki "Sorgu"): bos aktif sekmeye ata, doluysa yeni sekme
  local want = route and route.query and route.query.connection_id
  local cur = active_tab()
  if want and want ~= "" and (not cur or cur.connection_id ~= want) then
    if cur and sql_of(cur) == "" then
      app.dispatch({ type = "QUERY_TAB_UPDATED", id = cur.id, patch = { connection_id = want, database = false } })
    else
      new_tab({ sql = "", connection_id = want, database = false })
    end
  end
  -- liste bos ya da istenen baglantiyi icermiyor (pano yalnizca ilk 5'i yukler): tam listeyi cek
  local want_conn = route and route.query and route.query.connection_id
  local known = false
  for _, c in ipairs(state.connections.items or {}) do if c.id == want_conn then known = true end end
  if state.connections.status == "idle" or (want_conn and want_conn ~= "" and not known) then
    app.dispatch({ type = "CONNECTIONS_REQUESTED" })
    local data = api.get("/connections", { per_page = 100 })
    if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
    -- baglantisiz acilan varsayilan sekmeye ilk baglantiyi ata
    local tab = active_tab()
    local first = app.get_state().connections.items[1]
    if tab and not tab.connection_id and first then
      app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id, patch = { connection_id = first.id } })
    end
  end
  local tab = active_tab()
  if tab and tab.connection_id then load_completion(tab.connection_id, tab.database) end
end

local function close_tab(id)
  local h = editor_handles[id]
  if h then editor.destroy(h) end
  editor_handles[id], current_sql[id], has_selection[id] = nil, nil, nil
  app.dispatch({ type = "QUERY_TAB_CLOSED", id = id })
  schedule_persist()
end

function _M.close_active_tab()
  local tab = active_tab()
  if tab then close_tab(tab.id) end
end

function _M.new_tab() new_tab({ sql = "" }) end

local function tab_menu(ev, t)
  local tabs = app.get_state().query.tabs
  require("components.context_menu").open(ev, {
    { label = "Kapat", onclick = function() close_tab(t.id) end },
    { label = "Diğerlerini kapat", disabled = #tabs < 2, onclick = function()
      for _, o in ipairs(app.get_state().query.tabs) do if o.id ~= t.id then close_tab(o.id) end end
    end },
    { label = "Tümünü kapat", onclick = function()
      for _, o in ipairs(app.get_state().query.tabs) do close_tab(o.id) end
    end },
  })
end

-- Render sonrasi: DOM'dan kopan editorleri at (sekme/sayfa degisimi), aktif sekmeye editor ac.
-- ponytail: sekme degisince geri-al gecmisi kaybolur; sekme basina gizli editor tutmak gerekirse eklenir
local function mount_editor(tab, catalog)
  for id, h in pairs(editor_handles) do
    if not editor.attached(h, "editor-" .. id) then editor.destroy(h); editor_handles[id] = nil end
  end
  if editor_failed or editor_handles[tab.id] then return end
  local container = js.dom.byId("editor-" .. tab.id)
  if not container then return end
  local ok, h = pcall(editor.create, container, {
    value = sql_of(tab),
    ariaLabel = "SQL sorgusu",
    schema = catalog or {},
    onChange = function(v) on_editor_change(tab.id, v) end,
    onSelection = function(sel)
      if has_selection[tab.id] ~= sel then has_selection[tab.id] = sel; app.schedule_render() end
    end,
    onRun = function(v)
      current_sql[tab.id] = v
      run_query(active_tab())
    end,
  })
  if ok and h then
    editor_handles[tab.id] = h
  else
    editor_failed = true
    js.log("error", "CodeMirror açılamadı: " .. tostring(h))
    app.schedule_render()
  end
end

local function render_tab_bar(dispatch, tabs, active_idx)
  local items = {}
  for i, t in ipairs(tabs) do
    local is_active = i == active_idx
    local title = _M.auto_title(sql_of(t))
    items[#items + 1] = dom.div({ key = t.id, class = "flex items-center" },
      dom.button({
        type = "button", ["aria-current"] = is_active and "true" or nil, ["data-tab"] = "query",
        title = title .. " (sağ tık: menü)",
        class = is_active
          and "px-3 py-1.5 text-sm bg-[var(--primary)] text-[var(--primary-fg)] rounded-l border border-[var(--primary)] max-w-56 truncate"
          or "px-3 py-1.5 text-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-l hover:bg-[var(--bg)] max-w-56 truncate",
        onclick = function() dispatch({ type = "QUERY_TAB_SWITCHED", index = i }); schedule_persist() end,
        oncontextmenu = function(e) tab_menu(e, t) end,
      }, (t.status == "running" and "⏳ " or "") .. title),
      dom.button({
        type = "button",
        class = "px-1.5 py-1.5 text-xs rounded-r border-y border-r border-[var(--border)] hover:bg-[var(--bg-elev)]",
        ["aria-label"] = title .. " sekmesini kapat",
        onclick = function() close_tab(t.id) end,
      }, "×"))
  end
  items[#items + 1] = dom.button({
    type = "button",
    class = "px-3 py-1.5 border border-dashed border-[var(--border)] rounded text-sm hover:bg-[var(--bg-elev)]",
    ["aria-label"] = "Yeni sorgu sekmesi", title = "Yeni sekme (Alt+N)",
    onclick = function() new_tab({ sql = "" }) end,
  }, "+")
  return dom.nav({ ["aria-label"] = "Sorgu sekmeleri", class = "flex gap-2 flex-wrap items-center" },
    dom.list(items))
end

-- codd veritabani secici: sunucudaki (sablon olmayan) veritabanlari, aranabilir (datalist) + yenile
local function load_databases(conn_id)
  db_lists[conn_id] = { status = "loading", items = db_lists[conn_id] and db_lists[conn_id].items or {} }
  local data, err = api.get("/connections/" .. router.urlencode(conn_id) .. "/databases")
  db_lists[conn_id] = { status = err and "error" or "ready", items = type(data) == "table" and data or {} }
  app.schedule_render()
end

database_picker = function(dispatch, tab)
  local conn = tab.connection_id
  if not conn then return nil end
  if not db_lists[conn] then app.spawn(load_databases, conn) end
  local list = db_lists[conn] or { items = {} }
  local opts = {}
  for i, name in ipairs(list.items) do opts[i] = dom.option({ value = name }) end
  local list_id = "dbs-" .. tostring(tab.id)
  return dom.div({ class = "flex items-center gap-1" },
    dom.input({
      type = "search", list = list_id, placeholder = "Veritabanı (varsayılan)", ["aria-label"] = "Veritabanı",
      class = "px-2 py-1.5 text-sm border border-[var(--border)] rounded bg-[var(--bg)] w-44",
      value = tab.database or "",
      onchange = function(e)
        local db = (e.value or ""):match("^%s*(.-)%s*$")
        dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id, patch = { database = db ~= "" and db or false } })
        schedule_persist()
        app.spawn(load_completion, conn, db ~= "" and db or nil)
      end,
    }),
    dom.datalist({ id = list_id }, dom.list(opts)),
    dom.button({ type = "button", title = "Veritabanı listesini yenile", ["aria-label"] = "Veritabanı listesini yenile",
      class = "px-2 py-1.5 text-sm border border-[var(--border)] rounded",
      onclick = function() app.spawn(load_databases, conn) end }, "↻"))
end

local function render_toolbar(state, dispatch, tab)
  local conn_opts = { dom.option({ value = "" }, "Bağlantı seç") }
  for _, c in ipairs(state.connections.items or {}) do
    conn_opts[#conn_opts + 1] = dom.option({ value = c.id, selected = tab.connection_id == c.id and "selected" or nil },
      c.name .. " (" .. c.host .. ":" .. tostring(c.port) .. ")")
  end
  local running = tab.status == "running"
  return dom.div({ class = "flex flex-wrap items-center gap-2 p-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
    dom.select({
      ["aria-label"] = "Bağlantı",
      class = "px-2 py-1.5 text-sm border border-[var(--border)] rounded bg-[var(--bg)] min-w-40",
      onchange = function(e)
        local id = e.value ~= "" and e.value or nil
        dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id, patch = { connection_id = id or false, database = false } })
        schedule_persist()
        if id then app.spawn(load_completion, id, nil) end
      end,
    }, dom.list(conn_opts)),
    database_picker(dispatch, tab),
    running
      and dom.button({ type = "button",
        class = "px-4 py-1.5 rounded-[var(--radius)] bg-[var(--danger)] text-white text-sm min-h-9",
        onclick = function() _M.cancel_run() end }, "İptal (Esc)")
      or dom.button({ type = "button",
        class = "px-4 py-1.5 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] text-sm hover:opacity-90 min-h-9",
        onclick = function() run_query(tab) end }, "Çalıştır (Ctrl+Enter)"),
    app.can("export.csv") and dom.button({
      type = "button", class = "px-3 py-1.5 rounded border border-[var(--border)] text-sm hover:bg-[var(--bg)]",
      onclick = function() export_csv(tab) end,
    }, "CSV") or nil,
    dom.button({ type = "button", class = "px-3 py-1.5 rounded border border-[var(--border)] text-sm hover:bg-[var(--bg)]",
      disabled = not tab.connection_id and "disabled" or nil,
      onclick = function() require("views.query_history").open_popover(tab) end }, "Geçmiş"),
    has_selection[tab.id] and dom.span({ class = "text-xs text-[var(--fg-muted)]", role = "status" },
      "Seçim çalıştırılacak") or nil)
end

local function render_editor(tab)
  if editor_failed then
    return dom.textarea({
      id = "sql-" .. tab.id, ["aria-label"] = "SQL sorgusu",
      class = "w-full min-h-[180px] p-3 font-mono text-sm bg-[var(--bg)] border border-[var(--border)] rounded-[var(--radius)]",
      value = sql_of(tab),
      oninput = function(e) on_editor_change(tab.id, e.value or "") end,
      onkeydown = function(e)
        if e.key == "Enter" and (e.ctrlKey or e.metaKey) then run_query(active_tab()); return true end
      end,
    })
  end
  return dom.div({ key = "editor-" .. tab.id, id = "editor-" .. tab.id,
    class = "border border-[var(--border)] rounded-[var(--radius)] overflow-hidden min-h-[180px] bg-[var(--bg)]" })
end

local function render_result(tab)
  local grid = require("components.result_grid")
  if tab.status == "error" and tab.error then return grid.render({ error = tab.error }) end
  if tab.result then
    return grid.render(tab.result, {
      row_limit = tab.row_limit or DEFAULT_ROW_LIMIT,
      on_row_limit = function(n)
        app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id, patch = { row_limit = n } })
        schedule_persist()
      end,
      on_export = app.can("export.csv") and function() export_csv(tab) end or nil,
    })
  end
  if tab.status == "running" then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)] flex items-center gap-2", role = "status" },
      dom.span({ class = "skeleton h-3 w-3 rounded-full", ["aria-hidden"] = "true" }), "Sorgu çalışıyor…")
  end
  return dom.div({ class = "p-2 text-xs text-[var(--fg-muted)] border border-dashed border-[var(--border)] rounded" },
    "Sorgu çalıştırıldığında sonuçlar burada görünecek.")
end

function _M.render(state, dispatch)
  local q = state.query
  local tabs = q.tabs or {}
  local active_idx = math.max(1, math.min(q.active_tab or 1, #tabs))
  local tab = tabs[active_idx]

  local main
  if tab then
    local catalog = state.query.completion
    js.timer.after(0, function()
      mount_editor(tab, catalog)
      if catalog ~= applied_catalog then
        applied_catalog = catalog
        for _, h in pairs(editor_handles) do editor.set_completions(h, catalog) end
      end
    end)
    main = dom.div({ class = "space-y-3 min-w-0" },
      render_toolbar(state, dispatch, tab), render_editor(tab), render_result(tab))
  else
    main = dom.div({ class = "p-6 text-center border border-dashed border-[var(--border)] rounded-[var(--radius)]" },
      dom.p({ class = "text-sm text-[var(--fg-muted)] mb-3" }, "Açık sorgu sekmesi yok."),
      dom.button({ type = "button", class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]",
        onclick = function() new_tab({ sql = "" }) end }, "Yeni sekme"))
  end

  local ok, sidebar_mod = pcall(require, "views.schema_sidebar")
  local sidebar = ok and sidebar_mod.render(state, dispatch)
    or dom.div({ class = "p-2 text-xs text-[var(--fg-muted)] border rounded" }, "Şema yükleniyor…")

  return dom.div({ class = "space-y-3" },
    dom.h1({ class = "text-xl font-bold", tabindex = "-1" }, "Sorgu Editörü"),
    render_tab_bar(dispatch, tabs, active_idx),
    dom.div({ class = "grid grid-cols-1 lg:grid-cols-[280px_1fr] gap-3" }, sidebar, main))
end

-- global kisayollar icin disaridan tetikleyiciler
function _M.trigger_run() run_query(active_tab()) end

-- calisan sorguyu sunucuda iptal et (pg_cancel_backend); sonuc istegi 57014 ile doner
function _M.cancel_run()
  local tab = active_tab()
  local run_id = tab and run_ids[tab.id]
  if not run_id then return false end
  app.spawn(function()
    local _, err = api.post("/query/cancel", { run_id = run_id })
    if err then app.toast("error", protocol.message(err.code)) end
  end)
  return true
end

function _M.focus_editor()
  local tab = active_tab()
  local h = tab and editor_handles[tab.id]
  if h then editor.focus(h) end
end

return _M
