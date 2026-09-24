# ═══ FAZ 21 — FRONTEND UX POLISH ═══

> Kanonik: [00-genel-bakis.md](00-genel-bakis.md) — erişilebilirlik, tema.

## Amaç

Üretim kalitesi: tema, klavye, erişilebilirlik, boş/hatalar, skeletons, toast, command palette, focus yönetimi.

## Çıktılar

| Yol | Güncelleme |
|---|---|
| `web/public/styles.css` | dark/light değişkenleri, reduced-motion, focus, skeleton |
| `web/src/components/modal.lua` | `<dialog>` + focus trap + Esc |
| `web/src/components/toast.lua` | queue, deduplicate, aria-live |
| `web/src/views/*` | empty state, error state, skeleton |
| `web/src/keyboard.lua` | global shortcuts |

## Tema

- `localStorage "pg.theme"`: `light|dark|system`. `system` → `matchMedia("(prefers-color-scheme: dark)")` listener ile `documentElement.dataset.theme`.
- FOUC yok: `boot.js` zaten tema uygular; F21'de geçiş animasyonu `transition: background .2s`.
- `prefers-reduced-motion` → skeleton shimmer ve confetti kapalı.

## Klavye

| Kısayol | Eylem |
|---|---|
| `Ctrl/Cmd+Enter` | Sorgu çalıştır (editör odaklı) |
| `Ctrl/Cmd+K` | Command palette: bağlantı değiştir, tablo ara |
| `Ctrl/Cmd+B` | Sidebar toggle |
| `?` | Kısayol listesi modal |
| `Esc` | Modal kapat |
| `g d` | Dashboard |
| `g c` | Connections |
| `g q` | Query |

`keyboard.lua` → `js.keyboard.onKey(fn)` → `typing` flag (input'da `g` tetiklenmez).

## Erişilebilirlik (a11y)

- `skip-link` (`#main`).
- Modal `<dialog>` native: `showModal()` → focus trap + `inert` arka plan.
- Focus iadesi: dialog kapanınca `document.activeElement` → trigger button.
- `aria-live="polite"` toast root, `role="alert"` boot error.
- Renk kontrast WCAG AA ≥4.5:1 (light/dark fg/bg).
- `prefers-reduced-motion` → animasyon yok.

## Empty / Error / Skeleton

- Empty: `No connections yet` + CTA "Bağlantı ekle" + illustration.
- Error: `CONNECTION_FAILED` → "Bağlantı kurulamadı" + retry butonu.
- Skeleton: grid shimmer card'lar, `aria-busy`.

## Toast

- Queue: aynı mesaj 3 sn içinde tekrar → `count` badge artar, yeni toast eklenmez.
- Seviyeler: `success` (yeşil), `error` (kırmızı), `info` (mavi), auto-dismiss 5s, hover pause.

## Command Palette

`Ctrl+K` → modal: input + sonuç listesi (connections, tables). `js.dom.focusFirst("[data-command]")`.

## DoD

- [ ] Tema system → OS dark → dark, light → light, değişim anında.
- [ ] `prefers-reduced-motion` açık → skeleton animasyon yok.
- [ ] `Ctrl+Enter` editörde çalışır, input'da çalışmaz.
- [ ] Modal Esc ile kapanır, focus trigger'a döner.
- [ ] Lighthouse a11y ≥95, contrast hatası yok.
- [ ] Empty state'te CTA görünür.
