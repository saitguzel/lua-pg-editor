-- F17: Tek state deposu, dilim bazlı saf reducer'lar, rAF ile birleştirilmiş render döngüsü.
-- pg-editor uyarlaması: connections / databases / schemas / objects / structure / query / table_browser / users / rbac / audit

local dom = require("dom")
local router = require("router")
local storage = require("storage")
local api = require("fetch")

local app = {}

-- --- yardımcılar ---------------------------------------------------------------

local function shallow_copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- patch'teki nil değerler Lua tablosunda yer almaz; silinecek alanlar ayrıca clear listesiyle verilir
local function assign(base, patch, clear)
  local c = shallow_copy(base)
  for k, v in pairs(patch) do c[k] = v end
  for _, k in ipairs(clear or {}) do c[k] = nil end
  return c
end

app._assign = assign
app._shallow_copy = shallow_copy

-- --- initial state ---------------------------------------------------------------

local initial_state = {
  route = { name = nil, params = {}, query = {}, forbidden = false },
  auth  = { status = "unknown", user = nil, permissions = {} },
  connections = { items = {}, by_id = {}, meta = {}, status = "idle", error = nil,
                  editing = nil, testing = nil, filters = {}, pending = {} },
  databases = { list = {}, status = "idle", error = nil },
  schemas = { list = {}, status = "idle", error = nil },
  objects = { items = {}, status = "idle", filter = "", error = nil },
  structure = { data = nil, status = "idle", selected = nil, error = nil },
  query = { tabs = {}, active_tab = 1, next_id = 1, history = { items = {}, status = "idle" }, completion = nil, status = "idle" },
  table_browser = { object = nil, columns = {}, rows = {}, meta = { page = 1, per_page = 100, total = 0, has_next = false },
                    status = "idle", filters = {}, sort = nil, editing = nil, pending = {}, error = nil },
  users = { items = {}, by_id = {}, meta = nil, status = "idle", error = nil,
            filters = {}, editing = nil, saving = false },
  rbac  = { pages = {}, matrix = nil, cache_ttl = nil, status = "idle", pending = {} },
  audit = { items = {}, meta = nil, filters = {}, status = "idle", selected = nil,
            detail = nil, stats = nil, exporting = false },
  ui    = { theme = "light", toasts = {}, modal = nil, sidebar_open = true, busy = {}, loaded_at = nil },
}

app.initial_state = initial_state

-- --- alt reducer'lar -------------------------------------------------------------

local function reduce_route(s, a)
  if a.type == "ROUTE_CHANGED" then
    return { name = a.name, params = a.params or {}, query = a.query or {}, forbidden = a.forbidden or false }
  elseif a.type == "FORBIDDEN" then
    return assign(s, { forbidden = true })
  end
  return s
end

local function reduce_auth(s, a)
  if a.type == "AUTH_RESTORED" or a.type == "LOGIN_SUCCEEDED" then
    return { status = "authenticated", user = a.user, permissions = a.permissions or {} }
  elseif a.type == "AUTH_ANONYMOUS" or a.type == "LOGGED_OUT" then
    return { status = "anonymous", user = nil, permissions = {} }
  elseif a.type == "PERMISSIONS_LOADED" then
    return assign(s, { permissions = a.permissions or {} })
  elseif a.type == "USER_LOADED" then
    return assign(s, { user = a.user or s.user, permissions = a.permissions or s.permissions })
  end
  return s
end

local function reduce_connections(s, a)
  if a.type == "CONNECTIONS_REQUESTED" then
    return assign(s, { status = "loading", filters = a.filters or s.filters }, { "error" })
  elseif a.type == "CONNECTIONS_LOADED" then
    local items, by_id = {}, {}
    for i, c in ipairs(a.items or {}) do
      items[i] = c
      by_id[c.id] = i
    end
    return assign(s, { items = items, by_id = by_id, meta = a.meta or s.meta, status = "ready" })
  elseif a.type == "CONNECTIONS_FAILED" then
    return assign(s, { status = "error", error = a.error })
  elseif a.type == "CONNECTIONS_FILTERS_CHANGED" then
    return assign(s, { filters = assign(s.filters, a.patch or {}) })
  elseif a.type == "CONNECTION_EDIT_OPENED" then
    return assign(s, { editing = a.id or "new", editing_item = a.item })
  elseif a.type == "CONNECTION_EDIT_CLOSED" then
    if s.editing == nil then return s end
    return assign(s, {}, { "editing", "editing_item" })
  elseif a.type == "CONNECTION_TESTING" then
    return assign(s, { testing = a.id })
  elseif a.type == "CONNECTION_TESTED" or a.type == "CONNECTION_TEST_FAILED" then
    if s.testing ~= a.id then return s end
    return assign(s, {}, { "testing" })
  elseif a.type == "CONNECTION_CREATED" then
    -- optimistic sonrası veya direkt create: listeye ekle
    local items = shallow_copy(s.items)
    local by_id = shallow_copy(s.by_id)
    -- eğer items zaten aynı id'yi içeriyorsa güncelle, değilse ekle
    local existing = by_id[a.connection.id]
    if existing then
      items[existing] = a.connection
    else
      items[#items + 1] = a.connection
      by_id[a.connection.id] = #items
    end
    return assign(s, { items = items, by_id = by_id })
  elseif a.type == "CONNECTION_UPDATED" then
    local idx = s.by_id[a.connection.id]
    if not idx then return s end
    local items = shallow_copy(s.items)
    items[idx] = a.connection
    return assign(s, { items = items })
  elseif a.type == "CONNECTION_REMOVED" then
    local idx = s.by_id[a.id]
    if not idx then return s end
    local items, by_id = {}, {}
    for i, t in ipairs(s.items) do
      if i ~= idx then
        items[#items + 1] = t
        by_id[t.id] = #items
      end
    end
    return assign(s, { items = items, by_id = by_id })
  end
  return s
end

local function reduce_databases(s, a)
  if a.type == "DATABASES_REQUESTED" then return assign(s, { status = "loading" }, { "error" })
  elseif a.type == "DATABASES_LOADED" then return assign(s, { list = a.list or {}, status = "ready" })
  elseif a.type == "DATABASES_FAILED" then return assign(s, { status = "error", error = a.error })
  end
  return s
end

local function reduce_schemas(s, a)
  if a.type == "SCHEMAS_REQUESTED" then return assign(s, { status = "loading" }, { "error" })
  elseif a.type == "SCHEMAS_LOADED" then return assign(s, { list = a.list or {}, status = "ready" })
  elseif a.type == "SCHEMAS_FAILED" then return assign(s, { status = "error", error = a.error })
  end
  return s
end

local function reduce_objects(s, a)
  if a.type == "OBJECTS_REQUESTED" then return assign(s, { status = "loading" }, { "error" })
  elseif a.type == "OBJECTS_LOADED" then return assign(s, { items = a.items or {}, status = "ready" })
  elseif a.type == "OBJECTS_FAILED" then return assign(s, { status = "error", error = a.error })
  elseif a.type == "OBJECTS_FILTER_CHANGED" then return assign(s, { filter = a.filter or "" })
  end
  return s
end

local function reduce_structure(s, a)
  if a.type == "STRUCTURE_REQUESTED" then
    return assign(s, { status = "loading", selected = a.selected or s.selected }, { "error" })
  elseif a.type == "STRUCTURE_LOADED" then return assign(s, { data = a.data, status = "ready" })
  elseif a.type == "STRUCTURE_FAILED" then return assign(s, { status = "error", error = a.error })
  end
  return s
end

local function reduce_query(s, a)
  if a.type == "QUERY_TAB_CREATED" then
    local tab = {
      id = s.next_id,
      title = a.title or ("Sorgu " .. s.next_id),
      sql = a.sql or "",
      result = nil,
      status = "idle",
      connection_id = a.connection_id,
      database = a.database,
      row_limit = a.row_limit,
      error = nil,
    }
    local tabs = shallow_copy(s.tabs)
    tabs[#tabs + 1] = tab
    return assign(s, { tabs = tabs, active_tab = #tabs, next_id = s.next_id + 1 })
  elseif a.type == "QUERY_TAB_CLOSED" then
    local tabs = {}
    for _, t in ipairs(s.tabs) do
      if t.id ~= a.id then tabs[#tabs + 1] = t end
    end
    local active = s.active_tab
    if active > #tabs then active = #tabs end
    if active < 1 then active = 1 end
    if #tabs == 0 then return assign(s, { tabs = {}, active_tab = 1 }) end
    return assign(s, { tabs = tabs, active_tab = active })
  elseif a.type == "QUERY_TAB_SWITCHED" then
    return assign(s, { active_tab = a.index or s.active_tab })
  elseif a.type == "QUERY_TAB_UPDATED" then
    local tabs = shallow_copy(s.tabs)
    local idx = nil
    for i, t in ipairs(tabs) do if t.id == a.id then idx = i; break end end
    if not idx then return s end
    -- patch'te false olan alan silinir (ör. database = false → varsayılan DB)
    local patch, clear = {}, {}
    for k, v in pairs(a.patch or {}) do
      if v == false then clear[#clear + 1] = k else patch[k] = v end
    end
    tabs[idx] = assign(tabs[idx], patch, clear)
    return assign(s, { tabs = tabs })
  elseif a.type == "QUERY_RUN_REQUESTED" then
    local tabs = shallow_copy(s.tabs)
    local idx = nil
    for i, t in ipairs(tabs) do if t.id == a.id then idx = i; break end end
    if not idx then return s end
    tabs[idx] = assign(tabs[idx], { status = "running" }, { "error" })
    return assign(s, { tabs = tabs })
  elseif a.type == "QUERY_RUN_SUCCEEDED" then
    local tabs = shallow_copy(s.tabs)
    local idx = nil
    for i, t in ipairs(tabs) do if t.id == a.id then idx = i; break end end
    if not idx then return s end
    tabs[idx] = assign(tabs[idx], { status = "ready", result = a.result }, { "error" })
    return assign(s, { tabs = tabs })
  elseif a.type == "QUERY_RUN_FAILED" then
    local tabs = shallow_copy(s.tabs)
    local idx = nil
    for i, t in ipairs(tabs) do if t.id == a.id then idx = i; break end end
    if not idx then return s end
    tabs[idx] = assign(tabs[idx], { status = "error", error = a.error })
    return assign(s, { tabs = tabs })
  elseif a.type == "QUERY_HISTORY_LOADED" then
    return assign(s, { history = assign(s.history, { items = a.items or {}, meta = a.meta, status = "ready" }) })
  elseif a.type == "QUERY_HISTORY_REQUESTED" then
    return assign(s, { history = assign(s.history, { status = "loading" }) })
  elseif a.type == "QUERY_HISTORY_FAILED" then
    return assign(s, { history = assign(s.history, { status = "error" }) })
  elseif a.type == "COMPLETION_LOADED" then
    return assign(s, { completion = a.catalog })
  end
  return s
end

local function reduce_table_browser(s, a)
  if a.type == "TABLE_ROWS_REQUESTED" then
    return assign(s, { status = "loading", filters = a.filters or s.filters, sort = a.sort or s.sort }, { "error" })
  elseif a.type == "TABLE_ROWS_LOADED" then
    return assign(s, { rows = a.rows or {}, columns = a.columns or s.columns, meta = a.meta or s.meta, status = "ready" })
  elseif a.type == "TABLE_ROWS_FAILED" then return assign(s, { status = "error", error = a.error })
  elseif a.type == "TABLE_BROWSER_FILTERS_CHANGED" then return assign(s, { filters = assign(s.filters, a.patch or {}) })
  elseif a.type == "TABLE_BROWSER_SORT_CHANGED" then return assign(s, { sort = a.sort })
  elseif a.type == "TABLE_ROW_UPDATE_OPTIMISTIC" then
    -- satır güncelle optimistic: rows içinde ilgili id'li satırı yama
    local rows = shallow_copy(s.rows)
    local idx = nil
    for i, r in ipairs(rows) do if tostring(r.id) == tostring(a.id) or r._rid == a.id then idx = i; break end end
    if not idx then return s end
    local pending = shallow_copy(s.pending)
    pending[a.id] = { op = "update", snapshot = rows[idx] }
    local new_row = shallow_copy(rows[idx])
    for k, v in pairs(a.patch or {}) do new_row[k] = v end
    rows[idx] = new_row
    return assign(s, { rows = rows, pending = pending })
  elseif a.type == "TABLE_ROW_UPDATE_CONFIRMED" then
    local pending = shallow_copy(s.pending)
    pending[a.id] = nil
    return assign(s, { pending = pending })
  elseif a.type == "TABLE_ROW_UPDATE_ROLLBACK" then
    local p = s.pending[a.id]
    if not p then return s end
    local pending = shallow_copy(s.pending)
    pending[a.id] = nil
    local rows = shallow_copy(s.rows)
    local idx = nil
    for i, r in ipairs(rows) do if tostring(r.id) == tostring(a.id) then idx = i; break end end
    if idx and p.snapshot then rows[idx] = p.snapshot end
    return assign(s, { rows = rows, pending = pending })
  elseif a.type == "TABLE_BROWSER_OBJECT_SET" then
    return assign(s, { object = a.object, columns = a.columns or {}, rows = {}, meta = { page = 1, per_page = 100, total = 0, has_next = false }, status = "idle" })
  end
  return s
end

local function reduce_users(s, a)
  if a.type == "USERS_REQUESTED" then
    return assign(s, { status = "loading", filters = a.filters or s.filters }, { "error" })
  elseif a.type == "USERS_LOADED" then
    local items, by_id = {}, {}
    for i, u in ipairs(a.items or {}) do
      items[i] = u
      by_id[u.id] = i
    end
    return assign(s, { items = items, by_id = by_id, meta = a.meta, status = "ready" })
  elseif a.type == "USERS_FAILED" then return assign(s, { status = "error", error = a.error })
  elseif a.type == "USERS_FILTERS_CHANGED" then return assign(s, { filters = assign(s.filters, a.patch or {}) })
  elseif a.type == "USER_EDIT_OPENED" then return assign(s, { editing = a.id or "new" })
  elseif a.type == "USER_EDIT_CLOSED" then
    if s.editing == nil then return s end
    return assign(s, {}, { "editing" })
  elseif a.type == "USER_SAVE_REQUESTED" then return assign(s, { saving = true })
  elseif a.type == "USER_SAVED" then return assign(s, { saving = false }, { "editing" })
  elseif a.type == "USER_SAVE_FAILED" then return assign(s, { saving = false })
  elseif a.type == "USER_REMOVED" then
    local idx = s.by_id[a.id]
    if not idx then return s end
    local items, by_id = {}, {}
    for i, t in ipairs(s.items) do
      if i ~= idx then
        items[#items + 1] = t
        by_id[t.id] = #items
      end
    end
    return assign(s, { items = items, by_id = by_id })
  end
  return s
end

local function reduce_rbac(s, a)
  if a.type == "RBAC_REQUESTED" then return assign(s, { status = "loading" })
  elseif a.type == "RBAC_LOADED" then
    return assign(s, { pages = a.pages or s.pages, matrix = a.matrix, cache_ttl = a.cache_ttl, status = "ready" })
  elseif a.type == "RBAC_FAILED" then return assign(s, { status = "error" })
  elseif a.type == "RBAC_CELL_TOGGLED" then
    local matrix = s.matrix
    if not matrix then return s end
    local role = matrix[a.role]
    if not role then return s end
    local new_matrix = shallow_copy(matrix)
    new_matrix[a.role] = shallow_copy(role)
    local pending = shallow_copy(s.pending)
    pending[a.role .. ":" .. a.page_key] = { old = role[a.page_key] }
    new_matrix[a.role][a.page_key] = a.can_access
    return assign(s, { matrix = new_matrix, pending = pending })
  elseif a.type == "RBAC_CELL_CONFIRMED" then
    local pending = shallow_copy(s.pending)
    pending[a.role .. ":" .. a.page_key] = nil
    return assign(s, { pending = pending })
  elseif a.type == "RBAC_CELL_ROLLBACK" then
    local key = a.role .. ":" .. a.page_key
    local p = s.pending and s.pending[key]
    local matrix = s.matrix
    if p and matrix and matrix[a.role] then
      local new_matrix = shallow_copy(matrix)
      new_matrix[a.role] = shallow_copy(matrix[a.role])
      new_matrix[a.role][a.page_key] = p.old
      local pending = shallow_copy(s.pending)
      pending[key] = nil
      return assign(s, { matrix = new_matrix, pending = pending })
    end
    return s
  elseif a.type == "RBAC_MATRIX_REPLACED" then
    return assign(s, { matrix = a.matrix, pending = {} })
  end
  return s
end

local function reduce_audit(s, a)
  if a.type == "AUDIT_REQUESTED" then return assign(s, { status = "loading", filters = a.filters or s.filters })
  elseif a.type == "AUDIT_LOADED" then return assign(s, { items = a.items or {}, meta = a.meta, status = "ready" })
  elseif a.type == "AUDIT_FAILED" then return assign(s, { status = "error" })
  elseif a.type == "AUDIT_FILTERS_CHANGED" then return assign(s, { filters = assign(s.filters, a.patch or {}) })
  elseif a.type == "AUDIT_SELECTED" then return assign(s, { selected = a.id }, { "detail" })
  elseif a.type == "AUDIT_DETAIL_LOADED" then return assign(s, { detail = a.log })
  elseif a.type == "AUDIT_DESELECTED" then
    if s.selected == nil then return s end
    return assign(s, {}, { "selected", "detail" })
  elseif a.type == "AUDIT_STATS_LOADED" then return assign(s, { stats = a.stats })
  elseif a.type == "AUDIT_EXPORT_STARTED" then return assign(s, { exporting = true })
  elseif a.type == "AUDIT_EXPORT_FINISHED" then return assign(s, { exporting = false }) end
  return s
end

local function reduce_ui(s, a)
  if a.type == "TOAST_PUSHED" then
    for _, t in ipairs(s.toasts) do
      if t.message == a.toast.message then
        local toasts = shallow_copy(s.toasts)
        for i, tt in ipairs(toasts) do
          if tt.message == a.toast.message then
            toasts[i] = assign(tt, { count = (tt.count or 1) + 1 })
          end
        end
        return assign(s, { toasts = toasts })
      end
    end
    local toasts = shallow_copy(s.toasts)
    toasts[#toasts + 1] = a.toast
    while #toasts > 5 do table.remove(toasts, 1) end
    return assign(s, { toasts = toasts })
  elseif a.type == "TOAST_DISMISSED" then
    local toasts = {}
    for _, t in ipairs(s.toasts) do
      if t.id ~= a.id then toasts[#toasts + 1] = t end
    end
    return assign(s, { toasts = toasts })
  elseif a.type == "MODAL_CHANGED" then
    return assign(s, { modal_seq = (s.modal_seq or 0) + 1 })
  elseif a.type == "THEME_SET" then
    return assign(s, { theme = a.theme })
  elseif a.type == "SIDEBAR_TOGGLED" then
    return assign(s, { sidebar_open = not s.sidebar_open })
  elseif a.type == "SIDEBAR_SET" then
    if s.sidebar_open == a.sidebar_open then return s end
    return assign(s, { sidebar_open = a.sidebar_open })
  elseif a.type == "ROUTE_CHANGED" then
    if not (s.form_errors or s.forgot_sent or s.reset_done) then return s end
    return assign(s, { form_errors = false, forgot_sent = false, reset_done = false })
  elseif a.type == "LOGIN_REQUESTED" then
    return assign(s, { busy = assign(s.busy, { login = true }),
      form_errors = assign(s.form_errors or {}, { login = false }) })
  elseif a.type == "FORGOT_SENT" then
    return assign(s, { forgot_sent = true })
  elseif a.type == "RESET_DONE" then
    return assign(s, { reset_done = true })
  elseif a.type == "BUSY_SET" then
    return assign(s, { busy = assign(s.busy, { [a.key] = a.value }) })
  elseif a.type == "FORM_ERRORS_SET" then
    return assign(s, { form_errors = assign(s.form_errors or {}, { [a.form] = a.errors }) })
  end
  return s
end

local reducers = {
  route = reduce_route, auth = reduce_auth,
  connections = reduce_connections, databases = reduce_databases, schemas = reduce_schemas,
  objects = reduce_objects, structure = reduce_structure, query = reduce_query,
  table_browser = reduce_table_browser,
  users = reduce_users, rbac = reduce_rbac, audit = reduce_audit, ui = reduce_ui,
}

local reset_user_slices

-- Saf: değişmeyen dilim aynı tablo referansını korur (render kısa devresi)
local function root_reducer(state, action)
  if action.type == "LOGGED_OUT" then return reset_user_slices(state) end
  local next_state, changed = {}, false
  for k, r in pairs(reducers) do
    local s = r(state[k], action)
    next_state[k] = s
    if s ~= state[k] then changed = true end
  end
  return changed and next_state or state
end
app.root_reducer = root_reducer

reset_user_slices = function(state)
  local fresh = root_reducer(initial_state, { type = "AUTH_ANONYMOUS" })
  return assign(fresh, { route = state.route,
    ui = assign(initial_state.ui, { theme = state.ui.theme, toasts = state.ui.toasts }) })
end

-- --- store ------------------------------------------------------------------------

local state = initial_state
local render_scheduled = false
local current_tree = nil
local app_root_handle = nil
local rendering = false
local focus_pending = false

local toast_seq = 0
local toast_paused = {}

-- Tema tercihi ("light" | "dark" | "system") → data-theme'e yazılacak gerçek değer
local function effective_theme(pref)
  if pref == "system" then return js.media.prefersDark() and "dark" or "light" end
  return pref == "dark" and "dark" or "light"
end
app.effective_theme = effective_theme

function app.dispatch(action)
  if rendering then error("render içinde dispatch yapılamaz", 2) end
  local prev = state
  state = root_reducer(state, action)
  if state == prev then return end

  -- yan etkiler (reducer dışında)
  if action.type == "THEME_SET" then
    js.dom.setRootAttr("data-theme", effective_theme(action.theme))
    storage.set_raw("theme", action.theme)
  end
  app.schedule_render()
end

function app.get_state() return state end
app.state = app.get_state

-- Effect'leri coroutine'de çalıştırır; hata yakalanır ve toast'a çevrilir
function app.spawn(fn, ...)
  local args = table.pack(...)
  local co = coroutine.create(function()
    local ok, err = xpcall(function() return fn(table.unpack(args, 1, args.n)) end,
      function(e) return debug.traceback(tostring(e), 2) end)
    if not ok then
      js.log("error", "effect hatası: " .. tostring(err))
      app.toast("error", "Beklenmeyen bir hata oluştu")
    end
  end)
  local ok, err = coroutine.resume(co)
  if not ok then js.log("error", "spawn hatası: " .. tostring(err)) end
end

function app.can(page_key)
  return state.auth.status == "authenticated" and state.auth.permissions[page_key] == true
end

-- izinler değişince (/rbac hücresi, 403) /auth/me → PERMISSIONS_LOADED
local refreshing_permissions = false
function app.refresh_permissions()
  if refreshing_permissions then return end
  refreshing_permissions = true
  app.spawn(function()
    local data, err = api.get("/auth/me")
    refreshing_permissions = false
    if data and data.user then
      app.dispatch({ type = "USER_LOADED", user = data.user, permissions = data.permissions or {} })
      app.apply_route(router.current())
    elseif err then
      js.log("error", "refresh_permissions: " .. tostring(err.code))
    end
  end)
end

-- --- toast helper'ları -------------------------------------------------------------

local function schedule_dismiss(id, ms)
  js.timer.after(ms, function()
    if toast_paused[id] then return schedule_dismiss(id, 1000) end
    app.dispatch({ type = "TOAST_DISMISSED", id = id })
  end)
end

function app.toast(kind, message, opts)
  opts = opts or {}
  toast_seq = toast_seq + 1
  local id = "toast-" .. toast_seq
  local timeout = opts.timeout or (kind == "error" and 7000 or 4000)
  app.dispatch({ type = "TOAST_PUSHED", toast = { id = id, kind = kind, message = message, action = opts.action } })
  schedule_dismiss(id, timeout)
  return id
end

function app.pause_toast(id, paused)
  toast_paused[id] = paused or nil
end

-- --- render ------------------------------------------------------------------------

function app.schedule_render()
  if render_scheduled then return end
  render_scheduled = true
  js.timer.raf(function()
    render_scheduled = false
    app.render_now()
  end)
end

local function not_found()
  return dom.section({ class = "p-8" },
    dom.h1({ class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Sayfa bulunamadı"),
    dom.a({ href = "#/", class = "text-[var(--primary)] underline" }, "Panoya dön"))
end

local function build_tree()
  local layout_ok, layout = pcall(require, "views.layout")
  if not layout_ok then
    -- F16 stub: layout henüz yoksa doğrudan mesaj (PAGES sayısı)
    local ok, types = pcall(require, "pg_shared.types")
    local count = ok and #types.PAGES or 16
    return dom.div({ class = "p-8 text-center" },
      dom.h1({ class = "text-xl" }, "pg-web hazır — PAGES=" .. count))
  end
  if state.auth.status == "unknown" then
    return layout.boot_skeleton()
  end
  local parsed = state.route.name and router.current() or { name = "not_found" }
  local route_def = parsed.route
  local view = router.resolve(parsed)
  local content, title
  if state.route.forbidden then
    content, title = layout.forbidden_page(), "Erişim yok"
  elseif view then
    content, title = view.render(state, app.dispatch), view.title
  elseif route_def and not router.bundle_ready(route_def) then
    content, title = layout.page_skeleton(), "Yükleniyor"
  else
    content, title = not_found(), "Sayfa bulunamadı"
  end
  local with_layout = state.auth.status == "authenticated" and not (route_def and route_def.layout == false)
  return with_layout and layout.render(state, app.dispatch, content, title) or content, title
end

function app.render_now()
  rendering = true
  local ok, err = xpcall(function()
    if not app_root_handle then app_root_handle = js.dom.byId("app") end
    if not app_root_handle then return end

    local tree, title = build_tree()
    current_tree = dom.patch(app_root_handle, current_tree, tree)

    -- toast/modal/palette kökleri ayrı ağaçlar (F16/F21)
    local toast_ok, toast_mod = pcall(require, "components.toast")
    if toast_ok then toast_mod.render(state) end
    local modal_ok, modal_mod = pcall(require, "components.modal")
    if modal_ok then modal_mod.render(state) end
    local pal_ok, palette = pcall(require, "components.command_palette")
    if pal_ok and palette.render then palette.render(state) end
    local menu_ok, menu = pcall(require, "components.context_menu")
    if menu_ok then menu.render(state) end
    js.dom.openModals()

    if title then js.dom.title(title .. " · pgLua") end
  end, function(e) return debug.traceback(tostring(e), 2) end)
  rendering = false
  if not ok then js.log("error", "render hatası: " .. tostring(err)) end
  if focus_pending and state.auth.status ~= "unknown" then
    focus_pending = false
    -- sayfa değişiminde odağı başlığa taşı; kullanıcı Tab ile gezinmeye devam eder (skip-link'i atlamaz)
    if not js.dom.modalOpen() then js.dom.focusFirst("#main h1, #main") end
  end
end

-- --- route işleme --------------------------------------------------------------------

function app.apply_route(parsed)
  if not parsed then return end
  local redirect = router.guard(parsed, state.auth)
  if redirect and redirect ~= "forbidden" then
    router.navigate(redirect, { replace = true })
    return
  end
  local forbidden = redirect == "forbidden"
  app.dispatch({ type = "ROUTE_CHANGED", name = parsed.name, params = parsed.params, query = parsed.query,
    forbidden = forbidden })
  -- mobilde gezinme sonrası sidebar kapansın; masaüstünde açık kalır (Ctrl+B toggle'ı bozulmasın)
  if js.media and js.media.matches and js.media.matches("(max-width: 767px)") then
    app.dispatch({ type = "SIDEBAR_SET", sidebar_open = false })
  end
  focus_pending = true
  app.schedule_render()
  if state.auth.status == "unknown" or forbidden or not parsed.route then return end
  local r = parsed.route
  app.spawn(function()
    if not router.bundle_ready(r) then
      local ok2, err = router.load_bundle(r.bundle)
      if not ok2 then
        js.log("error", "bundle yüklenemedi: " .. tostring(err))
        app.toast("error", "Sayfa yüklenemedi. Bağlantınızı kontrol edin.")
        return
      end
      app.schedule_render()
    end
    local view = router.resolve(parsed)
    if view and view.enter then view.enter(parsed, state) end
  end)
end

function app.logout()
  app.spawn(function()
    local tokens = storage.get("auth")
    if tokens and tokens.access_token then
      api.post("/auth/logout", { refresh_token = tokens.refresh_token })
    end
    storage.remove("auth")
    app.dispatch({ type = "LOGGED_OUT" })
    router.navigate("#/login")
  end)
end

-- --- başlangıç ----------------------------------------------------------------------

function app.start(opts)
  opts = opts or {}

  -- 1. tema (boot.js ilk boyamayı zaten ayarladı; burada state'e alınır)
  local theme = storage.get_raw("theme") or "system"
  app.dispatch({ type = "THEME_SET", theme = theme })
  js.media.onChange("(prefers-color-scheme: dark)", function()
    if state.ui.theme == "system" then js.dom.setRootAttr("data-theme", effective_theme("system")) end
  end)
  -- codd Compact Mode: yogun veri gorunumu (Ayarlar'dan)
  js.dom.setRootAttr("data-density", storage.get_raw("density") == "compact" and "compact" or "comfortable")
  -- ana menü: masaüstünde son tercih (rail = yalnızca ikonlar)
  if storage.get_raw("sidebar") == "rail" then app.dispatch({ type = "SIDEBAR_SET", sidebar_open = false }) end

  -- 2. api yapılandırması
  api.configure({
    base = opts.apiBase or "/api/v1",
    -- PASSWORD_REQUIRED / SSH_HOST_KEY_UNKNOWN: kullaniciya sor, cozulduyse istek tekrarlanir
    on_recoverable = function(err)
      return require("views.connections").recover(err)
    end,
    get_tokens = function() return storage.get("auth") end,
    set_tokens = function(access, refresh)
      storage.set("auth", { access_token = access, refresh_token = refresh })
    end,
    on_logout = function()
      storage.remove("auth")
      if state.auth.status == "authenticated" then
        app.dispatch({ type = "LOGGED_OUT" })
        local cur = router.current()
        router.navigate("#/login?next=" .. router.urlencode(cur and cur.raw or "#/"))
      end
    end,
    on_forbidden = function() app.refresh_permissions() end,
  })

  -- 3. router
  router.start(app.apply_route)

  -- 4. klavye köprüsü + global kısayollar (F21)
  local ok_kb, keyboard = pcall(require, "keyboard")
  if ok_kb and keyboard.setup then
    keyboard.setup(app)
  else
    local ok, shortcuts = pcall(require, "shortcuts")
    if ok then
      shortcuts.register("global", "?", function()
        local ok2, modal = pcall(require, "components.modal")
        if ok2 and modal.help then modal.help() end
        return true
      end, "Kısayol yardımı")
      js.keyboard.onKey(function(key, typing, ctrl, alt, tag)
        return shortcuts.handle_key(key, typing, ctrl, alt, tag)
      end)
    end
  end

  -- 5. oturum geri yükleme; bitince guard mevcut route için yeniden çalışır
  app.spawn(function()
    local tokens = storage.get("auth")
    if tokens and tokens.access_token then
      local data = api.get("/auth/me")
      if data and data.user then
        app.dispatch({ type = "AUTH_RESTORED", user = data.user, permissions = data.permissions or {} })
      else
        storage.remove("auth")
        app.dispatch({ type = "AUTH_ANONYMOUS" })
      end
    else
      app.dispatch({ type = "AUTH_ANONYMOUS" })
    end
    app.apply_route(router.current())
  end)

  -- F16 stub kanıtı: ilk render'da PAGES sayısı loglanır, layout yoksa stub mesaj gösterilir
  local ok2, types = pcall(require, "pg_shared.types")
  if ok2 and state.auth.status == "anonymous" then
    -- placeholder zaten build_tree içinde; ek log
    js.log("info", "pg-web hazır — PAGES=" .. #types.PAGES)
  end

  app.schedule_render()
end

return app
