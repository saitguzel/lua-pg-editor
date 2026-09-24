-- Yapi ogesi eylemleri (codd structure_actions): kolon / index / constraint / trigger yeniden adlandir ve sil.
-- Silme bagimlilik hatasi (2BP01) verirse istemci CASCADE ile tekrar dener. Constraint'e bagli index'ler
-- index olarak yonetilmez (constraint uzerinden). Izin: object.actions.
local connection_repo = require("repositories.connection_repo")
local pool_manager = require("db.pool_manager")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")

local _M = {}

_M.KINDS = { column = true, index = true, constraint = true, trigger = true }

local function q(ident) return '"' .. ident:gsub('"', '""') .. '"' end

-- kind → { rename = fn(tbl, schema, item, new), drop = fn(tbl, schema, item) } ; tbl = "sema"."tablo"
local SQL = {
  column = {
    rename = function(tbl, _, item, new) return "ALTER TABLE " .. tbl .. " RENAME COLUMN " .. q(item) .. " TO " .. q(new) end,
    drop = function(tbl, _, item) return "ALTER TABLE " .. tbl .. " DROP COLUMN " .. q(item) end,
  },
  index = {
    rename = function(_, schema, item, new) return "ALTER INDEX " .. q(schema) .. "." .. q(item) .. " RENAME TO " .. q(new) end,
    drop = function(_, schema, item) return "DROP INDEX " .. q(schema) .. "." .. q(item) end,
  },
  constraint = {
    rename = function(tbl, _, item, new) return "ALTER TABLE " .. tbl .. " RENAME CONSTRAINT " .. q(item) .. " TO " .. q(new) end,
    drop = function(tbl, _, item) return "ALTER TABLE " .. tbl .. " DROP CONSTRAINT " .. q(item) end,
  },
  trigger = {
    rename = function(tbl, _, item, new) return "ALTER TRIGGER " .. q(item) .. " ON " .. tbl .. " RENAME TO " .. q(new) end,
    drop = function(tbl, _, item) return "DROP TRIGGER " .. q(item) .. " ON " .. tbl end,
  },
}
_M.SQL = SQL

local function map_err(err)
  local code = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  if code == "2BP01" then return errors.new("CONFLICT", "Bagimli obje var, CASCADE gerekli", { sqlstate = code, db_message = msg }) end
  if code == "42P01" or code == "42703" or code == "42704" then
    return errors.new("OBJECT_NOT_FOUND", "Oge bulunamadi", { sqlstate = code, db_message = msg })
  end
  if code == "42P07" or code == "42710" or code == "42701" then
    return errors.new("CONFLICT", "Ayni isimde oge zaten var", { sqlstate = code, db_message = msg })
  end
  return errors.new("QUERY_FAILED", "Islem basarisiz", { sqlstate = code, db_message = msg })
end

-- p: { schema, table, kind, item, new_name?, cascade?, database? }
local function run(identity, connection_id, p, action)
  local conn_row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not conn_row or conn_row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Baglanti bulunamadi")
  end
  local pg, cid = pool_manager.acquire_for(conn_row, p.database)
  if not pg then return nil, cid end
  local tbl = q(p.schema) .. "." .. q(p.table)
  local sql = SQL[p.kind][action](tbl, p.schema, p.item, p.new_name)
  if action == "drop" and p.cascade then sql = sql .. " CASCADE" end
  local res, qerr = pg:query(sql)
  pool_manager.release(cid, pg, false)
  if not res then return nil, map_err(qerr) end
  require("services.schema_service").invalidate_completion(connection_id, p.database or conn_row.database)
  audit_service.record("structure." .. action, { entity_type = p.kind,
    entity_id = p.schema .. "." .. p.table .. "." .. p.item,
    new_value = { kind = p.kind, item = p.item, new_name = p.new_name, cascade = p.cascade == true } })
  return { ok = true, kind = p.kind, item = p.item, new_name = p.new_name }
end

function _M.rename(identity, connection_id, p) return run(identity, connection_id, p, "rename") end
function _M.drop(identity, connection_id, p) return run(identity, connection_id, p, "drop") end

return _M
