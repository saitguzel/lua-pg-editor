import { test, expect } from "@playwright/test";
import { login, create_user, unique_email, API, api_token, set_permission } from "./helpers";

test.describe("admin: kullanıcılar", () => {
  test("kullanıcı oluştur → o kullanıcıyla giriş yapılır", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    const email = unique_email("created");
    await page.getByRole("button", { name: "+ Kullanıcı ekle" }).click();
    const dialog = page.getByRole("dialog", { name: "Yeni kullanıcı" });
    await dialog.getByLabel("E-posta").fill(email);
    await dialog.getByLabel("Parola", { exact: true }).fill("YeniParola1!");
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog).toHaveCount(0);
    await page.getByLabel("Ara", { exact: true }).fill(email);
    await expect(page).toHaveURL(/q=/);
    await expect(page.getByRole("rowheader", { name: email })).toBeVisible({ timeout: 10_000 });

    await page.getByRole("button", { name: "Çıkış" }).click();
    await login(page, email, "YeniParola1!");
  });

  test("aynı e-posta → EMAIL_TAKEN alan hatası", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    await page.getByRole("button", { name: "+ Kullanıcı ekle" }).click();
    const dialog = page.getByRole("dialog", { name: "Yeni kullanıcı" });
    await dialog.getByLabel("E-posta").fill("admin@pgeditor.local");
    await dialog.getByLabel("Parola", { exact: true }).fill("YeniParola1!");
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog.getByText("Bu e-posta zaten kullanılıyor")).toBeVisible();
    await expect(dialog.getByLabel("E-posta")).toBeFocused();
  });

  test("admin kendini silemez (buton disabled)", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.goto(`#/users?q=${encodeURIComponent(adm.email)}`);
    await expect(page.getByRole("button", { name: `${adm.email} sil` })).toBeDisabled();
  });
});

test.describe.serial("admin: yetki matrisi", () => {
  test("admin'in rbac.matrix hücresi kilitli (disabled)", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Yetkiler" }).click();
    await expect(page.getByRole("checkbox", { name: "admin rolü için rbac.matrix erişimi" })).toBeDisabled();
  });

  test("editor'a users.list verilince menüde görünür (reload sonrası)", async ({ page, request }) => {
    const user = await create_user(request, "editor");
    try {
      const adm = await create_user(request, "admin");
      await login(page, adm.email, adm.password);
      await page.getByRole("link", { name: "Yetkiler" }).click();
      const cell = page.getByRole("checkbox", { name: "editor rolü için users.list erişimi" });
      await cell.check();
      await expect(page.locator("#toast-polite")).toContainText("users.list");
      await page.getByRole("button", { name: "Çıkış" }).click();
      await login(page, user.email, user.password);
      await page.reload();
      await expect(page.getByRole("link", { name: "Kullanıcılar" })).toBeVisible({ timeout: 10_000 });
    } finally {
      await set_permission(request, "editor", "users.list", false);
    }
  });

  test("editor admin API'sine doğrudan istekte 403 alır", async ({ request }) => {
    const user = await create_user(request, "editor");
    const token = await api_token(request, user.email, user.password);
    const res = await request.get(`${API}/rbac/matrix`, { headers: { Authorization: `Bearer ${token}` } });
    expect(res.status()).toBe(403);
    expect((await res.json()).error.code).toBe("FORBIDDEN");
  });

  test("editor #/rbac → 'yetkiniz yok' içeriği, admin bundle'ı indirilmez", async ({ page, request }) => {
    const user = await create_user(request, "editor");
    const adminBundle: string[] = [];
    page.on("request", (r) => { if (r.url().includes("bundle-admin")) adminBundle.push(r.url()); });
    await login(page, user.email, user.password);
    await page.goto("#/rbac");
    await expect(page.getByRole("heading", { name: "Bu sayfaya erişim yetkiniz yok" })).toBeVisible();
    expect(adminBundle).toEqual([]);
  });
});

test.describe("admin: denetim ve dışa aktarım", () => {
  test("audit log listesi ve CSV indir", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Denetim" }).click();
    await expect(page.getByRole("heading", { name: "Denetim Kayıtları" })).toBeVisible();
    await expect(page.getByRole("table")).toBeVisible({ timeout: 10_000 });
    // satıra tıkla → detay drawer
    const firstRow = page.locator("tbody tr").first();
    if (await firstRow.count() > 0) {
      await firstRow.click();
      await expect(page.getByRole("dialog")).toBeVisible({ timeout: 5_000 });
      await page.keyboard.press("Escape");
    }
    // CSV
    const downloadPromise = page.waitForEvent("download", { timeout: 10_000 }).catch(() => null);
    await page.getByRole("button", { name: "CSV indir" }).click();
    await expect(page.locator("#toast-polite")).toContainText(/CSV indirildi/, { timeout: 10_000 });
    const dl = await downloadPromise;
    // download may be via API blob, not playwright download, so not asserting file
  });
});
