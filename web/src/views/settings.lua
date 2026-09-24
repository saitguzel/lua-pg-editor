-- F20: Ayarlar — tema, per_page default, row_limit default, versiyon footer.
local dom = require("dom")
local app = require("app")
local storage = require("storage")
local theme_toggle = require("components.theme_toggle")
local types = require("pg_shared.types")

local _M = {}
_M.title = "Ayarlar"
_M.layout = true

local function per_page_options()
  return types.PAGE_SIZE_OPTIONS or { 50, 100, 250, 500 }
end

local ROW_LIMITS = { 100, 1000, 5000, 50000 }

function _M.enter() end
function _M.mounted() end

function _M.render(state, dispatch)
  local theme = state.ui.theme or "light"
  local per_page = storage.get("per_page", 100)
  if type(per_page) ~= "number" then per_page = tonumber(per_page) or 100 end
  local row_limit = storage.get("row_limit", 1000)
  if type(row_limit) ~= "number" then row_limit = tonumber(row_limit) or 1000 end

  -- version: boot config
  local version = "0.1.0"
  do
    local ok, cfg = pcall(function() return js.config and js.config() end)
    if ok and cfg then
      local ok2, dec = pcall(require("json").decode, cfg)
      if ok2 and dec and dec.version then version = dec.version end
      if ok2 and dec and dec.app_version then version = dec.app_version end
    end
    -- fallback: storage'da version var mi
    local stored = storage.get("app_version")
    if stored and type(stored) == "string" and stored ~= "" then version = stored end
  end

  local per_page_opts = {}
  for _, v in ipairs(per_page_options()) do
    per_page_opts[#per_page_opts + 1] = dom.option({ value = tostring(v), selected = per_page == v and "selected" or nil }, tostring(v))
  end
  local row_opts = {}
  for _, v in ipairs(ROW_LIMITS) do
    row_opts[#row_opts + 1] = dom.option({ value = tostring(v), selected = row_limit == v and "selected" or nil }, tostring(v))
  end

  return dom.div({ class = "max-w-2xl space-y-6" },
    dom.h1({ class = "text-2xl font-bold", tabindex = "-1" }, "Ayarlar"),
    dom.section({ class = "space-y-3 p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
      dom.h2({ class = "font-semibold" }, "Tema"),
      dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Arayuz temasi — sistem secili ise isletim sisteminizin tercihine uyar."),
      theme_toggle.render(state, dispatch),
      dom.p({ class = "text-xs text-[var(--fg-muted)]" }, "Secim otomatik kaydedilir (localStorage: pg.theme).")),
    dom.section({ class = "space-y-3 p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
      dom.h2({ class = "font-semibold" }, "Tablo varsayilanlari"),
      dom.div({ class = "grid grid-cols-1 md:grid-cols-2 gap-4" },
        dom.div({},
          dom.label({ ["for"] = "settings-per-page", class = "block text-sm font-medium mb-1" }, "Sayfa boyutu (per_page)"),
          dom.select({
            id = "settings-per-page",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
            onchange = function(e)
              local v = tonumber(e.value) or 100
              storage.set("per_page", v)
              app.toast("success", "Varsayilan sayfa boyutu " .. v .. " olarak kaydedildi")
            end,
          }, dom.list(per_page_opts)),
          dom.p({ class = "text-xs text-[var(--fg-muted)] mt-1" }, "Tablo tarayici icin varsayilan satir sayisi (50/100/250/500)")),
        dom.div({},
          dom.label({ ["for"] = "settings-row-limit", class = "block text-sm font-medium mb-1" }, "Sorgu satir limiti (row_limit)"),
          dom.select({
            id = "settings-row-limit",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
            onchange = function(e)
              local v = tonumber(e.value) or 1000
              storage.set("row_limit", v)
              app.toast("success", "Varsayilan sorgu limiti " .. v .. " olarak kaydedildi")
            end,
          }, dom.list(row_opts)),
          dom.p({ class = "text-xs text-[var(--fg-muted)] mt-1" }, "Sorgu editoru icin varsayilan limit (100/1000/5000/50000)")))),
    dom.section({ class = "space-y-2 p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
      dom.h2({ class = "font-semibold" }, "Görünüm"),
      dom.label({ class = "flex items-center gap-2 text-sm" },
        dom.input({ id = "settings-compact", type = "checkbox",
          checked = storage.get_raw("density") == "compact" and "checked" or nil,
          onchange = function(e)
            local compact = e.checked == true
            storage.set_raw("density", compact and "compact" or "comfortable")
            js.dom.setRootAttr("data-density", compact and "compact" or "comfortable")
          end }),
        "Sıkı görünüm (compact mode) — tablolarda daha fazla satır")),
    dom.section({ class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]" },
      dom.h2({ class = "font-semibold mb-2" }, "Sistem"),
      dom.dl({ class = "grid grid-cols-[10rem_1fr] gap-y-1 text-sm" },
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Uygulama"),
        dom.dd({}, "pgLua — PostgreSQL Web Editor"),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Versiyon"),
        dom.dd({ class = "font-mono" }, version),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Tema"),
        dom.dd({}, theme),
        dom.dt({ class = "text-[var(--fg-muted)]" }, "Yapim"),
        dom.dd({ class = "font-mono text-xs" }, tostring(storage.get_raw and storage.get_raw("build_mode") or "development")))),
    dom.footer({ class = "text-xs text-[var(--fg-muted)] text-center pt-4 border-t border-[var(--border)]" },
      "© 2026 pgLua · Versiyon " .. version .. " · Ayarlar tarayicida saklanir (localStorage)"))
end

return _M
