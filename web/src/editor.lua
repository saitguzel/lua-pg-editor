-- F16/F17: CodeMirror sarmalayıcısı (completion + Ctrl-Enter).

local json = require("json")

local editor = {}

function editor.create(containerHandle, opts)
  opts = opts or {}
  local payload = json.encode({ value = opts.value or "", schema = opts.schema or {}, ariaLabel = opts.ariaLabel,
    snippets = opts.snippets or {} })
  local h = js.editor.create(containerHandle, payload)
  if h and opts.onChange then
    js.editor.onChange(h, opts.onChange)
  end
  if h and opts.onRun then
    js.editor.onRun(h, opts.onRun)
  end
  if h and opts.onSelection then
    js.editor.onSelection(h, opts.onSelection)
  end
  if h and opts.onAi then
    js.editor.onAi(h, opts.onAi)
  end
  return h
end

function editor.set_value(handle, value)
  if handle then js.editor.setValue(handle, value or "") end
end

function editor.get_value(handle)
  if not handle then return "" end
  return js.editor.getValue(handle) or ""
end

function editor.on_change(handle, fn)
  if handle and fn then js.editor.onChange(handle, fn) end
end

function editor.on_run(handle, fn)
  if handle and fn then js.editor.onRun(handle, fn) end
end

-- catalog: GET /connections/:id/completion yanıtı ({ schemas = { {name, tables = {{name, columns}}} } });
-- lang-sql namespace'ine glue.js çevirir
function editor.set_completions(handle, catalog)
  if not handle or not catalog then return end
  js.editor.setCompletions(handle, json.encode(catalog))
end

-- taslaklar: { { name, prefix, body } } — önekli olanlar tamamlamada önerilir
function editor.set_snippets(handle, list)
  if handle and list then js.editor.setSnippets(handle, json.encode(list)) end
end

-- düz metni seçimin yerine (seçim yoksa whole → tüm belge, aksi halde imlece) koyar; Ctrl+Z geri alır
function editor.replace_text(handle, text, whole)
  if handle and text then js.editor.replaceText(handle, text, whole == true) end
end

-- ${ad} yer tutuculu taslağı imlece ekler
function editor.insert_snippet(handle, body)
  if handle and body then js.editor.insertSnippet(handle, body) end
end

function editor.get_selection(handle)
  if not handle then return "" end
  return js.editor.getSelection(handle) or ""
end

-- fn(has_selection: bool) seçim değişince
function editor.on_selection(handle, fn)
  if handle and fn then js.editor.onSelection(handle, fn) end
end

-- editör DOM'da ve (verildiyse) container_id'li kabın içinde mi
function editor.attached(handle, container_id)
  return handle ~= nil and js.editor.attached(handle, container_id) == true
end

function editor.focus(handle)
  if handle then js.editor.focus(handle) end
end

function editor.destroy(handle)
  if handle then js.editor.destroy(handle) end
end

return editor
