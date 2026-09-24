# ═══ FAZ 16 — FRONTEND İSKELET ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltme #1, #11, #12.

## Amaç

`pg-web` iskeleti: Wasmoon yükleyici (`glue.js`), Lua bundle (`build-wasm.sh`), `index.html`+`boot.js`, `styles.css`, `main.lua` stub. Tarayıcıda Wasmoon yüklenir, `main.lua` çalışır, `shared` modülleri require edilebilir.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/package.json` | wasmoon, codemirror, canvas-confetti, esbuild, serve |
| `web/build-wasm.sh` | glue.wasm kopya + Lua bundle.json + esbuild |
| `web/js/glue.js` | Wasmoon mount + JS köprüleri (DOM, fetch, storage, editor) |
| `web/public/index.html` | kabuk HTML, CSP, preload, #app |
| `web/public/boot.js` | tema FOUC önleme + config |
| `web/public/styles.css` | CSS değişkenleri, skeleton, badge |
| `web/src/main.lua` | giriş, hata yakalama, app.start |
| `.gitignore` | + `web/public/app.wasm`, `bundle.json`, `glue.js` |

## package.json

```json
{
  "name": "pg-web",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "./build-wasm.sh",
    "build:prod": "MODE=production ./build-wasm.sh",
    "dev": "./build-wasm.sh && serve public -l 28000 --single"
  },
  "dependencies": {
    "wasmoon": "^1.16.0",
    "canvas-confetti": "^1.9.3",
    "@codemirror/lang-sql": "^6.7.0",
    "@codemirror/view": "^6.26.0",
    "@codemirror/state": "^6.4.0",
    "@codemirror/autocomplete": "^6.8.0"
  },
  "devDependencies": { "esbuild": "^0.24.0", "serve": "^14.2.0" }
}
```

## build-wasm.sh (öz)

```
1. set -euo pipefail; [ -d node_modules ] || npm ci
2. cp node_modules/wasmoon/dist/glue.wasm public/app.wasm
3. Lua paketleme: src/**/*.lua → "views.*" ; ../shared/src/*.lua → "pg_shared.*"
   - luac5.4 -p sözdizimi check
   - jq -Rs add → public/bundle.json (+ hash)
4. MODE=production → minify (yorum sil)
5. esbuild js/glue.js --bundle --format=esm --target=es2020 --outfile=public/glue.js
6. __BUNDLE_HASH__ replace
```

## glue.js (köprü)

`js` global Lua'ya verilir:

- `dom.*`: create, text, byId, setAttr/removeAttr, setProp/getProp, setText, append, insertAt, replaceWith, replaceChildren, remove, release, focus, on(event), setClass, setRootAttr, title, activeElement, activeDataId, openModals, focusFirst, _size
- `http.*`: request (callback), download (blob)
- `storage`: get/set/remove (localStorage)
- `timer`: after/cancel, raf, now
- `location`: hash/setHash/replace/onHashChange
- `keyboard`: onKey
- `media`: prefersDark/reducedMotion/matches/onChange
- `editor`: create(containerId, opts) → handle, setValue/getValue, onChange, setCompletions(catalogJson), focus, destroy
- `json`: encode/decode (null→nil)
- `log`, `config` (window.__PG_CONFIG__)
- `loadBundle(name, cb)` — admin bundle lazy

CodeMirror entegrasyonu (`editor`):

```js
import { EditorView, keymap } from "@codemirror/view";
import { EditorState } from "@codemirror/state";
import { sql } from "@codemirror/lang-sql";
import { autocompletion } from "@codemirror/autocomplete";

const editors = new Map(); // id -> EditorView
bridge.editor = {
  create: (containerHandle, optsJson) => {
    const container = get(containerHandle);
    const opts = JSON.parse(optsJson || "{}");
    const view = new EditorView({
      state: EditorState.create({
        doc: opts.value || "",
        extensions: [
          sql({ schema: opts.schema || {} }), // opts.schema = { public: { customers: ["id","email"] } }
          autocompletion({ activateOnTyping: true }),
          EditorView.lineWrapping,
          keymap.of([{ key:"Ctrl-Enter", run: () => { opts.onRun?.(); return true; }}]),
          EditorView.updateListener.of(u => { if(u.docChanged) opts.onChange?.(u.state.doc.toString()); }),
        ],
      }),
      parent: container,
    });
    return handle(view);
  },
  setValue: (h, v) => get(h)?.dispatch({ changes:{ from:0, to:get(h).state.doc.length, insert:v } }),
  getValue: (h) => get(h)?.state.doc.toString() ?? "",
  onChange: (h, fn) => get(h)?.dispatch, // updateListener zaten
}
```

Lua tarafı `editor.lua` bu handle'ı saklar; `completion` katalogu geldikçe `bridge.editor.setCompletions` ile schema güncellenir.

## index.html / boot.js

```html
<!doctype html><html lang="tr" data-theme="light"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>pgLua — PostgreSQL Web Editor</title>
<meta name="lua-bundle" content="./bundle.__HASH__.json">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'">
<link rel="preload" href="./app.wasm" as="fetch" type="application/wasm" crossorigin>
<link rel="stylesheet" href="./styles.css">
<script src="./boot.js"></script>
<script type="module" src="./glue.js"></script>
</head><body class="min-h-screen bg-[var(--bg)] text-[var(--fg)]">
<div id="toast-root" aria-live="polite"></div><div id="modal-root"></div><div id="app"><div id="boot" aria-busy="true">Yükleniyor…</div></div>
<noscript>JavaScript ve WebAssembly gereklidir.</noscript>
</body></html>
```

`boot.js`:

```js
try{ const t=localStorage.getItem("pg.theme")|| (matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light"); document.documentElement.dataset.theme=t; }catch{}
window.__PG_CONFIG__={ apiBase: `${location.origin}/api/v1` };
```

## styles.css

CSS değişkenleri light/dark (özgün palet), `.skeleton` shimmer, `.badge-*`, `.codemirror-wrapper`, focus halkası, skip-link.

## main.lua stub

```lua
assert(_VERSION=="Lua 5.4")
local ok, err = xpcall(function()
  local types = require("pg_shared.types")
  local app = require("app") -- F17'de gerçek
  app.start({ config=js.json.decode(js.config()) })
end, debug.traceback)
if not ok then js.log("error", tostring(err)); local root=js.dom.byId("app"); if root then js.dom.setText(root,"Beklenmeyen hata.") end end
```

Stub `app.lua`:

```lua
local _M={}
function _M.start(opts)
  local root=js.dom.byId("app")
  local el=js.dom.create("div"); js.dom.setText(el,"pg-web hazır — PAGES="..#require("pg_shared.types").PAGES)
  js.dom.append(root, el)
end
return _M
```

## DoD

- [ ] `cd web && ./build-wasm.sh` → `public/app.wasm`, `bundle.<hash>.json`, `glue.js`.
- [ ] Sözdizimi hatalı lua → build fail.
- [ ] `npm run dev` → `http://localhost:28000` "pg-web hazır — PAGES=16".
- [ ] `window.__pg` (burada `__pg`) bootMs <1000ms, memory sayı.
- [ ] CSP ihlali yok, `'unsafe-eval'` yok.
- [ ] CodeMirror container'da editör açılır, `Ctrl-Enter` Lua'ya gider.
- [ ] `luacheck web/src` temiz.
