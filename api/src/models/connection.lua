-- Baglanti modeli: DB satiri -> Lua tablosu, public serilestirme (parola maskeli)
local cjson = require("cjson.safe")

local _M = {}

function _M.from_row(row)
  if not row then return nil end
  return {
    id = row.id,
    user_id = row.user_id,
    name = row.name,
    host = row.host,
    port = row.port and tonumber(row.port) or row.port,
    database = row.database,
    username = row.username,
    password_encrypted = row.password_encrypted,
    save_password = row.save_password,
    ssh_enabled = row.ssh_enabled,
    ssh_host = row.ssh_host,
    ssh_port = row.ssh_port and tonumber(row.ssh_port) or row.ssh_port,
    ssh_username = row.ssh_username,
    ssh_auth_method = row.ssh_auth_method,
    ssh_private_key_path = row.ssh_private_key_path,
    ssh_save_secret = row.ssh_save_secret,
    ssh_host_key_fingerprint = row.ssh_host_key_fingerprint,
    ssh_secret_encrypted = row.ssh_secret_encrypted,
    ssh_passphrase_encrypted = row.ssh_passphrase_encrypted,
    ssh_known_host = row.ssh_known_host,
    ssl_mode = row.ssl_mode,
    last_tested_at = row.last_tested_at,
    last_test_success = row.last_test_success,
    last_test_latency_ms = row.last_test_latency_ms and tonumber(row.last_test_latency_ms) or row.last_test_latency_ms,
    created_at = row.created_at,
    updated_at = row.updated_at,
  }
end

function _M.serialize(row)
  if not row then return nil end
  local m = _M.from_row(row)
  return {
    id = m.id,
    user_id = m.user_id,
    name = m.name,
    host = m.host,
    port = m.port,
    database = m.database,
    username = m.username,
    has_password = m.password_encrypted ~= nil and m.password_encrypted ~= "",
    password = "***",
    save_password = m.save_password,
    ssh_enabled = m.ssh_enabled,
    ssh_host = m.ssh_host or cjson.null,
    ssh_port = m.ssh_port or cjson.null,
    ssh_username = m.ssh_username or cjson.null,
    ssh_auth_method = m.ssh_auth_method or cjson.null,
    ssh_private_key_path = m.ssh_private_key_path or cjson.null,
    ssh_save_secret = m.ssh_save_secret,
    ssh_host_key_fingerprint = m.ssh_host_key_fingerprint or cjson.null,
    has_ssh_secret = m.ssh_secret_encrypted ~= nil and m.ssh_secret_encrypted ~= "",
    ssh_host_trusted = m.ssh_known_host ~= nil and m.ssh_known_host ~= "",
    ssl_mode = m.ssl_mode or "disable",
    last_tested_at = m.last_tested_at or cjson.null,
    last_test_success = m.last_test_success,
    last_test_latency_ms = m.last_test_latency_ms or cjson.null,
    created_at = m.created_at,
    updated_at = m.updated_at,
  }
end

function _M.mask(row)
  -- audit icin: parola alanlari maskelenir
  local copy = _M.from_row(row)
  if not copy then return nil end
  if copy.password_encrypted then copy.password_encrypted = "***" end
  if copy.ssh_secret_encrypted then copy.ssh_secret_encrypted = "***" end
  if copy.ssh_passphrase_encrypted then copy.ssh_passphrase_encrypted = "***" end
  return copy
end

_M.COLUMNS = "id, user_id, name, host, port, database, username, password_encrypted, save_password, ssh_enabled, ssh_host, ssh_port, ssh_username, ssh_auth_method, ssh_private_key_path, ssh_save_secret, ssh_host_key_fingerprint, ssh_secret_encrypted, ssh_passphrase_encrypted, ssh_known_host, ssl_mode, last_tested_at, last_test_success, last_test_latency_ms, created_at, updated_at"

return _M
