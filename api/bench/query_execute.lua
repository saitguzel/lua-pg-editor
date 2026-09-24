-- wrk query_execute senaryosu: POST /query/execute (TOKEN run.sh'tan)
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli (api/bench/run.sh uretir)")
local conn_id = os.getenv("CONN_ID") or "00000000-0000-0000-0000-000000000000"
local cjson = require("cjson.safe")
wrk.method = "POST"
wrk.path = "/api/v1/query/execute"
wrk.headers["Authorization"] = "Bearer " .. token
wrk.headers["Content-Type"] = "application/json"
wrk.body = cjson.encode({ connection_id = conn_id, sql = "SELECT * FROM customers LIMIT 100" })

local statuses = {}
response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
