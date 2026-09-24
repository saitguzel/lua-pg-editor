-- DB detaylı istatistik servisi — bağlı hedef DB'nin boyut, tablo, index, sorgu geçmişi istatistikleri
local connection_repo = require("repositories.connection_repo")
local errors = require("middleware.error_handler")
local pool_manager = require("db.pool_manager")
local cjson = require("cjson.safe")
local query = require("db.query")

local _M = {}

local function get_conn_owned(identity, connection_id)
  local row, err = connection_repo.find_by_id(connection_id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  return row
end

local function human_bytes(n)
  n = tonumber(n) or 0
  if n == 0 then return "0 B" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.1f %s", n, units[i])
end

-- query_history istatistikleri (local app DB)
local function query_history_stats(identity, connection_id, database)
  local stats = {}
  -- toplam
  local total_row = query.query_one(
    [[SELECT count(*)::int AS total, coalesce(avg(duration_ms),0)::int AS avg_duration,
             coalesce(max(duration_ms),0)::int AS max_duration,
             count(*) FILTER (WHERE truncated = true)::int AS truncated
       FROM query_history WHERE user_id=$1 AND connection_id=$2 AND ($3::text IS NULL OR database=$3 OR ($3='' AND database IS NULL))]],
    identity.user_id, connection_id, database
  )
  if total_row then
    stats.total = tonumber(total_row.total) or 0
    stats.avg_duration_ms = tonumber(total_row.avg_duration) or 0
    stats.max_duration_ms = tonumber(total_row.max_duration) or 0
    stats.truncated = tonumber(total_row.truncated) or 0
  else
    stats.total, stats.avg_duration_ms, stats.max_duration_ms, stats.truncated = 0, 0, 0, 0
  end

  -- son 24 saat
  local r24 = query.query_one(
    [[SELECT count(*)::int AS n FROM query_history
       WHERE user_id=$1 AND connection_id=$2 AND executed_at > now() - interval '24 hours'
         AND ($3::text IS NULL OR database=$3)]],
    identity.user_id, connection_id, database
  )
  stats.last_24h = r24 and tonumber(r24.n) or 0

  -- son 7 gün günlük
  local per_day_7 = query.query(
    [[SELECT to_char(date_trunc('day', executed_at), 'YYYY-MM-DD') AS day, count(*)::int AS count
       FROM query_history WHERE user_id=$1 AND connection_id=$2 AND executed_at > now() - interval '7 days'
         AND ($3::text IS NULL OR database=$3)
       GROUP BY 1 ORDER BY 1]],
    identity.user_id, connection_id, database
  )
  stats.per_day_7 = per_day_7 or {}

  -- son 30 gün
  local per_day_30 = query.query(
    [[SELECT to_char(date_trunc('day', executed_at), 'YYYY-MM-DD') AS day, count(*)::int AS count
       FROM query_history WHERE user_id=$1 AND connection_id=$2 AND executed_at > now() - interval '30 days'
         AND ($3::text IS NULL OR database=$3)
       GROUP BY 1 ORDER BY 1]],
    identity.user_id, connection_id, database
  )
  stats.per_day_30 = per_day_30 or {}

  -- veritabanı bazında (tüm DB'ler)
  local per_db = query.query(
    [[SELECT coalesce(database,'') AS database, count(*)::int AS count
       FROM query_history WHERE user_id=$1 AND connection_id=$2 GROUP BY 1 ORDER BY count DESC]],
    identity.user_id, connection_id
  )
  stats.per_database = per_db or {}

  -- yavaş sorgular (en yavaş 5)
  local slow = query.query(
    [[SELECT left(sql, 120) AS sql_preview, duration_ms, executed_at, database
       FROM query_history WHERE user_id=$1 AND connection_id=$2 AND ($3::text IS NULL OR database=$3)
       ORDER BY duration_ms DESC LIMIT 5]],
    identity.user_id, connection_id, database
  )
  stats.slowest = slow or {}

  -- saatlik dağılım (son 24 saat, 0-23)
  local per_hour = query.query(
    [[SELECT extract(hour from executed_at)::int AS hour, count(*)::int AS count
       FROM query_history WHERE user_id=$1 AND connection_id=$2 AND executed_at > now() - interval '24 hours'
         AND ($3::text IS NULL OR database=$3)
       GROUP BY 1 ORDER BY 1]],
    identity.user_id, connection_id, database
  )
  -- 0-23 arası doldur
  local hour_map = {}
  for _, r in ipairs(per_hour or {}) do hour_map[tonumber(r.hour)] = tonumber(r.count) end
  local per_hour_filled = {}
  for h=0,23 do per_hour_filled[h+1] = { hour = h, count = hour_map[h] or 0 } end
  stats.per_hour = per_hour_filled

  return stats
end

function _M.get_stats(identity, connection_id, database)
  local conn_row, err = get_conn_owned(identity, connection_id)
  if not conn_row then return nil, err end

  local pg, acq_err = pool_manager.acquire_for(conn_row, database)
  if not pg then
    if type(acq_err) == "table" and acq_err.__app_error then return nil, acq_err end
    return nil, errors.new("CONNECTION_FAILED", "Hedef DB'ye bağlanılamadı", { db_message = tostring(acq_err and acq_err.message or acq_err) })
  end

  local result = {
    connection = { id = conn_row.id, name = conn_row.name, host = conn_row.host, port = conn_row.port, database = conn_row.database },
    current_database = database or conn_row.database,
    generated_at = ngx.now(),
  }

  -- 1. Veritabanı boyutları (tüm DB'ler)
  local db_sizes, dberr = pg:query([[SELECT datname, pg_database_size(datname) AS size_bytes
     FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC]])
  if db_sizes then
    local dbs = {}
    for i, r in ipairs(db_sizes) do
      dbs[i] = { name = r.datname, size_bytes = tonumber(r.size_bytes) or 0, size_pretty = human_bytes(r.size_bytes) }
    end
    result.databases = dbs
  else
    result.databases = {}
  end

  -- 2. Mevcut DB boyutu
  local cur_db_size = pg:query([[SELECT pg_database_size(current_database()) AS size_bytes, current_database() AS name]])
  if cur_db_size and cur_db_size[1] then
    result.current_db_size = { name = cur_db_size[1].name, size_bytes = tonumber(cur_db_size[1].size_bytes) or 0, size_pretty = human_bytes(cur_db_size[1].size_bytes) }
  end

  -- 3. Tablo boyutları (top 20)
  local top_tables, terr = pg:query([[
    SELECT n.nspname AS schema, c.relname AS name,
           pg_total_relation_size(c.oid) AS total_bytes,
           pg_relation_size(c.oid) AS table_bytes,
           pg_indexes_size(c.oid) AS index_bytes,
           COALESCE(s.n_live_tup, 0) AS n_live_tup,
           COALESCE(s.n_dead_tup, 0) AS n_dead_tup,
           COALESCE(s.seq_scan, 0) AS seq_scan,
           COALESCE(s.idx_scan, 0) AS idx_scan,
           COALESCE(s.n_tup_ins, 0) AS n_tup_ins,
           COALESCE(s.n_tup_upd, 0) AS n_tup_upd,
           COALESCE(s.n_tup_del, 0) AS n_tup_del,
           COALESCE(s.last_vacuum, s.last_autovacuum) AS last_vacuum,
           COALESCE(s.last_analyze, s.last_autoanalyze) AS last_analyze
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
      AND c.relkind IN ('r','p') AND NOT c.relispartition
    ORDER BY pg_total_relation_size(c.oid) DESC
    LIMIT 20]])
  if top_tables then
    for _, r in ipairs(top_tables) do
      r.total_bytes = tonumber(r.total_bytes) or 0
      r.table_bytes = tonumber(r.table_bytes) or 0
      r.index_bytes = tonumber(r.index_bytes) or 0
      r.n_live_tup = tonumber(r.n_live_tup) or 0
      r.n_dead_tup = tonumber(r.n_dead_tup) or 0
      r.seq_scan = tonumber(r.seq_scan) or 0
      r.idx_scan = tonumber(r.idx_scan) or 0
      r.total_pretty = human_bytes(r.total_bytes)
      r.table_pretty = human_bytes(r.table_bytes)
      r.index_pretty = human_bytes(r.index_bytes)
    end
    result.top_tables = top_tables
  else
    result.top_tables = {}
  end

  -- 4. En çok satır içeren tablolar (top by rows)
  local top_rows, rerr = pg:query([[
    SELECT n.nspname AS schema, c.relname AS name, COALESCE(s.n_live_tup,0) AS n_live_tup,
           pg_total_relation_size(c.oid) AS total_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND n.nspname NOT LIKE 'pg\_toast%' AND c.relkind IN ('r','p') AND NOT c.relispartition
    ORDER BY COALESCE(s.n_live_tup,0) DESC
    LIMIT 15]])
  if top_rows then
    for _, r in ipairs(top_rows) do
      r.n_live_tup = tonumber(r.n_live_tup) or 0
      r.total_bytes = tonumber(r.total_bytes) or 0
      r.total_pretty = human_bytes(r.total_bytes)
    end
    result.top_by_rows = top_rows
  else
    result.top_by_rows = {}
  end

  -- 5. Şema istatistikleri
  local schemas, serr = pg:query([[
    SELECT n.nspname AS schema,
           count(*) AS table_count,
           sum(pg_total_relation_size(c.oid)) AS total_bytes,
           sum(COALESCE(s.n_live_tup,0)) AS total_rows
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
      AND c.relkind IN ('r','p') AND NOT c.relispartition
    GROUP BY n.nspname
    ORDER BY total_bytes DESC]])
  if schemas then
    for _, r in ipairs(schemas) do
      r.table_count = tonumber(r.table_count) or 0
      r.total_bytes = tonumber(r.total_bytes) or 0
      r.total_rows = tonumber(r.total_rows) or 0
      r.total_pretty = human_bytes(r.total_bytes)
    end
    result.schemas = schemas
  else
    result.schemas = {}
  end

  -- 6. Toplam tablo sayısı ve boyut özeti
  local summary, sumerr = pg:query([[
    SELECT count(*) AS table_count,
           sum(pg_total_relation_size(c.oid)) AS total_bytes,
           sum(pg_relation_size(c.oid)) AS table_bytes,
           sum(pg_indexes_size(c.oid)) AS index_bytes,
           sum(COALESCE(s.n_live_tup,0)) AS total_rows,
           sum(COALESCE(s.n_dead_tup,0)) AS dead_rows
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
      AND c.relkind IN ('r','p') AND NOT c.relispartition]])
  if summary and summary[1] then
    local r = summary[1]
    result.summary = {
      table_count = tonumber(r.table_count) or 0,
      total_bytes = tonumber(r.total_bytes) or 0,
      table_bytes = tonumber(r.table_bytes) or 0,
      index_bytes = tonumber(r.index_bytes) or 0,
      total_rows = tonumber(r.total_rows) or 0,
      dead_rows = tonumber(r.dead_rows) or 0,
      total_pretty = human_bytes(r.total_bytes),
      table_pretty = human_bytes(r.table_bytes),
      index_pretty = human_bytes(r.index_bytes),
    }
  else
    result.summary = { table_count = 0, total_bytes = 0, table_bytes = 0, index_bytes = 0, total_rows = 0, dead_rows = 0 }
  end

  -- 7. Index istatistikleri (en çok kullanılan / kullanılmayan)
  local indexes, ierr = pg:query([[
    SELECT n.nspname AS schema, c.relname AS table_name, ic.relname AS index_name,
           pg_relation_size(i.indexrelid) AS size_bytes,
           COALESCE(s.idx_scan,0) AS idx_scan,
           i.indisunique AS is_unique, i.indisprimary AS is_primary
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_class ic ON ic.oid = i.indexrelid
    LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = i.indexrelid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_toast%'
      AND c.relkind IN ('r','p')
    ORDER BY pg_relation_size(i.indexrelid) DESC
    LIMIT 15]])
  if indexes then
    for _, r in ipairs(indexes) do
      r.size_bytes = tonumber(r.size_bytes) or 0
      r.idx_scan = tonumber(r.idx_scan) or 0
      r.size_pretty = human_bytes(r.size_bytes)
    end
    result.top_indexes = indexes
  else
    result.top_indexes = {}
  end

  -- 8. pg_stat_activity
  local activity, aerr = pg:query([[SELECT count(*)::int AS total,
       count(*) FILTER (WHERE state='active')::int AS active,
       count(*) FILTER (WHERE state='idle')::int AS idle,
       count(*) FILTER (WHERE wait_event IS NOT NULL)::int AS waiting
     FROM pg_stat_activity WHERE datname = current_database()]])
  if activity and activity[1] then
    result.activity = {
      total = tonumber(activity[1].total) or 0,
      active = tonumber(activity[1].active) or 0,
      idle = tonumber(activity[1].idle) or 0,
      waiting = tonumber(activity[1].waiting) or 0,
    }
  else
    result.activity = { total = 0, active = 0, idle = 0, waiting = 0 }
  end

  -- 9. pg_stat_database for current db
  local dbstat, dserr = pg:query([[SELECT xact_commit, xact_rollback, blks_read, blks_hit,
       tup_fetched, tup_inserted, tup_updated, tup_deleted, temp_bytes, deadlocks,
       pg_postmaster_start_time() AS start_time, now() - pg_postmaster_start_time() AS uptime
     FROM pg_stat_database WHERE datname = current_database()]])
  if dbstat and dbstat[1] then
    local r = dbstat[1]
    result.pg_stat_database = {
      xact_commit = tonumber(r.xact_commit) or 0,
      xact_rollback = tonumber(r.xact_rollback) or 0,
      blks_read = tonumber(r.blks_read) or 0,
      blks_hit = tonumber(r.blks_hit) or 0,
      tup_fetched = tonumber(r.tup_fetched) or 0,
      tup_inserted = tonumber(r.tup_inserted) or 0,
      tup_updated = tonumber(r.tup_updated) or 0,
      tup_deleted = tonumber(r.tup_deleted) or 0,
      temp_bytes = tonumber(r.temp_bytes) or 0,
      deadlocks = tonumber(r.deadlocks) or 0,
      hit_ratio = (tonumber(r.blks_hit) or 0) + (tonumber(r.blks_read) or 0) > 0 and (tonumber(r.blks_hit) / ((tonumber(r.blks_hit) or 0)+(tonumber(r.blks_read) or 0)) * 100) or 0,
      temp_pretty = human_bytes(r.temp_bytes),
    }
  else
    result.pg_stat_database = {}
  end

  -- 10. Bloat tahmini (dead tup oranı yüksek tablolar)
  local bloat, berr = pg:query([[
    SELECT n.nspname AS schema, c.relname AS name,
           COALESCE(s.n_dead_tup,0) AS dead_tup,
           COALESCE(s.n_live_tup,0) AS live_tup,
           CASE WHEN COALESCE(s.n_live_tup,0) > 0 THEN (COALESCE(s.n_dead_tup,0)::float / s.n_live_tup * 100) ELSE 0 END AS bloat_ratio
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_toast%' AND c.relkind='r'
      AND COALESCE(s.n_dead_tup,0) > 100
    ORDER BY bloat_ratio DESC
    LIMIT 10]])
  if bloat then
    for _, r in ipairs(bloat) do
      r.dead_tup = tonumber(r.dead_tup) or 0
      r.live_tup = tonumber(r.live_tup) or 0
      r.bloat_ratio = tonumber(r.bloat_ratio) or 0
    end
    result.bloat = bloat
  else
    result.bloat = {}
  end

  pool_manager.release(conn_row.id, pg, false)

  -- query_history stats (local DB)
  result.query_history = query_history_stats(identity, connection_id, database)

  return result
end

return _M
