-- DatabaseObject modeli: sema tarayici tablo/view temsili
local cjson = require("cjson.safe")

local _M = {}

function _M.from_row(row)
  if not row then return nil end
  local kind = row.kind or row.table_type or row.relkind
  if kind == "BASE TABLE" or kind == "r" or kind == "p" then kind = "table"
  elseif kind == "VIEW" or kind == "v" then kind = "view"
  elseif kind == "m" then kind = "view"
  else kind = kind or "table" end
  return {
    schema = row.schema or row.table_schema or row.schemaname,
    name = row.name or row.table_name or row.relname,
    kind = kind,
  }
end

function _M.serialize(row)
  local o = _M.from_row(row)
  if not o then return nil end
  return { schema = o.schema, name = o.name, kind = o.kind }
end

function _M.serialize_list(rows)
  if not rows then return {} end
  local out = {}
  for i, r in ipairs(rows) do out[i] = _M.serialize(r) end
  return out
end

return _M
