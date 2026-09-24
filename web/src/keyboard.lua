-- F21: Genel klavye yoneticisi — shortcuts.lua'yi sarar, app.start tarafindan baslatilir.
-- js.keyboard.onKey -> shortcuts.handle_key baglantisi; ayrica global kisayollari burada kaydeder.
-- Bu dosya shortcuts ile ayni API'yi sunar ama global kisayollarin tek yerden kayitlarini toplar.

local shortcuts = require("shortcuts")
local router = require("router")

local keyboard = {}

function keyboard.setup(app)
  -- global kisayollar
  shortcuts.register("global", "?", function()
    local ok, modal = pcall(require, "components.modal")
    if ok and modal.help then modal.help() end
    return true
  end, "Kisayol yardimi (? -> yardim)")

  shortcuts.register("global", "Ctrl+K", function()
    local ok, palette = pcall(require, "components.command_palette")
    if ok and palette.open then palette.open() end
    return true
  end, "Komut paleti (Ctrl+K)")

  shortcuts.register("global", "Ctrl+B", function()
    app.dispatch({ type = "SIDEBAR_TOGGLED" })
    return true
  end, "Kenar cubugu ac/kapat (Ctrl+B)")

  shortcuts.register("global", "Ctrl+Enter", function()
    -- query view kendi handler'ini register ederse o calisir; fallback burada
    local st = app.get_state()
    if st.route.name == "query" then
      -- query_editor icinde run_query'yi tetikle: view'e event gondermek yerine dogrudan dispatch
      -- view zaten editor onRun ve buton ile calistiriyor; burada toast ile bilgi ver
      -- En basit: query sayfasindaki aktif sekmeyi calistir icin custom event
      local ok2, qview = pcall(require, "views.query_editor")
      if ok2 and qview.trigger_run then pcall(qview.trigger_run) end
    end
    return true
  end, "Sorguyu calistir (Ctrl+Enter)")

  -- g sekansi icin g tusunu kaydetmiyoruz; shortcuts.handle_key icinde ozel islenir.
  -- Ama help modalinda g d/c/q aciklamalari gorunsun diye dummy kayitlar
  shortcuts.register("global", "g d", function() router.navigate("#/"); return true end, "Panoya git (g d)")
  shortcuts.register("global", "g c", function() router.navigate("#/connections"); return true end, "Baglantilara git (g c)")
  shortcuts.register("global", "g q", function() router.navigate("#/query"); return true end, "Sorguya git (g q)")

  -- query sayfasi icin ek kisayollar (editor odakli degilse de calisir)
  shortcuts.register("query", "Ctrl+Enter", function()
    local ok2, qview = pcall(require, "views.query_editor")
    if ok2 and qview.trigger_run then pcall(qview.trigger_run) end
    return true
  end, "Sorguyu calistir")

  -- codd: Esc calisan sorguyu iptal eder (autocomplete acikken CodeMirror Esc'i kendisi tuketir)
  shortcuts.register("query", "Escape", function()
    local ok2, qview = pcall(require, "views.query_editor")
    return ok2 and qview.cancel_run() or false
  end, "Çalışan sorguyu iptal et (Esc)")

  -- sorgu sekmeleri (codd Ctrl+N/W; tarayici bu tuslari sayfaya birakmadigi icin Alt ile)
  local function qe() return require("views.query_editor") end
  shortcuts.register("query", "Alt+N", function() qe().new_tab(); return true end, "Yeni sorgu sekmesi (Alt+N)")
  shortcuts.register("query", "Alt+W", function() qe().close_active_tab(); return true end, "Sekmeyi kapat (Alt+W)")
  shortcuts.register("query", "Ctrl+E", function() qe().focus_editor(); return true end, "SQL editörüne odaklan (Ctrl+E)")

  -- tablo tarayici (codd): Delete odakli satiri siler, Ctrl+R yeniler
  shortcuts.register("browse", "Delete", function()
    return require("views.table_browser").delete_focused()
  end, "Seçili satırı sil (Delete)")
  shortcuts.register("browse", "Ctrl+R", function()
    require("views.table_browser").reload()
    return true
  end, "Tabloyu yenile (Ctrl+R)")

  -- nesne kenar cubugu olan sayfalar (codd): F5 nesneleri yeniler, Ctrl+F nesne aramasina odaklanir
  for _, scope in ipairs({ "query", "browse", "structure" }) do
    shortcuts.register(scope, "F5", function() require("views.schema_sidebar").reload(); return true end,
      "Veritabanı nesnelerini yenile (F5)")
    shortcuts.register(scope, "Ctrl+F", function() return require("views.schema_sidebar").focus_search() end,
      "Nesne ara (Ctrl+F)")
  end

  -- connections sayfasi: n yeni baglanti
  -- shortcuts.register("connections", "n", function() app.dispatch({type="CONNECTION_EDIT_OPENED", id="new"}); return true end, "Yeni baglanti")

  js.keyboard.onKey(function(key, typing, ctrl, alt, tag)
    return shortcuts.handle_key(key, typing, ctrl, alt, tag)
  end)
end

keyboard.shortcuts = shortcuts

return keyboard
