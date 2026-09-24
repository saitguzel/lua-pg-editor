-- Nesne eylemleri (codd sidebar menusu): script (yeni sorgu sekmesinde), yeniden adlandir, bosalt, sil.
-- Sidebar ve yapi sayfasi ortak kullanir. ctx = { connection_id, database, schema, name, kind }
local app = require("app")
local api = require("fetch")
local router = require("router")
local protocol = require("pg_shared.protocol")

local _M = {}

local TABLE_KINDS = { table = true, partitioned = true }
_M.TABLE_KINDS = TABLE_KINDS
-- rename/truncate/drop ve SELECT scripti yalnız ilişkiler için; CREATE scripti ayrıca sequence/type/domain için
local RELATION_KINDS = { table = true, partitioned = true, view = true, matview = true, foreign = true }
local CREATE_ONLY_KINDS = { sequence = true, type_base = true, type_composite = true, type_enum = true,
  type_range = true, domain = true }

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

-- sema degisti: sidebar + autocomplete tazelensin; acik sayfa bu nesneyi gösteriyorsa yonlendir
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
  if app.can("script.generate") then
    local kinds
    if TABLE_KINDS[ctx.kind] then
      kinds = { { "create", "CREATE" }, { "select", "SELECT" }, { "insert", "INSERT" }, { "update", "UPDATE" },
        { "delete", "DELETE" } }
    elseif RELATION_KINDS[ctx.kind] then
      kinds = { { "create", "CREATE" }, { "select", "SELECT" } }
    elseif CREATE_ONLY_KINDS[ctx.kind] then
      kinds = { { "create", "CREATE script'i göster" } }
    end
    if kinds then
      items[#items + 1] = { group = "Script" }
      for _, k in ipairs(kinds) do
        items[#items + 1] = { label = k[2], onclick = function() _M.script(ctx, k[1]) end }
      end
    end
  end
  if app.can("object.actions") and RELATION_KINDS[ctx.kind] then
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Yeniden adlandır…", onclick = function() _M.rename(ctx) end }
    if TABLE_KINDS[ctx.kind] then
      items[#items + 1] = { label = "Boşalt (TRUNCATE)…", danger = true, onclick = function() _M.truncate(ctx) end }
    end
    items[#items + 1] = { label = "Sil…", danger = true, onclick = function() _M.drop(ctx) end }
  end
  return items
end

-- --- fonksiyon / prosedür / trigger (oid ile) ----------------------------------------
-- ctx = { connection_id, database, schema, name, kind = function|procedure|trigger, oid, args, table, enabled }
_M.ROUTINE_LABEL = { ["function"] = "fonksiyon", procedure = "prosedür", trigger = "trigger",
  aggregate = "aggregate fonksiyonu", window = "window fonksiyonu" }

local function routine_path(ctx)
  return "/connections/" .. router.urlencode(ctx.connection_id) .. "/routines/" .. ctx.kind .. "/"
    .. string.format("%d", tonumber(ctx.oid)) -- json sayısı float gelebilir ("123.0" olmasın)
end

local function routine_changed()
  pcall(function() require("views.schema_sidebar").reload() end)
end

-- type: ddl (düzenlenebilir CREATE OR REPLACE) | execute | drop — yeni sorgu sekmesinde açılır
function _M.routine_script(ctx, type)
  app.spawn(function()
    local q = { type = type }
    if ctx.database and ctx.database ~= "" then q.database = ctx.database end
    local data, err = api.get(routine_path(ctx) .. "/script", q)
    if err then return fail(err) end
    require("views.query_editor").open_in_new_tab(data.sql or "",
      { connection_id = ctx.connection_id, database = ctx.database })
  end)
end

function _M.routine_rename(ctx)
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
    local _, err = api.post(routine_path(ctx) .. "/rename" .. with_db(ctx), { new_name = new_name })
    if err then return fail(err) end
    app.toast("success", ctx.name .. " → " .. new_name)
    routine_changed()
  end)
end

function _M.routine_drop(ctx)
  app.spawn(function()
    local modal = require("components.modal")
    local label = ctx.schema .. "." .. ctx.name
      .. (ctx.kind == "trigger" and (" (" .. tostring(ctx.table) .. " üzerinde)") or ("(" .. (ctx.args or "") .. ")"))
    if not modal.confirm({ title = "Silinsin mi?", danger = true, confirm_label = "Sil",
      message = label .. " " .. _M.ROUTINE_LABEL[ctx.kind] .. " kalıcı olarak silinecek." }) then return end
    local _, err = api.delete(routine_path(ctx) .. with_db(ctx))
    if err and err.details and err.details.sqlstate == "2BP01" then
      if not modal.confirm({ title = "Bağımlı nesneler var", danger = true, confirm_label = "CASCADE ile sil",
        message = "Başka nesneler " .. ctx.name .. " nesnesine bağlı (ör. trigger). Birlikte silinsin mi?" }) then
        return
      end
      _, err = api.delete(routine_path(ctx) .. with_db(ctx, "cascade=true"))
    end
    if err then return fail(err) end
    app.toast("success", ctx.name .. " silindi")
    routine_changed()
  end)
end

function _M.trigger_toggle(ctx)
  app.spawn(function()
    local _, err = api.post(routine_path(ctx) .. "/enabled" .. with_db(ctx), { enabled = not ctx.enabled })
    if err then return fail(err) end
    app.toast("success", ctx.name .. (ctx.enabled and " devre dışı bırakıldı" or " etkinleştirildi"))
    routine_changed()
  end)
end

function _M.routine_menu_items(ctx)
  local items = {}
  local function copy(text) js.clipboard(text); app.toast("success", "Kopyalandı") end
  if app.can("script.generate") then
    items[#items + 1] = { label = ctx.kind == "trigger" and "Tanımı düzenle (DDL)" or "Düzenle (CREATE OR REPLACE)",
      onclick = function() _M.routine_script(ctx, "ddl") end }
    if ctx.kind ~= "trigger" then
      items[#items + 1] = { label = ctx.kind == "procedure" and "CALL betiği" or "SELECT betiği",
        onclick = function() _M.routine_script(ctx, "execute") end }
    end
    items[#items + 1] = { label = "DROP betiği", onclick = function() _M.routine_script(ctx, "drop") end }
  end
  items[#items + 1] = { label = "Adı kopyala", onclick = function() copy(ctx.name) end }
  if app.can("object.actions") then
    items[#items + 1] = { separator = true }
    if ctx.kind == "trigger" then
      items[#items + 1] = { label = ctx.enabled and "Devre dışı bırak" or "Etkinleştir",
        onclick = function() _M.trigger_toggle(ctx) end }
    end
    items[#items + 1] = { label = "Yeniden adlandır…", onclick = function() _M.routine_rename(ctx) end }
    items[#items + 1] = { label = "Sil…", danger = true, onclick = function() _M.routine_drop(ctx) end }
  end
  return items
end

return _M
