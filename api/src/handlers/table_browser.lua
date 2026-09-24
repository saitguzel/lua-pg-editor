-- Tablo tarayici handler: rows CRUD + duplicate
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local table_browser_service = require("services.table_browser_service")
local cjson = require("cjson.safe")

local _M = {}

local function get_conn_id(self)
  return errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
end

function _M.list_rows(self)
  local id, err = get_conn_id(self)
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local args = ngx.req.get_uri_args()
  -- table_rows_query semasi
  local q_in = {
    page = args.page,
    per_page = args.per_page,
    sort = args.sort,
    filters = args.filters,
    custom_where = args.custom_where,
    database = args.database or self.params.database,
  }
  local qclean, qerr = validation.validate(validation.schemas.table_rows_query, q_in)
  -- filters JSON string ise izin ver, validasyon esnek
  if not qclean then
    -- fallback: dogrudan kullan ama page/per_page sayiya cevir
    qclean = {
      page = tonumber(args.page) or 1,
      per_page = tonumber(args.per_page) or 100,
      sort = args.sort,
      filters = args.filters,
      custom_where = args.custom_where,
      database = args.database or self.params.database,
    }
  else
    -- filters zaten decode edilmis olabilir; string ise birak
    qclean.filters = q_in.filters
    qclean.custom_where = q_in.custom_where
  end
  local page, serr = table_browser_service.list(ngx.ctx.identity, id, clean.schema, clean.name, qclean)
  if not page then return errors.respond(serr) end
  return { status = 200, json = { data = page.rows, meta = { page = page.page, per_page = page.per_page,
    total = page.total, has_next = page.has_next, columns = page.columns, kind = page.kind, editable = page.editable } } }
end

function _M.create_row(self)
  local id, err = get_conn_id(self)
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local values = body.values or body
  if type(values) ~= "table" then return errors.respond(errors.new("VALIDATION_FAILED", "values zorunlu")) end
  local args = ngx.req.get_uri_args()
  local database = args.database or self.params.database
  local row, serr = table_browser_service.insert(ngx.ctx.identity, id, clean.schema, clean.name, values, database)
  if not row then return errors.respond(serr) end
  return { status = 201, json = { data = row } }
end

function _M.update_row(self)
  local id, err = get_conn_id(self)
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local rid = self.params.rid
  if not rid or rid == "" then return errors.respond(errors.new("VALIDATION_FAILED", "rid zorunlu", { rid={"zorunlu alan"} })) end
  local body, berr = errors.read_json_body()
  if not body then return errors.respond(berr) end
  local values = body.values or body
  if type(values) ~= "table" then return errors.respond(errors.new("VALIDATION_FAILED", "values zorunlu")) end
  local args = ngx.req.get_uri_args()
  local database = args.database or self.params.database
  local row, serr = table_browser_service.update(ngx.ctx.identity, id, clean.schema, clean.name, rid, values, database)
  if not row then return errors.respond(serr) end
  return { status = 200, json = { data = row } }
end

function _M.delete_rows(self)
  local id, err = get_conn_id(self)
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local args = ngx.req.get_uri_args()
  local body, berr = errors.read_json_body()
  local ids = nil
  if body and body.ids then ids = body.ids
  elseif body and type(body)=="table" and #body>0 then ids = body
  elseif args.rid then ids = { args.rid }
  elseif args.ids then
    if type(args.ids)=="string" then
      local ok, dec = pcall(cjson.decode, args.ids)
      if ok and type(dec)=="table" then ids=dec else ids={ args.ids } end
    else ids = args.ids end
  end
  if not ids or #ids==0 then return errors.respond(errors.new("VALIDATION_FAILED", "ids zorunlu", { ids={"zorunlu alan"} })) end
  local database = args.database or self.params.database
  local res, serr = table_browser_service.delete(ngx.ctx.identity, id, clean.schema, clean.name, ids, database)
  if not res then return errors.respond(serr) end
  return { status = 200, json = { data = res } }
end

function _M.duplicate_row(self)
  local id, err = get_conn_id(self)
  if not id then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean then return errors.respond(errors.validation(v)) end
  local rid = self.params.rid
  if not rid or rid == "" then return errors.respond(errors.new("VALIDATION_FAILED", "rid zorunlu")) end
  local args = ngx.req.get_uri_args()
  local database = args.database or self.params.database
  local row, serr = table_browser_service.duplicate(ngx.ctx.identity, id, clean.schema, clean.name, rid, database)
  if not row then return errors.respond(serr) end
  return { status = 201, json = { data = row } }
end

return _M
