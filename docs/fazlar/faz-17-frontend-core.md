# ═══ FAZ 17 — FRONTEND CORE ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — teknik düzeltmeler.

## Amaç

SPA çekirdeği: tek store + dilim reducer'lar, rAF birleştirilmiş render, dom + fetch + storage + router + editor bridge.

## Çıktılar

| Yol | Sorumluluk |
|---|---|
| `web/src/app.lua` | store, dispatch, subscribe, start |
| `web/src/store.lua` | (app.lua içinde) reducer, initial_state |
| `web/src/dom.lua` | vdom helper (h, render, keyed diff), bridge sarmalayıcı |
| `web/src/fetch.lua` | http request → coroutine, token, refresh, retry |
| `web/src/storage.lua` | localStorage sarmalayıcı |
| `web/src/router.lua` | hash router, route table, guards |
| `web/src/editor.lua` | CodeMirror sarmalayıcı (completion) |
| `web/src/json.lua` | `js.json.encode/decode` sarmalayıcı |
| `web/src/components/*.lua` | button, input, select, modal, toast |

## Store (app.lua)

Initial state:

```lua
initial_state = {
  route={ name=nil, params={}, query={}, forbidden=false },
  auth={ status="unknown", user=nil, permissions={} },
  connections={ items={}, by_id={}, meta={}, status="idle", error=nil, editing=nil, testing=nil, filters={} },
  databases={ list={}, status="idle" },
  schemas={ list={}, status="idle" },
  objects={ items={}, status="idle", filter="" },
  structure={ data=nil, status="idle", selected={schema,name} },
  query={ tabs={}, active_tab=1, next_id=1, history={ items={}, status="idle" }, completion=nil },
  table_browser={ object=nil, columns={}, rows={}, meta={page=1,per_page=100,total=0,has_next=false}, status="idle", filters={}, sort=nil, editing=nil, pending={} },
  users={ items={}, by_id={}, meta=nil, status="idle" },
  rbac={ pages={}, matrix=nil, status="idle", pending={} },
  audit={ items={}, meta=nil, filters={}, status="idle" },
  ui={ theme="light", toasts={}, modal=nil, sidebar_open=true, busy={}, loaded_at=nil },
}
```

Reducer'lar: `reduce_route`, `reduce_auth`, `reduce_connections`, `reduce_query` (tabs: CREATE_TAB, CLOSE_TAB, RUN_REQUESTED, RUN_SUCCEEDED, HISTORY_LOADED), `reduce_table_browser` (ROWS_REQUESTED/LOADED, ROW_UPDATE_OPTIMISTIC), `reduce_ui`.

`dispatch(action)` → `new_state = reducer(state, action)` → `schedule_render()` (rAF, 16ms throttle).

`app.start(opts)`:

1. storage'dan `access_token`, `refresh_token`, `theme` yükle.
2. `GET /auth/me` → `AUTH_RESTORED` / `AUTH_ANONYMOUS`.
3. router.init() → `ROUTE_CHANGED`.
4. render loop.

## dom.lua

`h(tag, props, children)` → vnode; `render(vnode, containerHandle)` → keyed diff (`insertAt` ile odak korunur). Props: `class`, `style`, `onClick`, `data-*`, `value`.

Bridge: `js.dom.*` handle'ları; `dom.lua` handle lifecycle'ı yönetir (`release`).

## fetch.lua

```lua
local _M={}
function _M.request(method, path, opts)
  -- opts.body (table → json encode), opts.query (table → ?a=1)
  -- header: Authorization Bearer storage.get("access_token")
  -- js.http.request(method, apiBase..path..query, headersJson, body, callback)
  -- coroutine yield → resume
  -- 401 TOKEN_EXPIRED → refresh: POST /auth/refresh {refresh_token} → yeni token store → retry once
  -- 401 diğer → storage.remove + dispatch AUTH_ANONYMOUS + router #/login
  -- NETWORK_ERROR → { code="NETWORK_ERROR" }
end
function _M.get(path, query) return _M.request("GET", path, {query=query}) end
function _M.post(path, body) return _M.request("POST", path, {body=body}) end
function _M.download(path, token, filename) return js.http.download(apiBase..path, token, filename) end
```

`cjson` yok; `js.json.decode` kullanılır (null→nil).

## router.lua

```lua
local routes = {
  { name="login", pattern="#/login", auth=false },
  { name="connections", pattern="#/connections", page="connections.list" },
  { name="query", pattern="#/query", page="query.execute" },
  { name="browse", pattern="#/browse/:schema/:table", page="table.browser" },
  { name="structure", pattern="#/structure/:schema/:name", page="structure.view" },
  { name="users", pattern="#/users", page="users.list" },
  { name="rbac", pattern="#/rbac", page="rbac.matrix" },
  { name="audit", pattern="#/audit", page="audit.logs" },
}
function _M.init() -- js.location.onHashChange → dispatch ROUTE_CHANGED; guards: !auth → #/login, !can(page) → FORBIDDEN
```

## editor.lua

```lua
local editor = {}
function editor.create(containerHandle, opts)
  local h = js.editor.create(containerHandle, js.json.encode({ value=opts.value or "", schema=opts.schema }))
  -- opts.onChange, opts.onRun
  return h
end
function editor.set_completions(handle, catalog) -- { public={customers={columns={}}}}
  js.editor.setCompletions(handle, js.json.encode(catalog))
end
```

## DoD

- [ ] `dispatch({type="CONNECTIONS_LOADED", items={...}})` → render list yenilenir, başka dilim referans aynı.
- [ ] `fetch.get("/connections")` 401 expired → refresh → retry → success.
- [ ] Network offline → `NETWORK_ERROR` toast.
- [ ] Route `#/browse/public/customers` → `ROUTE_CHANGED` + `structure.view` guard.
- [ ] rAF render: 10 dispatch aynı frame'de → tek DOM güncelleme.
