-- Hafif SVG grafikler — harici kütüphane yok, sadece DOM + inline SVG
-- Türler: bar (yatay/dikey), line/area (timescale), donut, sparkline
local dom = require("dom")

local chart = {}

local function max_of(arr)
  local m = 0
  for _, v in ipairs(arr) do if v > m then m = v end end
  return m > 0 and m or 1
end

-- Basit dikey bar grafik (by_action için)
function chart.bar(opts)
  opts = opts or {}
  local values = opts.values or {}
  local labels = opts.labels or {}
  local n = #values
  if n == 0 then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)] text-center" }, "Veri yok")
  end
  local W, H = opts.width or 320, opts.height or 140
  local padL, padR, padT, padB = 32, 8, 8, 28
  local innerW, innerH = W - padL - padR, H - padT - padB
  local maxV = opts.max or max_of(values)
  local bw = innerW / n * 0.64
  local gap = innerW / n * 0.36
  local colors = opts.colors or { "#6366f1", "#06b6d4", "#8b5cf6", "#f59e0b", "#10b981", "#ef4444", "#ec4899" }

  local bars = {}
  for i, v in ipairs(values) do
    local h = (v / maxV) * (innerH - 4)
    local x = padL + (i - 1) * (bw + gap) + gap/2
    local y = padT + innerH - h
    local c = colors[((i - 1) % #colors) + 1]
    bars[#bars+1] = dom.h("g", { key = "bar-"..i },
      dom.h("rect", {
        x = tostring(x), y = tostring(y), width = tostring(bw), height = tostring(h),
        rx = "3", ry = "3", fill = c, opacity = "0.92",
        title = (labels[i] or "") .. ": " .. tostring(v)
      }),
      dom.h("text", {
        x = tostring(x + bw/2), y = tostring(padT + innerH + 14),
        ["text-anchor"] = "middle", ["font-size"] = "10", fill = "var(--fg-muted)",
      }, (labels[i] or ""):sub(1,10))
    )
  end
  -- y ekseni çizgileri
  local grid = {}
  for j=0,3 do
    local yy = padT + innerH * j/3
    grid[#grid+1] = dom.h("line", {
      x1 = tostring(padL), y1 = tostring(yy), x2 = tostring(W-padR), y2 = tostring(yy),
      stroke = "var(--border)", ["stroke-width"] = j==3 and "1" or "0.5", ["stroke-dasharray"] = j<3 and "3 3" or nil, opacity = "0.5"
    })
  end
  return dom.div({ class = "overflow-x-auto" },
    dom.h("svg", {
      viewBox = "0 0 "..W.." "..H, width = tostring(W), height = tostring(H),
      role = "img", ["aria-label"] = opts.title or "Bar grafik",
      class = "w-full max-w-full"
    },
      dom.h("rect", { x="0", y="0", width=tostring(W), height=tostring(H), rx="8", fill="transparent" }),
      grid,
      bars
    ))
end

-- Zaman serisi alan grafiği (by_day için) – timescale
function chart.area(opts)
  opts = opts or {}
  local values = opts.values or {}
  local labels = opts.labels or {}
  local n = #values
  if n == 0 then
    return dom.div({ class = "p-4 text-sm text-[var(--fg-muted)] text-center" }, "Veri yok")
  end
  local W, H = opts.width or 360, opts.height or 120
  local padL, padR, padT, padB = 28, 8, 12, 24
  local innerW, innerH = W - padL - padR, H - padT - padB
  local maxV = math.max(max_of(values) * 1.1, 1)
  local minV = 0
  local stepX = n > 1 and innerW / (n - 1) or innerW
  local points, areaPoints = {}, {}
  for i, v in ipairs(values) do
    local x = padL + (i-1)*stepX
    local y = padT + innerH - ((v - minV)/(maxV - minV))*innerH
    points[#points+1] = string.format("%.1f,%.1f", x, y)
    areaPoints[#areaPoints+1] = {x=x, y=y}
  end
  local lineD = "M " .. table.concat(points, " L ")
  local areaD = lineD .. " L " .. string.format("%.1f,%.1f", padL + (n-1)*stepX, padT+innerH)
    .. " L " .. string.format("%.1f,%.1f", padL, padT+innerH) .. " Z"
  local gradId = "grad-" .. tostring(math.random(100000))
  local dots = {}
  for i, p in ipairs(areaPoints) do
    dots[#dots+1] = dom.h("circle", {
      cx = tostring(p.x), cy = tostring(p.y), r = n < 20 and "3" or "2",
      fill = opts.color or "#6366f1", stroke = "white", ["stroke-width"]="1.5",
      title = (labels[i] or "") .. ": " .. tostring(values[i])
    })
  end
  local xLabels = {}
  local step = math.max(1, math.floor(n/6))
  for i=1,n,step do
    local lb = labels[i] or ""
    -- sadece MM-DD göster
    if #lb >= 10 then lb = lb:sub(6,10) end
    xLabels[#xLabels+1] = dom.h("text", {
      x = tostring(padL + (i-1)*stepX), y = tostring(H - 6),
      ["text-anchor"] = "middle", ["font-size"]="9", fill="var(--fg-muted)"
    }, lb)
  end
  return dom.div({ class = "overflow-hidden" },
    dom.h("svg", {
      viewBox="0 0 "..W.." "..H, width=tostring(W), height=tostring(H),
      role="img", ["aria-label"]=opts.title or "Zaman serisi",
      class="w-full"
    },
      dom.h("defs", {},
        dom.h("linearGradient", { id=gradId, x1="0", y1="0", x2="0", y2="1" },
          dom.h("stop", { offset="0%", ["stop-color"]=opts.color or "#6366f1", ["stop-opacity"]="0.35" }),
          dom.h("stop", { offset="100%", ["stop-color"]=opts.color or "#6366f1", ["stop-opacity"]="0.02" })
        )
      ),
      dom.h("rect", { x="0", y="0", width=tostring(W), height=tostring(H), rx="8", fill="transparent" }),
      -- grid
      dom.h("line", { x1=tostring(padL), y1=tostring(padT), x2=tostring(padL), y2=tostring(padT+innerH), stroke="var(--border)", ["stroke-width"]="0.7" }),
      dom.h("line", { x1=tostring(padL), y1=tostring(padT+innerH), x2=tostring(W-padR), y2=tostring(padT+innerH), stroke="var(--border)", ["stroke-width"]="0.7" }),
      dom.h("path", { d=areaD, fill="url(#"..gradId..")", stroke="none" }),
      dom.h("path", { d=lineD, fill="none", stroke=opts.color or "#6366f1", ["stroke-width"]="2.2", ["stroke-linecap"]="round", ["stroke-linejoin"]="round" }),
      dots,
      xLabels
    ))
end

-- Yatay bar (top users için) – daha okunabilir
function chart.hbar(opts)
  opts = opts or {}
  local labels = opts.labels or {}
  local values = opts.values or {}
  local n = #values
  if n == 0 then return dom.div({ class="p-2 text-sm text-[var(--fg-muted)]" }, "Veri yok") end
  local maxV = max_of(values)
  local rows = {}
  local colors = { "#6366f1", "#06b6d4", "#8b5cf6", "#f59e0b", "#10b981" }
  for i=1,n do
    local pct = maxV > 0 and (values[i]/maxV*100) or 0
    local c = colors[((i-1) % #colors)+1]
    rows[#rows+1] = dom.div({ key="hbar-"..i, class="flex items-center gap-2 text-xs" },
      dom.div({ class="w-28 truncate text-right text-[var(--fg-muted)]", title=labels[i] }, labels[i]),
      dom.div({ class="flex-1 h-2 bg-[var(--border)] rounded-full overflow-hidden" },
        dom.div({ class="h-full rounded-full", style="width:"..string.format("%.1f", pct).."%; background:"..c }) ),
      dom.div({ class="w-8 text-[var(--fg)] font-medium" }, tostring(values[i]))
    )
  end
  return dom.div({ class="space-y-2" }, rows)
end

-- Donut (by_status için)
function chart.donut(opts)
  opts = opts or {}
  local segments = opts.segments or {}
  local total = 0
  for _, s in ipairs(segments) do total = total + (s.value or 0) end
  if total == 0 then return dom.div({ class="p-4 text-sm text-[var(--fg-muted)] text-center" }, "Veri yok") end
  local W, H = 140, 140
  local cx, cy, r, inner = 70, 70, 58, 38
  local start = -90
  local paths = {}
  for i, seg in ipairs(segments) do
    local pct = seg.value / total
    local angle = pct * 360
    local endAngle = start + angle
    local large = angle > 180 and 1 or 0
    local rad = math.pi/180
    local x1, y1 = cx + r*math.cos(start*rad), cy + r*math.sin(start*rad)
    local x2, y2 = cx + r*math.cos(endAngle*rad), cy + r*math.sin(endAngle*rad)
    local ix1, iy1 = cx + inner*math.cos(endAngle*rad), cy + inner*math.sin(endAngle*rad)
    local ix2, iy2 = cx + inner*math.cos(start*rad), cy + inner*math.sin(start*rad)
    local d = string.format("M %.2f,%.2f A %d,%d 0 %d,1 %.2f,%.2f L %.2f,%.2f A %d,%d 0 %d,0 %.2f,%.2f Z",
      x1,y1, r,r, large, x2,y2, ix1,iy1, inner,inner, large, ix2,iy2)
    paths[#paths+1] = dom.h("path", { d=d, fill=seg.color or "#6366f1", stroke="white", ["stroke-width"]="2", title=seg.label..": "..seg.value })
    start = endAngle
  end
  local legend = {}
  for i, seg in ipairs(segments) do
    legend[#legend+1] = dom.div({ class="flex items-center gap-1.5 text-xs" },
      dom.span({ class="w-3 h-3 rounded-sm", style="background:"..(seg.color or "#6366f1") }),
      dom.span({ class="text-[var(--fg-muted)]" }, seg.label),
      dom.span({ class="font-semibold" }, tostring(seg.value))
    )
  end
  return dom.div({ class="flex items-center gap-4" },
    dom.h("svg", { viewBox="0 0 "..W.." "..H, width=tostring(W), height=tostring(H), role="img", ["aria-label"]=opts.title or "Donut" },
      dom.h("circle", { cx=tostring(cx), cy=tostring(cy), r=tostring(r+1), fill="transparent", stroke="var(--border)", ["stroke-width"]="1", opacity="0.3" }),
      paths,
      dom.h("circle", { cx=tostring(cx), cy=tostring(cy), r=tostring(inner-1), fill="var(--bg-elev)" }),
      dom.h("text", { x=tostring(cx), y=tostring(cy-2), ["text-anchor"]="middle", ["font-size"]="16", ["font-weight"]="700", fill="var(--fg)" }, tostring(total)),
      dom.h("text", { x=tostring(cx), y=tostring(cy+12), ["text-anchor"]="middle", ["font-size"]="9", fill="var(--fg-muted)" }, "toplam")
    ),
    dom.div({ class="space-y-1.5" }, legend)
  )
end

-- Sparkline (küçük, canlı istek için)
function chart.sparkline(values, opts)
  opts = opts or {}
  local n = #values
  if n < 2 then return dom.span({ class="text-xs text-[var(--fg-muted)]" }, "—") end
  local W, H = opts.width or 80, opts.height or 24
  local maxV, minV = max_of(values), math.huge
  for _, v in ipairs(values) do if v < minV then minV = v end end
  if minV == math.huge then minV = 0 end
  local range = maxV - minV
  if range == 0 then range = 1 end
  local step = W / (n-1)
  local pts = {}
  for i, v in ipairs(values) do
    local x = (i-1)*step
    local y = H - ((v - minV)/range)*(H-4) -2
    pts[#pts+1] = string.format("%.1f,%.1f", x, y)
  end
  local d = "M " .. table.concat(pts, " L ")
  return dom.h("svg", { viewBox="0 0 "..W.." "..H, width=tostring(W), height=tostring(H), class="overflow-visible" },
    dom.h("path", { d=d, fill="none", stroke=opts.color or "#22c55e", ["stroke-width"]="1.8", ["stroke-linecap"]="round", ["stroke-linejoin"]="round" })
  )
end

return chart
