-- TableBrowser modelleri: sayfa, kolon, filtre DTO'lari
local cjson = require("cjson.safe")

local _M = {}

local FILTER_OPS = {
  ["="] = true, ["!="] = true, [">"] = true, [">="] = true, ["<"] = true, ["<="] = true,
  ["LIKE"] = true, ["ILIKE"] = true, ["IS NULL"] = true, ["IS NOT NULL"] = true,
}

_M.FILTER_OPS = FILTER_OPS

-- type_group -> izinli operatorler: tek kaynak pg_shared.types (frontend filtre cubugu da kullanir)
local OP_BY_GROUP = {}
for group, list in pairs(require("pg_shared.types").FILTER_OPS_BY_GROUP) do
  local set = {}
  for _, op in ipairs(list) do set[op] = true end
  OP_BY_GROUP[group] = set
end

function _M.allowed_operators_for_type(type_group)
  return OP_BY_GROUP[type_group or "other"] or OP_BY_GROUP.other
end

function _M.is_allowed_operator(op, type_group)
  local allowed = _M.allowed_operators_for_type(type_group)
  return allowed[op] == true
end

-- Satıri hucre DTO'ya cevir: null -> { value="NULL", is_null=true }
local function cell_value(v)
  if v == nil or v == cjson.null or v == ngx.null then
    return { value = "NULL", is_null = true }
  end
  return { value = v, is_null = false }
end

function _M.serialize_page(page)
  if not page then return nil end
  return {
    rows = page.rows or {},
    page = page.page or 1,
    per_page = page.per_page or 100,
    total = page.total or 0,
    has_next = page.has_next or false,
    columns = page.columns,
  }
end

function _M.serialize_rows(rows, columns)
  if not rows then return {} end
  local out = {}
  for i, r in ipairs(rows) do
    if type(r) == "table" then
      local nr = {}
      -- kolon sirasi korunur
      if columns then
        for _, col in ipairs(columns) do
          local key = col.name or col.column_name or col
          nr[key] = cell_value(r[key])
        end
        -- rid icin ham degerleri de ekle (duplicate/delete icin)
        nr._raw = r
      else
        for k, v in pairs(r) do nr[k] = cell_value(v) end
        nr._raw = r
      end
      out[i] = nr
    else
      out[i] = r
    end
  end
  return out
end

-- Kolon tipi yardimcilari (F9 is_insertable/is_required mantigi)
function _M.is_insertable(col)
  if not col then return false end
  if col.is_identity or col.is_generated then return false end
  if col.type_group == "binary" then return false end
  return true
end

function _M.is_required_for_insert(col)
  if not col then return false end
  if col.is_nullable == true or col.is_nullable == "YES" then return false end
  if col.has_default then return false end
  if col.is_identity or col.is_generated then return false end
  return true
end

return _M
