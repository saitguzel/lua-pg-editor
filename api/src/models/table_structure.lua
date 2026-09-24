-- TableStructure DTO: 6 bolumlu yapi incelemesi
local cjson = require("cjson.safe")

local _M = {}

local types = require("pg_shared.types")
local function present(v) return v ~= nil and v ~= cjson.null and v ~= "" end
local function truthy(v) return v == true or v == "YES" or v == "t" end

-- repo satiri (target_schema_repo.list_columns) → kolon DTO'su
local function normalize_column(row)
  local udt = row.udt_name or row.type_name or row.data_type
  local enum_values = type(row.enum_values) == "table" and row.enum_values or nil
  return {
    name = row.column_name or row.name,
    display_type = row.data_type or udt or "unknown",
    type_name = udt or "unknown",
    type_group = types.type_group(udt, row.data_type, truthy(row.is_enum)),
    is_array = truthy(row.is_array),
    is_nullable = row.is_nullable == "YES" or row.is_nullable == true,
    is_primary_key = truthy(row.is_primary_key) or truthy(row.is_primary),
    has_default = present(row.column_default),
    column_default = present(row.column_default) and row.column_default or nil,
    is_identity = truthy(row.is_identity),
    identity_kind = present(row.identity_kind) and row.identity_kind or nil,
    is_generated = truthy(row.is_generated) or row.is_generated == "ALWAYS",
    generation_expression = present(row.generation_expression) and row.generation_expression or nil,
    collation = present(row.collation) and row.collation or nil,
    ordinal_position = tonumber(row.ordinal_position) or 0,
    enum_values = enum_values,
  }
end

local CONSTRAINT_TYPE = { p = "Primary key", f = "Foreign key", u = "Unique", c = "Check", x = "Exclusion", t = "Trigger" }
local FK_ACTION = { a = "No action", r = "Restrict", c = "Cascade", n = "Set null", d = "Set default" }
local TRIGGER_STATE = { O = "Enabled", D = "Disabled", A = "Always", R = "Replica" }

local function normalize_index(row)
  return {
    name = row.name, def = row.def,
    is_primary = truthy(row.is_primary), is_unique = truthy(row.is_unique),
    is_valid = row.is_valid ~= false, is_partial = truthy(row.is_partial),
    constraint_name = present(row.constraint_name) and row.constraint_name or nil,
  }
end

local function normalize_constraint(row)
  return {
    name = row.name, contype = row.contype, type = CONSTRAINT_TYPE[row.contype] or row.contype, def = row.def,
    validated = row.validated ~= false, deferrable = truthy(row.deferrable), deferred = truthy(row.deferred),
  }
end

local function normalize_fk(row)
  return {
    name = row.name, columns = row.columns or {}, ref_schema = row.ref_schema, ref_table = row.ref_table,
    ref_columns = row.ref_columns or {}, on_update = FK_ACTION[row.on_update] or row.on_update,
    on_delete = FK_ACTION[row.on_delete] or row.on_delete, deferrable = truthy(row.deferrable),
  }
end

local function normalize_trigger(row)
  return { name = row.name, def = row.def, ["function"] = row["function"],
    state = TRIGGER_STATE[row.enabled] or row.enabled }
end

-- F25: RuleInfo { name, event, is_instead, def }
-- PolicyInfo { name, command, permissive, roles, using_expr, check_expr }
local function normalize_rule(row)
  return { name = row.name, event = row.event, is_instead = truthy(row.is_instead), def = row.def }
end

local function normalize_policy(row)
  return { name = row.name, command = row.command, permissive = row.permissive ~= false,
    roles = type(row.roles) == "table" and row.roles or {},
    using_expr = present(row.using_expr) and row.using_expr or nil,
    check_expr = present(row.check_expr) and row.check_expr or nil }
end

-- cjson.null alanlari nil'e cevir (detail satiri dogrudan repo'dan gelir)
local function strip_null(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do if v ~= cjson.null then out[k] = v end end
  return out
end

function _M.from_parts(object, parts)
  return {
    object = object,
    columns = parts.columns or {},
    indexes = parts.indexes or {},
    constraints = parts.constraints or {},
    foreign_keys = parts.foreign_keys or {},
    triggers = parts.triggers or {},
    rules = parts.rules or {},
    policies = parts.policies or {},
    detail = parts.detail,
    size_bytes = parts.size_bytes,
    table_bytes = parts.table_bytes,
    index_bytes = parts.index_bytes,
    stats = parts.stats,
    kind = parts.kind,
  }
end

function _M.serialize(struct)
  if not struct then return nil end
  local cols = {}
  for i, c in ipairs(struct.columns or {}) do cols[i] = normalize_column(c) end
  local idxs = {}
  for i, v in ipairs(struct.indexes or {}) do idxs[i] = normalize_index(v) end
  local cons = {}
  for i, v in ipairs(struct.constraints or {}) do cons[i] = normalize_constraint(v) end
  local fks = {}
  for i, v in ipairs(struct.foreign_keys or {}) do fks[i] = normalize_fk(v) end
  local trigs = {}
  for i, v in ipairs(struct.triggers or {}) do trigs[i] = normalize_trigger(v) end
  local rules = {}
  for i, v in ipairs(struct.rules or {}) do rules[i] = normalize_rule(v) end
  local policies = {}
  for i, v in ipairs(struct.policies or {}) do policies[i] = normalize_policy(v) end
  return {
    object = struct.object,
    columns = cols,
    indexes = idxs,
    constraints = cons,
    foreign_keys = fks,
    triggers = trigs,
    rules = rules,
    policies = policies,
    detail = struct.detail and strip_null(struct.detail) or nil,
    size_bytes = tonumber(struct.size_bytes),
    table_bytes = tonumber(struct.table_bytes),
    index_bytes = tonumber(struct.index_bytes),
    stats = struct.stats,
    kind = struct.kind,
  }
end

_M._normalize_column = normalize_column

return _M
