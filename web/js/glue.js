// Wasmoon yükleyici ve Lua ↔ JS köprüsü (F16/F17 - pg-editor).
// BUNDLE_PATH / ADMIN_BUNDLE_PATH / WASM_PATH esbuild --define ile build sırasında enjekte edilir.
import { LuaFactory } from "wasmoon";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
// history → cmHistory: global window.history (router replaceState) gölgelenmesin
import { history as cmHistory, defaultKeymap, historyKeymap } from "@codemirror/commands";
// SQL dili, autocomplete ve renklendirme lazy: yalnizca editor acilinca dinamik import (F22)
let _lang = null;
async function ensureCodeMirrorLang() {
  if (!_lang) {
    const [sqlMod, autoMod, langMod, hl] = await Promise.all([
      import("@codemirror/lang-sql"),
      import("@codemirror/autocomplete"),
      import("@codemirror/language"),
      import("@lezer/highlight"),
    ]);
    const t = hl.tags;
    // renkler tema değişkenlerinden: açık/koyu tema otomatik
    const style = langMod.HighlightStyle.define([
      { tag: t.keyword, color: "var(--syn-keyword)", fontWeight: "600" },
      { tag: [t.string, t.special(t.string)], color: "var(--syn-string)" },
      { tag: [t.number, t.bool, t.null], color: "var(--syn-number)" },
      { tag: [t.lineComment, t.blockComment], color: "var(--syn-comment)", fontStyle: "italic" },
      { tag: [t.typeName, t.standard(t.name)], color: "var(--syn-type)" },
      { tag: [t.operator, t.punctuation], color: "var(--syn-operator)" },
      { tag: [t.name, t.special(t.name)], color: "var(--syn-name)" },
    ]);
    _lang = { sqlMod, autoMod, highlight: langMod.syntaxHighlighting(style) };
  }
  return _lang;
}

// Backend kataloğu { schemas: [{ name, tables: [{ name, columns: [{ name }] }] }] } → lang-sql namespace
function sqlNamespace(catalog) {
  const ns = {};
  for (const s of catalog?.schemas || []) {
    const tables = (ns[s.name] = {});
    for (const tb of s.tables || []) tables[tb.name] = (tb.columns || []).map((c) => c?.name ?? String(c));
  }
  return ns;
}

// Editör dil+autocomplete+renk eklentileri (lang yüklüyse); katalog değişince yeniden kurulur
function languageExtensions(catalog) {
  const { sqlMod, autoMod, highlight } = _lang;
  return [
    sqlMod.sql({ dialect: sqlMod.PostgreSQL, schema: sqlNamespace(catalog), defaultSchema: "public", upperCaseKeywords: true }),
    autoMod.autocompletion({ activateOnTyping: true, maxRenderedOptions: 200 }),
    highlight,
  ];
}

const editorTheme = EditorView.theme({
  "&": { backgroundColor: "var(--bg)", color: "var(--fg)", fontSize: "13px", minHeight: "180px" },
  ".cm-content": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", caretColor: "var(--fg)" },
  ".cm-gutters": { backgroundColor: "var(--bg-elev)", color: "var(--fg-muted)", borderRight: "1px solid var(--border)" },
  ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: "color-mix(in srgb, var(--primary) 8%, transparent)" },
  "&.cm-focused": { outline: "2px solid var(--focus)" },
  ".cm-tooltip": { backgroundColor: "var(--bg-elev)", color: "var(--fg)", border: "1px solid var(--border)" },
  ".cm-tooltip-autocomplete ul li[aria-selected]": { backgroundColor: "var(--primary)", color: "var(--primary-fg)" },
});

const WASM_URL = new URL(WASM_PATH, import.meta.url).href;
const BUNDLE_URL = new URL(BUNDLE_PATH, import.meta.url).href;
const ADMIN_BUNDLE_URL = new URL(ADMIN_BUNDLE_PATH, import.meta.url).href;

// Lua'ya verilen DOM nesneleri ID ile tutulur; ham DOM referansı Lua'ya taşınmaz.
const nodes = new Map(); // id -> Node | EditorView
let nextId = 1;
const handle = (node) => { const id = nextId++; nodes.set(id, node); return id; };
const get = (h) => nodes.get(h);

// Editor'e özel map ve callback deposu
const editors = new Map(); // id -> EditorView
const editorCallbacks = new Map(); // id -> { onChange, onRun }

// Skip-link: #main hash'i SPA router'ını bozmasın; odağı programatik taşı (a11y)
document.addEventListener("click", (e) => {
  const a = e.target.closest?.("a.skip-link");
  if (!a) return;
  e.preventDefault();
  const main = document.getElementById("main");
  if (main) { main.focus(); main.scrollIntoView(); }
});

// Lua'ya yalnızca ihtiyaç duyulan event alanları düz nesne olarak geçer
function eventToLua(e) {
  return {
    type: e.type,
    key: e.key,
    ctrlKey: e.ctrlKey,
    metaKey: e.metaKey,
    shiftKey: e.shiftKey,
    altKey: e.altKey,
    button: e.button,
    // bağlam menüsü konumu: fare yoksa (klavye ile tıklama) hedefin sol-alt köşesi
    x: e.clientX || e.target?.getBoundingClientRect?.().left || 0,
    y: e.clientY || e.target?.getBoundingClientRect?.().bottom || 0,
    value: e.target?.value,
    checked: e.target?.checked,
    targetId: e.target?.dataset?.id,
    action: e.target?.closest?.("[data-action]")?.dataset.action,
    // grid olay delegasyonu: tıklanan hücrenin "satır:kolon" konumu (hücre başına dinleyici yok)
    cell: e.target?.closest?.("[data-cell]")?.dataset.cell,
  };
}

// Kaldırılan alt ağaçta açık dialog varsa odağı tetikleyen öğeye geri ver (F16)
function returnFocusOf(n) {
  if (!(n instanceof Element)) return null;
  const ds = n.tagName === "DIALOG" ? [n] : [...n.querySelectorAll("dialog")];
  return ds.find((d) => d._returnFocus)?._returnFocus ?? null;
}

let factory = null;
const loadedBundles = new Map(); // url -> Promise
function mountBundle(url) {
  if (!loadedBundles.has(url)) {
    loadedBundles.set(url, fetch(url)
      .then((r) => { if (!r.ok) throw new Error(`bundle ${r.status}`); return r.json(); })
      .then((bundle) => Promise.all(Object.entries(bundle)
        .map(([mod, src]) => factory.mountFile(`/lua/${mod.replaceAll(".", "/")}.lua`, src))))
      .catch((e) => { loadedBundles.delete(url); throw e; }));
  }
  return loadedBundles.get(url);
}

const bridge = {
  dom: {
    create: (tag) => handle(document.createElement(tag)),
    text: (s) => handle(document.createTextNode(s)),
    byId: (id) => { const n = document.getElementById(id); return n ? handle(n) : null; },
    setAttr: (h, k, v) => get(h)?.setAttribute(k, v),
    removeAttr: (h, k) => get(h)?.removeAttribute(k),
    // value/checked/disabled gibi property'ler attr değil prop ile set edilir
    setProp: (h, k, v) => { const n = get(h); if (n) n[k] = v; },
    getProp: (h, k) => { const n = get(h); return n ? n[k] : null; },
    setText: (h, s) => { const n = get(h); if (n) n.textContent = s; },
    append: (p, c) => get(p)?.appendChild(get(c)),
    // keyed diff: düğüm zaten doğru konumdaysa DOM'a dokunulmaz (odak korunur)
    insertAt: (p, c, i) => {
      const pn = get(p), cn = get(c);
      if (!pn || !cn) return;
      const ref = pn.childNodes[i] ?? null;
      if (ref !== cn) pn.insertBefore(cn, ref);
    },
    replaceWith: (o, n) => {
      const on = get(o), nn = get(n);
      if (!on || !nn) return;
      const rf = returnFocusOf(on);
      on.replaceWith(nn);
      rf?.focus?.();
    },
    replaceChildren: (p, ...cs) => get(p)?.replaceChildren(...cs.map(get).filter(Boolean)),
    remove: (h) => {
      const n = get(h);
      if (n) { const rf = returnFocusOf(n); n.remove(); rf?.focus?.(); }
      nodes.delete(h);
    },
    release: (h) => nodes.delete(h), // Lua tarafı ağacı atınca handle'ı serbest bırakır
    focus: (h) => get(h)?.focus?.(),
    on: (h, ev, fn) => {
      const f = (e) => {
        // SPA: form hiçbir zaman native submit edilmez (CSP form-action 'none')
        if (e.type === "submit") e.preventDefault();
        // native dialog Esc → cancel: kapanışı Lua state'i yönetir
        if (e.type === "cancel") e.preventDefault();
        // sağ tık: tarayıcı menüsü yerine uygulamanın bağlam menüsü
        if (e.type === "contextmenu") e.preventDefault();
        try { fn(eventToLua(e)); } catch (err) { console.error("[lua]", err); }
      };
      get(h)?.addEventListener(ev, f);
      return () => get(h)?.removeEventListener(ev, f);
    },
    setClass: (h, cls, on) => get(h)?.classList.toggle(cls, on),
    setRootAttr: (k, v) => document.documentElement.setAttribute(k, v),
    title: (s) => { document.title = s; },
    activeElement: () => (document.activeElement ? handle(document.activeElement) : null),
    // Seçili satır: odaktaki öğenin en yakın [data-id] atası (F16 e/d kısayolları)
    activeDataId: () => document.activeElement?.closest?.("[data-id]")?.dataset.id ?? null,
    // Render sonrası açılmamış modal dialog'ları showModal ile aç (focus trap + inert arka plan)
    openModals: () => {
      document.querySelectorAll("dialog[data-modal]:not([open])").forEach((d) => {
        d._returnFocus = document.activeElement;
        d.showModal();
      });
    },
    modalOpen: () => !!document.querySelector("dialog[open]"),
    viewport: () => [window.innerWidth, window.innerHeight],
    // sel ile eşleşen öğeler arasında odağı delta kadar (döngüsel) taşır — menü ok tuşları
    focusMove: (sel, delta) => {
      const els = [...document.querySelectorAll(sel)];
      if (!els.length) return;
      const i = els.indexOf(document.activeElement);
      els[(i + delta + els.length) % els.length].focus();
    },
    focusFirst: (sel) => {
      // skip-link odaklıyken render tetiklenirse odağı çalma (a11y: Tab → skip-link → Enter akışı);
      // body odaklıyken (sayfa ilk yüklemesi) de otomatik odak atlanır
      const ae = document.activeElement;
      if (ae && (ae.classList?.contains("skip-link") || ae === document.body)) return;
      document.querySelector(sel)?.focus?.();
    },
    _size: () => nodes.size,
  },
  http: {
    // Callback tabanlı: Lua coroutine'i yield eder, callback resume eder (F13 fetch.lua)
    request: (method, url, headersJson, body, cb) => {
      const ctrl = new AbortController();
      // zaman aşımı → NETWORK_ERROR; backend sorgu zaman aşımından (30 sn) uzun olmalı ki sorgu hatası görünsün
      const to = setTimeout(() => ctrl.abort(), window.__PG_CONFIG__?.request_timeout_ms || 35000);
      fetch(url, {
        method,
        headers: JSON.parse(headersJson || "{}"),
        body: body ?? undefined,
        credentials: "omit",
        signal: ctrl.signal,
      })
        .then(async (r) => {
          clearTimeout(to);
          cb(undefined, r.status, await r.text(), r.headers.get("content-type") || "",
            r.headers.get("retry-after") || "");
        })
        .catch((e) => { clearTimeout(to); cb(String(e?.message || e), 0, "", "", ""); });
    },
    // CSV export: Authorization header gerektiğinden <a href> yerine blob indirilir (F15)
    // body (JSON metni) verilirse POST; hata yanıtının JSON gövdesi cb'ye ikinci argüman olarak döner
    download: (url, token, filename, cb, body) => {
      const headers = token ? { Authorization: `Bearer ${token}` } : {};
      if (body != null) headers["Content-Type"] = "application/json";
      fetch(url, { method: body != null ? "POST" : "GET", headers, body: body ?? undefined, credentials: "omit" })
        .then(async (r) => {
          if (!r.ok) { const e = new Error(`download ${r.status}`); e.body = await r.text(); throw e; }
          return r.blob();
        })
        .then((blob) => {
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = filename || "export.csv";
          document.body.appendChild(a);
          a.click();
          a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 5000);
          cb?.(undefined);
        })
        .catch((e) => { console.error("[lua] download hatası:", e); cb?.(String(e?.message || e), e?.body || ""); });
    },
  },
  storage: {
    get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
    set: (k, v) => { try { localStorage.setItem(k, v); return true; } catch { return false; } },
    remove: (k) => { try { localStorage.removeItem(k); } catch { /* engelli */ } },
  },
  timer: {
    after: (ms, fn) => setTimeout(() => { try { fn(); } catch (e) { console.error("[lua]", e); } }, ms),
    cancel: (id) => clearTimeout(id),
    raf: (fn) => requestAnimationFrame(() => { try { fn(); } catch (e) { console.error("[lua]", e); } }),
    now: () => Date.now(),
  },
  location: {
    hash: () => location.hash,
    setHash: (h) => { location.hash = h; },
    replace: (h) => history.replaceState(null, "", h), // reset token'ı URL'den silmek (F14)
    onHashChange: (fn) => window.addEventListener("hashchange", () => { try { fn(location.hash); } catch (e) { console.error("[lua]", e); } }),
  },
  keyboard: {
    onKey: (fn) => document.addEventListener("keydown", (e) => {
      if (e.defaultPrevented) return; // CodeMirror keymap'i işlediyse (Ctrl+Enter) ikinci kez çalışmasın
      const t = e.target;
      const typing = t?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t?.tagName);
      try {
        if (fn(e.key, !!typing, e.ctrlKey || e.metaKey, e.altKey, t?.tagName || "") === true) e.preventDefault();
      } catch (err) { console.error("[lua]", err); }
    }),
  },
  media: {
    prefersDark: () => matchMedia("(prefers-color-scheme: dark)").matches,
    reducedMotion: () => matchMedia("(prefers-reduced-motion: reduce)").matches,
    matches: (q) => matchMedia(q).matches,
    onChange: (q, fn) => matchMedia(q).addEventListener("change", (e) => { try { fn(e.matches); } catch (err) { console.error("[lua]", err); } }), // tema "system" (F16)
  },
  editor: {
    create: (containerHandle, optsJson) => {
      const container = get(containerHandle);
      if (!container) return null;
      let opts = {};
      try { opts = JSON.parse(optsJson || "{}"); } catch {}
      const langCompartment = new Compartment();
      const cb = (name, ...args) => {
        const cbs = editorCallbacks.get(view._handleId);
        if (cbs && cbs[name]) { try { cbs[name](...args); } catch (err) { console.error("[editor]", err); } }
      };
      const view = new EditorView({
        state: EditorState.create({
          doc: opts.value || "",
          extensions: [
            lineNumbers(), highlightActiveLineGutter(), highlightActiveLine(), drawSelection(), cmHistory(),
            EditorState.tabSize.of(4),
            langCompartment.of(_lang ? languageExtensions(opts.schema) : []),
            EditorView.lineWrapping,
            editorTheme,
            // erişilebilirlik: CodeMirror content textbox'ına erişilebilir ad (aria-input-field-name)
            EditorView.contentAttributes.of({ "aria-label": opts.ariaLabel || "SQL sorgusu" }),
            keymap.of([
              { key: "Mod-Enter", run: () => { cb("onRun", view.state.doc.toString()); return true; } },
              // codd: Tab 4 boşluk ekler (Esc ardından Tab odağı editörden çıkarır — CodeMirror tab focus mode)
              { key: "Tab", run: (v) => { v.dispatch(v.state.replaceSelection("    ")); return true; } },
              ...historyKeymap, ...defaultKeymap,
            ]),
            EditorView.updateListener.of((u) => {
              if (u.docChanged) cb("onChange", u.state.doc.toString());
              if (u.selectionSet) cb("onSelection", !u.state.selection.main.empty);
            }),
          ],
        }),
        parent: container,
      });
      const h = handle(view);
      view._handleId = h;
      view._langCompartment = langCompartment;
      view._catalog = opts.schema || null;
      editors.set(h, view);
      editorCallbacks.set(h, {});
      if (!_lang) {
        ensureCodeMirrorLang().then(() => {
          if (!view.dom.isConnected && !editors.has(h)) return;
          view.dispatch({ effects: langCompartment.reconfigure(languageExtensions(view._catalog)) });
        }).catch((e) => console.error("[editor] lazy lang:", e));
      }
      return h;
    },
    setValue: (h, v) => {
      const view = editors.get(h) || get(h);
      if (!view || !view.dispatch) return;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: v ?? "" } });
    },
    getValue: (h) => {
      const view = editors.get(h) || get(h);
      return view?.state?.doc?.toString() ?? "";
    },
    onChange: (h, fn) => {
      const cbs = editorCallbacks.get(h);
      if (cbs) cbs.onChange = fn;
      else editorCallbacks.set(h, { onChange: fn });
    },
    onRun: (h, fn) => {
      const cbs = editorCallbacks.get(h);
      if (cbs) cbs.onRun = fn;
      else editorCallbacks.set(h, { onRun: fn });
    },
    setCompletions: (h, catalogJson) => {
      const view = editors.get(h);
      if (!view) return;
      try { view._catalog = JSON.parse(catalogJson || "{}"); } catch { return; }
      if (_lang) view.dispatch({ effects: view._langCompartment.reconfigure(languageExtensions(view._catalog)) });
    },
    // seçili metin (ana seçim); seçim yoksa ""
    getSelection: (h) => {
      const view = editors.get(h);
      if (!view) return "";
      const { from, to } = view.state.selection.main;
      return view.state.sliceDoc(from, to);
    },
    onSelection: (h, fn) => {
      const cbs = editorCallbacks.get(h);
      if (cbs) cbs.onSelection = fn;
    },
    // editör DOM'da mı? (view yeniden çizilip kap değiştiyse Lua yeni editör açar)
    // containerId verilirse editör o kabın içinde olmalı (diff kabı başka sekmeye yeniden kullanmış olabilir)
    attached: (h, containerId) => {
      const v = editors.get(h);
      return !!v?.dom?.isConnected && (!containerId || v.dom.parentElement?.id === containerId);
    },
    focus: (h) => {
      const view = editors.get(h) || get(h);
      view?.focus?.();
    },
    destroy: (h) => {
      const view = editors.get(h) || get(h);
      if (view && view.destroy) { try { view.destroy(); } catch {} }
      editors.delete(h);
      editorCallbacks.delete(h);
      nodes.delete(h);
    },
  },
  // Admin view'ları ayrı bundle'da (F17 #7); ilk admin route'unda yüklenir
  loadBundle: (name, cb) => {
    const url = name === "admin" ? ADMIN_BUNDLE_URL : null;
    if (!url) { cb(`bilinmeyen bundle: ${name}`); return; }
    mountBundle(url).then(() => cb(undefined)).catch((e) => cb(String(e?.message || e)));
  },
  // API UTC ISO döner, UI yerel saat gösterir (F14 profil, F15 audit tablosu)
  format_date: (iso, style) => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return String(iso);
    return new Intl.DateTimeFormat("tr-TR",
      style === "date" ? { dateStyle: "medium" } : { dateStyle: "medium", timeStyle: "short" }).format(d);
  },
  // datetime-local girdisini yerel saat → UTC ISO'ya çevirir (tarih formu)
  to_iso_utc: (localValue) => {
    if (!localValue) return null;
    const d = new Date(localValue);
    return Number.isNaN(d.getTime()) ? null : d.toISOString().replace(/\.\d{3}Z$/, "Z");
  },
  // UTC ISO → datetime-local input değeri ("YYYY-MM-DDTHH:MM", yerel saat)
  to_local_input: (iso) => {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "";
    d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
    return d.toISOString().slice(0, 16);
  },
  // Admin "parola oluştur" (F15): kriptografik rastgele, karışık karakter sınıfları
  random_password: (len) => {
    const cs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%*-_";
    const a = crypto.getRandomValues(new Uint32Array(len || 16));
    // şema gereği her sınıftan en az bir karakter garanti edilir
    return "Aa1!" + Array.from(a.slice(4), (x) => cs[x % cs.length]).join("");
  },
  clipboard: (text) => { navigator.clipboard?.writeText(text).catch(() => { /* sessiz */ }); },
  confetti: (opts) => {
    // canvas-confetti dinamik import: ilk kullanıma kadar yüklenmez (F17)
    import("canvas-confetti").then(({ default: confetti }) => {
      const base = { disableForReducedMotion: true, ...(opts ? JSON.parse(opts) : {}) };
      if (!bridge.media.reducedMotion()) confetti(base);
    }).catch((e) => console.error("[lua] confetti:", e));
  },
  // Lua 5.4'te cjson yok; JSON JS tarafında çözülür (F13 json.lua sarmalayıcısı).
  // Nesne alanındaki null atılır (Lua'da nil); dizi içindeki null (ör. sonuç hücresi) işaretle korunur,
  // json.lua onu json.null'a çevirir — yoksa Lua dizisinde delik açılır ve ipairs ilk NULL'da durur.
  json: {
    encode: (v) => JSON.stringify(v),
    // hücre görüntüleyici: girintili JSON (geçersizse metin aynen döner)
    pretty: (s) => { try { return JSON.stringify(JSON.parse(s), null, 2); } catch { return s; } },
    // işaret NUL içermez: Wasmoon stringleri C-string olarak aktarır, \0'da keser (ponytail: hücre tam bu metni içerirse NULL görünür)
    decode: (s) => JSON.parse(s, function (_k, v) { return v === null ? (Array.isArray(this) ? "\u0001pg:null\u0001" : undefined) : v; }),
  },
  log: (level, msg) => console[level]?.(`[lua] ${msg}`),
  config: () => JSON.stringify(window.__PG_CONFIG__ || {}),
};

// Wasmoon JS null'ı Lua'ya aktaramaz (injectObjects kapalı) ve dönen nesneleri derin kopyalar →
// köprüden dönen null ve DOM nesneleri (appendChild'ın döndürdüğü Node gibi) undefined (= nil) olur
const nn = (v) => (v === null || v instanceof Node || v instanceof Event ? undefined : v);
(function wrapNulls(obj) {
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "function") obj[k] = (...a) => nn(v(...a));
    else if (v && typeof v === "object") wrapNulls(v);
  }
})(bridge);

async function boot() {
  const t0 = performance.now();
  // Wasmoon glue.wasm'ı Emscripten üzerinden WebAssembly.instantiateStreaming ile yükler
  // (application/wasm MIME ile servis edildiğinde indirme ve derleme paralel — F17 #6).
  factory = new LuaFactory(WASM_URL);
  const [lua] = await Promise.all([
    // injectObjects: false → JS null Lua'ya nil olarak gelir (true iken js_null userdata olur ve "x or y" kalıpları bozulur)
    factory.createEngine({ openStandardLibs: true, injectObjects: false, enableProxy: false }),
    mountBundle(BUNDLE_URL), // paralel mount (F17 optimizasyonu)
  ]);
  lua.global.set("js", bridge);
  await lua.doString(`package.path = "/lua/?.lua;/lua/?/init.lua"`);
  await lua.doString(`require("main")`);
  document.getElementById("boot")?.remove();
  window.__pg = {
    lua,
    bootMs: Math.round(performance.now() - t0),
    memory: () => factory.getLuaModule().then((m) => m.module.HEAPU8.length),
    nodesSize: () => nodes.size,
  };
  // E2E bekleme yardımcısı: keyfi sleep yerine data-ready (F17)
  document.documentElement.dataset.ready = "1";
  performance.mark("lua-ready");
  console.info(`[pg] lua-ready ${window.__pg.bootMs} ms`);
}

boot().catch((err) => {
  console.error(err);
  const el = document.getElementById("boot");
  if (el) { el.textContent = "Uygulama yüklenemedi. Sayfayı yenileyin."; el.setAttribute("role", "alert"); }
});
