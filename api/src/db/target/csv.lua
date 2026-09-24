-- CSV export: COPY streaming benzeri, Lua'da sorgu calistirip CSV'ye cevirir
local cjson = require("cjson.safe")
local sql_parser = require("utils.sql_parser")

local _M = {}

local function csv_escape(v, delimiter)
  if v == nil or v == cjson.null or v == ngx.null then return "" end
  local s = type(v) == "table" and cjson.encode(v) or tostring(v)
  -- delimiter veya cift tirnak veya satir kirilmasi varsa tirnakla
  if s:find('["\r\n]') or s:find(delimiter, 1, true) then
    s = '"' .. s:gsub('"', '""') .. '"'
  end
  -- excel formulu korumasi: = + - @ baslangic
  if s:find("^[=+%-@\t\r]") then s = "'" .. s end
  return s
end

function _M.csv_line(values, delimiter, n)
  delimiter = delimiter or ","
  local out = {}
  for i = 1, n or #values do out[i] = csv_escape(values[i], delimiter) end
  return table.concat(out, delimiter) .. "\r\n"
end

local function to_csv(cols, rows, delimiter, include_header)
  local buf = {}
  if include_header ~= false then buf[1] = _M.csv_line(cols, delimiter) end
  for _, r in ipairs(rows) do buf[#buf + 1] = _M.csv_line(r, delimiter, #cols) end
  return table.concat(buf)
end

-- Sorguyu salt-okunur islemde calistirip CSV uret (header dahil)
function _M.export_query(pg, sql, opts)
  opts = opts or {}
  local delimiter = opts.delimiter or ","
  if sql_parser.contains_transaction_control(sql) then
    return nil, { code = "READONLY_VIOLATION", message = "Yalnizca okuma islemine izin var", __app_error = true }
  end
  local bres, berr = pg:query("BEGIN READ ONLY")
  if not bres then return nil, berr end
  local res, err = require("db.target.query").execute(pg, sql, opts.limit or 100000, { in_transaction = true })
  pg:query("ROLLBACK")
  if not res then return nil, err end
  local cols = res.columns or {}
  return to_csv(cols, res.rows or {}, delimiter, opts.include_header),
    { truncated = res.truncated, rows = #(res.rows or {}), columns = cols }
end

-- Tabloyu filtre/siralama ile disari aktar; WHERE, tarayicinin dogrulanmis uretecinden gelir
function _M.export_table(pg, schema, table_name, opts)
  opts = opts or {}
  local delimiter = opts.delimiter or ","
  local browser = require("db.target.table_browser")
  local q = browser.quote_ident
  local col_list = "*"
  if opts.columns and #opts.columns > 0 then
    local qcols = {}
    for i, c in ipairs(opts.columns) do qcols[i] = q(c) end
    col_list = table.concat(qcols, ", ")
  end
  local where, params = browser.build_where(opts.filters, opts.custom_where)
  if not where then return nil, { code = "VALIDATION_FAILED", message = params, __app_error = true } end
  local order = opts.order_by and (" ORDER BY " .. opts.order_by) or ""
  local limit = opts.limit or 100000
  params[#params + 1] = limit + 1
  local sql = "SELECT " .. col_list .. " FROM " .. q(schema) .. "." .. q(table_name) .. " " .. where
    .. order .. " LIMIT $" .. #params
  local bres, berr = pg:query("BEGIN READ ONLY")
  if not bres then return nil, berr end
  local res, err = pg:query(sql, unpack(params))
  pg:query("ROLLBACK")
  if not res then return nil, err end
  local info = require("db.pool_manager").result_info(res)
  local cols = info and info.fields or {}
  local rows = {}
  for i = 1, math.min(#res, limit) do
    local r, row = res[i], {}
    for j, c in ipairs(cols) do row[j] = r[c] end
    rows[i] = row
  end
  return to_csv(cols, rows, delimiter, opts.include_header),
    { truncated = #res > limit, rows = #rows, columns = cols }
end

return _M
