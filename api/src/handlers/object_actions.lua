-- Obje eylem handler'lari: rename, truncate, drop
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local object_actions_service = require("services.object_actions_service")

local _M = {}

local function get_id(self)
  return errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
end

function _M.rename(self)
  local id, err = get_id(self)
  if not id then return errors.respond(err) end
  local clean_ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not clean_ref then return errors.respond(errors.validation(v)) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local clean, ve = validation.validate(validation.schemas.object_rename, body)
  if not clean then return errors.respond(errors.validation(ve)) end
  local database = self.params.database or ngx.req.get_uri_args().database
  local res, serr = object_actions_service.rename(ngx.ctx.identity, id, clean_ref.schema, clean_ref.name, clean.new_name, database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.truncate(self)
  local id, err = get_id(self)
  if not id then return errors.respond(err) end
  local clean_ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not clean_ref then return errors.respond(errors.validation(v)) end
  local body = errors.read_json_body() or {}
  local args = ngx.req.get_uri_args()
  local function flag(v) return v == true or v == "true" or v == "1" end
  local opts = { cascade = flag(body.cascade) or flag(args.cascade),
    restart_identity = flag(body.restart_identity) or flag(args.restart_identity) }
  local database = self.params.database or args.database
  local res, serr = object_actions_service.truncate(ngx.ctx.identity, id, clean_ref.schema, clean_ref.name, opts, database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.drop(self)
  local id, err = get_id(self)
  if not id then return errors.respond(err) end
  local clean_ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not clean_ref then return errors.respond(errors.validation(v)) end
  local args = ngx.req.get_uri_args()
  local cascade = false
  if args.cascade ~= nil then cascade = args.cascade == "true" or args.cascade == "1" end
  if self.params.cascade ~= nil then cascade = self.params.cascade == "true" or self.params.cascade == "1" end
  local database = self.params.database or args.database
  local res, serr = object_actions_service.drop(ngx.ctx.identity, id, clean_ref.schema, clean_ref.name, cascade, database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

-- Yapı ogeleri: /connections/:id/objects/:schema/:name/structure/:kind/:item[/rename]
local structure_service = require("services.structure_actions_service")

local function structure_params(self)
  local id, err = get_id(self)
  if not id then return nil, err end
  local ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not ref then return nil, errors.validation(v) end
  local kind, item = self.params.kind, self.params.item
  if not structure_service.KINDS[kind] then
    return nil, errors.new("VALIDATION_FAILED", "gecersiz kind", { kind = { "column|index|constraint|trigger" } })
  end
  local ok_item, iv = validation.validate(validation.schemas.object_rename, { new_name = item })
  if not ok_item then return nil, errors.validation({ item = iv.new_name }) end
  local args = ngx.req.get_uri_args()
  return id, { schema = ref.schema, table = ref.name, kind = kind, item = item,
    database = self.params.database or args.database,
    cascade = args.cascade == "true" or args.cascade == "1" }
end

function _M.structure_rename(self)
  local id, p = structure_params(self)
  if not id then return errors.respond(p) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local clean, ve = validation.validate(validation.schemas.object_rename, body)
  if not clean then return errors.respond(errors.validation(ve)) end
  p.new_name = clean.new_name
  local res, serr = structure_service.rename(ngx.ctx.identity, id, p)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.structure_drop(self)
  local id, p = structure_params(self)
  if not id then return errors.respond(p) end
  local res, serr = structure_service.drop(ngx.ctx.identity, id, p)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

-- Fonksiyon / prosedür / trigger: /connections/:id/routines/:kind/:oid[...]
local routines = require("db.target.routines")
local SCRIPT_TYPES = { ddl = true, execute = true, drop = true }

local function routine_params(self, kinds)
  local id, err = get_id(self)
  if not id then return nil, err end
  local kind, oid = self.params.kind, self.params.oid
  if not (kinds or routines.KINDS)[kind] then
    return nil, errors.new("VALIDATION_FAILED", "gecersiz kind", { kind = { "function|procedure|trigger" } })
  end
  -- oid: 32 bit işaretsiz tam sayı
  if type(oid) ~= "string" or not oid:match("^%d+$") or #oid > 10 or tonumber(oid) > 4294967295 then
    return nil, errors.new("OBJECT_NOT_FOUND", "Obje bulunamadı")
  end
  local args = ngx.req.get_uri_args()
  return id, { kind = kind, oid = tonumber(oid), database = args.database,
    cascade = args.cascade == "true" or args.cascade == "1", args = args }
end

function _M.routine_script(self)
  local id, p = routine_params(self)
  if not id then return errors.respond(p) end
  local t = p.args.type or "ddl"
  if not SCRIPT_TYPES[t] then
    return errors.respond(errors.new("VALIDATION_FAILED", "gecersiz type", { type = { "ddl|execute|drop" } }))
  end
  local sql, serr = object_actions_service.routine_script(ngx.ctx.identity, id, p.kind, p.oid, t, p.database)
  if not sql then return errors.respond(serr) end
  return { status = 200, json = { data = { sql = sql, kind = p.kind, type = t } } }
end

function _M.routine_drop(self)
  local id, p = routine_params(self)
  if not id then return errors.respond(p) end
  local res, serr = object_actions_service.routine_drop(ngx.ctx.identity, id, p.kind, p.oid, p.cascade, p.database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.routine_rename(self)
  local id, p = routine_params(self)
  if not id then return errors.respond(p) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local clean, ve = validation.validate(validation.schemas.object_rename, body)
  if not clean then return errors.respond(errors.validation(ve)) end
  local res, serr = object_actions_service.routine_rename(ngx.ctx.identity, id, p.kind, p.oid, clean.new_name,
    p.database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.trigger_toggle(self)
  local id, p = routine_params(self, { trigger = true })
  if not id then return errors.respond(p) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  if type(body.enabled) ~= "boolean" then
    return errors.respond(errors.new("VALIDATION_FAILED", "enabled boolean olmali", { enabled = { "boolean" } }))
  end
  local res, serr = object_actions_service.trigger_set_enabled(ngx.ctx.identity, id, p.oid, body.enabled, p.database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

return _M
