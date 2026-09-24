-- Script uretimi (codd table_scripts): CREATE / SELECT / INSERT / UPDATE / DELETE (+ DROP / TRUNCATE).
-- columns: models/table_structure normalize_column ciktisi (name, display_type, is_primary_key, is_identity,
-- identity_kind, is_generated, generation_expression, column_default, is_nullable, collation)
local _M = {}

local function q(ident)
  return '"' .. ident:gsub('"', '""') .. '"'
end

local function qname(schema, name) return q(schema) .. "." .. q(name) end

local function names(columns, keep)
  local out = {}
  for _, c in ipairs(columns) do if not keep or keep(c) then out[#out + 1] = q(c.name) end end
  return out
end

-- PK varsa "pk1 = $n AND ...", yoksa codd'daki gibi yer tutucu
local function where_pk(columns, start)
  local parts, n = {}, start
  for _, c in ipairs(columns) do
    if c.is_primary_key then
      n = n + 1
      parts[#parts + 1] = q(c.name) .. " = $" .. n
    end
  end
  return #parts > 0 and table.concat(parts, " AND ") or "<condition>"
end

function _M.select_script(schema, name, columns)
  return "SELECT " .. table.concat(names(columns), ",\n       ") .. "\nFROM " .. qname(schema, name) .. ";"
end

-- generated / identity ALWAYS kolonlarina deger yazilamaz
local function writable(c) return not c.is_generated and c.identity_kind ~= "ALWAYS" end

function _M.insert_script(schema, name, columns)
  local cols = names(columns, writable)
  local marks = {}
  for i = 1, #cols do marks[i] = "$" .. i end
  return "INSERT INTO " .. qname(schema, name) .. " (" .. table.concat(cols, ", ") .. ")\nVALUES ("
    .. table.concat(marks, ", ") .. ");"
end

function _M.update_script(schema, name, columns)
  local sets, n = {}, 0
  for _, c in ipairs(columns) do
    if writable(c) and not c.is_primary_key then
      n = n + 1
      sets[#sets + 1] = q(c.name) .. " = $" .. n
    end
  end
  return "UPDATE " .. qname(schema, name) .. "\nSET " .. table.concat(sets, ",\n    ") .. "\nWHERE "
    .. where_pk(columns, n) .. ";"
end

function _M.delete_script(schema, name, columns)
  return "DELETE FROM " .. qname(schema, name) .. "\nWHERE " .. where_pk(columns, 0) .. ";"
end

local SQL_TYPE = { table = "TABLE", partitioned = "TABLE", view = "VIEW", matview = "MATERIALIZED VIEW",
  foreign = "FOREIGN TABLE" }

function _M.drop_script(schema, name, kind)
  return "DROP " .. (SQL_TYPE[kind] or "TABLE") .. " " .. qname(schema, name) .. ";"
end

function _M.truncate_script(schema, name)
  return "TRUNCATE TABLE " .. qname(schema, name) .. ";"
end

-- identity sequence secenekleri (START/INCREMENT/MIN/MAX/CACHE/CYCLE)
local function identity_clause(pg, schema, name, c)
  local clause = "GENERATED " .. (c.identity_kind or "BY DEFAULT") .. " AS IDENTITY"
  local res = pg:query([[SELECT s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
    FROM pg_sequence s WHERE s.seqrelid = pg_get_serial_sequence($1, $2)::regclass]], qname(schema, name), c.name)
  local s = res and res[1]
  if not s then return clause end
  return clause .. " (START WITH " .. s.seqstart .. " INCREMENT BY " .. s.seqincrement .. " MINVALUE " .. s.seqmin
    .. " MAXVALUE " .. s.seqmax .. " CACHE " .. s.seqcache .. (s.seqcycle and " CYCLE" or "") .. ")"
end

local function column_def(pg, schema, name, c)
  local def = "    " .. q(c.name) .. " " .. c.display_type
  if c.collation then def = def .. " COLLATE " .. q(c.collation) end
  if c.is_generated then
    def = def .. " GENERATED ALWAYS AS (" .. tostring(c.generation_expression) .. ") STORED"
  elseif c.is_identity then
    def = def .. " " .. identity_clause(pg, schema, name, c)
  elseif c.column_default then
    def = def .. " DEFAULT " .. c.column_default
  end
  if not c.is_nullable then def = def .. " NOT NULL" end
  return def
end

-- CREATE: tablo (codd bicimi) ya da view/matview tanimi
function _M.create_script(pg, schema, name, kind, columns)
  local full = qname(schema, name)
  if kind == "view" or kind == "matview" then
    local res, err = pg:query("SELECT pg_get_viewdef($1::regclass, true) AS def", full)
    if not res then return nil, err end
    return "-- " .. _M.drop_script(schema, name, kind) .. "\nCREATE " .. SQL_TYPE[kind] .. " " .. full .. " AS\n"
      .. (res[1] and res[1].def or "SELECT ...;")
  end
  local lines = {}
  for _, c in ipairs(columns) do lines[#lines + 1] = column_def(pg, schema, name, c) end
  local cons = pg:query([[SELECT conname, pg_get_constraintdef(oid, true) AS def FROM pg_constraint
    WHERE conrelid = $1::regclass AND contype <> 'n' ORDER BY contype = 'p' DESC, conname]], full) or {}
  for _, con in ipairs(cons) do lines[#lines + 1] = "    CONSTRAINT " .. q(con.conname) .. " " .. con.def end
  local meta = (pg:query([[SELECT pg_get_userbyid(c.relowner) AS owner, t.spcname AS tablespace
    FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace WHERE c.oid = $1::regclass]], full) or {})[1] or {}
  local out = {
    "-- DROP TABLE IF EXISTS " .. full .. ";",
    "",
    "CREATE TABLE IF NOT EXISTS " .. full,
    "(",
    table.concat(lines, ",\n"),
    ")" .. (meta.tablespace and ("\nTABLESPACE " .. q(meta.tablespace)) or "") .. ";",
  }
  if meta.owner then out[#out + 1] = "\nALTER TABLE IF EXISTS " .. full .. "\n    OWNER to " .. q(meta.owner) .. ";" end
  -- constraint'e bagli olmayan indexler (PK/UNIQUE constraint indexleri yukarida tanimli)
  local idx = pg:query([[SELECT pg_get_indexdef(i.indexrelid) AS def FROM pg_index i
    WHERE i.indrelid = $1::regclass
      AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid)
    ORDER BY i.indexrelid]], full) or {}
  for _, ix in ipairs(idx) do
    local def = ix.def:gsub("^CREATE UNIQUE INDEX ", "CREATE UNIQUE INDEX IF NOT EXISTS ", 1)
    def = def:gsub("^CREATE INDEX ", "CREATE INDEX IF NOT EXISTS ", 1)
    out[#out + 1] = "\n" .. def .. ";"
  end
  return table.concat(out, "\n")
end

return _M
