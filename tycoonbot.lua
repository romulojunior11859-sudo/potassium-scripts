--[[
    TycoonBot - automacao para o PlaceId 132767904294856 (tycoon de esteira)

    Usa os mesmos remotes que a UI do jogo usa, com os precos e cooldowns reais:
      PickupCrateBox / PickupCandyBag / CollectCollectableObject
      CollectVariantTokenSpawn / CollectItemRainItem / ClaimObbyBonus
      SellCrate / SellCandyBag
      DepositCrate / CollectPolisherCrate
      NewRequestConveyorRoll / PurchaseConveyorRoll (preco real do BoxService)
      RequestSetConveyorAutoBuy / RequestSetConveyorAutoSpawn
      ClaimDailyReward / ClaimPlaytimeReward / ClaimOfflineEarnings
      ClaimAllIndexRewards / EquipBestPlayerUnits

    Painel: RightShift. Botao "scan" lista as partes perto, pra calibrar nomes.
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local UIS     = game:GetService("UserInputService")

local lp = Players.LocalPlayer

local function tryRequire(path)
    local ok, mod = pcall(function() return require(path) end)
    if ok then return mod end
    return nil
end

local Remoting = tryRequire(RS.Shared.Utility.Remoting)
if type(Remoting) ~= "table" or type(Remoting.RemoteEvent) ~= "function" then
    warn("[tycoonbot] nao achei Shared.Utility.Remoting - o jogo mudou de estrutura")
    return
end

local BoxService      = tryRequire(RS.Shared.Services.BoxService)
local CurrencyService = tryRequire(RS.Shared.Services.CurrencyService)

-- cache de remotes, resolvido sob demanda
local remotes = {}
local function R(name, kind)
    if remotes[name] ~= nil then return remotes[name] or nil end
    local getter = (kind == "fn") and Remoting.RemoteFunction or Remoting.RemoteEvent
    local ok, r = pcall(getter, name)
    remotes[name] = (ok and r) or false
    if not ok then warn("[tycoonbot] remote ausente: " .. name) end
    return remotes[name] or nil
end

-- ---------------- config ----------------
local cfg = {
    collectEvery = 0.6,
    collectRange = 60,
    sellEvery    = 4,
    polishEvery  = 3,
    rollEvery    = 1.5,
    claimEvery   = 60,
    equipEvery   = 120,
}

local state = {
    collect = false, sell = false, polish = false,
    roll = false, claim = false, equip = false,
}
local stats = { picked = 0, sold = 0, rolled = 0, claimed = 0, started = os.clock() }

local log = {}
local function say(s)
    s = tostring(s)
    log[#log + 1] = s
    if #log > 7 then table.remove(log, 1) end
    print("[tycoonbot] " .. s)
end

local function fire(name, ...)
    local r = R(name)
    if not r then return false end
    local ok, err = pcall(function(...) r:FireServer(...) end, ...)
    if not ok then say("falhou " .. name .. ": " .. tostring(err)) end
    return ok
end

-- ---------------- helpers ----------------
local function root()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function near(inst, range)
    local r = root()
    if not r then return false end
    local ok, cf = pcall(function() return inst:GetPivot() end)
    local pos = ok and cf and cf.Position or (inst:IsA("BasePart") and inst.Position)
    if not pos then return false end
    return (pos - r.Position).Magnitude <= (range or cfg.collectRange)
end

local function cash()
    if type(CurrencyService) == "table" then
        for _, f in ipairs({ "GetCurrency", "Get", "GetAmount" }) do
            if type(CurrencyService[f]) == "function" then
                local ok, v = pcall(CurrencyService[f], lp, "Cash")
                if ok and tonumber(v) then return tonumber(v) end
            end
        end
    end
    local ls = lp:FindFirstChild("leaderstats")
    local s = ls and (ls:FindFirstChild("Cash") or ls:FindFirstChild("Money"))
    return s and tonumber(s.Value) or nil
end

-- tudo que o jogo marca com esses atributos/nomes vira alvo de coleta
local COLLECT_RULES = {
    { match = "CrateGuid",        remote = "PickupCrateBox" },
    { match = "CandyBagGuid",     remote = "PickupCandyBag" },
    { match = "CollectableId",    remote = "CollectCollectableObject" },
    { match = "VariantTokenId",   remote = "CollectVariantTokenSpawn" },
    { match = "ItemRainId",       remote = "CollectItemRainItem" },
    { match = "ObbyBonus",        remote = "ClaimObbyBonus" },
}

local lastFired = {}
local function fireOnce(inst, remote, cooldown)
    local key = tostring(inst) .. remote
    local now = os.clock()
    if lastFired[key] and now - lastFired[key] < (cooldown or 2) then return false end
    lastFired[key] = now
    return fire(remote, inst)
end

-- ---------------- loops ----------------
task.spawn(function()
    while true do
        task.wait(cfg.collectEvery)
        if state.collect then
            for _, inst in ipairs(workspace:GetDescendants()) do
                if inst:IsA("BasePart") or inst:IsA("Model") then
                    for _, rule in ipairs(COLLECT_RULES) do
                        if inst:GetAttribute(rule.match) ~= nil and near(inst) then
                            if fireOnce(inst, rule.remote) then
                                stats.picked += 1
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- venda: o cliente le o guid do que esta na mao
task.spawn(function()
    while true do
        task.wait(cfg.sellEvery)
        if state.sell then
            local char = lp.Character
            local tool = char and char:FindFirstChildOfClass("Tool")
            if tool then
                local crate = tool:GetAttribute("CrateGuid")
                local bag   = tool:GetAttribute("CandyBagGuid")
                if crate and fire("SellCrate", crate) then
                    stats.sold += 1
                    say("vendeu crate")
                elseif bag and fire("SellCandyBag", bag) then
                    stats.sold += 1
                    say("vendeu candy bag")
                end
            end
        end
    end
end)

-- polidor: deposita e recolhe
task.spawn(function()
    while true do
        task.wait(cfg.polishEvery)
        if state.polish then
            for _, inst in ipairs(workspace:GetDescendants()) do
                if inst:IsA("BasePart") and inst.Name == "CollectPart" and near(inst, 40) then
                    fireOnce(inst, "DepositCrate", 4)
                    fireOnce(inst, "CollectPolisherCrate", 4)
                end
            end
        end
    end
end)

-- roll: preco real, e liga o auto-buy nativo do jogo
task.spawn(function()
    local armed = false
    while true do
        task.wait(cfg.rollEvery)
        if state.roll then
            if not armed then
                fire("RequestSetConveyorAutoBuy", true)
                fire("RequestSetConveyorAutoSpawn", true)
                armed = true
                say("auto-buy e auto-spawn do jogo ligados")
            end

            local part, boxName, variant
            for _, inst in ipairs(workspace:GetDescendants()) do
                if inst:GetAttribute("BoxName") and inst:GetAttribute("Variant") and near(inst, 80) then
                    part = inst
                    boxName = inst:GetAttribute("BoxName")
                    variant = inst:GetAttribute("Variant")
                    break
                end
            end

            if part then
                local price
                if type(BoxService) == "table" and type(BoxService.GetConveyorBoxPrice) == "function" then
                    local ok, p = pcall(BoxService.GetConveyorBoxPrice, boxName, variant)
                    if ok then price = tonumber(p) end
                end

                local money = cash()
                local hasSpace = true
                if type(BoxService) == "table" and type(BoxService.HasBoxInventorySpace) == "function" then
                    local ok, s = pcall(BoxService.HasBoxInventorySpace, lp, 1)
                    if ok then hasSpace = s and true or false end
                end

                if not hasSpace then
                    say("locker cheio - vende antes")
                elseif price and money and money < price then
                    say("sem dinheiro pro roll (precisa " .. tostring(price) .. ")")
                elseif price then
                    if fire("PurchaseConveyorRoll", boxName, variant, price) then
                        stats.rolled += 1
                    end
                end
            end
        else
            armed = false
        end
    end
end)

-- recompensas que o jogo da de graca
task.spawn(function()
    while true do
        task.wait(cfg.claimEvery)
        if state.claim then
            local n = 0
            for _, name in ipairs({
                "ClaimDailyReward", "ClaimPlaytimeReward",
                "ClaimOfflineEarnings", "ClaimAllIndexRewards",
            }) do
                if fire(name) then n += 1 end
            end
            if n > 0 then
                stats.claimed += n
                say("pediu " .. n .. " recompensa(s)")
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(cfg.equipEvery)
        if state.equip then fire("EquipBestPlayerUnits") end
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
local old = parent:FindFirstChild("TycoonBot")
if old then old:Destroy() end

local BG    = Color3.fromRGB(18, 18, 22)
local PANEL = Color3.fromRGB(26, 26, 32)
local ROW   = Color3.fromRGB(33, 33, 40)
local ON    = Color3.fromRGB(70, 190, 120)
local OFF   = Color3.fromRGB(70, 70, 82)
local TEXT  = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(145, 145, 160)
local FONT  = Enum.Font.Code

local gui = Instance.new("ScreenGui")
gui.Name = "TycoonBot"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(312, 420)
main.Position = UDim2.new(0, 24, 0.5, -210)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
Instance.new("UIStroke", main).Color = Color3.fromRGB(55, 55, 70)

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 32)
bar.BackgroundColor3 = PANEL
bar.BorderSizePixel = 0
bar.Parent = main
Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(12, 0)
title.Size = UDim2.new(1, -90, 1, 0)
title.Font = FONT
title.Text = "tycoon bot"
title.TextSize = 14
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = bar

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.fromOffset(46, 20)
scanBtn.Position = UDim2.new(1, -84, 0, 6)
scanBtn.BackgroundColor3 = ROW
scanBtn.BorderSizePixel = 0
scanBtn.Font = FONT
scanBtn.Text = "scan"
scanBtn.TextSize = 11
scanBtn.TextColor3 = TEXT
scanBtn.Parent = bar
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 5)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(24, 20)
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
    for k in pairs(state) do state[k] = false end
    gui:Destroy()
end)

-- scan: lista atributos das partes perto, pra calibrar as regras de coleta
scanBtn.MouseButton1Click:Connect(function()
    local seen, n = {}, 0
    for _, inst in ipairs(workspace:GetDescendants()) do
        if (inst:IsA("BasePart") or inst:IsA("Model")) and near(inst, 50) then
            local attrs = inst:GetAttributes()
            for k in pairs(attrs) do
                if not seen[k] then
                    seen[k] = true
                    n += 1
                    if n <= 25 then print("[scan] atributo: " .. k .. "  (ex: " .. inst.Name .. ")") end
                end
            end
        end
    end
    say("scan: " .. n .. " atributos distintos perto - olha o console")
end)

local y = 40
local function toggle(label, key)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -24, 0, 28)
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
    led.Size = UDim2.fromOffset(36, 16)
    led.Position = UDim2.new(1, -46, 0, 6)
    led.BackgroundColor3 = OFF
    led.BorderSizePixel = 0
    led.Parent = row
    Instance.new("UICorner", led).CornerRadius = UDim.new(0, 8)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(12, 12)
    knob.Position = UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = TEXT
    knob.BorderSizePixel = 0
    knob.Parent = led
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    row.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        led.BackgroundColor3 = state[key] and ON or OFF
        knob.Position = state[key] and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2)
        say(label .. ": " .. tostring(state[key]))
    end)

    y += 32
end

toggle("auto coletar", "collect")
toggle("auto vender", "sell")
toggle("auto polidor", "polish")
toggle("auto roll", "roll")
toggle("auto recompensas", "claim")
toggle("auto equipar", "equip")

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.fromOffset(12, y + 6)
info.Size = UDim2.new(1, -24, 0, 170)
info.Font = FONT
info.Text = ""
info.TextSize = 11
info.TextColor3 = MUTED
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.TextWrapped = true
info.Parent = main

task.spawn(function()
    while gui.Parent do
        local mins = math.max((os.clock() - stats.started) / 60, 0.01)
        info.Text = string.format(
            "cash: %s\ncoletado: %d (%.0f/min)  vendido: %d\nrolls: %d   recompensas: %d\n\n%s",
            tostring(cash() or "?"),
            stats.picked, stats.picked / mins, stats.sold,
            stats.rolled, stats.claimed,
            table.concat(log, "\n")
        )
        task.wait(0.5)
    end
end)

do
    local dragging, startPos, startInput
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, startPos, startInput = true, main.Position, input.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - startInput
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        main.Visible = not main.Visible
    end
end)

say("carregado - roda o scan primeiro pra calibrar a coleta")
