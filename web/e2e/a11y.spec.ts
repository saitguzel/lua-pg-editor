import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { wait_for_app, login, create_user } from "./helpers";

const pages: Array<{ name: string; hash: string; admin?: boolean }> = [
  { name: "login", hash: "#/login" },
  { name: "dashboard", hash: "#/" },
  { name: "connections", hash: "#/connections" },
  { name: "query", hash: "#/query" },
  { name: "browse", hash: "#/browse/public/customers" },
  { name: "structure", hash: "#/structure/public/customers" },
  { name: "profile", hash: "#/profile" },
  { name: "users", hash: "#/users", admin: true },
  { name: "rbac", hash: "#/rbac", admin: true },
  { name: "audit", hash: "#/audit", admin: true },
];

for (const theme of ["light", "dark"]) {
  test.describe(`a11y (${theme})`, () => {
    test.use({ colorScheme: theme === "dark" ? "dark" : "light" });

    for (const p of pages) {
      test(`${p.name}: 0 serious/critical ihlal`, async ({ page, request }) => {
        if (p.hash !== "#/login") {
          const u = await create_user(request, p.admin ? "admin" : "editor");
          await login(page, u.email, u.password);
        }
        await page.goto(p.hash);
        await wait_for_app(page);
        // bekle skeleton gitsin
        await page.locator("[aria-busy='true']").first().waitFor({ state: "detached", timeout: 5000 }).catch(() => {});
        const results = await new AxeBuilder({ page })
          .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
          .analyze();
        const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
        expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
      });
    }
  });
}

test.describe("a11y keyboard", () => {
  test("skip-link ve odak yönetimi", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await wait_for_app(page);
    // hash geçişi sayfayı yeniden yüklemez; odağı belge başına sıfırla (Tab skip-link'ten başlamalı)
    // skip-link belgedeki ilk odaklanabilir öğe: ilk menü bağlantısından Shift+Tab ile ona gelinir
    // (uygulama sayfa değişiminde odağı başlığa taşıdığı için blur+Tab başlangıcı başlıktan sürdürür)
    await page.getByRole("link", { name: "Pano" }).focus();
    await page.keyboard.press("Shift+Tab");
    const skip = page.getByRole("link", { name: "İçeriğe atla" });
    await expect(skip).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator("#main")).toBeFocused();
  });

  test("modal focus trap ve Esc ile kapanma", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await page.getByRole("button", { name: "+ Yeni bağlantı" }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    // focus first input
    await expect(page.getByLabel("Bağlantı adı")).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
    // focus trigger'a döner (Yeni bağlantı butonu)
    await expect(page.getByRole("button", { name: "+ Yeni bağlantı" })).toBeFocused();
  });
});
