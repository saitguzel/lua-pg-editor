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
    await expect(page.locator("#toast-assertive")).toContainText(/Sorgu hatası|bulunamadı/i, { timeout: 15_000 });

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

  test("F27: yeniden adlandır, Ctrl+Shift+Enter yalnız seçim, yıkıcı onay, hata satırı, geçmişten çalıştır", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    const token = await api_token(request, u.email, u.password);
    await create_connection(request, token);
    await login(page, u.email, u.password);
    await page.goto("#/query");
    await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 10_000 });

    // sekme yeniden adlandırma: çift tık → prompt → yenilemede korunur
    await page.locator("button[data-tab='query']").first().dblclick();
    await page.getByLabel("Sekme adı").fill("Raporum");
    await page.getByRole("button", { name: "Kaydet" }).click();
    await expect(page.locator("button[data-tab='query']").first()).toHaveText(/Raporum/);
    await page.reload();
    await expect(page.locator("button[data-tab='query']").first()).toHaveText(/Raporum/, { timeout: 10_000 });

    // Ctrl+Shift+Enter: yalnız seçili satır çalışır (ikinci satır seçili → kolon "b")
    await type_sql(page, "SELECT 1 AS a;\nSELECT 2 AS b");
    await page.keyboard.press("End");
    await page.keyboard.press("Shift+Home");
    await page.keyboard.press("ControlOrMeta+Shift+Enter");
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["b"], { timeout: 10_000 });

    // yıkıcı onay: DROP → modal → İptal → çalışmaz
    await type_sql(page, "DROP TABLE yok_tablo_xyz");
    await page.getByRole("button", { name: "Çalıştır", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Yıkıcı sorgu" })).toBeVisible();
    await page.getByRole("button", { name: "İptal" }).click();
    await expect(page.getByRole("heading", { name: "Yıkıcı sorgu" })).toBeHidden();
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["b"]);

    // hata konumu: 2. satırdaki sözdizimi hatası → rozet "satır 2" ve editörde vurgu
    await type_sql(page, "SELECT 1\nFROMM t");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByRole("button", { name: "Hata konumu" })).toContainText(/satır 2/, { timeout: 10_000 });
    await expect(page.locator(".cm-error-line")).toHaveCount(1);

    // geçmişten tek tıkla çalıştır: popover → Çalıştır → sonuç
    await page.getByRole("button", { name: "Geçmiş" }).click();
    // en yeni kayıt hatalı sorgu; "SELECT 2 AS b" satırının kendi Çalıştır düğmesi
    const pop = page.getByRole("dialog", { name: "Geçmiş" });
    await pop.locator("li", { hasText: "SELECT 2 AS b" }).first().getByRole("button", { name: "Çalıştır" }).click();
    await expect(page.locator("table").last().locator("thead th")).toHaveText(["b"], { timeout: 10_000 });
  });

  test("F28: sayfalama ve export diyaloğu formata göre alan gösterir", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    const token = await api_token(request, u.email, u.password);
    await create_connection(request, token);
    await login(page, u.email, u.password);
    await page.goto("#/query");
    await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 10_000 });
    await type_sql(page, "SELECT g AS n FROM generate_series(1, 250) g");
    await page.keyboard.press("ControlOrMeta+Enter");
    await expect(page.getByText(/1–100 \/ 250 satır/)).toBeVisible({ timeout: 10_000 });
    await expect(page.locator("table").last().locator("tbody tr")).toHaveCount(100);
    await page.getByRole("button", { name: "Son sayfa" }).click();
    await expect(page.getByText(/201–250 \/ 250 satır/)).toBeVisible();
    await expect(page.locator("table").last().locator("tbody tr")).toHaveCount(50);

    await page.getByRole("button", { name: "Dışa aktar" }).click();
    await expect(page.getByLabel("Ayraç")).toBeVisible();
    await page.getByLabel("Format").selectOption("xlsx");
    await expect(page.getByLabel("Ayraç")).toHaveCount(0);
    await expect(page.getByLabel("Başlık satırı")).toBeVisible();
    await page.getByLabel("Format").selectOption("json");
    await expect(page.getByLabel("Başlık satırı")).toHaveCount(0);
    await page.keyboard.press("Escape");
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
