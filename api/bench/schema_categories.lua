-- wrk F30: nesne gezgini katalogu — /categories (cache) ve /objects?category=tables karisik (TOKEN, CONN_ID run.sh'tan)
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli")
local conn_id = assert(os.getenv("CONN_ID"), "CONN_ID gerekli")
local schema = os.getenv("BENCH_SCHEMA") or "public"
wrk.headers["Authorization"] = "Bearer " .. token
local base = "/api/v1/connections/" .. conn_id .. "/schemas/" .. schema
local paths = { base .. "/categories", base .. "/objects?category=tables&limit=200" }
local i = 0

request = function()
  i = i + 1
  return wrk.format("GET", paths[i % 2 + 1])
end

local statuses = {}
response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
