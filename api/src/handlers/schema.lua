-- Sema/yapi handler'lari: schemas, objects, structure, completion
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local schema_service = require("services.schema_service")

local _M = {}

function _M.list_schemas(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local database = self.params.database or ngx.req.get_uri_args().database
  if database and database ~= "" then
    local ok, v = validation.validate(validation.schema({ database = validation.sql_identifier() }), { database = database })
    if not ok then return errors.respond(errors.validation(v)) end
    database = ok.database
  else
    database = nil
  end
  local list, serr = schema_service.list_schemas(ngx.ctx.identity, id, database)
  if not list then return errors.respond(serr) end
  return { status = 200, json = { data = list } }
end

local function blank_to_nil(v) if v == nil or v == "" then return nil end return v end

-- F25: ?category=&q=&limit=&offset= ile kategori listesi (meta ile); category yoksa F7 yaniti
function _M.list_objects(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local args = ngx.req.get_uri_args()
  local clean, v = validation.validate(validation.schemas.schema_objects_query, {
    schema = self.params.schema, database = blank_to_nil(self.params.database or args.database),
    category = blank_to_nil(args.category), q = blank_to_nil(args.q),
    limit = blank_to_nil(args.limit), offset = blank_to_nil(args.offset) })
  if not clean then return errors.respond(errors.validation(v)) end
  local list, meta = schema_service.list_objects(ngx.ctx.identity, id, clean.schema, clean.database,
    clean.category and { category = clean.category, q = clean.q, limit = clean.limit, offset = clean.offset } or nil)
  if not list then return errors.respond(meta) end
  return { status = 200, json = { data = list, meta = clean.category and meta or nil } }
end

-- F25: sema basina kategori sayaclari
function _M.list_categories(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.schema_ref, {
    schema = self.params.schema, database = blank_to_nil(self.params.database or ngx.req.get_uri_args().database) })
  if not clean then return errors.respond(errors.validation(v)) end
  local list, serr = schema_service.list_categories(ngx.ctx.identity, id, clean.schema, clean.database)
  if not list then return errors.respond(serr) end
  return { status = 200, json = { data = list } }
end

function _M.structure(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local database = self.params.database or ngx.req.get_uri_args().database
  if database and database ~= "" then
    local ok, ve = validation.validate(validation.schema({ database = validation.sql_identifier() }), { database = database })
    if not ok then return errors.respond(errors.validation(ve)) end
    database = ok.database
  else
    database = nil
  end
  local data, serr = schema_service.get_structure(ngx.ctx.identity, id, clean.schema, clean.name, database)
  if not data then return errors.respond(serr) end
  return { status = 200, json = { data = data } }
end

function _M.completion(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local database = self.params.database or ngx.req.get_uri_args().database
  if database and database ~= "" then
    local ok, ve = validation.validate(validation.schema({ database = validation.sql_identifier() }), { database = database })
    if not ok then return errors.respond(errors.validation(ve)) end
    database = ok.database
  else
    database = nil
  end
  local cat, serr = schema_service.get_completion(ngx.ctx.identity, id, database)
  if not cat then return errors.respond(serr) end
  return { status = 200, json = { data = cat } }
end

-- Alias for routes that expect /databases endpoint already exists in connections handler,
-- but schema.browser page also uses /schemas.

return _M
