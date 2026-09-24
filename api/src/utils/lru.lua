-- Basit LRU cache: max_size ve idle TTL ile (pg-editor pool_manager icin)
-- O(1) degil ama 32 giris icin yeterli; ngx.now ile zaman damgasi.
local _M = {}

function _M.new(max_size, ttl_seconds)
  local self = {
    max_size = max_size or 32,
    ttl = ttl_seconds or 300,
    map = {},
    order = {}, -- key listesi LRU sirasi (son en yeni)
  }

  function self:get(key)
    local entry = self.map[key]
    if not entry then return nil end
    local now = ngx.now()
    if self.ttl > 0 and (now - entry.touched) > self.ttl then
      self:delete(key)
      return nil
    end
    entry.touched = now
    -- order guncelle
    for i, k in ipairs(self.order) do
      if k == key then
        table.remove(self.order, i)
        break
      end
    end
    self.order[#self.order + 1] = key
    return entry.value
  end

  function self:set(key, value)
    local now = ngx.now()
    if self.map[key] then
      self.map[key].value = value
      self.map[key].touched = now
      -- order guncelle
      for i, k in ipairs(self.order) do
        if k == key then table.remove(self.order, i); break end
      end
      self.order[#self.order + 1] = key
      return
    end
    -- evict en eski
    if #self.order >= self.max_size then
      local evict = table.remove(self.order, 1)
      self.map[evict] = nil
    end
    self.map[key] = { value = value, touched = now }
    self.order[#self.order + 1] = key
  end

  function self:delete(key)
    if not self.map[key] then return end
    self.map[key] = nil
    for i, k in ipairs(self.order) do
      if k == key then table.remove(self.order, i); break end
    end
  end

  function self:count()
    return #self.order
  end

  function self:keys()
    local out = {}
    for i, k in ipairs(self.order) do out[i] = k end
    return out
  end

  return self
end

return _M
