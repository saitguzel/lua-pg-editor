-- AI handler'ları: yönetici ayarları (/admin/ai/*) ve sorgu ekranı (/ai/status, /ai/generate)
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local ai_service = require("services.ai_service")

local _M = {}

local function body_of(schema)
  local body, err = errors.read_json_body()
  if not body then return nil, err end
  local clean, v = validation.validate(validation.schemas[schema], body)
  if not clean then return nil, errors.validation(v) end
  return clean
end

local function ok(data, status) return { status = status or 200, json = { data = data } } end

function _M.get_settings()
  local data, err = ai_service.get_settings()
  if not data then return errors.respond(err) end
  return ok(data)
end

function _M.update_settings()
  local input, err = body_of("ai_settings_update")
  if not input then return errors.respond(err) end
  local data, serr = ai_service.update_settings(ngx.ctx.identity, input)
  if not data then return errors.respond(serr) end
  return ok(data)
end

function _M.refresh_models()
  local data, err = ai_service.refresh_models(ngx.ctx.identity)
  if not data then return errors.respond(err) end
  return ok(data)
end

function _M.test_model()
  local input, err = body_of("ai_model_test")
  if not input then return errors.respond(err) end
  local data, serr = ai_service.test_model(ngx.ctx.identity, input.model)
  if not data then return errors.respond(serr) end
  return ok(data)
end

-- arka planda paralel test; ilerleme GET /admin/ai/settings → job
function _M.test_all()
  local input, err = body_of("ai_test_all")
  if not input then return errors.respond(err) end
  local job, serr = ai_service.start_test_all(ngx.ctx.identity, input)
  if not job then return errors.respond(serr) end
  return ok(job, 202)
end

function _M.status()
  local data, err = ai_service.status()
  if not data then return errors.respond(err) end
  return ok(data)
end

function _M.generate()
  local input, err = body_of("ai_generate")
  if not input then return errors.respond(err) end
  local data, serr = ai_service.generate(ngx.ctx.identity, input)
  if not data then return errors.respond(serr) end
  return ok(data)
end

return _M
