-- Hedef DB sorgu calistirma: SQL ayrıştırıcı mantigi (rate limit disinda)
local cjson = require("cjson.safe")
local sql_parser = require("utils.sql_parser")
local config = require("config")

local _M = {}

local function map_target_error(err)
  local sqlstate = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  -- 42P01 undefined_table -> OBJECT_NOT_FOUND, 42601 syntax -> BAD_REQUEST
  if sqlstate == "42P01" then
    return { code = "OBJECT_NOT_FOUND", message = "Tablo veya view bulunamadi", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  elseif sqlstate == "42P02" or sqlstate == "42703" or sqlstate == "42P02" then
    return { code = "OBJECT_NOT_FOUND", message = "Obje bulunamadi", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  elseif sqlstate == "42601" or sqlstate == "42602" then
    return { code = "BAD_REQUEST", message = "SQL sozdizimi hatali", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  elseif sqlstate == "57014" then
    return { code = "QUERY_FAILED", message = "Sorgu iptal edildi", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  elseif sqlstate == "42501" then
    return { code = "FORBIDDEN", message = "Yetki yok", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  elseif sqlstate then
    return { code = "QUERY_FAILED", message = "Sorgu calistirilamadi", details = { sqlstate = sqlstate, db_message = msg }, __app_error = true }
  end
  if msg and msg:find("timeout", 1, true) then
    return { code = "QUERY_FAILED", message = "Sorgu zaman asimi", details = { db_message = msg }, __app_error = true }
  end
  return { code = "QUERY_FAILED", message = "Sorgu calistirilamadi", details = { db_message = msg }, __app_error = true }
end

local function safe_row_limit(limit)
  return sql_parser.safe_row_limit(limit)
end

_M.safe_row_limit = safe_row_limit

local function expects_rows(sql)
  return sql_parser.expects_rows_when_empty(sql)
end

-- pgmoon sonucunu { columns, column_types, rows(dizi), row_count, truncated } yapar.
-- Satirlar SELECT kolon sirasinda dizi; NULL → cjson.null (JSON'da null, satir kesilmez).
local function shape(res, limit)
  if type(res) ~= "table" then
    return { columns = {}, rows = {}, row_count = 0, truncated = false }
  end
  local info = require("db.pool_manager").result_info(res)
  -- satir tanimi yoksa (INSERT/UPDATE/DDL) affected_rows gelir
  if not info then
    local n = res.affected_rows or 0
    return { columns = {}, rows = {}, row_count = n, truncated = false, command = "affected", affected = n }
  end
  local cols = info.fields
  local count = math.min(#res, limit)
  local rows = {}
  for i = 1, count do
    local r, row = res[i], {}
    local arr = info.array_rows and info.array_rows[i]
    for j, c in ipairs(cols) do
      local v
      if arr then v = arr[j] else v = r[c] end
      if v == nil then v = cjson.null end
      row[j] = v
    end
    rows[i] = row
  end
  return { columns = cols, column_types = info.types, rows = rows, row_count = count, truncated = #res > limit }
end

local ROW_STATEMENTS = { select = true, with = true, values = true, table = true }

-- Satir donduren ifade: cursor ile yalnizca limit+1 satir cekilir (tum sonuc belleğe alinmaz).
-- DECLARE kabul etmezse (SELECT INTO, veri degistiren WITH vb.) ifade dogrudan calisir.
local function exec_limited(pg, stmt, limit)
  if not pg:query("BEGIN") then return nil end
  if not pg:query("DECLARE _pgl_cur NO SCROLL CURSOR FOR " .. stmt) then
    pg:query("ROLLBACK")
    return nil
  end
  local res, err = pg:query("FETCH " .. (limit + 1) .. " FROM _pgl_cur")
  pg:query("CLOSE _pgl_cur")
  pg:query(res and "COMMIT" or "ROLLBACK")
  if not res then return false, err end
  return shape(res, limit)
end

-- Tek bir ifadeyi calistir, satir limitini uygula (truncated bayragi)
local function exec_one(pg, stmt, limit, use_cursor)
  if use_cursor then
    local kw = sql_parser.strip_leading_sql_comments(stmt):lower():match("^%s*(%a+)")
    if ROW_STATEMENTS[kw] then
      local out, err = exec_limited(pg, stmt, limit)
      if out then return out end
      if out == false then return nil, map_target_error(err) end
    end
  end
  local res, err = pg:query(stmt)
  if not res then return nil, map_target_error(err) end
  return shape(res, limit)
end

-- opts.in_transaction: cagiran zaten islem acti (READ ONLY export) → cursor'un kendi BEGIN/COMMIT'i
-- o islemi erken bitirip sonraki ifadeleri salt-okunur korumasi disinda calistirirdi
function _M.execute(pg, sql, row_limit, opts)
  if type(sql) ~= "string" or sql:match("^%s*$") then
    return nil, { code = "VALIDATION_FAILED", message = "SQL zorunlu", details = { sql = { "zorunlu alan" } }, __app_error = true }
  end
  local cfg = config.get()
  local max_bytes = cfg and cfg.query and cfg.query.max_bytes or 102400
  if #sql > max_bytes then
    return nil, { code = "PAYLOAD_TOO_LARGE", message = "Sorgu cok buyuk", __app_error = true }
  end
  local limit = safe_row_limit(row_limit)
  -- kullanici islem komutu (BEGIN/COMMIT) kullaniyorsa kendi BEGIN'imiz onun islemini bozar: cursor yok
  local use_cursor = not (opts and opts.in_transaction) and not sql_parser.contains_transaction_control(sql)
  -- Coklu ifade: hepsi sirayla calisir, yalnizca sonuncunun sonucu doner (codd davranisi)
  local last
  for _, stmt in ipairs(sql_parser.sql_statements(sql)) do
    local trimmed = stmt:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local cur, err = exec_one(pg, trimmed, limit, use_cursor)
      if not cur then return nil, err end
      last = cur
    end
  end
  return last or { columns = {}, rows = {}, row_count = 0, truncated = false }
end

function _M.execute_read_only(pg, sql, row_limit)
  if sql_parser.contains_transaction_control(sql) then
    return nil, { code = "READONLY_VIOLATION", message = "Yalnizca okuma islemine izin var", __app_error = true }
  end
  -- BEGIN READ ONLY ile sar
  local bres, berr = pg:query("BEGIN READ ONLY")
  if not bres then return nil, map_target_error(berr) end
  local res, err = _M.execute(pg, sql, row_limit, { in_transaction = true })
  -- her durumda ROLLBACK
  local rres, rerr = pg:query("ROLLBACK")
  if not rres then ngx.log(ngx.WARN, "ROLLBACK basarisiz: ", tostring(rerr)) end
  if not res then return nil, err end
  return res
end

-- CSV icin COPY
function _M.copy_to_stdout(pg, sql, delimiter, include_header)
  -- sql'in read-only oldugu disarda dogrulanir
  -- COPY (query) TO STDOUT WITH (FORMAT csv, HEADER ..., DELIMITER ',')
  delimiter = delimiter or ","
  local delim_map = { [","] = ",", [";"] = ";", ["\t"] = "\t", ["|"] = "|" }
  local d = delim_map[delimiter] or ","
  -- pgmoon COPY streaming desteklemiyor olabilir; biz basit sorgu ile CSV uretiyoruz
  -- Alternatif: sorguyu calistirip Lua'da CSV'ye cevir
  return nil, "COPY streaming desteklenmiyor, fallback kullanin"
end

_M.map_target_error = map_target_error
_M.expects_rows = expects_rows

return _M
