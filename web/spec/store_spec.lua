-- F21/F22: reducer birim testleri — pg-editor dilimleri (connections, query, rbac vb.) saf fonksiyonlar
require("helper")
local app = require("app")

local function run(action)
  return app.root_reducer(app.initial_state, action)
end

describe("root_reducer", function()
  it("bilinmeyen action state referansını korur", function()
    local next_state = run({ type = "UNKNOWN_ACTION" })
    assert.equal(app.initial_state, next_state)
  end)
end)

describe("auth reducer", function()
  it("LOGIN_SUCCEEDED authenticated yapar", function()
    local s = run({ type = "LOGIN_SUCCEEDED",
      user = { id = "u1", email = "a@b.c", role = "admin" },
      permissions = { ["users.list"] = true } })
    assert.equal("authenticated", s.auth.status)
    assert.equal("a@b.c", s.auth.user.email)
    assert.is_true(s.auth.permissions["users.list"])
  end)

  it("LOGGED_OUT kullanıcı dilimlerini sıfırlar", function()
    local s = run({ type = "LOGIN_SUCCEEDED", user = { id = "u1" }, permissions = {} })
    s = app.root_reducer(s, { type = "CONNECTIONS_LOADED", items = { { id = "c1", name = "pg" } } })
    s = app.root_reducer(s, { type = "LOGGED_OUT" })
    assert.equal("anonymous", s.auth.status)
    assert.equal(0, #s.connections.items)
    assert.is_nil(s.connections.editing)
  end)

  it("PERMISSIONS_LOADED izinleri günceller", function()
    local s = run({ type = "LOGIN_SUCCEEDED", user = { id = "u1" }, permissions = {} })
    s = app.root_reducer(s, { type = "PERMISSIONS_LOADED", permissions = { ["audit.logs"] = true } })
    assert.is_true(s.auth.permissions["audit.logs"])
    assert.equal("authenticated", s.auth.status)
  end)
end)

describe("connections reducer", function()
  it("CONNECTIONS_LOADED items ve by_id kurar", function()
    local s = run({ type = "CONNECTIONS_LOADED", items = { { id = "c1", name = "a" }, { id = "c2", name = "b" } }, meta = { total = 2 } })
    assert.equal(2, #s.connections.items)
    assert.equal(1, s.connections.by_id["c1"])
    assert.equal(2, s.connections.by_id["c2"])
    assert.equal("ready", s.connections.status)
  end)

  it("CONNECTION_CREATED yeni ekler, var ise günceller", function()
    local s = run({ type = "CONNECTIONS_LOADED", items = { { id = "c1", name = "a" } } })
    s = app.root_reducer(s, { type = "CONNECTION_CREATED", connection = { id = "c2", name = "b" } })
    assert.equal(2, #s.connections.items)
    s = app.root_reducer(s, { type = "CONNECTION_CREATED", connection = { id = "c1", name = "a2" } })
    assert.equal(2, #s.connections.items)
    assert.equal("a2", s.connections.items[1].name)
  end)

  it("CONNECTION_REMOVED indeks koruyarak siler", function()
    local s = run({ type = "CONNECTIONS_LOADED", items = { { id = "c1" }, { id = "c2" }, { id = "c3" } } })
    s = app.root_reducer(s, { type = "CONNECTION_REMOVED", id = "c2" })
    assert.equal(2, #s.connections.items)
    assert.equal("c1", s.connections.items[1].id)
    assert.equal("c3", s.connections.items[2].id)
    assert.is_nil(s.connections.by_id["c2"])
  end)

  it("CONNECTION_EDIT_OPENED/CLOSED editing alanini yonetir", function()
    local s = run({ type = "CONNECTION_EDIT_OPENED", id = "new" })
    assert.equal("new", s.connections.editing)
    s = app.root_reducer(s, { type = "CONNECTION_EDIT_CLOSED" })
    assert.is_nil(s.connections.editing)
  end)

  it("unknown id ile remove hata firlatmaz", function()
    local s = run({ type = "CONNECTIONS_LOADED", items = { { id = "c1" } } })
    local before = s.connections
    s = app.root_reducer(s, { type = "CONNECTION_REMOVED", id = "yok" })
    assert.equal(before, s.connections)
  end)
end)

describe("query reducer", function()
  it("QUERY_TAB_CREATED sekmeyi ekler ve aktif yapar", function()
    local s = run({ type = "QUERY_TAB_CREATED", title = "Sorgu 1", sql = "SELECT 1" })
    assert.equal(1, #s.query.tabs)
    assert.equal("Sorgu 1", s.query.tabs[1].title)
    assert.equal(1, s.query.active_tab)
    s = app.root_reducer(s, { type = "QUERY_TAB_CREATED", title = "Sorgu 2" })
    assert.equal(2, #s.query.tabs)
    assert.equal(2, s.query.active_tab)
  end)

  it("QUERY_TAB_CLOSED aktif indeksi korur", function()
    local s = run({ type = "QUERY_TAB_CREATED" })
    s = app.root_reducer(s, { type = "QUERY_TAB_CREATED" })
    s = app.root_reducer(s, { type = "QUERY_TAB_CREATED" })
    -- aktif 3
    s = app.root_reducer(s, { type = "QUERY_TAB_CLOSED", id = s.query.tabs[3].id })
    assert.equal(2, #s.query.tabs)
    assert.equal(2, s.query.active_tab)
  end)

  it("QUERY_RUN_REQUESTED/SUCCEEDED/FAILED durumu gunceller", function()
    local s = run({ type = "QUERY_TAB_CREATED" })
    local id = s.query.tabs[1].id
    s = app.root_reducer(s, { type = "QUERY_RUN_REQUESTED", id = id })
    assert.equal("running", s.query.tabs[1].status)
    s = app.root_reducer(s, { type = "QUERY_RUN_SUCCEEDED", id = id, result = { rows = {} } })
    assert.equal("ready", s.query.tabs[1].status)
    s = app.root_reducer(s, { type = "QUERY_RUN_FAILED", id = id, error = { code = "QUERY_FAILED" } })
    assert.equal("error", s.query.tabs[1].status)
  end)
end)

describe("table_browser reducer", function()
  it("TABLE_BROWSER_OBJECT_SET objeyi ve kolonlari sifirlar", function()
    local s = run({ type = "TABLE_BROWSER_OBJECT_SET", object = { schema = "public", name = "customers" }, columns = { { name = "id" } } })
    assert.equal("public", s.table_browser.object.schema)
    assert.equal(1, #s.table_browser.columns)
    assert.equal(0, #s.table_browser.rows)
  end)

  it("optimistic update + rollback snapshot geri getirir", function()
    local s = run({ type = "TABLE_ROWS_LOADED", rows = { { id = "1", name = "eski" } }, columns = {}, meta = {} })
    s = app.root_reducer(s, { type = "TABLE_ROW_UPDATE_OPTIMISTIC", id = "1", patch = { name = "yeni" } })
    assert.equal("yeni", s.table_browser.rows[1].name)
    s = app.root_reducer(s, { type = "TABLE_ROW_UPDATE_ROLLBACK", id = "1" })
    assert.equal("eski", s.table_browser.rows[1].name)
  end)
end)

describe("rbac reducer", function()
  local matrix = { admin = { ["rbac.matrix"] = true }, editor = { ["users.list"] = false } }

  it("CELL_TOGGLED optimistic uygular + snapshot saklar", function()
    local s = run({ type = "RBAC_LOADED", matrix = matrix, cache_ttl = 60 })
    s = app.root_reducer(s, { type = "RBAC_CELL_TOGGLED", role = "editor", page_key = "users.list", can_access = true })
    assert.is_true(s.rbac.matrix.editor["users.list"])
    assert.equals(false, s.rbac.pending["editor:users.list"].old)
  end)

  it("CELL_ROLLBACK eski degere doner", function()
    local s = run({ type = "RBAC_LOADED", matrix = matrix, cache_ttl = 60 })
    s = app.root_reducer(s, { type = "RBAC_CELL_TOGGLED", role = "editor", page_key = "users.list", can_access = true })
    s = app.root_reducer(s, { type = "RBAC_CELL_ROLLBACK", role = "editor", page_key = "users.list" })
    assert.is_false(s.rbac.matrix.editor["users.list"])
    assert.is_nil(s.rbac.pending["editor:users.list"])
  end)
end)

describe("route/ui reducer", function()
  it("CONNECTION_EDIT_CLOSED editing alanini siler", function()
    local s = run({ type = "CONNECTION_EDIT_OPENED", id = "new" })
    assert.equal("new", s.connections.editing)
    s = app.root_reducer(s, { type = "CONNECTION_EDIT_CLOSED" })
    assert.is_nil(s.connections.editing)
  end)

  it("ROUTE_CHANGED forbidden bayragini tasir; FORBIDDEN isaretler", function()
    local s = run({ type = "ROUTE_CHANGED", name = "users", forbidden = true })
    assert.is_true(s.route.forbidden)
    s = app.root_reducer(s, { type = "ROUTE_CHANGED", name = "audit" })
    assert.is_false(s.route.forbidden)
    s = app.root_reducer(s, { type = "FORBIDDEN" })
    assert.is_true(s.route.forbidden)
  end)

  it("SIDEBAR_SET ayni degerde referansi korur", function()
    local s = run({ type = "SIDEBAR_SET", sidebar_open = true })
    assert.equal(app.initial_state, s)
    s = app.root_reducer(s, { type = "SIDEBAR_SET", sidebar_open = false })
    assert.is_false(s.ui.sidebar_open)
  end)
end)

describe("diğer dilimler", function()
  local function chain(actions)
    local s = app.initial_state
    for _, a in ipairs(actions) do s = app.root_reducer(s, a) end
    return s
  end

  it("users: kaydetme ve silme", function()
    local s = chain({
      { type = "USERS_LOADED", items = { { id = "a" }, { id = "b" } }, meta = { total = 2 } },
      { type = "USER_EDIT_OPENED", id = "a" },
      { type = "USER_SAVE_REQUESTED" },
    })
    assert.is_true(s.users.saving)
    s = app.root_reducer(s, { type = "USER_SAVE_FAILED" })
    assert.is_false(s.users.saving)
    s = app.root_reducer(s, { type = "USER_EDIT_CLOSED" })
    assert.is_nil(s.users.editing)
    s = app.root_reducer(s, { type = "USER_REMOVED", id = "a" })
    assert.equal(1, #s.users.items)
  end)

  it("ui: toast queue 5 limit ve duplicate", function()
    local s = app.initial_state
    for i = 1, 6 do
      s = app.root_reducer(s, { type = "TOAST_PUSHED", toast = { id = "t" .. i, kind = "info", message = "m" .. i } })
    end
    assert.equal(5, #s.ui.toasts)
    assert.equal("t2", s.ui.toasts[1].id)
    s = app.root_reducer(s, { type = "TOAST_PUSHED", toast = { id = "t7", kind = "info", message = "m6" } })
    assert.equal(5, #s.ui.toasts)
    assert.equal(2, s.ui.toasts[5].count)
  end)
end)
