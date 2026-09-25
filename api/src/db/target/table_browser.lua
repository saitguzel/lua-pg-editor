-- Hedef DB tablo tarayıcı: filtreli sayfali satır cekme, INSERT/UPDATE/DELETE, rid (satır kimligi)
local cjson = require("cjson.safe")

local _M = {}

local function quote_ident(ident)
  return '"' .. ident:gsub('"', '""') .. '"'
end

_M.quote_ident = quote_ident

-- Filter operator -> SQL (beyaz liste; LIKE/ILIKE codd gibi ::text uzerinden → uuid/dizi de aranir)
local OP_SQL = {
  ["="] = "=", ["!="] = "!=", [">"] = ">", [">="] = ">=", ["<"] = "<", ["<="] = "<=",
  ["LIKE"] = "LIKE", ["ILIKE"] = "ILIKE",
  ["IS NULL"] = "IS NULL", ["IS NOT NULL"] = "IS NOT NULL",
}

-- → where, params | nil, hata. Degerler parametreli (tipsiz → Postgres kolon tipine cevirir), filtreler AND
local function build_where(filters, custom_where)
  local clauses, params = {}, {}
  for _, f in ipairs(filters or {}) do
    local col = f.column or f.field
    local op = f.operator or f.op
    if type(col) ~= "string" or not OP_SQL[op] then
      return nil, "gecersiz filtre: " .. tostring(op)
    end
    if op == "IS NULL" or op == "IS NOT NULL" then
      clauses[#clauses + 1] = quote_ident(col) .. " " .. op
    else
      params[#params + 1] = f.value
      local lhs = (op == "LIKE" or op == "ILIKE") and (quote_ident(col) .. "::text") or quote_ident(col)
      clauses[#clauses + 1] = lhs .. " " .. OP_SQL[op] .. " $" .. #params
    end
  end
  if custom_where and custom_where ~= "" then
    clauses[#clauses + 1] = "(" .. custom_where .. ")"
  end
  return #clauses > 0 and ("WHERE " .. table.concat(clauses, " AND ")) or "", params
end

_M.build_where = build_where

-- sort: "kolon" | "-kolon"; yalnizca tablonun kolonlari
local function sort_expr(sort, allowed)
  if type(sort) ~= "string" or sort == "" then return nil end
  local dir, name = "ASC", sort
  if sort:sub(1, 1) == "-" then dir, name = "DESC", sort:sub(2) end
  if not allowed[name] then return nil end
  return quote_ident(name) .. " " .. dir
end

-- opts: page, per_page, sort, filters, custom_where, pk_columns, is_table
-- Varsayilan sira (codd): PK; PK yoksa tabloda ctid, view'da sira yok
function _M.fetch_rows(pg, schema, table_name, columns, opts)
  opts = opts or {}
  local page = math.max(1, math.floor(tonumber(opts.page) or 1))
  local per_page = math.floor(tonumber(opts.per_page) or 100)
  if per_page < 1 or per_page > 500 then per_page = 100 end
  local offset = (page - 1) * per_page
  local where, params = build_where(opts.filters, opts.custom_where)
  if not where then return nil, { code = "VALIDATION_FAILED", message = params, __app_error = true } end
  local allowed = {}
  for _, c in ipairs(columns or {}) do allowed[c.column_name or c.name] = true end
  local order = sort_expr(opts.sort, allowed)
  if not order then
    local pks = {}
    for i, k in ipairs(opts.pk_columns or {}) do pks[i] = quote_ident(k) end
    order = #pks > 0 and table.concat(pks, ", ") or (opts.is_table and "ctid" or nil)
  end
  local qname = quote_ident(schema) .. "." .. quote_ident(table_name)
  local cnt_res, cnt_err = pg:query("SELECT COUNT(*)::bigint AS cnt FROM " .. qname .. " " .. where, unpack(params))
  if not cnt_res then return nil, cnt_err end
  local total = tonumber(cnt_res[1] and cnt_res[1].cnt) or 0
  local qp = {}
  for i = 1, #params do qp[i] = params[i] end
  qp[#qp + 1] = per_page
  qp[#qp + 1] = offset
  local sql = "SELECT * FROM " .. qname .. " " .. where .. (order and (" ORDER BY " .. order) or "")
    .. " LIMIT $" .. (#params + 1) .. " OFFSET $" .. (#params + 2)
  local rows, err = pg:query(sql, unpack(qp))
  if not rows then return nil, err end
  return { rows = rows, total = total, has_next = (offset + per_page) < total, page = page, per_page = per_page }
end

-- cjson.null → pgmoon NULL (parametre olarak SQL NULL gider)
local function db_value(pg, v)
  if v == cjson.null or v == ngx.null then return pg.NULL end
  return v
end

-- values: { kolon = deger | cjson.null }; bos ise DEFAULT VALUES
function _M.insert_row(pg, schema, table_name, values)
  local qname = quote_ident(schema) .. "." .. quote_ident(table_name)
  local cols, marks, params = {}, {}, {}
  for col, val in pairs(values) do
    params[#params + 1] = db_value(pg, val)
    cols[#cols + 1] = quote_ident(col)
    marks[#marks + 1] = "$" .. #params
  end
  if #cols == 0 then return pg:query("INSERT INTO " .. qname .. " DEFAULT VALUES RETURNING *") end
  return pg:query("INSERT INTO " .. qname .. " (" .. table.concat(cols, ", ") .. ") VALUES ("
    .. table.concat(marks, ", ") .. ") RETURNING *", unpack(params))
end

-- rid_where: { clause = "pk=$1 AND pk2=$2", params = {...} }
function _M.update_rows(pg, schema, table_name, rid_where, values)
  local sets, params = {}, {}
  for col, val in pairs(values) do
    params[#params + 1] = db_value(pg, val)
    sets[#sets + 1] = quote_ident(col) .. " = $" .. #params
  end
  if #sets == 0 then return nil, "güncellenecek alan yok" end
  local offset = #params
  local clause = rid_where.clause:gsub("%$(%d+)", function(n) return "$" .. (tonumber(n) + offset) end)
  for i, v in ipairs(rid_where.params) do params[offset + i] = v end
  local qname = quote_ident(schema) .. "." .. quote_ident(table_name)
  return pg:query("UPDATE " .. qname .. " SET " .. table.concat(sets, ", ") .. " WHERE " .. clause
    .. " RETURNING *", unpack(params))
end

function _M.delete_rows(pg, schema, table_name, where_clause, where_params)
  if not where_clause or where_clause == "" then return nil, "where sarti gerekli" end
  local qname = quote_ident(schema) .. "." .. quote_ident(table_name)
  return pg:query("DELETE FROM " .. qname .. " WHERE " .. where_clause, unpack(where_params or {}))
end

-- PK'ya gore tek satır cek
function _M.fetch_one_by_rid(pg, schema, table_name, rid_where)
  local qname = quote_ident(schema) .. "." .. quote_ident(table_name)
  local res, err = pg:query("SELECT * FROM " .. qname .. " WHERE " .. rid_where.clause .. " LIMIT 1",
    unpack(rid_where.params))
  if not res then return nil, err end
  return res[1]
end

-- rid: PK degerlerinin (PK kolon sirasinda) JSON dizisi, base64url. Istemci opak tasir.
local function b64url(s) return (ngx.encode_base64(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")) end
local function unb64url(s)
  s = s:gsub("%-", "+"):gsub("_", "/")
  return ngx.decode_base64(s .. string.rep("=", (4 - #s % 4) % 4))
end

function _M.encode_rid(row, pk_columns)
  if not pk_columns or #pk_columns == 0 then return nil end
  local vals = {}
  for i, k in ipairs(pk_columns) do
    local v = row[k]
    if v == nil then return nil end
    vals[i] = type(v) == "string" and v or tostring(v)
  end
  return b64url(cjson.encode(vals))
end

-- → { clause, params } | nil, hata
function _M.decode_rid(rid, pk_columns)
  if not pk_columns or #pk_columns == 0 then return nil, "birincil anahtari olmayan tabloda satır duzenlenemez" end
  local raw = type(rid) == "string" and unb64url(rid)
  local vals = raw and cjson.decode(raw)
  if type(vals) ~= "table" or #vals ~= #pk_columns then return nil, "gecersiz rid" end
  local clauses = {}
  for i, col in ipairs(pk_columns) do
    if type(vals[i]) ~= "string" then return nil, "gecersiz rid" end
    clauses[i] = quote_ident(col) .. " = $" .. i
  end
  return { clause = table.concat(clauses, " AND "), params = vals }
end

-- toplu silme: (pk...) IN ((...), (...))
function _M.build_delete_where(ids, pk_columns)
  if not ids or #ids == 0 then return nil, "ids bos" end
  local cols, tuples, params = {}, {}, {}
  for i, c in ipairs(pk_columns or {}) do cols[i] = quote_ident(c) end
  for _, rid in ipairs(ids) do
    local decoded, err = _M.decode_rid(rid, pk_columns)
    if not decoded then return nil, err end
    local marks = {}
    for _, v in ipairs(decoded.params) do
      params[#params + 1] = v
      marks[#marks + 1] = "$" .. #params
    end
    tuples[#tuples + 1] = "(" .. table.concat(marks, ", ") .. ")"
  end
  return "(" .. table.concat(cols, ", ") .. ") IN (" .. table.concat(tuples, ", ") .. ")", params
end

return _M
