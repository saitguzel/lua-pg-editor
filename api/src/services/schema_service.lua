-- Şema/yapı servis: sahiplik, pool_manager, completion cache, 6 paralel sorgu
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
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  return row
end

local acquire_target = pool_manager.acquire_for

local function map_target_err(err)
  if not err then return nil end
  local sqlstate = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  if sqlstate == "42P01" or sqlstate == "42P02" or sqlstate == "42703" then
    return errors.new("OBJECT_NOT_FOUND", "Tablo veya view bulunamadı", { sqlstate = sqlstate, db_message = msg })
  elseif sqlstate == "3D000" then
    return errors.new("DATABASE_NOT_FOUND", "Veritabani bulunamadı", { sqlstate = sqlstate })
  elseif sqlstate and sqlstate:sub(1,2)=="42" then
    return errors.new("QUERY_FAILED", "Sorgu çalıştırilamadi", { sqlstate = sqlstate, db_message = msg })
  end
  if type(err) == "table" and err.__app_error then return err end
  return errors.new("QUERY_FAILED", "Sorgu çalıştırilamadi", { db_message = msg })
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

local function categories_key(conn_id, database, schema)
  return "categories:" .. conn_id .. ":" .. (database or "default") .. ":" .. schema
end

local function cache_ttl()
  local cfg = config.get()
  return cfg and cfg.completion and cfg.completion.cache_ttl or 300
end

-- F25: şema basina kategori sayaclari ([{category,count}] x16), completion_cache'te TTL'li
function _M.list_categories(identity, connection_id, schema, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local key = categories_key(connection_id, database or conn_row.database, schema)
  local dict = ngx.shared.completion_cache
  local cached = dict and dict:get(key)
  if cached then
    local ok, decoded = pcall(cjson.decode, cached)
    if ok and decoded then return decoded end
  end
  local pg, cid = acquire_target(conn_row, database)
  if not pg then return nil, cid end
  local counts, qerr = target_repo.count_categories(pg, schema)
  pool_manager.release(cid, pg, counts == nil)
  if not counts then return nil, map_target_err(qerr) end
  if dict then dict:set(key, cjson.encode(counts), cache_ttl()) end
  return counts
end

-- opts (F25, opsiyonel): { category, q, limit, offset } → liste, meta. category yoksa F7 davranisi (meta nil)
function _M.list_objects(identity, connection_id, schema, database, opts)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, conn_id = acquire_target(conn_row, database)
  if not pg then return nil, conn_id end
  local model = require("models.database_object")
  local out = {}
  if not (opts and opts.category) then
    local objs, qerr = target_repo.list_objects(pg, schema)
    pool_manager.release(conn_id, pg, objs == nil)
    if not objs then return nil, map_target_err(qerr) end
    for i, r in ipairs(objs) do out[i] = model.serialize(r) end
    return out
  end
  local limit, offset = opts.limit or 200, opts.offset or 0
  local objs, qerr = target_repo.list_category(pg, opts.category, schema, opts.q, limit + 1, offset)
  pool_manager.release(conn_id, pg, objs == nil)
  if not objs then return nil, map_target_err(qerr) end
  local has_more = #objs > limit
  for i = 1, math.min(#objs, limit) do out[i] = model.serialize(objs[i]) end
  -- toplam: q yoksa sayac cache'inden, q varsa dondurulen sayfa (arama sonuclari sayilmaz)
  local total = #out + offset + (has_more and 1 or 0)
  if not opts.q then
    local counts = _M.list_categories(identity, connection_id, schema, database)
    for _, c in ipairs(counts or {}) do if c.category == opts.category then total = c.count end end
  end
  return out, { total = total, limit = limit, offset = offset, has_more = has_more }
end

-- Yapı: tek bağlantıda sirali katalog sorgulari (hepsi ms mertebesinde); nesne yoksa kolon sorgusu 42P01 doner
function _M.get_structure(identity, connection_id, schema, name, database)
  local conn_row, err = get_connection_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = acquire_target(conn_row, database)
  if not pg then return nil, cid end
  local parts, qerr = {}, nil
  local ok, perr = pcall(function()
    parts.kind = target_repo.object_kind(pg, schema, name)
    if not parts.kind then
      -- F25: iliski degil → sequence/type/domain/extension/... detayi
      parts.kind = target_repo.other_object_kind(pg, schema, name)
      if not parts.kind then qerr = { code = "42P01", message = "object does not exist" } return end
      parts.detail, qerr = target_repo.object_detail(pg, parts.kind, schema, name)
      return
    end
    parts.columns, qerr = target_repo.list_columns(pg, schema, name)
    if not parts.columns then return end
    for key, fn in pairs({ indexes = "list_indexes", constraints = "list_constraints",
                           foreign_keys = "list_foreign_keys", triggers = "list_triggers",
                           rules = "list_rules", policies = "list_policies" }) do
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

-- completion + kategori sayaclarini (categories:<conn>:<db>:*) siler. database yoksa "default" anahtari
-- silinir; diger db'ler TTL ile duser. ponytail: get_keys(0) tum dict'i tarar; anahtar sayisi kucuk (şema basina 1)
function _M.invalidate_completion(connection_id, database)
  local dict = ngx.shared.completion_cache
  if not dict then return end
  dict:delete(completion_key(connection_id, database))
  local prefix = categories_key(connection_id, database, "")
  for _, key in ipairs(dict:get_keys(0) or {}) do
    if key:sub(1, #prefix) == prefix then dict:delete(key) end
  end
end

return _M
