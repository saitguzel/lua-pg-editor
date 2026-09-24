-- default_users: varsayılan admin ve editor seed'i
-- SEED_DEFAULTS=true iken çalışır, argon2id hash kullanılır.
local password = require("security.password")

local USERS = {
  { email = "admin@pgeditor.local", password = "Admin123!", full_name = "Sistem Yöneticisi", role = "admin" },
  { email = "editor@pgeditor.local", password = "Editor123!", full_name = "Örnek Editör", role = "editor" },
}

return {
  name = "default_users",
  enabled = function(env)
    return env.SEED_DEFAULTS == "true"
  end,
  run = function(q)
    for _, u in ipairs(USERS) do
      local hash = assert(password.hash(u.password))
      q([[INSERT INTO users (email, password_hash, full_name, role)
          VALUES ($1, $2, $3, $4::user_role)
          ON CONFLICT (email) DO NOTHING]],
        u.email, hash, u.full_name, u.role)
    end
  end,
}
