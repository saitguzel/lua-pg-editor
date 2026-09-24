-- Script servis: DDL sablonlarini hedef DB meta'sindan uretir
local connection_repo = require("repositories.connection_repo")
local pool_manager = require("db.pool_manager")
local target_script = require("db.target.script")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")

local _M = {}

local function get_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then return nil, errors.new("CONNECTION_NOT_FOUND", "Baglanti bulunamadi") end
  return row
end

local acquire = pool_manager.acquire_for

local types = require("pg_shared.types")

-- kind: select | insert | update | delete | create | drop | truncate (pg_shared.types.SCRIPT_KINDS)
function _M.generate(identity, connection_id, schema, name, kind, database)
  if not types.SCRIPT_KIND_SET[kind] then
    return nil, errors.new("VALIDATION_FAILED", "gecersiz kind", { kind = { "gecersiz deger" } })
  end
  local conn_row, err = get_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local ok, sql, serr = pcall(function()
    local meta = require("services.table_browser_service").describe(pg, schema, name)
    if not meta then return nil, "bulunamadi" end
    if kind == "create" then return target_script.create_script(pg, schema, name, meta.kind, meta.columns) end
    if kind == "drop" then return target_script.drop_script(schema, name, meta.kind) end
    if kind == "truncate" then return target_script.truncate_script(schema, name) end
    return target_script[kind .. "_script"](schema, name, meta.columns)
  end)
  pool_manager.release(cid, pg, not ok)
  if not ok then error(sql) end
  if not sql then
    if serr == "bulunamadi" then return nil, errors.new("OBJECT_NOT_FOUND", "Obje bulunamadi") end
    return nil, errors.new("QUERY_FAILED", "Script olusturulamadi", { db_message = tostring(serr and serr.message or serr) })
  end
  audit_service.record("script.generate", { entity_type = "table", entity_id = schema .. "." .. name, new_value = { kind = kind } })
  return sql
end

return _M
