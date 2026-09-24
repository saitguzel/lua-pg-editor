import { test, expect, Page } from "@playwright/test";
import { login, create_user, api_token, create_connection } from "./helpers";

// CodeMirror'a metin yaz (içeriği değiştirir)
async function type_sql(page: Page, sql: string) {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Delete");
  await page.keyboard.insertText(sql);
}

test.describe("query", () => {
  test("SELECT çalıştır → sonuç görünür, hata toast'u, geçmiş, CSV export", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    const token = await api_token(request, u.email, u.password);
    const conn = await create_connection(request, token);

    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Sorgu", exact: true }).click();
    await expect(page.getByRole("heading", { name: /Sorgu/ })).toBeVisible();
    await page.getByLabel("Bağlantı", { exact: true }).selectOption(conn.id);
    await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 10_000 });

    await type_sql(page, "SELECT 1 as one");
    await page.getByRole("button", { name: /Çalıştır/ }).click();
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["one"], { timeout: 15_000 });

    // hata: invalid sql
    await type_sql(page, "SELECT * FROM yok_tablo_xyz");
    await page.getByRole("button", { name: /Çalıştır/ }).click();
    await expect(page.locator("#toast-assertive")).toContainText(/Sorgu hatası|bulunamadi/i, { timeout: 15_000 });

    // CSV export (query): gerçek dosya iner
    await type_sql(page, "SELECT 1 AS a, NULL AS b");
    await page.getByRole("button", { name: "CSV" }).click();
    await page.getByLabel("Ayraç").selectOption(";");
    const [dl] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Dışa aktar" }).click()]);
    expect(dl.suggestedFilename()).toBe("query.csv");

    // geçmiş
    await page.getByRole("button", { name: "Geçmiş" }).click();
    await page.getByRole("button", { name: "Tümünü gör" }).click();
    await expect(page).toHaveURL(/query\/history/);
    await expect(page.getByRole("button", { name: "Uygula" }).first()).toBeVisible({ timeout: 10_000 });
  });

  test("Ctrl+Enter ile sorgu çalıştır", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    const token = await api_token(request, u.email, u.password);
    await create_connection(request, token);
    await login(page, u.email, u.password);
    await page.goto("#/query");
    await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 10_000 });
    await type_sql(page, "SELECT 2 AS iki");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["iki"], { timeout: 10_000 });
  });

  test("sekme yönetimi: yeni sekme aç/kapat", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/query");
    const tabs = page.locator("button[data-tab='query']");
    await expect(tabs).toHaveCount(1);
    await page.getByRole("button", { name: "Yeni sorgu sekmesi" }).click();
    await expect(tabs).toHaveCount(2);
    await page.getByRole("button", { name: /sekmesini kapat/ }).first().click();
    await expect(tabs).toHaveCount(1);
  });
});
