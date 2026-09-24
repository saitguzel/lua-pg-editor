-- F29: Görünmeyen özellikler için ipuçları — yardım modalı ("help"), pano kartı ("dash"), tarayıcı ("browse").
-- Statik liste; snippets_builtin ile aynı yaklaşım. next_tip(seen) görülmemiş ilk ipucunu döner.
local tips = {}

tips.TIPS = {
  { id = "ctx-sidebar", where = { help = true, dash = true },
    text = "Nesne gezgininde bir nesneye sağ tıklayın: SELECT, CREATE script, yeniden adlandır, drop." },
  { id = "ctx-grid", where = { help = true, dash = true },
    text = "Sonuç hücresine sağ tık: hücre/satır/kolon/tümünü TSV kopyalar; çift tık tam içeriği açar." },
  { id = "esc-cancel", where = { help = true, dash = true },
    text = "Uzun süren sorguyu Esc ile iptal edin (pg_cancel_backend)." },
  { id = "run-sel", where = { help = true, dash = true },
    text = "Sadece seçili SQL'i Ctrl+Shift+Enter ile çalıştırın." },
  { id = "tab-complete", where = { help = true },
    text = "Tab tamamlamayı kabul eder; öneri yoksa 4 boşluk ekler." },
  { id = "splitter", where = { help = true },
    text = "Panel ayırıcılarını sürükleyin ya da odaklayıp ok tuşlarıyla 16 px adımlarla taşıyın." },
  { id = "g-seq", where = { help = true, dash = true },
    text = "g d / g c / g q: Pano, Bağlantılar, Sorgu sayfalarına atlayın." },
  { id = "palette", where = { help = true, dash = true },
    text = "Ctrl+K paletinden bağlantı, tablo ve komutlara ulaşın." },
  { id = "tab-rename", where = { help = true, dash = true },
    text = "Sekme başlığına çift tıklayarak yeniden adlandırın." },
  { id = "dblclick-edit", where = { help = true, browse = true },
    text = "Tablo tarayıcıda hücreye çift tık düzenler; Delete odaklı satırı siler." },
  { id = "sidebar-hide", where = { help = true },
    text = "Ctrl+B kenar çubuğunu daraltır; nesne panelini bağlantı başına gizleyebilirsiniz." },
  { id = "clear-undo", where = { help = true },
    text = "Alt+L ekranı temizler, Ctrl+Z geri alır." },
}

-- where'e göre süzülmüş liste
function tips.for_where(where)
  local out = {}
  for _, t in ipairs(tips.TIPS) do
    if t.where[where] then out[#out + 1] = t end
  end
  return out
end

-- seen: görülen id listesi; where varsayılan "dash". Hepsi görüldüyse nil.
function tips.next_tip(seen, where)
  local seen_set = {}
  for _, id in ipairs(seen or {}) do seen_set[id] = true end
  for _, t in ipairs(tips.for_where(where or "dash")) do
    if not seen_set[t.id] then return t end
  end
  return nil
end

return tips
