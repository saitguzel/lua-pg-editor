-- Script handler: GET /connections/:id/objects/:schema/:name/script?kind=
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local script_service = require("services.script_service")
local types = require("pg_shared.types")

local _M = {}

function _M.generate(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local clean_ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.name })
  if not clean_ref then return errors.respond(errors.validation(v)) end
  local args = ngx.req.get_uri_args()
  local kind = self.params.kind or args.kind
  if not kind or not types.SCRIPT_KIND_SET[kind] then
    return errors.respond(errors.new("VALIDATION_FAILED", "gecersiz kind", { kind={"gecersiz deger"} }))
  end
  local database = self.params.database or args.database
  if database and database ~= "" then -- F25: database param'i da dogrulanir
    local ok, ve = validation.validate(validation.schema({ database = validation.pg_name() }), { database = database })
    if not ok then return errors.respond(errors.validation(ve)) end
    database = ok.database
  else
    database = nil
  end
  local sql, serr = script_service.generate(ngx.ctx.identity, id, clean_ref.schema, clean_ref.name, kind, database)
  if not sql then return errors.respond(serr) end
  return { status = 200, json = { data = { sql = sql, kind = kind } } }
end

return _M
