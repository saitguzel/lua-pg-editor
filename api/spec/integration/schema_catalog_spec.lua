-- F25 entegrasyon: kategori sayaclari, kategori listesi, rules/policies, detail ve CREATE script.
-- Hedef olarak meta DB'nin kendisi kullanilir (API konteynerinden DB_HOST); nesneler it_f25 semasinda
-- olusturulup silinir.
-- YALNIZ izole test yiginda (make up.e2e / make test.integration) kosar: h.reset_db meta DB'yi TRUNCATE eder.
local h = require("helpers.init")

describe("schema catalog (integration)", function()
  local admin, conn_id
  local base
  local function run(sql)
    local res = h.request("POST", "/query/execute", { connection_id = conn_id, sql = sql }, admin.access_token)
    assert(res.status == 200, "sql: " .. tostring(res.status) .. " " .. res.raw)
    return res.body.data
  end

  setup(function()
    h.reset_db()
    admin = h.login_admin()
    local res = h.request("POST", "/connections", {
      name = "f25-self", host = os.getenv("DB_HOST") or "postgres", port = 5432,
      database = os.getenv("DB_NAME") or "pgeditor", username = os.getenv("DB_USER") or "pgeditor",
      password = os.getenv("DB_PASSWORD"), save_password = true,
    }, admin.access_token)
    assert(res.status == 201, "connection: " .. tostring(res.status) .. " " .. res.raw)
    conn_id = res.body.data.id
    base = "/connections/" .. conn_id
    run([[DROP SCHEMA IF EXISTS it_f25 CASCADE; CREATE SCHEMA it_f25;
      CREATE TABLE it_f25.orders (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, status text);
      CREATE VIEW it_f25.v_orders AS SELECT id FROM it_f25.orders;
      CREATE TYPE it_f25.status AS ENUM ('new', 'paid');
      CREATE DOMAIN it_f25.email AS text CHECK (VALUE LIKE '%@%');
      CREATE SEQUENCE it_f25.manual_seq START 5;
      CREATE FUNCTION it_f25.add(a int, b int) RETURNS int LANGUAGE sql AS 'SELECT a + b';
      ALTER TABLE it_f25.orders ENABLE ROW LEVEL SECURITY;
      CREATE POLICY p_all ON it_f25.orders FOR SELECT USING (true);
      CREATE RULE r_nodel AS ON DELETE TO it_f25.orders DO INSTEAD NOTHING;]])
  end)

  teardown(function()
    if conn_id then run("DROP SCHEMA IF EXISTS it_f25 CASCADE") end
  end)

  it("categories: 16 kategori, sayaclar dogru", function()
    local res = h.request("GET", base .. "/schemas/it_f25/categories", nil, admin.access_token)
    assert.equal(200, res.status)
    local by = {}
    for _, c in ipairs(res.body.data) do by[c.category] = c.count end
    assert.equal(16, #res.body.data)
    assert.equal(1, by.tables); assert.equal(1, by.views); assert.equal(1, by.functions)
    assert.equal(2, by.sequences) -- identity sequence + manual_seq
    assert.equal(1, by.types); assert.equal(1, by.domains); assert.equal(0, by.extensions)
  end)

  it("objects?category= kind/meta; q filtresi; category'siz F7 yaniti", function()
    local res = h.request("GET", base .. "/schemas/it_f25/objects?category=types", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.equal("type_enum", res.body.data[1].kind)
    assert.equal(1, res.body.meta.total)
    assert.is_false(res.body.meta.has_more)
    res = h.request("GET", base .. "/schemas/it_f25/objects?category=sequences&q=man&limit=1", nil, admin.access_token)
    assert.equal(1, #res.body.data)
    assert.equal("manual_seq", res.body.data[1].name)
    res = h.request("GET", base .. "/schemas/it_f25/objects?category=functions", nil, admin.access_token)
    assert.equal("(a integer, b integer)", res.body.data[1].extra)
    res = h.request("GET", base .. "/schemas/it_f25/objects", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.is_nil(res.body.meta)
    assert.equal(2, #res.body.data) -- orders + v_orders
    assert.equal(422, h.request("GET", base .. "/schemas/it_f25/objects?category=nope", nil, admin.access_token).status)
  end)

  it("structure: rules/policies; enum detail.labels", function()
    local res = h.request("GET", base .. "/objects/it_f25/orders/structure", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.equal("r_nodel", res.body.data.rules[1].name)
    assert.equal("DELETE", res.body.data.rules[1].event)
    assert.is_true(res.body.data.rules[1].is_instead)
    assert.equal("p_all", res.body.data.policies[1].name)
    assert.equal("SELECT", res.body.data.policies[1].command)
    assert.same({ "public" }, res.body.data.policies[1].roles)
    res = h.request("GET", base .. "/objects/it_f25/status/structure?kind=type_enum", nil, admin.access_token)
    assert.equal(200, res.status)
    assert.equal("type_enum", res.body.data.kind)
    assert.same({ "new", "paid" }, res.body.data.detail.labels)
    res = h.request("GET", base .. "/objects/it_f25/manual_seq/structure", nil, admin.access_token)
    assert.equal("sequence", res.body.data.kind)
    assert.equal(5, tonumber(res.body.data.detail.start))
    assert.equal(404, h.request("GET", base .. "/objects/it_f25/yok/structure", nil, admin.access_token).status)
  end)

  it("script?kind=create view/enum/sequence/domain", function()
    local function create(name)
      local res = h.request("GET", base .. "/objects/it_f25/" .. name .. "/script?kind=create", nil, admin.access_token)
      assert.equal(200, res.status, res.raw)
      return res.body.data.sql
    end
    assert.truthy(create("v_orders"):find('CREATE VIEW "it_f25"."v_orders" AS', 1, true))
    assert.truthy(create("status"):find([[CREATE TYPE "it_f25"."status" AS ENUM ('new', 'paid');]], 1, true))
    assert.truthy(create("manual_seq"):find("START WITH 5", 1, true))
    assert.truthy(create("email"):find('CREATE DOMAIN "it_f25"."email" AS text', 1, true))
  end)

  it("DDL sonrasi kategori sayaci guncellenir (cache invalidation)", function()
    run("CREATE SEQUENCE it_f25.second_seq")
    local res = h.request("GET", base .. "/schemas/it_f25/categories", nil, admin.access_token)
    for _, c in ipairs(res.body.data) do if c.category == "sequences" then assert.equal(3, c.count) end end
  end)
end)
