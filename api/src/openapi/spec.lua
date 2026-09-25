-- OpenAPI 3.1 spec: Lua tablosu, shared enum'lardan uretilir (pg-editor F13)
local cjson = require("cjson.safe")
local types = require("pg_shared.types")
local protocol = require("pg_shared.protocol")
local config = require("config")

local _M = {}
local EMPTY = cjson.empty_array

local function ref(name)
  return { ["$ref"] = "#/components/schemas/" .. name }
end

local function json_body(schema_name, example)
  return { required = true, content = { ["application/json"] = { schema = ref(schema_name), example = example } } }
end

local function resp(description, schema, ctype)
  return { description = description, content = { [ctype or "application/json"] = { schema = schema } } }
end

local function data_of(schema)
  return { type = "object", required = { "data" }, properties = { data = schema } }
end

local function page_of(item_schema_name)
  return {
    type = "object", required = { "data", "meta" },
    properties = { data = { type = "array", items = ref(item_schema_name) }, meta = ref("PaginationMeta") },
  }
end

local function qp(name)
  return { ["$ref"] = "#/components/parameters/" .. name }
end

local function op(o)
  o.responses = o.responses or {}
  local pk = o["x-page-key"]
  if pk then
    o.description = (o.description and (o.description .. "\n\n") or "") .. "Yetki: " .. pk
  end
  if o.errors then
    for _, code in ipairs(o.errors) do
      local status = tostring(protocol.http_status(code))
      if not o.responses[status] then
        o.responses[status] = { ["$ref"] = "#/components/responses/" .. code }
      end
    end
    o.errors = nil
  end
  if not o.responses["500"] then o.responses["500"] = { ["$ref"] = "#/components/responses/INTERNAL_ERROR" } end
  if not o.responses["503"] and o.tags and o.tags[1] ~= "system" then
    o.responses["503"] = { ["$ref"] = "#/components/responses/DB_UNAVAILABLE" }
  end
  return o
end

local TAGS = { type = "array", maxItems = 20, uniqueItems = true, items = { type = "string", minLength = 1, maxLength = 50 } }
local NSTR = { type = { "string", "null" } }

local function components()
  local schemas = {
    Error = {
      type = "object", required = { "code", "message" },
      properties = {
        code = { type = "string", enum = protocol.CODE_LIST },
        message = { type = "string" },
        details = { type = { "object", "null" } },
        req_id = ref("Uuid"),
      },
    },
    ErrorResponse = { type = "object", required = { "error" }, properties = { error = ref("Error") } },
    PaginationMeta = {
      type = "object", required = { "page", "per_page", "total", "total_pages" },
      properties = {
        page = { type = "integer", minimum = 1 },
        per_page = { type = "integer", minimum = 1, maximum = 100 },
        total = { type = "integer", minimum = 0 },
        total_pages = { type = "integer", minimum = 0 },
      },
    },
    Uuid = { type = "string", format = "uuid", pattern = "^[0-9a-fA-F-]{36}$" },
    Timestamp = { type = "string", format = "date-time" },
    Role = { type = "string", enum = types.ROLES },
    PageKey = { type = "string", enum = types.PAGES },
    ScriptKind = { type = "string", enum = types.SCRIPT_KINDS },
    User = {
      type = "object",
      required = { "id", "email", "role", "is_active", "created_at", "updated_at" },
      properties = {
        id = ref("Uuid"), email = { type = "string", format = "email" },
        full_name = { type = { "string", "null" }, maxLength = 255 },
        role = ref("Role"), is_active = { type = "boolean" },
        last_login_at = { type = { "string", "null" }, format = "date-time" },
        created_at = ref("Timestamp"), updated_at = ref("Timestamp"),
      },
    },
    Permissions = {
      type = "object",
      propertyNames = ref("PageKey"),
      additionalProperties = { type = "boolean" },
      example = { dashboard = true, ["connections.list"] = true },
    },
    Me = {
      type = "object", required = { "user", "permissions" },
      properties = { user = ref("User"), permissions = ref("Permissions") },
    },
    UserCreate = {
      type = "object", required = { "email", "password", "role" },
      properties = {
        email = { type = "string", format = "email", maxLength = 255 },
        password = { type = "string", minLength = 8, maxLength = 128, writeOnly = true, example = "Ornek123!" },
        full_name = { type = { "string", "null" }, maxLength = 255 },
        role = ref("Role"), is_active = { type = "boolean" },
      },
    },
    UserUpdate = {
      type = "object", description = "Tum alanlar opsiyonel; gonderilmeyen alan degismez",
      properties = {
        email = { type = "string", format = "email" },
        full_name = NSTR,
        role = ref("Role"), is_active = { type = "boolean" },
        password = { type = "string", minLength = 8, maxLength = 128, writeOnly = true },
      },
    },
    Connection = {
      type = "object",
      required = { "id", "user_id", "name", "host", "port", "database", "username", "created_at", "updated_at" },
      properties = {
        id = ref("Uuid"), user_id = ref("Uuid"), name = { type = "string", maxLength = 100 },
        host = { type = "string" }, port = { type = "integer", minimum = 1, maximum = 65535 },
        database = { type = "string" }, username = { type = "string" },
        has_password = { type = "boolean" }, save_password = { type = "boolean" },
        ssh_enabled = { type = "boolean" }, ssh_host = NSTR, ssh_port = { type = { "integer", "null" } },
        ssh_username = NSTR, ssh_auth_method = NSTR, ssh_private_key_path = NSTR,
        ssh_save_secret = { type = "boolean" }, ssh_host_key_fingerprint = NSTR,
        last_tested_at = NSTR, last_test_success = { type = { "boolean", "null" } },
        last_test_latency_ms = { type = { "integer", "null" } },
        created_at = ref("Timestamp"), updated_at = ref("Timestamp"),
      },
    },
    ConnectionCreate = {
      type = "object", required = { "name", "host", "port", "database", "username" },
      properties = {
        name = { type = "string", minLength = 1, maxLength = 100 },
        host = { type = "string" }, port = { type = "integer", minimum = 1, maximum = 65535 },
        database = { type = "string", minLength = 1, maxLength = 63 },
        username = { type = "string", minLength = 1, maxLength = 63 },
        password = { type = "string", maxLength = 255 }, save_password = { type = "boolean" },
        ssh_enabled = { type = "boolean" }, ssh_host = NSTR, ssh_port = { type = { "integer", "null" }, minimum = 1, maximum = 65535 },
        ssh_username = NSTR, ssh_auth_method = { type = { "string", "null" }, enum = { "password", "private_key", "agent", cjson.null } },
        ssh_private_key_path = NSTR, ssh_save_secret = { type = "boolean" }, ssh_host_key_fingerprint = NSTR,
      },
      additionalProperties = false,
    },
    ConnectionTestResult = {
      type = "object",
      properties = {
        success = { type = "boolean" }, latency_ms = { type = "integer" }, pg_version = { type = "string" },
        read_only = { type = "boolean", description = "default_transaction_read_only = on (F30 RO rozeti)" },
      },
    },
    DatabaseObject = {
      type = "object",
      properties = {
        schema = { type = "string" }, name = { type = "string" }, kind = { type = "string", enum = types.OBJECT_KINDS },
        extra = { type = { "string", "null" }, description = "Kisa aciklama: fonksiyon imzasi, surum, temel tip..." },
      },
    },
    CategoryCount = {
      type = "object",
      properties = { category = { type = "string", enum = types.OBJECT_CATEGORIES }, count = { type = "integer" } },
    },
    ObjectListMeta = {
      type = "object",
      properties = { total = { type = "integer" }, limit = { type = "integer" }, offset = { type = "integer" },
        has_more = { type = "boolean" } },
    },
    SchemaList = { type = "array", items = { type = "string" } },
    TableColumn = {
      type = "object",
      properties = {
        name = { type = "string" }, display_type = { type = "string" }, type_name = { type = "string" },
        type_group = { type = "string", enum = { "boolean", "binary", "datetime", "json", "numeric", "text", "other" } },
        is_array = { type = "boolean" }, is_range = { type = "boolean" }, is_nullable = { type = "boolean" },
        is_primary_key = { type = "boolean" }, has_default = { type = "boolean" },
        is_identity = { type = "boolean" }, is_generated = { type = "boolean" },
        ordinal_position = { type = "integer" },
      },
    },
    TableStructure = {
      type = "object",
      properties = {
        object = ref("DatabaseObject"),
        columns = { type = "array", items = ref("TableColumn") },
        indexes = { type = "array", items = { type = "object" } },
        constraints = { type = "array", items = { type = "object" } },
        foreign_keys = { type = "array", items = { type = "object" } },
        triggers = { type = "array", items = { type = "object" } },
        rules = { type = "array", items = { type = "object", properties = { name = { type = "string" },
          event = { type = "string" }, is_instead = { type = "boolean" }, def = { type = "string" } } } },
        policies = { type = "array", items = { type = "object", properties = { name = { type = "string" },
          command = { type = "string" }, permissive = { type = "boolean" },
          roles = { type = "array", items = { type = "string" } },
          using_expr = { type = { "string", "null" } }, check_expr = { type = { "string", "null" } } } } },
        detail = { type = { "object", "null" }, description = "Iliski olmayan nesne (sequence, type_*, domain, ...) detayi" },
        size_bytes = { type = { "integer", "null" } },
      },
    },
    QueryRequest = {
      type = "object", required = { "connection_id", "sql" },
      properties = {
        connection_id = ref("Uuid"), database = { type = "string" },
        sql = { type = "string", minLength = 1, maxLength = 102400 },
        row_limit = { type = "integer", minimum = 1, maximum = 50000 },
        run_id = { type = "string", maxLength = 64, description = "POST /query/cancel icin istemci kimligi" },
        confirm = { type = "boolean", description = "Yikici sorgu onayi (DROP/TRUNCATE/DELETE WHERE'siz)" },
      },
    },
    QueryResult = {
      type = "object",
      properties = {
        columns = { type = "array", items = { type = "string" } },
        column_types = { type = "array", items = { type = "string" },
          description = "pgmoon tip adi: number, int8, numeric, boolean, json, bytea_hex, date, timestamp, timestamptz, array_*, string" },
        rows = { type = "array", items = { type = "array", items = {} } },
        row_count = { type = "integer" }, truncated = { type = "boolean" },
        duration_ms = { type = "number" }, command = { type = "string" },
      },
    },
    QueryHistory = {
      type = "object",
      properties = {
        id = { type = "integer" }, user_id = ref("Uuid"), connection_id = ref("Uuid"),
        database = { type = "string" }, sql = { type = "string" },
        row_count = { type = "integer" }, duration_ms = { type = "integer" },
        truncated = { type = "boolean" }, executed_at = ref("Timestamp"),
      },
    },
    TablePage = {
      type = "object",
      properties = {
        rows = { type = "array", items = { type = "object" } },
        page = { type = "integer" }, per_page = { type = "integer" },
        total = { type = "integer" }, has_next = { type = "boolean" },
        columns = { type = "array", items = ref("TableColumn") },
      },
    },
    RowCreate = {
      type = "object", properties = { values = { type = "object" }, database = { type = "string" } },
    },
    RowUpdate = {
      type = "object", required = { "values" }, properties = { values = { type = "object" } },
    },
    ScriptResult = {
      type = "object", properties = { sql = { type = "string" }, kind = ref("ScriptKind") },
    },
    CompletionItem = {
      type = "object",
      properties = { label = { type = "string" }, kind = { type = "string" }, detail = { type = "string" } },
    },
    LoginRequest = {
      type = "object", required = { "email", "password" },
      properties = { email = { type = "string", format = "email" }, password = { type = "string", maxLength = 128 } },
    },
    TokenPair = {
      type = "object",
      properties = {
        access_token = { type = "string" }, refresh_token = { type = "string" },
        token_type = { type = "string", const = "Bearer" }, expires_in = { type = "integer" },
        refresh_expires_in = { type = "integer" }, user = ref("User"), permissions = ref("Permissions"),
      },
    },
    RefreshRequest = { type = "object", required = { "refresh_token" }, properties = { refresh_token = { type = "string" } } },
    LogoutRequest = { type = "object", properties = { refresh_token = { type = "string" } } },
    ForgotPasswordRequest = { type = "object", required = { "email" }, properties = { email = { type = "string", format = "email" } } },
    ResetPasswordRequest = { type = "object", required = { "token", "new_password" }, properties = {
      token = { type = "string", pattern = "^[0-9a-fA-F]+$" }, new_password = { type = "string", minLength = 8 } } },
    MessageResponse = { type = "object", required = { "data" }, properties = { data = { type = "object", properties = { message = { type = "string" } } } } },
    RbacPage = {
      type = "object", properties = {
        key = { type = "string" }, label = { type = "string" }, group = { type = "string" },
        locked_for = { type = "array", items = { type = "string" } },
      },
    },
    RbacMatrix = {
      type = "object",
      properties = {
        roles = { type = "array", items = ref("Role") },
        pages = { type = "array", items = ref("PageKey") },
        matrix = { type = "object", additionalProperties = { type = "object", additionalProperties = { type = "boolean" } } },
      },
    },
    RbacMatrixUpdate = {
      type = "object",
      properties = {
        permissions = { type = "array", items = { type = "object", required = { "role", "page_key", "can_access" },
          properties = { role = ref("Role"), page_key = ref("PageKey"), can_access = { type = "boolean" } } } },
        matrix = { type = "object", description = "Alternatif format: { admin: { dashboard:true } }" },
      },
      description = "Kismi matris gonderilebilir; eksik hucre degismez (PUT icin tam matris onerilir)",
    },
    RbacCellUpdate = { type = "object", required = { "can_access" }, properties = { can_access = { type = "boolean" } } },
    AuditLog = {
      type = "object",
      properties = {
        id = { type = "integer" }, user_id = NSTR, user_email = NSTR,
        action = { type = "string" }, entity_type = NSTR, entity_id = NSTR,
        old_value = { type = { "object", "null" } }, new_value = { type = { "object", "null" } },
        ip_address = NSTR, user_agent = NSTR,
        status = { type = "string" }, error_message = NSTR, created_at = ref("Timestamp"),
      },
    },
    AuditLogSummary = {
      type = "object",
      properties = {
        id = { type = "integer" }, created_at = ref("Timestamp"), user_email = NSTR,
        action = { type = "string" }, entity_type = NSTR, entity_id = NSTR,
        status = { type = "string" }, ip_address = NSTR, user_agent = NSTR,
      },
    },
    AuditStats = {
      type = "object",
      required = { "range", "total", "by_status", "by_action", "by_day", "top_users", "failed_logins_24h" },
      properties = {
        range = { type = "object", properties = { from = ref("Timestamp"), to = ref("Timestamp") } },
        total = { type = "integer" },
        by_status = { type = "object", properties = { success = { type = "integer" }, failure = { type = "integer" } } },
        by_action = { type = "array", items = { type = "object", properties = { action = { type = "string" }, count = { type = "integer" } } } },
        by_day = { type = "array", items = { type = "object", properties = { day = { type = "string", format = "date" }, count = { type = "integer" } } } },
        top_users = { type = "array", items = { type = "object", properties = { user_email = { type = "string" }, count = { type = "integer" } } } },
        failed_logins_24h = { type = "integer" },
      },
    },
    Health = {
      type = "object",
      properties = { status = { type = "string", enum = { "ok", "degraded" } }, version = { type = "string" }, db = { type = "string" }, uptime_s = { type = "integer" } },
    },
    Readiness = {
      type = "object",
      properties = {
        status = { type = "string", enum = { "ready", "unavailable" } },
        db = { type = "string", enum = { "up", "down" } },
      },
    },
  }
  local parameters = {
    IdPath = { name = "id", ["in"] = "path", required = true, schema = ref("Uuid") },
    ConnectionIdPath = { name = "id", ["in"] = "path", required = true, schema = ref("Uuid"), description = "Bağlantı ID" },
    SchemaPath = { name = "schema", ["in"] = "path", required = true, schema = { type = "string" }, description = "Şema adi" },
    NamePath = { name = "name", ["in"] = "path", required = true, schema = { type = "string" }, description = "Tablo/view adi" },
    TablePath = { name = "table", ["in"] = "path", required = true, schema = { type = "string" }, description = "Tablo adi" },
    RidPath = { name = "rid", ["in"] = "path", required = true, schema = { type = "string" }, description = "Satır kimligi (PK degerleri)" },
    AuditIdPath = { name = "id", ["in"] = "path", required = true, schema = { type = "integer", minimum = 1 } },
    Page = { name = "page", ["in"] = "query", schema = { type = "integer", minimum = 1, default = 1 } },
    PerPage = { name = "per_page", ["in"] = "query", schema = { type = "integer", minimum = 1, maximum = 100, default = 20 } },
    PerPage100 = { name = "per_page", ["in"] = "query", schema = { type = "integer", minimum = 1, maximum = 100, default = 100 } },
    Sort = { name = "sort", ["in"] = "query", schema = { type = "string" }, description = "Endpoint bazli whitelist" },
    Search = { name = "search", ["in"] = "query", schema = { type = "string", maxLength = 100 }, description = "ILIKE arama" },
    Q = { name = "q", ["in"] = "query", schema = { type = "string", maxLength = 100 }, description = "Metin aramasi (ILIKE)" },
    From = { name = "from", ["in"] = "query", schema = { type = "string", format = "date-time" }, description = "Varsayilan: to - 7 gun; from-to en fazla 90 gun" },
    To = { name = "to", ["in"] = "query", schema = { type = "string", format = "date-time" }, description = "Varsayilan: simdi" },
    UserIdQuery = { name = "user_id", ["in"] = "query", schema = ref("Uuid"), description = "Yalnizca admin icin anlamli" },
    RoleQuery = { name = "role", ["in"] = "query", schema = ref("Role") },
    IsActiveQuery = { name = "is_active", ["in"] = "query", schema = { type = "string", enum = { "true", "false" } } },
    Action = { name = "action", ["in"] = "query", schema = { type = "string", maxLength = 100 }, description = "Tam ad veya onek: auth.*" },
    AuditStatus = { name = "status", ["in"] = "query", schema = { type = "string", enum = { "success", "failure" } } },
    EntityType = { name = "entity_type", ["in"] = "query", schema = { type = "string", maxLength = 50 } },
    EntityId = { name = "entity_id", ["in"] = "query", schema = { type = "string", maxLength = 100 } },
    UserEmail = { name = "user_email", ["in"] = "query", schema = { type = "string", maxLength = 255 } },
    Ip = { name = "ip", ["in"] = "query", schema = { type = "string", maxLength = 45 } },
    DatabaseQuery = { name = "database", ["in"] = "query", schema = { type = "string" }, description = "Hedef DB adi (opsiyonel)" },
    FiltersQuery = { name = "filters", ["in"] = "query", schema = { type = "string" }, description = "JSON filtre dizisi" },
    CustomWhereQuery = { name = "custom_where", ["in"] = "query", schema = { type = "string" }, description = "Guvenli WHERE ifadesi" },
  }
  local responses = {}
  for _, code in ipairs(protocol.CODE_LIST) do
    responses[code] = {
      description = protocol.message(code),
      content = { ["application/json"] = { schema = ref("ErrorResponse"), example = { error = {
        code = code, message = protocol.message(code), req_id = "5b1d9c1e-7f7a-4c1b-9a8e-3f2d8e1c0a11" } } } },
    }
  end
  responses.RATE_LIMITED.headers = { ["Retry-After"] = { schema = { type = "integer" } } }
  local securitySchemes = {
    bearerAuth = { type = "http", scheme = "bearer", bearerFormat = "JWT", description = "POST /auth/login'den alinan access_token" },
  }
  return { schemas = schemas, parameters = parameters, responses = responses, securitySchemes = securitySchemes }
end

local function paths()
  local p = {}
  -- auth
  p["/auth/login"] = {
    post = op({
      tags = { "auth" }, operationId = "login", summary = "Giris yap",
      security = EMPTY,
      requestBody = json_body("LoginRequest", { email = "admin@pgeditor.local", password = "Admin123!" }),
      responses = { ["200"] = resp("Basarili", data_of(ref("TokenPair"))) },
      errors = { "VALIDATION_FAILED", "INVALID_CREDENTIALS", "ACCOUNT_DISABLED", "RATE_LIMITED" },
    }),
  }
  p["/auth/logout"] = {
    post = op({
      tags = { "auth" }, operationId = "logout", summary = "Cikis yap",
      description = "Govde opsiyonel; refresh_token verilirse o da iptal edilir.",
      requestBody = { required = false, content = { ["application/json"] = { schema = ref("LogoutRequest"), example = { refresh_token = "eyJ..." } } } },
      responses = { ["204"] = { description = "Cikis yapıldi" } },
      errors = { "BAD_REQUEST", "VALIDATION_FAILED", "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED" },
    }),
  }
  p["/auth/refresh"] = {
    post = op({
      tags = { "auth" }, operationId = "refreshToken", summary = "Token yenile",
      security = EMPTY,
      requestBody = json_body("RefreshRequest", { refresh_token = "eyJ..." }),
      responses = { ["200"] = resp("Yenilendi", data_of(ref("TokenPair"))) },
      errors = { "VALIDATION_FAILED", "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED", "ACCOUNT_DISABLED" },
    }),
  }
  p["/auth/forgot-password"] = {
    post = op({
      tags = { "auth" }, operationId = "forgotPassword", summary = "Parola sıfırlama istegi",
      security = EMPTY,
      requestBody = json_body("ForgotPasswordRequest", { email = "user@pgeditor.local" }),
      responses = { ["202"] = resp("Istek alindi", ref("MessageResponse")) },
      errors = { "VALIDATION_FAILED", "RATE_LIMITED" },
    }),
  }
  p["/auth/reset-password"] = {
    post = op({
      tags = { "auth" }, operationId = "resetPassword", summary = "Parola sifirla",
      security = EMPTY,
      requestBody = json_body("ResetPasswordRequest", { token = string.rep("a", 64), new_password = "YeniPass123!" }),
      responses = { ["204"] = { description = "Sifirlandi" } },
      errors = { "VALIDATION_FAILED", "RESET_TOKEN_INVALID" },
    }),
  }
  p["/auth/verify-reset-token"] = {
    get = op({
      tags = { "auth" }, operationId = "verifyResetToken", summary = "Sıfırlama token dogrula",
      security = EMPTY,
      parameters = { { name = "token", ["in"] = "query", required = true, schema = { type = "string" } } },
      responses = { ["200"] = resp("Geçerli", data_of({ type = "object", properties = { valid = { type = "boolean" } } })) },
      errors = { "VALIDATION_FAILED", "RESET_TOKEN_INVALID" },
    }),
  }
  p["/auth/me"] = {
    get = op({
      tags = { "auth" }, operationId = "getMe", summary = "Mevcut kullanıcı",
      responses = { ["200"] = resp("Kullanıcı", data_of(ref("Me"))) },
      errors = { "UNAUTHORIZED", "USER_NOT_FOUND" },
    }),
  }
  -- connections
  p["/connections"] = {
    get = op({
      tags = { "connections" }, operationId = "listConnections", summary = "Bağlantılari listele",
      ["x-page-key"] = "connections.list",
      parameters = { qp("Page"), qp("PerPage"), qp("Search"), qp("Q") },
      responses = { ["200"] = resp("Liste", page_of("Connection")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
    post = op({
      tags = { "connections" }, operationId = "createConnection", summary = "Bağlantı oluştur",
      ["x-page-key"] = "connections.create",
      requestBody = json_body("ConnectionCreate", { name = "local", host = "postgres", port = 5432, database = "pgeditor", username = "pgeditor" }),
      responses = { ["201"] = resp("Oluşturuldu", data_of(ref("Connection"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONFLICT" },
    }),
  }
  p["/connections/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "connections" }, operationId = "getConnection", summary = "Bağlantı getir",
      ["x-page-key"] = "connections.list",
      responses = { ["200"] = resp("Bağlantı", data_of(ref("Connection"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND" },
    }),
    put = op({
      tags = { "connections" }, operationId = "updateConnection", summary = "Bağlantı güncelle",
      ["x-page-key"] = "connections.create",
      requestBody = json_body("ConnectionCreate", { name = "local2", host = "postgres", port = 5432, database = "pgeditor", username = "pgeditor" }),
      responses = { ["200"] = resp("Güncellendi", data_of(ref("Connection"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "VALIDATION_FAILED", "CONFLICT" },
    }),
    delete = op({
      tags = { "connections" }, operationId = "deleteConnection", summary = "Bağlantı sil",
      ["x-page-key"] = "connections.create",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND" },
    }),
  }
  p["/connections/{id}/test"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    post = op({
      tags = { "connections" }, operationId = "testConnection", summary = "Bağlantı test et",
      ["x-page-key"] = "connections.create",
      responses = { ["200"] = resp("Test sonucu", data_of(ref("ConnectionTestResult"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  p["/connections/{id}/unlock"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    post = op({
      tags = { "connections" }, operationId = "unlockConnection", summary = "Kaydedilmemis parolayi oturum icin gir",
      ["x-page-key"] = "connections.list",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object",
        required = { "password" }, properties = { password = { type = "string", maxLength = 255 } } } } } },
      responses = { ["200"] = resp("Acildi", data_of({ type = "object", properties = { unlocked = { type = "boolean" } } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  p["/connections/{id}/ssh/host-key"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "connections" }, operationId = "getSshHostKey", summary = "SSH sunucu anahtari parmak izleri (ssh-keyscan)",
      ["x-page-key"] = "connections.create",
      responses = { ["200"] = resp("Parmak izleri", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
    post = op({
      tags = { "connections" }, operationId = "trustSshHostKey", summary = "SSH sunucu anahtarini onayla (TOFU)",
      ["x-page-key"] = "connections.create",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object",
        required = { "fingerprint" }, properties = { fingerprint = { type = "string" } } } } } },
      responses = { ["200"] = resp("Onaylandi", data_of(ref("Connection"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED", "CONFLICT" },
    }),
  }
  p["/connections/{id}/databases"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "connections" }, operationId = "listDatabases", summary = "Veritabanlarini listele",
      ["x-page-key"] = "connections.list",
      responses = { ["200"] = resp("Veritabanlari", data_of({ type = "array", items = { type = "string" } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  p["/connections/{id}/stats"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "connections" }, operationId = "getConnectionStats", summary = "Bağlantı istatistikleri",
      ["x-page-key"] = "dashboard",
      parameters = { qp("DatabaseQuery") },
      responses = { ["200"] = resp("Istatistikler", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  -- schema & structure
  p["/connections/{id}/schemas"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "schema" }, operationId = "listSchemas", summary = "Şemalari listele",
      ["x-page-key"] = "schema.browser",
      parameters = { qp("DatabaseQuery") },
      responses = { ["200"] = resp("Şema listesi", data_of({ type = "array", items = { type = "string" } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  p["/connections/{id}/schemas/{schema}/objects"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" } },
    get = op({
      tags = { "schema" }, operationId = "listObjects",
      summary = "Nesne listele (category verilirse kategori bazli, sayfali; yoksa tablo/view/matview/foreign)",
      ["x-page-key"] = "schema.browser",
      parameters = { qp("DatabaseQuery"),
        { name = "category", ["in"] = "query", schema = { type = "string", enum = types.OBJECT_CATEGORIES } },
        { name = "q", ["in"] = "query", schema = { type = "string", maxLength = 64 }, description = "Ad ile ILIKE" },
        { name = "limit", ["in"] = "query", schema = { type = "integer", minimum = 1, maximum = 500, default = 200 } },
        { name = "offset", ["in"] = "query", schema = { type = "integer", minimum = 0, default = 0 } } },
      responses = { ["200"] = resp("Obje listesi", { type = "object", properties = {
        data = { type = "array", items = ref("DatabaseObject") }, meta = ref("ObjectListMeta") } }) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED", "VALIDATION_FAILED" },
    }),
  }
  p["/connections/{id}/schemas/{schema}/categories"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" } },
    get = op({
      tags = { "schema" }, operationId = "listCategories", summary = "Kategori sayaclari (16 kategori, cache'li)",
      ["x-page-key"] = "schema.browser",
      parameters = { qp("DatabaseQuery") },
      responses = { ["200"] = resp("Sayaclar", data_of({ type = "array", items = ref("CategoryCount") })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED", "VALIDATION_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{name}/structure"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/NamePath" } },
    get = op({
      tags = { "schema" }, operationId = "getStructure",
      summary = "Yapı incele (kolon, index, FK, trigger, rule, policy; iliski disi nesnede detail)",
      ["x-page-key"] = "structure.view",
      parameters = { qp("DatabaseQuery"),
        { name = "kind", ["in"] = "query", schema = { type = "string", enum = types.OBJECT_KINDS },
          description = "Ipucu; tur sunucuda tespit edilir" } },
      responses = { ["200"] = resp("Yapı", data_of(ref("TableStructure"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  p["/connections/{id}/completion"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "schema" }, operationId = "getCompletion", summary = "Otomatik tamamlama katalogu",
      ["x-page-key"] = "schema.browser",
      parameters = { qp("DatabaseQuery") },
      responses = { ["200"] = resp("Katalog", data_of({ type = "array", items = ref("CompletionItem") })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "CONNECTION_FAILED" },
    }),
  }
  -- query
  p["/query/execute"] = {
    post = op({
      tags = { "query" }, operationId = "executeQuery", summary = "SQL çalıştır",
      ["x-page-key"] = "query.execute",
      requestBody = json_body("QueryRequest", { connection_id = "00000000-0000-0000-0000-000000000000", sql = "SELECT 1" }),
      responses = { ["200"] = resp("Sonuc", data_of(ref("QueryResult"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "QUERY_FAILED", "PAYLOAD_TOO_LARGE", "RATE_LIMITED", "DESTRUCTIVE_REQUIRES_CONFIRM" },
    }),
  }
  p["/query/cancel"] = {
    post = op({
      tags = { "query" }, operationId = "cancelQuery", summary = "Calisan sorguyu iptal et (pg_cancel_backend)",
      ["x-page-key"] = "query.execute",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object",
        required = { "run_id" }, properties = { run_id = { type = "string", maxLength = 64 } } } } } },
      responses = { ["200"] = resp("Iptal sonucu", data_of({ type = "object", properties = { cancelled = { type = "boolean" } } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND" },
    }),
  }
  p["/query/history"] = {
    get = op({
      tags = { "query" }, operationId = "listQueryHistory", summary = "Sorgu geçmişi",
      ["x-page-key"] = "query.history",
      parameters = {
        { name = "connection_id", ["in"] = "query", required = false, description = "Yoksa tum bağlantılarin geçmişi", schema = ref("Uuid") },
        qp("DatabaseQuery"), qp("Page"), qp("PerPage"),
        { name = "q", ["in"] = "query", required = false, description = "SQL metninde arama (buyuk/kucuk harf duyarsiz)", schema = { type = "string", maxLength = 200 } },
      },
      responses = { ["200"] = resp("Gecmis", page_of("QueryHistory")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
    delete = op({
      tags = { "query" }, operationId = "deleteQueryHistory", summary = "Sorgu geçmişi sil",
      ["x-page-key"] = "query.history",
      parameters = {
        { name = "connection_id", ["in"] = "query", required = true, schema = ref("Uuid") },
        qp("DatabaseQuery"),
      },
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  -- table browser
  p["/connections/{id}/objects/{schema}/{table}/rows"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/TablePath" } },
    get = op({
      tags = { "table" }, operationId = "listRows", summary = "Satırlari listele (sayfala, filtre, siralama)",
      ["x-page-key"] = "table.browser",
      parameters = { qp("Page"), qp("PerPage100"), qp("Sort"), qp("FiltersQuery"), qp("CustomWhereQuery"), qp("DatabaseQuery") },
      responses = { ["200"] = resp("Satırlar", data_of(ref("TablePage"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED" },
    }),
    post = op({
      tags = { "table" }, operationId = "createRow", summary = "Satır ekle",
      ["x-page-key"] = "table.edit",
      requestBody = json_body("RowCreate", { values = { name = "ornek" } }),
      responses = { ["201"] = resp("Eklendi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED", "QUERY_FAILED" },
    }),
    delete = op({
      tags = { "table" }, operationId = "deleteRows", summary = "Satırlari sil (toplu)",
      ["x-page-key"] = "table.edit",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", properties = { ids = { type = "array", items = { type = "string" } } } } } } },
      responses = { ["200"] = resp("Silindi", data_of({ type = "object", properties = { deleted = { type = "integer" } } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{table}/rows/{rid}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/TablePath" }, { ["$ref"] = "#/components/parameters/RidPath" } },
    patch = op({
      tags = { "table" }, operationId = "updateRow", summary = "Satır güncelle",
      ["x-page-key"] = "table.edit",
      requestBody = json_body("RowUpdate", { values = { name = "yeni" } }),
      responses = { ["200"] = resp("Güncellendi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "ROW_NOT_FOUND", "VALIDATION_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{table}/rows/{rid}/duplicate"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/TablePath" }, { ["$ref"] = "#/components/parameters/RidPath" } },
    post = op({
      tags = { "table" }, operationId = "duplicateRow", summary = "Satıri cogalt",
      ["x-page-key"] = "table.edit",
      responses = { ["201"] = resp("Cogaltildi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "ROW_NOT_FOUND" },
    }),
  }
  -- object actions & script & export
  p["/connections/{id}/objects/{schema}/{name}/rename"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/NamePath" } },
    post = op({
      tags = { "objects" }, operationId = "renameObject", summary = "Obje yeniden adlandir",
      ["x-page-key"] = "object.actions",
      requestBody = json_body("RowUpdate", { values = { new_name = "yeni_ad" } }),
      responses = { ["200"] = resp("Yeniden adlandirildi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED", "QUERY_FAILED" },
    }),
  }
  -- AI ile SQL
  local ai_obj = data_of({ type = "object" })
  local function ai_op(o)
    o.tags = { "ai" }
    o.responses = o.responses or { ["200"] = resp("Tamam", ai_obj) }
    return op(o)
  end
  local ai_admin_errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "AI_NOT_CONFIGURED", "AI_PROVIDER_ERROR", "AI_TIMEOUT" }
  p["/admin/ai/settings"] = {
    get = ai_op({ operationId = "getAiSettings", summary = "AI ayarlari (anahtar yalnizca son 4 karakter)", ["x-page-key"] = "settings",
      errors = { "UNAUTHORIZED", "FORBIDDEN" } }),
    put = ai_op({ operationId = "updateAiSettings", summary = "AI ayarlarini güncelle", ["x-page-key"] = "settings",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", properties = {
        enabled = { type = "boolean" }, base_url = { type = "string", format = "uri" }, api_key = { type = "string", writeOnly = true },
        clear_api_key = { type = "boolean" }, default_model = { type = "string" },
        visible = { type = "array", items = { type = "string" } }, excluded = { type = "array", items = { type = "string" } } } } } } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" } }),
  }
  p["/admin/ai/models/refresh"] = { post = ai_op({ operationId = "refreshAiModels", summary = "Saglayicidan model listesini yenile",
    ["x-page-key"] = "settings", errors = ai_admin_errors }) }
  p["/admin/ai/models/test"] = { post = ai_op({ operationId = "testAiModel", summary = "Tek modeli test et", ["x-page-key"] = "settings",
    requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", required = { "model" },
      properties = { model = { type = "string" } } } } } },
    errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "NOT_FOUND", "AI_NOT_CONFIGURED" } }) }
  p["/admin/ai/models/test-all"] = { post = ai_op({ operationId = "testAllAiModels",
    summary = "Tum modelleri arka planda paralel test et (prune=true: calismayanlari listeden kaldir)", ["x-page-key"] = "settings",
    requestBody = { required = false, content = { ["application/json"] = { schema = { type = "object", properties = {
      prune = { type = "boolean" }, only_visible = { type = "boolean" } } } } } },
    responses = { ["202"] = resp("Is baslatildi", ai_obj) },
    errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONFLICT", "AI_NOT_CONFIGURED" } }) }
  p["/ai/status"] = { get = ai_op({ operationId = "aiStatus", summary = "Sorgu ekrani icin AI durumu ve gorunur modeller",
    ["x-page-key"] = "query.ai", errors = { "UNAUTHORIZED", "FORBIDDEN" } }) }
  p["/ai/generate"] = { post = ai_op({ operationId = "aiGenerate", summary = "Dogal dilden SQL uret / secili SQL'i güncelle (çalıştırmaz)",
    ["x-page-key"] = "query.ai",
    requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", required = { "connection_id", "prompt" },
      properties = { connection_id = ref("Uuid"), database = { type = "string" }, prompt = { type = "string", maxLength = 4000 },
        model = { type = "string", description = "auto ya da gorunur model" }, sql = { type = "string" } } } } } },
    errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "RATE_LIMITED",
      "AI_DISABLED", "AI_NOT_CONFIGURED", "AI_PROVIDER_ERROR", "AI_TIMEOUT" } }) }
  -- taslaklar
  local snippet_schema = { type = "object", required = { "name", "body" }, properties = {
    name = { type = "string", maxLength = 100 }, prefix = { type = { "string", "null" }, maxLength = 32, pattern = "^[A-Za-z0-9_]*$" },
    description = { type = { "string", "null" }, maxLength = 500 }, body = { type = "string", maxLength = 65536 } } }
  local snippet_body = { required = true, content = { ["application/json"] = { schema = snippet_schema } } }
  p["/snippets"] = {
    get = op({
      tags = { "snippets" }, operationId = "listSnippets", summary = "Kullanıcınin taslakları", ["x-page-key"] = "query.execute",
      responses = { ["200"] = resp("Taslaklar", data_of({ type = "array", items = { type = "object" } })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
    post = op({
      tags = { "snippets" }, operationId = "createSnippet", summary = "Taslak oluştur", ["x-page-key"] = "query.execute",
      requestBody = snippet_body,
      responses = { ["201"] = resp("Oluşturuldu", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONFLICT" },
    }),
  }
  p["/snippets/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    put = op({
      tags = { "snippets" }, operationId = "updateSnippet", summary = "Taslak güncelle", ["x-page-key"] = "query.execute",
      requestBody = snippet_body,
      responses = { ["200"] = resp("Güncellendi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "NOT_FOUND", "CONFLICT" },
    }),
    delete = op({
      tags = { "snippets" }, operationId = "deleteSnippet", summary = "Taslak sil", ["x-page-key"] = "query.execute",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND" },
    }),
  }
  -- fonksiyon / prosedür / trigger (oid ile)
  local routine_params = { { ["$ref"] = "#/components/parameters/IdPath" },
    { name = "kind", ["in"] = "path", required = true, schema = { type = "string", enum = { "function", "procedure", "trigger" } } },
    { name = "oid", ["in"] = "path", required = true, schema = { type = "integer", minimum = 1 } } }
  local routine_errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED", "QUERY_FAILED" }
  p["/connections/{id}/routines/{kind}/{oid}/script"] = {
    parameters = routine_params,
    get = op({
      tags = { "objects" }, operationId = "routineScript", summary = "Fonksiyon/prosedur/trigger scripti (ddl|execute|drop)",
      ["x-page-key"] = "script.generate",
      parameters = { { name = "type", ["in"] = "query", schema = { type = "string", enum = { "ddl", "execute", "drop" } } }, qp("DatabaseQuery") },
      responses = { ["200"] = resp("Script", data_of({ type = "object", properties = { sql = { type = "string" } } })) },
      errors = routine_errors,
    }),
  }
  p["/connections/{id}/routines/{kind}/{oid}"] = {
    parameters = routine_params,
    delete = op({
      tags = { "objects" }, operationId = "dropRoutine", summary = "Fonksiyon/prosedur/trigger sil (cascade=true)",
      ["x-page-key"] = "object.actions",
      parameters = { qp("DatabaseQuery") },
      responses = { ["200"] = resp("Silindi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED", "CONFLICT", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/routines/{kind}/{oid}/rename"] = {
    parameters = routine_params,
    post = op({
      tags = { "objects" }, operationId = "renameRoutine", summary = "Fonksiyon/prosedur/trigger yeniden adlandir",
      ["x-page-key"] = "object.actions",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", required = { "new_name" }, properties = { new_name = { type = "string" } } } } } },
      responses = { ["200"] = resp("Yeniden adlandirildi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED", "CONFLICT", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/routines/{kind}/{oid}/enabled"] = {
    parameters = routine_params,
    post = op({
      tags = { "objects" }, operationId = "toggleTrigger", summary = "Trigger etkinlestir/devre disi birak (yalnizca kind=trigger)",
      ["x-page-key"] = "object.actions",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object", required = { "enabled" }, properties = { enabled = { type = "boolean" } } } } } },
      responses = { ["200"] = resp("Güncellendi", data_of({ type = "object" })) },
      errors = routine_errors,
    }),
  }
  p["/connections/{id}/objects/{schema}/{name}/truncate"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/NamePath" } },
    post = op({
      tags = { "objects" }, operationId = "truncateObject", summary = "Tablo truncate",
      ["x-page-key"] = "object.actions",
      responses = { ["204"] = { description = "Truncate edildi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "QUERY_FAILED" },
    }),
  }
  local structure_item_params = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" },
    { ["$ref"] = "#/components/parameters/NamePath" },
    { name = "kind", ["in"] = "path", required = true, schema = { type = "string", enum = { "column", "index", "constraint", "trigger" } } },
    { name = "item", ["in"] = "path", required = true, schema = { type = "string" }, description = "Kolon/index/constraint/trigger adi" } }
  p["/connections/{id}/objects/{schema}/{name}/structure/{kind}/{item}/rename"] = {
    parameters = structure_item_params,
    post = op({
      tags = { "objects" }, operationId = "renameStructureItem", summary = "Kolon/index/constraint/trigger yeniden adlandir",
      ["x-page-key"] = "object.actions",
      requestBody = { required = true, content = { ["application/json"] = { schema = { type = "object",
        required = { "new_name" }, properties = { new_name = { type = "string", maxLength = 63 } } } } } },
      responses = { ["200"] = resp("Yeniden adlandirildi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "CONFLICT", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{name}/structure/{kind}/{item}"] = {
    parameters = structure_item_params,
    delete = op({
      tags = { "objects" }, operationId = "dropStructureItem", summary = "Kolon/index/constraint/trigger sil (?cascade=true)",
      ["x-page-key"] = "object.actions",
      responses = { ["200"] = resp("Silindi", data_of({ type = "object" })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "CONFLICT", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{name}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/NamePath" } },
    delete = op({
      tags = { "objects" }, operationId = "dropObject", summary = "Tablo/view sil",
      ["x-page-key"] = "object.actions",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{name}/script"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/NamePath" } },
    get = op({
      tags = { "objects" }, operationId = "generateScript", summary = "DDL script uret",
      ["x-page-key"] = "script.generate",
      parameters = { { name = "kind", ["in"] = "query", required = true, schema = ref("ScriptKind") }, qp("DatabaseQuery") },
      responses = { ["200"] = resp("Script", data_of(ref("ScriptResult"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND", "VALIDATION_FAILED" },
    }),
  }
  p["/query/csv"] = {
    post = op({
      tags = { "export" }, operationId = "exportQueryCsv", summary = "Sorgu sonucu export (format: csv|json|xlsx)",
      ["x-page-key"] = "export.csv",
      requestBody = json_body("QueryRequest", { connection_id = "00000000-0000-0000-0000-000000000000", sql = "SELECT * FROM tbl" }),
      responses = { ["200"] = resp("CSV", { type = "string", format = "binary" }, "text/csv") },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED", "CONNECTION_NOT_FOUND", "QUERY_FAILED" },
    }),
  }
  p["/connections/{id}/objects/{schema}/{table}/export"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" }, { ["$ref"] = "#/components/parameters/SchemaPath" }, { ["$ref"] = "#/components/parameters/TablePath" } },
    post = op({
      tags = { "export" }, operationId = "exportTableCsv", summary = "Tablo export (format: csv|json|xlsx)",
      ["x-page-key"] = "export.csv",
      requestBody = { required = false, content = { ["application/json"] = { schema = { type = "object", properties = { delimiter = { type = "string" }, include_header = { type = "boolean" }, format = { type = "string", enum = { "csv", "json", "xlsx" } } } } } } },
      responses = { ["200"] = resp("CSV", { type = "string", format = "binary" }, "text/csv") },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONNECTION_NOT_FOUND", "OBJECT_NOT_FOUND" },
    }),
  }
  -- users & rbac
  p["/users"] = {
    get = op({
      tags = { "users" }, operationId = "listUsers", summary = "Kullanıcı listele",
      ["x-page-key"] = "users.list",
      parameters = { qp("Q"), qp("RoleQuery"), qp("IsActiveQuery"), qp("Page"), qp("PerPage"), qp("Sort") },
      responses = { ["200"] = resp("Liste", page_of("User")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
    post = op({
      tags = { "users" }, operationId = "createUser", summary = "Kullanıcı oluştur",
      ["x-page-key"] = "users.create",
      requestBody = json_body("UserCreate", { email = "yeni@pgeditor.local", password = "Ornek123!", role = "editor" }),
      responses = { ["201"] = resp("Oluşturuldu", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "EMAIL_TAKEN", "VALIDATION_FAILED" },
    }),
  }
  p["/users/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/IdPath" } },
    get = op({
      tags = { "users" }, operationId = "getUser", summary = "Kullanıcı getir",
      ["x-page-key"] = "users.list",
      responses = { ["200"] = resp("Kullanıcı", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND" },
    }),
    put = op({
      tags = { "users" }, operationId = "updateUser", summary = "Kullanıcı güncelle",
      ["x-page-key"] = "users.create",
      requestBody = json_body("UserUpdate", { full_name = "Yeni Ad", is_active = true }),
      responses = { ["200"] = resp("Güncellendi", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND", "EMAIL_TAKEN", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN", "VALIDATION_FAILED" },
    }),
    patch = op({
      tags = { "users" }, operationId = "patchUser", summary = "Kullanıcı kismi güncelle",
      ["x-page-key"] = "users.create",
      requestBody = json_body("UserUpdate", { is_active = false }),
      responses = { ["200"] = resp("Güncellendi", data_of(ref("User"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND", "EMAIL_TAKEN", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN", "VALIDATION_FAILED" },
    }),
    delete = op({
      tags = { "users" }, operationId = "deleteUser", summary = "Kullanıcı sil",
      ["x-page-key"] = "users.create",
      responses = { ["204"] = { description = "Silindi" } },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "USER_NOT_FOUND", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN" },
    }),
  }
  p["/rbac/pages"] = {
    get = op({
      tags = { "rbac" }, operationId = "listRbacPages", summary = "Sayfalar",
      ["x-page-key"] = "rbac.matrix",
      responses = { ["200"] = resp("Sayfalar", data_of({ type = "array", items = ref("RbacPage") })) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
  }
  p["/rbac/matrix"] = {
    get = op({
      tags = { "rbac" }, operationId = "getRbacMatrix", summary = "Matris getir",
      ["x-page-key"] = "rbac.matrix",
      responses = { ["200"] = resp("Matris", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
    put = op({
      tags = { "rbac" }, operationId = "updateRbacMatrix", summary = "Matris güncelle",
      ["x-page-key"] = "rbac.matrix",
      requestBody = json_body("RbacMatrixUpdate", { permissions = { { role = "admin", page_key = "dashboard", can_access = true } } }),
      responses = { ["200"] = resp("Güncellendi", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "CONFLICT", "VALIDATION_FAILED" },
    }),
  }
  p["/rbac/matrix/{role}/{page_key}"] = {
    parameters = {
      { name = "role", ["in"] = "path", required = true, schema = ref("Role") },
      { name = "page_key", ["in"] = "path", required = true, schema = ref("PageKey") },
    },
    patch = op({
      tags = { "rbac" }, operationId = "setRbacCell", summary = "Hucre güncelle",
      ["x-page-key"] = "rbac.matrix",
      requestBody = json_body("RbacCellUpdate", { can_access = true }),
      responses = { ["200"] = resp("Güncellendi", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND", "CONFLICT", "VALIDATION_FAILED" },
    }),
  }
  p["/rbac/matrix/reset"] = {
    post = op({
      tags = { "rbac" }, operationId = "resetRbacMatrix", summary = "Matrisi varsayilana sifirla",
      ["x-page-key"] = "rbac.matrix",
      responses = { ["200"] = resp("Sifirlandi", data_of(ref("RbacMatrix"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN" },
    }),
  }
  -- audit
  p["/audit/logs"] = {
    get = op({
      tags = { "audit" }, operationId = "listAuditLogs", summary = "Denetim kayıtları",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"), qp("UserEmail"), qp("Ip"), qp("From"), qp("To"), qp("Page"), qp("PerPage"), qp("Search") },
      responses = { ["200"] = resp("Liste", page_of("AuditLogSummary")) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/audit/logs/{id}"] = {
    parameters = { { ["$ref"] = "#/components/parameters/AuditIdPath" } },
    get = op({
      tags = { "audit" }, operationId = "getAuditLog", summary = "Denetim detayi",
      ["x-page-key"] = "audit.logs",
      responses = { ["200"] = resp("Kayit", data_of(ref("AuditLog"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND" },
    }),
  }
  p["/audit/stats"] = {
    get = op({
      tags = { "audit" }, operationId = "getAuditStats", summary = "Denetim istatistikleri",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"), qp("UserEmail"), qp("Ip"), qp("From"), qp("To") },
      responses = { ["200"] = resp("Stats", data_of(ref("AuditStats"))) },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/audit/export"] = {
    get = op({
      tags = { "audit" }, operationId = "exportAuditLogs", summary = "Denetim CSV export",
      ["x-page-key"] = "audit.logs",
      parameters = { qp("Action"), qp("AuditStatus"), qp("EntityType"), qp("EntityId"), qp("UserIdQuery"), qp("UserEmail"), qp("Ip"), qp("From"), qp("To") },
      responses = { ["200"] = resp("CSV", { type = "string", format = "binary" }, "text/csv") },
      errors = { "UNAUTHORIZED", "FORBIDDEN", "VALIDATION_FAILED" },
    }),
  }
  p["/health"] = {
    get = {
      tags = { "system" }, operationId = "getHealth", summary = "Liveness ve DB durumu",
      security = EMPTY,
      responses = { ["200"] = resp("OK", ref("Health")), ["503"] = resp("Degraded", ref("Health")) },
    },
  }
  p["/health/ready"] = {
    get = {
      tags = { "system" }, operationId = "getReadiness", summary = "Readiness (DB SELECT 1)",
      security = EMPTY,
      responses = {
        ["200"] = resp("Hazir", ref("Readiness")),
        ["503"] = resp("Hazir degil", ref("Readiness")),
      },
    },
  }
  p["/metrics"] = {
    get = {
      tags = { "system" }, operationId = "getMetrics", summary = "Prometheus sayaclari",
      description = "Prod'da proxy tarafindan disariya kapatilir (403).",
      security = EMPTY,
      responses = {
        ["200"] = resp("Prometheus metin formati", { type = "string" }, "text/plain"),
        ["403"] = { description = "Proxy uzerinden erisim reddedildi" },
      },
    },
  }
  p["/swagger.json"] = {
    get = {
      tags = { "system" }, operationId = "getOpenApiSpec", summary = "OpenAPI spec",
      security = EMPTY,
      responses = { ["200"] = resp("Spec", { type = "object" }) },
    },
  }
  p["/swagger"] = {
    get = {
      tags = { "system" }, operationId = "getSwaggerUi", summary = "Swagger UI",
      security = EMPTY,
      responses = { ["200"] = resp("HTML", { type = "string" }, "text/html") },
    },
  }
  return p
end

function _M.build()
  local cfg = config.get()
  local base_url = "http://localhost:28080"
  local env_desc = "development"
  if cfg then
    base_url = cfg.app and cfg.app.base_url or cfg.APP_BASE_URL or base_url
    env_desc = cfg.app and cfg.app.env or cfg.APP_ENV or env_desc
  end
  local comps = components()
  return {
    openapi = "3.1.0",
    info = {
      title = "pg-editor API",
      version = "0.1.0",
      description = "PostgreSQL Web Editor - OpenResty + Lapis tabanli REST API. Tum yanitlar JSON zarfi kullanir.",
      license = { name = "MIT", identifier = "MIT" },
    },
    jsonSchemaDialect = "https://spec.openapis.org/oas/3.1/dialect/base",
    servers = { { url = base_url .. "/api/v1", description = env_desc } },
    security = { { bearerAuth = EMPTY } },
    tags = {
      { name = "auth", description = "Kimlik dogrulama" },
      { name = "connections", description = "Bağlantı yönetimi" },
      { name = "schema", description = "Şema ve yapı kesfi" },
      { name = "query", description = "Sorgu çalıştırma ve gecmis" },
      { name = "table", description = "Tablo tarayıcı" },
      { name = "objects", description = "Obje eylemleri ve script" },
      { name = "export", description = "CSV dışa aktarim" },
      { name = "users", description = "Kullanıcı yönetimi (admin)" },
      { name = "rbac", description = "Rol-sayfa izin matrisi (admin)" },
      { name = "audit", description = "Denetim kayıtları (admin)" },
      { name = "system", description = "Saglik ve dokumantasyon" },
    },
    components = {
      securitySchemes = comps.securitySchemes,
      schemas = comps.schemas,
      parameters = comps.parameters,
      responses = comps.responses,
    },
    paths = paths(),
  }
end

return _M
