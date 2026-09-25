-- Bağlantı HTTP handler'lari: list, create, get, update, delete, test, list_databases
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local connections_service = require("services.connections_service")

local _M = {}

function _M.list()
  local args = ngx.req.get_uri_args()
  local clean, v_err = validation.validate(validation.schemas.pagination or validation.schema({ page = validation.optional(validation.query_int({ min = 1, default = 1 })), per_page = validation.optional(validation.query_int({ min = 1, max = 100, default = 20 })), search = validation.optional(validation.string({ max = 100 })), q = validation.optional(validation.string({ max = 100 })) }), args)
  -- fallback: pagination şemasi yoksa manuel parse
  if not clean then
    -- try simple validation for pagination params
    local page = tonumber(args.page) or 1
    local per_page = tonumber(args.per_page) or 20
    local search = args.search or args.q
    clean = { page = page, per_page = per_page, search = search, q = search }
  end
  local result, serr = connections_service.list(ngx.ctx.identity, clean)
  if not result then return errors.respond(serr) end
  return { status = 200, json = { data = result.items, meta = result.meta } }
end

function _M.create()
  local body, err = errors.read_json_body()
  if not body then return errors.respond(err) end
  local clean, v_err = validation.validate(validation.schemas.connection_create, body)
  if not clean then return errors.respond(errors.validation(v_err)) end
  local conn, serr = connections_service.create(ngx.ctx.identity, clean)
  if not conn then return errors.respond(serr) end
  return { status = 201, json = { data = conn } }
end

function _M.get(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local conn, serr = connections_service.get(ngx.ctx.identity, id)
  if not conn then return errors.respond(serr) end
  return { status = 200, json = { data = conn } }
end

function _M.update(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local clean, v_err = validation.validate_partial(validation.schemas.connection_create, body)
  if not clean then return errors.respond(errors.validation(v_err)) end
  local conn, serr = connections_service.update(ngx.ctx.identity, id, clean)
  if not conn then return errors.respond(serr) end
  return { status = 200, json = { data = conn } }
end

function _M.delete(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local ok, serr = connections_service.delete(ngx.ctx.identity, id)
  if not ok then return errors.respond(serr) end
  return { status = 204, layout = false }
end

function _M.test(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local res, serr = connections_service.test_connection(ngx.ctx.identity, id)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

local function body_string(key, max)
  local body, err = errors.read_json_body()
  if not body then return nil, err end
  local v = body[key]
  if type(v) ~= "string" or v == "" or #v > max then
    return nil, errors.validation({ [key] = { "zorunlu alan" } })
  end
  return v
end

function _M.unlock(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local password, berr = body_string("password", 255)
  if not password then return errors.respond(berr) end
  local res, serr = connections_service.unlock(ngx.ctx.identity, id, password)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.ssh_host_key(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local res, serr = connections_service.ssh_host_key(ngx.ctx.identity, id)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.trust_ssh_host_key(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local fp, berr = body_string("fingerprint", 200)
  if not fp then return errors.respond(berr) end
  local res, serr = connections_service.trust_ssh_host_key(ngx.ctx.identity, id, fp)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.list_databases(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local dbs, serr = connections_service.list_databases(ngx.ctx.identity, id)
  if not dbs then return errors.respond(serr) end
  return { status = 200, json = { data = dbs } }
end

return _M
