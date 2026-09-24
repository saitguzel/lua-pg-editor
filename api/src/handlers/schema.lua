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

function _M.list_objects(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local schema = self.params.schema
  if not schema or schema == "" then return errors.respond(errors.new("VALIDATION_FAILED", "schema zorunlu", { schema={"zorunlu alan"} })) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = schema, name = "tmp" })
  -- object_ref hem schema hem name ister; biz sadece schema dogrulayalim
  if not clean then
    -- schema tek basina valid mi?
    local ok2, v2 = validation.validate(validation.schema({ schema = validation.sql_identifier() }), { schema = schema })
    if not ok2 then return errors.respond(errors.validation(v2)) end
    schema = ok2.schema
  else
    schema = clean.schema
  end
  local database = self.params.database or ngx.req.get_uri_args().database
  if database and database ~= "" then
    local ok, ve = validation.validate(validation.schema({ database = validation.sql_identifier() }), { database = database })
    if not ok then return errors.respond(errors.validation(ve)) end
    database = ok.database
  else
    database = nil
  end
  local list, serr = schema_service.list_objects(ngx.ctx.identity, id, schema, database)
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
