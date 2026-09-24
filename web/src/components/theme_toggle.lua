-- F16: Tema tercihi: "light" | "dark" | "system". data-theme attribute'u tüm UI'ı çevirir;
-- "system" seçiliyken OS teması değişirse anında uygulanır (app.start media dinleyicisi).

local dom = require("dom")
local icons = require("icons")

local theme_toggle = {}

local ICON_FOR = { light = "sun", dark = "moon", system = "monitor" }

-- header'daki kompakt sürüm: tek buton, döngüsel geçiş
function theme_toggle.render_compact(state, dispatch)
  local order = { "light", "dark", "system" }
  local next_pref = "system"
  for i, p in ipairs(order) do
    if p == state.ui.theme then next_pref = order[(i % #order) + 1] break end
  end
  local label = ({ light = "Açık", dark = "Koyu", system = "Sistem" })[state.ui.theme] or state.ui.theme
  local icon_name = ICON_FOR[state.ui.theme] or "sun"
  return dom.button({
    class = "btn btn-ghost btn-icon btn-sm",
    ["aria-label"] = "Tema: " .. label .. ". Değiştir",
    title = "Tema: " .. label .. " (tıkla değiştir)",
    onclick = function() dispatch({ type = "THEME_SET", theme = next_pref }) end,
  }, icons.get(icon_name, "w-4 h-4"))
end

-- profil sayfasındaki radiogroup sürümü
function theme_toggle.render(state, dispatch)
  local current = state.ui.theme
  local options = {
    { pref = "light", icon = "sun", label = "Açık" },
    { pref = "dark", icon = "moon", label = "Koyu" },
    { pref = "system", icon = "monitor", label = "Sistem" },
  }
  local buttons = {}
  for _, o in ipairs(options) do
    buttons[#buttons + 1] = dom.button({
      role = "radio",
      ["aria-checked"] = tostring(current == o.pref),
      class = "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-[var(--radius)] border text-sm "
        .. (current == o.pref and "border-[var(--primary)] text-[var(--primary)] bg-[color-mix(in_srgb,var(--primary)_10%,transparent)]" or "border-[var(--border)] hover:bg-[var(--bg)]"),
      onclick = function() dispatch({ type = "THEME_SET", theme = o.pref }) end,
    }, icons.get(o.icon, "w-4 h-4"), dom.span({}, o.label))
  end
  return dom.div({ role = "radiogroup", ["aria-label"] = "Tema", class = "flex gap-2 flex-wrap" }, dom.list(buttons))
end

return theme_toggle
