-- Sema/yapi servis: sahiplik, pool_manager, completion cache, 6 paralel sorgu
local cjson = require("cjson.safe")
local config = require("config")
local connection_repo = require("repositories.connection_repo")
local target_repo = require("repositories.target_schema_repo")
local pool_manager = require("db.pool_manager")
local errors = require("middleware.error_handler")

local _M = {}

local function completion_key(conn_id, database)
  return "completion:" .. conn_id .. ":" .. (database or "default")
end

local function get_connection_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Baglanti bulunamadi")
  end
  return row
end

local acquire_target = pool_manager.acquire_for

local function map_target_err(err)
  if not err then return nil end
  local sqlstate = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  if sqlstate == "42P01" or sqlstate == "42P02" or sqlstate == "42703" then
    return errors.new("OBJECT_NOT_FOUND", "Tablo veya view bulunamadi", { sqlstate = sqlstate, db_message = msg })
  elseif sqlstate == "3D000" then
    return errors.new("DATABASE_NOT_FOUND", "Veritabani bulunamadi", { sqlstate = sqlstate })
  elseif sqlstate and sqlstate:sub(1,2)=="42" then
    return errors.new("QUERY_FAILED", "Sorgu calistirilamadi", { sqlstate = sqlstate, db_message = msg })
  end
  if type(err) == "table" and err.__app_error then return err end
  return errors.new("QUERY_FAILED", "Sorgu calistirilamadi", { db_message = msg })
end

function _M.list_schemas(identity, connection_id, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  -- completion cache kontrol (sadece list_schemas icin degil, full katalog cache)
  -- Basit: dogrudan hedef DB'den cek
  local pg, conn_id = acquire_target(conn_row, database)
  if not pg then return nil, conn_id end
  local schemas, qerr = target_repo.list_schemas(pg)
  pool_manager.release(conn_id, pg, schemas == nil)
  if not schemas then return nil, map_target_err(qerr) end
  return schemas
end

function _M.list_objects(identity, connection_id, schema, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, conn_id = acquire_target(conn_row, database)
  if not pg then return nil, conn_id end
  local objs, qerr = target_repo.list_objects(pg, schema)
  pool_manager.release(conn_id, pg, objs == nil)
  if not objs then return nil, map_target_err(qerr) end
  local model = require("models.database_object")
  local out = {}
  for i, r in ipairs(objs) do out[i] = model.serialize(r) end
  return out
end

-- Yapi: tek baglantida sirali katalog sorgulari (hepsi ms mertebesinde); nesne yoksa kolon sorgusu 42P01 doner
function _M.get_structure(identity, connection_id, schema, name, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = acquire_target(conn_row, database)
  if not pg then return nil, cid end
  local parts, qerr = {}, nil
  local ok, perr = pcall(function()
    parts.columns, qerr = target_repo.list_columns(pg, schema, name)
    if not parts.columns then return end
    parts.kind = target_repo.object_kind(pg, schema, name)
    for key, fn in pairs({ indexes = "list_indexes", constraints = "list_constraints",
                           foreign_keys = "list_foreign_keys", triggers = "list_triggers" }) do
      parts[key], qerr = target_repo[fn](pg, schema, name)
      if not parts[key] then return end
    end
    local size = target_repo.get_size(pg, schema, name) or {}
    parts.size_bytes, parts.table_bytes, parts.index_bytes, parts.stats =
      size.size_bytes, size.table_bytes, size.index_bytes, size.stats
    qerr = nil
  end)
  pool_manager.release(cid, pg, not ok)
  if not ok then error(perr) end
  if qerr then return nil, map_target_err(qerr) end
  local model = require("models.table_structure")
  return model.serialize(model.from_parts({ schema = schema, name = name }, parts))
end

function _M.get_completion(identity, connection_id, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local key = completion_key(connection_id, database or conn_row.database)
  local dict = ngx.shared.completion_cache
  local cfg = config.get()
  local ttl = cfg and cfg.completion and cfg.completion.cache_ttl or 300
  if dict then
    local cached = dict:get(key)
    if cached then
      local ok, decoded = pcall(cjson.decode, cached)
      if ok and decoded then return decoded end
    end
  end
  local pg, cid = acquire_target(conn_row, database)
  if not pg then return nil, cid end
  local catalog, qerr = target_repo.completion_catalog(pg)
  pool_manager.release(cid, pg, catalog == nil)
  if not catalog then return nil, map_target_err(qerr) end
  if dict then
    local ok, set_err = dict:set(key, cjson.encode(catalog), ttl)
    if not ok then ngx.log(ngx.WARN, "completion_cache set basarisiz: ", tostring(set_err)) end
  end
  return catalog
end

function _M.invalidate_completion(connection_id, database)
  local dict = ngx.shared.completion_cache
  if not dict then return end
  if database then
    dict:delete(completion_key(connection_id, database))
  else
    -- tum db'ler icin prefix temizlik yok, en azindan default sil
    dict:delete(completion_key(connection_id, database))
    -- LRU dict'te keys yok, tek silme yeterli; diger db'ler zamanla expire
  end
end

return _M
