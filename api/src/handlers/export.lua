-- Export handler: query CSV ve tablo CSV (streaming)
local validation = require("pg_shared.validation")
local errors = require("middleware.error_handler")
local csv_service = require("services.csv_export_service")
local cjson = require("cjson.safe")

local _M = {}

-- format → Content-Type ve uzantı (varsayılan csv; geriye uyumlu)
local FORMATS = {
  csv = { type = "text/csv; charset=utf-8", ext = "csv" },
  json = { type = "application/json; charset=utf-8", ext = "json" },
  xlsx = { type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ext = "xlsx" },
}
_M.FORMATS = FORMATS

function _M.query_csv(self)
  local body, err = errors.read_json_body()
  if not body then return errors.respond(err) end
  local clean, v = validation.validate(validation.schemas.csv_export, body)
  if not clean then return errors.respond(errors.validation(v)) end
  local fmt = FORMATS[clean.format or "csv"]
  ngx.header["Content-Type"] = fmt.type
  local filename = "query_export_" .. os.date("%Y%m%d_%H%M%S") .. "." .. fmt.ext
  ngx.header["Content-Disposition"] = 'attachment; filename="' .. filename .. '"'
  -- servis streaming mantigi: biz senkron CSV uretip yaziyoruz (buyuk veri icin parcali gonderim de olur)
  local csv_data, serr = csv_service.stream_query_csv(ngx, ngx.ctx.identity, clean)
  if not csv_data then
    -- header zaten gonderildi mi? Eger hata ise JSON dondurmeliydik; ama simdi header gonderildi.
    -- Bu sebeple hata durumunda once kontrol: eger csv_data nil ise ve headers_sent degilse JSON dondur
    if not ngx.headers_sent then return errors.respond(serr) end
    ngx.say("Hata: " .. tostring(serr and serr.message or serr))
    return { status = 200, layout = false }
  end
  ngx.print(csv_data)
  ngx.flush(true)
  return { status = 200, layout = false }
end

-- Alternatif: POST /query/csv non-streaming JSON body ile ama header farkli
function _M.query_csv_simple(self)
  return _M.query_csv(self)
end

function _M.table_csv(self)
  local id, err = errors.require_uuid_param(self, "id", "CONNECTION_NOT_FOUND")
  if not id then return errors.respond(err) end
  local clean_ref, v = validation.validate(validation.schemas.object_ref, { schema = self.params.schema, name = self.params.table or self.params.name })
  if not clean_ref then return errors.respond(errors.validation(v)) end
  local args = ngx.req.get_uri_args()
  -- POST body'den de filter alinabilir
  local body, _ = errors.read_json_body()
  local opts = {}
  if body then
    opts.delimiter = body.delimiter
    opts.include_header = body.include_header
    opts.filters = body.filters
    opts.custom_where = body.custom_where
    opts.columns = body.columns
    opts.database = body.database
    opts.sort = body.sort
    opts.limit = tonumber(body.limit)
  end
  -- query param override
  if args.delimiter then opts.delimiter = args.delimiter end
  if args.include_header ~= nil then opts.include_header = args.include_header == "true" or args.include_header == "1" end
  if args.filters then
    local ok, dec = pcall(cjson.decode, args.filters)
    if ok then opts.filters = dec else opts.filters = args.filters end
  end
  if args.custom_where then opts.custom_where = args.custom_where end
  if args.columns then
    local ok, dec = pcall(cjson.decode, args.columns)
    if ok then opts.columns = dec else opts.columns = { args.columns } end
  end
  if args.database then opts.database = args.database end
  opts.format = args.format or (body and body.format) or "csv"
  if not FORMATS[opts.format] then
    return errors.respond(errors.new("VALIDATION_FAILED", "gecersiz format", { format = { "gecersiz deger" } }))
  end
  -- validate delimiter
  if opts.delimiter and opts.delimiter ~= "," and opts.delimiter ~= ";" and opts.delimiter ~= "\t" and opts.delimiter ~= "|" then
    return errors.respond(errors.new("VALIDATION_FAILED", "gecersiz delimiter", { delimiter={"gecersiz deger"} }))
  end
  ngx.header["Content-Type"] = FORMATS[opts.format].type
  local filename = clean_ref.name .. "_" .. os.date("%Y%m%d_%H%M%S") .. "." .. FORMATS[opts.format].ext
  ngx.header["Content-Disposition"] = 'attachment; filename="' .. filename .. '"'
  local csv_data, serr = csv_service.stream_table_csv(ngx, ngx.ctx.identity, id, clean_ref.schema, clean_ref.name, opts)
  if not csv_data then
    if not ngx.headers_sent then return errors.respond(serr) end
    ngx.say("Hata: " .. tostring(serr and serr.message or serr))
    return { status = 200, layout = false }
  end
  ngx.print(csv_data)
  ngx.flush(true)
  return { status = 200, layout = false }
end

return _M
