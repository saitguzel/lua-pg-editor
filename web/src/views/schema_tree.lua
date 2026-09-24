-- F26: Nesne gezgini saf yardımcıları — kategori/tür tabloları, hızlı filtreler, sayaç biçimi, düğüm anahtarı.
-- DOM/istek yok; schema_sidebar ve structure kullanır, spec ile test edilir.
local _M = {}

-- Kategori sırası API ile aynı (faz-25 OBJECT_CATEGORIES); label spec'teki İngilizce adlar.
_M.CATEGORIES = {
  { id = "tables", label = "Tables" },
  { id = "views", label = "Views" },
  { id = "matviews", label = "Materialized Views" },
  { id = "foreign_tables", label = "Foreign Tables" },
  { id = "functions", label = "Functions" },
  { id = "procedures", label = "Procedures" },
  { id = "sequences", label = "Sequences" },
  { id = "types", label = "Types" },
  { id = "domains", label = "Domains" },
  { id = "extensions", label = "Extensions" },
  { id = "operators", label = "Operators" },
  { id = "collations", label = "Collations" },
  { id = "fts_configs", label = "FTS Configurations" },
  { id = "fts_dicts", label = "FTS Dictionaries" },
  { id = "fts_parsers", label = "FTS Parsers" },
  { id = "fts_templates", label = "FTS Templates" },
}
-- trigger'lar katalogdan (GET /completion) gelir; ağaçta kategori gibi gösterilir
_M.TRIGGER_CATEGORY = { id = "triggers", label = "Triggers" }

_M.QUICK_FILTERS = {
  { id = "all", label = "Tümü" },
  { id = "tables", label = "Sadece tablolar", categories = { tables = true, foreign_tables = true } },
  { id = "views", label = "View'lar", categories = { views = true, matviews = true } },
  { id = "routines", label = "Fonksiyonlar", categories = { functions = true, procedures = true, triggers = true } },
  { id = "other", label = "Diğer", categories = { sequences = true, types = true, domains = true, extensions = true,
    operators = true, collations = true, fts_configs = true, fts_dicts = true, fts_parsers = true,
    fts_templates = true } },
}

_M.RELATION_KINDS = { table = true, partitioned = true, view = true, matview = true, foreign = true }
_M.EXPANDABLE_KINDS = { table = true, partitioned = true, foreign = true } -- yapı alt düğümleri
_M.ROUTINE_KINDS = { ["function"] = true, aggregate = true, window = true, procedure = true }

_M.ICON = { table = "table", partitioned = "table", view = "eye", matview = "eye", foreign = "plug",
  ["function"] = "function", aggregate = "function", window = "function", procedure = "procedure", trigger = "zap",
  sequence = "sequence", type_base = "type", type_composite = "type", type_enum = "type", type_range = "type",
  domain = "shield", extension = "extension", operator = "operator", collation = "collation",
  fts_config = "fts", fts_dict = "fts", fts_parser = "fts", fts_template = "fts" }
_M.ICON_COLOR = { table = "text-sky-600", partitioned = "text-sky-600", view = "text-emerald-600",
  matview = "text-emerald-600", foreign = "text-slate-500", ["function"] = "text-violet-600",
  aggregate = "text-violet-600", window = "text-violet-600", procedure = "text-amber-600", trigger = "text-rose-600",
  sequence = "text-orange-600", type_base = "text-teal-600", type_composite = "text-teal-600",
  type_enum = "text-teal-600", type_range = "text-teal-600", domain = "text-teal-600", extension = "text-fuchsia-600",
  operator = "text-slate-500", collation = "text-slate-500", fts_config = "text-lime-600", fts_dict = "text-lime-600",
  fts_parser = "text-lime-600", fts_template = "text-lime-600" }
_M.KIND_LABEL = { table = "tablo", partitioned = "bölümlü tablo", view = "view", matview = "materialized view",
  foreign = "foreign table", ["function"] = "fonksiyon", aggregate = "aggregate fonksiyonu",
  window = "window fonksiyonu", procedure = "prosedür", trigger = "trigger", sequence = "sequence",
  type_base = "temel tip", type_composite = "composite tip", type_enum = "enum tipi", type_range = "range tipi",
  domain = "domain", extension = "extension", operator = "operatör", collation = "collation",
  fts_config = "FTS yapılandırması", fts_dict = "FTS sözlüğü", fts_parser = "FTS ayrıştırıcısı",
  fts_template = "FTS şablonu" }

-- tablo alt düğümleri: structure yanıtındaki dizi alanı → etiket
_M.CHILD_SECTIONS = {
  { key = "columns", label = "Columns", tab = "columns" },
  { key = "indexes", label = "Indexes", tab = "indexes" },
  { key = "constraints", label = "Constraints", tab = "constraints" },
  { key = "triggers", label = "Triggers", tab = "triggers" },
  { key = "rules", label = "Rules", tab = "rules" },
  { key = "policies", label = "Policies", tab = "policies" },
}

function _M.format_count(label, n) return label .. " (" .. tostring(n or 0) .. ")" end

-- "all" her zaman; diğerleri kategori kümesine bakar
function _M.quick_filter_matches(filter_id, category)
  if filter_id == nil or filter_id == "all" then return true end
  for _, f in ipairs(_M.QUICK_FILTERS) do
    if f.id == filter_id then return f.categories ~= nil and f.categories[category] == true end
  end
  return true
end

-- düğüm anahtarı: şema → "public", kategori → "public:tables", nesne → "public.orders"
function _M.node_key(schema, category, name)
  if name then return schema .. "." .. name end
  if category then return schema .. ":" .. category end
  return schema
end

-- ad (ve varsa tablo adı) üzerinde büyük/küçük harf duyarsız alt dize eşleşmesi
function _M.filter_items(items, needle)
  needle = (needle or ""):lower()
  if needle == "" then return items end
  local out = {}
  for _, it in ipairs(items or {}) do
    local name = (it.name or ""):lower()
    if name:find(needle, 1, true) or (it.table and it.table:lower():find(needle, 1, true)) then out[#out + 1] = it end
  end
  return out
end

-- sunucu kind → menü/route için rutin türü (aggregate/window da /routines/function altında)
function _M.routine_kind(kind)
  if kind == "procedure" then return "procedure" end
  if _M.ROUTINE_KINDS[kind] then return "function" end
  return nil
end

return _M
