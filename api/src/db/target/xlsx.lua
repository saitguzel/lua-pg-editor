-- Minimal .xlsx (OOXML) üretici: tek sayfa, kalın başlık, sayılar sayı hücresi, gerisi inline string.
-- Zip sıkıştırmasız (STORE) — CRC için ngx.crc32_long; ek bağımlılık yok.
-- ponytail: bellek içi ve sıkıştırmasız; export satır limiti (50k) ile sınırlı. Büyürse zlib/streaming yazar.
local cjson = require("cjson.safe")

local _M = {}

local floor = math.floor

local function u16(n) return string.char(n % 256, floor(n / 256) % 256) end
local function u32(n)
  return string.char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

-- files: { { name, data }, ... } → zip bayt dizisi
function _M.zip(files)
  local out, central, offset = {}, {}, 0
  -- 0x0800: dosya adı UTF-8; tarih 1980-01-01 00:00 (0x0021)
  for _, f in ipairs(files) do
    local crc, size = ngx.crc32_long(f.data), #f.data
    local common = u16(20) .. u16(0x0800) .. u16(0) .. u16(0) .. u16(0x21) .. u32(crc) .. u32(size) .. u32(size)
      .. u16(#f.name)
    local lh = "PK\3\4" .. common .. u16(0) .. f.name
    out[#out + 1] = lh
    out[#out + 1] = f.data
    central[#central + 1] = "PK\1\2" .. u16(20) .. common .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
      .. u32(offset) .. f.name
    offset = offset + #lh + size
  end
  local cd = table.concat(central)
  out[#out + 1] = cd
  out[#out + 1] = "PK\5\6" .. u16(0) .. u16(0) .. u16(#files) .. u16(#files) .. u32(#cd) .. u32(offset) .. u16(0)
  return table.concat(out)
end

-- XML 1.0'da geçersiz kontrol karakterleri atılır (Excel dosyayı bozuk sayar)
local XML_ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }
local function xml_escape(s)
  return (s:gsub("[%z\1-\8\11\12\14-\31]", ""):gsub('[&<>"]', XML_ESC))
end
_M.xml_escape = xml_escape

-- 0 → A, 25 → Z, 26 → AA
local function col_name(i)
  local s = ""
  i = i + 1
  while i > 0 do
    local r = (i - 1) % 26
    s = string.char(65 + r) .. s
    i = floor((i - 1) / 26)
  end
  return s
end
_M.col_name = col_name

local function cell(ref, v, style)
  local st = style and (' s="' .. style .. '"') or ""
  if v == nil or v == cjson.null or v == ngx.null then return "" end
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
    return '<c r="' .. ref .. '"' .. st .. '><v>' .. string.format("%.17g", v) .. "</v></c>"
  end
  if type(v) == "boolean" then
    return '<c r="' .. ref .. '"' .. st .. ' t="b"><v>' .. (v and "1" or "0") .. "</v></c>"
  end
  local s = type(v) == "table" and (cjson.encode(v) or "") or tostring(v)
  -- Excel hücre sınırı 32767 karakter
  if #s > 32767 then s = s:sub(1, 32767) end
  return '<c r="' .. ref .. '"' .. st .. ' t="inlineStr"><is><t xml:space="preserve">' .. xml_escape(s)
    .. "</t></is></c>"
end

local function sheet_xml(cols, rows, include_header)
  local buf = { '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    .. '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    .. (include_header ~= false and '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2"'
      .. ' activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' or "")
    .. "<sheetData>" }
  local r = 0
  local function row(values, style)
    r = r + 1
    local cells = {}
    for j = 1, #cols do cells[j] = cell(col_name(j - 1) .. r, values[j], style) end
    buf[#buf + 1] = '<row r="' .. r .. '">' .. table.concat(cells) .. "</row>"
  end
  if include_header ~= false then row(cols, 1) end
  for _, v in ipairs(rows) do row(v) end
  buf[#buf + 1] = "</sheetData></worksheet>"
  return table.concat(buf)
end

local XML_HEAD = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
local OOXML = "http://schemas.openxmlformats.org/"
local STATIC = {
  content_types = XML_HEAD .. '<Types xmlns="' .. OOXML .. 'package/2006/content-types">'
    .. '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    .. '<Default Extension="xml" ContentType="application/xml"/>'
    .. '<Override PartName="/xl/workbook.xml" '
    .. 'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    .. '<Override PartName="/xl/worksheets/sheet1.xml" '
    .. 'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    .. '<Override PartName="/xl/styles.xml" '
    .. 'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    .. "</Types>",
  rels = XML_HEAD .. '<Relationships xmlns="' .. OOXML .. 'package/2006/relationships">'
    .. '<Relationship Id="rId1" Type="' .. OOXML .. 'officeDocument/2006/relationships/officeDocument" '
    .. 'Target="xl/workbook.xml"/></Relationships>',
  workbook_rels = XML_HEAD .. '<Relationships xmlns="' .. OOXML .. 'package/2006/relationships">'
    .. '<Relationship Id="rId1" Type="' .. OOXML .. 'officeDocument/2006/relationships/worksheet" '
    .. 'Target="worksheets/sheet1.xml"/>'
    .. '<Relationship Id="rId2" Type="' .. OOXML .. 'officeDocument/2006/relationships/styles" '
    .. 'Target="styles.xml"/></Relationships>',
  -- stil 0: normal, stil 1: kalın başlık
  styles = XML_HEAD .. '<styleSheet xmlns="' .. OOXML .. 'spreadsheetml/2006/main">'
    .. '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
    .. '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
    .. '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    .. '<fill><patternFill patternType="gray125"/></fill></fills>'
    .. '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    .. '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    .. '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    .. '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
    .. "</styleSheet>",
}

-- cols: { "ad", ... }, rows: { { v1, v2, ... }, ... } → .xlsx baytları
function _M.build(cols, rows, opts)
  opts = opts or {}
  local name = (opts.sheet_name or "Sonuc"):gsub("[%[%]%*%?/\\:]", "_"):sub(1, 31)
  local workbook = XML_HEAD .. '<workbook xmlns="' .. OOXML .. 'spreadsheetml/2006/main" '
    .. 'xmlns:r="' .. OOXML .. 'officeDocument/2006/relationships">'
    .. '<sheets><sheet name="' .. xml_escape(name) .. '" sheetId="1" r:id="rId1"/></sheets></workbook>'
  return _M.zip({
    { name = "[Content_Types].xml", data = STATIC.content_types },
    { name = "_rels/.rels", data = STATIC.rels },
    { name = "xl/workbook.xml", data = workbook },
    { name = "xl/_rels/workbook.xml.rels", data = STATIC.workbook_rels },
    { name = "xl/styles.xml", data = STATIC.styles },
    { name = "xl/worksheets/sheet1.xml", data = sheet_xml(cols, rows, opts.include_header) },
  })
end

return _M
