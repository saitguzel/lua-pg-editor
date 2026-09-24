-- Nesne eylemleri (codd sidebar menusu): script (yeni sorgu sekmesinde), yeniden adlandir, bosalt, sil.
-- Sidebar ve yapi sayfasi ortak kullanir. ctx = { connection_id, database, schema, name, kind }
local app = require("app")
local api = require("fetch")
local router = require("router")
local protocol = require("pg_shared.protocol")

local _M = {}

local TABLE_KINDS = { table = true, partitioned = true }
_M.TABLE_KINDS = TABLE_KINDS

local function obj_path(ctx)
  return "/connections/" .. router.urlencode(ctx.connection_id) .. "/objects/" .. router.urlencode(ctx.schema)
    .. "/" .. router.urlencode(ctx.name)
end

local function with_db(ctx, extra)
  local parts = {}
  if ctx.database and ctx.database ~= "" then parts[#parts + 1] = "database=" .. router.urlencode(ctx.database) end
  if extra then parts[#parts + 1] = extra end
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function fail(err) app.toast("error", err and err.message or protocol.message(err and err.code)) end

-- sema degisti: sidebar + autocomplete tazelensin; acik sayfa bu nesneyi gosteriyorsa yonlendir
local function after_change(ctx, new_name)
  pcall(function() require("views.schema_sidebar").reload() end)
  local st = app.get_state()
  local p = st.route.params or {}
  local on_object = (st.route.name == "browse" or st.route.name == "structure")
    and p.schema == ctx.schema and (p.table or p.name) == ctx.name
  if on_object then
    if new_name then
      local q = st.route.query or {}
      router.navigate("#/" .. st.route.name .. "/" .. router.urlencode(ctx.schema) .. "/" .. router.urlencode(new_name)
        .. "?connection_id=" .. router.urlencode(q.connection_id or ctx.connection_id)
        .. (q.database and ("&database=" .. router.urlencode(q.database)) or ""))
    else
      router.navigate("#/query")
    end
  end
end

-- codd: uretilen script yeni sorgu sekmesinde acilir
function _M.script(ctx, kind)
  app.spawn(function()
    local q = { kind = kind }
    if ctx.database and ctx.database ~= "" then q.database = ctx.database end
    local data, err = api.get(obj_path(ctx) .. "/script", q)
    if err then return fail(err) end
    require("views.query_editor").open_in_new_tab(data.sql or "", { connection_id = ctx.connection_id, database = ctx.database })
  end)
end

function _M.rename(ctx)
  app.spawn(function()
    local new_name = require("components.modal").prompt({
      title = "Yeniden adlandır: " .. ctx.schema .. "." .. ctx.name, label = "Yeni ad", value = ctx.name,
      validate = function(v)
        if v == "" then return "Ad boş olamaz" end
        if #v > 63 then return "En fazla 63 bayt" end
        if v == ctx.name then return "Ad aynı" end
      end,
    })
    if not new_name then return end
    local _, err = api.post(obj_path(ctx) .. "/rename" .. with_db(ctx), { new_name = new_name })
    if err then return fail(err) end
    app.toast("success", ctx.name .. " → " .. new_name)
    after_change(ctx, new_name)
  end)
end

function _M.truncate(ctx)
  app.spawn(function()
    local ok, opts = require("components.modal").confirm({
      title = "Tablo boşaltılsın mı?", danger = true, confirm_label = "Boşalt",
      message = ctx.schema .. "." .. ctx.name .. " tablosundaki tüm satırlar silinecek. Bu işlem geri alınamaz.",
      checkboxes = { { key = "restart_identity", label = "Identity/sequence sayaçlarını sıfırla (RESTART IDENTITY)" },
                     { key = "cascade", label = "Bağlı tabloları da boşalt (CASCADE)" } },
    })
    if not ok then return end
    local _, err = api.post(obj_path(ctx) .. "/truncate" .. with_db(ctx),
      { restart_identity = opts.restart_identity, cascade = opts.cascade })
    if err then return fail(err) end
    app.toast("success", ctx.name .. " boşaltıldı")
    if app.get_state().route.name == "browse" then pcall(function() require("views.table_browser").reload() end) end
  end)
end

function _M.drop(ctx)
  app.spawn(function()
    local modal = require("components.modal")
    local what = TABLE_KINDS[ctx.kind] and "tablo" or (ctx.kind == "matview" and "materialized view" or ctx.kind or "nesne")
    if not modal.confirm({ title = "Silinsin mi?", danger = true, confirm_label = "Sil",
      message = ctx.schema .. "." .. ctx.name .. " (" .. what .. ") kalıcı olarak silinecek." }) then return end
    local _, err = api.delete(obj_path(ctx) .. with_db(ctx))
    -- codd: bagimli nesne varsa (2BP01) CASCADE ile tekrar denemeyi oner
    if err and err.details and err.details.sqlstate == "2BP01" then
      if not modal.confirm({ title = "Bağımlı nesneler var", danger = true, confirm_label = "CASCADE ile sil",
        message = "Başka nesneler " .. ctx.name .. " nesnesine bağlı. Bağımlı nesnelerle birlikte silinsin mi?" }) then return end
      _, err = api.delete(obj_path(ctx) .. with_db(ctx, "cascade=true"))
    end
    if err then return fail(err) end
    app.toast("success", ctx.name .. " silindi")
    after_change(ctx, nil)
  end)
end

-- sidebar/yapi menusu ogeleri (izinlere gore); extra: basa eklenecek ogeler
function _M.menu_items(ctx, extra)
  local items = extra or {}
  local function copy(text) js.clipboard(text); app.toast("success", "Kopyalandı") end
  local qualified = '"' .. ctx.schema:gsub('"', '""') .. '"."' .. ctx.name:gsub('"', '""') .. '"'
  items[#items + 1] = { label = "Adı kopyala", onclick = function() copy(ctx.name) end }
  items[#items + 1] = { label = "Nitelikli adı kopyala", onclick = function() copy(qualified) end }
  if TABLE_KINDS[ctx.kind] and app.can("script.generate") then
    items[#items + 1] = { group = "Script" }
    for _, k in ipairs({ { "create", "CREATE" }, { "select", "SELECT" }, { "insert", "INSERT" },
                         { "update", "UPDATE" }, { "delete", "DELETE" } }) do
      items[#items + 1] = { label = k[2], onclick = function() _M.script(ctx, k[1]) end }
    end
  end
  if app.can("object.actions") then
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Yeniden adlandır…", onclick = function() _M.rename(ctx) end }
    if TABLE_KINDS[ctx.kind] then
      items[#items + 1] = { label = "Boşalt (TRUNCATE)…", danger = true, onclick = function() _M.truncate(ctx) end }
    end
    items[#items + 1] = { label = "Sil…", danger = true, onclick = function() _M.drop(ctx) end }
  end
  return items
end

return _M
