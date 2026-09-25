-- Parola sıfırlama token repository (password_reset_tokens)
local query = require("db.query")

local _M = {}

function _M.create(user_id, token_hash, ttl)
  return query.exec(
    [[INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
      VALUES ($1, $2, now() + make_interval(secs => $3))]],
    user_id, token_hash, ttl
  )
end

function _M.find_by_hash(hash)
  return query.query_one(
    [[SELECT id, user_id, token_hash, expires_at, used_at, created_at
      FROM password_reset_tokens
      WHERE token_hash = $1 LIMIT 1]],
    hash
  )
end

function _M.find_valid_for_update(hash)
  return query.query_one(
    [[SELECT id, user_id
      FROM password_reset_tokens
      WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() FOR UPDATE]],
    hash
  )
end

function _M.mark_used(id)
  return query.exec("UPDATE password_reset_tokens SET used_at = now() WHERE id = $1", id)
end

function _M.invalidate_all(user_id)
  return query.exec("UPDATE password_reset_tokens SET used_at = now() WHERE user_id = $1 AND used_at IS NULL", user_id)
end

function _M.delete_expired()
  return query.exec("DELETE FROM password_reset_tokens WHERE expires_at < now() - interval '1 day' OR used_at IS NOT NULL AND used_at < now() - interval '7 days'")
end

return _M
