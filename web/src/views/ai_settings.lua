-- Ayarlar → "Yapay Zekâ" kartı (yalnızca settings yetkisi): aç/kapat, sağlayıcı adresi, API anahtarı (yalnızca
-- yazılır), model listesini yenile, tek tek / toplu test, çalışmayanları kaldır, sorgu ekranında görünecekleri seç,
-- varsayılan model. Toplu test arka planda sürer; ilerleme 2 sn'de bir sorgulanır.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local icons = require("icons")
local protocol = require("pg_shared.protocol")

local _M = {}

local data = nil -- GET /admin/ai/settings yanıtı
local busy = {} -- işlem adı → true (buton kilidi)
local testing = {} -- model id → true
local filter = ""
local polling = false

local INPUT = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm"

local function fail(err) app.toast("error", err and err.message or protocol.message(err and err.code)) end

local function set_data(d)
  data = d
  app.schedule_render()
end

local function fetch() return api.get("/admin/ai/settings") end

local poll
local function ensure_polling()
  if polling or not (data and data.job and data.job.running) then return end
  polling = true
  js.timer.after(2000, function() app.spawn(poll) end)
end

poll = function()
  polling = false
  local d = fetch()
  if d then
    local was_running = data and data.job and data.job.running
    set_data(d)
    if was_running and d.job and not d.job.running then
      local removed = tonumber(d.job.removed) or 0
      app.toast(d.job.error and "error" or "success", d.job.error or ("Test tamamlandı: " .. tostring(d.job.passed)
        .. "/" .. tostring(d.job.total) .. " çalışıyor" .. (removed > 0 and (", " .. removed .. " model kaldırıldı") or "")))
    end
  end
  ensure_polling()
end

function _M.load()
  if not app.can("settings") then return end
  local d, err = fetch()
  if err then return fail(err) end
  set_data(d)
  ensure_polling()
end

-- işlem sarmalayıcı: kilitle, çağır (fn → yeni ayarlar | nil, err), sonucu uygula
local function action(name, fn)
  if busy[name] then return end
  busy[name] = true
  app.schedule_render()
  app.spawn(function()
    local d, err = fn()
    busy[name] = nil
    if err then fail(err) elseif d then set_data(d) end
    app.schedule_render()
    ensure_polling()
  end)
end

local function put(patch, msg)
  return function()
    local d, err = api.put("/admin/ai/settings", patch)
    if d and msg then app.toast("success", msg) end
    return d, err
  end
end

-- toplu test başlat; ardından ilerleme için ayarları çek
local function start_test_all(body)
  return function()
    local _, err = api.post("/admin/ai/models/test-all", body)
    if err then return nil, err end
    return fetch()
  end
end

local function visible_ids(except, add)
  local out = {}
  for _, m in ipairs(data.models or {}) do
    local on = m.visible
    if m.id == except then on = add end
    if on then out[#out + 1] = m.id end
  end
  return out
end

local function status_badge(m)
  local t = type(m.last_test) == "table" and m.last_test or nil
  if testing[m.id] then return dom.span({ class = "badge badge-in_progress" }, "test ediliyor…") end
  if not t then return dom.span({ class = "badge badge-pending" }, "test edilmedi") end
  if t.ok then
    return dom.span({ class = "badge badge-completed", title = "Son test başarılı" },
      icons.get("check", "w-3 h-3"), " " .. string.format("%.1f sn", (tonumber(t.latency_ms) or 0) / 1000))
  end
  return dom.span({ class = "badge badge-high", title = tostring(t.error or "") },
    icons.get("x", "w-3 h-3"), " " .. tostring(t.error or "hata"):sub(1, 40))
end

local function test_one(id)
  if testing[id] then return end
  testing[id] = true
  app.schedule_render()
  app.spawn(function()
    local d, err = api.post("/admin/ai/models/test", { model = id })
    testing[id] = nil
    if err then fail(err) else
      set_data(d.settings)
      app.toast(d.result.ok and "success" or "error",
        id .. (d.result.ok and " çalışıyor" or (": " .. tostring(d.result.error))))
    end
    app.schedule_render()
  end)
end

local function render_models()
  local models = data.models or {}
  local needle = filter:lower()
  local rows, visible_n, ok_n = {}, 0, 0
  for _, m in ipairs(models) do
    if m.visible then visible_n = visible_n + 1 end
    if type(m.last_test) == "table" and m.last_test.ok then ok_n = ok_n + 1 end
    if needle == "" or m.id:lower():find(needle, 1, true) then
      rows[#rows + 1] = dom.tr({ key = m.id, class = "border-b border-[var(--border)]" },
        dom.td({ class = "py-1.5 pr-2 w-10 text-center" },
          dom.input({ type = "checkbox", checked = m.visible and "checked" or nil,
            ["aria-label"] = m.id .. " sorgu ekranında göster",
            onchange = function(e) action("visible", put({ visible = visible_ids(m.id, e.checked == true) })) end })),
        dom.td({ class = "py-1.5 pr-2 font-mono text-xs break-all" }, m.id),
        dom.td({ class = "py-1.5 pr-2" }, status_badge(m)),
        dom.td({ class = "py-1.5 text-right" },
          icons.button({ icon = "zap", label = "Test et", class = "btn-sm", disabled = testing[m.id] or nil,
            ["aria-label"] = m.id .. " test et", onclick = function() test_one(m.id) end })))
    end
  end
  local job = data.job
  local running = job and job.running
  local progress = running and dom.div({ class = "space-y-1", role = "status" },
    dom.div({ class = "text-sm" }, "Modeller test ediliyor: " .. tostring(job.done or 0) .. " / "
      .. tostring(job.total or 0) .. " (çalışan: " .. tostring(job.passed or 0) .. ")"
      .. (job.prune and " — çalışmayanlar kaldırılacak" or "")),
    dom.progress({ class = "w-full", max = tostring(job.total or 1), value = tostring(job.done or 0),
      ["aria-label"] = "Test ilerlemesi" })) or nil
  local excluded_n = #(data.excluded or {})
  return dom.div({ class = "space-y-3" },
    dom.div({ class = "flex flex-wrap items-center gap-2" },
      icons.button({ icon = "refresh", label = "Modelleri yenile", class = "btn-sm", disabled = busy.refresh or nil,
        title = "Sağlayıcıdan güncel model listesini al",
        onclick = function() action("refresh", function() return api.post("/admin/ai/models/refresh", {}) end) end }),
      icons.button({ icon = "zap", label = "Görünenleri test et", class = "btn-sm", disabled = running or visible_n == 0 or nil,
        onclick = function() action("testall", start_test_all({ only_visible = true })) end }),
      icons.button({ icon = "trash", label = "Tümünü test et, çalışmayanları kaldır", variant = "danger", class = "btn-sm",
        disabled = running or #models == 0 or nil,
        onclick = function()
          app.spawn(function()
            if not require("components.modal").confirm({ title = "Tüm modeller test edilsin mi?", danger = true,
              confirm_label = "Test et ve kaldır",
              message = #models .. " model paralel test edilecek (birkaç dakika sürebilir). SQL üretemeyenler "
                .. "listeden kaldırılıp hariç tutulanlara eklenecek; listeyi yenileseniz de geri gelmezler." }) then
              return
            end
            action("testall", start_test_all({ prune = true }))
          end)
        end }),
      excluded_n > 0 and icons.button({ icon = "refresh", label = "Hariç tutulanları geri getir (" .. excluded_n .. ")",
        variant = "ghost", class = "btn-sm", disabled = busy.restore or nil,
        onclick = function()
          action("restore", function()
            local _, err = api.put("/admin/ai/settings", { excluded = {} })
            if err then return nil, err end
            return api.post("/admin/ai/models/refresh", {})
          end)
        end }) or nil),
    progress,
    dom.div({ class = "flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3 text-sm text-[var(--fg-muted)]" },
      dom.span({}, #models .. " model · " .. ok_n .. " çalışıyor · " .. visible_n .. " sorgu ekranında"),
      dom.input({ type = "search", class = INPUT .. " w-full sm:max-w-64 sm:ml-auto", value = filter, placeholder = "Model ara…",
        ["aria-label"] = "Model ara", oninput = function(e) filter = e.value or ""; app.schedule_render() end })),
    #models == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)]" },
      data.has_key and "Liste boş — \"Modelleri yenile\" ile sağlayıcıdan alın." or "Önce API anahtarını kaydedin.")
      or nil,
    #models > 0 and dom.div({ class = "max-h-[28rem] overflow-auto border border-[var(--border)] rounded-[var(--radius)] -mx-3 sm:mx-0" },
      dom.div({ class = "min-w-[520px] px-3 sm:px-0" },
        dom.table({ class = "w-full text-sm" },
          dom.thead({}, dom.tr({ class = "text-left text-xs text-[var(--fg-muted)]" },
            dom.th({ class = "py-2 pr-2 text-center", scope = "col" }, "Göster"),
            dom.th({ class = "py-2 pr-2", scope = "col" }, "Model"),
            dom.th({ class = "py-2 pr-2", scope = "col" }, "Durum"),
            dom.th({ class = "py-2", scope = "col" }, dom.span({ class = "sr-only" }, "Test")))),
          dom.tbody({}, dom.list(rows))))) or nil)
end

function _M.render()
  if not app.can("settings") then return nil end
  local section = "space-y-4 p-3 sm:p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]"
  local head = dom.div({ class = "flex items-center gap-2" },
    dom.span({ class = "text-[var(--ai-a)] shrink-0" }, icons.get("sparkles", "w-5 h-5")),
    dom.h2({ id = "ai-settings-title", class = "font-semibold text-sm sm:text-base" }, "Yapay Zekâ ile SQL"))
  if not data then
    return dom.section({ class = section, ["aria-busy"] = "true" }, head, require("components.skeleton").lines(3))
  end
  local visible_opts = { dom.option({ value = "auto", selected = data.default_model == "auto" and "selected" or nil },
    "Otomatik (en hızlı çalışan)") }
  for _, m in ipairs(data.models or {}) do
    if m.visible then
      visible_opts[#visible_opts + 1] = dom.option({ value = m.id,
        selected = data.default_model == m.id and "selected" or nil }, m.id)
    end
  end
  return dom.section({ class = section, ["aria-labelledby"] = "ai-settings-title" },
    head,
    dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Sorgu ekranında doğal dilden SQL üretme ve seçili sorguyu "
      .. "güncelleme. OpenAI uyumlu sağlayıcı (varsayılan NVIDIA build.nvidia.com). Üretilen SQL otomatik çalıştırılmaz."),
    dom.label({ class = "flex items-center gap-2 text-sm font-medium" },
      dom.input({ id = "ai-enabled", type = "checkbox", checked = data.enabled and "checked" or nil,
        onchange = function(e)
          action("enabled", put({ enabled = e.checked == true },
            e.checked and "AI ile kod oluşturma açıldı" or "AI ile kod oluşturma kapatıldı"))
        end }),
      "AI ile kod oluştur (kapalıyken sorgu ekranında AI bileşenleri gizlenir)"),
    dom.div({ class = "grid grid-cols-1 md:grid-cols-2 gap-4" },
      dom.div({ class = "space-y-1" },
        dom.label({ ["for"] = "ai-base-url", class = "block text-sm font-medium" }, "Sağlayıcı adresi"),
        dom.input({ id = "ai-base-url", type = "url", class = INPUT .. " font-mono", value = data.base_url or "",
          onchange = function(e) action("base", put({ base_url = e.value }, "Sağlayıcı adresi kaydedildi")) end })),
      dom.div({ class = "space-y-1" },
        dom.label({ ["for"] = "ai-key", class = "block text-sm font-medium" }, "API anahtarı"),
        dom.div({ class = "flex gap-2" },
          dom.input({ id = "ai-key", type = "password", class = INPUT .. " font-mono", autocomplete = "off",
            placeholder = data.has_key and ("kayıtlı " .. tostring(data.key_hint)) or "nvapi-…" }),
          icons.button({ icon = "save", label = "Kaydet", variant = "accent", disabled = busy.key or nil,
            ["aria-label"] = "API anahtarını kaydet",
            onclick = function()
              local v = (dom.value("ai-key") or ""):match("^%s*(.-)%s*$")
              if v == "" then app.toast("error", "Anahtar girin"); return end
              dom.set_value("ai-key", "")
              action("key", put({ api_key = v }, "API anahtarı kaydedildi (şifreli)"))
            end }),
          data.has_key and icons.button({ icon = "trash", label = "Anahtarı sil", icon_only = true, variant = "ghost",
            onclick = function() action("key", put({ clear_api_key = true }, "API anahtarı silindi")) end }) or nil),
        dom.p({ class = "text-xs text-[var(--fg-muted)]" }, "Sunucuda şifreli saklanır; bir daha görüntülenemez."))),
    dom.div({ class = "space-y-1 max-w-md" },
      dom.label({ ["for"] = "ai-default-model", class = "block text-sm font-medium" }, "Varsayılan model"),
      dom.select({ id = "ai-default-model", class = INPUT,
        onchange = function(e) action("default", put({ default_model = e.value }, "Varsayılan model kaydedildi")) end },
        dom.list(visible_opts))),
    dom.h3({ class = "font-medium pt-2" }, "Modeller"),
    render_models())
end

return _M
