-- wrk connections list: GET /connections (TOKEN run.sh'tan)
local token = assert(os.getenv("TOKEN"), "TOKEN gerekli")
wrk.headers["Authorization"] = "Bearer " .. token
wrk.path = "/api/v1/connections?per_page=20"

local statuses = {}
response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
end

done = function()
  for s, n in pairs(statuses) do io.write(string.format("status %d: %d\n", s, n)) end
end
