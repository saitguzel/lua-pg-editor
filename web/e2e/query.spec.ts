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
    await page.getByRole("button", { name: "Dışa aktar" }).click();
    await page.getByLabel("Ayraç").selectOption(";");
    const [dl] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "İndir" }).click()]);
    expect(dl.suggestedFilename()).toBe("query.csv");
    // Excel ve JSON: dosya adı + içerik imzası (xlsx = zip "PK", json = dizi)
    for (const [fmt, check] of [
      ["xlsx", (b: Buffer) => b.subarray(0, 2).toString() === "PK"],
      ["json", (b: Buffer) => JSON.parse(b.toString())[0].a === 1],
    ] as const) {
      await page.getByRole("button", { name: "Dışa aktar" }).click();
      await page.getByLabel("Format").selectOption(fmt);
      const [d] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "İndir" }).click()]);
      expect(d.suggestedFilename()).toBe(`query.${fmt}`);
      const fs = await import("node:fs");
      expect(check(fs.readFileSync((await d.path())!))).toBe(true);
    }

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

  test("Temizle: editör + sonuç boşalır, Ctrl+Z geri getirir; nesne paneli gizlenince editör genişler", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    const token = await api_token(request, u.email, u.password);
    await create_connection(request, token);
    await login(page, u.email, u.password);
    await page.goto("#/query");
    await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 10_000 });
    await type_sql(page, "SELECT 3 AS uc");
    await page.getByRole("button", { name: "Çalıştır" }).click();
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["uc"], { timeout: 10_000 });

    await page.getByRole("button", { name: "Temizle" }).click();
    await expect(page.locator(".cm-content")).toHaveText("");
    await expect(page.getByText("Sorgu çalıştırıldığında sonuçlar burada görünecek.")).toBeVisible();
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+Z");
    await expect(page.locator(".cm-content")).toContainText("SELECT 3 AS uc");

    const editor = page.locator(".cm-editor");
    const before = (await editor.boundingBox())!.width;
    await page.getByRole("button", { name: "Gizle" }).click();
    await expect.poll(async () => (await editor.boundingBox())!.width).toBeGreaterThan(before + 150);
    await page.getByRole("button", { name: "Nesneleri göster" }).click();
    await expect.poll(async () => (await editor.boundingBox())!.width).toBeLessThan(before + 10);
  });
});
