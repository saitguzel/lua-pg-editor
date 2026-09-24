-- F17: Button bileşeni — ikon destekli sarmalayıcı (icons.button ile uyumlu).
-- props = { variant, icon, label, title, disabled, onclick, class_extra, aria-label, icon_only }

local dom = require("dom")
local icons = require("icons")

local button = {}

local VARIANT_CLASS = {
  primary = "btn btn-primary",
  accent = "btn btn-accent",
  secondary = "btn btn-secondary",
  danger = "btn btn-danger",
  ai = "btn btn-ai",
  ghost = "btn btn-ghost",
}

function button.render(props, label)
  props = props or {}
  -- ikonlu kullanım: icons.button delegasyonu
  if props.icon then
    return icons.button({
      icon = props.icon,
      label = label or props.label or "Button",
      variant = props.variant,
      title = props.title,
      icon_only = props.icon_only,
      disabled = props.disabled,
      onclick = props.onclick,
      class = props.class_extra,
      ["aria-label"] = props["aria-label"],
    })
  end
  local variant = props.variant or "accent"
  local base = VARIANT_CLASS[variant] or VARIANT_CLASS.accent
  if props.class then base = props.class end
  return dom.button({
    type = props.type or "button",
    class = base .. (props.class_extra and (" " .. props.class_extra) or ""),
    disabled = props.disabled and "disabled" or nil,
    onclick = props.onclick,
    title = props.title,
    ["aria-label"] = props["aria-label"],
  }, icons.get(props.icon) , label or props.label or "Button")
end

return button
