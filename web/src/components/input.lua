-- F17: Input bileşeni — minimal sarmalayıcı.

local dom = require("dom")

local input = {}

function input.render(props)
  props = props or {}
  return dom.input({
    id = props.id,
    name = props.name,
    type = props.type or "text",
    value = props.value,
    placeholder = props.placeholder,
    class = props.class or "w-full px-3 py-2 rounded-[var(--radius)] border border-[var(--border)] bg-[var(--bg-elev)]",
    disabled = props.disabled and "disabled" or nil,
    ["aria-invalid"] = props.error and "true" or nil,
    ["aria-describedby"] = props.describedby,
    oninput = props.oninput,
    onchange = props.onchange,
  })
end

function input.field(label, props, error)
  return dom.div({ class = "space-y-1" },
    label and dom.label({ ["for"] = props.id, class = "text-sm font-medium" }, label),
    input.render(props),
    error and dom.p({ class = "field-error", id = props.id and (props.id .. "-error") }, error))
end

return input
