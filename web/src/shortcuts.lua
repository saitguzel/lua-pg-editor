-- F21: Klavye kisayollari — global + view scope, typing korumasi, g sekansi, ctrl kombinasyonlari.
-- glue.js tek keydown dinleyicisini app.lua'ya baglar, bu modul dagitir.
-- Ctrl/Cmd kombinasyonlari typing olsa da calisir (editor icinde Ctrl+Enter gibi); tek tuslular typing'de bloklu.

local shortcuts = {}

-- WCAG 2.1.4: tek tus kisayollari kapatilabilir (profil ayari, localStorage'da kalici)
local STORAGE_KEY = "pg.shortcuts"
function shortcuts.enabled()
  return js.storage.get(STORAGE_KEY) ~= "off"
end
function shortcuts.set_enabled(on)
  if on then js.storage.remove(STORAGE_KEY) else js.storage.set(STORAGE_KEY, "off") end
end

-- scope -> { [key] = { fn, description } }
local registry = {}

function shortcuts.register(scope, key, fn, description)
  registry[scope] = registry[scope] or {}
  registry[scope][key] = { fn = fn, description = description or "" }
end

function shortcuts.unregister_scope(scope)
  registry[scope] = nil
end

-- F29: yardım/profil listesi için scope etiketleri ve sırası; "editor" scope'u hiçbir route ile eşleşmez,
-- yalnız CodeMirror içi tuşları listelemek için kullanılır (kayıt tetiklenmez).
shortcuts.SCOPE_LABEL = { global = "Genel", query = "Sorgu editörü", editor = "Editör içi",
  browse = "Tablo tarayıcı", structure = "Yapı" }
local SCOPE_ORDER = { global = 1, query = 2, editor = 3, browse = 4, structure = 5 }

-- yardim modali icin: { scope, label, key, description } — scope sırası SCOPE_ORDER, sonra tuş adı
function shortcuts.list()
  local out = {}
  for scope, keys in pairs(registry) do
    for key, entry in pairs(keys) do
      out[#out + 1] = { scope = scope, label = shortcuts.SCOPE_LABEL[scope] or scope, key = key,
        description = entry.description }
    end
  end
  table.sort(out, function(a, b)
    local oa, ob = SCOPE_ORDER[a.scope] or 99, SCOPE_ORDER[b.scope] or 99
    if oa ~= ob then return oa < ob end
    if a.scope ~= b.scope then return a.scope < b.scope end
    return a.key < b.key
  end)
  return out
end

-- scope'a göre gruplu: { { scope, label, items = { {key, description}... } }, ... }
function shortcuts.grouped()
  local groups, by_scope = {}, {}
  for _, s in ipairs(shortcuts.list()) do
    local g = by_scope[s.scope]
    if not g then
      g = { scope = s.scope, label = s.label, items = {} }
      by_scope[s.scope] = g
      groups[#groups + 1] = g
    end
    g.items[#g.items + 1] = s
  end
  return groups
end

-- Aktif route'a gore bakilacak scope'lar
local function active_scopes()
  local scopes = {}
  local ok, app = pcall(require, "app")
  local name = ok and app.get_state().route.name or nil
  if name then
    scopes[#scopes + 1] = name
  end
  scopes[#scopes + 1] = "global"
  return scopes
end

-- g sekansi durumu
local pending_g = false
local pending_timer = nil
local function clear_pending_g()
  pending_g = false
  if pending_timer then js.timer.cancel(pending_timer) end
  pending_timer = nil
end
function shortcuts._clear_pending() clear_pending_g() end
local function set_pending_g()
  pending_g = true
  if pending_timer then js.timer.cancel(pending_timer) end
  -- 1 sn icinde ikinci tus gelmezse iptal
  pending_timer = js.timer.after(1000, function() pending_g = false; pending_timer = nil end)
end

-- app.dispatch'e kisa erisim (dongusel require dikkat)
local function get_app()
  local ok, app = pcall(require, "app")
  if ok then return app end
  return nil
end

local function handle_ctrl(key, typing, tag)
  local lower = key:lower()
  -- Ctrl/Cmd + Enter: sorgu calistir (editor odakli)
  if key == "Enter" then
    -- input'da calismaz: eger typing ve hedef INPUT ise engelle; contenteditable/editor ise izin ver
    if typing and tag == "INPUT" then return false end
    local app = get_app()
    if not app then return false end
    local st = app.get_state()
    -- sadece query sayfasinda veya tab varsa
    if st.route.name == "query" then
      local qmod_ok, qview = pcall(require, "views.query_editor")
      -- query_editor.run disaridan tetikle: en ustte bir fonksiyon expose edelim mi?
      -- basit: event dispatch via custom action; view kendi handle eder via register
      -- burada registry'de "Ctrl+Enter" kaydi varsa onu cagir
      for _, sc in ipairs(active_scopes()) do
        local entry = registry[sc] and registry[sc]["Ctrl+Enter"]
        if entry then
          local ok, prevent = pcall(entry.fn)
          if not ok then js.log("error", "kisayol hatasi: " .. tostring(prevent)) end
          return ok and prevent == true
        end
      end
      -- fallback: query calistir action
      app.spawn(function()
        local tab = st.query.tabs[st.query.active_tab]
        if tab then
          -- query_editor icindeki run_query'yi tetiklemek icin global event?
          -- en basit: app.dispatch ile REQUEST? view handle eder.
          -- Biz dogrudan fetch'i burada yapmiyoruz; view'in register ettigi handler var.
          -- O yuzden registry'ye birakiyoruz; yoksa sessiz.
        end
      end)
      return true
    else
      -- diger sayfalarda registry'de varsa calistir
      for _, sc in ipairs(active_scopes()) do
        local entry = registry[sc] and registry[sc]["Ctrl+Enter"]
        if entry then
          local ok, prevent = pcall(entry.fn)
          return ok and prevent == true
        end
      end
    end
    return false
  end
  if lower == "k" then
    -- Ctrl+K: command palette
    local ok, palette = pcall(require, "components.command_palette")
    if ok and palette and palette.open then palette.open() return true end
    -- registry fallback
    for _, sc in ipairs(active_scopes()) do
      local entry = registry[sc] and registry[sc]["Ctrl+K"]
      if entry then local ok2, prev = pcall(entry.fn); return ok2 and prev == true end
    end
    -- eger palette yoksa, registry'deki handler
    return true
  end
  if lower == "b" then
    local app = get_app()
    if app then app.dispatch({ type = "SIDEBAR_TOGGLED" }); return true end
    for _, sc in ipairs(active_scopes()) do
      local entry = registry[sc] and registry[sc]["Ctrl+B"]
      if entry then local ok, prev = pcall(entry.fn); return ok and prev == true end
    end
    return false
  end
  -- diger Ctrl+<tus> kayitlari (Ctrl+R yenile, Ctrl+E editor, Ctrl+F arama ...)
  local combo = "Ctrl+" .. (#key == 1 and key:upper() or key)
  for _, sc in ipairs(active_scopes()) do
    local entry = registry[sc] and registry[sc][combo]
    if entry then
      local ok, prevent = pcall(entry.fn)
      if not ok then js.log("error", "kisayol hatasi: " .. tostring(prevent)) end
      return ok and prevent == true
    end
  end
  return false
end

-- app.lua js.keyboard.onKey'den cagrilir. Donus true → JS e.preventDefault() yapar.
-- Signature: key, typing, ctrl, alt, tag
function shortcuts.handle_key(key, typing, ctrl, alt, tag)
  tag = tag or ""
  -- Alt: yalnizca kayitli Alt+<tus> kisayollari (Ctrl+N/W tarayiciya ayrilmis → Alt+N/W)
  if alt then
    local combo = "Alt+" .. (#key == 1 and key:upper() or key)
    for _, sc in ipairs(active_scopes()) do
      local entry = registry[sc] and registry[sc][combo]
      if entry then
        local ok, prevent = pcall(entry.fn)
        return ok and prevent == true
      end
    end
    return false
  end
  -- tek tus kisayollari kapatildiysa sadece ctrl'ler calisir
  local enabled = shortcuts.enabled()
  if not enabled and not ctrl then return false end

  -- Ctrl/Cmd kombinasyonlari: typing'den bagimsiz (editor icinde Ctrl+Enter dahil), ama Alt yok
  if ctrl then
    return handle_ctrl(key, typing, tag)
  end

  -- acik native dialog Esc'i kendi cancel olayiyla yonetir; diger kisayollar arka planda calismaz
  if js.dom.modalOpen and js.dom.modalOpen() then
    -- yalniz Esc dialog tarafindan yonetilir; biz mudahale etmeyelim
    return false
  end

  -- editable hedefte tek harfliler tetiklenmez (WCAG 2.1.4); yalniz Esc calisir
  if typing and key ~= "Escape" and key ~= "?" then return false end

  -- g sekansi: g -> d/c/q
  if pending_g then
    clear_pending_g()
    local app = get_app()
    if key == "d" then
      if app then require("router").navigate("#/") end
      return true
    elseif key == "c" then
      if app then require("router").navigate("#/connections") end
      return true
    elseif key == "q" then
      if app then require("router").navigate("#/query") end
      return true
    else
      -- sekans bozuldu, normal akisa devam (key'i normal handler'lara birak)
      -- fallthrough
    end
  end
  if key == "g" and not typing then
    set_pending_g()
    return true
  end

  -- ? yardim
  if key == "?" then
    for _, sc in ipairs(active_scopes()) do
      local entry = registry[sc] and registry[sc][key]
      if entry then
        local ok, prevent = pcall(entry.fn)
        if not ok then js.log("error", "kisayol hatasi: " .. tostring(prevent)) end
        return ok and prevent == true
      end
    end
    return false
  end

  -- Esc modal kapat degil, normal kisayollar icinde handle edilecek (modal yoksa nothing)
  if key == "Escape" then
    -- registry'de Escape kaydi varsa calistir (or. detail kapat)
    for _, sc in ipairs(active_scopes()) do
      local entry = registry[sc] and registry[sc][key]
      if entry then
        local ok, prevent = pcall(entry.fn)
        return ok and prevent == true
      end
    end
    return false
  end

  -- normal tek tus kisayollar (registry)
  for _, sc in ipairs(active_scopes()) do
    local entry = registry[sc] and registry[sc][key]
    if entry then
      local ok, prevent = pcall(entry.fn)
      if not ok then js.log("error", "kisayol hatasi: " .. tostring(prevent)) end
      return ok and prevent == true
    end
  end
  return false
end

return shortcuts
