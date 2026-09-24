-- QueryResult DTO: sorgu calistirma sonucu
local cjson = require("cjson.safe")

local _M = {}

-- exec_res: db/target/query.lua exec_one ciktisi (satirlar zaten kolon sirasinda dizi)
function _M.from_execution(exec_res, duration_ms)
  if not exec_res then return nil end
  local rows = exec_res.rows or {}
  return {
    columns = exec_res.columns or {},
    column_types = exec_res.column_types,
    rows = rows,
    row_count = exec_res.row_count or #rows,
    truncated = exec_res.truncated or false,
    duration_ms = duration_ms and math.floor(duration_ms * 100) / 100 or nil,
    command = exec_res.command,
  }
end

function _M.serialize(res)
  if not res then return nil end
  return {
    columns = res.columns or {},
    column_types = res.column_types,
    rows = res.rows or {},
    row_count = res.row_count or 0,
    truncated = res.truncated or false,
    duration_ms = res.duration_ms,
    command = res.command,
  }
end

-- History serialize: query_history tablosu satiri
function _M.serialize_history(row)
  if not row then return nil end
  return {
    id = row.id and tonumber(row.id) or row.id,
    user_id = row.user_id,
    connection_id = row.connection_id,
    database = row.database,
    sql = row.sql,
    row_count = row.row_count and tonumber(row.row_count) or row.row_count,
    duration_ms = row.duration_ms and tonumber(row.duration_ms) or row.duration_ms,
    truncated = row.truncated,
    executed_at = row.executed_at,
  }
end

return _M
