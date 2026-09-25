-- Tablo tarayıcı servis: filtreli liste, satır CRUD, cogaltma, audit.
-- codd kurallari: satır islemleri yalnizca PK'li tablolarda; PK/identity(ALWAYS)/generated/bytea kolonlari
-- duzenlenemez; view/matview salt okunur.
local cjson = require("cjson.safe")
local connection_repo = require("repositories.connection_repo")
local target_schema_repo = require("repositories.target_schema_repo")
local target_browser = require("db.target.table_browser")
local pool_manager = require("db.pool_manager")
local sql_parser = require("utils.sql_parser")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local table_browser_model = require("models.table_browser")
local table_structure = require("models.table_structure")

local _M = {}

local EDITABLE_KINDS = { table = true, partitioned = true }

local function get_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı") end
  return row
end

local function map_target(err)
  if type(err) == "table" and err.__app_error then return err end
  local sqlstate = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  if sqlstate == "42P01" then return errors.new("OBJECT_NOT_FOUND", "Tablo veya view bulunamadı", { sqlstate = sqlstate }) end
  return errors.new("QUERY_FAILED", "Sorgu çalıştırilamadi", { sqlstate = sqlstate, db_message = msg })
end

-- Hedef tablo meta'si: kolon DTO'lari, PK kolonlari, tur, satır duzenlenebilir mi
local function describe(pg, schema, table_name)
  local rows, err = target_schema_repo.list_columns(pg, schema, table_name)
  if not rows then return nil, err end
  local kind = target_schema_repo.object_kind(pg, schema, table_name) or "table"
  local cols, by_name, pk = {}, {}, {}
  for i, r in ipairs(rows) do
    local c = table_structure._normalize_column(r)
    c.read_only = c.is_primary_key or c.type_group == "binary" or c.is_generated or c.identity_kind == "ALWAYS"
    cols[i], by_name[c.name] = c, c
    if c.is_primary_key then pk[#pk + 1] = c.name end
  end
  return { columns = cols, by_name = by_name, pk = pk, kind = kind,
    editable = EDITABLE_KINDS[kind] == true and #pk > 0 }
end

-- Bağlantı + tablo meta'si ile calis; fn(pg, meta) → sonuc | nil, hata. Havuz her durumda birakilir.
local function with_table(identity, connection_id, database, schema, table_name, fn)
  local conn_row, err = get_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = pool_manager.acquire_for(conn_row, database)
  if not pg then return nil, cid end
  local meta, merr = describe(pg, schema, table_name)
  if not meta then
    pool_manager.release(cid, pg, false)
    return nil, map_target(merr)
  end
  local ok, res, ferr = pcall(fn, pg, meta)
  pool_manager.release(cid, pg, not ok)
  if not ok then error(res) end
  if res == nil then return nil, map_target(ferr) end
  return res
end

local function require_editable(meta)
  if meta.editable then return true end
  if not EDITABLE_KINDS[meta.kind] then
    return nil, errors.new("VALIDATION_FAILED", "View/matview satırlari duzenlenemez")
  end
  return nil, errors.new("VALIDATION_FAILED", "Birincil anahtari olmayan tabloda satır duzenlenemez")
end

-- filtreler: kolon var mi, operator kolon tipine uygun mu (pg_shared.types.FILTER_OPS_BY_GROUP)
local function validate_filters(filters, meta)
  if filters == nil or filters == "" then return {} end
  if type(filters) == "string" then
    local dec = cjson.decode(filters)
    if type(dec) ~= "table" then return nil, "filters JSON dizi olmali" end
    filters = dec
  end
  for i, f in ipairs(filters) do
    local col = meta.by_name[f.column or f.field or ""]
    local op = f.operator or f.op
    if not col then return nil, "[" .. i .. "] bilinmeyen kolon" end
    if not table_browser_model.is_allowed_operator(op, col.type_group) then
      return nil, "operator " .. tostring(op) .. " kolon " .. col.name .. " icin izinli degil"
    end
    if op ~= "IS NULL" and op ~= "IS NOT NULL" and (f.value == nil or f.value == cjson.null) then
      return nil, "[" .. i .. "] deger zorunlu"
    end
  end
  return filters
end
_M._validate_filters = validate_filters
_M.describe = describe

function _M.list(identity, connection_id, schema, table_name, query)
  query = query or {}
  return with_table(identity, connection_id, query.database, schema, table_name, function(pg, meta)
    local filters, ferr = validate_filters(query.filters, meta)
    if not filters then return nil, errors.new("VALIDATION_FAILED", ferr, { filters = { ferr } }) end
    if query.custom_where and query.custom_where ~= "" then
      local ok, verr = sql_parser.validate_expression(query.custom_where, meta.by_name)
      if not ok then return nil, errors.new("BAD_REQUEST", "custom_where: " .. verr) end
    end
    local page, qerr = target_browser.fetch_rows(pg, schema, table_name, meta.columns, {
      page = query.page, per_page = query.per_page, sort = query.sort,
      filters = filters, custom_where = query.custom_where,
      pk_columns = meta.pk, is_table = EDITABLE_KINDS[meta.kind],
    })
    if not page then return nil, qerr end
    if meta.editable then
      for _, r in ipairs(page.rows) do r._rid = target_browser.encode_rid(r, meta.pk) end
    end
    page.columns, page.kind, page.editable = meta.columns, meta.kind, meta.editable
    return page
  end)
end

-- values: kolon → deger | cjson.null. Salt okunur kolon ve bilinmeyen kolon reddedilir.
local function check_values(values, meta, for_insert)
  for k in pairs(values) do
    local c = meta.by_name[k]
    if not c then return nil, errors.new("VALIDATION_FAILED", "bilinmeyen kolon: " .. k, { [k] = { "bilinmeyen kolon" } }) end
    local blocked = for_insert and (c.is_generated or c.identity_kind == "ALWAYS" or c.type_group == "binary")
      or (not for_insert and c.read_only)
    if blocked then return nil, errors.new("VALIDATION_FAILED", k .. " kolonu duzenlenemez", { [k] = { "duzenlenemez" } }) end
  end
  return true
end

function _M.insert(identity, connection_id, schema, table_name, values, database)
  return with_table(identity, connection_id, database, schema, table_name, function(pg, meta)
    local ok, err = require_editable(meta)
    if not ok then return nil, err end
    ok, err = check_values(values, meta, true)
    if not ok then return nil, err end
    for _, c in ipairs(meta.columns) do
      if table_browser_model.is_required_for_insert(c) and values[c.name] == nil then
        return nil, errors.new("VALIDATION_FAILED", c.name .. " zorunlu", { [c.name] = { "zorunlu alan" } })
      end
    end
    local res, qerr = target_browser.insert_row(pg, schema, table_name, values)
    if not res then return nil, qerr end
    local row = res[1] or {}
    row._rid = target_browser.encode_rid(row, meta.pk)
    audit_service.record("table.row.create", { entity_type = "table_row", entity_id = table_name,
      new_value = { schema = schema, table = table_name, row = row } })
    return row
  end)
end

function _M.update(identity, connection_id, schema, table_name, rid, values, database)
  return with_table(identity, connection_id, database, schema, table_name, function(pg, meta)
    local ok, err = require_editable(meta)
    if not ok then return nil, err end
    if not next(values) then return nil, errors.new("VALIDATION_FAILED", "güncellenecek alan yok") end
    ok, err = check_values(values, meta, false)
    if not ok then return nil, err end
    local where, rerr = target_browser.decode_rid(rid, meta.pk)
    if not where then return nil, errors.new("BAD_REQUEST", rerr) end
    local res, qerr = target_browser.update_rows(pg, schema, table_name, where, values)
    if not res then return nil, qerr end
    if not res[1] then return nil, errors.new("ROW_NOT_FOUND", "Satır bulunamadı") end
    local row = res[1]
    row._rid = target_browser.encode_rid(row, meta.pk)
    audit_service.record("table.row.update", { entity_type = "table_row", entity_id = rid,
      old_value = { schema = schema, table = table_name, rid = rid }, new_value = row })
    return row
  end)
end

function _M.delete(identity, connection_id, schema, table_name, ids, database)
  if not ids or #ids == 0 then return nil, errors.new("VALIDATION_FAILED", "ids zorunlu") end
  return with_table(identity, connection_id, database, schema, table_name, function(pg, meta)
    local ok, err = require_editable(meta)
    if not ok then return nil, err end
    local where, params = target_browser.build_delete_where(ids, meta.pk)
    if not where then return nil, errors.new("BAD_REQUEST", params) end
    local res, qerr = target_browser.delete_rows(pg, schema, table_name, where, params)
    if not res then return nil, qerr end
    local affected = res.affected_rows or 0
    audit_service.record("table.row.delete", { entity_type = "table_row", entity_id = table_name,
      old_value = { schema = schema, table = table_name, ids = ids, affected = affected } })
    return { deleted = affected }
  end)
end

-- Sunucu tarafi kopya (API uyumlulugu; arayuz codd gibi on-dolu ekleme formu kullanir):
-- PK, identity ve generated kolonlar kopyalanmaz → varsayilanlarini alir
function _M.duplicate(identity, connection_id, schema, table_name, rid, database)
  return with_table(identity, connection_id, database, schema, table_name, function(pg, meta)
    local ok, err = require_editable(meta)
    if not ok then return nil, err end
    local where, rerr = target_browser.decode_rid(rid, meta.pk)
    if not where then return nil, errors.new("BAD_REQUEST", rerr) end
    local src, serr = target_browser.fetch_one_by_rid(pg, schema, table_name, where)
    if serr then return nil, serr end
    if not src then return nil, errors.new("ROW_NOT_FOUND", "Satır bulunamadı") end
    local vals = {}
    for _, c in ipairs(meta.columns) do
      if not (c.is_primary_key or c.is_identity or c.is_generated) and src[c.name] ~= nil then
        vals[c.name] = src[c.name]
      end
    end
    local res, qerr = target_browser.insert_row(pg, schema, table_name, vals)
    if not res then return nil, qerr end
    local row = res[1] or {}
    row._rid = target_browser.encode_rid(row, meta.pk)
    audit_service.record("table.row.duplicate", { entity_type = "table_row", entity_id = rid, old_value = src, new_value = row })
    return row
  end)
end

return _M
