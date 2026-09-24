-- Backend ve frontend'in paylastigi enum'lar ve RBAC sayfa anahtarlari.
-- Degerler veritabani ENUM'lari (001 migration) ile birebir ayni olmalidir.
local _M = {}

_M.ROLES = { "admin", "editor" }

-- Sira UI'daki (RBAC matrisi) sutun sirasidir
_M.PAGES = {
  "dashboard",
  "connections.list", "connections.create",
  "query.execute", "query.history", "query.ai",
  "schema.browser", "table.browser", "table.edit",
  "structure.view", "object.actions", "script.generate", "export.csv",
  "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
}

_M.PAGE_META = {
  dashboard = { label = "Gosterge Paneli", group = "genel" },
  ["connections.list"] = { label = "Baglantilar", group = "connections" },
  ["connections.create"] = { label = "Baglanti Yonetimi", group = "connections" },
  ["query.execute"] = { label = "Sorgu Calistir", group = "query" },
  ["query.history"] = { label = "Sorgu Gecmisi", group = "query" },
  ["query.ai"] = { label = "AI ile Sorgu Olustur", group = "query" },
  ["schema.browser"] = { label = "Sema Tarayici", group = "browse" },
  ["table.browser"] = { label = "Tablo Tarayici", group = "browse" },
  ["table.edit"] = { label = "Satir Duzenleme", group = "browse" },
  ["structure.view"] = { label = "Yapi Inceleme", group = "browse" },
  ["object.actions"] = { label = "Obje Eylemleri", group = "admin" },
  ["script.generate"] = { label = "Script Uretimi", group = "browse" },
  ["export.csv"] = { label = "CSV Disa Aktar", group = "query" },
  ["users.list"] = { label = "Kullanici Listesi", group = "admin" },
  ["users.create"] = { label = "Kullanici Yonetimi", group = "admin" },
  ["rbac.matrix"] = { label = "Yetki Matrisi", group = "admin" },
  ["audit.logs"] = { label = "Denetim Kayitlari", group = "admin" },
  settings = { label = "Ayarlar", group = "admin" },
}

_M.DEFAULT_PERMISSIONS = {
  admin = { ["*"] = true },
  editor = {
    dashboard = true,
    ["connections.list"] = true, ["connections.create"] = true,
    ["query.execute"] = true, ["query.history"] = true, ["query.ai"] = true,
    ["schema.browser"] = true, ["table.browser"] = true, ["table.edit"] = true,
    ["structure.view"] = true, ["script.generate"] = true, ["export.csv"] = true,
  },
}

_M.LOCKED_PERMISSIONS = { { role = "admin", page_key = "rbac.matrix" } }

_M.AUDIT_ACTIONS = {
  "auth.login.success", "auth.login.failure", "auth.logout", "auth.token.refresh",
  "auth.password.reset.request", "auth.password.reset.success",
  "connection.create", "connection.update", "connection.delete", "connection.test",
  "query.execute", "query.export.csv",
  "table.row.create", "table.row.update", "table.row.delete", "table.row.duplicate",
  "object.rename", "object.truncate", "object.drop", "script.generate",
  "structure.rename", "structure.drop", "object.trigger.toggle",
  "snippet.create", "snippet.update", "snippet.delete",
  "ai.settings.update", "ai.models.test", "ai.generate",
  "user.create", "user.update", "user.delete",
  "rbac.matrix.update", "access.denied",
}

_M.FILTER_OPS = { "=", "!=", ">", ">=", "<", "<=", "LIKE", "ILIKE", "IS NULL", "IS NOT NULL" }
-- F25: nesne gezgini kategorileri (sira UI sirasidir) ve tum nesne turleri (database_object.kind)
_M.OBJECT_CATEGORIES = {
  "tables", "views", "matviews", "foreign_tables", "sequences",
  "functions", "procedures", "types", "domains", "extensions",
  "operators", "collations", "fts_configs", "fts_dicts", "fts_parsers", "fts_templates",
}
_M.OBJECT_KINDS = { "table", "view", "matview", "partitioned", "foreign", "sequence",
  "function", "aggregate", "window", "procedure", "type_base", "type_composite", "type_enum", "type_range",
  "domain", "extension", "operator", "collation", "fts_config", "fts_dict", "fts_parser", "fts_template" }
-- iliski (pg_class) olan turler: tarayici/yapi sekmeleri bunlar icin
_M.RELATION_KINDS = { "table", "view", "matview", "partitioned", "foreign" }
_M.SCRIPT_KINDS = { "select", "insert", "update", "delete", "create", "drop", "truncate" }

-- codd: kolon tipine gore filtre operatorleri (frontend secenekleri ve backend dogrulamasi ayni tablo)
local NULL_OPS = { "IS NULL", "IS NOT NULL" }
local function ops(list)
  local out = {}
  for _, o in ipairs(list) do out[#out + 1] = o end
  for _, o in ipairs(NULL_OPS) do out[#out + 1] = o end
  return out
end
_M.FILTER_OPS_BY_GROUP = {
  boolean = ops({ "=", "!=" }),
  numeric = ops({ "=", "!=", ">", ">=", "<", "<=" }),
  datetime = ops({ "=", "!=", ">", ">=", "<", "<=" }),
  text = ops({ "=", "!=", "LIKE", "ILIKE" }),
  json = ops({}),
  binary = ops({}),
  other = ops({ "=", "!=" }),
}

-- udt_name / data_type → tip grubu. codd gibi uuid, dizi ve enum metin sayilir (LIKE ::text uzerinden)
function _M.type_group(udt, data_type, is_enum)
  local t = (udt or data_type or ""):lower()
  if is_enum or t:sub(1, 1) == "_" or (data_type or ""):upper() == "ARRAY" then return "text" end
  if t == "bool" or t == "boolean" then return "boolean" end
  if t == "bytea" then return "binary" end
  if t == "json" or t == "jsonb" then return "json" end
  if t:match("^int[248]?$") or t:match("^float[48]$") or t == "numeric" or t == "money"
    or t:match("^integer") or t:match("^smallint") or t:match("^bigint") or t:match("^double") or t:match("^real") then
    return "numeric"
  end
  if t == "date" or t:match("^timestamp") or t:match("^time") then return "datetime" end
  if t:match("char") or t == "text" or t == "uuid" or t == "name" or t == "citext" then return "text" end
  return "other"
end
_M.COLUMN_TYPE_GROUPS = { "boolean", "binary", "datetime", "json", "numeric", "text", "other" }
_M.DEFAULT_PAGE_SIZE = 100
_M.PAGE_SIZE_OPTIONS = { 50, 100, 250, 500 }

local function to_set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

_M.ROLE_SET = to_set(_M.ROLES)
_M.PAGE_SET = to_set(_M.PAGES)
_M.AUDIT_SET = to_set(_M.AUDIT_ACTIONS)
_M.FILTER_OP_SET = to_set(_M.FILTER_OPS)
_M.OBJECT_KIND_SET = to_set(_M.OBJECT_KINDS)
_M.OBJECT_CATEGORY_SET = to_set(_M.OBJECT_CATEGORIES)
_M.RELATION_KIND_SET = to_set(_M.RELATION_KINDS)
_M.SCRIPT_KIND_SET = to_set(_M.SCRIPT_KINDS)

function _M.is_member(set, value)
  return set[value] == true
end

function _M.default_permission(role, page_key)
  local perm = _M.DEFAULT_PERMISSIONS[role]
  if not perm then return false end
  if perm["*"] then return true end
  return perm[page_key] == true
end

function _M.default_matrix()
  local permissions = {}
  for _, role in ipairs(_M.ROLES) do
    for _, page in ipairs(_M.PAGES) do
      permissions[#permissions + 1] = {
        role = role,
        page_key = page,
        can_access = _M.default_permission(role, page),
      }
    end
  end
  return { permissions = permissions }
end

function _M.is_locked(role, page_key)
  for _, entry in ipairs(_M.LOCKED_PERMISSIONS) do
    if entry.role == role and entry.page_key == page_key then
      return true
    end
  end
  return false
end

return _M
