-- Satır içi SVG ikonlar (Lucide, ISC lisansı; 24x24, stroke=currentColor). Kütüphane yok:
-- her ikon path listesi; icons.get(ad, class) vnode döner. glue.js svg/path'i SVG ad alanında oluşturur.
local dom = require("dom")

local icons = {}

local P = {
  play = { "M6 3l14 9-14 9V3z" },
  stop = { "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" },
  trash = { "M3 6h18", "M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6", "M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2" },
  eraser = { "m7 21-4.3-4.3c-1-1-1-2.5 0-3.4l9.6-9.6c1-1 2.5-1 3.4 0l5.6 5.6c1 1 1 2.5 0 3.4L13 21",
    "M22 21H7", "m5 11 9 9" },
  download = { "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "M7 10l5 5 5-5", "M12 15V3" },
  history = { "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", "M3 3v5h5", "M12 7v5l4 2" },
  sparkles = { "M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14"
    .. "a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44"
    .. " 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z", "M20 3v4", "M22 5h-4" },
  wand = { "M15 4V2", "M15 16v-2", "M8 9h2", "M20 9h2", "M17.8 11.8 19 13", "M17.8 6.2 19 5", "m3 21 9-9",
    "M12.2 6.2 11 5" },
  save = { "M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z", "M17 21v-8H7v8", "M7 3v5h8" },
  code = { "m16 18 6-6-6-6", "m8 6-6 6 6 6" },
  ["file-code"] = { "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6",
    "m10 13-2 2 2 2", "m14 17 2-2-2-2" },
  ["function"] = { "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z",
    "M9 17c2 0 2.8-1 2.8-2.8V10c0-2 1-3.3 3.2-3", "M9 11.2h5.7" },
  procedure = { "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z", "m10 8 6 4-6 4V8z" },
  zap = { "M13 2 3 14h9l-1 8 10-12h-9l1-8z" },
  table = { "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z", "M3 9h18", "M3 15h18",
    "M12 3v18" },
  eye = { "M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7z", "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z" },
  refresh = { "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8", "M21 3v5h-5" },
  plus = { "M5 12h14", "M12 5v14" },
  edit = { "M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5z" },
  copy = { "M10 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2z",
    "M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" },
  search = { "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14z", "m21 21-4.3-4.3" },
  ["chevron-down"] = { "m6 9 6 6 6-6" },
  ["chevron-left"] = { "m15 18-6-6 6-6" },
  ["chevron-right"] = { "m9 18 6-6-6-6" },
  ["panel-left"] = { "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z", "M9 3v18" },
  settings = { "M4 21v-7", "M4 10V3", "M12 21v-9", "M12 8V3", "M20 21v-5", "M20 12V3", "M2 14h4", "M10 8h4",
    "M18 16h4" },
  check = { "M20 6 9 17l-5-5" },
  x = { "M18 6 6 18", "m6 6 12 12" },
  dashboard = { "M3 3h7v7H3z", "M14 3h7v7h-7z", "M14 14h7v7h-7z", "M3 14h7v7H3z" },
  plug = { "M12 22v-5", "M9 8V2", "M15 8V2", "M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8z" },
  terminal = { "m4 17 6-6-6-6", "M12 19h8" },
  users = { "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8z",
    "M22 21v-2a4 4 0 0 0-3-3.87", "M16 3.13a4 4 0 0 1 0 7.75" },
  shield = { "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2"
    .. " 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" },
  list = { "M3 12h.01", "M3 18h.01", "M3 6h.01", "M8 12h13", "M8 18h13", "M8 6h13" },
  database = { "M3 5c0-1.66 4-3 9-3s9 1.34 9 3-4 3-9 3-9-1.34-9-3z", "M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5",
    "M3 12c0 1.66 4 3 9 3s9-1.34 9-3" },
  menu = { "M4 6h16", "M4 12h16", "M4 18h16" },
  logout = { "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4", "m16 17 5-5-5-5", "M21 12H9" },
  ["log-in"] = { "M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4", "m10 17 5-5-5-5", "M15 12H3" },
  ["log-out"] = { "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4", "m16 17 5-5-5-5", "M21 12H9" },
  filter = { "M22 3H2l8 9.46a1 1 0 0 1 .27.95l-.53 3.53a1 1 0 0 1-1.04.94H10a1 1 0 0 1-1-1v-3a1 1 0 0 0-.27-.95z" },
  mail = { "M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z", "m22 6-10 7L2 6" },
  key = { "M21 11a8 8 0 0 1-16 0 8 8 0 0 1 8-8h2", "M15.5 9a2.5 2.5 0 0 1 4 4v2h-4v-2a1 1 0 0 1 1-1z" },
  clock = { "M12 22a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", "M12 6v6l4 2" },
  calendar = { "M8 2v4", "M16 2v4", "M3 8h18", "M5 4H19a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z" },
  info = { "M12 22a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", "M12 8v4", "M12 16h.01" },
  ["alert-circle"] = { "M12 22a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", "M12 8v4", "M12 16h.01" },
  ["alert-triangle"] = { "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3z", "M12 9v4", "M12 17h.01" },
  ["external-link"] = { "M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6", "M15 3h6v6", "M10 14L21 3" },
  ["arrow-right"] = { "M5 12h14", "m12 5 5 5-5 5" },
  ["arrow-left"] = { "M19 12H5", "m7 5-5 5 5 5" },
  ["arrow-up"] = { "M12 19V5", "m5 7-5-5-5 5" },
  ["arrow-down"] = { "M12 5v14", "m7-5-5 5-5-5" },
  ["plus-circle"] = { "M12 22a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", "M12 8v8", "M8 12h8" },
  ["user-plus"] = { "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8z", "M19 8v6", "M16 11h6" },
  ["file-plus"] = { "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "M12 18v-6", "M9 15h6" },
  link = { "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71", "M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" },
  ["chevron-up"] = { "m18 15-6-6-6 6" },
  funnel = { "M22 3H2l8 9.46a1 1 0 0 1 .27.95L12 21l1.73-8a1 1 0 0 1 .27-.95z" },
  sliders = { "M4 21v-7", "M4 10V3", "M12 21v-9", "M12 8V3", "M20 21v-5", "M20 12V3", "M2 14h4", "M10 8h4", "M18 16h4" },
  ["more-horizontal"] = { "M12 12h.01", "M19 12h.01", "M5 12h.01" },
  inbox = { "M22 12h-6l-2 3h-9a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h7l2 2h8a2 2 0 0 1 2 2z" },
  sun = { "M12 2v2", "M12 20v2", "M4.93 4.93l1.41 1.41", "M17.66 17.66l1.41 1.41", "M2 12h2", "M20 12h2", "M6.34 17.66l-1.41 1.41", "M19.07 4.93l-1.41 1.41", "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z" },
  moon = { "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" },
  monitor = { "M8 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-6", "M12 18v4", "M8 22h8" },
  -- F26 nesne gezgini türleri
  sequence = { "M4 9h16", "M4 15h16", "m10 3-2 18", "m16 3-2 18" },
  type = { "M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5c0 1.1.9 2 2 2h1",
    "M16 21h1a2 2 0 0 0 2-2v-5c0-1.1.9-2 2-2a2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1" },
  extension = { "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0"
    .. "l7-4A2 2 0 0 0 21 16z", "m3.3 7 8.7 5 8.7-5", "M12 22V12" },
  operator = { "M12 3v14", "M5 10h14", "M5 21h14" },
  collation = { "M4 7V4h16v3", "M9 20h6", "M12 4v16" },
  fts = { "M21 6H3", "M10 12H3", "M10 18H3", "M18.5 15a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z", "m22 18-1.5-1.5" },
  -- F29 yardım (lucide circle-help)
  help = { "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z", "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3", "M12 17h.01" },
  lightbulb = { "M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5",
    "M9 18h6", "M10 22h4" },
  activity = { "M22 12h-2.48a2 2 0 0 0-1.93 1.45l-2.35 8.36a.25.25 0 0 1-.48 0L9 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.24 12H2" },
  cpu = { "M12 20v2", "M12 2v2", "M17 20v2", "M17 2v2", "M2 12h2", "M2 17h2", "M2 7h2", "M20 12h2", "M20 17h2", "M20 7h2",
    "M4 8a4 4 0 0 1 4-4h8a4 4 0 0 1 4 4v8a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z", "M9 9h6v6H9z" },
  ["hard-drive"] = { "M12 2v4", "M12 18v4", "M4 6v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2z",
    "M12 12a2 2 0 1 0 0 4 2 2 0 0 0 0-4z" },
  trending = { "M15 3h6v6", "M14 9l6-6", "M9 14l3 3 5-5" },
}

icons.names = P

-- class: Tailwind boyutu (varsayılan w-4 h-4). Bilinmeyen ad → nil (dom çocuk olarak atlar).
function icons.get(name, class)
  local paths = P[name]
  if not paths then return nil end
  local children = {}
  for i, d in ipairs(paths) do children[i] = dom.h("path", { d = d }) end
  return dom.h("svg", {
    viewBox = "0 0 24 24", fill = "none", stroke = "currentColor",
    ["stroke-width"] = "2", ["stroke-linecap"] = "round", ["stroke-linejoin"] = "round",
    ["aria-hidden"] = "true", focusable = "false", class = class or "w-4 h-4 shrink-0",
  }, children)
end

-- İkonlu buton: opts = { icon, label, variant = primary|danger|ai|secondary|ghost, title, icon_only, ... }
-- icon_only: metin görünmez, label aria-label olur.
function icons.button(opts)
  return dom.button({
    type = "button",
    class = "btn btn-" .. (opts.variant or "secondary") .. (opts.icon_only and " btn-icon" or "")
      .. (opts.class and (" " .. opts.class) or ""),
    title = opts.title or opts.label,
    ["aria-label"] = opts.icon_only and opts.label or opts["aria-label"],
    ["aria-haspopup"] = opts["aria-haspopup"],
    disabled = opts.disabled and "disabled" or nil,
    onclick = opts.onclick,
  }, icons.get(opts.icon), not opts.icon_only and dom.span({}, opts.label) or nil)
end

return icons
