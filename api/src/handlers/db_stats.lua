-- DB istatistik handler — bağlı hedef DB'nin detaylı istatistikleri
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local db_stats_service = require("services.db_stats_service")

local _M = {}

function _M.stats(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local args = ngx.req.get_uri_args()
  local database = args.database
  if database and database ~= "" then
    local ok, ve = validation.validate(validation.schema({ database = validation.pg_name() }), { database = database })
    if not ok then return errors.respond(errors.validation(ve)) end
    database = ok.database
  else
    database = nil
  end
  local data, serr = db_stats_service.get_stats(ngx.ctx.identity, id, database)
  if not data then return errors.respond(serr) end
  return { status = 200, json = { data = data } }
end

return _M
