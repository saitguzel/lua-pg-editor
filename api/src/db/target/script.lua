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

local function lit(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

-- F25: iliski olmayan nesneler icin CREATE; detail = target_schema_repo.object_detail ciktisi (saf, DB'siz)
function _M.create_other_script(kind, schema, name, detail)
  local full, d = qname(schema, name), detail or {}
  if kind == "sequence" then
    local parts = { "CREATE SEQUENCE " .. full }
    if d.data_type then parts[#parts + 1] = "    AS " .. d.data_type end
    if d.start then parts[#parts + 1] = "    START WITH " .. d.start end
    if d.increment then parts[#parts + 1] = "    INCREMENT BY " .. d.increment end
    if d.min then parts[#parts + 1] = "    MINVALUE " .. d.min end
    if d.max then parts[#parts + 1] = "    MAXVALUE " .. d.max end
    if d.cache then parts[#parts + 1] = "    CACHE " .. d.cache end
    if d.cycle then parts[#parts + 1] = "    CYCLE" end
    if d.owned_by then parts[#parts + 1] = "    OWNED BY " .. d.owned_by end
    return table.concat(parts, "\n") .. ";"
  elseif kind == "type_enum" then
    local labels = {}
    for i, l in ipairs(d.labels or {}) do labels[i] = lit(l) end
    return "CREATE TYPE " .. full .. " AS ENUM (" .. table.concat(labels, ", ") .. ");"
  elseif kind == "type_composite" then
    local attrs = {}
    for i, a in ipairs(d.attributes or {}) do attrs[i] = "    " .. q(a.name) .. " " .. a.type end
    return "CREATE TYPE " .. full .. " AS (\n" .. table.concat(attrs, ",\n") .. "\n);"
  elseif kind == "type_range" then
    return "CREATE TYPE " .. full .. " AS RANGE (\n    subtype = " .. tostring(d.subtype)
      .. (d.collation and (",\n    collation = " .. d.collation) or "") .. "\n);"
  elseif kind == "domain" then
    local out = "CREATE DOMAIN " .. full .. " AS " .. tostring(d.base_type)
    if d.default then out = out .. "\n    DEFAULT " .. d.default end
    if d.not_null then out = out .. "\n    NOT NULL" end
    for _, c in ipairs(d.constraints or {}) do out = out .. "\n    CONSTRAINT " .. c end
    return out .. ";"
  elseif kind == "extension" then
    return "CREATE EXTENSION IF NOT EXISTS " .. q(name) .. " SCHEMA " .. q(schema)
      .. (d.version and (" VERSION " .. lit(d.version)) or "") .. ";"
  end
  return nil, { message = "bu nesne turu icin CREATE uretilmiyor: " .. tostring(kind) }
end

-- CREATE: tablo (codd bicimi) ya da view/matview tanimi
function _M.create_script(pg, schema, name, kind, columns)
  local full = qname(schema, name)
  if kind == "view" or kind == "matview" then
    local res, err = pg:query("SELECT pg_get_viewdef($1::regclass, true) AS def", full)
    if not res then return nil, err end
    local out = "-- " .. _M.drop_script(schema, name, kind) .. "\nCREATE " .. SQL_TYPE[kind] .. " " .. full .. " AS\n"
      .. (res[1] and res[1].def or "SELECT ...;")
    if kind == "matview" then
      local idx = pg:query("SELECT pg_get_indexdef(i.indexrelid) AS def FROM pg_index i"
        .. " WHERE i.indrelid = $1::regclass", full) or {}
      for _, ix in ipairs(idx) do out = out .. "\n" .. ix.def .. ";" end
    end
    return out
  end
  -- F25: foreign table → SERVER + OPTIONS
  local foreign = kind == "foreign" and (pg:query([[SELECT s.srvname, ft.ftoptions FROM pg_foreign_table ft
    JOIN pg_foreign_server s ON s.oid = ft.ftserver WHERE ft.ftrelid = $1::regclass]], full) or {})[1] or nil
  local lines = {}
  for _, c in ipairs(columns) do lines[#lines + 1] = column_def(pg, schema, name, c) end
  local cons = pg:query([[SELECT conname, pg_get_constraintdef(oid, true) AS def FROM pg_constraint
    WHERE conrelid = $1::regclass AND contype <> 'n' ORDER BY contype = 'p' DESC, conname]], full) or {}
  for _, con in ipairs(cons) do lines[#lines + 1] = "    CONSTRAINT " .. q(con.conname) .. " " .. con.def end
  local meta = (pg:query([[SELECT pg_get_userbyid(c.relowner) AS owner, t.spcname AS tablespace
    FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace WHERE c.oid = $1::regclass]], full) or {})[1] or {}
  local tail = ")" .. (meta.tablespace and ("\nTABLESPACE " .. q(meta.tablespace)) or "")
  if foreign then
    local opts = {}
    for i, o in ipairs(type(foreign.ftoptions) == "table" and foreign.ftoptions or {}) do
      local k, v = tostring(o):match("^([^=]+)=(.*)$")
      opts[i] = k and (q(k) .. " " .. lit(v)) or lit(o)
    end
    tail = ")\nSERVER " .. q(foreign.srvname)
      .. (#opts > 0 and ("\nOPTIONS (" .. table.concat(opts, ", ") .. ")") or "")
  end
  local sql_type = SQL_TYPE[kind] or "TABLE"
  local out = {
    "-- DROP " .. sql_type .. " IF EXISTS " .. full .. ";",
    "",
    "CREATE " .. sql_type .. " IF NOT EXISTS " .. full,
    "(",
    table.concat(lines, ",\n"),
    tail .. ";",
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
