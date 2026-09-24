import { test, expect } from "@playwright/test";
import { login, create_user, unique_name, API, api_token, wait_for_app } from "./helpers";

test.describe("connections", () => {
  test("oluştur → test et → düzenle → sil", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Bağlantılar", exact: true }).click();
    await wait_for_app(page);
    await expect(page.getByRole("heading", { name: /^Bağlantılar/ })).toBeVisible();

    const name = unique_name("conn-ui");
    await page.getByRole("button", { name: "+ Yeni bağlantı" }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.getByLabel("Bağlantı adı").fill(name);
    await page.getByLabel("Host", { exact: true }).fill("postgres");
    await page.getByLabel("Port", { exact: true }).fill("5432");
    await page.getByLabel("Veritabanı").fill("pgeditor");
    await page.getByLabel("Kullanıcı", { exact: true }).fill("pgeditor");
    await page.getByLabel("Parola", { exact: true }).fill("pgeditor");
    await page.getByRole("button", { name: "Oluştur" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByText(name)).toBeVisible({ timeout: 10_000 });

    // test et
    const row = page.locator("[data-id]", { hasText: name });
    await row.getByRole("button", { name: "Test et" }).click();
    await expect(page.locator("#toast-polite")).toContainText(/Başarılı|başarılı/, { timeout: 15_000 });

    // düzenle
    await row.getByRole("button", { name: "Düzenle" }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.getByLabel("Bağlantı adı").fill(name + "-edit");
    await page.getByRole("button", { name: "Kaydet" }).click();
    await expect(page.getByText(name + "-edit")).toBeVisible();

    // sil (onaylı)
    const editedRow = page.locator("[data-id]", { hasText: name + "-edit" });
    await editedRow.getByRole("button", { name: "Sil" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Sil", exact: true }).click();
    await expect(page.locator("[data-id]", { hasText: name + "-edit" })).toHaveCount(0);
  });

  test("API hatasında hata mesajı", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Bağlantılar", exact: true }).click();
    await wait_for_app(page);
    await page.route("**/api/v1/connections?*", (route) =>
      route.fulfill({ status: 500, body: JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "hata" } }) }));
    await page.reload();
    await expect(page.getByRole("alert").filter({ hasText: "Bağlantılar yüklenemedi" })).toBeVisible({ timeout: 10_000 });
  });

  test("filtreler URL'ye yansır; geri tuşu önceki filtreye döner", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await wait_for_app(page);
    const search = page.getByPlaceholder("Ara (isim/host/db)…");
    // type search
    await search.fill("pg");
    await expect(page).toHaveURL(/search=pg/, { timeout: 5_000 });
    await page.goBack();
    await expect(page).not.toHaveURL(/search=pg/);
  });

  test("başka kullanıcının bağlantısı görünmez (404)", async ({ page, request }) => {
    const other = await create_user(request, "editor");
    const token = await api_token(request, other.email, other.password);
    const res = await request.post(`${API}/connections`, {
      headers: { Authorization: `Bearer ${token}` },
      data: { name: unique_name("other-conn"), host: "postgres", port: 5432, database: "pgeditor", username: "pgeditor", password: "pgeditor" },
    });
    expect(res.ok()).toBeTruthy();
    const id = (await res.json()).data.id;

    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    // attempt to fetch other's connection via API directly should be 404
    const token2 = await api_token(request, u.email, u.password);
    const check = await request.get(`${API}/connections/${id}`, { headers: { Authorization: `Bearer ${token2}` } });
    expect(check.status()).toBe(404);
  });

  test("boş durum: filtre sonucu yoksa filtre temizle", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto(`#/connections?search=${encodeURIComponent("yok-" + Date.now())}`);
    await expect(page.getByRole("heading", { name: "Sonuç yok" })).toBeVisible({ timeout: 10_000 });
    await page.getByRole("button", { name: "Filtreyi temizle" }).click();
    await expect(page).toHaveURL(/#\/connections$/);
  });
});
