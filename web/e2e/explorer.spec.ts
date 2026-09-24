// F26 nesne gezgini: şema → kategori (sayaçlı) → nesne ağacı, lazy istek, arama, hızlı filtre, sağ tık, detay.
import { test, expect, Page } from "@playwright/test";
import { login, ADMIN, API } from "./helpers";

let test_conn: { id: string } | null = null;
const cleanups: Array<() => Promise<unknown>> = [];
test.afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!().catch(() => {});
});

async function open_query(page: Page) {
  await login(page, ADMIN.email, ADMIN.password);
  const token = await page.evaluate(() => JSON.parse(localStorage.getItem("pg.auth") || "{}").access_token);
  const res = await page.request.post(`${API}/connections`, { headers: { Authorization: `Bearer ${token}` },
    data: { name: `e2e-explorer-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`, host: "postgres", port: 5432,
      database: "pgeditor", username: "pgeditor", password: "pgeditor", save_password: true, ssl_mode: "disable" } });
  expect(res.status(), await res.text()).toBe(201);
  test_conn = (await res.json()).data;
  const id = test_conn!.id;
  cleanups.push(() => page.request.delete(`${API}/connections/${id}`, { headers: { Authorization: `Bearer ${token}` } }));
  await page.goto(`#/query?connection_id=${id}`);
  await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 15_000 });
  return token;
}

async function set_sql(page: Page, sql: string) {
  const content = page.locator(".cm-content");
  await content.click();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Delete");
  await page.keyboard.insertText(sql);
}

test.describe("F26 nesne gezgini", () => {
  test("kategori sayaçları, lazy yükleme, arama, hızlı filtre, CREATE script, yenile, alt düğümler, detay", async ({ page }) => {
    const t = `e2e_x_${Date.now()}`;
    const token = await open_query(page);
    cleanups.push(() => page.request.post(`${API}/query/execute`, { headers: { Authorization: `Bearer ${token}` },
      data: { connection_id: test_conn!.id,
        sql: `DROP TABLE IF EXISTS ${t} CASCADE; DROP SEQUENCE IF EXISTS ${t}_seq; DROP TYPE IF EXISTS ${t}_mood` } }));
    await set_sql(page, `CREATE TABLE ${t}(id serial primary key, x int);
      ALTER TABLE ${t} ENABLE ROW LEVEL SECURITY;
      CREATE POLICY ${t}_pol ON ${t} FOR SELECT USING (true);
      CREATE VIEW ${t}_v AS SELECT * FROM ${t};
      CREATE SEQUENCE ${t}_seq START 5 INCREMENT 2;
      CREATE TYPE ${t}_mood AS ENUM ('sad', 'ok', 'happy')`);
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/tamamlandı|satır etkilendi/)).toBeVisible({ timeout: 10_000 });
    await page.getByRole("button", { name: "Yenile", exact: true }).first().click();

    const side = page.getByRole("complementary", { name: "Veritabanı nesneleri" });
    // sayaçlı kategoriler
    const tables = side.getByRole("button", { name: /^Tables \(\d+\)$/ });
    await expect(tables).toBeVisible({ timeout: 10_000 });
    await expect(side.getByRole("button", { name: /^Sequences \(\d+\)$/ })).toBeVisible();
    await expect(side.getByRole("button", { name: /^Types \(\d+\)$/ })).toBeVisible();

    // lazy: kategori açılana kadar nesne isteği yok
    const requests: string[] = [];
    page.on("request", (r) => { if (r.url().includes("/objects?")) requests.push(r.url()); });
    expect(requests.filter((u) => u.includes("category=tables")).length).toBe(0);
    await tables.click();
    await expect(side.getByRole("link", { name: t, exact: true })).toBeVisible({ timeout: 10_000 });
    expect(requests.filter((u) => u.includes("category=tables")).length).toBe(1);

    // alt düğümler: Columns / Policies
    await side.getByRole("button", { name: `${t} alt öğeleri` }).click();
    await expect(side.getByRole("button", { name: "Columns (2)" })).toBeVisible({ timeout: 10_000 });
    await expect(side.getByRole("button", { name: "Policies (1)" })).toBeVisible();
    await side.getByRole("button", { name: "Columns (2)" }).click();
    await expect(side.getByRole("link", { name: /^id / })).toBeVisible();

    // arama: sunucu tarafı, kategoriye göre gruplu
    await side.getByLabel("Nesne ara").fill(t);
    await expect(side.getByRole("link", { name: `${t}_v`, exact: true })).toBeVisible({ timeout: 10_000 });
    await expect(side.getByRole("link", { name: `${t}_seq`, exact: true })).toBeVisible();
    await expect(side.getByRole("link", { name: `${t}_mood`, exact: true })).toBeVisible();

    // hızlı filtre: yalnız tablolar
    await side.getByRole("radio", { name: "Sadece tablolar" }).click();
    await expect(side.getByRole("link", { name: t, exact: true })).toBeVisible();
    await expect(side.getByRole("link", { name: `${t}_v`, exact: true })).toHaveCount(0);
    await side.getByRole("radio", { name: "Tümü" }).click();
    await expect(side.getByRole("link", { name: `${t}_v`, exact: true })).toBeVisible();

    // sağ tık view → CREATE script yeni sekmede
    await side.getByRole("button", { name: `${t}_v menüsü` }).click();
    await page.getByRole("menuitem", { name: "CREATE" }).click();
    await expect(page.locator(".cm-content")).toContainText(`CREATE VIEW`, { timeout: 10_000 });

    // sağ tık sequence → CREATE script
    await side.getByRole("button", { name: `${t}_seq menüsü` }).click();
    await page.getByRole("menuitem", { name: "CREATE script'i göster" }).click();
    await expect(page.locator(".cm-content")).toContainText(`CREATE SEQUENCE`, { timeout: 10_000 });

    // kategori sağ tık → Yenile yeni istek atar
    await side.getByLabel("Nesne ara").fill("");
    const before = requests.filter((u) => u.includes("category=tables")).length;
    await tables.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Yenile" }).click();
    await expect.poll(() => requests.filter((u) => u.includes("category=tables")).length).toBeGreaterThan(before);

    // detay: sequence → yapı sayfasında start/increment
    await side.getByLabel("Nesne ara").fill(`${t}_seq`);
    await side.getByRole("link", { name: `${t}_seq`, exact: true }).click();
    await expect(page).toHaveURL(/kind=sequence/);
    await expect(page.getByText("increment")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText("CREATE script")).toBeVisible();
  });
});
