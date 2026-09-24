-- F17: Button bileşeni — minimal sarmalayıcı.

local dom = require("dom")

local button = {}

function button.render(props, label)
  props = props or {}
  local cls = props.class or "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] hover:opacity-90 disabled:opacity-50"
  if props.variant == "secondary" then
    cls = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)] hover:bg-[var(--bg)]"
  elseif props.variant == "danger" then
    cls = "px-4 py-2 rounded-[var(--radius)] bg-[var(--danger)] text-white hover:opacity-90"
  end
  return dom.button({
    type = props.type or "button",
    class = cls .. (props.class_extra and (" " .. props.class_extra) or ""),
    disabled = props.disabled and "disabled" or nil,
    onclick = props.onclick,
    ["aria-label"] = props["aria-label"],
  }, label or props.label or "Button")
end

return button
