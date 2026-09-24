-- Query history repository: meta DB uzerinde gecmis kayitlari
local query = require("db.query")
local cjson = require("cjson.safe")

local _M = {}

-- codd: ayni SQL tekrar calisinca kayit en uste tasinir (sql_hash tekil); DB basina en fazla 100 kayit,
-- 64 KB ustu sorgular kaydedilmez
local MAX_PER_DB, MAX_SQL_BYTES = 100, 64 * 1024

function _M.insert(entry)
  if #entry.sql > MAX_SQL_BYTES then return true end
  local row, err = query.query_one(
    [[INSERT INTO query_history (user_id, connection_id, database, sql, sql_hash, row_count, duration_ms, truncated)
      VALUES ($1, $2, $3, $4, md5($4), $5, $6, $7)
      ON CONFLICT (user_id, connection_id, database, sql_hash) DO UPDATE
        SET executed_at = now(), row_count = EXCLUDED.row_count, duration_ms = EXCLUDED.duration_ms,
            truncated = EXCLUDED.truncated
      RETURNING *]],
    entry.user_id, entry.connection_id, entry.database, entry.sql, entry.row_count, entry.duration_ms, entry.truncated
  )
  if not row then return nil, err end
  query.exec([[DELETE FROM query_history WHERE id IN (
      SELECT id FROM query_history WHERE user_id = $1 AND connection_id = $2 AND database = $3
      ORDER BY executed_at DESC, id DESC OFFSET $4)]],
    entry.user_id, entry.connection_id, entry.database, MAX_PER_DB)
  return row
end

-- search: SQL metninde büyük/küçük harf duyarsız alt dizgi (LIKE jokerleri kaçışlı)
-- ponytail: ILIKE sıralı tarama; kullanıcı+DB başına en fazla 100 kayıt olduğundan yeterli
function _M.find_by_connection_db(user_id, connection_id, database, limit, offset, search)
  limit = tonumber(limit) or 50
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end
  offset = tonumber(offset) or 0
  if offset < 0 then offset = 0 end
  -- connection_id nil → kullanicinin tum gecmisi
  local where = "WHERE user_id=$1"
  local params = { user_id }
  local idx = 1
  if connection_id then
    idx = idx + 1
    where = where .. " AND connection_id=$" .. idx
    params[idx] = connection_id
  end
  if database and database ~= "" then
    idx = idx + 1
    where = where .. " AND database=$" .. idx
    params[idx] = database
  end
  if search and search ~= "" then
    idx = idx + 1
    where = where .. " AND sql ILIKE $" .. idx .. " ESCAPE '\\'"
    params[idx] = query.like_pattern(search)
  end
  idx = idx + 1
  local lim_idx = idx
  params[idx] = limit
  idx = idx + 1
  local off_idx = idx
  params[idx] = offset
  local sql = string.format(
    [[SELECT id, user_id, connection_id, database, sql, row_count, duration_ms, truncated, executed_at,
             COUNT(*) OVER() AS total_count
      FROM query_history %s
      ORDER BY executed_at DESC, id DESC
      LIMIT $%d OFFSET $%d]],
    where, lim_idx, off_idx
  )
  local rows, err = query.query(sql, unpack(params))
  if not rows then return nil, err end
  local total = 0
  if rows[1] and rows[1].total_count then total = tonumber(rows[1].total_count) or 0 end
  for _, r in ipairs(rows) do r.total_count = nil end
  return rows, total
end

function _M.delete_by_connection_db(user_id, connection_id, database)
  local where = "WHERE user_id=$1 AND connection_id=$2"
  local params = { user_id, connection_id }
  if database and database ~= "" then
    where = where .. " AND database=$3"
    params[3] = database
    return query.exec("DELETE FROM query_history " .. where, unpack(params))
  end
  return query.exec("DELETE FROM query_history " .. where, unpack(params))
end

function _M.delete_old(days, limit)
  limit = limit or 1000
  local rows, err = query.query(
    [[DELETE FROM query_history WHERE id IN (SELECT id FROM query_history WHERE executed_at < now() - make_interval(days => $1) ORDER BY executed_at LIMIT $2) RETURNING 1]],
    days, limit
  )
  if not rows then return nil, err end
  return #rows
end

return _M
