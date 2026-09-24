-- F17: shortcuts testleri — editable hedef koruması (WCAG 2.1.4), scope temizliği.
local fake = require("helper")
local shortcuts = require("shortcuts")
local app = require("app")

describe("shortcuts", function()
  before_each(function()
    fake.reset()
    -- kısayollar yalnızca aktif sayfanın scope'unda çalışır
    app.dispatch({ type = "ROUTE_CHANGED", name = "connections" })
    shortcuts.unregister_scope("connections")
    shortcuts.unregister_scope("global")
    shortcuts.unregister_scope("browse")
    shortcuts.unregister_scope("users")
    shortcuts.unregister_scope("query")
    -- g sekansi temizle
    if shortcuts._clear_pending then shortcuts._clear_pending() end
  end)

  it("kayıtlı kısayol tetiklenir", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "Yeni bağlantı")
    shortcuts.handle_key("n", false, false, false)
    assert.is_true(called)
  end)

  it("Ctrl+K paleti tetikler", function()
    -- Ctrl+K her zaman paleti acar (typing olsa da)
    assert.is_true(shortcuts.handle_key("k", true, true, false))
    assert.is_true(shortcuts.handle_key("k", false, true, false))
  end)

  it("Ctrl+B sidebar", function()
    assert.is_true(shortcuts.handle_key("b", false, true, false))
    assert.is_true(shortcuts.handle_key("b", true, true, false))
  end)

  it("editable hedefte tek harfliler tetiklenmez", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "Yeni bağlantı")
    shortcuts.handle_key("n", true, false, false) -- typing = true
    assert.is_false(called)
  end)

  it("Ctrl/Alt ile tetiklenmez", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "Yeni bağlantı")
    shortcuts.handle_key("n", false, true, false) -- ctrl
    assert.is_false(called)
    shortcuts.handle_key("n", false, false, true) -- alt
    assert.is_false(called)
  end)

  it("tanımsız scope'ta tetiklenmez", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "")
    shortcuts.handle_key("x", false, false, false)
    assert.is_false(called)
  end)

  it("unregister_scope temizler", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "")
    shortcuts.unregister_scope("connections")
    shortcuts.handle_key("n", false, false, false)
    assert.is_false(called)
  end)

  it("connections sayfasında scope aktiftir", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "")
    app.dispatch({ type = "ROUTE_CHANGED", name = "connections" })
    shortcuts.handle_key("n", false, false, false)
    assert.is_true(called)
  end)

  it("başka sayfanın scope'u tetiklenmez", function()
    local called = false
    shortcuts.register("users", "n", function() called = true end, "")
    shortcuts.handle_key("n", false, false, false)
    assert.is_false(called)
    shortcuts.unregister_scope("users")
  end)

  it("açık modal varken kısayollar çalışmaz (Esc native dialog'a kalır)", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "")
    fake.modal_open = true
    assert.is_false(shortcuts.handle_key("n", false, false, false))
    assert.is_false(called)
  end)

  it("true dönen kısayol preventDefault ister", function()
    shortcuts.register("connections", "/", function() return true end, "")
    assert.is_true(shortcuts.handle_key("/", false, false, false))
  end)

  it("kullanıcı kapatınca hiçbir kısayol çalışmaz (WCAG 2.1.4)", function()
    local called = false
    shortcuts.register("connections", "n", function() called = true end, "")
    shortcuts.set_enabled(false)
    shortcuts.handle_key("n", false, false, false)
    assert.is_false(called)
    shortcuts.set_enabled(true)
    shortcuts.handle_key("n", false, false, false)
    assert.is_true(called)
  end)

  it("list kayıtları döner", function()
    shortcuts.register("connections", "n", function() end, "Yeni bağlantı")
    shortcuts.register("global", "?", function() end, "Yardım")
    local list = shortcuts.list()
    assert.equal(2, #list)
  end)
end)
