-- log_cleanup birim testleri (resty altinda): should_run, run_once
local CFG = { audit = { retention_days = 30, cleanup_batch_size = 1000, cleanup_hour = 3, cleanup_enabled = true }, query = { history_retention_days = 30 } }
package.loaded["config"] = { get = function() return CFG end, current = CFG }

local query_mock = {}
local remaining = 0
local locked = true

package.loaded["db.query"] = {
  query = function(sql, a, b)
    if sql:find("pg_try_advisory_lock") then
      return locked and { { locked = true } } or { { locked = false } }
    end
    if sql:find("pg_advisory_unlock") then return { { ok = true } } end
    if sql:find("DELETE FROM audit_logs") then
      local n = math.min(remaining, b)
      remaining = remaining - n
      local rows = {}
      for i = 1, n do rows[i] = { id = i } end
      return rows
    end
    if sql:find("DELETE FROM query_history") then
      local n = math.min(remaining, b)
      remaining = remaining - n
      local rows = {}
      for i = 1, n do rows[i] = { id = i } end
      return rows
    end
    if sql:find("DELETE FROM password_reset_tokens") then
      local rows = {}
      for i = 1, remaining do rows[i] = { id = i } end
      remaining = 0
      return rows
    end
    return {}
  end,
  query_one = function(sql, a)
    if sql:find("pg_try_advisory_lock") then
      return { locked = locked }
    end
    return {}
  end,
  exec = function(sql, a) return 1 end,
}

package.loaded["jobs.log_cleanup"] = nil
package.loaded["jobs.query_history_cleanup"] = nil
package.loaded["jobs.password_reset_cleanup"] = nil

local job = require("jobs.log_cleanup")
job.BATCH_PAUSE = 0
local qjob = require("jobs.query_history_cleanup")
qjob.BATCH_PAUSE = 0
local pjob = require("jobs.password_reset_cleanup")

local AT3 = 1789700400 -- 2026-09-18 03:00:00 UTC

describe("log_cleanup.should_run", function()
  it("yanlis saat -> false", function()
    assert.is_false(job.should_run(AT3, 4, nil))
  end)
  it("dogru saat + dun calismis -> true", function()
    assert.is_true(job.should_run(AT3, 3, "2026-09-17"))
  end)
  it("dogru saat + bugun calismis -> false", function()
    assert.is_false(job.should_run(AT3, 3, "2026-09-18"))
  end)
  it("last_run nil -> true", function()
    assert.is_true(job.should_run(AT3, 3, nil))
  end)
end)

describe("log_cleanup.run_once", function()
  it("batch silme 2500 satır", function()
    remaining = 2500
    locked = true
    local r = assert(job.run_once())
    assert.equal(2500, r.deleted)
    assert.equal(3, r.batches) -- 1000+1000+500
    assert.equal(0, remaining)
  end)

  it("skipped when disabled", function()
    CFG.audit.cleanup_enabled = false
    local r = assert(job.run_once())
    assert.truthy(r.skipped)
    CFG.audit.cleanup_enabled = true
  end)
end)

describe("query_history_cleanup.run_once", function()
  it("query history batch silme", function()
    remaining = 1500
    local r = assert(qjob.run_once())
    assert.equal(1500, r.deleted)
  end)
end)

describe("password_reset_cleanup.run_once", function()
  it("expired token silme", function()
    remaining = 5
    local r = assert(pjob.run_once())
    assert.equal(5, r.deleted)
  end)
end)
