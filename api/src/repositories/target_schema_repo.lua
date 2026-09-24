-- Hedef DB katalog sorgulari: information_schema + pg_catalog
local _M = {}

local function quote_ident(ident)
  if type(ident) ~= "string" then return '"' .. tostring(ident) .. '"' end
  return '"' .. ident:gsub('"', '""') .. '"'
end

_M.quote_ident = quote_ident

-- Sistem semalari (pg_catalog, information_schema, pg_toast*, pg_temp*) listelenmez
local USER_SCHEMAS = [[n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%']]
local KIND_SQL = [[CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned' WHEN 'v' THEN 'view'
  WHEN 'm' THEN 'matview' WHEN 'f' THEN 'foreign' END]]
-- listelenen nesneler: tablo, bolumlu tablo (bolumleri haric), view, materialized view, foreign table
local RELKINDS = [[c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relispartition]]

function _M.list_schemas(pg)
  local res, err = pg:query("SELECT n.nspname AS schema_name FROM pg_namespace n WHERE " .. USER_SCHEMAS
    .. " ORDER BY n.nspname")
  if not res then return nil, err end
  local list = {}
  for i, r in ipairs(res) do list[i] = r.schema_name end
  return list
end

function _M.list_objects(pg, schema)
  local res, err = pg:query("SELECT n.nspname AS schema, c.relname AS name, " .. KIND_SQL .. [[ AS kind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND ]] .. RELKINDS .. " ORDER BY c.relname", schema)
  if not res then return nil, err end
  return res
end

-- Kolonlar (pg_catalog): tip, NULL, varsayilan, identity turu, generated ifadesi, PK, enum degerleri, collation.
-- data_type format_type ciktisidir ("character varying(80)", "integer[]"); udt_name ham tip adi.
function _M.list_columns(pg, schema, table)
  local sql = [[
    SELECT a.attname AS column_name,
      format_type(a.atttypid, a.atttypmod) AS data_type,
      t.typname AS udt_name,
      CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END AS is_nullable,
      CASE WHEN a.attgenerated = '' THEN pg_get_expr(d.adbin, d.adrelid) END AS column_default,
      a.attnum AS ordinal_position,
      a.attidentity <> '' AS is_identity,
      CASE a.attidentity WHEN 'a' THEN 'ALWAYS' WHEN 'd' THEN 'BY DEFAULT' END AS identity_kind,
      a.attgenerated <> '' AS is_generated,
      CASE WHEN a.attgenerated <> '' THEN pg_get_expr(d.adbin, d.adrelid) END AS generation_expression,
      EXISTS (SELECT 1 FROM pg_index x WHERE x.indrelid = c.oid AND x.indisprimary
              AND a.attnum = ANY (x.indkey)) AS is_primary,
      t.typtype = 'e' AS is_enum,
      CASE WHEN t.typtype = 'e' THEN ARRAY(SELECT e.enumlabel::text FROM pg_enum e
                                           WHERE e.enumtypid = t.oid ORDER BY e.enumsortorder) END AS enum_values,
      t.typcategory = 'A' AS is_array,
      CASE WHEN a.attcollation <> t.typcollation THEN coll.collname END AS collation
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    LEFT JOIN pg_collation coll ON coll.oid = a.attcollation
    WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
    ORDER BY a.attnum]]
  local res, err = pg:query(sql, schema, table)
  if not res then return nil, err end
  if #res == 0 then return nil, { code = "42P01", message = "relation does not exist" } end
  return res
end

-- Nesne turu (pg_class.relkind): table | partitioned | view | matview | foreign; yoksa nil
local RELKIND = { r = "table", p = "partitioned", v = "view", m = "matview", f = "foreign" }
function _M.object_kind(pg, schema, name)
  local res = pg:query([[SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2]], schema, name)
  return res and res[1] and RELKIND[res[1].relkind] or nil
end

-- Yapi sorgulari: $1 = '"sema"."ad"' (regclass). pg_catalog tabanli, codd'daki alanlar.
local function qualified(schema, table) return quote_ident(schema) .. "." .. quote_ident(table) end

function _M.list_indexes(pg, schema, table)
  return pg:query([[SELECT ic.relname AS name, pg_get_indexdef(i.indexrelid) AS def,
      i.indisprimary AS is_primary, i.indisunique AS is_unique, i.indisvalid AS is_valid,
      i.indpred IS NOT NULL AS is_partial,
      (SELECT c.conname FROM pg_constraint c WHERE c.conindid = i.indexrelid LIMIT 1) AS constraint_name
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
    WHERE i.indrelid = $1::regclass ORDER BY i.indisprimary DESC, ic.relname]], qualified(schema, table))
end

function _M.list_constraints(pg, schema, table)
  return pg:query([[SELECT conname AS name, contype, pg_get_constraintdef(oid, true) AS def,
      convalidated AS validated, condeferrable AS deferrable, condeferred AS deferred
    FROM pg_constraint WHERE conrelid = $1::regclass AND contype <> 'n'
    ORDER BY contype = 'p' DESC, contype, conname]], qualified(schema, table))
end

-- cok kolonlu FK'ler tek satir (conkey/confkey sirasiyla); sema eslesmesi OID uzerinden
function _M.list_foreign_keys(pg, schema, table)
  return pg:query([[SELECT c.conname AS name,
      ARRAY(SELECT a.attname::text FROM unnest(c.conkey) WITH ORDINALITY k(n, o)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o) AS columns,
      fn.nspname AS ref_schema, fc.relname AS ref_table,
      ARRAY(SELECT a.attname::text FROM unnest(c.confkey) WITH ORDINALITY k(n, o)
            JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.o) AS ref_columns,
      c.confupdtype AS on_update, c.confdeltype AS on_delete, c.condeferrable AS deferrable
    FROM pg_constraint c
    JOIN pg_class fc ON fc.oid = c.confrelid JOIN pg_namespace fn ON fn.oid = fc.relnamespace
    WHERE c.conrelid = $1::regclass AND c.contype = 'f' ORDER BY c.conname]], qualified(schema, table))
end

function _M.list_triggers(pg, schema, table)
  return pg:query([[SELECT t.tgname AS name, pg_get_triggerdef(t.oid, true) AS def,
      t.tgfoid::regproc::text AS function, t.tgenabled::text AS enabled
    FROM pg_trigger t WHERE t.tgrelid = $1::regclass AND NOT t.tgisinternal ORDER BY t.tgname]], qualified(schema, table))
end

-- boyut ve istatistik (tablolar icin; view'da boyut 0)
function _M.get_size(pg, schema, table)
  local full = qualified(schema, table)
  local res, err = pg:query([[SELECT pg_total_relation_size($1::regclass) AS total_bytes,
      pg_relation_size($1::regclass) AS table_bytes, pg_indexes_size($1::regclass) AS index_bytes]], full)
  if not res then return nil, err end
  local stats = pg:query([[SELECT n_live_tup, n_dead_tup, seq_scan, idx_scan, last_vacuum, last_autovacuum,
      last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE relid = $1::regclass]], full)
  local r = res[1] or {}
  return { size_bytes = tonumber(r.total_bytes), table_bytes = tonumber(r.table_bytes),
    index_bytes = tonumber(r.index_bytes), stats = stats and stats[1] or nil }
end

-- Completion katalogu: tek sorguda tum kullanici nesneleri ve kolonlari (kolonsuz nesneler dahil)
function _M.completion_catalog(pg)
  local schemas, err = _M.list_schemas(pg)
  if not schemas then return nil, err end
  local res, cerr = pg:query("SELECT n.nspname AS schema, c.relname AS name, " .. KIND_SQL .. [[ AS kind,
      a.attname AS column_name, format_type(a.atttypid, a.atttypmod) AS data_type
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE ]] .. USER_SCHEMAS .. " AND " .. RELKINDS .. " ORDER BY 1, 2, a.attnum")
  if not res then return nil, cerr end
  local by_schema, tables = {}, {}
  for _, sch in ipairs(schemas) do by_schema[sch] = {} end
  for _, r in ipairs(res) do
    local key = r.schema .. "." .. r.name
    local t = tables[key]
    if not t and by_schema[r.schema] then
      t = { name = r.name, kind = r.kind, columns = {} }
      tables[key] = t
      table.insert(by_schema[r.schema], t)
    end
    if t and r.column_name then t.columns[#t.columns + 1] = { name = r.column_name, type = r.data_type } end
  end
  local out = { schemas = {} }
  local index = {}
  for i, sch in ipairs(schemas) do
    out.schemas[i] = { name = sch, tables = by_schema[sch], routines = {}, triggers = {} }
    index[sch] = out.schemas[i]
  end
  -- fonksiyon/prosedürler (eklenti fonksiyonları hariç: pgcrypto vb. listeyi boğar) ve kullanıcı trigger'ları
  local routines = pg:query([[SELECT n.nspname AS schema, p.oid::bigint AS oid, p.proname AS name,
      CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS kind,
      pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS returns,
      l.lanname AS language
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
    WHERE ]] .. USER_SCHEMAS .. [[ AND p.prokind IN ('f', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                      AND d.deptype = 'e')
    ORDER BY 1, 3, 5]]) or {}
  for _, r in ipairs(routines) do
    local sch = index[r.schema]
    if sch then
      sch.routines[#sch.routines + 1] = { oid = r.oid, name = r.name, kind = r.kind, args = r.args,
        returns = r.returns, language = r.language }
    end
  end
  local triggers = pg:query([[SELECT n.nspname AS schema, t.oid::bigint AS oid, t.tgname AS name,
      c.relname AS table_name, t.tgenabled::text <> 'D' AS enabled
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE ]] .. USER_SCHEMAS .. [[ AND NOT t.tgisinternal ORDER BY 1, 3]]) or {}
  for _, r in ipairs(triggers) do
    local sch = index[r.schema]
    if sch then
      sch.triggers[#sch.triggers + 1] = { oid = r.oid, name = r.name, table = r.table_name, enabled = r.enabled }
    end
  end
  return out
end

return _M
