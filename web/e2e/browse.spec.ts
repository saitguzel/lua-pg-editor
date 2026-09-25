import { test, expect, Page, APIRequestContext } from "@playwright/test";
import { login, create_user, api_token, create_connection, API } from "./helpers";

// Test verisi: kendi PK'li tablosu (+ view ve PK'siz tablo); test sonunda kaldırılır
async function sql(request: APIRequestContext, token: string, conn: string, q: string) {
  const res = await request.post(`${API}/query/execute`, { headers: { Authorization: `Bearer ${token}` },
    data: { connection_id: conn, sql: q } });
  expect(res.ok(), await res.text()).toBeTruthy();
}

async function setup(page: Page, request: APIRequestContext) {
  const u = await create_user(request, "editor");
  const token = await api_token(request, u.email, u.password);
  const conn = await create_connection(request, token);
  const t = `e2e_b_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
  await sql(request, token, conn.id, `
    DO $$ BEGIN CREATE TYPE e2e_mood AS ENUM ('sad','ok','happy'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    CREATE TABLE ${t} (id serial PRIMARY KEY, name text NOT NULL, note text, mood e2e_mood, flag bool);
    INSERT INTO ${t} (name, note, mood, flag) SELECT 'row' || g, CASE WHEN g % 2 = 0 THEN NULL ELSE 'n' || g END, 'ok', g % 3 = 0
      FROM generate_series(1, 120) g;
    CREATE VIEW ${t}_v AS SELECT * FROM ${t};
    CREATE TABLE ${t}_nopk (a int)`);
  await login(page, u.email, u.password);
  const cleanup = () => sql(request, token, conn.id, ["DROP VIEW IF EXISTS", `${t}_v;`, "DROP TABLE IF EXISTS", `${t}, ${t}_nopk`].join(" "));
  return { conn, t, cleanup };
}

const cell = (page: Page, r: number, c: number) => page.locator(`td[data-cell='${r}:${c}']`);

test.describe("browse (codd tablo tarayıcı)", () => {
  test("sıralama, filtre paneli, sayfalama", async ({ page, request }) => {
    const { conn, t, cleanup } = await setup(page, request);
    await page.goto(`#/browse/public/${t}?connection_id=${conn.id}`);
    await expect(page.getByText("1-100 / 120 satır")).toBeVisible({ timeout: 15_000 });
    await expect(cell(page, 1, 1)).toHaveText("1"); // varsayılan sıra: PK
    // sıralama: artan → azalan
    await page.getByRole("button", { name: /^id/ }).click();
    await page.getByRole("button", { name: /^id/ }).click();
    await expect(cell(page, 1, 1)).toHaveText("120");
    // son sayfa
    await page.getByRole("button", { name: "Son sayfa" }).click();
    await expect(page.getByText("101-120 / 120 satır")).toBeVisible();
    // filtre: note IS NULL
    await page.getByRole("button", { name: "Filtreler" }).click();
    await page.getByRole("button", { name: "+ Filtre ekle" }).click();
    await page.getByLabel("Filtre 1 kolon").selectOption("note");
    await expect(page.getByLabel("Filtre 1 operatör").locator("option")).toHaveText(["=", "!=", "LIKE", "ILIKE", "IS NULL", "IS NOT NULL"]);
    await page.getByLabel("Filtre 1 operatör").selectOption("IS NULL");
    await page.getByRole("button", { name: "Uygula" }).click();
    await expect(page.getByText("1-60 / 60 satır")).toBeVisible();
    await expect(page.getByRole("button", { name: "Filtreler (1)" })).toBeVisible();
    await cleanup();
  });

  test("hücre düzenle, NULL yap, enum, ekle, çoğalt, sil", async ({ page, request }) => {
    const { conn, t, cleanup } = await setup(page, request);
    await page.goto(`#/browse/public/${t}?connection_id=${conn.id}`);
    await expect(cell(page, 1, 3)).toHaveText("n1", { timeout: 15_000 });
    // note → NULL
    await cell(page, 1, 3).dblclick();
    await page.getByRole("dialog").getByRole("button", { name: "NULL yap" }).click();
    await expect(cell(page, 1, 3)).toHaveText("NULL");
    // mood enum seçimi
    await cell(page, 1, 4).dblclick();
    await page.getByRole("dialog").locator("select").selectOption("happy");
    await page.getByRole("dialog").getByRole("button", { name: "Kaydet" }).click();
    await expect(cell(page, 1, 4)).toHaveText("happy");
    // PK düzenlenemez: çift tık salt okunur görüntüleyici açar
    await cell(page, 1, 1).dblclick();
    await expect(page.getByRole("dialog", { name: /Hücre değeri — id/ })).toBeVisible();
    await page.getByRole("dialog").getByRole("button", { name: "Kapat" }).first().click();
    // ekle: id varsayılan, name değer
    await page.getByRole("button", { name: "+ Satır ekle" }).click();
    const dlg = page.getByRole("dialog", { name: "Yeni satır" });
    await dlg.locator("#val-name").fill("yeni-satır");
    await dlg.getByRole("button", { name: "Kaydet" }).click();
    await expect(dlg).toHaveCount(0);
    await expect(page.getByText("/ 121 satır")).toBeVisible();
    // çoğalt (sağ tık menüsü → ön-dolu form)
    await cell(page, 2, 2).click({ button: "right" });
    await page.getByRole("menuitem", { name: "Satırı çoğalt" }).click();
    const dup = page.getByRole("dialog", { name: "Satırı çoğalt" });
    await expect(dup.locator("#val-name")).toHaveValue("row2");
    await dup.getByRole("button", { name: "Kaydet" }).click();
    await expect(page.getByText("/ 122 satır")).toBeVisible();
    // Delete tuşu: odaklı satırı siler
    await cell(page, 3, 2).click();
    await page.keyboard.press("Delete");
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await expect(page.getByText("/ 121 satır")).toBeVisible();
    // toplu silme
    await page.getByLabel("Satır 1 seç").check();
    await page.getByLabel("Satır 2 seç").check();
    await page.getByRole("button", { name: "Sil (2)" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil" }).click();
    await expect(page.getByText("/ 119 satır")).toBeVisible();
    // CSV
    await page.getByRole("button", { name: "Dışa aktar" }).click();
    await page.getByLabel("Ayraç").selectOption(";");
    const [dl] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "İndir" }).click()]);
    expect(dl.suggestedFilename()).toBe(`${t}.csv`);
    await cleanup();
  });

  test("view ve PK'siz tablo salt okunur", async ({ page, request }) => {
    const { conn, t, cleanup } = await setup(page, request);
    await page.goto(`#/browse/public/${t}_v?connection_id=${conn.id}`);
    await expect(page.getByText("salt okunur")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByRole("button", { name: "+ Satır ekle" })).toHaveCount(0);
    await page.goto(`#/browse/public/${t}_nopk?connection_id=${conn.id}`);
    await expect(page.getByText("birincil anahtar yok")).toBeVisible({ timeout: 15_000 });
    await cleanup();
  });

  test("custom_where kaçış denemesi reddedilir", async ({ page, request }) => {
    const { conn, t, cleanup } = await setup(page, request);
    await page.goto(`#/browse/public/${t}?connection_id=${conn.id}&custom_where=${encodeURIComponent("1=1; x")}`);
    await expect(page.getByRole("main").getByRole("alert").filter({ hasText: /noktali virgul/i })).toBeVisible({ timeout: 10_000 });
    await cleanup();
  });
});
