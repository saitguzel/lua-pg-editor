-- CSV export servis: sorgu ve tablo disari aktarimi, streaming hazirligi, audit
local cjson = require("cjson.safe")
local connection_repo = require("repositories.connection_repo")
local pool_manager = require("db.pool_manager")
local target_csv = require("db.target.csv")
local target_query = require("db.target.query")
local sql_parser = require("utils.sql_parser")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local config = require("config")

local _M = {}

local function get_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then return nil, errors.new("CONNECTION_NOT_FOUND", "Baglanti bulunamadi") end
  return row
end

local acquire = pool_manager.acquire_for

local function validate_readonly(sql)
  if sql_parser.contains_transaction_control(sql) then
    return nil, errors.new("READONLY_VIOLATION", "Yalnizca okuma islemine izin var")
  end
  -- ek: sadece SELECT/WITH/SHOW/EXPLAIN/VALUES icerir mi? Eger DELETE/UPDATE/INSERT iceriyorsa reject
  local lc = sql_parser.strip_leading_sql_comments(sql):lower()
  if lc:match("^%s*delete") or lc:match("^%s*insert") or lc:match("^%s*update") or lc:match("^%s*alter") or lc:match("^%s*drop") or lc:match("^%s*truncate") or lc:match("^%s*create") then
    return nil, errors.new("READONLY_VIOLATION", "Yalnizca okuma islemine izin var")
  end
  return true
end

function _M.stream_query_csv(ngx, identity, input)
  -- input: { connection_id, database, sql, delimiter, include_header }
  local conn_row, err = get_owned(identity, input.connection_id)
  if not conn_row then return nil, err end
  local database = input.database or conn_row.database
  local ok, rerr = validate_readonly(input.sql)
  if not ok then return nil, rerr end
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local cfg = config.get()
  local max_rows = cfg and cfg.csv and cfg.csv.max_rows or 100000
  -- pgmoon streaming: biz toplu alip ngx.print ile parca parca gonderiyoruz
  local limit = math.max(1, math.min(tonumber(input.limit) or max_rows, max_rows))
  local csv_data, meta = target_csv.export_query(pg, input.sql, { delimiter=input.delimiter, include_header=input.include_header, limit=limit, format=input.format })
  -- export_query kendi icinde BEGIN READ ONLY/ROLLBACK yapti, release
  pool_manager.release(cid, pg, csv_data==nil)
  if not csv_data then
    if type(meta)=="table" and meta.__app_error then return nil, meta end
    return nil, errors.new("QUERY_FAILED", "CSV olusturulamadi", { db_message=tostring(meta) })
  end
  -- header'lar handler'da ayarlanacak; burada sadece veri ve audit
  audit_service.record("query.export.csv", { entity_type="query", entity_id=input.connection_id, new_value={ connection_id=input.connection_id, database=database, rows=meta.rows, truncated=meta.truncated, format=input.format or "csv" } })
  return csv_data, meta
end

-- Handler icinde streaming: ngx.header ayarla, chunk gonder
function _M.stream_table_csv(ngx, identity, connection_id, schema, table_name, opts)
  opts = opts or {}
  local conn_row, err = get_owned(identity, connection_id)
  if not conn_row then return nil, err end
  local database = opts.database or conn_row.database
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local cfg = config.get()
  local max_rows = cfg and cfg.csv and cfg.csv.max_rows or 100000
  -- filtre/siralama tablo tarayicisiyla ayni kurallar (kolon var mi, operator tipe uygun mu)
  local browser_service = require("services.table_browser_service")
  local tmeta, terr = browser_service.describe(pg, schema, table_name)
  local function fail(e) pool_manager.release(cid, pg, false); return nil, e end
  if not tmeta then return fail(errors.new("OBJECT_NOT_FOUND", "Tablo veya view bulunamadi", { db_message = tostring(terr and terr.message) })) end
  local filters, ferr = browser_service._validate_filters(opts.filters, tmeta)
  if not filters then return fail(errors.new("VALIDATION_FAILED", ferr, { filters = { ferr } })) end
  if opts.custom_where and opts.custom_where ~= "" then
    local vok, verr = sql_parser.validate_expression(opts.custom_where)
    if not vok then return fail(errors.new("BAD_REQUEST", "custom_where: " .. verr)) end
  end
  local order_by
  if type(opts.sort) == "string" and opts.sort ~= "" then
    local desc = opts.sort:sub(1, 1) == "-"
    local name = desc and opts.sort:sub(2) or opts.sort
    if tmeta.by_name[name] then order_by = '"' .. name:gsub('"', '""') .. '"' .. (desc and " DESC" or " ASC") end
  end
  local csv_data, meta = target_csv.export_table(pg, schema, table_name, { delimiter=opts.delimiter, include_header=opts.include_header,
    filters=filters, custom_where=opts.custom_where, columns=opts.columns, order_by=order_by, format=opts.format, limit=math.max(1, math.min(tonumber(opts.limit) or max_rows, max_rows)) })
  -- export_table BEGIN/ROLLBACK icerir, ama disarda acquire edilmis pg'yi release et
  pool_manager.release(cid, pg, csv_data==nil)
  if not csv_data then
    if type(meta)=="table" and meta.__app_error then return nil, meta end
    return nil, errors.new("QUERY_FAILED", "CSV olusturulamadi", { db_message=tostring(meta) })
  end
  audit_service.record("query.export.csv", { entity_type="query", entity_id=connection_id, new_value={ connection_id=connection_id, schema=schema, table=table_name, rows=meta.rows, format=opts.format or "csv" } })
  return csv_data, meta
end

-- Basit: dogrudan CSV string donduren (non-streaming) API da desteklenir
function _M.export_query_csv(identity, input)
  local conn_row, err = get_owned(identity, input.connection_id)
  if not conn_row then return nil, err end
  local database = input.database or conn_row.database
  local ok, rerr = validate_readonly(input.sql)
  if not ok then return nil, rerr end
  local pg, cid = acquire(conn_row, database)
  if not pg then return nil, cid end
  local cfg = config.get()
  local max_rows = cfg and cfg.csv and cfg.csv.max_rows or 100000
  local csv_data, meta = target_csv.export_query(pg, input.sql, { delimiter=input.delimiter, include_header=input.include_header, limit=max_rows })
  pool_manager.release(cid, pg, csv_data==nil)
  if not csv_data then
    if type(meta)=="table" and meta.__app_error then return nil, meta end
    return nil, errors.new("QUERY_FAILED", "CSV olusturulamadi")
  end
  audit_service.record("query.export.csv", { entity_type="query", entity_id=input.connection_id, new_value={ connection_id=input.connection_id, database=database, rows=meta.rows } })
  return { csv=csv_data, meta=meta }
end

return _M
