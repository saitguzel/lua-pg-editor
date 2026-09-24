-- wrk table_browser senaryosu: GET /connections/:id/objects/:schema/:table/rows
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli")
local conn_id = os.getenv("CONN_ID") or "00000000-0000-0000-0000-000000000000"
local schema = os.getenv("BENCH_SCHEMA") or "public"
local table_name = os.getenv("BENCH_TABLE") or "customers"
wrk.headers["Authorization"] = "Bearer " .. token
wrk.path = string.format("/api/v1/connections/%s/objects/%s/%s/rows?page=1&per_page=100", conn_id, schema, table_name)

local statuses = {}
response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
