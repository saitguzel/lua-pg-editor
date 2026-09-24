-- AI ile SQL üretimi: OpenAI uyumlu sağlayıcı (varsayılan NVIDIA build: integrate.api.nvidia.com/v1).
-- Ayarlar app_settings("ai") içinde; API anahtarı AES-GCM ile şifreli, istemciye yalnızca son 4 karakteri döner.
-- Üretilen SQL asla çalıştırılmaz; yalnızca editöre konur.
local cjson = require("cjson.safe")
local query = require("db.query")
local crypto = require("security.crypto")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local validation = require("pg_shared.validation")

local _M = {}

local SETTINGS_KEY = "ai"
_M.DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1"
local TEST_TIMEOUT_MS = 25000
local GEN_TIMEOUT_MS = 55000 -- 3 deneme × 55 sn < proxy 180 sn
local TEST_CONCURRENCY = 8
local MAX_ATTEMPTS = 3
local CONTEXT_LIMIT = 12000
local RATE_PER_MIN = 20
local JOB_TTL = 1800

-- --- HTTP (testlerde _M._http değiştirilir) --------------------------------------
-- dönüş: status, body | nil, nil, err ("timeout" vb.)
function _M._http(method, url, api_key, body, timeout_ms)
  local http = require("resty.http")
  local c = http.new()
  c:set_timeout(timeout_ms)
  local res, err = c:request_uri(url, {
    method = method,
    body = body and cjson.encode(body) or nil,
    headers = { Authorization = "Bearer " .. api_key, ["Content-Type"] = "application/json",
      Accept = "application/json" },
    ssl_verify = true,
  })
  if not res then return nil, nil, err end
  return res.status, res.body
end

local function now_ms() ngx.update_time(); return ngx.now() * 1000 end

-- --- ayarlar ----------------------------------------------------------------------
local function normalize(v)
  v = type(v) == "table" and v or {}
  v.enabled = v.enabled == true
  v.base_url = type(v.base_url) == "string" and v.base_url ~= "" and v.base_url or _M.DEFAULT_BASE_URL
  v.default_model = type(v.default_model) == "string" and v.default_model ~= "" and v.default_model or "auto"
  v.models = type(v.models) == "table" and v.models or {}
  v.excluded = type(v.excluded) == "table" and v.excluded or {}
  return v
end
_M._normalize = normalize

function _M.load()
  local row, err = query.query_one("SELECT value::text AS v FROM app_settings WHERE key = $1", SETTINGS_KEY)
  if err then return nil, err end
  return normalize(row and cjson.decode(row.v))
end

local function arr(t) return (#t > 0) and t or cjson.empty_array end

function _M.save(s, user_id)
  local out = {}
  for k, v in pairs(s) do out[k] = v end
  out.models, out.excluded = arr(s.models), arr(s.excluded)
  return query.exec([[INSERT INTO app_settings (key, value, updated_by) VALUES ($1, $2::jsonb, $3)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by]],
    SETTINGS_KEY, cjson.encode(out), user_id or validation.NULL)
end

local function api_key_of(s)
  if not s.api_key_encrypted then return nil end
  return crypto.decrypt(s.api_key_encrypted)
end

-- --- saf yardımcılar (unit test edilir) ---------------------------------------------

-- sağlayıcı hata gövdesinden kısa mesaj
function _M.provider_message(status, body)
  local d = type(body) == "string" and cjson.decode(body) or nil
  local msg
  if type(d) == "table" then
    msg = (type(d.error) == "table" and d.error.message) or (type(d.error) == "string" and d.error)
      or d.detail or d.title or d.message
  end
  msg = tostring(msg or (type(body) == "string" and body ~= "" and body) or "yanıt yok")
  msg = msg:gsub("%s+", " ")
  if #msg > 200 then msg = msg:sub(1, 197) .. "…" end
  return (status and (tostring(status) .. ": ") or "") .. msg
end

-- model yanıtından SQL: ```sql blok``` → ``` blok``` → düz metin; <think> blokları atılır
function _M.extract_sql(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("<think>.-</think>", "")
  local sql = text:match("```[Ss][Qq][Ll]%s*\n(.-)```") or text:match("```[%w_]*%s*\n(.-)```")
    or text:match("```[Ss][Qq][Ll]%s*\n(.*)$") -- kapanmamış blok
    or text
  sql = sql:match("^%s*(.-)%s*$")
  return sql ~= "" and sql or nil
end

-- mesajdan metin (content, yoksa reasoning) — test başarısı için
local function message_text(msg)
  if type(msg) ~= "table" then return "", "" end
  local content = type(msg.content) == "string" and msg.content or ""
  local reasoning = type(msg.reasoning_content) == "string" and msg.reasoning_content
    or (type(msg.reasoning) == "string" and msg.reasoning) or ""
  return content, reasoning
end

-- otomatik mod sırası: görünür + son testi başarılı (hızlıdan yavaşa), sonra görünür + test edilmemiş
function _M.rank_models(models)
  local ok, untested = {}, {}
  for _, m in ipairs(models or {}) do
    if m.visible then
      local t = type(m.last_test) == "table" and m.last_test or nil
      if t and t.ok then ok[#ok + 1] = m elseif not t then untested[#untested + 1] = m end
    end
  end
  table.sort(ok, function(a, b)
    local la, lb = tonumber(a.last_test.latency_ms) or math.huge, tonumber(b.last_test.latency_ms) or math.huge
    if la == lb then return a.id < b.id end
    return la < lb
  end)
  local out = {}
  for _, m in ipairs(ok) do out[#out + 1] = m.id end
  for _, m in ipairs(untested) do out[#out + 1] = m.id end
  return out
end

-- sağlayıcı listesi ile mevcut ayarları birleştir: görünürlük/test sonucu korunur, hariç tutulanlar eklenmez
function _M.merge_models(existing, ids, excluded)
  local by_id, skip, out = {}, {}, {}
  for _, m in ipairs(existing or {}) do by_id[m.id] = m end
  for _, id in ipairs(excluded or {}) do skip[id] = true end
  for _, id in ipairs(ids) do
    if not skip[id] then out[#out + 1] = by_id[id] or { id = id, visible = false } end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- şema bağlamı: "şema.tablo(kolon tip, …)" satırları; istemde geçen tablolar önce; limitte kesilir
-- ponytail: basit ad eşleşmesi + kırpma; çok büyük şemalarda gömme (embedding) tabanlı seçim gerekir
function _M.schema_context(catalog, hint, limit)
  limit = limit or CONTEXT_LIMIT
  hint = (hint or ""):lower()
  local first, rest = {}, {}
  for _, sch in ipairs(type(catalog) == "table" and catalog.schemas or {}) do
    for _, t in ipairs(sch.tables or {}) do
      local cols = {}
      for i, c in ipairs(t.columns or {}) do cols[i] = c.name .. (c.type and (" " .. c.type) or "") end
      local line = sch.name .. "." .. t.name .. (t.kind and t.kind ~= "table" and (" [" .. t.kind .. "]") or "")
        .. "(" .. table.concat(cols, ", ") .. ")"
      if hint:find(t.name:lower(), 1, true) then first[#first + 1] = line else rest[#rest + 1] = line end
    end
    for _, r in ipairs(sch.routines or {}) do
      rest[#rest + 1] = (r.kind == "procedure" and "PROCEDURE " or "FUNCTION ") .. sch.name .. "." .. r.name
        .. "(" .. (r.args or "") .. ")" .. (r.returns and r.returns ~= "" and (" RETURNS " .. r.returns) or "")
    end
  end
  local out, size, omitted = {}, 0, 0
  for _, list in ipairs({ first, rest }) do
    for _, line in ipairs(list) do
      if size + #line + 1 > limit then omitted = omitted + 1
      else out[#out + 1] = line; size = size + #line + 1 end
    end
  end
  if omitted > 0 then out[#out + 1] = "-- … " .. omitted .. " nesne daha (bağlam sınırı)" end
  return table.concat(out, "\n")
end

-- --- sağlayıcı çağrıları -------------------------------------------------------------

local function chat(base_url, key, model, messages, max_tokens, timeout_ms)
  local t0 = now_ms()
  local status, body, err = _M._http("POST", base_url .. "/chat/completions", key,
    { model = model, messages = messages, max_tokens = max_tokens, temperature = 0.1, stream = false }, timeout_ms)
  local latency = math.floor(now_ms() - t0)
  if not status then
    return nil, { timeout = err == "timeout", message = err == "timeout" and "zaman aşımı" or tostring(err) }, latency
  end
  if status ~= 200 then return nil, { status = status, message = _M.provider_message(status, body) }, latency end
  local d = cjson.decode(body or "")
  local msg = type(d) == "table" and type(d.choices) == "table" and d.choices[1] and d.choices[1].message
  if not msg then return nil, { message = "beklenmeyen yanıt biçimi" }, latency end
  return msg, nil, latency
end

-- tek model testi: HTTP 200 + yanıtta "SELECT" (içerik ya da reasoning). Yalnızca boş olmayan yanıt yetmez:
-- içerik güvenliği / çeviri / ayrıştırma modelleri de metin döndürür ama SQL isteğini yerine getirmez.
function _M.test_request(base_url, key, model)
  local msg, err, latency = chat(base_url, key, model,
    -- istem SQL içermez: yalnızca metni tekrarlayan (çeviri vb.) modeller geçemez
    { { role = "user", content = "Write a PostgreSQL query that returns the number 42 in a column named answer. "
      .. "Reply with the SQL only." } }, 512, TEST_TIMEOUT_MS)
  local r = { ok = false, latency_ms = latency, at = ngx.time() }
  if not msg then r.error = err.message; return r end
  local content, reasoning = message_text(msg)
  local text = (content .. " " .. reasoning):lower()
  if text:find("select", 1, true) and text:find("42", 1, true) then
    r.ok = true
  elseif (content .. reasoning):match("%S") then
    r.error = "SQL üretmedi: " .. (content ~= "" and content or reasoning):gsub("%s+", " "):sub(1, 80)
  else
    r.error = "boş yanıt"
  end
  return r
end

-- --- iş: tüm modelleri paralel test et (arka plan, ngx.timer) -------------------------
local function dict() return ngx.shared.ai_state end

function _M.job_status()
  local d = dict()
  local raw = d and d:get("job")
  if not raw then return nil end
  local job = cjson.decode(raw) or {}
  job.done = d:get("job_done") or 0
  job.passed = d:get("job_ok") or 0
  return job
end

local function run_job(premature, ids, opts)
  if premature then return end
  local d = dict()
  local ok, perr = pcall(function()
    local results, next_i = {}, 0
    local function worker()
      while true do
        next_i = next_i + 1 -- işbirlikçi coroutine: artırma ile okuma arasında yield yok
        local i = next_i
        if i > #ids then return end
        local r = _M.test_request(opts.base_url, opts.key, ids[i])
        results[ids[i]] = r
        d:incr("job_done", 1, 0)
        if r.ok then d:incr("job_ok", 1, 0) end
      end
    end
    local threads = {}
    for n = 1, math.min(TEST_CONCURRENCY, #ids) do threads[n] = ngx.thread.spawn(worker) end
    for _, t in ipairs(threads) do ngx.thread.wait(t) end
    -- ponytail: iş süresince ayarlar ayrıca değişirse modeller listesindeki o değişiklik bu yazımla ezilebilir
    local s = assert(_M.load())
    local keep, removed = {}, {}
    for _, m in ipairs(s.models) do
      local r = results[m.id]
      if r then m.last_test = r end
      if opts.prune and r and not r.ok then
        removed[#removed + 1] = m.id
        s.excluded[#s.excluded + 1] = m.id
      else
        keep[#keep + 1] = m
      end
    end
    s.models = keep
    for _, id in ipairs(removed) do if s.default_model == id then s.default_model = "auto" end end
    assert(_M.save(s, opts.user_id))
    local job = cjson.decode(d:get("job") or "{}") or {}
    job.running, job.finished_at, job.removed = false, ngx.time(), #removed
    d:set("job", cjson.encode(job), JOB_TTL)
    audit_service.record("ai.models.test", { user_id = opts.user_id, entity_type = "ai",
      new_value = { tested = #ids, passed = d:get("job_ok") or 0, removed = #removed, prune = opts.prune == true } })
  end)
  if not ok then
    ngx.log(ngx.ERR, "ai model test isi basarisiz: ", tostring(perr))
    local job = cjson.decode(d:get("job") or "{}") or {}
    job.running, job.finished_at, job.error = false, ngx.time(), "iş tamamlanamadı"
    d:set("job", cjson.encode(job), JOB_TTL)
  end
  d:delete("job_lock")
end

-- --- yönetici işlemleri ----------------------------------------------------------------

function _M.admin_view(s)
  local key = api_key_of(s)
  return {
    enabled = s.enabled, base_url = s.base_url, default_model = s.default_model,
    has_key = key ~= nil, key_hint = key and ("…" .. key:sub(-4)) or nil,
    models = arr(s.models), excluded = arr(s.excluded), job = _M.job_status(),
  }
end

function _M.get_settings()
  local s, err = _M.load()
  if not s then return nil, err end
  return _M.admin_view(s)
end

-- input: { enabled?, base_url?, api_key?, clear_api_key?, default_model?, visible? = {id…}, excluded? = {id…} }
function _M.update_settings(identity, input)
  local s, err = _M.load()
  if not s then return nil, err end
  if input.enabled ~= nil then s.enabled = input.enabled == true end
  if input.base_url then s.base_url = input.base_url:gsub("/+$", "") end
  local key_changed = false
  if input.clear_api_key then s.api_key_encrypted, key_changed = nil, true end
  if type(input.api_key) == "string" and input.api_key ~= "" then
    local enc, eerr = crypto.encrypt(input.api_key)
    if not enc then return nil, errors.new("INTERNAL_ERROR", "Anahtar şifrelenemedi", { reason = eerr }) end
    s.api_key_encrypted, key_changed = enc, true
  end
  if type(input.visible) == "table" then
    local set = {}
    for _, id in ipairs(input.visible) do set[id] = true end
    for _, m in ipairs(s.models) do m.visible = set[m.id] == true end
  end
  if type(input.excluded) == "table" then s.excluded = input.excluded end
  if input.default_model then
    local found = input.default_model == "auto"
    for _, m in ipairs(s.models) do if m.id == input.default_model and m.visible then found = true end end
    if not found then
      return nil, errors.new("VALIDATION_FAILED", "Varsayılan model görünür modellerden biri olmalı",
        { default_model = { "görünür bir model ya da auto" } })
    end
    s.default_model = input.default_model
  end
  -- görünürlüğü kaldırılan varsayılan model otomatik moda döner
  if s.default_model ~= "auto" then
    local still = false
    for _, m in ipairs(s.models) do if m.id == s.default_model and m.visible then still = true end end
    if not still then s.default_model = "auto" end
  end
  local ok, serr = _M.save(s, identity.user_id)
  if not ok then return nil, serr end
  local visible = 0
  for _, m in ipairs(s.models) do if m.visible then visible = visible + 1 end end
  audit_service.record("ai.settings.update", { entity_type = "ai", new_value = { enabled = s.enabled,
    base_url = s.base_url, key_changed = key_changed, visible_models = visible, default_model = s.default_model } })
  return _M.admin_view(s)
end

local function require_key(s)
  local key = api_key_of(s)
  if not key then return nil, errors.new("AI_NOT_CONFIGURED", "API anahtarı kayıtlı değil") end
  return key
end

function _M.refresh_models(identity)
  local s, err = _M.load()
  if not s then return nil, err end
  local key, kerr = require_key(s)
  if not key then return nil, kerr end
  local status, body, herr = _M._http("GET", s.base_url .. "/models", key, nil, TEST_TIMEOUT_MS)
  if not status then
    return nil, errors.new(herr == "timeout" and "AI_TIMEOUT" or "AI_PROVIDER_ERROR", "Model listesi alınamadı",
      { message = tostring(herr) })
  end
  if status ~= 200 then
    return nil, errors.new("AI_PROVIDER_ERROR", "Model listesi alınamadı: " .. _M.provider_message(status, body),
      { status = status })
  end
  local d = cjson.decode(body or "")
  local ids = {}
  for _, m in ipairs(type(d) == "table" and type(d.data) == "table" and d.data or {}) do
    if type(m) == "table" and type(m.id) == "string" then ids[#ids + 1] = m.id end
  end
  s.models = _M.merge_models(s.models, ids, s.excluded)
  local ok, serr = _M.save(s, identity.user_id)
  if not ok then return nil, serr end
  return _M.admin_view(s)
end

function _M.test_model(identity, model_id)
  local s, err = _M.load()
  if not s then return nil, err end
  local key, kerr = require_key(s)
  if not key then return nil, kerr end
  local target
  for _, m in ipairs(s.models) do if m.id == model_id then target = m end end
  if not target then return nil, errors.new("NOT_FOUND", "Model listede yok") end
  local r = _M.test_request(s.base_url, key, model_id)
  -- test sırasında ayar değişmiş olabilir: güncel kopyaya yalnızca bu sonucu yaz
  local fresh = _M.load() or s
  for _, m in ipairs(fresh.models) do if m.id == model_id then m.last_test = r end end
  _M.save(fresh, identity.user_id)
  audit_service.record("ai.models.test", { entity_type = "ai", entity_id = model_id,
    new_value = { ok = r.ok, latency_ms = r.latency_ms } })
  return { result = r, settings = _M.admin_view(fresh) }
end

-- opts: { prune = bool (çalışmayanları listeden kaldır), only_visible = bool }
function _M.start_test_all(identity, opts)
  local s, err = _M.load()
  if not s then return nil, err end
  local key, kerr = require_key(s)
  if not key then return nil, kerr end
  local ids = {}
  for _, m in ipairs(s.models) do
    if not opts.only_visible or m.visible then ids[#ids + 1] = m.id end
  end
  if #ids == 0 then return nil, errors.new("VALIDATION_FAILED", "Test edilecek model yok (önce listeyi yenileyin)") end
  local d = dict()
  if not d:add("job_lock", true, JOB_TTL) then
    return nil, errors.new("CONFLICT", "Model testi zaten çalışıyor")
  end
  d:set("job", cjson.encode({ running = true, total = #ids, prune = opts.prune == true, started_at = ngx.time() }),
    JOB_TTL)
  d:set("job_done", 0, JOB_TTL)
  d:set("job_ok", 0, JOB_TTL)
  local ok, terr = ngx.timer.at(0, run_job, ids, { prune = opts.prune == true, base_url = s.base_url, key = key,
    user_id = identity.user_id })
  if not ok then
    d:delete("job_lock")
    return nil, errors.new("INTERNAL_ERROR", "Test işi başlatılamadı", { reason = terr })
  end
  return _M.job_status()
end

-- --- sorgu ekranı --------------------------------------------------------------------

function _M.status()
  local s, err = _M.load()
  if not s then return nil, err end
  if not s.enabled then return { enabled = false } end
  local models = {}
  for _, m in ipairs(s.models) do
    if m.visible then
      local t = type(m.last_test) == "table" and m.last_test or {}
      models[#models + 1] = { id = m.id, ok = t.ok, latency_ms = t.latency_ms }
    end
  end
  return { enabled = true, configured = api_key_of(s) ~= nil and #models > 0, default_model = s.default_model,
    models = arr(models) }
end

local function rate_limited(user_id)
  local d = dict()
  if not d then return false end
  local k = "rate:" .. tostring(user_id) .. ":" .. math.floor(ngx.time() / 60)
  local n = d:incr(k, 1, 0, 120)
  return (n or 0) > RATE_PER_MIN
end

local SYSTEM_PROMPT = [[You are an expert PostgreSQL assistant embedded in a SQL editor.
Write correct PostgreSQL for the user's request using ONLY the database schema given below.
Rules:
- Return ONLY the SQL inside a single ```sql code block. No explanations outside the block.
- Never invent tables, columns or functions that are not in the schema.
- If something is ambiguous, make a reasonable assumption and note it as a SQL comment (-- ...).
- UPDATE and DELETE statements must always have a WHERE clause.
- The user may write in Turkish; SQL comments may be in Turkish.]]

-- input: { connection_id, database?, prompt, model? ("auto"|id), sql? (varsa: bu SQL'i talimata göre güncelle) }
function _M.generate(identity, input)
  local s, err = _M.load()
  if not s then return nil, err end
  if not s.enabled then return nil, errors.new("AI_DISABLED", "AI ile kod oluşturma kapalı") end
  local key, kerr = require_key(s)
  if not key then return nil, kerr end
  local candidates
  local wanted = input.model or s.default_model
  if wanted and wanted ~= "auto" then
    for _, m in ipairs(s.models) do if m.id == wanted and m.visible then candidates = { wanted } end end
    if not candidates then
      return nil, errors.new("VALIDATION_FAILED", "Model kullanılamıyor", { model = { "görünür bir model seçin" } })
    end
  else
    candidates = _M.rank_models(s.models)
    if #candidates == 0 then
      return nil, errors.new("AI_NOT_CONFIGURED", "Sorgu ekranında görünen çalışan model yok")
    end
  end
  if rate_limited(identity.user_id) then
    return nil, errors.new("RATE_LIMITED", "Dakikada en fazla " .. RATE_PER_MIN .. " AI isteği")
  end
  local catalog, cerr = require("services.schema_service").get_completion(identity, input.connection_id, input.database)
  if not catalog then return nil, cerr end
  local modify = type(input.sql) == "string" and input.sql:match("%S") ~= nil
  local context = _M.schema_context(catalog, input.prompt .. " " .. (modify and input.sql or ""))
  local user_msg = modify
    and ("Modify the following SQL according to the instruction and return the complete updated SQL.\n\nSQL:\n```sql\n"
      .. input.sql .. "\n```\n\nInstruction: " .. input.prompt)
    or input.prompt
  local messages = {
    { role = "system", content = SYSTEM_PROMPT .. "\n\nDatabase schema (schema.table(column type, ...)):\n" .. context },
    { role = "user", content = user_msg },
  }
  local t0, last_err, attempts = now_ms(), nil, 0
  for i = 1, math.min(MAX_ATTEMPTS, #candidates) do
    local model = candidates[i]
    attempts = attempts + 1
    local msg, cherr = chat(s.base_url, key, model, messages, 4096, GEN_TIMEOUT_MS)
    local sql = msg and _M.extract_sql((message_text(msg)))
    if sql then
      audit_service.record("ai.generate", { entity_type = "ai", entity_id = model, new_value = {
        connection_id = input.connection_id, mode = modify and "modify" or "generate",
        prompt_length = #input.prompt, attempts = attempts } })
      return { sql = sql, model = model, attempts = attempts, duration_ms = math.floor(now_ms() - t0) }
    end
    cherr = cherr or { message = "boş yanıt" }
    last_err = errors.new(cherr.timeout and "AI_TIMEOUT" or "AI_PROVIDER_ERROR",
      model .. ": " .. cherr.message, { model = model, status = cherr.status })
    ngx.log(ngx.WARN, "ai generate denemesi basarisiz model=", model, " ", cherr.message)
  end
  audit_service.record("ai.generate", { entity_type = "ai", status = "failure",
    error_message = last_err and last_err.message, new_value = { attempts = attempts } })
  return nil, last_err
end

return _M
