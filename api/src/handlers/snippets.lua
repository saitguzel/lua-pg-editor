-- Taslak handler'ları: GET/POST /snippets, PUT/DELETE /snippets/:id
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local snippet_service = require("services.snippet_service")
local cjson = require("cjson.safe")

local _M = {}

local function body_input()
  local body, err = errors.read_json_body()
  if not body then return nil, err end
  local clean, v = validation.validate(validation.schemas.snippet, body)
  if not clean then return nil, errors.validation(v) end
  return clean
end

function _M.list()
  local rows, err = snippet_service.list(ngx.ctx.identity)
  if not rows then return errors.respond(err) end
  return { status = 200, json = { data = #rows > 0 and rows or cjson.empty_array } }
end

function _M.create()
  local input, err = body_input()
  if not input then return errors.respond(err) end
  local row, serr = snippet_service.create(ngx.ctx.identity, input)
  if not row then return errors.respond(serr) end
  return { status = 201, json = { data = row } }
end

function _M.update(self)
  local id, ierr = errors.require_uuid_param(self, "id", "NOT_FOUND")
  if not id then return errors.respond(ierr) end
  local input, err = body_input()
  if not input then return errors.respond(err) end
  local row, serr = snippet_service.update(ngx.ctx.identity, id, input)
  if not row then return errors.respond(serr) end
  return { status = 200, json = { data = row } }
end

function _M.delete(self)
  local id, ierr = errors.require_uuid_param(self, "id", "NOT_FOUND")
  if not id then return errors.respond(ierr) end
  local ok, serr = snippet_service.delete(ngx.ctx.identity, id)
  if not ok then return errors.respond(serr) end
  return { status = 204, layout = false }
end

return _M
