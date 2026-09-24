-- F17: Select bileşeni — minimal sarmalayıcı.

local dom = require("dom")

local select = {}

function select.render(props, options)
  props = props or {}
  options = options or {}
  local children = {}
  for _, opt in ipairs(options) do
    children[#children + 1] = dom.option({
      value = opt.value,
      selected = (tostring(opt.value) == tostring(props.value)) and "selected" or nil,
    }, opt.label or tostring(opt.value))
  end
  return dom.select({
    id = props.id,
    name = props.name,
    class = props.class or "w-full px-3 py-2 rounded-[var(--radius)] border border-[var(--border)] bg-[var(--bg-elev)]",
    disabled = props.disabled and "disabled" or nil,
    onchange = props.onchange,
  }, children)
end

return select
