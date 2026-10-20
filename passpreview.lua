--[[
    PassPreview - faz o TEU cliente achar que voce tem as gamepasses do jogo.

    O que isso faz:   a UI destrava, botoes de "comprar" viram "ativo", telas
                      bloqueadas abrem - da pra ver como o jogo fica pra quem comprou.
    O que NAO faz:    nada de servidor. O servidor roda a propria checagem
                      (Shared.Service -> UserOwnsGamePassAsync) e nenhum perk,
                      multiplicador, item ou moeda vem dessa simulacao.

    Painel: RightAlt
]]

local Players            = game:GetService("Players")
local RS                 = game:GetService("ReplicatedStorage")
local UIS                = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")

local lp = Players.LocalPlayer

-- ---------------- acesso ----------------
-- so quem estiver aqui consegue rodar.
local WHITELIST = {
    -- [123456789] = "meu alt",
}

do
    local id = lp.UserId
    if next(WHITELIST) == nil or not WHITELIST[id] then
        warn("[passpreview] acesso negado - UserId " .. tostring(id))
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "passpreview",
                Text = "acesso negado - UserId " .. tostring(id),
                Duration = 8,
            })
        end)
        return
    end
end

-- funcoes de hook do executor
local F_hookmeta  = hookmetamethod
local F_namecall  = getnamecallmethod
local F_newc      = newcclosure or function(f) return f end
local F_caller    = checkcaller or function() return false end

if type(F_hookmeta) ~= "function" or type(F_namecall) ~= "function" then
    warn("[passpreview] executor sem hookmetamethod/getnamecallmethod - nao da pra seguir")
    return
end

local state = { on = false, all = true }
local passes = {}      -- [id] = nome
local hits   = 0       -- quantas checagens foram respondidas por nos

-- ---------------- catalogo de passes ----------------
local function collectPasses()
    table.clear(passes)
    local ok, Monetization = pcall(function() return require(RS.Modules.Monetization) end)
    if not ok or type(Monetization) ~= "table" then return end

    local data = Monetization.Data
    local gp = data and data.Gamepasses
    if type(gp) ~= "table" then return end

    local function idOf(entry)
        if type(entry) == "number" then return entry end
        if type(entry) ~= "table" then return nil end
        for _, field in ipairs({ "Id", "ID", "id", "GamepassId", "GamePassId", "ProductId" }) do
            if type(entry[field]) == "number" then return entry[field] end
        end
        return nil
    end

    for key, entry in pairs(gp) do
        local id = idOf(entry)
        if id then
            passes[id] = tostring(key)
        end
    end
end

collectPasses()

-- recoleta quando o servidor manda o catalogo
task.spawn(function()
    for _ = 1, 12 do
        task.wait(5)
        if next(passes) == nil then collectPasses() end
    end
end)

-- ---------------- hook ----------------
local function shouldFake(method, a, b)
    if not state.on then return false end

    if method == "UserOwnsGamePassAsync" then
        -- assinatura: (player/userId, gamePassId)
        local userId = typeof(a) == "Instance" and a:IsA("Player") and a.UserId or a
        if userId ~= lp.UserId then return false end
        return state.all or passes[b] ~= nil
    end

    if method == "PlayerOwnsAsset" then
        local player = typeof(a) == "Instance" and a or nil
        if player ~= lp then return false end
        return state.all
    end

    return false
end

local oldNamecall
oldNamecall = F_hookmeta(game, "__namecall", F_newc(function(self, ...)
    local method = F_namecall()

    if (method == "UserOwnsGamePassAsync" or method == "PlayerOwnsAsset") and not F_caller() then
        local a, b = ...
        if shouldFake(method, a, b) then
            hits += 1
            return true
        end
    end

    return oldNamecall(self, ...)
end))

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
local old = parent:FindFirstChild("PassPreview")
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
gui.Name = "PassPreview"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 9999
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(290, 210)
main.Position = UDim2.new(1, -320, 0.5, -105)
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
title.Text = "pass preview"
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
    state.on = false
    gui:Destroy()
end)

local row = Instance.new("TextButton")
row.Size = UDim2.new(1, -24, 0, 32)
row.Position = UDim2.fromOffset(12, 44)
row.BackgroundColor3 = ROW
row.BorderSizePixel = 0
row.AutoButtonColor = false
row.Font = FONT
row.Text = ""
row.Parent = main
Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

local label = Instance.new("TextLabel")
label.BackgroundTransparency = 1
label.Position = UDim2.fromOffset(10, 0)
label.Size = UDim2.new(1, -70, 1, 0)
label.Font = FONT
label.Text = "fingir posse"
label.TextSize = 13
label.TextColor3 = TEXT
label.TextXAlignment = Enum.TextXAlignment.Left
label.Parent = row

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
    state.on = not state.on
    led.BackgroundColor3 = state.on and ON or OFF
    knob.Position = state.on and UDim2.fromOffset(26, 2) or UDim2.fromOffset(2, 2)
    print("[passpreview] fingir posse: " .. tostring(state.on))
end)

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.fromOffset(12, 86)
info.Size = UDim2.new(1, -24, 0, 110)
info.Font = FONT
info.Text = ""
info.TextSize = 12
info.TextColor3 = MUTED
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.TextWrapped = true
info.Parent = main

task.spawn(function()
    while gui.Parent do
        local n = 0
        for _ in pairs(passes) do n += 1 end
        info.Text = string.format(
            "passes no catalogo: %d\nchecagens respondidas: %d\n\nso muda a aparencia no teu cliente.\no servidor nao concede nada.",
            n, hits
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
    if not processed and input.KeyCode == Enum.KeyCode.RightAlt then
        main.Visible = not main.Visible
    end
end)

print("[passpreview] carregado - RightAlt esconde o painel")
