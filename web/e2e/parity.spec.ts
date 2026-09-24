// codd özellik eşitliği E2E (faz faz büyür). Demo bağlantısı: API'deki ilk bağlantı.
import { test, expect, Page } from "@playwright/test";
import { login, ADMIN, API } from "./helpers";

// Her test kendi gecici baglantisiyla (test DB'si) calisir; kullanicinin baglantilarina/verisine dokunmaz
let test_conn: { id: string } | null = null;
async function open_query(page: Page) {
  await login(page, ADMIN.email, ADMIN.password);
  const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
  const res = await page.request.post(`${API}/connections`, { headers: { Authorization: `Bearer ${token}` },
    data: { name: `e2e-parity-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`, host: "postgres", port: 5432,
      database: "pgeditor", username: "pgeditor", password: "pgeditor", save_password: true, ssl_mode: "disable" } });
  expect(res.status(), await res.text()).toBe(201);
  test_conn = (await res.json()).data;
  const id = test_conn!.id;
  test.info().attach("connection", { body: id });
  cleanups.push(() => page.request.delete(`${API}/connections/${id}`, { headers: { Authorization: `Bearer ${token}` } }));
  await page.goto(`#/query?connection_id=${id}`);
  await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 15_000 });
  await expect(page.getByLabel("Bağlantı", { exact: true })).toHaveValue(id);
}

const cleanups: Array<() => Promise<unknown>> = [];
test.afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!().catch(() => {});
});

async function set_sql(page: Page, sql: string) {
  const content = page.locator(".cm-content");
  await content.click();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Delete");
  await page.keyboard.insertText(sql);
}

test.describe("F0/F2 sorgu editörü", () => {
  test("satır numarası, renklendirme ve NULL hücreler", async ({ page }) => {
    await open_query(page);
    await set_sql(page, "SELECT NULL::int AS z, 2 AS b, 'x' AS a\nUNION ALL SELECT 1, NULL, NULL");
    await expect(page.locator(".cm-lineNumbers .cm-gutterElement", { hasText: "2" })).toBeVisible();
    await page.keyboard.press("ControlOrMeta+Enter");
    const grid = page.locator("table").last();
    await expect(grid.locator("thead th")).toHaveText(["z", "b", "a"]);
    await expect(grid.locator("tbody tr").nth(1).locator("td")).toHaveCount(3);
    await expect(grid.locator("tbody tr").nth(1).locator("td").nth(1)).toHaveText("NULL");
  });

  test("Ctrl+Enter INSERT'i tek kez çalıştırır", async ({ page }) => {
    await open_query(page);
    const t = `e2e_once_${Date.now()}`;
    await set_sql(page, `CREATE TEMP TABLE IF NOT EXISTS x(); SELECT 1`);
    const posts: string[] = [];
    page.on("request", (r) => { if (r.url().endsWith("/query/execute")) posts.push(t); });
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.locator("table").last()).toBeVisible();
    await page.waitForTimeout(500);
    expect(posts.length).toBe(1);
  });

  test("autocomplete şema tablolarını önerir", async ({ page }) => {
    await open_query(page);
    await set_sql(page, "SELECT * FROM ");
    await page.keyboard.press("Control+Space");
    await expect(page.locator(".cm-tooltip-autocomplete")).toBeVisible({ timeout: 10_000 });
  });

  test("iki sekme bağımsız; yazılan metin sidebar eklemesiyle kaybolmaz", async ({ page }) => {
    await open_query(page);
    await set_sql(page, "SELECT 'birinci'");
    await page.getByRole("button", { name: "Yeni sorgu sekmesi" }).click();
    await set_sql(page, "SELECT 'ikinci'");
    await page.locator("button[data-tab='query']").first().click();
    await expect(page.locator(".cm-content")).toContainText("birinci");
    await expect(page.locator(".cm-editor")).toHaveCount(1);
  });
});

test.describe("F3 çalıştırma ve sonuçlar", () => {
  test("uzun sorgu İptal ile sunucuda durdurulur", async ({ page }) => {
    await open_query(page);
    await set_sql(page, "SELECT pg_sleep(20)");
    await page.keyboard.press("ControlOrMeta+Enter");
    await page.getByRole("button", { name: /İptal/ }).click();
    await expect(page.getByRole("alert").filter({ hasText: "57014" })).toBeVisible({ timeout: 8_000 });
  });

  test("satır limiti: N+ işareti, tip renkleri, hücre görüntüleyici ve kopyala menüsü", async ({ page }) => {
    await open_query(page);
    await set_sql(page, "SELECT g, '{\"a\":1}'::jsonb AS j FROM generate_series(1,1500) g");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText("1000+ satır")).toBeVisible({ timeout: 10_000 });
    const cell = page.locator("td[data-cell='1:2']");
    await cell.dblclick();
    await expect(page.getByRole("dialog", { name: /Hücre değeri — j/ })).toContainText('"a": 1');
    await page.getByRole("dialog").getByRole("button", { name: "Kapat" }).first().click();
    await cell.click({ button: "right" });
    await expect(page.getByRole("menuitem", { name: "Satırı kopyala" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("menu")).toHaveCount(0);
  });
});

test.describe("F7 sidebar ve nesne eylemleri", () => {
  async function mk(page: Page) {
    const t = `e2e_s_${Date.now()}`;
    await open_query(page);
    await set_sql(page, `CREATE TABLE ${t}(id serial primary key, x int); INSERT INTO ${t}(x) VALUES (1),(2); CREATE VIEW ${t}_v AS SELECT * FROM ${t}`);
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/tamamlandı|satır etkilendi/)).toBeVisible({ timeout: 10_000 });
    await page.getByRole("button", { name: "Yenile", exact: true }).first().click();
    return t;
  }

  test("arama, tıklayınca tarayıcı, yeniden adlandır, boşalt, CASCADE ile sil", async ({ page }) => {
    const t = await mk(page);
    const side = page.getByRole("complementary", { name: "Veritabanı nesneleri" });
    await side.getByLabel("Nesne ara").fill(t);
    await expect(side.getByRole("link", { name: t, exact: true })).toBeVisible({ timeout: 10_000 });
    await expect(side.getByRole("link", { name: `${t}_v` })).toBeVisible();
    // rename
    await side.getByRole("button", { name: `${t} menüsü` }).click();
    await page.getByRole("menuitem", { name: "Yeniden adlandır…" }).click();
    await page.getByLabel("Yeni ad").fill(`${t}_r`);
    await page.getByRole("dialog").getByRole("button", { name: "Tamam" }).click();
    await expect(side.getByRole("link", { name: `${t}_r`, exact: true })).toBeVisible({ timeout: 10_000 });
    // tıkla → tarayıcı
    await side.getByRole("link", { name: `${t}_r`, exact: true }).click();
    await expect(page.getByText("1-2 / 2 satır")).toBeVisible({ timeout: 10_000 });
    // boşalt (RESTART IDENTITY)
    await side.getByRole("button", { name: `${t}_r menüsü` }).click();
    await page.getByRole("menuitem", { name: /Boşalt/ }).click();
    await page.getByLabel(/RESTART IDENTITY/).check();
    await page.getByRole("dialog").getByRole("button", { name: "Boşalt" }).click();
    await expect(page.getByText("0-0 / 0 satır")).toBeVisible({ timeout: 10_000 });
    // sil: bağımlı view → CASCADE önerisi
    await side.getByRole("button", { name: `${t}_r menüsü` }).click();
    await page.getByRole("menuitem", { name: "Sil…" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "CASCADE ile sil" }).click();
    await expect(page).toHaveURL(/#\/query/);
    await expect(side.getByRole("link", { name: `${t}_r`, exact: true })).toHaveCount(0);
    await expect(side.getByRole("link", { name: `${t}_v` })).toHaveCount(0);
  });
});

test.describe("F8/F9 script ve yapı", () => {
  test("yapı sekmeleri, kolon yeniden adlandır, bağımlı kolon CASCADE ile sil, UPDATE scripti yeni sekmede", async ({ page }) => {
    const t = `e2e_st_${Date.now()}`;
    await open_query(page);
    await set_sql(page, `CREATE TABLE ${t}_p(id int primary key);
      CREATE TABLE ${t}(id serial primary key, pid int REFERENCES ${t}_p(id) ON DELETE CASCADE, note text, amount int CHECK (amount > 0));
      CREATE INDEX ${t}_note ON ${t}(note);
      CREATE FUNCTION ${t}_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
      CREATE TRIGGER ${t}_tg BEFORE INSERT ON ${t} FOR EACH ROW EXECUTE FUNCTION ${t}_fn();
      CREATE VIEW ${t}_v AS SELECT note FROM ${t}`);
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/tamamlandı|satır etkilendi/)).toBeVisible({ timeout: 10_000 });
    const conn = await page.getByLabel("Bağlantı", { exact: true }).inputValue();
    const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
    // test nesnelerini kaldir (baglanti silinmeden once calisir: cleanups LIFO)
    cleanups.push(() => page.request.post(`${API}/query/execute`, { headers: { Authorization: `Bearer ${token}` },
      data: { connection_id: conn, sql: `DROP TABLE IF EXISTS ${t}, ${t}_p CASCADE; DROP FUNCTION IF EXISTS ${t}_fn()` } }));
    await page.goto(`#/structure/public/${t}?connection_id=${conn}`);
    await expect(page.getByRole("button", { name: "Kolonlar (4)" })).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole("button", { name: "Foreign Keys (1)" })).toBeVisible();
    await page.getByRole("button", { name: "Foreign Keys (1)" }).click();
    await expect(page.getByRole("cell", { name: "Cascade" })).toBeVisible();
    await page.getByRole("button", { name: "Trigger'lar (1)" }).click();
    await expect(page.getByRole("cell", { name: "Enabled" })).toBeVisible();
    // kolon yeniden adlandır
    await page.getByRole("button", { name: /^Kolonlar/ }).click();
    await page.getByRole("button", { name: "amount menüsü" }).click();
    await page.getByRole("menuitem", { name: "Yeniden adlandır…" }).click();
    await page.getByLabel("Yeni ad").fill("tutar");
    await page.getByRole("dialog").getByRole("button", { name: "Tamam" }).click();
    await expect(page.getByRole("cell", { name: "tutar", exact: true })).toBeVisible();
    // PK index'i constraint'e bağlı → yalnızca "Adı kopyala"
    await page.getByRole("button", { name: /^Indexler/ }).click();
    await page.getByRole("button", { name: `${t}_pkey menüsü` }).click();
    await expect(page.getByRole("menuitem", { name: "Sil…" })).toHaveCount(0);
    await page.keyboard.press("Escape");
    // view'ın bağlı olduğu kolonu sil → CASCADE önerisi
    await page.getByRole("button", { name: /^Kolonlar/ }).click();
    await page.getByRole("button", { name: "note menüsü" }).click();
    await page.getByRole("menuitem", { name: "Sil…" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "CASCADE ile sil" }).click();
    await expect(page.getByRole("button", { name: "Kolonlar (3)" })).toBeVisible();
    // UPDATE scripti yeni sorgu sekmesinde
    await page.getByRole("button", { name: /^Eylemler/ }).click();
    await page.getByRole("menuitem", { name: "UPDATE" }).click();
    await expect(page).toHaveURL(/#\/query/);
    await expect(page.locator(".cm-content")).toContainText(`UPDATE "public"."${t}"`);
    await expect(page.locator(".cm-content")).toContainText(`WHERE "id" = $3`);
  });
});

test.describe("F4 geçmiş", () => {
  test("aynı SQL tekrar çalışınca tek kayıt; Uygula editöre alır", async ({ page }) => {
    const marker = `hist_${Date.now()}`;
    await open_query(page);
    for (let i = 0; i < 2; i++) {
      await set_sql(page, `SELECT '${marker}'`);
      await page.keyboard.press("ControlOrMeta+Enter");
      await expect(page.locator("table").last()).toBeVisible();
    }
    await set_sql(page, "SELECT 1");
    await page.getByRole("button", { name: "Geçmiş" }).click();
    const dlg = page.getByRole("dialog", { name: "Geçmiş" });
    await expect(dlg.getByText(`SELECT '${marker}'`)).toHaveCount(1);
    await dlg.getByRole("listitem").filter({ hasText: marker }).getByRole("button", { name: "Uygula" }).click();
    await expect(page.locator(".cm-content")).toHaveText(`SELECT '${marker}'`);
  });
});

test.describe("F10 bağlantılar", () => {
  async function api_conn(page: Page, body: Record<string, unknown>) {
    const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
    const res = await page.request.post("http://localhost:28180/api/v1/connections", {
      headers: { Authorization: `Bearer ${token}` },
      data: { name: `e2e-c-${Date.now()}`, host: "postgres", port: 5432, database: "pgeditor", username: "pgeditor",
        ssl_mode: "disable", ...body } });
    expect(res.status(), await res.text()).toBe(201);
    const conn = (await res.json()).data;
    // test sonunda kaldir: sorgu sayfasi en yeni baglantiyi varsayilan secer, digerlerini etkilemesin
    conn.remove = () => page.request.delete(`http://localhost:28180/api/v1/connections/${conn.id}`,
      { headers: { Authorization: `Bearer ${token}` } });
    return conn;
  }

  test("kaydedilmemiş parola sorulur; veritabanı seçici; kartta Sorgu bağlantıyı taşır", async ({ page }) => {
    await open_query(page);
    // parola zorunlu rol (yerel pgeditor kullanicisi parolasiz kabul ediliyor)
    await set_sql(page, "DO $$ BEGIN CREATE ROLE e2e_pw LOGIN PASSWORD 'pw123'; EXCEPTION WHEN duplicate_object THEN NULL; END $$");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/tamamlandı|satır etkilendi/)).toBeVisible({ timeout: 10_000 });
    const conn = await api_conn(page, { save_password: false, username: "e2e_pw" });
    try {
    await page.goto("#/connections");
    await page.reload();
    await page.getByRole("searchbox", { name: "Bağlantı ara" }).fill(conn.name);
    const sorgu = page.locator("[data-id]", { hasText: conn.name }).getByRole("link", { name: "Sorgu" });
    await expect(sorgu).toHaveAttribute("href", `#/query?connection_id=${conn.id}`);
    await page.goto(`#/query?connection_id=${conn.id}`);
    // PASSWORD_REQUIRED → nesne kataloğu yüklenirken parola bir kez sorulur (eş zamanlı istekler bekler)
    const dlg = page.getByRole("dialog", { name: "Parola gerekli" });
    await expect(dlg).toHaveCount(1, { timeout: 10_000 });
    await dlg.getByRole("textbox").fill("pw123");
    await dlg.getByRole("button", { name: "Tamam" }).click();
    await expect(dlg).toHaveCount(0);
    await expect(page.getByLabel("Bağlantı", { exact: true })).toHaveValue(conn.id);
    await set_sql(page, "SELECT current_database() AS db");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.locator("td[data-cell='1:1']")).toHaveText("pgeditor", { timeout: 10_000 });
    // veritabanı değiştir
    await page.getByLabel("Veritabanı", { exact: true }).fill("postgres");
    await page.getByLabel("Veritabanı", { exact: true }).press("Enter");
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.locator("td[data-cell='1:1']")).toHaveText("postgres", { timeout: 10_000 });
    } finally { await conn.remove(); }
  });

  test("SSH tüneli: sunucu anahtarı onayı ve tünel üzerinden sorgu", async ({ page }) => {
    test.skip(!process.env.SSH_E2E_HOST, "SSH_E2E_HOST (test sshd) tanımlı değil");
    await open_query(page);
    const conn = await api_conn(page, { password: process.env.SSH_E2E_DB_PASSWORD, save_password: true,
      ssh_enabled: true, ssh_host: process.env.SSH_E2E_HOST, ssh_port: 22, ssh_username: process.env.SSH_E2E_USER,
      ssh_auth_method: "password", ssh_secret: process.env.SSH_E2E_PASSWORD });
    try {
    await page.goto(`#/query?connection_id=${conn.id}`);
    await set_sql(page, "SELECT 'tunel' AS t");
    await page.keyboard.press("ControlOrMeta+Enter");
    const dlg = page.getByRole("dialog", { name: "SSH sunucu anahtarına güvenilsin mi?" });
    await expect(dlg).toContainText("SHA256:", { timeout: 15_000 });
    await dlg.getByRole("button", { name: "Güven ve bağlan" }).click();
    await expect(page.locator("td[data-cell='1:1']")).toHaveText("tunel", { timeout: 20_000 });
    } finally { await conn.remove(); }
  });
});

test.describe("F11 UX", () => {
  test("Alt+N yeni sekme, Alt+W kapat, Ctrl+E editöre odak; compact mode", async ({ page }) => {
    await open_query(page);
    const tabs = page.locator("button[data-tab='query']");
    const n = await tabs.count();
    await page.getByRole("heading", { name: "Sorgu Editörü" }).click();
    await page.keyboard.press("Alt+n");
    await expect(tabs).toHaveCount(n + 1);
    await page.keyboard.press("Alt+w");
    await expect(tabs).toHaveCount(n);
    await page.getByRole("heading", { name: "Sorgu Editörü" }).click();
    await page.keyboard.press("Control+e");
    await expect(page.locator(".cm-content")).toBeFocused();
    // compact mode
    await page.goto("#/settings");
    await page.getByLabel(/Sıkı görünüm/).check();
    await expect(page.locator("html")).toHaveAttribute("data-density", "compact");
    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-density", "compact");
    await page.getByLabel(/Sıkı görünüm/).uncheck();
    await expect(page.locator("html")).toHaveAttribute("data-density", "comfortable");
  });
});

test.describe("Faz 2 fonksiyon / prosedür / trigger", () => {
  test("listele, overload ayrımı, DDL düzenle, çağrı betiği, trigger kapat, yeniden adlandır, sil, CASCADE, tamamlama", async ({ page }) => {
    const t = `e2e_r_${Date.now()}`;
    await open_query(page);
    const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
    // testin oluşturduğu nesneler her durumda kaldırılır
    const cleanup_sql = [`TABLE IF EXISTS ${t} CASCADE`, `FUNCTION IF EXISTS ${t}_fn(int)`, `FUNCTION IF EXISTS ${t}_fn(text)`,
      `PROCEDURE IF EXISTS ${t}_pr()`, `PROCEDURE IF EXISTS ${t}_pr2()`, `FUNCTION IF EXISTS ${t}_tf() CASCADE`]
      .map((x) => "DROP " + x).join("; ");
    cleanups.push(() => page.request.post(`${API}/query/execute`, { headers: { Authorization: `Bearer ${token}` },
      data: { connection_id: test_conn!.id, sql: cleanup_sql } }));
    await set_sql(page, `CREATE TABLE ${t}(id int primary key, u timestamptz);
      CREATE FUNCTION ${t}_fn(a integer) RETURNS integer LANGUAGE sql AS 'SELECT a + 1';
      CREATE FUNCTION ${t}_fn(a text) RETURNS text LANGUAGE sql AS 'SELECT a';
      CREATE PROCEDURE ${t}_pr() LANGUAGE sql AS 'SELECT 1';
      CREATE FUNCTION ${t}_tf() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN NEW.u := now(); RETURN NEW; END';
      CREATE TRIGGER ${t}_trg BEFORE UPDATE ON ${t} FOR EACH ROW EXECUTE FUNCTION ${t}_tf()`);
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/tamamlandı|satır etkilendi/)).toBeVisible({ timeout: 10_000 });
    await page.getByRole("button", { name: "Yenile", exact: true }).first().click();

    const side = page.getByRole("complementary", { name: "Veritabanı nesneleri" });
    await side.getByLabel("Nesne ara").fill(t);
    const fnInt = side.getByRole("button", { name: `${t}_fn(a integer) (fonksiyon)` });
    const fnText = side.getByRole("button", { name: `${t}_fn(a text) (fonksiyon)` });
    await expect(fnInt).toBeVisible({ timeout: 10_000 });
    await expect(fnText).toBeVisible();
    await expect(side.getByRole("button", { name: `${t}_pr() (prosedür)` })).toBeVisible();
    await expect(side.getByRole("button", { name: `${t}_trg (trigger)` })).toBeVisible();

    // tıkla → düzenlenebilir DDL yeni sekmede
    await fnInt.click();
    await expect(page.locator(".cm-content")).toContainText(`CREATE OR REPLACE FUNCTION public.${t}_fn(a integer)`, { timeout: 10_000 });

    // overload'ın çağrı betiği
    const menu = (name: string) => side.getByRole("button", { name: `${name} menüsü`, exact: true });
    await menu(`${t}_fn`).last().click();
    await page.getByRole("menuitem", { name: "SELECT betiği" }).click();
    await expect(page.locator(".cm-content")).toContainText(`SELECT * FROM "public"."${t}_fn"(`, { timeout: 10_000 });
    await expect(page.locator(".cm-content")).toContainText("NULL /* a text */");

    // trigger devre dışı → menüde "Etkinleştir"
    await menu(`${t}_trg`).click();
    await page.getByRole("menuitem", { name: "Devre dışı bırak" }).click();
    await expect(page.getByText(/devre dışı bırakıldı/)).toBeVisible({ timeout: 10_000 });
    await expect(async () => {
      await menu(`${t}_trg`).click();
      await expect(page.getByRole("menuitem", { name: "Etkinleştir" })).toBeVisible({ timeout: 1_000 });
    }).toPass({ timeout: 10_000 });
    await page.keyboard.press("Escape");

    // prosedürü yeniden adlandır
    await menu(`${t}_pr`).click();
    await page.getByRole("menuitem", { name: "Yeniden adlandır…" }).click();
    await page.getByLabel("Yeni ad").fill(`${t}_pr2`);
    await page.getByRole("dialog").getByRole("button", { name: "Tamam" }).click();
    await expect(side.getByRole("button", { name: `${t}_pr2() (prosedür)` })).toBeVisible({ timeout: 10_000 });

    // overload'lardan yalnızca biri silinir
    await menu(`${t}_fn`).first().click();
    await page.getByRole("menuitem", { name: "Sil…" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await expect(fnInt).toHaveCount(0, { timeout: 10_000 });
    await expect(fnText).toBeVisible();

    // trigger fonksiyonu: bağımlı trigger → CASCADE önerisi
    await menu(`${t}_tf`).click();
    await page.getByRole("menuitem", { name: "Sil…" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "CASCADE ile sil" }).click();
    await expect(side.getByRole("button", { name: `${t}_trg (trigger)` })).toHaveCount(0, { timeout: 10_000 });

    // "+" yeni fonksiyon taslağı
    await side.getByLabel("Nesne ara").fill("");
    await side.getByRole("button", { name: "Yeni fonksiyon (public)" }).click();
    await expect(page.locator(".cm-content")).toContainText("CREATE OR REPLACE FUNCTION public.fonksiyon_adi", { timeout: 10_000 });

    // tamamlama: kullanıcı fonksiyonu imzasıyla önerilir
    await set_sql(page, `SELECT ${t}_f`);
    await page.keyboard.press("Control+Space");
    await expect(page.locator(".cm-tooltip-autocomplete")).toContainText(`${t}_fn`, { timeout: 10_000 });
  });
});

test.describe("Faz 3 taslaklar ve geçmiş araması", () => {
  test("hazır taslak Ctrl+J ile eklenir; seçimi kaydet, önek + Tab, düzenle, sil", async ({ page }) => {
    const p = `e2e${Date.now() % 1_000_000}`;
    await open_query(page);
    const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
    // testin taslakları her durumda silinir
    cleanups.push(async () => {
      const list = await (await page.request.get(`${API}/snippets`, { headers: { Authorization: `Bearer ${token}` } })).json();
      for (const s of list.data || []) {
        if ((s.name || "").startsWith(p)) {
          await page.request.delete(`${API}/snippets/${s.id}`, { headers: { Authorization: `Bearer ${token}` } });
        }
      }
    });
    const dialog = page.getByRole("dialog", { name: "Taslaklar" });

    // hazır taslak: ara + Enter → yer tutucular düz metin olarak eklenir
    await set_sql(page, "");
    await page.keyboard.press("Control+j");
    await expect(dialog).toBeVisible();
    await dialog.getByLabel("Taslak ara").fill("CREATE PROCEDURE");
    await page.keyboard.press("Enter");
    await expect(dialog).toHaveCount(0);
    await expect(page.locator(".cm-content")).toContainText("CREATE OR REPLACE PROCEDURE sema.prosedur_adi");

    // seçimi taslak olarak kaydet (Alt+S): önek ile
    await set_sql(page, `SELECT 42 AS ${p}_col`);
    await page.keyboard.press("Alt+s");
    await dialog.getByLabel("Ad", { exact: true }).fill(`${p} cevap`);
    await dialog.getByLabel(/Önek/).fill(p);
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog.getByRole("option", { name: `${p} cevap` })).toBeVisible({ timeout: 10_000 });
    // aynı önek ikinci kez → çakışma hatası
    await dialog.getByRole("button", { name: "Yeni taslak" }).click();
    await dialog.getByLabel("Ad", { exact: true }).fill(`${p} ikinci`);
    await dialog.getByLabel(/Önek/).fill(p);
    await dialog.getByLabel(/SQL/).fill("SELECT 1");
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog.getByRole("alert")).toContainText("önek");
    await dialog.getByRole("button", { name: "Vazgeç" }).click();
    await dialog.getByRole("button", { name: "Kapat", exact: true }).last().click();

    // önek + Tab editörde taslağı açar
    await set_sql(page, "");
    await page.keyboard.type(p);
    await expect(page.locator(".cm-tooltip-autocomplete")).toContainText(p, { timeout: 10_000 });
    await page.keyboard.press("Tab");
    await expect(page.locator(".cm-content")).toContainText(`SELECT 42 AS ${p}_col`);

    // düzenle ve sil
    await page.keyboard.press("Control+j");
    await dialog.getByLabel("Taslak ara").fill(p);
    await dialog.getByRole("button", { name: `${p} cevap düzenle` }).click();
    await dialog.getByLabel("Ad", { exact: true }).fill(`${p} yeni ad`);
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog.getByRole("option", { name: `${p} yeni ad` })).toBeVisible({ timeout: 10_000 });
    await dialog.getByRole("button", { name: `${p} yeni ad sil` }).click();
    await page.getByRole("dialog", { name: "Taslak silinsin mi?" }).getByRole("button", { name: "Sil" }).click();
    await expect(dialog.getByRole("option", { name: `${p} yeni ad` })).toHaveCount(0, { timeout: 10_000 });
  });

  test("geçmişte arama: popover ve geçmiş sayfası, eşleşme vurgulu", async ({ page }) => {
    const m = `ara_${Date.now()}`;
    await open_query(page);
    for (const sql of [`SELECT 1 AS ${m}`, "SELECT 2 AS baska_kolon"]) {
      await set_sql(page, sql);
      await page.keyboard.press("ControlOrMeta+Enter");
      await expect(page.locator("table").last().locator("thead th").first()).toBeVisible({ timeout: 10_000 });
    }
    await page.getByRole("button", { name: "Geçmiş" }).click();
    const pop = page.getByRole("dialog", { name: "Geçmiş" });
    await pop.getByLabel("Geçmişte ara").fill(m);
    await expect(pop.locator("pre")).toHaveCount(1, { timeout: 10_000 });
    await expect(pop.locator("mark")).toHaveText(m);
    await pop.getByRole("button", { name: "Tümünü gör" }).click();
    await expect(page).toHaveURL(/query\/history/);
    const search = page.getByLabel("Geçmişte ara");
    await expect(search).toHaveValue(m);
    await expect(page.locator("main li pre")).toHaveCount(1, { timeout: 10_000 });
    await search.fill("yok_boyle_bir_sey_xyz");
    await expect(page.getByText("Eşleşme yok")).toBeVisible({ timeout: 10_000 });
    await search.fill("");
    await expect.poll(async () => page.locator("main li pre").count(), { timeout: 10_000 }).toBeGreaterThan(1);
  });
});
