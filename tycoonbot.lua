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
local PolisherService = tryRequire(RS.Shared.Services.PolisherService)
local Constants       = tryRequire(RS.Shared.Constants)
local Cooldowns       = tryRequire(RS.Shared.Constants.Cooldowns)

-- chama funcao de service com seguranca, devolvendo nil se nao existir
local function call(mod, fname, ...)
    if type(mod) ~= "table" or type(mod[fname]) ~= "function" then return nil end
    local ok, v = pcall(mod[fname], ...)
    if ok then return v end
    return nil
end

-- thread nova nasce sem a identidade do executor, e escrever em instancia
-- do gethui() exige capability. Toda thread chama isso na primeira linha.
local F_identity = setthreadidentity or setidentity or set_thread_identity
local function elevate()
    if type(F_identity) == "function" then pcall(F_identity, 8) end
end

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
-- os tempos vem do proprio jogo (Constants.Cooldowns), nao de chute:
--   CONVEYOR_ROLL_COOLDOWN = 1      EQUIP_BEST_FIGURES_COOLDOWN = 2
--   PLAYER_UNIT_SHOWCASE_COLLECT_COOLDOWN = 0.75
local CD = (type(Cooldowns) == "table") and Cooldowns or {}

local cfg = {
    collectEvery = CD.PLAYER_UNIT_SHOWCASE_COLLECT_COOLDOWN or 0.75,
    collectRange = 60,
    sellEvery    = 4,
    polishEvery  = 5,
    rollEvery    = CD.CONVEYOR_ROLL_COOLDOWN or 1,
    rollMargin   = 0.15,  -- folga em cima do cooldown real
    claimEvery   = 60,
    equipEvery   = math.max(CD.EQUIP_BEST_FIGURES_COOLDOWN or 2, 60),
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

-- o nome certo e GetCurrencyAmount(player, "Cash") - os outros nao existem
local function cash()
    local v = call(CurrencyService, "GetCurrencyAmount", lp, "Cash")
    if tonumber(v) then return tonumber(v) end

    local ls = lp:FindFirstChild("leaderstats")
    local s = ls and (ls:FindFirstChild("Cash") or ls:FindFirstChild("Money"))
    return s and tonumber(s.Value) or nil
end

local function canAfford(price)
    local v = call(CurrencyService, "CanAfford", lp, "Cash", price)
    if type(v) == "boolean" then return v end
    local money = cash()
    return (money == nil) or (money >= price)
end

-- locker: ocupado / capacidade, direto do BoxService
local function locker()
    local used = call(BoxService, "GetTotalBoxInventoryAmount", lp)
    local max  = call(BoxService, "GetMaxBoxInventorySpace", lp)
    return tonumber(used), tonumber(max)
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
    elevate()
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
    elevate()
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

-- polidor: so age se estiver desbloqueado, e so recolhe se tiver caixa pronta.
-- PolisherService.IsUnlocked / GetPendingCash / GetPolishedCash sao do jogo.
task.spawn(function()
    elevate()
    while true do
        task.wait(cfg.polishEvery)
        if state.polish then
            local unlocked = call(PolisherService, "IsUnlocked", lp)
            if unlocked == false then
                say("polidor nao desbloqueado (CratePolisherUnlock)")
            else
                local pending  = tonumber(call(PolisherService, "GetPendingCash", lp)) or 0
                local polished = tonumber(call(PolisherService, "GetPolishedCash", lp)) or 0

                for _, inst in ipairs(workspace:GetDescendants()) do
                    if inst:IsA("BasePart") and inst.Name == "CollectPart" and near(inst, 40) then
                        -- so deposita se nao tem nada em processamento
                        if pending <= 0 then
                            fireOnce(inst, "DepositCrate", 4)
                        end
                        -- so recolhe se ja tem polido esperando
                        if polished > 0 then
                            if fireOnce(inst, "CollectPolisherCrate", 4) then
                                say("recolheu do polidor: " .. tostring(polished))
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- roll: preco real, e liga o auto-buy nativo do jogo
task.spawn(function()
    elevate()
    local armed = false
    while true do
        -- cooldown real do jogador, nao numero fixo
        local realCd = tonumber(call(BoxService, "GetConveyorRollCooldown", lp))
        task.wait((realCd or cfg.rollEvery) + cfg.rollMargin)

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
                local price = tonumber(call(BoxService, "GetConveyorBoxPrice", boxName, variant))
                local hasSpace = call(BoxService, "HasBoxInventorySpace", lp, 1)
                if hasSpace == nil then hasSpace = true end

                if not hasSpace then
                    local used, max = locker()
                    say(string.format("locker cheio (%s/%s) - vende antes",
                        tostring(used or "?"), tostring(max or "?")))
                elseif price and not canAfford(price) then
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
    elevate()
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
    elevate()
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

local movedGui = false

task.spawn(function()
    elevate()
    while gui.Parent do
        local mins = math.max((os.clock() - stats.started) / 60, 0.01)
        local used, max = locker()
        local cd = tonumber(call(BoxService, "GetConveyorRollCooldown", lp))
        local pend = tonumber(call(PolisherService, "GetPendingCash", lp))

        local texto = string.format(
            "cash: %s   locker: %s/%s\ncoletado: %d (%.0f/min)  vendido: %d\nrolls: %d (cd %ss)   recompensas: %d\npolidor pendente: %s\n\n%s",
            tostring(cash() or "?"),
            tostring(used or "?"), tostring(max or "?"),
            stats.picked, stats.picked / mins, stats.sold,
            stats.rolled, tostring(cd or cfg.rollEvery), stats.claimed,
            tostring(pend or "-"),
            table.concat(log, "\n")
        )

        -- se a escrita falhar por capability, muda o painel pra PlayerGui,
        -- que e instancia comum e nao exige nada
        local okWrite = pcall(function() info.Text = texto end)
        if not okWrite and not movedGui then
            movedGui = true
            local pg = lp:FindFirstChildOfClass("PlayerGui")
            if pg and pcall(function() gui.Parent = pg end) then
                print("[tycoonbot] painel movido pro PlayerGui (capability)")
            else
                print("[tycoonbot] sem painel - acompanha pelo console")
            end
        end

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
