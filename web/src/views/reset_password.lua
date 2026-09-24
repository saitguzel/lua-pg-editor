-- Şifre sıfırlama — pg-editor. Token URL'den okunup hemen history.replace ile silinir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local validation = require("pg_shared.validation")
local protocol = require("pg_shared.protocol")
local icons = require("icons")

local _M = {}
_M.title = "Yeni parola"
_M.layout = false
_M.public = true

local function token_valid(token)
  return type(token) == "string" and #token == 64 and token:match("^%x+$") ~= nil
end

local held_token = nil

function _M.enter(route)
  if route.query and route.query.token then
    held_token = route.query.token
    router.navigate("#/reset-password", { silent = true })
  end
end

function _M.render(state)
  local errors = (state.ui.form_errors or {}).reset or {}
  local done = state.ui.reset_done or false

  if done then
    return dom.main({ class = "min-h-screen flex items-center justify-center p-3 sm:p-4", id = "main", tabindex = "-1" },
      dom.div({ class = "w-full max-w-sm text-center", role = "status" },
        dom.div({ class = "flex justify-center mb-2 text-[var(--success)]" }, icons.get("check", "w-8 h-8")),
        dom.h1({ class = "text-lg sm:text-xl font-bold mb-2" }, "Parolanız güncellendi"),
        dom.a({ href = "#/login", class = "inline-flex items-center gap-1 text-[var(--primary)] underline" },
          icons.get("log-in", "w-4 h-4"), "Giriş yap")))
  end

  local token = held_token or (state.route and state.route.query and state.route.query.token)
  if not token_valid(token) then
    return dom.main({ class = "min-h-screen flex items-center justify-center p-3 sm:p-4", id = "main", tabindex = "-1" },
      dom.div({ class = "w-full max-w-sm text-center" },
        dom.div({ class = "flex justify-center mb-2 text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
        dom.h1({ class = "text-lg sm:text-xl font-bold mb-2" }, "Bağlantı geçersiz"),
        dom.p({ class = "text-sm text-[var(--fg-muted)] mb-4" },
          "Bu sıfırlama bağlantısı geçersiz veya eksık."),
        dom.a({ href = "#/forgot-password", class = "inline-flex items-center gap-1 text-[var(--primary)] underline" },
          icons.get("mail", "w-4 h-4"), "Yeni bağlantı iste")))
  end

  return dom.main({ class = "min-h-screen flex items-center justify-center p-3 sm:p-4", id = "main", tabindex = "-1" },
    dom.form({
      class = "w-full max-w-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-4 sm:p-6 " ..
        "shadow-[var(--shadow)]",
      ["aria-labelledby"] = "reset-title",
      onsubmit = function()
        local p1 = dom.value("new-password") or ""
        local p2 = dom.value("new-password-confirm") or ""
        app.spawn(function() _M.submit(token, p1, p2) end)
      end,
    },
      dom.h1({ id = "reset-title", class = "text-lg sm:text-xl font-bold mb-4 flex items-center gap-2" },
        icons.get("key", "w-5 h-5 text-[var(--primary)] shrink-0"), "Yeni parola belirleyin"),
      dom.div({ role = "alert", class = errors._ and "field-error mb-2 flex items-center gap-1.5" or "" },
        errors._ and icons.get("alert-circle", "w-4 h-4") or nil, errors._ and errors._[1] or nil),
      dom.div({ class = "mb-3" },
        dom.label({ ["for"] = "new-password", class = "block text-sm font-medium mb-1 flex items-center gap-1" },
          icons.get("key", "w-3.5 h-3.5 text-[var(--fg-muted)]"), "Yeni parola"),
        dom.input({
          id = "new-password", type = "password", required = "required", minlength = "8",
          autocomplete = "new-password",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          oninput = function(e)
            local v = e.value or ""
            local score = 0
            if #v >= 8 then score = score + 1 end
            if v:match("%u") and v:match("%l") then score = score + 1 end
            if v:match("%d") then score = score + 1 end
            local label = ({ "Zayıf", "Orta", "İyi", "Güçlü" })[score + 1] or ""
            local el = js.dom.byId("pw-strength")
            if el then
              js.dom.setText(el, "Parola gücü: " .. label)
              js.dom.release(el)
            end
          end,
        }),
        dom.p({ id = "pw-strength", class = "text-xs text-[var(--fg-muted)] mt-1", ["aria-live"] = "polite" }, "")),
      dom.div({ class = "mb-4" },
        dom.label({ ["for"] = "new-password-confirm", class = "block text-sm font-medium mb-1 flex items-center gap-1" },
          icons.get("key", "w-3.5 h-3.5 text-[var(--fg-muted)]"), "Parolayı onayla"),
        dom.input({
          id = "new-password-confirm", type = "password", required = "required", minlength = "8",
          autocomplete = "new-password",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
        }),
        errors.new_password and dom.p({ class = "field-error" }, errors.new_password[1]) or nil),
      dom.button({
        type = "submit",
        class = "w-full py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] font-medium inline-flex items-center justify-center gap-1.5",
      }, icons.get("check", "w-4 h-4"), "Parolayı güncelle")))
end

function _M.submit(token, password, confirm)
  if password ~= confirm then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "reset", errors = { _ = { "Parolalar eşleşmiyor" } } })
    dom.focus("new-password-confirm")
    return
  end

  local clean, errs = validation.validate(validation.schemas.reset_password, { token = token, new_password = password })
  if not clean then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "reset", errors = errs })
    dom.focus("new-password")
    return
  end

  local _, err = api.post("/auth/reset-password", clean)
  if err then
    if err.code == "RESET_TOKEN_INVALID" then
      app.dispatch({ type = "FORM_ERRORS_SET", form = "reset",
        errors = { _ = { "Bağlantının süresi dolmuş veya kullanılmış" } } })
    else
      app.dispatch({ type = "FORM_ERRORS_SET", form = "reset",
        errors = errs or { _ = { protocol.message(err.code) } } })
    end
    return
  end

  held_token = nil
  app.dispatch({ type = "RESET_DONE" })
  app.toast("success", "Parolanız güncellendi")
  js.timer.after(1200, function() router.navigate("#/login") end)
end

return _M
