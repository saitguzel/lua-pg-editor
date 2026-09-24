-- DatabaseObject modeli: sema tarayici nesne temsili { schema, name, kind, extra? }
-- kind: pg_shared.types.OBJECT_KINDS (F25 ile sequence/type_*/domain/extension/... eklendi); information_schema
-- degerleri ve ham relkind harfleri de kabul edilir.
local _M = {}

local KIND_ALIAS = { ["BASE TABLE"] = "table", VIEW = "view", r = "table", p = "partitioned", v = "view", m = "matview",
  f = "foreign", S = "sequence" }

function _M.from_row(row)
  if not row then return nil end
  local kind = row.kind or row.table_type or row.relkind
  kind = KIND_ALIAS[kind] or kind or "table"
  local extra = row.extra
  if extra == "" or extra == require("cjson.safe").null then extra = nil end
  -- rutin satirlari (oid kolonu var): extra yapisal { oid, args, returns, language }
  if row.oid ~= nil and row.oid ~= require("cjson.safe").null then
    extra = { oid = row.oid, args = row.args, returns = row.returns, language = row.language }
  end
  return {
    schema = row.schema or row.table_schema or row.schemaname,
    name = row.name or row.table_name or row.relname,
    kind = kind,
    extra = extra,
  }
end

function _M.serialize(row)
  local o = _M.from_row(row)
  if not o then return nil end
  return { schema = o.schema, name = o.name, kind = o.kind, extra = o.extra }
end

function _M.serialize_list(rows)
  if not rows then return {} end
  local out = {}
  for i, r in ipairs(rows) do out[i] = _M.serialize(r) end
  return out
end

return _M
