# ═══ FAZ 22 — FRONTEND TEST & WASM OPTİMİZASYON ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltme #11.

## Amaç

Frontend kalitesini kilitlemek: birim testler (Lua 5.4), Playwright E2E, ve WASM/bundle optimizasyonları.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/spec/*.lua` | busted (lua5.4) birim testler (store, validation, fetch) |
| `web/e2e/*.spec.ts` | Playwright E2E |
| `web/build-wasm.sh` | (güncelle) hash, minify, preload, lazy admin bundle |
| `web/scripts/size-report.sh` | bundle boyut raporu |
| `Makefile` | `web.test`, `web.e2e`, `web.size` |

## Birim Testler (busted, lua5.4)

- `store_spec.lua`: reducer`lar saf, referans korunumu.
- `validation_spec.lua`: shared validation (frontend'de aynı).
- `fetch_spec.lua`: 401 refresh retry mock.
- `table_browser_spec.lua`: filter → sql builder.

Çalıştırma:

```
docker run --rm -v $(pwd):/w -w /w/web nickblah/lua:5.4-luarocks sh -c 'luarocks install busted && busted spec'
```

## E2E (Playwright)

`playwright.config.ts`:

```ts
export default {
  webServer: { command: "npm run dev", url: "http://localhost:28000", reuseExistingServer: true },
  use: { baseURL: "http://localhost:28000" },
  projects: [{ name:"chromium" }, { name:"firefox" }, { name:"webkit" }],
}
```

Spec'ler:

| spec | Senaryo |
|---|---|
| `auth.spec.ts` | login → connections, logout → login, wrong pass → error |
| `connections.spec.ts` | create → test → edit → delete |
| `query.spec.ts` | execute SELECT, error, history, export csv |
| `browse.spec.ts` | table rows pagination, filter, insert/duplicate/delete, structure tabs |
| `admin.spec.ts` | users CRUD, rbac toggle, audit export |
| `a11y.spec.ts` | axe-core, contrast, keyboard nav |

Helper `e2e/helpers.ts`: `login(page)`, `createConnection(page)`.

## WASM Optimizasyon (F22)

- **Bundle hash**: `bundle.<8hex>.json` → `index.html` preload `as="fetch"` + `Cache-Control: immutable` (prod nginx).
- **Admin lazy**: `admin` views (`users, rbac, audit`) ayrı `admin.bundle.json` → `js.loadBundle("admin")` ilk admin route'unda.
- **Minify**: Lua kaynakları `MODE=production` → yorum sil (`sed '/^--/d'`), `glue.js` esbuild `--minify`.
- **Gzip/brotli**: `public/*.js/*.json/*.wasm` → `.gz` + `.br` (nginx `gzip_static on`).
- **Preload**: `<link rel="preload" href="app.wasm" as="fetch" crossorigin>` + `bundle.json`.
- **CompileStreaming**: `WebAssembly.compileStreaming` (glue.js zaten).
- **CodeMirror lazy**: editör yalnızca `#/query` ve `#/browse` route'larında `import("@codemirror/lang-sql")` dinamik.

Boyut hedefleri:

| Dosya | Ham | Gzip |
|---|---|---|
| `app.wasm` | ~350 KB | ~120 KB |
| `bundle.json` | ~150 KB | ~35 KB |
| `glue.js` | ~80 KB | ~25 KB |
| `admin.bundle.json` | ~50 KB | ~12 KB |
| Toplam kritik | ~630 KB | ~192 KB |

`web.size`:

```
web/public/app.wasm                 350 KB  gzip 120 KB
web/public/bundle.abc123.json       150 KB  gzip 35 KB
```

## DoD

- [ ] `make web.test` busted 100% yeşil (lua5.4).
- [ ] `make web.e2e` Playwright 3 browser + mobile yeşil, flaky 0.
- [ ] `axe` a11y hatası 0.
- [ ] Prod `MODE=production ./build-wasm.sh` → minify + hash + gzip.
- [ ] Ağ sekmesinde `bundle.json` tek istek, `app.wasm` preload.
- [ ] Lighthouse performance ≥90 (bundle <200KB gzip).
