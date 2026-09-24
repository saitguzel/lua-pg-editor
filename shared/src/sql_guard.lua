-- F27: Yıkıcı SQL tespiti (istemci onay penceresi için). Lua 5.1 + 5.4, bağımlılık yok.
-- strip: literal ('..', ".."), yorum (--, /* */) ve $tag$..$tag$ gövdelerini aynı uzunlukta boşluğa çevirir;
-- böylece anahtar kelime araması ve ';' bölme güvenli olur.
local _M = {}

local function dollar_tag(sql, i)
  local tag = sql:match("^%$[%a_][%w_]*%$", i) or sql:match("^%$%$", i)
  return tag
end

function _M.strip(sql)
  if type(sql) ~= "string" then return "" end
  local out, n, i, mode, tag = {}, #sql, 1, nil, nil
  while i <= n do
    local c, two = sql:sub(i, i), sql:sub(i, i + 1)
    if mode == "line" then
      out[#out + 1] = c == "\n" and "\n" or " "
      if c == "\n" then mode = nil end
      i = i + 1
    elseif mode == "block" then
      if two == "*/" then out[#out + 1] = "  "; i = i + 2; mode = nil else out[#out + 1] = " "; i = i + 1 end
    elseif mode == "single" or mode == "double" then
      local q = mode == "single" and "'" or '"'
      if c == q and sql:sub(i + 1, i + 1) == q then out[#out + 1] = "  "; i = i + 2
      elseif c == q then out[#out + 1] = " "; i = i + 1; mode = nil
      else out[#out + 1] = " "; i = i + 1 end
    elseif mode == "dollar" then
      if sql:sub(i, i + #tag - 1) == tag then out[#out + 1] = string.rep(" ", #tag); i = i + #tag; mode = nil
      else out[#out + 1] = c == "\n" and "\n" or " "; i = i + 1 end
    else
      local t = c == "$" and dollar_tag(sql, i) or nil
      if two == "--" then mode = "line"; out[#out + 1] = "  "; i = i + 2
      elseif two == "/*" then mode = "block"; out[#out + 1] = "  "; i = i + 2
      elseif c == "'" then mode = "single"; out[#out + 1] = " "; i = i + 1
      elseif c == '"' then mode = "double"; out[#out + 1] = " "; i = i + 1
      elseif t then mode = "dollar"; tag = t; out[#out + 1] = string.rep(" ", #t); i = i + #t
      else out[#out + 1] = c; i = i + 1 end
    end
  end
  return table.concat(out)
end

-- Literal/yorum dışı ';' ile böler; her ifade { text = ham metin, clean = temizlenmiş metin }
function _M.statements(sql)
  local clean = _M.strip(sql)
  local out, start = {}, 1
  for i = 1, #clean + 1 do
    if i > #clean or clean:sub(i, i) == ";" then
      local c = clean:sub(start, i - 1)
      if c:match("%S") then out[#out + 1] = { text = sql:sub(start, i - 1), clean = c } end
      start = i + 1
    end
  end
  return out
end

-- Onay isteyen ifade: DROP, TRUNCATE, WHERE'siz DELETE, ALTER … DROP. Yoksa nil.
-- Dönüş: { kind = "DROP"|"TRUNCATE"|"DELETE"|"ALTER_DROP", statement = ilk 80 karakter }
function _M.destructive_kind(sql)
  for _, st in ipairs(_M.statements(sql)) do
    local head = st.clean:upper():gsub("^%s+", "")
    local kind
    if head:match("^DROP%f[%W]") then kind = "DROP"
    elseif head:match("^TRUNCATE%f[%W]") then kind = "TRUNCATE"
    elseif head:match("^DELETE%f[%W]") and not head:match("%f[%w]WHERE%f[%W]") then kind = "DELETE"
    elseif head:match("^ALTER%f[%W]") and head:match("%f[%w]DROP%f[%W]") then kind = "ALTER_DROP" end
    if kind then
      local text = st.text:gsub("^%s+", ""):gsub("%s+", " ")
      if #text > 80 then text = text:sub(1, 79) .. "…" end
      return { kind = kind, statement = text }
    end
  end
  return nil
end

return _M
