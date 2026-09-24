import { test, expect } from "@playwright/test";
import { wait_for_app, login, create_user } from "./helpers";

test.describe("keyboard", () => {
  test("Ctrl+K komut paleti açar, Esc kapatır", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await page.keyboard.press("Control+k");
    await expect(page.getByRole("dialog", { name: "Komut paleti" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog", { name: "Komut paleti" })).toHaveCount(0);
  });

  test("Ctrl+B sidebar toggle", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    const sidebar = page.locator("#sidebar");
    await expect(sidebar).toHaveAttribute("data-collapsed", "false");
    const wide = (await sidebar.boundingBox())!.width;
    const main = page.locator("#main");
    const mainWide = (await main.boundingBox())!.width;
    await page.keyboard.press("Control+b");
    // masaüstünde rail: ikonlar görünür kalır, ana alan genişler
    await expect(sidebar).toHaveAttribute("data-collapsed", "true");
    await expect(sidebar).toBeVisible();
    await expect.poll(async () => (await sidebar.boundingBox())!.width).toBeLessThan(wide / 2);
    await expect.poll(async () => (await main.boundingBox())!.width).toBeGreaterThan(mainWide + 100);
    // tercih yenilemeden sonra korunur
    await page.reload();
    await expect(page.locator("#sidebar")).toHaveAttribute("data-collapsed", "true");
    await page.keyboard.press("Control+b");
    await expect(sidebar).toHaveAttribute("data-collapsed", "false");
  });

  test("g d / g c / g q navigasyon", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/query");
    await page.keyboard.press("g");
    await page.keyboard.press("c");
    await expect(page).toHaveURL(/#\/connections/);
    await page.keyboard.press("g");
    await page.keyboard.press("q");
    await expect(page).toHaveURL(/#\/query/);
    await page.keyboard.press("g");
    await page.keyboard.press("d");
    await expect(page).toHaveURL(/#\/$/);
  });

  test("? yardım modalı ve Esc", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await page.keyboard.press("?");
    const help = page.getByRole("dialog", { name: "Klavye kısayolları" });
    await expect(help).toBeVisible();
    await expect(help.getByText("Komut paleti")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(help).toHaveCount(0);
  });

  test("input içinde g tetiklenmez", async ({ page, request }) => {
    const u = await create_user(request, "editor");
    await login(page, u.email, u.password);
    await page.goto("#/connections");
    await wait_for_app(page);
    const search = page.getByPlaceholder("Ara (isim/host/db)…");
    await search.focus();
    await page.keyboard.type("g");
    await expect(page).not.toHaveURL(/#\/$/);
    await expect(search).toHaveValue("g");
  });
});
