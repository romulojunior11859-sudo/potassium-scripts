--[[
    MineBot - automacao de jogabilidade
    Jogo: PlaceId 79389059854988 (MineGame)

    Usa os mesmos eventos que o cliente do jogo dispara:
      HitBreakable(nodeId) + HarvestSwing  -> minerar
      MineTakeChest()                      -> coletar bau
      MineSellItems({keys})                -> vender
      MineEquipBest()                      -> equipar melhor

    Painel: RightShift
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")

local lp = Players.LocalPlayer

-- ---------------- acesso ----------------
-- vazia = qualquer um roda. preenchida = so quem esta na lista.
-- o UserId aparece em roblox.com/users/<id>/profile, ou no aviso de acesso negado.
local WHITELIST = {
    -- [123456789] = "meu alt",
}

do
    local id = lp.UserId
    if next(WHITELIST) ~= nil and not WHITELIST[id] then
        warn("[minebot] acesso negado - UserId " .. tostring(id))
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "minebot",
                Text = "acesso negado - UserId " .. tostring(id),
                Duration = 8,
            })
        end)
        return
    end
end

local okGS, GameState = pcall(function() return require(RS.Modules.GameState) end)
if not okGS or type(GameState) ~= "table" then
    warn("[minebot] nao consegui require do GameState - o jogo mudou de estrutura")
    return
end

local okInv, MineInventory = pcall(function() return require(RS.Modules.MineInventory) end)

-- ---------------- config ----------------
local cfg = {
    swingInterval = 0.12,  -- piso real do jogo (Melee.Config.SwingCooldown)
    jitter        = 0.18,  -- variacao aleatoria em volta do intervalo
    maxDist       = 16,    -- so bate em node a essa distancia ou menos
    walkToNode    = true,  -- anda ate o node quando esta longe
    faceNode      = true,  -- vira o personagem pro node antes de bater
    chestEvery    = 5,
    sellEvery     = 30,
    equipEvery    = 60,
    pickaxeEvery  = 20,
    sellKinds     = { Ore = true },  -- so minerio; bota Crate = true etc se quiser
    pauseEvery    = { 180, 420 },  -- a cada N swings, uma pausa curta
    pauseFor      = { 0.6, 2.2 },
}

local state = { mine = false, chest = false, sell = false, equip = false, pickaxe = false }
local stats = { swings = 0, sells = 0, chests = 0, picks = 0, started = os.clock() }

local okCfg,   MineConfig = pcall(function() return require(RS.Modules.MineConfig) end)
local okStock, MineStock  = pcall(function() return require(RS.Modules.MineStock) end)

-- ---------------- helpers ----------------
local function root()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
    local c = lp.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function myPlot()
    local world = workspace:FindFirstChild("MineWorld")
    local plots = world and world:FindFirstChild("Plots")
    if not plots then return nil end
    for _, p in ipairs(plots:GetChildren()) do
        if p:GetAttribute("OwnerUserId") == lp.UserId then return p end
    end
    return nil
end

local function nodeList()
    local p = myPlot()
    local folder = p and p:FindFirstChild("Nodes")
    if not folder then return {} end
    return folder:GetChildren()
end

local function pivotOf(inst)
    local ok, cf = pcall(function() return inst:GetPivot() end)
    if ok and cf then return cf.Position end
    if inst:IsA("BasePart") then return inst.Position end
    local part = inst:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function nearestNode()
    local r = root()
    if not r then return nil end
    local best, bestPos, bestDist
    for _, n in ipairs(nodeList()) do
        if n:GetAttribute("NodeId") then
            local pos = pivotOf(n)
            if pos then
                local d = (pos - r.Position).Magnitude
                if not bestDist or d < bestDist then
                    best, bestPos, bestDist = n, pos, d
                end
            end
        end
    end
    return best, bestPos, bestDist
end

local function face(pos)
    local r = root()
    if not r then return end
    local flat = Vector3.new(pos.X, r.Position.Y, pos.Z)
    if (flat - r.Position).Magnitude < 0.2 then return end
    r.CFrame = CFrame.lookAt(r.Position, flat)
end

local function mineData()
    local ok, data = pcall(GameState.GetData2)
    if not ok or type(data) ~= "table" then return nil end
    return type(data.MineGame) == "table" and data.MineGame or nil
end

local function send(...)
    local ok, err = pcall(GameState.SendEvent, ...)
    if not ok then warn("[minebot] SendEvent falhou: " .. tostring(err)) end
    return ok
end

-- ---------------- loops ----------------
local nextPause = math.random(cfg.pauseEvery[1], cfg.pauseEvery[2])

task.spawn(function()
    while true do
        local base = cfg.swingInterval
        local delta = (math.random() - 0.5) * 2 * cfg.jitter * base
        task.wait(math.max(0.05, base + delta))

        if state.mine then
            local node, pos, dist = nearestNode()
            if node and pos then
                if dist > cfg.maxDist then
                    local h = humanoid()
                    if cfg.walkToNode and h then h:MoveTo(pos) end
                else
                    if cfg.faceNode then face(pos) end
                    send("HitBreakable", node:GetAttribute("NodeId"))
                    send("HarvestSwing")
                    stats.swings += 1

                    nextPause -= 1
                    if nextPause <= 0 then
                        nextPause = math.random(cfg.pauseEvery[1], cfg.pauseEvery[2])
                        task.wait(cfg.pauseFor[1] + math.random() * (cfg.pauseFor[2] - cfg.pauseFor[1]))
                    end
                end
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(cfg.chestEvery)
        if state.chest then
            local d = mineData()
            if d and type(d.Chest) == "table" and next(d.Chest) ~= nil then
                if send("MineTakeChest") then stats.chests += 1 end
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(cfg.sellEvery)
        if state.sell then
            if not (okInv and type(MineInventory) == "table" and MineInventory.Collect) then
                warn("[minebot] MineInventory indisponivel - venda desligada")
                state.sell = false
            else
                local d = mineData()
                local ok, entries = pcall(MineInventory.Collect, d, "All", nil)
                if not ok then
                    warn("[minebot] Collect falhou: " .. tostring(entries))
                elseif type(entries) ~= "table" then
                    warn("[minebot] Collect nao devolveu tabela")
                else
                    -- as entradas usam Key/Kind maiusculos; o .key minusculo e do tile da UI
                    local keys = {}
                    for _, e in pairs(entries) do
                        if type(e) == "table" then
                            local key = e.Key or e.key
                            local kind = e.Kind or e.kind
                            if key and (cfg.sellKinds[kind] or next(cfg.sellKinds) == nil) then
                                keys[#keys + 1] = key
                            end
                        end
                    end
                    if #keys > 0 then
                        if send("MineSellItems", keys) then
                            stats.sells += #keys
                            print("[minebot] vendeu " .. #keys .. " item(ns)")
                        end
                    end
                end
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(cfg.equipEvery)
        if state.equip then send("MineEquipBest") end
    end
end)

-- compra de picareta: mesmas regras que o HUD usa pra habilitar o botao
-- (zona desbloqueada + estoque + dinheiro). Nao precisa estar perto de nada.
task.spawn(function()
    while true do
        task.wait(cfg.pickaxeEvery)
        if state.pickaxe then
            if not (okCfg and type(MineConfig) == "table" and type(MineConfig.Pickaxes) == "table") then
                warn("[minebot] MineConfig indisponivel - compra desligada")
                state.pickaxe = false
            else
                local ok, data = pcall(GameState.GetData2)
                local d = (ok and type(data) == "table") and data or nil
                local mine = d and type(d.MineGame) == "table" and d.MineGame or nil

                if mine then
                    local money = tonumber(d.Money) or 0
                    local unlocked = mine.UnlockedZones or {}
                    local bestIndex, bestCost, bestName

                    for i, def in ipairs(MineConfig.Pickaxes) do
                        local skip = (MineConfig.IsPickaxeFree and MineConfig.IsPickaxeFree(def))
                            or def.RobuxOnly or type(def.Stock) ~= "table"

                        if not skip and unlocked[def.ZoneReq] then
                            local cost = tonumber(def.Cost)
                            local remaining = nil
                            if okStock and MineStock and MineStock.GetRemaining then
                                local okR, r = pcall(MineStock.GetRemaining, d, def.Name)
                                if okR then remaining = r end
                            end

                            local inStock = (remaining == nil) or (remaining > 0)
                            if cost and inStock and cost <= money then
                                if not bestCost or cost > bestCost then
                                    bestIndex, bestCost, bestName = i, cost, def.Name
                                end
                            end
                        end
                    end

                    if bestIndex then
                        if send("MineBuyPickaxe", bestIndex) then
                            stats.picks += 1
                            print("[minebot] comprou picareta: " .. tostring(bestName))
                            task.wait(1)
                            send("MineEquipBest")
                        end
                    end
                end
            end
        end
    end
end)

-- ---------------- UI ----------------
local function uiParent()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return lp:WaitForChild("PlayerGui")
end

local parent = uiParent()
local old = parent:FindFirstChild("MineBot")
if old then old:Destroy() end

local BG     = Color3.fromRGB(18, 18, 22)
local PANEL  = Color3.fromRGB(26, 26, 32)
local ROW    = Color3.fromRGB(33, 33, 40)
local ON     = Color3.fromRGB(70, 190, 120)
local OFF    = Color3.fromRGB(70, 70, 82)
local TEXT   = Color3.fromRGB(235, 235, 240)
local MUTED  = Color3.fromRGB(145, 145, 160)
local FONT   = Enum.Font.Code

local gui = Instance.new("ScreenGui")
gui.Name = "MineBot"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 9999
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(300, 372)
main.Position = UDim2.new(0, 24, 0.5, -186)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(55, 55, 70)

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 34)
bar.BackgroundColor3 = PANEL
bar.BorderSizePixel = 0
bar.Parent = main
Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 10)

local patch = Instance.new("Frame")
patch.Size = UDim2.new(1, 0, 0, 12)
patch.Position = UDim2.new(0, 0, 1, -12)
patch.BackgroundColor3 = PANEL
patch.BorderSizePixel = 0
patch.Parent = bar

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(12, 0)
title.Size = UDim2.new(1, -50, 1, 0)
title.Font = FONT
title.Text = "minebot"
title.TextSize = 14
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = bar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(24, 22)
closeBtn.Position = UDim2.new(1, -32, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(52, 36, 42)
closeBtn.BorderSizePixel = 0
closeBtn.Font = FONT
closeBtn.Text = "x"
closeBtn.TextSize = 13
closeBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
closeBtn.Parent = bar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)
closeBtn.MouseButton1Click:Connect(function()
    state.mine, state.chest, state.sell, state.equip = false, false, false, false
    gui:Destroy()
end)

local y = 44
local function toggle(label, key)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -24, 0, 32)
    row.Position = UDim2.fromOffset(12, y)
    row.BackgroundColor3 = ROW
    row.BorderSizePixel = 0
    row.AutoButtonColor = false
    row.Font = FONT
    row.Text = ""
    row.Parent = main
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.Position = UDim2.fromOffset(10, 0)
    name.Size = UDim2.new(1, -70, 1, 0)
    name.Font = FONT
    name.Text = label
    name.TextSize = 13
    name.TextColor3 = TEXT
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.Parent = row

    local led = Instance.new("Frame")
    led.Size = UDim2.fromOffset(42, 18)
    led.Position = UDim2.new(1, -52, 0, 7)
    led.BackgroundColor3 = OFF
    led.BorderSizePixel = 0
    led.Parent = row
    Instance.new("UICorner", led).CornerRadius = UDim.new(0, 9)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(14, 14)
    knob.Position = UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = TEXT
    knob.BorderSizePixel = 0
    knob.Parent = led
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    row.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        led.BackgroundColor3 = state[key] and ON or OFF
        knob.Position = state[key] and UDim2.fromOffset(26, 2) or UDim2.fromOffset(2, 2)
        print("[minebot] " .. label .. ": " .. tostring(state[key]))
    end)

    y += 38
end

toggle("auto minerar", "mine")
toggle("auto bau", "chest")
toggle("auto vender", "sell")
toggle("auto equipar", "equip")
toggle("auto picareta", "pickaxe")

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.fromOffset(12, y + 4)
info.Size = UDim2.new(1, -24, 0, 100)
info.Font = FONT
info.Text = ""
info.TextSize = 12
info.TextColor3 = MUTED
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.Parent = main

task.spawn(function()
    while gui.Parent do
        local _, _, dist = nearestNode()
        local mins = math.max((os.clock() - stats.started) / 60, 0.01)
        local d = mineData()
        info.Text = string.format(
            "nodes no plot: %d\nnode mais perto: %s\nswings: %d  (%.0f/min)\nbaus: %d   vendidos: %d   picaretas: %d\nzona: %s",
            #nodeList(),
            dist and string.format("%.1f studs", dist) or "-",
            stats.swings, stats.swings / mins,
            stats.chests, stats.sells, stats.picks,
            d and tostring(d.CurrentZone or "?") or "?"
        )
        task.wait(0.5)
    end
end)

do
    local dragging, startPos, startInput
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startInput = true, main.Position, input.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startInput
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        main.Visible = not main.Visible
    end
end)

print("[minebot] carregado - RightShift esconde o painel")
