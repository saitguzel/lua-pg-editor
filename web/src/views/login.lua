-- Giriş ekranı — pg-editor. Shared şema ile doğrular; hatalı girişte e-posta varlığını ifşa etmez.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local storage = require("storage")
local validation = require("pg_shared.validation")
local protocol = require("pg_shared.protocol")
local icons = require("icons")

local _M = {}
_M.title = "Giriş"
_M.layout = false
_M.public = true

-- Demo hesaplar yalnızca production olmayan build'de: listeyi build-wasm.sh build_info modülüne gömer
-- (prod bundle'ında kimlik bilgisi yok; prod'da SEED_DEFAULTS=false olduğundan hesaplar da yok)
local info_ok, build_info = pcall(require, "build_info")
local DEMO_ACCOUNTS = info_ok and type(build_info) == "table" and type(build_info.demo) == "table"
  and build_info.demo or nil
_M.show_demo = DEMO_ACCOUNTS ~= nil

local function demo_box()
  local rows = {}
  for _, acc in ipairs(DEMO_ACCOUNTS or {}) do
    rows[#rows + 1] = dom.li({},
      dom.button({
        type = "button",
        class = "w-full text-left px-3 py-2 min-h-11 rounded-[var(--radius)] hover:bg-[var(--bg)] focus:bg-[var(--bg)]",
        ["aria-label"] = acc.label .. " hesabıyla doldur: " .. acc.email,
        onclick = function()
          dom.set_value("email", acc.email)
          dom.set_value("password", acc.password)
          dom.focus("login-submit")
        end,
      },
        dom.span({ class = "font-medium" }, acc.label .. ": "),
        dom.code({}, acc.email), " / ", dom.code({}, acc.password)))
  end
  return dom.section({
    class = "w-full max-w-sm mt-4 text-sm border border-dashed border-[var(--border)] rounded-[var(--radius)] p-3",
    ["aria-labelledby"] = "demo-title",
  },
    dom.h2({ id = "demo-title", class = "font-semibold mb-1" }, "Demo hesaplar"),
    dom.p({ class = "text-xs text-[var(--fg-muted)] mb-2" }, "Tıklayınca giriş alanları doldurulur."),
    dom.ul({ role = "list" }, rows))
end

function _M.render(state, dispatch)
  local errors = (state.ui.form_errors or {}).login or {}
  local busy = state.ui.busy.login or false

  return dom.main({ class = "min-h-screen flex flex-col items-center justify-center p-4", id = "main",
    tabindex = "-1" },
    dom.form({
      class = "w-full max-w-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] " ..
        "shadow-[var(--shadow)] p-6",
      ["aria-labelledby"] = "login-title",
      onsubmit = function()
        local email = dom.value("email") or ""
        local password = dom.value("password") or ""
        app.spawn(function() _M.submit(email, password, dispatch) end)
      end,
    },
      dom.h1({ id = "login-title", class = "text-xl font-bold mb-4 flex items-center gap-2" },
        icons.get("log-in", "w-5 h-5 text-[var(--primary)]"), "Giriş yap"),
      dom.div({ role = "alert", ["aria-live"] = "assertive", class = errors._ and "field-error mb-2 flex items-center gap-1.5" or "" },
        errors._ and icons.get("alert-circle", "w-4 h-4") or nil, errors._ and errors._[1] or nil),
      dom.div({ class = "mb-3" },
        dom.label({ ["for"] = "email", class = "block text-sm font-medium mb-1 flex items-center gap-1" },
          icons.get("mail", "w-3.5 h-3.5 text-[var(--fg-muted)]"), "E-posta"),
        dom.input({
          id = "email", name = "email", type = "email", autocomplete = "username", required = "required",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-describedby"] = errors.email and "email-err" or nil,
          ["aria-invalid"] = errors.email and "true" or nil,
        }),
        errors.email and dom.p({ id = "email-err", class = "field-error" }, errors.email[1]) or nil),
      dom.div({ class = "mb-4" },
        dom.label({ ["for"] = "password", class = "block text-sm font-medium mb-1 flex items-center gap-1" },
          icons.get("key", "w-3.5 h-3.5 text-[var(--fg-muted)]"), "Parola"),
        dom.input({
          id = "password", name = "password", type = "password", autocomplete = "current-password",
          required = "required", minlength = "8",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-describedby"] = errors.password and "password-err" or nil,
          ["aria-invalid"] = errors.password and "true" or nil,
        }),
        errors.password and dom.p({ id = "password-err", class = "field-error" }, errors.password[1]) or nil),
      dom.button({
        type = "submit", id = "login-submit",
        class = "w-full py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] font-medium inline-flex items-center justify-center gap-1.5 disabled:opacity-50",
        ["aria-busy"] = tostring(busy),
        disabled = busy and "disabled" or nil,
      }, icons.get(busy and "clock" or "log-in", "w-4 h-4"), busy and "Gönderiliyor…" or "Giriş yap"),
      dom.div({ class = "mt-4 text-center text-sm" },
        dom.a({ href = "#/forgot-password", class = "inline-flex items-center gap-1 text-[var(--primary)] underline" },
          icons.get("mail", "w-3.5 h-3.5"), "Şifremi unuttum"))),
    _M.show_demo and demo_box())
end

function _M.submit(email, password, dispatch)
  dispatch({ type = "LOGIN_REQUESTED" })

  local clean, errs = validation.validate(validation.schemas.login, { email = email, password = password })
  if not clean then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "login", errors = errs })
    app.dispatch({ type = "BUSY_SET", key = "login", value = false })
    local first = errs.email and "email" or (errs.password and "password" or nil)
    if first then dom.focus(first) end
    return
  end

  local data, err = api.post("/auth/login", clean)
  app.dispatch({ type = "BUSY_SET", key = "login", value = false })

  if err then
    local msg
    if err.code == "INVALID_CREDENTIALS" then
      msg = "E-posta veya parola hatalı"
    elseif err.code == "RATE_LIMITED" then
      msg = err.retry_after
        and ("Çok fazla deneme. " .. math.ceil(err.retry_after) .. " saniye sonra tekrar deneyin.")
        or "Çok fazla deneme. Lütfen bir süre sonra tekrar deneyin."
    elseif err.code == "ACCOUNT_DISABLED" then
      msg = "Hesabınız pasif. Yöneticiye başvurun."
    elseif err.code == "NETWORK_ERROR" then
      msg = "Sunucuya ulaşılamadı"
    else
      msg = protocol.message(err.code)
    end
    app.dispatch({ type = "FORM_ERRORS_SET", form = "login", errors = { _ = { msg } } })
    dom.set_value("password", "")
    dom.focus("password")
    return
  end

  if data and data.access_token then
    storage.set("auth", { access_token = data.access_token, refresh_token = data.refresh_token })
  end

  app.dispatch({ type = "LOGIN_SUCCEEDED", user = data.user, permissions = data.permissions or {} })

  local st = app.get_state()
  local next_hash = st.route and st.route.query and router.safe_next(st.route.query.next)
  router.navigate(next_hash or "#/", { replace = true })
end

return _M
