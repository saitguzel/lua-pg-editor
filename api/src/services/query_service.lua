-- Query servis: execute, history, rate limit, completion invalidate, audit
local cjson = require("cjson.safe")
local config = require("config")
local connection_repo = require("repositories.connection_repo")
local query_history_repo = require("repositories.query_history_repo")
local pool_manager = require("db.pool_manager")
local target_query = require("db.target.query")
local sql_parser = require("utils.sql_parser")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local query_result_model = require("models.query_result")
local db_query = require("db.query")

local _M = {}

local function get_conn_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Baglanti bulunamadi")
  end
  return row
end

local function check_rate_limit(identity, connection_id)
  local dict = ngx.shared.query_rate_limit
  if not dict then return true end
  local key = "query:" .. identity.user_id .. ":" .. connection_id
  local cnt = dict:incr(key, 1, 0, 60)
  if not cnt then return true end
  if cnt > 30 then
    local ttl = dict:ttl(key)
    local e = errors.new("RATE_LIMITED", "Cok fazla deneme, lutfen bekleyin")
    e.headers = { ["Retry-After"] = tostring(ttl > 0 and math.floor(ttl) or 60) }
    return nil, e
  end
  return true
end

local acquire_target = pool_manager.acquire_for

function _M.execute(identity, input)
  -- 1. ownership
  local conn_row, err = get_conn_owned(identity, input.connection_id)
  if not conn_row then return nil, err end
  -- 2. rate limit
  local ok, rerr = check_rate_limit(identity, input.connection_id)
  if not ok then return nil, rerr end
  -- 3. validations zaten handler'da, ama max_bytes kontrol
  local cfg = config.get()
  local max_bytes = cfg and cfg.query and cfg.query.max_bytes or 102400
  if #input.sql > max_bytes then
    return nil, errors.new("PAYLOAD_TOO_LARGE", "Sorgu cok buyuk")
  end
  local database = input.database or conn_row.database
  local row_limit = input.row_limit or (cfg and cfg.query and cfg.query.row_limit_default or 1000)
  row_limit = sql_parser.safe_row_limit(row_limit)
  -- 4. pool acquire
  local pg, conn_id = acquire_target(conn_row, database)
  if not pg then return nil, conn_id end
  -- iptal icin: backend pid'i run_id ile kaydet (POST /query/cancel pg_cancel_backend cagirir)
  local run_key = input.run_id and (identity.user_id .. ":" .. input.run_id)
  local runs = ngx.shared.query_runs
  if run_key and runs then
    local pres = pg:query("SELECT pg_backend_pid() AS pid")
    if pres and pres[1] then
      local timeout_s = (cfg and cfg.query and cfg.query.timeout_ms or 30000) / 1000 + 10
      runs:set(run_key, cjson.encode({ pid = pres[1].pid, connection_id = input.connection_id, database = database }), timeout_s)
    end
  end
  local t0 = ngx.now()
  local exec_res, qerr = target_query.execute(pg, input.sql, row_limit)
  local duration_ms = (ngx.now() - t0) * 1000
  if run_key and runs then runs:delete(run_key) end
  -- kullanici BEGIN/COMMIT kullandiysa acik islem kalmis olabilir: baglanti havuza donmez
  pool_manager.release(conn_id, pg, exec_res == nil or sql_parser.contains_transaction_control(input.sql))
  if not exec_res then
    -- audit failure (history yazilmaz mi? doc: failure da history yazilir ama row_count nil; biz failure'da history yazmayalim ama audit yap)
    audit_service.record("query.execute", {
      entity_type = "query", entity_id = input.connection_id,
      status = "failure",
      new_value = { connection_id = input.connection_id, database = database },
      error_message = qerr and qerr.message or tostring(qerr),
    })
    -- history insert failure durumunda da yapilir ama row_count nil
    if qerr and qerr.code == "QUERY_FAILED" or qerr.code == "OBJECT_NOT_FOUND" or qerr.code == "BAD_REQUEST" then
      -- history kaydet (opsiyonel, basarisiz da loglanir)
      pcall(function()
        query_history_repo.insert({ user_id = identity.user_id, connection_id = input.connection_id, database = database, sql = input.sql, row_count = nil, duration_ms = math.floor(duration_ms), truncated = false })
      end)
    end
    return nil, qerr
  end
  local result = query_result_model.from_execution(exec_res, duration_ms)
  -- 8. history insert (transaction icinde degil, meta DB)
  local history_ok, herr = pcall(function()
    return query_history_repo.insert({
      user_id = identity.user_id,
      connection_id = input.connection_id,
      database = database,
      sql = input.sql,
      row_count = result.row_count,
      duration_ms = math.floor(duration_ms),
      truncated = result.truncated and true or false,
    })
  end)
  if not history_ok then ngx.log(ngx.WARN, "history insert basarisiz: ", tostring(herr)) end
  -- 9. changes_schema -> completion invalidate
  if sql_parser.changes_schema(input.sql) then
    local schema_service = require("services.schema_service")
    schema_service.invalidate_completion(input.connection_id, database)
  end
  -- 10. audit success
  audit_service.record("query.execute", {
    entity_type = "query", entity_id = input.connection_id,
    status = "success",
    new_value = { connection_id = input.connection_id, database = database, row_count = result.row_count, duration_ms = math.floor(duration_ms), truncated = result.truncated },
  })
  return result
end

-- Calisan sorguyu sunucu tarafinda iptal et (codd yalnizca istemci tarafinda birakir)
function _M.cancel(identity, input)
  local runs = ngx.shared.query_runs
  local raw = runs and runs:get(identity.user_id .. ":" .. input.run_id)
  if not raw then return { cancelled = false } end -- zaten bitti
  local run = cjson.decode(raw)
  local conn_row, err = get_conn_owned(identity, run.connection_id)
  if not conn_row then return nil, err end
  local pg, conn_id = acquire_target(conn_row, run.database)
  if not pg then return nil, conn_id end
  local res, qerr = pg:query("SELECT pg_cancel_backend($1) AS ok", run.pid)
  pool_manager.release(conn_id, pg, res == nil)
  if not res then return nil, errors.new("QUERY_FAILED", "Iptal edilemedi", { db_message = tostring(qerr) }) end
  return { cancelled = res[1] and res[1].ok == true }
end

function _M.list_history(identity, q)
  -- q: { connection_id?, database, limit, offset, page, per_page }; connection_id yoksa tum gecmis
  q = q or {}
  if q.connection_id then
    local conn_row, err = get_conn_owned(identity, q.connection_id)
    if not conn_row then return nil, err end
  end
  local limit = q.limit or q.per_page or 50
  local offset = q.offset or 0
  if q.page then
    limit = q.per_page or 50
    offset = (q.page - 1) * limit
  end
  local rows, total = query_history_repo.find_by_connection_db(identity.user_id, q.connection_id, q.database, limit, offset,
    q.q)
  if not rows then return nil, total end
  local out = {}
  for i, r in ipairs(rows) do out[i] = query_result_model.serialize_history(r) end
  local page = q.page or 1
  local per_page = limit
  local total_pages = total > 0 and math.ceil(total / per_page) or 0
  return { items = out, meta = { page = page, per_page = per_page, total = total, total_pages = total_pages } }
end

function _M.delete_history(identity, q)
  if not q or not q.connection_id then
    return nil, errors.new("VALIDATION_FAILED", "connection_id zorunlu", { connection_id = { "zorunlu alan" } })
  end
  local conn_row, err = get_conn_owned(identity, q.connection_id)
  if not conn_row then return nil, err end
  local deleted, derr = query_history_repo.delete_by_connection_db(identity.user_id, q.connection_id, q.database)
  if derr then return nil, derr end
  return { deleted = deleted or 0 }
end

return _M
