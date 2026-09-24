-- Obje eylemleri (hedef DB): rename / truncate / drop — nesne turune gore dogru SQL (codd)
local schema_repo = require("repositories.target_schema_repo")

local _M = {}

local function quote_ident(ident)
  return '"' .. ident:gsub('"', '""') .. '"'
end

-- tur → ALTER/DROP anahtar kelimesi
local SQL_TYPE = { table = "TABLE", partitioned = "TABLE", view = "VIEW", matview = "MATERIALIZED VIEW",
  foreign = "FOREIGN TABLE" }

-- nesne turu: table | partitioned | view | matview | foreign | nil (yok)
function _M.get_kind(pg, schema, name)
  return schema_repo.object_kind(pg, schema, name)
end

local function not_found() return nil, { code = "42P01", message = "relation does not exist" } end

function _M.rename(pg, schema, name, new_name, kind)
  if not SQL_TYPE[kind] then return not_found() end
  return pg:query("ALTER " .. SQL_TYPE[kind] .. " " .. quote_ident(schema) .. "." .. quote_ident(name)
    .. " RENAME TO " .. quote_ident(new_name))
end

-- opts: { cascade, restart_identity } — yalnizca tablolar
function _M.truncate(pg, schema, name, opts)
  opts = opts or {}
  return pg:query("TRUNCATE TABLE " .. quote_ident(schema) .. "." .. quote_ident(name)
    .. (opts.restart_identity and " RESTART IDENTITY" or "") .. (opts.cascade and " CASCADE" or ""))
end

function _M.drop(pg, schema, name, kind, cascade)
  if not SQL_TYPE[kind] then return not_found() end
  return pg:query("DROP " .. SQL_TYPE[kind] .. " " .. quote_ident(schema) .. "." .. quote_ident(name)
    .. (cascade and " CASCADE" or ""))
end

_M.SQL_TYPE = SQL_TYPE

return _M
