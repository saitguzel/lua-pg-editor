-- Obje eylemleri servis: rename / truncate / drop, audit, cache invalidate
local connection_repo = require("repositories.connection_repo")
local pool_manager = require("db.pool_manager")
local target_actions = require("db.target.object_actions")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")

local _M = {}

local function get_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı") end
  return row
end

local acquire = pool_manager.acquire_for

local function map_err(err)
  local code = type(err)=="table" and err.code or nil
  local msg = type(err)=="table" and (err.message or tostring(err)) or tostring(err)
  if code=="42P07" then return errors.new("CONFLICT", "Ayni isimde obje zaten var", { sqlstate=code }) end
  if code=="42P01" or code=="42883" then return errors.new("OBJECT_NOT_FOUND", "Obje bulunamadı", { sqlstate=code }) end
  if code=="42723" or code=="42710" then return errors.new("CONFLICT", "Ayni isimde obje zaten var", { sqlstate=code }) end
  if code=="42501" then return errors.new("FORBIDDEN", "Yetki yok", { sqlstate=code }) end
  if code=="2BP01" then return errors.new("CONFLICT", "Bagimli obje var, CASCADE gerekli", { sqlstate=code }) end
  if type(err)=="table" and err.__app_error then return err end
  if code then return errors.new("QUERY_FAILED", "Islem basarisiz", { sqlstate=code, db_message=msg }) end
  return errors.new("QUERY_FAILED", "Islem basarisiz", { db_message=msg })
end

local function invalidate(connection_id, database)
  local svc = require("services.schema_service")
  svc.invalidate_completion(connection_id, database)
end

-- Bağlantı al, nesne turunu ogren, fn(pg, kind) çalıştır; havuz her durumda birakilir
local function with_object(identity, connection_id, database, schema, name, fn)
  local conn_row, err = get_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local kind = target_actions.get_kind(pg, schema, name)
  local res, qerr
  if not kind then
    qerr = { code = "42P01" }
  else
    res, qerr = fn(pg, kind)
  end
  pool_manager.release(cid, pg, false)
  if not res then return nil, map_err(qerr) end
  invalidate(connection_id, database or conn_row.database)
  return res, kind
end

function _M.rename(identity, connection_id, schema, name, new_name, database)
  local res, kind = with_object(identity, connection_id, database, schema, name, function(pg, k)
    return target_actions.rename(pg, schema, name, new_name, k)
  end)
  if not res then return nil, kind end
  audit_service.record("object.rename", { entity_type = kind, entity_id = schema .. "." .. name,
    old_value = { old_name = name }, new_value = { new_name = new_name } })
  return { old_name = name, new_name = new_name, schema = schema, kind = kind }
end

-- opts: { cascade, restart_identity }
function _M.truncate(identity, connection_id, schema, name, opts, database)
  opts = type(opts) == "table" and opts or { cascade = opts == true }
  local res, kind = with_object(identity, connection_id, database, schema, name, function(pg, k)
    if k ~= "table" and k ~= "partitioned" then
      return nil, errors.new("VALIDATION_FAILED", "Yalnizca tablolar bosaltilabilir")
    end
    return target_actions.truncate(pg, schema, name, opts)
  end)
  if not res then return nil, kind end
  audit_service.record("object.truncate", { entity_type = kind, entity_id = schema .. "." .. name,
    new_value = { schema = schema, table = name, cascade = opts.cascade == true, restart_identity = opts.restart_identity == true } })
  return { truncated = true, schema = schema, table = name }
end

function _M.drop(identity, connection_id, schema, name, cascade, database)
  local res, kind = with_object(identity, connection_id, database, schema, name, function(pg, k)
    return target_actions.drop(pg, schema, name, k, cascade)
  end)
  if not res then return nil, kind end
  audit_service.record("object.drop", { entity_type = kind, entity_id = schema .. "." .. name,
    old_value = { schema = schema, table = name, kind = kind, cascade = cascade == true } })
  return { dropped = true, schema = schema, table = name, kind = kind }
end

-- --- fonksiyon / prosedür / trigger (oid ile) ---------------------------------------
local routines = require("db.target.routines")

local function with_routine(identity, connection_id, database, fn)
  local conn_row, err = get_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local ok, res, qerr = pcall(fn, pg)
  pool_manager.release(cid, pg, not ok)
  if not ok then error(res) end
  if not res then return nil, map_err(qerr) end
  return res, conn_row
end

-- script_kind: ddl | execute | drop (salt okunur; audit script.generate)
function _M.routine_script(identity, connection_id, kind, oid, script_kind, database)
  local sql, err = with_routine(identity, connection_id, database, function(pg)
    return routines.script(pg, kind, oid, script_kind)
  end)
  if not sql then return nil, err end
  audit_service.record("script.generate", { entity_type = kind, entity_id = tostring(oid),
    new_value = { kind = script_kind } })
  return sql
end

function _M.routine_drop(identity, connection_id, kind, oid, cascade, database)
  local r, conn_row = with_routine(identity, connection_id, database, function(pg)
    return routines.drop(pg, kind, oid, cascade)
  end)
  if not r then return nil, conn_row end
  invalidate(connection_id, database or conn_row.database)
  audit_service.record("object.drop", { entity_type = kind, entity_id = r.schema .. "." .. r.name,
    old_value = { schema = r.schema, name = r.name, args = r.args, table = r.table_name, cascade = cascade == true } })
  return { dropped = true, kind = kind, schema = r.schema, name = r.name }
end

function _M.routine_rename(identity, connection_id, kind, oid, new_name, database)
  local r, conn_row = with_routine(identity, connection_id, database, function(pg)
    return routines.rename(pg, kind, oid, new_name)
  end)
  if not r then return nil, conn_row end
  invalidate(connection_id, database or conn_row.database)
  audit_service.record("object.rename", { entity_type = kind, entity_id = r.schema .. "." .. r.name,
    old_value = { old_name = r.name }, new_value = { new_name = new_name } })
  return { old_name = r.name, new_name = new_name, schema = r.schema, kind = kind }
end

function _M.trigger_set_enabled(identity, connection_id, oid, enabled, database)
  local r, conn_row = with_routine(identity, connection_id, database, function(pg)
    return routines.set_trigger_enabled(pg, oid, enabled)
  end)
  if not r then return nil, conn_row end
  invalidate(connection_id, database or conn_row.database)
  audit_service.record("object.trigger.toggle", { entity_type = "trigger", entity_id = r.schema .. "." .. r.name,
    new_value = { table = r.table_name, enabled = enabled } })
  return { name = r.name, table = r.table_name, enabled = enabled }
end

return _M
