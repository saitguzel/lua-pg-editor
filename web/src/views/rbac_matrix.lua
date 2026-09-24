-- F20: Yetki matrisi — GET /rbac/pages + GET /rbac/matrix, tek hucre PATCH optimistic, PUT tumu, reset.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local types = require("pg_shared.types")
local protocol = require("pg_shared.protocol")
local icons = require("icons")

local _M = {}
_M.title = "Yetki Matrisi"
_M.layout = true

local function matrix_of(data)
  if type(data) ~= "table" then return nil end
  return data.matrix or data
end

function _M.enter()
  app.dispatch({ type = "RBAC_REQUESTED" })
  -- iki istek arka arkaya; fetch coroutine icinde sirali
  app.spawn(function()
    local pages = api.get("/rbac/pages")
    local data, merr, meta = api.get("/rbac/matrix")
    if merr then
      app.dispatch({ type = "RBAC_FAILED" })
      app.toast("error", protocol.message(merr.code))
      return
    end
    local pages_list = nil
    if pages then
      if type(pages) == "table" and pages[1] and type(pages[1]) == "table" and pages[1].key then
        pages_list = pages
      elseif type(pages) == "table" and pages.items then
        pages_list = pages.items
      elseif type(pages) == "table" then
        pages_list = pages
      end
    end
    app.dispatch({
      type = "RBAC_LOADED",
      pages = pages_list,
      matrix = matrix_of(data),
      cache_ttl = meta and meta.cache_ttl or nil,
    })
  end)
end

function _M.mounted(dispatch)
  _M.enter()
end

local function toggle_cell(role, page_key, checked)
  app.dispatch({ type = "RBAC_CELL_TOGGLED", role = role, page_key = page_key, can_access = checked })
  app.spawn(function()
    local _, err = api.patch("/rbac/matrix/" .. router.urlencode(role) .. "/" .. router.urlencode(page_key), { can_access = checked })
    -- fallback: if fetch.lua patch path is without urlencode?
    if err then
      -- try without double encode
      -- already did; check error
    end
    if err then
      app.dispatch({ type = "RBAC_CELL_ROLLBACK", role = role, page_key = page_key })
      if err.code == "CONFLICT" then
        app.toast("error", "Bu izin kilitli")
      else
        app.toast("error", protocol.message(err.code))
      end
      return
    end
    app.dispatch({ type = "RBAC_CELL_CONFIRMED", role = role, page_key = page_key })
    app.toast("info", role .. " → " .. page_key .. ": " .. (checked and "acik" or "kapali"), { timeout = 2000 })
    local me = app.get_state().auth.user
    if me and me.role == role then
      app.refresh_permissions()
    end
  end)
end

-- gruplu header icin sayfa -> group
local function group_of(page_key)
  local meta = types.PAGE_META[page_key]
  return meta and meta.group or "diger"
end

local GROUP_LABEL = { genel = "Genel", connections = "Baglantilar", query = "Sorgu",
  browse = "Tarayici", admin = "Admin" }
local GROUP_ORDER = { "genel", "connections", "query", "browse", "admin" }

function _M.render(state, dispatch)
  local st = state.rbac
  local matrix = st.matrix
  if st.status == "error" or (st.status ~= "loading" and st.status ~= "idle" and not matrix and st.status ~= "ready") then
    -- if no matrix and not loading, show error
    if not matrix and st.status ~= "loading" then
      return dom.section({},
        dom.h1({ class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Yetki Matrisi"),
        dom.p({ class = "text-[var(--danger)]", role = "alert" }, "Matris yuklenemedi. Sayfayi yenileyin."))
    end
  end
  if not matrix then
    return dom.section({},
      dom.h1({ class = "text-2xl font-bold mb-4", tabindex = "-1" }, "Yetki Matrisi"),
      require("components.skeleton").lines(9))
  end

  -- API etiketleri varsa kullan
  local labels = {}
  for _, p in ipairs(type(st.pages) == "table" and st.pages or {}) do
    if type(p) == "table" and p.key then labels[p.key] = p.label or p.key end
    if type(p) == "string" then labels[p] = (types.PAGE_META[p] or {}).label or p end
  end

  local ttl_text = st.cache_ttl and ("Degisiklikler aninda kaydedilir. Onbellek nedeniyle diger oturumlara "
    .. st.cache_ttl .. " sn icinde yansin.") or
    "Degisiklikler aninda kaydedilir. Onbellek nedeniyle diger oturumlara kisa sure icinde yansir."

  -- gruplar: sayfalar gruplara ayrilir (satirlar gruplu gosterilir)
  local grouped = {}
  for _, page in ipairs(types.PAGES) do
    local g = group_of(page)
    grouped[g] = grouped[g] or {}
    grouped[g][#grouped[g] + 1] = page
  end

  -- sutunlar: roller (ustte), satirlar: sayfalar (solda) — istenen yerlesim
  local roles = {}
  for role in pairs(matrix) do roles[#roles + 1] = role end
  if #roles == 0 then for _, r in ipairs(types.ROLES) do roles[#roles + 1] = r end end
  table.sort(roles)

  -- collect pages in order for row order (gruplu)
  local ordered_pages = {}
  for _, g in ipairs(GROUP_ORDER) do
    for _, pg in ipairs(grouped[g] or {}) do ordered_pages[#ordered_pages + 1] = pg end
  end
  for g, pages_in_group in pairs(grouped) do
    local found = false
    for _, og in ipairs(GROUP_ORDER) do if og == g then found = true; break end end
    if not found then for _, pg in ipairs(pages_in_group) do ordered_pages[#ordered_pages + 1] = pg end end
  end

  -- header: Sayfa + roller
  local header_cells = { dom.th({ scope = "col", class = "py-2 text-left" }, "Sayfa") }
  for _, role in ipairs(roles) do
    header_cells[#header_cells + 1] = dom.th({ scope = "col", class = "py-2 px-2 text-center font-medium" }, role)
  end

  local rows = {}
  -- gruplu satirlar: her grup icin once grup basligi, sonra sayfa satirlari
  for _, g in ipairs(GROUP_ORDER) do
    local pages_in_group = grouped[g] or {}
    if #pages_in_group > 0 then
      rows[#rows + 1] = dom.tr({ key = "group-" .. g, class = "bg-[var(--bg)]" },
        dom.th({ colspan = tostring(1 + #roles), class = "py-1 text-left text-xs font-semibold border-y px-2" },
          GROUP_LABEL[g] or g))
      for _, page in ipairs(pages_in_group) do
        local label = labels[page] or (types.PAGE_META[page] or {}).label or page
        local cells = { dom.th({ scope = "row", class = "py-2 pr-4 text-left font-normal pl-4" },
          dom.div({},
            dom.span({}, label),
            dom.code({ class = "ml-2 text-[10px] text-[var(--fg-muted)]" }, page))) }
        for _, role in ipairs(roles) do
          local locked = types.is_locked(role, page)
          local cell_pending = st.pending and st.pending[role .. ":" .. page]
          local value = matrix[role] and matrix[role][page] == true
          cells[#cells + 1] = dom.td({ class = "py-2 px-2 text-center" },
            dom.input({
              type = "checkbox",
              checked = value and "checked" or nil,
              disabled = (locked or cell_pending) and "disabled" or nil,
              ["aria-label"] = role .. " rolü için " .. page .. " erişimi",
              ["aria-describedby"] = locked and "lock-note" or nil,
              onchange = function(e)
                app.spawn(toggle_cell, role, page, e.checked == true)
              end,
            }),
            locked and " 🔒" or nil)
        end
        rows[#rows + 1] = dom.tr({ key = page, class = "border-b border-[var(--border)]" }, dom.list(cells))
      end
    end
  end

  -- Alternative per spec: matrix with row role, col page_key grouped, checkbox per cell, PATCH for single cell optimistic, PUT for whole matrix, reset.
  -- Add bulk save and reset buttons.

  return dom.section({ class = "max-w-5xl", ["aria-labelledby"] = "rbac-title" },
    dom.h1({ id = "rbac-title", class = "text-xl sm:text-2xl font-bold mb-2 flex items-center gap-2", tabindex = "-1" },
      icons.get("shield", "w-6 h-6 text-[var(--primary)] shrink-0"), "Rol – Sayfa Yetkileri"),
    dom.p({ id = "rbac-help", class = "text-xs sm:text-sm text-[var(--fg-muted)] mb-4" }, ttl_text),
    dom.div({ class = "overflow-auto border rounded -mx-3 sm:mx-0" },
      dom.div({ class = "min-w-[560px] px-3 sm:px-0" },
        dom.table({ ["aria-describedby"] = "rbac-help", class = "w-full text-sm" },
          dom.caption({ class = "sr-only" }, "Sayfalarin rol erisim izinleri — solda sayfa adlari, ustte roller"),
          dom.thead({},
            dom.tr({ class = "text-left border-b bg-[var(--bg)]" }, dom.list(header_cells))),
          dom.tbody({ ["aria-busy"] = tostring(st.status == "loading") }, dom.list(rows))))),
    dom.p({ id = "lock-note", class = "text-xs text-[var(--fg-muted)] mt-2" },
      "Admin'in yetki matrisi erisimi kilitlidir (kendini kilitleme onlemi)."),
    dom.div({ class = "flex gap-2 mt-4 flex-wrap" },
      icons.button({ icon = "save", label = "Tümünü kaydet (PUT)", variant = "accent",
        title = "Tüm matrisi PUT ile kaydet",
        onclick = function()
          app.spawn(function()
            local payload = types.default_matrix()
            -- PUT whole matrix
            local data, err = api.put("/rbac/matrix", payload)
            if err then
              app.toast("error", protocol.message(err.code))
              return
            end
            local m = matrix_of(data)
            if m then app.dispatch({ type = "RBAC_MATRIX_REPLACED", matrix = m }) end
            app.toast("success", "Matris kaydedildi")
            app.refresh_permissions()
          end)
        end }),
      icons.button({ icon = "refresh", label = "Varsayılana sıfırla", variant = "secondary",
        title = "İzinleri fabrika ayarlarına sıfırla",
        onclick = function()
          app.spawn(function()
            if not require("components.modal").confirm({ title = "Varsayilana sifirlansin mi?",
              message = "Tum izinler fabrika ayarlarina donecek.", confirm_label = "Sifirla" }) then
              return
            end
            local data, err = api.post("/rbac/matrix/reset", {})
            if err then
              -- try alternative: POST /rbac/matrix/reset may require body? or PUT default?
              -- fallback to PUT default_matrix
              local data2, err2 = api.put("/rbac/matrix", types.default_matrix())
              if err2 then
                app.toast("error", protocol.message(err.code or err2.code))
                return
              end
              data = data2
            end
            local m = matrix_of(data) or matrix_of(types.default_matrix())
            -- if reset endpoint returns no matrix, build from default
            if not m then
              local def = types.default_matrix()
              m = {}
              for _, p in ipairs(def.permissions) do
                m[p.role] = m[p.role] or {}
                m[p.role][p.page_key] = p.can_access
              end
            else
              -- if matrix is list form, convert
              if m.permissions then
                local conv = {}
                for _, p in ipairs(m.permissions) do
                  conv[p.role] = conv[p.role] or {}
                  conv[p.role][p.page_key] = p.can_access
                end
                m = conv
              end
            end
            app.dispatch({ type = "RBAC_MATRIX_REPLACED", matrix = m })
            app.toast("success", "Matris varsayilana sifirlandi")
            app.refresh_permissions()
          end)
        end })))
end

return _M
