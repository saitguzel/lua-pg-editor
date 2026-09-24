package = "pg-shared"
version = "0.1.0-1"
source = { url = "git+file:///dev/null" }
description = {
  summary = "pg-editor ortak tipler, dogrulama ve protokol",
  license = "MIT",
}
dependencies = { "lua >= 5.1, < 5.5" }
build = {
  type = "builtin",
  modules = {
    ["pg_shared.types"] = "shared/src/types.lua",
    ["pg_shared.validation"] = "shared/src/validation.lua",
    ["pg_shared.protocol"] = "shared/src/protocol.lua",
  },
}
