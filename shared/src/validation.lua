-- Şema tabanlı doğrulayıcı — backend (LuaJIT) ve frontend (Lua 5.4) ortak.
-- 5.1 ve 5.4 alt kümesi uyumlu (pg-editor)
local _M = {}

_M.NULL = {}

local function utf8_len(s)
  local len = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 128 or b >= 192 then len = len + 1 end
  end
  return len
end

_M.utf8_len = utf8_len

function _M.is_uuid(s)
  if type(s) ~= "string" then return false end
  return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = #t
  if n == 0 then
    return next(t) == nil
  end
  for i = 1, n do if t[i] == nil then return false end end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then return false end
  end
  return true
end

local function copy_rule(rule, extra)
  local c = {}
  for k, v in pairs(rule) do c[k] = v end
  for k, v in pairs(extra) do c[k] = v end
  return c
end

function _M.optional(rule)
  return copy_rule(rule, { optional = true })
end

function _M.nullable(rule)
  return copy_rule(rule, { nullable = true })
end

function _M.string(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local pat = opts.pattern
  local do_trim = opts.trim
  local do_lower = opts.lower
  return {
    kind = "string",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "metin olmalı" } end
      local s = val
      if do_trim then s = s:match("^%s*(.-)%s*$") or "" end
      if do_lower then s = s:lower() end
      local len = utf8_len(s)
      if min and len < min then return false, { "en az " .. tostring(min) .. " karakter" } end
      if max and len > max then return false, { "en fazla " .. tostring(max) .. " karakter" } end
      if pat and not s:match(pat) then return false, { "geçersiz biçim" } end
      return true, s
    end
  }
end

function _M.integer(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  return {
    kind = "integer",
    optional = false,
    nullable = false,
    check = function(val)
      local n = val
      if type(n) == "string" then
        n = tonumber(n)
        if n == nil then return false, { "tamsayı olmalı" } end
      end
      if type(n) ~= "number" then return false, { "tamsayı olmalı" } end
      if n ~= math.floor(n) then return false, { "tamsayı olmalı" } end
      n = math.floor(n)
      if min and n < min then return false, { "en az " .. tostring(min) } end
      if max and n > max then return false, { "en fazla " .. tostring(max) } end
      return true, n
    end
  }
end

function _M.boolean()
  return {
    kind = "boolean",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "boolean" then return false, { "true/false olmalı" } end
      return true, val
    end
  }
end

function _M.enum(list)
  local set = {}
  for _, v in ipairs(list) do set[v] = true end
  local allowed = table.concat(list, ", ")
  return {
    kind = "enum",
    optional = false,
    nullable = false,
    check = function(val)
      if not set[val] then
        return false, { "geçersiz değer: " .. tostring(val) .. " (izinli: " .. allowed .. ")" }
      end
      return true, val
    end
  }
end

function _M.email()
  return {
    kind = "email",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "geçerli bir e-posta olmalı" } end
      local s = val:match("^%s*(.-)%s*$") or ""
      s = s:lower()
      if #s == 0 or #s > 255 then return false, { "geçerli bir e-posta olmalı" } end
      if not s:match("^[%w%.%%%+%-_]+@[%w%.%-]+%.%a%a+$") then
        return false, { "geçerli bir e-posta olmalı" }
      end
      return true, s
    end
  }
end

function _M.uuid()
  return {
    kind = "uuid",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "geçerli bir UUID olmalı" } end
      if not _M.is_uuid(val) then return false, { "geçerli bir UUID olmalı" } end
      return true, val
    end
  }
end

function _M.datetime()
  return {
    kind = "datetime",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "ISO-8601 tarih/saat olmalı" } end
      local y, mo, d, h, mi, s, tz = val:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
      if not y or not (tz == "Z" or tz:match("^[%+%-]%d%d:%d%d$")) then
        return false, { "ISO-8601 tarih/saat olmalı" }
      end
      y = tonumber(y); mo = tonumber(mo); d = tonumber(d)
      h = tonumber(h); mi = tonumber(mi); s = tonumber(s)
      local mdays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
      if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then mdays[2] = 29 end
      if mo < 1 or mo > 12 or d < 1 or d > mdays[mo] or h > 23 or mi > 59 or s > 59 then
        return false, { "ISO-8601 tarih/saat olmalı" }
      end
      return true, val
    end
  }
end

function _M.password()
  return {
    kind = "password",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "en az 8 karakter" } end
      local msgs = {}
      if #val < 8 then msgs[#msgs+1] = "en az 8 karakter" end
      if #val > 128 then msgs[#msgs+1] = "en fazla 128 karakter" end
      if not val:match("%u") then msgs[#msgs+1] = "en az bir büyük harf içermeli" end
      if not val:match("%l") then msgs[#msgs+1] = "en az bir küçük harf içermeli" end
      if not val:match("%d") then msgs[#msgs+1] = "en az bir rakam içermeli" end
      if #msgs > 0 then return false, msgs end
      return true, val
    end
  }
end

function _M.array_of(rule, opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local unique = opts.unique
  return {
    kind = "array_of",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "table" or not is_array(val) then
        return false, { "dizi olmalı" }
      end
      if min and #val < min then return false, { "en az " .. tostring(min) .. " eleman" } end
      if max and #val > max then return false, { "en fazla " .. tostring(max) .. " eleman" } end
      if unique then
        local seen = {}
        for _, v in ipairs(val) do
          if seen[v] then return false, { "tekrarlı değer" } end
          seen[v] = true
        end
      end
      local clean = {}
      local errors = {}
      local has_err = false
      for i, elem in ipairs(val) do
        if rule._fields then
          local c2, e2 = _M.validate(rule, elem)
          if c2 then
            clean[i] = c2
          else
            has_err = true
            local fk = next(e2)
            local msg = fk and e2[fk][1] or "geçersiz"
            errors[i] = "[" .. tostring(i) .. "]." .. tostring(fk) .. ": " .. msg
          end
        else
          local ok, out = rule.check(elem)
          if ok then clean[i] = out else
            has_err = true
            local msg = out[1] or "geçersiz"
            errors[i] = "[" .. tostring(i) .. "]: " .. msg
          end
        end
      end
      if has_err then
        local flat = {}
        for i = 1, #val do if errors[i] then flat[#flat+1] = errors[i] end end
        return false, flat
      end
      return true, clean
    end
  }
end

function _M.query_int(opts)
  opts = opts or {}
  local min = opts.min
  local max = opts.max
  local def = opts.default
  return {
    kind = "query_int",
    optional = false,
    nullable = false,
    check = function(val)
      if val == nil and def ~= nil then return true, def end
      local n = tonumber(val)
      if n == nil then return false, { "tamsayı olmalı" } end
      if n ~= math.floor(n) then return false, { "tamsayı olmalı" } end
      n = math.floor(n)
      if min and n < min then return false, { "en az " .. tostring(min) } end
      if max and n > max then return false, { "en fazla " .. tostring(max) } end
      return true, n
    end
  }
end

function _M.schema(fields, opts)
  opts = opts or {}
  local strict = opts.strict
  if strict == nil then strict = true end
  return {
    _fields = fields,
    _strict = strict,
  }
end

function _M.validate(schema, input, opts)
  opts = opts or {}
  local null_values = opts.null_values
  local strict = opts.strict
  if strict == nil then strict = schema._strict end

  if type(input) ~= "table" then
    return nil, { _ = { "nesne olmalı" } }
  end

  local errors = {}
  local clean = {}

  if strict then
    for k in pairs(input) do
      if schema._fields[k] == nil then
        errors[k] = { "bilinmeyen alan" }
      end
    end
  end

  for name, rule in pairs(schema._fields) do
    local val = input[name]
    local is_null_sentinel = false
    if val ~= nil then
      if null_values then
        for _, nv in ipairs(null_values) do
          if val == nv then
            val = _M.NULL
            is_null_sentinel = true
            break
          end
        end
      end
      if not is_null_sentinel and rule.nullable and type(val) == "userdata" then
        val = _M.NULL
      end
    end

    if val == nil then
      if not rule.optional then
        if not errors[name] then
          errors[name] = { "zorunlu alan" }
        end
      end
    elseif val == _M.NULL then
      if not rule.nullable then
        errors[name] = { "boş olamaz" }
      else
        clean[name] = _M.NULL
      end
    else
      if rule._fields then
        local c2, e2 = _M.validate(rule, val)
        if c2 then
          clean[name] = c2
        else
          errors[name] = e2
          if e2 and next(e2) then
            local fk = next(e2)
            errors[name] = { fk .. ": " .. e2[fk][1] }
          end
        end
      else
        local ok, out = rule.check(val)
        if ok then
          clean[name] = out
        else
          errors[name] = out
        end
      end
    end
  end

  if next(errors) ~= nil then
    return nil, errors
  end
  return clean, nil
end

function _M.validate_partial(schema, input, opts)
  if type(input) ~= "table" then
    return nil, { _ = { "nesne olmalı" } }
  end
  if next(input) == nil then
    return nil, { _ = { "en az bir alan gönderilmeli" } }
  end
  local fields = {}
  for k, rule in pairs(schema._fields) do
    fields[k] = copy_rule(rule, { optional = true })
  end
  local partial = { _fields = fields, _strict = schema._strict }
  return _M.validate(partial, input, opts)
end

-- PG-Editor ozeli yardimcilar
function _M.host()
  return {
    kind = "host",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "host metin olmali" } end
      local s = val:match("^%s*(.-)%s*$") or ""
      if #s == 0 then return false, { "host zorunlu" } end
      if #s > 255 then return false, { "en fazla 255 karakter" } end
      if s:sub(1,1) == "/" then
        if not s:match("^/[%w%/_%.%-]+$") then return false, { "gecersiz unix socket yolu" } end
        return true, s
      end
      if not s:match("^[%w%.%-]+$") then return false, { "gecersiz host" } end
      return true, s
    end
  }
end

function _M.port()
  return _M.integer({ min = 1, max = 65535 })
end

function _M.sql_identifier()
  local reserved = { select=true, from=true, where=true, table=true, view=true, index=true }
  return {
    kind = "sql_identifier",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "tanimlayici metin olmali" } end
      local s = val:match("^%s*(.-)%s*$") or ""
      if #s == 0 then return false, { "zorunlu alan" } end
      if #s > 63 then return false, { "en fazla 63 karakter" } end
      if not s:match("^[%a_][%w_]*$") then return false, { "gecersiz tanimlayici" } end
      if reserved[s:lower()] then return false, { "rezerve kelime" } end
      return true, s
    end
  }
end

-- PostgreSQL nesne/DB/kullanici adi: 1-63 bayt, NUL yok. Adlar SQL'e her zaman quote_ident ile girer,
-- bu yuzden tire, nokta, bosluk, Unicode ve rezerve kelimeler gecerlidir (codd ile ayni).
function _M.pg_name()
  return {
    kind = "pg_name",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" or val == "" then return false, { "zorunlu alan" } end
      if #val > 63 then return false, { "en fazla 63 bayt" } end
      if val:find("%z") then return false, { "gecersiz karakter" } end
      return true, val
    end
  }
end

function _M.safe_sql()
  return {
    kind = "safe_sql",
    optional = false,
    nullable = false,
    check = function(val)
      if type(val) ~= "string" then return false, { "metin olmali" } end
      if val:find(";") then return false, { "noktali virgul iceremez" } end
      if val:lower():find("drop%s+table") then return false, { "DROP iceremez" } end
      if #val > 5000 then return false, { "en fazla 5000 karakter" } end
      return true, val
    end
  }
end

-- Hazır şemalar (frontend ve backend ortak)
local function init_schemas()
  local ok, types = pcall(require, "pg_shared.types")
  if not ok then
    types = {
      ROLES = { "admin", "editor" },
      PAGES = {
        "dashboard", "connections.list", "connections.create",
        "query.execute", "query.history", "schema.browser", "table.browser", "table.edit",
        "structure.view", "object.actions", "script.generate", "export.csv",
        "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
      },
    }
  end

  _M.schemas = {}

  _M.schemas.login = _M.schema({
    email = _M.email(),
    password = _M.string({ min = 1, max = 128 }),
  })

  _M.schemas.forgot_password = _M.schema({
    email = _M.email(),
  })

  _M.schemas.reset_password = _M.schema({
    token = _M.string({ min = 64, max = 64, pattern = "^%x+$" }),
    new_password = _M.password(),
  })

  _M.schemas.refresh = _M.schema({
    refresh_token = _M.string({ min = 1, max = 2048 }),
  })

  _M.schemas.logout = _M.schema({
    refresh_token = _M.optional(_M.string({ min = 1, max = 2048 })),
  })

  _M.schemas.user_create = _M.schema({
    email = _M.email(),
    password = _M.password(),
    full_name = _M.optional(_M.nullable(_M.string({ min = 1, max = 255, trim = true }))),
    role = _M.enum(types.ROLES),
    is_active = _M.optional(_M.boolean()),
  })

  _M.schemas.user_update = _M.schema({
    email = _M.optional(_M.email()),
    full_name = _M.optional(_M.nullable(_M.string({ min = 1, max = 255, trim = true }))),
    role = _M.optional(_M.enum(types.ROLES)),
    is_active = _M.optional(_M.boolean()),
    password = _M.optional(_M.password()),
  })

  _M.schemas.rbac_cell = _M.schema({
    can_access = _M.boolean(),
  })

  _M.schemas.rbac_matrix = _M.schema({
    permissions = _M.array_of(_M.schema({
      role = _M.enum(types.ROLES),
      page_key = _M.enum(types.PAGES),
      can_access = _M.boolean(),
    }, { strict = true }), { min = 1 }),
  })

  _M.schemas.user_list_query = _M.schema({
    q = _M.optional(_M.string({ max = 100 })),
    role = _M.optional(_M.enum(types.ROLES)),
    is_active = _M.optional(_M.enum({ "true", "false" })),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
    sort = _M.optional(_M.string({ max = 100 })),
  })

  _M.schemas.audit_query = _M.schema({
    action = _M.optional(_M.string({ max = 100 })),
    status = _M.optional(_M.enum({ "success", "failure" })),
    entity_type = _M.optional(_M.string({ max = 50 })),
    entity_id = _M.optional(_M.string({ max = 100 })),
    user_id = _M.optional(_M.uuid()),
    user_email = _M.optional(_M.string({ max = 255 })),
    ip = _M.optional(_M.string({ max = 45, pattern = "^[%x%.:]+$" })),
    from = _M.optional(_M.datetime()),
    to = _M.optional(_M.datetime()),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
  })

  -- PG-editor connection semasi
  _M.schemas.connection_create = _M.schema({
    name = _M.string({ min = 1, max = 100, trim = true }),
    host = _M.host(),
    port = _M.port(),
    database = _M.pg_name(),
    username = _M.pg_name(),
    password = _M.optional(_M.string({ max = 255 })),
    save_password = _M.optional(_M.boolean()),
    ssh_enabled = _M.optional(_M.boolean()),
    ssh_host = _M.optional(_M.nullable(_M.string({ max = 255 }))),
    ssh_port = _M.optional(_M.nullable(_M.integer({ min = 1, max = 65535 }))),
    ssh_username = _M.optional(_M.nullable(_M.string({ max = 255 }))),
    -- web sunucusunda SSH agent yok: parola ya da ozel anahtar (icerigi, sifreli saklanir)
    ssh_auth_method = _M.optional(_M.nullable(_M.enum({ "password", "private_key" }))),
    ssh_private_key_path = _M.optional(_M.nullable(_M.string({ max = 500 }))),
    ssh_save_secret = _M.optional(_M.boolean()),
    ssh_host_key_fingerprint = _M.optional(_M.nullable(_M.string({ max = 500 }))),
    ssh_secret = _M.optional(_M.nullable(_M.string({ max = 16384 }))),
    ssh_passphrase = _M.optional(_M.nullable(_M.string({ max = 255 }))),
    ssl_mode = _M.optional(_M.enum({ "disable", "prefer", "require" })),
  })

  _M.schemas.pagination = _M.schema({
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
    search = _M.optional(_M.string({ max = 100 })),
    q = _M.optional(_M.string({ max = 100 })),
  })

  _M.schemas.connection_list_query = _M.schema({
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 20 })),
    search = _M.optional(_M.string({ max = 100 })),
    q = _M.optional(_M.string({ max = 100 })),
  }, { strict = false })

  _M.schemas.object_ref = _M.schema({
    schema = _M.pg_name(),
    name = _M.pg_name(),
  })

  _M.schemas.object_rename = _M.schema({
    new_name = _M.pg_name(),
  })

  -- F25: sema referansi ve kategori bazli nesne listesi (?category=&q=&limit=&offset=)
  _M.schemas.schema_ref = _M.schema({
    schema = _M.pg_name(),
    database = _M.optional(_M.pg_name()),
  })
  _M.schemas.schema_objects_query = _M.schema({
    schema = _M.pg_name(),
    database = _M.optional(_M.pg_name()),
    category = _M.optional(_M.enum(types.OBJECT_CATEGORIES or {})),
    q = _M.optional(_M.string({ min = 1, max = 64 })),
    limit = _M.optional(_M.query_int({ min = 1, max = 500, default = 200 })),
    offset = _M.optional(_M.query_int({ min = 0, default = 0 })),
  })

  _M.schemas.query_execute = _M.schema({
    connection_id = _M.uuid(),
    database = _M.optional(_M.pg_name()),
    sql = _M.string({ min = 1, max = 102400 }),
    row_limit = _M.optional(_M.integer({ min = 1, max = 50000 })),
    run_id = _M.optional(_M.string({ min = 1, max = 64 })),
  })

  _M.schemas.query_cancel = _M.schema({
    run_id = _M.string({ min = 1, max = 64 }),
  })

  _M.schemas.query_history_query = _M.schema({
    connection_id = _M.optional(_M.uuid()),
    database = _M.optional(_M.pg_name()),
    limit = _M.optional(_M.query_int({ min = 1, max = 100, default = 50 })),
    offset = _M.optional(_M.query_int({ min = 0, default = 0 })),
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 100, default = 50 })),
    q = _M.optional(_M.string({ max = 200 })),
  }, { strict = false })

  -- AI ayarları (yalnızca yönetici): base_url http(s); api_key yalnızca yazılır, geri okunmaz
  local model_id = _M.string({ min = 1, max = 200 })
  _M.schemas.ai_settings_update = _M.schema({
    enabled = _M.optional(_M.boolean()),
    base_url = _M.optional(_M.string({ max = 300, trim = true, pattern = "^https?:%/%/[^%s]+$" })),
    api_key = _M.optional(_M.string({ min = 1, max = 500, trim = true })),
    clear_api_key = _M.optional(_M.boolean()),
    default_model = _M.optional(model_id),
    visible = _M.optional(_M.array_of(model_id, { max = 1000 })),
    excluded = _M.optional(_M.array_of(model_id, { max = 1000 })),
  }, { strict = true })
  _M.schemas.ai_model_test = _M.schema({ model = model_id }, { strict = false })
  _M.schemas.ai_test_all = _M.schema({
    prune = _M.optional(_M.boolean()),
    only_visible = _M.optional(_M.boolean()),
  }, { strict = false })
  _M.schemas.ai_generate = _M.schema({
    connection_id = _M.uuid(),
    database = _M.optional(_M.pg_name()),
    prompt = _M.string({ min = 1, max = 4000, trim = true }),
    model = _M.optional(model_id),
    sql = _M.optional(_M.string({ max = 102400 })),
  }, { strict = false })

  -- taslak: önek harf/rakam/_ (editörde yazıp Tab ile açılır)
  _M.schemas.snippet = _M.schema({
    name = _M.string({ min = 1, max = 100, trim = true }),
    prefix = _M.optional(_M.nullable(_M.string({ max = 32, trim = true, pattern = "^[%w_]*$" }))),
    description = _M.optional(_M.nullable(_M.string({ max = 500, trim = true }))),
    body = _M.string({ min = 1, max = 65536 }),
  }, { strict = false })

  _M.schemas.table_rows_query = _M.schema({
    page = _M.optional(_M.query_int({ min = 1, default = 1 })),
    per_page = _M.optional(_M.query_int({ min = 1, max = 500, default = 100 })),
    sort = _M.optional(_M.string({ max = 100 })),
    filters = _M.optional(_M.string({ max = 5000 })),
    custom_where = _M.optional(_M.safe_sql()),
    database = _M.optional(_M.pg_name()),
  }, { strict = false })

  _M.schemas.table_row_create = _M.schema({
    values = _M.optional(_M.schema({}, { strict = false })),
    database = _M.optional(_M.pg_name()),
  }, { strict = false })

  _M.schemas.table_row_update = _M.schema({
    values = _M.schema({}, { strict = false }),
  }, { strict = false })

  _M.schemas.csv_export = _M.schema({
    connection_id = _M.uuid(),
    database = _M.optional(_M.pg_name()),
    sql = _M.string({ min = 1, max = 102400 }),
    delimiter = _M.optional(_M.enum({ ",", ";", "\t", "|" })),
    include_header = _M.optional(_M.boolean()),
    limit = _M.optional(_M.integer({ min = 1, max = 50000 })),
    format = _M.optional(_M.enum({ "csv", "json", "xlsx" })),
  }, { strict = false })

  _M.schemas.csv_table_export = _M.schema({
    delimiter = _M.optional(_M.enum({ ",", ";", "\t", "|" })),
    include_header = _M.optional(_M.boolean()),
    columns = _M.optional(_M.array_of(_M.pg_name(), { max = 100 })),
    filters = _M.optional(_M.string({ max = 5000 })),
    custom_where = _M.optional(_M.safe_sql()),
    database = _M.optional(_M.pg_name()),
    format = _M.optional(_M.enum({ "csv", "json", "xlsx" })),
  }, { strict = false })
end

init_schemas()

return _M
