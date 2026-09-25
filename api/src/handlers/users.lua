-- Kullanıcı handler'lari: list, get, create, update, delete (pg-editor F11)
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local user_service = require("services.user_service")

local _M = {}

local UUID_RE = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function valid_id(self)
  local id = self.params and self.params.id
  return type(id) == "string" and id:match(UUID_RE) ~= nil
end

function _M.list()
  local raw = ngx.req.get_uri_args()
  -- Faz11: ?page&per_page&search&role&is_active  -> user_list_query q/role/is_active/page/per_page/sort
  -- search alias -> q
  if raw.search and not raw.q then raw.q = raw.search end
  local clean, ferr = validation.validate(validation.schemas.user_list_query, raw)
  if not clean then return errors.respond(errors.validation(ferr)) end
  if clean.sort then
    local col = clean.sort:gsub("^-", "")
    local allowed = { created_at = true, email = true, full_name = true, last_login_at = true, role = true }
    if not allowed[col] then return errors.respond(errors.validation({ sort = { "gecersiz siralama" } })) end
  end
  local res, serr = user_service.list(ngx.ctx.identity, clean)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res.items, meta = res.meta } }
end

function _M.get(self)
  if not valid_id(self) then return errors.respond(errors.new("USER_NOT_FOUND", "Kullanıcı bulunamadı")) end
  local user, err = user_service.get(ngx.ctx.identity, self.params.id)
  if not user then return errors.respond(err) end
  return { status = 200, json = { data = user } }
end

function _M.create()
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, ferr = validation.validate(validation.schemas.user_create, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  local user, serr = user_service.create(ngx.ctx.identity, clean)
  if not user then return errors.respond(serr) end
  return { status = 201, json = { data = user }, headers = { Location = "/api/v1/users/" .. user.id } }
end

function _M.update(self)
  if not valid_id(self) then return errors.respond(errors.new("USER_NOT_FOUND", "Kullanıcı bulunamadı")) end
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  -- PUT: tam güncelle; validation user_update (optional ama PUT'te de ayni schema)
  local clean, ferr = validation.validate(validation.schemas.user_update, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  -- PUT bos gonderilemez (en az bir alan) -> ancak user_update optional, bos obje de kabul? Faz doc PUT full update diyor
  -- bos ise hata dondur
  if not next(clean) then
    return errors.respond(errors.validation({ _ = { "en az bir alan gonderilmeli" } }))
  end
  local user, serr = user_service.update(ngx.ctx.identity, self.params.id, clean)
  if not user then return errors.respond(serr) end
  return { status = 200, json = { data = user } }
end

function _M.patch(self)
  if not valid_id(self) then return errors.respond(errors.new("USER_NOT_FOUND", "Kullanıcı bulunamadı")) end
  local input, err = errors.read_json_body()
  if not input then return errors.respond(err) end
  local clean, ferr = validation.validate_partial(validation.schemas.user_update, input)
  if not clean then return errors.respond(errors.validation(ferr)) end
  local user, serr = user_service.update(ngx.ctx.identity, self.params.id, clean)
  if not user then return errors.respond(serr) end
  return { status = 200, json = { data = user } }
end

function _M.delete(self)
  if not valid_id(self) then return errors.respond(errors.new("USER_NOT_FOUND", "Kullanıcı bulunamadı")) end
  local ok, err = user_service.delete(ngx.ctx.identity, self.params.id)
  if not ok then return errors.respond(err) end
  return { status = 204, layout = false }
end

return _M
