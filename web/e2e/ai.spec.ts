// Faz 4: AI ile SQL. Ayar global olduğundan testler seri koşar ve önceki durumu geri yükler.
// Gerçek sağlayıcı testleri yalnızca repo kökünde api-key.txt varsa çalışır (anahtar asla loglanmaz).
import { test, expect, Page, APIRequestContext } from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import { login, ADMIN, API, api_token, create_user } from "./helpers";

test.describe.configure({ mode: "serial" });

const KEY_FILE = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../api-key.txt");
const hasKey = fs.existsSync(KEY_FILE);
const MODEL = "openai/gpt-oss-20b";

async function admin(request: APIRequestContext) {
  const token = await api_token(request, ADMIN.email, ADMIN.password);
  const H = { Authorization: `Bearer ${token}` };
  const get = async () => (await (await request.get(`${API}/admin/ai/settings`, { headers: H })).json()).data;
  const put = async (data: object) => {
    const r = await request.put(`${API}/admin/ai/settings`, { headers: H, data });
    expect(r.status(), await r.text()).toBe(200);
    return (await r.json()).data;
  };
  return { get, put };
}

async function open_query(page: Page, request: APIRequestContext) {
  const token = await api_token(request, ADMIN.email, ADMIN.password);
  const res = await request.post(`${API}/connections`, { headers: { Authorization: `Bearer ${token}` },
    data: { name: `e2e-ai-${Date.now()}`, host: "postgres", port: 5432, database: "pgeditor", username: "pgeditor",
      password: "pgeditor", save_password: true, ssl_mode: "disable" } });
  expect(res.status()).toBe(201);
  const id = (await res.json()).data.id;
  await login(page, ADMIN.email, ADMIN.password);
  await page.goto(`#/query?connection_id=${id}`);
  await expect(page.locator(".cm-editor")).toBeVisible({ timeout: 15_000 });
  return async () => request.delete(`${API}/connections/${id}`, { headers: { Authorization: `Bearer ${token}` } });
}

test("AI kapalıyken sorgu ekranında AI bileşeni yok; açıkken var; editör ayar kartını görmez", async ({ page, request }) => {
  const a = await admin(request);
  const before = (await a.get()).enabled;
  await a.put({ enabled: false });
  const cleanup = await open_query(page, request);
  try {
    await expect(page.getByRole("button", { name: "Çalıştır" })).toBeVisible();
    await expect(page.getByRole("button", { name: "AI ile oluştur" })).toHaveCount(0);
    await page.keyboard.press("Control+i");
    await expect(page.getByRole("region", { name: "AI ile SQL" })).toHaveCount(0);

    await a.put({ enabled: true });
    await page.reload();
    await expect(page.getByRole("button", { name: "AI ile oluştur" })).toBeVisible({ timeout: 15_000 });
    await page.locator(".cm-content").click();
    await page.keyboard.press("Control+i");
    await expect(page.getByRole("region", { name: "AI ile SQL" })).toBeVisible();

    // editör: yönetici API'si yasak, ayarlar sayfasında AI kartı yok
    const u = await create_user(request, "editor");
    const et = await api_token(request, u.email, u.password);
    expect((await request.get(`${API}/admin/ai/settings`, { headers: { Authorization: `Bearer ${et}` } })).status()).toBe(403);
    const ctx = await page.context().browser()!.newContext({ baseURL: test.info().project.use.baseURL });
    const p2 = await ctx.newPage();
    await login(p2, u.email, u.password);
    // Ayarlar menüden erişilebilir (herkese açık)
    await p2.getByRole("navigation", { name: "Sayfalar" }).getByRole("link", { name: "Ayarlar" }).click();
    await expect(p2).toHaveURL(/#\/settings/);
    await expect(p2.getByRole("heading", { name: "Ayarlar", exact: true })).toBeVisible();
    await expect(p2.getByRole("heading", { name: "Yapay Zekâ ile SQL" })).toHaveCount(0);
    await ctx.close();
  } finally {
    await a.put({ enabled: before });
    await cleanup();
  }
});

test("yönetici ayarları: anahtar maskeli, model tablosu, tek model testi, görünür yap", async ({ page, request }) => {
  test.skip(!hasKey, "api-key.txt yok");
  test.setTimeout(120_000);
  const key = fs.readFileSync(KEY_FILE, "utf8").trim();
  const a = await admin(request);
  const before = await a.get();
  if (!before.has_key) await a.put({ api_key: key });
  try {
    await login(page, ADMIN.email, ADMIN.password);
    await page.getByRole("navigation", { name: "Sayfalar" }).getByRole("link", { name: "Ayarlar" }).click();
    const card = page.getByRole("region", { name: "Yapay Zekâ ile SQL" });
    await expect(card).toBeVisible({ timeout: 15_000 });
    // anahtar sayfada asla düz metin görünmez
    await expect(card.getByLabel("API anahtarı", { exact: true })).toHaveAttribute("placeholder", /^kayıtlı …/);
    expect(await page.content()).not.toContain(key);
    await card.getByRole("button", { name: "Modelleri yenile" }).click();
    await card.getByLabel("Model ara").fill(MODEL);
    await expect(card.getByRole("row", { name: new RegExp(MODEL) })).toBeVisible({ timeout: 30_000 });
    await card.getByRole("button", { name: `${MODEL} test et` }).click();
    await expect(card.getByRole("row", { name: new RegExp(MODEL) }).locator(".badge-completed"))
      .toBeVisible({ timeout: 60_000 });
    const cb = card.getByLabel(`${MODEL} sorgu ekranında göster`);
    if (!(await cb.isChecked())) await cb.check();
    await expect(card.getByLabel("Varsayılan model").locator("option", { hasText: MODEL })).toHaveCount(1, { timeout: 10_000 });
  } finally {
    await a.put({ enabled: before.enabled });
  }
});

test("sorgu ekranı: gerçek sağlayıcı ile SQL üret, sorguyu güncelle, Ctrl+Z geri alır", async ({ page, request }) => {
  test.skip(!hasKey, "api-key.txt yok");
  test.setTimeout(300_000);
  const a = await admin(request);
  const before = await a.get();
  const visible = before.models.filter((m: { visible: boolean }) => m.visible).map((m: { id: string }) => m.id);
  await a.put({ enabled: true, visible: Array.from(new Set([...visible, MODEL])) });
  const cleanup = await open_query(page, request);
  const content = page.locator(".cm-content");
  try {
    await page.getByRole("button", { name: "AI ile oluştur" }).click();
    const bar = page.getByRole("region", { name: "AI ile SQL" });
    await bar.getByLabel("AI modeli").selectOption(MODEL);
    await bar.getByLabel("AI isteği").fill("users tablosundaki aktif kullanıcıların e-posta adresleri, alfabetik");
    await bar.getByRole("button", { name: "Oluştur" }).click();
    await expect(bar.getByText("AI yazıyor…")).toBeVisible();
    await expect(content).toContainText(/select/i, { timeout: 120_000 });
    await expect(content).toContainText("users");
    await expect(content).not.toContainText(/limit\s+5/i);

    // seçim yokken "Sorguyu güncelle": tüm sekme değişir; Ctrl+Z eski metne döner
    await bar.getByLabel("AI isteği").fill("sonucu en fazla 5 satırla sınırla (LIMIT 5)");
    await bar.getByRole("button", { name: "Sorguyu güncelle" }).click();
    await expect(content).toContainText(/limit\s+5/i, { timeout: 120_000 });
    await content.click();
    await page.keyboard.press("ControlOrMeta+Z");
    await expect(content).not.toContainText(/limit\s+5/i, { timeout: 5_000 });
    await expect(content).toContainText("users");
  } finally {
    await a.put({ enabled: before.enabled, visible });
    await cleanup();
  }
});
