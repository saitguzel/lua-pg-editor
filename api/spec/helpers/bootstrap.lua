-- busted helper: pg_shared.X modullerini repo icindeki ../shared/src/X.lua'dan cozer
local searchers = package.loaders or package.searchers
table.insert(searchers, 2, function(name)
  local sub = name:match("^pg_shared%.(.+)$")
  if not sub then return nil end
  local path = "../shared/src/" .. sub:gsub("%.", "/") .. ".lua"
  local chunk, err = loadfile(path)
  if not chunk then return "\n\tno file '" .. path .. "' (" .. tostring(err) .. ")" end
  return chunk
end)
-- also support shared module path for direct require
package.path = package.path .. ";../shared/src/?.lua;shared/src/?.lua;api/src/?.lua;api/src/?/init.lua"
