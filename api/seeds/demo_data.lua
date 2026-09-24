-- demo_data: minimal demo verisi (pg-editor için hedef demo DB değil, meta demo)
-- Gerçek demo tablolari (customers/orders) hedef DB'de olusturulur; burada sadece placeholder.
return {
  name = "demo_data",
  enabled = function(env)
    return env.SEED_DEFAULTS == "true"
  end,
  run = function(q)
    -- minimal: demo baglanti yoktur, sadece log
    -- Ileride pg-editor_dev demo icin kullanilacak; simdilik bos
  end,
}
