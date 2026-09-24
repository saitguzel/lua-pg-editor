-- Baglanti repository: CRUD + arama, sahiplik kontrolu
local query = require("db.query")

local _M = {}

function _M.find_by_id(id)
  return query.query_one("SELECT * FROM connections WHERE id = $1 LIMIT 1", id)
end

function _M.find_by_user_and_name(user_id, name)
  return query.query_one("SELECT * FROM connections WHERE user_id = $1 AND name = $2 LIMIT 1", user_id, name)
end

function _M.find_by_user(user_id, opts)
  opts = opts or {}
  local page = opts.page or 1
  local per_page = opts.per_page or 20
  local search = opts.search or opts.q
  local clauses = {}
  local params = {}
  local function add(sql, val)
    params[#params + 1] = val
    clauses[#clauses + 1] = sql:gsub("%$%?", "$" .. #params)
  end
  add("user_id = $?", user_id)
  if search and search ~= "" then
    local pat = query.like_pattern(search)
    params[#params + 1] = pat
    local idx = #params
    clauses[#clauses + 1] = "(name ILIKE $" .. idx .. " ESCAPE '\\' OR host ILIKE $" .. idx .. " ESCAPE '\\' OR database ILIKE $" .. idx .. " ESCAPE '\\' OR username ILIKE $" .. idx .. " ESCAPE '\\')"
  end
  local where = "WHERE " .. table.concat(clauses, " AND ")
  local offset = (page - 1) * per_page
  params[#params + 1] = per_page
  local lim_idx = #params
  params[#params + 1] = offset
  local off_idx = #params
  local sql = string.format(
    [[SELECT *, COUNT(*) OVER() AS total_count
      FROM connections %s
      ORDER BY created_at DESC, id
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

function _M.create(fields)
  return query.query_one(
    [[INSERT INTO connections (user_id, name, host, port, database, username, password_encrypted, save_password,
      ssh_enabled, ssh_host, ssh_port, ssh_username, ssh_auth_method, ssh_private_key_path, ssh_save_secret, ssh_host_key_fingerprint,
      ssl_mode, ssh_secret_encrypted, ssh_passphrase_encrypted)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, COALESCE($17, 'prefer'), $18, $19)
      RETURNING *]],
    fields.user_id, fields.name, fields.host, fields.port, fields.database, fields.username, fields.password_encrypted, fields.save_password,
    fields.ssh_enabled, fields.ssh_host, fields.ssh_port, fields.ssh_username, fields.ssh_auth_method, fields.ssh_private_key_path, fields.ssh_save_secret, fields.ssh_host_key_fingerprint,
    fields.ssl_mode, fields.ssh_secret_encrypted, fields.ssh_passphrase_encrypted
  )
end

function _M.update(id, fields)
  if not fields or not next(fields) then return _M.find_by_id(id) end
  local set_map = {
    name = "name = $?",
    host = "host = $?",
    port = "port = $?",
    database = "database = $?",
    username = "username = $?",
    password_encrypted = "password_encrypted = $?",
    save_password = "save_password = $?",
    ssh_enabled = "ssh_enabled = $?",
    ssh_host = "ssh_host = $?",
    ssh_port = "ssh_port = $?",
    ssh_username = "ssh_username = $?",
    ssh_auth_method = "ssh_auth_method = $?",
    ssh_private_key_path = "ssh_private_key_path = $?",
    ssh_save_secret = "ssh_save_secret = $?",
    ssh_host_key_fingerprint = "ssh_host_key_fingerprint = $?",
    ssl_mode = "ssl_mode = $?",
    ssh_secret_encrypted = "ssh_secret_encrypted = $?",
    ssh_passphrase_encrypted = "ssh_passphrase_encrypted = $?",
    ssh_known_host = "ssh_known_host = $?",
  }
  local sets = {}
  local params = {}
  for k, expr in pairs(set_map) do
    if fields[k] ~= nil then
      params[#params + 1] = fields[k]
      -- validation.NULL veya cjson.null (userdata) -> SQL NULL; db/query normalize zaten yapiyor
      local sql = expr:gsub("%$%?", "$" .. #params)
      sets[#sets + 1] = sql
    end
  end
  if #sets == 0 then return _M.find_by_id(id) end
  params[#params + 1] = id
  local sql = "UPDATE connections SET " .. table.concat(sets, ", ") .. " WHERE id = $" .. #params .. " RETURNING *"
  return query.query_one(sql, unpack(params))
end

function _M.delete(id)
  return query.query_one("DELETE FROM connections WHERE id = $1 RETURNING *", id)
end

function _M.update_test_result(id, success, latency_ms)
  return query.exec(
    "UPDATE connections SET last_tested_at = now(), last_test_success = $2, last_test_latency_ms = $3 WHERE id = $1",
    id, success, latency_ms
  )
end

return _M
