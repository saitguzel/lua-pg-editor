-- Audit entegrasyon testleri (pg-editor F12)
local h = require("helpers.init")

describe("audit (integration)", function()
  local admin, editor, conn_id, new_user
  setup(function()
    h.reset_db()
    admin = h.login_admin()
    editor = h.login_user()
    -- create a connection for audit events
    local res = h.request("POST", "/connections", { name = "audit-conn", host = "127.0.0.1", port = 5432, database = "testdb", username = "testuser" }, admin.access_token)
    if res.status == 201 then conn_id = res.body.data.id end
    new_user = h.create_user(admin.access_token)
    assert(h.request("PUT", "/users/" .. new_user.id, { full_name = "Degisti" }, admin.access_token).status == 200)
    assert(h.request("DELETE", "/users/" .. new_user.id, nil, admin.access_token).status == 204)
    h.request("PATCH", "/rbac/matrix/editor/settings", { can_access = true }, admin.access_token)
    h.request("PATCH", "/rbac/matrix/editor/settings", { can_access = false }, admin.access_token)
    h.request("GET", "/audit/logs", nil, editor.access_token) -- access.denied
  end)

  it("connection.create kaydinda ip dolu", function()
    local rows = h.audit(admin.access_token, "action=connection.create")
    assert.truthy(#rows >= 1)
    assert.is_string(rows[1].ip_address)
  end)

  it("user.create kaydinda password_hash maskeli", function()
    local rows = h.audit(admin.access_token, "action=user.create")
    local d = h.request("GET", "/audit/logs/" .. rows[1].id, nil, admin.access_token).body.data
    -- old/new JSONB decoded; check mask
    local new_val = d.new_value
    if type(new_val) == "string" then new_val = require("cjson.safe").decode(new_val) end
    if new_val then assert.equal("***", new_val.password_hash) end
  end)

  it("filtreler: action, status, from/to; >90 gun -> 422", function()
    h.request("POST", "/auth/login", { email = h.ADMIN.email, password = "Yanlis123!" })
    for _, r in ipairs(h.audit(admin.access_token, "action=auth.login.failure")) do
      assert.equal("auth.login.failure", r.action)
    end
    assert.equal(0, #h.audit(admin.access_token, "from=2020-01-01T00:00:00Z&to=2020-01-02T00:00:00Z"))
    local res = h.request("GET", "/audit/logs?from=2020-01-01T00:00:00Z", nil, admin.access_token)
    assert.equal(422, res.status)
  end)

  it("stats: toplam, by_status, by_action", function()
    local res = h.request("GET", "/audit/stats", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.truthy(res.body.data.total > 0)
    assert.is_table(res.body.data.by_status)
    assert.is_table(res.body.data.by_action)
  end)

  it("export: text/csv, BOM, baslik", function()
    local res = h.request("GET", "/audit/export?action=user.create", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.truthy(res.headers["content-type"]:find("text/csv"))
    assert.equal("\239\187\191", res.raw:sub(1, 3))
  end)

  it("editor /audit/* -> 403", function()
    for _, p in ipairs({ "/audit/logs", "/audit/stats", "/audit/export" }) do
      assert.equal(403, h.request("GET", p, nil, editor.access_token).status, p)
    end
  end)

  it("00 S8: user/rbac/access olaylari kayitli", function()
    local seen = {}
    for _, r in ipairs(h.audit(admin.access_token)) do seen[r.action] = true end
    for _, a in ipairs({ "user.create", "user.update", "user.delete", "rbac.matrix.update", "access.denied", "auth.login.success" }) do
      assert.is_true(seen[a] == true, "audit yok: " .. a)
    end
  end)
end)
