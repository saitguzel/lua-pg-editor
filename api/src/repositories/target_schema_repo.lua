-- Hedef DB katalog sorgulari: information_schema + pg_catalog
local _M = {}

local function quote_ident(ident)
  if type(ident) ~= "string" then return '"' .. tostring(ident) .. '"' end
  return '"' .. ident:gsub('"', '""') .. '"'
end

_M.quote_ident = quote_ident

-- Sistem şemalari (pg_catalog, information_schema, pg_toast*, pg_temp*) listelenmez
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

-- ---- F25: kategori bazli katalog ------------------------------------------------------------------
-- Her kategori: from (pg_namespace n zorunlu), where (n.nspname = $1 sonrasi ek kosul), name (ILIKE/ORDER kolonu),
-- select (name, kind, extra kolonlari). extra: kisa metin (imza, surum, temel tip...) ya da NULL.
local TYPE_KIND = [[CASE t.typtype WHEN 'b' THEN 'type_base' WHEN 'c' THEN 'type_composite'
  WHEN 'e' THEN 'type_enum' WHEN 'r' THEN 'type_range' END]]
local function rel(kinds, kind_sql)
  return { from = "pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace",
    where = "c.relkind IN (" .. kinds .. ") AND NOT c.relispartition", name = "c.relname",
    select = "c.relname AS name, " .. kind_sql .. " AS kind, NULL::text AS extra" }
end
-- Rutinlerde extra yapısal: oid/args/returns/language ayri kolon gelir, model bunlari extra{} altinda toplar
-- (kenar cubugu rutin menusu /routines/:kind/:oid icin oid'ye ihtiyac duyar).
local function proc(kinds, kind_sql)
  return { from = "pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang",
    where = "p.prokind IN (" .. kinds .. ") AND NOT EXISTS (SELECT 1 FROM pg_depend d"
      .. " WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')",
    name = "p.proname",
    select = "p.proname AS name, " .. kind_sql .. " AS kind, '(' || pg_get_function_identity_arguments(p.oid) || ')'"
      .. " AS extra, p.oid::bigint AS oid, pg_get_function_identity_arguments(p.oid) AS args,"
      .. " pg_get_function_result(p.oid) AS returns, l.lanname AS language" }
end
local function simple(tbl, alias, ns_col, name_col, kind, extra)
  return { from = "pg_" .. tbl .. " " .. alias .. " JOIN pg_namespace n ON n.oid = " .. alias .. "." .. ns_col,
    where = "TRUE", name = alias .. "." .. name_col,
    select = alias .. "." .. name_col .. " AS name, '" .. kind .. "' AS kind, " .. (extra or "NULL::text")
      .. " AS extra" }
end
local FUNC_KIND = "CASE p.prokind WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window' ELSE 'function' END"
local CATEGORY = {
  tables = rel("'r', 'p'", "CASE c.relkind WHEN 'p' THEN 'partitioned' ELSE 'table' END"),
  views = rel("'v'", "'view'"),
  matviews = rel("'m'", "'matview'"),
  foreign_tables = rel("'f'", "'foreign'"),
  sequences = rel("'S'", "'sequence'"),
  functions = proc("'f', 'a', 'w'", FUNC_KIND),
  procedures = proc("'p'", "'procedure'"),
  -- dizi tipleri (typelem) ve tablo satır tipleri (typrelid + relkind<>'c') haric
  types = { from = "pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace LEFT JOIN pg_class c ON c.oid = t.typrelid",
    where = "t.typtype IN ('b', 'c', 'e', 'r') AND t.typelem = 0 AND (t.typrelid = 0 OR c.relkind = 'c')",
    name = "t.typname", select = "t.typname AS name, " .. TYPE_KIND .. " AS kind, NULL::text AS extra" },
  domains = { from = "pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace", where = "t.typtype = 'd'",
    name = "t.typname",
    select = "t.typname AS name, 'domain' AS kind, format_type(t.typbasetype, t.typtypmod) AS extra" },
  extensions = simple("extension", "e", "extnamespace", "extname", "extension", "e.extversion"),
  operators = simple("operator", "o", "oprnamespace", "oprname", "operator",
    "o.oprleft::regtype::text || ' ' || o.oprname || ' ' || o.oprright::regtype::text"),
  collations = simple("collation", "co", "collnamespace", "collname", "collation", "co.collprovider::text"),
  fts_configs = simple("ts_config", "f", "cfgnamespace", "cfgname", "fts_config"),
  fts_dicts = simple("ts_dict", "f", "dictnamespace", "dictname", "fts_dict"),
  fts_parsers = simple("ts_parser", "f", "prsnamespace", "prsname", "fts_parser"),
  fts_templates = simple("ts_template", "f", "tmplnamespace", "tmplname", "fts_template"),
}
local CATEGORY_ORDER = require("pg_shared.types").OBJECT_CATEGORIES

-- ILIKE deseninde % ve _ kacislanir (ESCAPE '\')
function _M.escape_like(s)
  return (tostring(s):gsub("[\\%%_]", function(c) return "\\" .. c end))
end

-- Liste SQL'i: $1 = şema, $2 = %q% (q verilmisse); limit/offset parametreli $n (faz-31)
function _M.category_sql(category, with_q, limit, offset)
  local c = CATEGORY[category]
  if not c then return nil end
  local sql = "SELECT n.nspname AS schema, " .. c.select .. " FROM " .. c.from .. " WHERE n.nspname = $1 AND " .. c.where
  local idx = 1
  if with_q then idx = idx + 1; sql = sql .. " AND " .. c.name .. " ILIKE $" .. idx .. " ESCAPE '\\'" end
  sql = sql .. " ORDER BY " .. c.name
  if limit then idx = idx + 1; sql = sql .. " LIMIT $" .. idx end
  if offset and offset > 0 then idx = idx + 1; sql = sql .. " OFFSET $" .. idx end
  return sql
end

-- Sayac SQL'i: 16 kategori tek round-trip (UNION ALL), $1 = şema
function _M.count_categories_sql()
  local parts = {}
  for i, cat in ipairs(CATEGORY_ORDER) do
    local c = CATEGORY[cat]
    parts[i] = "SELECT '" .. cat .. "' AS category, count(*) AS count FROM " .. c.from .. " WHERE n.nspname = $1 AND "
      .. c.where
  end
  return table.concat(parts, "\nUNION ALL\n")
end

function _M.count_categories(pg, schema)
  local res, err = pg:query(_M.count_categories_sql(), schema)
  if not res then return nil, err end
  local by = {}
  for _, r in ipairs(res) do by[r.category] = tonumber(r.count) or 0 end
  local out = {}
  for i, cat in ipairs(CATEGORY_ORDER) do out[i] = { category = cat, count = by[cat] or 0 } end
  return out
end

function _M.list_category(pg, category, schema, q, limit, offset)
  local has_q = q ~= nil
  local has_limit = limit ~= nil
  local has_offset = offset ~= nil and offset > 0
  local sql = _M.category_sql(category, has_q, has_limit and limit or nil, has_offset and offset or nil)
  if not sql then return nil, { message = "bilinmeyen kategori" } end
  local params = { schema }
  if has_q then params[#params + 1] = "%" .. _M.escape_like(q) .. "%" end
  if has_limit then params[#params + 1] = math.floor(limit) end
  if has_offset then params[#params + 1] = math.floor(offset) end
  return pg:query(sql, unpack(params))
end

local RULE_EVENT = { ["1"] = "SELECT", ["2"] = "UPDATE", ["3"] = "INSERT", ["4"] = "DELETE" }
function _M.list_rules(pg, schema, table)
  local res, err = pg:query([[SELECT r.rulename AS name, r.ev_type::text AS ev_type, r.is_instead,
      pg_get_ruledef(r.oid, true) AS def
    FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND r.rulename <> '_RETURN' ORDER BY r.rulename]], schema, table)
  if not res then return nil, err end
  for _, r in ipairs(res) do r.event = RULE_EVENT[r.ev_type] or r.ev_type; r.ev_type = nil end
  return res
end

local POLICY_CMD = { ["*"] = "ALL", r = "SELECT", a = "INSERT", w = "UPDATE", d = "DELETE" }
function _M.list_policies(pg, schema, table)
  local res, err = pg:query([[SELECT p.polname AS name, p.polcmd::text AS polcmd, p.polpermissive AS permissive,
      CASE WHEN p.polroles = '{0}'::oid[] THEN ARRAY['public']::text[]
           ELSE ARRAY(SELECT r.rolname::text FROM pg_roles r WHERE r.oid = ANY (p.polroles)) END AS roles,
      pg_get_expr(p.polqual, p.polrelid, true) AS using_expr,
      pg_get_expr(p.polwithcheck, p.polrelid, true) AS check_expr
    FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 ORDER BY p.polname]], schema, table)
  if not res then return nil, err end
  for _, r in ipairs(res) do r.command = POLICY_CMD[r.polcmd] or r.polcmd; r.polcmd = nil end
  return res
end

-- Iliski olmayan nesnenin turu (sequence, type_*, domain, extension, operator, collation, fts_*); yoksa nil
function _M.other_object_kind(pg, schema, name)
  local res = pg:query([[
    SELECT 'sequence' AS kind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'S'
    UNION ALL SELECT CASE t.typtype WHEN 'd' THEN 'domain' ELSE ]] .. TYPE_KIND .. [[ END
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace LEFT JOIN pg_class c ON c.oid = t.typrelid
      WHERE n.nspname = $1 AND t.typname = $2 AND t.typtype IN ('b', 'c', 'e', 'r', 'd') AND t.typelem = 0
        AND (t.typrelid = 0 OR c.relkind = 'c')
    UNION ALL SELECT 'extension' FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE n.nspname = $1 AND e.extname = $2
    UNION ALL SELECT 'operator' FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace
      WHERE n.nspname = $1 AND o.oprname = $2
    UNION ALL SELECT 'collation' FROM pg_collation co JOIN pg_namespace n ON n.oid = co.collnamespace
      WHERE n.nspname = $1 AND co.collname = $2
    UNION ALL SELECT 'fts_config' FROM pg_ts_config f JOIN pg_namespace n ON n.oid = f.cfgnamespace
      WHERE n.nspname = $1 AND f.cfgname = $2
    UNION ALL SELECT 'fts_dict' FROM pg_ts_dict f JOIN pg_namespace n ON n.oid = f.dictnamespace
      WHERE n.nspname = $1 AND f.dictname = $2
    UNION ALL SELECT 'fts_parser' FROM pg_ts_parser f JOIN pg_namespace n ON n.oid = f.prsnamespace
      WHERE n.nspname = $1 AND f.prsname = $2
    UNION ALL SELECT 'fts_template' FROM pg_ts_template f JOIN pg_namespace n ON n.oid = f.tmplnamespace
      WHERE n.nspname = $1 AND f.tmplname = $2
    LIMIT 1]], schema, name)
  return res and res[1] and res[1].kind or nil
end

-- Iliski olmayan nesne detayi (kategoriye ozel alanlar); satır yoksa nil
local DETAIL_SQL = {
  sequence = [[SELECT s.data_type::text AS data_type, s.start_value AS start, s.increment_by AS increment,
      s.min_value AS min, s.max_value AS max, s.cache_size AS cache, s.cycle, s.last_value,
      (SELECT quote_ident(rn.nspname) || '.' || quote_ident(rc.relname) || '.' || quote_ident(a.attname)
         FROM pg_depend d JOIN pg_class rc ON rc.oid = d.refobjid JOIN pg_namespace rn ON rn.oid = rc.relnamespace
         JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
         WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i') LIMIT 1) AS owned_by
    FROM pg_sequences s JOIN pg_namespace n ON n.nspname = s.schemaname
    JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename
    WHERE s.schemaname = $1 AND s.sequencename = $2]],
  type_enum = [[SELECT ARRAY(SELECT e.enumlabel::text FROM pg_enum e WHERE e.enumtypid = t.oid ORDER BY e.enumsortorder)
      AS labels
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = $1 AND t.typname = $2]],
  type_composite = [[SELECT a.attname::text AS name, format_type(a.atttypid, a.atttypmod) AS type
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace JOIN pg_attribute a ON a.attrelid = t.typrelid
    WHERE n.nspname = $1 AND t.typname = $2 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum]],
  type_range = [[SELECT r.rngsubtype::regtype::text AS subtype,
      NULLIF(r.rngcollation::regcollation::text, '-') AS collation
    FROM pg_range r JOIN pg_type t ON t.oid = r.rngtypid JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = $1 AND t.typname = $2]],
  type_base = [[SELECT t.typlen AS length, t.typbyval AS by_value, t.typcategory::text AS category,
      t.typinput::regproc::text AS input_function, t.typoutput::regproc::text AS output_function
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = $1 AND t.typname = $2]],
  domain = [[SELECT format_type(t.typbasetype, t.typtypmod) AS base_type, t.typnotnull AS not_null,
      pg_get_expr(t.typdefaultbin, 0) AS default,
      ARRAY(SELECT c.conname::text || ' ' || pg_get_constraintdef(c.oid, true) FROM pg_constraint c
            WHERE c.contypid = t.oid ORDER BY c.conname) AS constraints
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = $1 AND t.typname = $2]],
  extension = [[SELECT e.extversion AS version, e.extrelocatable AS relocatable,
      obj_description(e.oid, 'pg_extension') AS description
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE n.nspname = $1 AND e.extname = $2]],
  operator = [[SELECT o.oprleft::regtype::text AS left, o.oprright::regtype::text AS right,
      o.oprresult::regtype::text AS result, o.oprcode::regproc::text AS function
    FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace WHERE n.nspname = $1 AND o.oprname = $2 LIMIT 1]],
  collation = [[SELECT co.collprovider::text AS provider, co.collcollate AS lc_collate, co.collctype AS lc_ctype
    FROM pg_collation co JOIN pg_namespace n ON n.oid = co.collnamespace WHERE n.nspname = $1 AND co.collname = $2]],
  fts_config = [[SELECT obj_description(f.oid, 'pg_ts_config') AS description, f.cfgparser::regproc::text AS parser
    FROM pg_ts_config f JOIN pg_namespace n ON n.oid = f.cfgnamespace WHERE n.nspname = $1 AND f.cfgname = $2]],
  fts_dict = [[SELECT obj_description(f.oid, 'pg_ts_dict') AS description, f.dictinitoption AS options
    FROM pg_ts_dict f JOIN pg_namespace n ON n.oid = f.dictnamespace WHERE n.nspname = $1 AND f.dictname = $2]],
  fts_parser = [[SELECT obj_description(f.oid, 'pg_ts_parser') AS description
    FROM pg_ts_parser f JOIN pg_namespace n ON n.oid = f.prsnamespace WHERE n.nspname = $1 AND f.prsname = $2]],
  fts_template = [[SELECT obj_description(f.oid, 'pg_ts_template') AS description
    FROM pg_ts_template f JOIN pg_namespace n ON n.oid = f.tmplnamespace WHERE n.nspname = $1 AND f.tmplname = $2]],
}
_M.DETAIL_KINDS = DETAIL_SQL
function _M.object_detail(pg, kind, schema, name)
  local sql = DETAIL_SQL[kind]
  if not sql then return nil end
  local res, err = pg:query(sql, schema, name)
  if not res then return nil, err end
  if kind == "type_composite" then
    local attrs = {}
    for i, r in ipairs(res) do attrs[i] = { name = r.name, type = r.type } end
    return { attributes = attrs }
  end
  local row = res[1]
  if row and kind == "sequence" then row.cycle = row.cycle == true end
  return row
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

-- Yapı sorgulari: $1 = '"şema"."ad"' (regclass). pg_catalog tabanli, codd'daki alanlar.
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

-- cok kolonlu FK'ler tek satır (conkey/confkey sirasiyla); şema eslesmesi OID uzerinden
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

-- Completion katalogu: tek sorguda tum kullanıcı nesneleri ve kolonlari (kolonsuz nesneler dahil)
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
