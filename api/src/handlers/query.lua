-- Query handler: execute, history list/delete, completion (proxy)
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local query_service = require("services.query_service")

local _M = {}

function _M.execute(self)
  local body, err = errors.read_json_body()
  if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.query_execute, body)
  if not clean then return errors.respond(errors.validation(v)) end
  local cfg = require("config").get()
  local max_bytes = cfg and cfg.query and cfg.query.max_bytes or 102400
  if #clean.sql > max_bytes then return errors.respond(errors.new("PAYLOAD_TOO_LARGE", "Sorgu cok buyuk")) end
  local res, serr = query_service.execute(ngx.ctx.identity, clean)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.cancel(self)
  local body, err = errors.read_json_body()
  if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.query_cancel, body)
  if not clean then return errors.respond(errors.validation(v)) end
  local res, serr = query_service.cancel(ngx.ctx.identity, clean)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.history(self)
  local args = ngx.req.get_uri_args()
  -- merge self.params
  local merged = {}
  for k, v in pairs(args) do merged[k]=v end
  if self.params then for k, v in pairs(self.params) do merged[k]=v end end
  local clean, v = validation.validate(validation.schemas.query_history_query, merged)
  if not clean then return errors.respond(errors.validation(v)) end
  local result, serr = query_service.list_history(ngx.ctx.identity, clean)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result.items, meta = result.meta } }
end

function _M.history_delete(self)
  local args = ngx.req.get_uri_args()
  local merged = {}
  for k, v in pairs(args) do merged[k]=v end
  if self.params then for k, v in pairs(self.params) do merged[k]=v end end
  -- body'den de alabilir
  local clean, v = validation.validate(validation.schemas.query_history_query, merged)
  if not clean then return errors.respond(errors.validation(v)) end
  -- silme her zaman tek baglanti (+ istege bagli DB) kapsaminda
  if not clean.connection_id then return errors.respond(errors.validation({ connection_id = { "zorunlu alan" } })) end
  local res, serr = query_service.delete_history(ngx.ctx.identity, clean)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.completion(self)
  -- GET /connections/:id/completion (F7 katalog)
  -- handler/schema'ya proxy
  local schema_handler = require("handlers.schema")
  return schema_handler.completion(self)
end

return _M
