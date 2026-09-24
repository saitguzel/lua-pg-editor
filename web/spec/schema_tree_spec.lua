-- F26: Nesne gezgini — saf yardımcılar ve ağacın lazy istek akışı (sahte http üzerinden).
local fake = require("helper")
local json = require("json")
local tree = require("views.schema_tree")

describe("schema_tree yardımcıları", function()
  it("format_count", function()
    assert.equal("Tables (24)", tree.format_count("Tables", 24))
    assert.equal("Tables (0)", tree.format_count("Tables", 0))
    assert.equal("Tables (0)", tree.format_count("Tables", nil))
  end)

  it("quick_filter_matches", function()
    assert.is_true(tree.quick_filter_matches("tables", "foreign_tables"))
    assert.is_false(tree.quick_filter_matches("tables", "views"))
    assert.is_true(tree.quick_filter_matches("all", "sequences"))
    assert.is_true(tree.quick_filter_matches(nil, "sequences"))
    assert.is_true(tree.quick_filter_matches("routines", "triggers"))
    assert.is_true(tree.quick_filter_matches("other", "fts_configs"))
  end)

  it("node_key", function()
    assert.equal("public", tree.node_key("public"))
    assert.equal("public:tables", tree.node_key("public", "tables"))
    assert.equal("public.orders", tree.node_key("public", nil, "orders"))
  end)

  it("filter_items ad ve tablo adında arar", function()
    local items = { { name = "orders" }, { name = "orders_id_seq" }, { name = "customers" },
      { name = "trg", table = "ORDERS" } }
    local out = tree.filter_items(items, "ord")
    assert.equal(3, #out)
    assert.equal("orders", out[1].name)
    assert.equal("trg", out[3].name)
    assert.same(items, tree.filter_items(items, ""))
  end)

  it("her kategori ve tür için ikon/etiket tanımlı", function()
    assert.equal(16, #tree.CATEGORIES)
    for kind in pairs(tree.KIND_LABEL) do
      assert.is_truthy(tree.ICON[kind], kind .. " ikonu yok")
      assert.is_truthy(tree.ICON_COLOR[kind], kind .. " rengi yok")
      assert.is_truthy(require("icons").names[tree.ICON[kind]], kind .. " ikon yolu yok")
    end
    assert.equal("function", tree.routine_kind("aggregate"))
    assert.equal("procedure", tree.routine_kind("procedure"))
    assert.is_nil(tree.routine_kind("table"))
  end)
end)

describe("schema_sidebar lazy ağaç", function()
  local app = require("app")
  local sidebar = require("views.schema_sidebar")

  -- vnode ağacındaki metinleri birleştirir
  local function texts(v, out)
    out = out or {}
    if type(v) ~= "table" then return out end
    if v.text then out[#out + 1] = v.text end
    for _, c in ipairs(v.children or {}) do texts(c, out) end
    return out
  end
  local function has_text(v, s)
    for _, t in ipairs(texts(v)) do if t == s then return true end end
    return false
  end
  local function state()
    return app.root_reducer(app.initial_state, { type = "ROUTE_CHANGED", name = "browse",
      params = { schema = "public", table = "orders" }, query = { connection_id = "c1" } })
  end
  local function urls()
    local out = {}
    for _, c in ipairs(fake.calls) do out[#out + 1] = c.url end
    return out
  end
  local function called(pattern)
    for _, u in ipairs(urls()) do if u:find(pattern, 1, true) then return true end end
    return false
  end

  before_each(function()
    fake.reset()
    sidebar._reset()
    -- sıra: completion (render), schemas, categories(public)
    fake.queue_response(200, json.encode({ data = { schemas = { { name = "public", tables = {}, routines = {},
      triggers = { { oid = 7, name = "trg_a", table = "orders", enabled = true } } } } } }))
    fake.queue_response(200, json.encode({ data = { "public", "audit" } }))
    fake.queue_response(200, json.encode({ data = { { category = "tables", count = 2 },
      { category = "views", count = 0 }, { category = "sequences", count = 1 } } }))
  end)

  it("şema listesi ve açık şemanın kategorileri yüklenir; sayaçlar etikette", function()
    sidebar.render(state())
    assert.is_true(called("/connections/c1/schemas"))
    assert.is_true(called("/connections/c1/schemas/public/categories"))
    assert.is_false(called("/schemas/audit/categories")) -- kapalı şema lazy
    local v = sidebar.render(state())
    assert.is_true(has_text(v, "Tables (2)"))
    assert.is_true(has_text(v, "Views (0)"))
    assert.is_true(has_text(v, "Sequences (1)"))
    assert.is_true(has_text(v, "Triggers (1)"))
    assert.is_false(called("category=tables")) -- kategori açılmadan nesne istenmez
  end)

  it("kategori açılınca nesneler tek istekle gelir; ikinci render yeni istek atmaz", function()
    fake.storage_store["pg.sidebar.expanded:c1"] = json.encode({ ["public:tables"] = true })
    fake.queue_response(200, json.encode({ data = { { schema = "public", name = "orders", kind = "table" },
      { schema = "public", name = "items", kind = "table" } },
      meta = { total = 2, limit = 200, offset = 0, has_more = false } }))
    sidebar.render(state())
    assert.is_true(called("category=tables"))
    local n = #fake.calls
    local v = sidebar.render(state())
    assert.equal(n, #fake.calls)
    assert.is_true(has_text(v, "orders"))
    assert.is_true(has_text(v, "items"))
  end)

  it("hızlı filtre kategorileri gizler", function()
    sidebar.render(state())
    fake.storage_store["pg.sidebar.filter"] = json.encode("tables")
    local v = sidebar.render(state())
    assert.is_true(has_text(v, "Tables (2)"))
    assert.is_false(has_text(v, "Sequences (1)"))
    assert.is_false(has_text(v, "Triggers (1)"))
  end)
end)
