import { test, expect } from "@playwright/test";
import { wait_for_app, login, logout, create_user, ADMIN } from "./helpers";

test.describe("auth", () => {
  test("admin girişi başarılı", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await page.goto("#/login");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(adm.email);
    await page.getByLabel("Parola", { exact: true }).fill(adm.password);
    await page.getByRole("button", { name: "Giriş yap" }).click();
    await expect(page).toHaveURL(/#\/$/, { timeout: 15_000 });
  });

  test("hatalı parola: e-posta varlığı ifşa edilmez", async ({ page, request }) => {
    const u = await create_user(request);
    await page.goto("#/login");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(u.email);
    await page.getByLabel("Parola", { exact: true }).fill("yanlis-parola-1A");
    await page.getByRole("button", { name: "Giriş yap" }).click();
    await expect(page.getByRole("alert").filter({ hasText: "E-posta veya parola hatalı" })).toBeVisible({ timeout: 10_000 });
  });

  test("oturum yenilemede korunur", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.reload();
    await wait_for_app(page);
    await expect(page).not.toHaveURL(/#\/login/);
  });

  test("logout sonrası korumalı sayfaya girilemez (geri tuşu dahil)", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await logout(page);
    await page.goBack();
    await expect(page).toHaveURL(/#\/login/);
    await page.goto("#/connections");
    await expect(page).toHaveURL(/#\/login\?next=/);
  });

  test("next parametresi: girişten sonra hedef sayfaya, harici URL'ye asla", async ({ page, request }) => {
    const u = await create_user(request);
    await page.goto("#/login?next=%23%2Fconnections");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(u.email);
    await page.getByLabel("Parola", { exact: true }).fill(u.password);
    await page.getByRole("button", { name: "Giriş yap" }).click();
    await expect(page).toHaveURL(/#\/connections$/);
  });

  test("demo hesap kutusu alanları doldurur (dev build)", async ({ page }) => {
    await page.goto("#/login");
    await wait_for_app(page);
    const demo = page.getByRole("button", { name: /Yönetici|Kullanıcı hesabıyla doldur/ });
    test.skip(await demo.count() === 0, "production build: demo kutusu yok");
    await demo.first().click();
    await expect(page.getByLabel("E-posta")).not.toHaveValue("");
  });

  test("editor menüsünde admin öğeleri görünmez", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await expect(page.getByRole("link", { name: "Kullanıcılar" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Yetkiler" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Denetim" })).toHaveCount(0);
  });
});
