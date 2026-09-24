-- F21: Genel klavye yoneticisi — shortcuts.lua'yi sarar, app.start tarafindan baslatilir.
-- js.keyboard.onKey -> shortcuts.handle_key bağlantısi; ayrica global kisayollari burada kaydeder.
-- Bu dosya shortcuts ile ayni API'yi sunar ama global kisayollarin tek yerden kayıtlarini toplar.

local shortcuts = require("shortcuts")
local router = require("router")

local keyboard = {}

function keyboard.setup(app)
  -- global kisayollar
  shortcuts.register("global", "?", function()
    local ok, modal = pcall(require, "components.modal")
    if ok and modal.help then modal.help() end
    return true
  end, "Yardım ve kısayollar")

  shortcuts.register("global", "Ctrl+K", function()
    local ok, palette = pcall(require, "components.command_palette")
    if ok and palette.open then palette.open() end
    return true
  end, "Komut paleti")

  shortcuts.register("global", "Ctrl+B", function()
    app.dispatch({ type = "SIDEBAR_TOGGLED" })
    return true
  end, "Kenar çubuğunu daralt/genişlet")

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
  end, "Sorguyu çalıştır (seçim varsa seçimi)")

  -- g sekansi icin g tusunu kaydetmiyoruz; shortcuts.handle_key icinde ozel islenir.
  -- Ama help modalinda g d/c/q aciklamalari gorunsun diye dummy kayıtlar
  shortcuts.register("global", "g d", function() router.navigate("#/"); return true end, "Panoya git")
  shortcuts.register("global", "g c", function() router.navigate("#/connections"); return true end, "Bağlantılara git")
  shortcuts.register("global", "g q", function() router.navigate("#/query"); return true end, "Sorguya git")

  -- query sayfasi icin ek kisayollar (editor odakli degilse de calisir)
  shortcuts.register("query", "Ctrl+Enter", function()
    local ok2, qview = pcall(require, "views.query_editor")
    if ok2 and qview.trigger_run then pcall(qview.trigger_run) end
    return true
  end, "Sorguyu çalıştır (seçim varsa seçimi)")

  -- F29: CodeMirror içi tuşlar yalnız yardım listesi için ("editor" scope'u hiçbir route ile eşleşmez)
  shortcuts.register("editor", "Tab", function() return false end, "Tamamlamayı kabul et; öneri yoksa 4 boşluk")
  shortcuts.register("editor", "Ctrl+Z", function() return false end, "Geri al (Temizle ve Formatla dahil)")
  shortcuts.register("editor", "Ctrl+Space", function() return false end, "Tamamlama önerilerini aç")

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
  shortcuts.register("query", "Alt+L", function() return qe().clear_screen() end, "Ekranı temizle (Alt+L)")
  shortcuts.register("query", "Ctrl+J", function() return qe().open_snippets() end, "Taslak ekle (Ctrl+J)")
  shortcuts.register("query", "Ctrl+I", function() return qe().toggle_ai() end, "AI ile SQL oluştur (Ctrl+I)")
  shortcuts.register("query", "Alt+S", function() return qe().save_as_snippet() end,
    "Seçimi taslak olarak kaydet (Alt+S)")
  -- F27: Shift kombinasyonları registry'de yalnız yardım listesi için; eşleme aşağıdaki onKey sarmalayıcısında
  shortcuts.register("query", "Ctrl+Shift+Enter", function() return qe().run_selection() end,
    "Yalnız seçili SQL'i çalıştır (Ctrl+Shift+Enter)")
  shortcuts.register("query", "Ctrl+Shift+F", function() return qe().format_sql() end,
    "SQL'i biçimle (Ctrl+Shift+F)")

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

  -- connections sayfasi: n yeni bağlantı
  -- shortcuts.register("connections", "n", function() app.dispatch({type="CONNECTION_EDIT_OPENED", id="new"}); return true end, "Yeni bağlantı")

  js.keyboard.onKey(function(key, typing, ctrl, alt, tag, shift)
    -- Ctrl+Shift+<tuş>: CodeMirror kendi keymap'iyle tüketir (defaultPrevented); textarea yedeği ve odak
    -- editör dışındayken burada eşlenir
    if ctrl and shift and not alt and app.get_state().route.name == "query" then
      local fn = key == "Enter" and function() return qe().run_selection() end
        or (key:lower() == "f" and function() return qe().format_sql() end) or nil
      if fn then
        local ok, prevent = pcall(fn)
        return ok and prevent == true
      end
    end
    return shortcuts.handle_key(key, typing, ctrl, alt, tag)
  end)
end

keyboard.shortcuts = shortcuts

return keyboard
