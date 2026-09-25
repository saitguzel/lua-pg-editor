-- SQL ayristirici: sql_statements ayristirici (Lua 5.1 uyumlu) - ozgun implementasyon
local _M = {}

local function is_space(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f"
end

-- Baslangictaki yorumlari ve bosluklari atla
function _M.strip_leading_sql_comments(sql)
  if type(sql) ~= "string" then return "" end
  local i = 1
  local n = #sql
  while i <= n do
    while i <= n and is_space(sql:sub(i, i)) do i = i + 1 end
    if sql:sub(i, i + 1) == "--" then
      local nl = sql:find("\n", i + 2, true)
      if nl then i = nl + 1 else i = n + 1; break end
    elseif sql:sub(i, i + 1) == "/*" then
      local ed = sql:find("*/", i + 2, true)
      if ed then i = ed + 2 else i = n + 1; break end
    else
      break
    end
  end
  return sql:sub(i)
end

function _M.strip_comments(sql)
  return _M.strip_leading_sql_comments(sql)
end

-- Dolar etiketini dene: $...$ seklinde, etiket [A-Za-z_][A-Za-z0-9_]* veya bos
local function try_dollar_tag(sql, pos)
  if sql:sub(pos, pos) ~= "$" then return nil end
  local n = #sql
  local j = pos + 1
  while j <= n do
    local c = sql:sub(j, j)
    if c == "$" then
      return sql:sub(pos, j), j
    elseif c:match("[A-Za-z0-9_]") then
      j = j + 1
    else
      return nil
    end
  end
  return nil
end

-- sql_statements: noktali virgul disindaki ifadeleri ayir (literal ve yorum disinda)
function _M.sql_statements(sql)
  if type(sql) ~= "string" then return {} end
  local stmts = {}
  local buf = {}
  local n = #sql
  local i = 1
  local in_single = false
  local in_double = false
  local in_line = false
  local in_block = false
  local dollar_tag = nil

  while i <= n do
    local c = sql:sub(i, i)
    local two = sql:sub(i, i + 1)
    if dollar_tag then
      -- dolar quoting icinde
      if sql:sub(i, i + #dollar_tag - 1) == dollar_tag then
        for k = 1, #dollar_tag do buf[#buf + 1] = sql:sub(i + k - 1, i + k - 1) end
        i = i + #dollar_tag
        dollar_tag = nil
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    elseif in_line then
      buf[#buf + 1] = c
      if c == "\n" then in_line = false end
      i = i + 1
    elseif in_block then
      buf[#buf + 1] = c
      if two == "*/" then
        buf[#buf + 1] = sql:sub(i + 1, i + 1)
        i = i + 2
        in_block = false
      else
        i = i + 1
      end
    elseif in_single then
      buf[#buf + 1] = c
      if c == "'" then
        if sql:sub(i + 1, i + 1) == "'" then
          buf[#buf + 1] = "'"
          i = i + 2
        else
          in_single = false
          i = i + 1
        end
      else
        i = i + 1
      end
    elseif in_double then
      buf[#buf + 1] = c
      if c == '"' then
        if sql:sub(i + 1, i + 1) == '"' then
          buf[#buf + 1] = '"'
          i = i + 2
        else
          in_double = false
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      if two == "--" then
        in_line = true
        buf[#buf + 1] = c
        buf[#buf + 1] = sql:sub(i + 1, i + 1)
        i = i + 2
      elseif two == "/*" then
        in_block = true
        buf[#buf + 1] = c
        buf[#buf + 1] = sql:sub(i + 1, i + 1)
        i = i + 2
      elseif c == "'" then
        in_single = true
        buf[#buf + 1] = c
        i = i + 1
      elseif c == '"' then
        in_double = true
        buf[#buf + 1] = c
        i = i + 1
      elseif c == "$" then
        local tag, epos = try_dollar_tag(sql, i)
        if tag then
          dollar_tag = tag
          for k = 1, #tag do buf[#buf + 1] = sql:sub(i + k - 1, i + k - 1) end
          i = epos + 1
        else
          buf[#buf + 1] = c
          i = i + 1
        end
      elseif c == ";" then
        -- ifade sonu
        local stmt = table.concat(buf)
        if stmt:match("%S") then stmts[#stmts + 1] = stmt end
        buf = {}
        i = i + 1
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
  end
  local last = table.concat(buf)
  if last:match("%S") then stmts[#stmts + 1] = last end
  return stmts
end

function _M.count_statements(sql)
  return #_M.sql_statements(sql)
end

function _M.has_multiple(sql)
  return _M.count_statements(sql) > 1
end

-- Literal ve yorumlari boslukla degistir, boylece anahtar kelime aramasi guvenli olur
local function stripped_for_search(sql)
  if type(sql) ~= "string" then return "" end
  local out = {}
  local n = #sql
  local i = 1
  local in_single = false
  local in_double = false
  local in_line = false
  local in_block = false
  local dollar_tag = nil
  while i <= n do
    local c = sql:sub(i, i)
    local two = sql:sub(i, i + 1)
    if dollar_tag then
      local tag_len = #dollar_tag
      if sql:sub(i, i + tag_len - 1) == dollar_tag then
        for _ = 1, tag_len do out[#out + 1] = " " end
        i = i + tag_len
        dollar_tag = nil
      else
        out[#out + 1] = " "
        i = i + 1
      end
    elseif in_line then
      out[#out + 1] = " "
      if c == "\n" then out[#out] = "\n"; in_line = false end
      i = i + 1
    elseif in_block then
      out[#out + 1] = " "
      if two == "*/" then out[#out + 1] = " "; i = i + 2; in_block = false else i = i + 1 end
    elseif in_single then
      out[#out + 1] = " "
      if c == "'" then
        if sql:sub(i + 1, i + 1) == "'" then out[#out + 1] = " "; i = i + 2 else in_single = false; i = i + 1 end
      else
        i = i + 1
      end
    elseif in_double then
      out[#out + 1] = " "
      if c == '"' then
        if sql:sub(i + 1, i + 1) == '"' then out[#out + 1] = " "; i = i + 2 else in_double = false; i = i + 1 end
      else
        i = i + 1
      end
    else
      if two == "--" then in_line = true; out[#out + 1] = " "; out[#out + 1] = " "; i = i + 2
      elseif two == "/*" then in_block = true; out[#out + 1] = " "; out[#out + 1] = " "; i = i + 2
      elseif c == "'" then in_single = true; out[#out + 1] = " "; i = i + 1
      elseif c == '"' then in_double = true; out[#out + 1] = " "; i = i + 1
      elseif c == "$" then
        local tag, epos = try_dollar_tag(sql, i)
        if tag then dollar_tag = tag; for _ = 1, #tag do out[#out + 1] = " " end; i = epos + 1
        else out[#out + 1] = c; i = i + 1 end
      else
        out[#out + 1] = c; i = i + 1
      end
    end
  end
  return table.concat(out)
end

_M._stripped_for_search = stripped_for_search

function _M.contains_keyword_outside_literals(sql, keyword)
  if not sql or not keyword then return false end
  local cleaned = stripped_for_search(sql):lower()
  local kw = keyword:lower()
  -- kelime siniri: \b benzeri
  local pattern = "%f[%w_]" .. kw:gsub("%%", "%%%%") .. "%f[^%w_]"
  return cleaned:find(pattern) ~= nil
end

function _M.contains_any_keyword_outside_literals(sql, keywords)
  for _, kw in ipairs(keywords) do
    if _M.contains_keyword_outside_literals(sql, kw) then return true end
  end
  return false
end

-- şema degistiren ifade mi?
local SCHEMA_KEYWORDS = { "alter", "create", "drop", "comment", "grant", "revoke", "reindex", "truncate" }
function _M.changes_schema(sql)
  if type(sql) ~= "string" then return false end
  for _, kw in ipairs(SCHEMA_KEYWORDS) do
    if _M.contains_keyword_outside_literals(sql, kw) then return true end
  end
  return false
end

-- transaction control var mi?
local TX_KEYWORDS = { "begin", "commit", "rollback", "start" }
function _M.contains_transaction_control(sql)
  for _, kw in ipairs(TX_KEYWORDS) do
    if _M.contains_keyword_outside_literals(sql, kw) then return true end
  end
  return false
end

-- bos sonuc beklenir mi? SELECT/WITH/SHOW/EXPLAIN/VALUES/RETURNING
function _M.expects_rows_when_empty(sql)
  local s = _M.strip_leading_sql_comments(sql):lower()
  s = s:match("^%s*(.-)%s*$") or ""
  if s:match("^select%s") or s:match("^select%(") or s == "select" then return true end
  if s:match("^with%s") then return true end
  if s:match("^show%s") then return true end
  if s:match("^explain%s") then return true end
  if s:match("^values%s") or s:match("^values%(") then return true end
  if s:lower():find("returning") then return true end
  return false
end

function _M.lead_keyword(sql)
  local s = _M.strip_leading_sql_comments(sql):lower():match("^%s*(%a+)")
  return s
end

function _M.safe_row_limit(limit, default, max)
  local cfg_ok, cfg = pcall(require, "config")
  local d = default
  local m = max
  if cfg_ok and cfg and cfg.get then
    local c = cfg.get()
    if c and c.query then
      d = d or c.query.row_limit_default or 1000
      m = m or c.query.row_limit_max or 50000
    end
  end
  d = d or 1000
  m = m or 50000
  local n = tonumber(limit) or d
  if n < 1 then n = 1 end
  if n > m then n = m end
  return math.floor(n)
end

-- custom_where icin guvenlik (codd kurallari + parantez dengesi): ifade "(...)" icine konur,
-- yorum/parametre/kapanmamis parantez ile WHERE'den kacip baska SQL eklenemez
-- allowed_columns: opsiyonel set { [kolon_adi]=true } ; verilirse bilinmeyen kolon/fonksiyon reddedilir
local FORBIDDEN_EXPR = {
  "select", "insert", "update", "delete", "drop", "truncate", "create", "alter",
  "grant", "revoke", "comment", "reindex", "vacuum", "cluster", "copy", "union",
  "into", "exec", "execute", "declare", "fetch", "with", "having", "window",
}
local SQL_KEYWORDS = {
  ["and"]=true, ["or"]=true, ["not"]=true, ["is"]=true, ["null"]=true, ["like"]=true, ["ilike"]=true,
  ["between"]=true, ["in"]=true, ["exists"]=true, ["true"]=true, ["false"]=true,
}

function _M.validate_expression(expr, allowed_columns)
  if type(expr) ~= "string" or expr:match("^%s*$") then return false, "bos ifade" end
  if #expr > 5000 then return false, "en fazla 5000 karakter" end
  if expr:find(";") then return false, "noktali virgul iceremez" end
  if expr:find("--", 1, true) or expr:find("/*", 1, true) then return false, "yorum iceremez" end
  if expr:find("%$%d") then return false, "parametre ($n) iceremez" end
  if _M.contains_transaction_control(expr) then return false, "transaction deyimi iceremez" end
  -- yasak kelimeler (literal/yorum disinda)
  for _, kw in ipairs(FORBIDDEN_EXPR) do
    if _M.contains_keyword_outside_literals(expr, kw) then return false, kw .. " iceremez" end
  end
  -- pg_ prefix (pg_sleep vb.)
  if stripped_for_search(expr):lower():find("pg_%w+") then return false, "pg_ iceremez" end
  -- parantez dengesi ve derinlik limiti (10)
  local depth, max_depth = 0, 0
  for ch in expr:gsub("'[^']*'", ""):gmatch("[()]") do
    depth = depth + (ch == "(" and 1 or -1)
    if depth > max_depth then max_depth = depth end
    if max_depth > 10 then return false, "parantez derinligi fazla" end
    if depth < 0 then return false, "parantezler dengesiz" end
  end
  if depth ~= 0 then return false, "parantezler dengesiz" end
  -- kolon allow-list (verildiyse): identifier'lar izinli kolon veya SQL anahtar kelimesi olmali
  -- fonksiyon adi (arkasinda '(') ise kolon kontrolunden muaf (pg_ zaten yukarida reddedildi)
  if allowed_columns and next(allowed_columns) ~= nil then
    local allowed_lower = {}
    for k in pairs(allowed_columns) do allowed_lower[k:lower()] = true end
    local stripped = _M._stripped_for_search(expr):lower()
    local pos = 1
    while true do
      local s, e, tok = stripped:find("([%a_][%w_]*)", pos)
      if not s then break end
      -- arkasi '(' mi? (bosluklari atla)
      local after = stripped:sub(e + 1):match("^%s*(.)")
      local is_func = after == "("
      if not is_func and not SQL_KEYWORDS[tok] and not allowed_lower[tok] then
        local is_forbidden = false
        for _, fk in ipairs(FORBIDDEN_EXPR) do if fk == tok then is_forbidden = true; break end end
        if not is_forbidden then
          return false, "bilinmeyen kolon: " .. tok
        end
      end
      pos = e + 1
    end
  end
  return true
end

return _M
