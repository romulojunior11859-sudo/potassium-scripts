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
    zoneEvery     = 25,
    skillEvery    = 10,
    summonEvery   = 6,
    crateEvery    = 9,   -- o jogo trava 8s entre aberturas
    potionEvery   = 15,
    mysteryEvery  = 5,
    minerEvery    = 8,
    mutationEvery = 12,
    enchantEvery  = 10,
    travel        = true,   -- ir ate o altar/shrine antes de usar
    travelMode    = "tp",   -- "tp" = CFrame direto, "walk" = caminhada
    travelRange   = 12,     -- distancia que ja conta como "chegou"
    travelTimeout = 25,     -- so vale no modo walk
    returnAfter   = true,   -- volta pro ponto de mineracao depois de usar
    potions       = {},  -- nomes exatos de pocao pra usar sozinho; vazio = nenhuma
    sellKinds     = { Ore = true },  -- so minerio; bota Crate = true etc se quiser
    pauseEvery    = { 180, 420 },  -- a cada N swings, uma pausa curta
    pauseFor      = { 0.6, 2.2 },
}

local state = {
    mine = false, chest = false, sell = false, equip = false,
    pickaxe = false, zone = false, skill = false,
    summon = false, crate = false, potion = false, mystery = false,
    miner = false, mutation = false, enchant = false,
}
local stats = {
    swings = 0, sells = 0, chests = 0, picks = 0, zones = 0, skills = 0,
    summons = 0, crates = 0, potions = 0, mysteries = 0, miners = 0,
    mutations = 0, enchants = 0, started = os.clock(),
}

local okCfg,   MineConfig = pcall(function() return require(RS.Modules.MineConfig) end)
local okStock, MineStock  = pcall(function() return require(RS.Modules.MineStock) end)
local okSum,   SummonCat  = pcall(function() return require(RS.Modules.MineSummonCatalog) end)
local okCrate, CrateConf  = pcall(function() return require(RS.Modules.MineCrateConfig) end)

-- motivo de cada modo ligado nao estar disparando, mostrado no painel
local why = {}

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

        if state.mine and not busy then
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

-- compra de caverna: a primeira zona bloqueada na ordem de MineConfig.ZoneKeys,
-- quando o dinheiro cobre o UnlockCost. Vai na ordem porque a zona anterior
-- e pre-requisito (ZoneResearchGateFor). Selecionar a zona e o proprio caminho
-- de compra: nao existe evento separado pra isso.
task.spawn(function()
    while true do
        task.wait(cfg.zoneEvery)
        if state.zone then
            if not (okCfg and type(MineConfig) == "table" and type(MineConfig.ZoneKeys) == "table") then
                warn("[minebot] MineConfig indisponivel - auto caverna desligado")
                state.zone = false
            else
                local ok, data = pcall(GameState.GetData2)
                local d = (ok and type(data) == "table") and data or nil
                local mine = d and type(d.MineGame) == "table" and d.MineGame or nil

                if mine then
                    local money = tonumber(d.Money) or 0
                    local unlocked = mine.UnlockedZones or {}

                    for _, key in ipairs(MineConfig.ZoneKeys) do
                        if not unlocked[key] then
                            local zone = (MineConfig.Zones or {})[key]
                            local cost = tonumber(zone and zone.UnlockCost)
                            if cost and cost <= money then
                                if send("MineSelectZone", key) then
                                    stats.zones += 1
                                    print("[minebot] comprou caverna: " ..
                                        tostring(zone.DisplayName or key))
                                end
                            end
                            break  -- so a proxima da fila importa
                        end
                    end
                end
            end
        end
    end
end)

-- arvore de habilidade: compra um no por vez, usando as mesmas checagens
-- do botao original (aberto e nao maximizado).
task.spawn(function()
    while true do
        task.wait(cfg.skillEvery)
        if state.skill then
            if not (okCfg and type(MineConfig) == "table" and MineConfig.GetSkillNodes) then
                warn("[minebot] MineConfig sem arvore de skill - desligado")
                state.skill = false
            else
                local ok, data = pcall(GameState.GetData2)
                local d = (ok and type(data) == "table") and data or nil
                local mine = d and type(d.MineGame) == "table" and d.MineGame or nil

                if mine then
                    local zoneKey = "Z" .. tostring(mine.CurrentZone or 1)
                    local unlocked = mine.UnlockedZones or {}

                    if unlocked[zoneKey] then
                        local skills = (mine.Skills or {})[zoneKey] or {}
                        local okNodes, nodes = pcall(MineConfig.GetSkillNodes, zoneKey)

                        if okNodes and type(nodes) == "table" then
                            for _, node in ipairs(nodes) do
                                local okM, maxed = pcall(MineConfig.IsSkillNodeMaxed, skills, node)
                                local okO, open  = pcall(MineConfig.IsSkillNodeOpen, skills, node)

                                if okM and okO and open and not maxed then
                                    if send("MineBuySkill", zoneKey, node.Family, node.Id) then
                                        stats.skills += 1
                                        print("[minebot] skill: " ..
                                            tostring(node.Name or node.Id) .. " (" .. zoneKey .. ")")
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- helper: devolve (dataCompleto, mineGame)
local function bothData()
    local ok, data = pcall(GameState.GetData2)
    if not ok or type(data) ~= "table" then return nil, nil end
    return data, (type(data.MineGame) == "table" and data.MineGame or nil)
end

-- enquanto true, o loop de mineracao para: senao os dois disputam o MoveTo
local busy = false

-- teleporte simples: escreve no CFrame do root.
-- O anticheat do jogo nao olha posicao nem magnitude - so physics FPS,
-- WalkSpeed/JumpPower e metamétodos - entao isso nao dispara nada dele.
local function tpTo(pos)
    local r = root()
    if not (r and pos) then return false end
    r.CFrame = CFrame.new(pos)
    task.wait(0.25)
    return true
end

-- vai ate um objeto do mundo (EnchantAltar, SummonShrine).
-- Devolve true quando chega perto o bastante.
local function goTo(inst, range, timeout)
    local target = inst and pivotOf(inst)
    if not target then return false end

    range = range or cfg.travelRange
    local r = root()
    if r and (r.Position - target).Magnitude <= range then
        return true
    end

    if cfg.travelMode == "tp" then
        busy = true

        local from = r and r.Position or (target + Vector3.new(0, 0, 10))
        local dir = from - target
        if dir.Magnitude < 1 then
            dir = Vector3.new(0, 0, 1)
        end

        -- para alguns studs antes do objeto, nao dentro dele
        tpTo(target + dir.Unit * math.min(range * 0.5, 6) + Vector3.new(0, 3, 0))
        task.wait(0.4)

        r = root()
        busy = false
        return (r ~= nil) and (r.Position - target).Magnitude <= range * 1.5
    end

    busy = true
    local deadline = os.clock() + (timeout or cfg.travelTimeout)

    while os.clock() < deadline do
        local h = humanoid()
        r = root()

        if not (h and r) then
            break
        end

        if (r.Position - target).Magnitude <= range then
            busy = false
            return true
        end

        h:MoveTo(target)
        task.wait(0.35)
    end

    busy = false
    return false
end

-- summon: tres portas - ilha liberada, pelo menos 1 scroll, e o altar no mundo
task.spawn(function()
    while true do
        task.wait(cfg.summonEvery)
        if state.summon then
            local d, mine = bothData()
            if mine then
                local unlocked = true
                if okSum and type(SummonCat) == "table" and SummonCat.Unlocked then
                    local okU, res = pcall(SummonCat.Unlocked, d)
                    unlocked = okU and res and true or false
                end

                local scrolls = 0
                if okCfg and MineConfig.GetSummonScrollCount then
                    local okS, n = pcall(MineConfig.GetSummonScrollCount, mine)
                    if okS then scrolls = tonumber(n) or 0 end
                end

                if not unlocked then
                    why.summon = "ilha do summon ainda bloqueada"
                elseif scrolls < 1 then
                    why.summon = "sem scroll de summon"
                else
                    local back = root() and root().Position or nil

                    if cfg.travel and not goTo(workspace:FindFirstChild("SummonShrine")) then
                        why.summon = "nao cheguei no SummonShrine"
                    else
                        why.summon = nil

                        if send("MineSummon") then
                            stats.summons += 1
                            print("[minebot] summon (restavam " .. scrolls .. " scrolls)")
                        end

                        if cfg.travel and cfg.returnAfter and back then
                            task.wait(1)
                            tpTo(back)
                        end
                    end
                end
            end
        end
    end
end)

-- crates: abre ate MaxOpen de uma vez, respeitando a trava de 8s do jogo
task.spawn(function()
    while true do
        task.wait(cfg.crateEvery)
        if state.crate then
            if not (okInv and MineInventory and MineInventory.CrateEntries) then
                why.crate = "MineInventory sem CrateEntries"
            else
                local _, mine = bothData()
                local okE, entries = pcall(MineInventory.CrateEntries, mine)

                if not okE or type(entries) ~= "table" then
                    why.crate = "nao consegui listar crates"
                else
                    local maxOpen = 1
                    if okCrate and type(CrateConf) == "table" then
                        maxOpen = tonumber(CrateConf.MaxOpen) or 1
                    end

                    local sent = false
                    for _, e in pairs(entries) do
                        if type(e) == "table" then
                            local count = tonumber(e.Count) or 0
                            local name = e.Name or e.Key
                            if name and count > 0 then
                                local n = math.min(count, maxOpen)
                                if send("MineOpenColossusCrate", name, n) then
                                    stats.crates += n
                                    print("[minebot] abriu " .. n .. "x " .. tostring(name))
                                    sent = true
                                end
                                break
                            end
                        end
                    end
                    why.crate = sent and nil or "nenhuma crate no inventario"
                end
            end
        end
    end
end)

-- pocoes: so as listadas em cfg.potions, e so se tiver no inventario
task.spawn(function()
    while true do
        task.wait(cfg.potionEvery)
        if state.potion then
            if next(cfg.potions) == nil then
                why.potion = "cfg.potions esta vazia"
            else
                local _, mine = bothData()
                local used = false

                for _, name in ipairs(cfg.potions) do
                    local have = 0
                    if okCfg and MineConfig.GetPotionCount then
                        local okP, n = pcall(MineConfig.GetPotionCount, mine, name)
                        if okP then have = tonumber(n) or 0 end
                    end

                    if have > 0 then
                        if send("MineUsePotion", name, 1) then
                            stats.potions += 1
                            print("[minebot] usou pocao: " .. tostring(name))
                            used = true
                        end
                        break
                    end
                end
                why.potion = used and nil or "nenhuma das pocoes listadas no inventario"
            end
        end
    end
end)

-- mystery block: so abre o que estiver EQUIPADO, igual ao heldBlock do jogo
task.spawn(function()
    while true do
        task.wait(cfg.mysteryEvery)
        if state.mystery then
            local _, mine = bothData()
            if mine then
                local equipped = mine.Equipped
                local label = (type(equipped) == "string" and equipped ~= ""
                    and type(mine.Hotbar) == "table") and mine.Hotbar[equipped] or nil

                local block
                if label and okCfg and MineConfig.GetMysteryBlockByLabel then
                    local okB, b = pcall(MineConfig.GetMysteryBlockByLabel, label)
                    if okB then block = b end
                end

                if not block then
                    why.mystery = "equipa um mystery block no hotbar"
                else
                    why.mystery = nil
                    local key = block.Key or label
                    if send("MineOpenMysteryBlock", key) then
                        stats.mysteries += 1
                        print("[minebot] abriu mystery block: " .. tostring(key))
                    end
                end
            end
        end
    end
end)

-- upgrade dos miners (os "pets" dos slots M1..N).
-- Em vez de recalcular o custo, ele tenta e observa o nivel: se nao subiu,
-- o slot entra em espera - e sinal de sem dinheiro ou nivel maximo.
local lastLevel, stalled = {}, {}

task.spawn(function()
    while true do
        task.wait(cfg.minerEvery)
        if state.miner then
            local _, mine = bothData()
            local holders = mine and type(mine.Holders) == "table" and mine.Holders or nil

            if not holders or next(holders) == nil then
                why.miner = "nenhum miner nos slots"
            else
                local now = os.clock()
                local picked, pickedLevel

                for key, holder in pairs(holders) do
                    if type(holder) == "table" and holder.CharName then
                        local level = tonumber(holder.Level) or 0

                        -- subiu desde a ultima tentativa? tira da espera
                        if lastLevel[key] and level > lastLevel[key] then
                            stalled[key] = nil
                        end

                        if not stalled[key] or now >= stalled[key] then
                            if not pickedLevel or level < pickedLevel then
                                picked, pickedLevel = key, level
                            end
                        end
                    end
                end

                if not picked then
                    why.miner = "todos os slots em espera (max ou sem dinheiro)"
                else
                    why.miner = nil
                    local before = pickedLevel
                    lastLevel[picked] = before

                    if send("MineUpgradeCharacter", picked) then
                        task.wait(1.5)
                        local _, after = bothData()
                        local nowLevel = after and after.Holders and after.Holders[picked]
                            and tonumber(after.Holders[picked].Level) or before

                        if nowLevel > before then
                            stats.miners += 1
                            print("[minebot] " .. picked .. " subiu pro nivel " .. nowLevel)
                        else
                            stalled[picked] = os.clock() + 60
                        end
                    end
                end
            end
        end
    end
end)

-- mutacao: rola no slot. O cliente exige personagem no slot, slot destravado
-- e dinheiro >= rollCost - mas rollCost e funcao local do jogo, entao aqui
-- a gente tenta e olha o dinheiro: se nao caiu, o slot espera 60s.
local mutStall = {}

task.spawn(function()
    while true do
        task.wait(cfg.mutationEvery)
        if state.mutation then
            local d, mine = bothData()
            local holders = mine and type(mine.Holders) == "table" and mine.Holders or nil

            if not holders or next(holders) == nil then
                why.mutation = "nenhum miner nos slots"
            else
                local now = os.clock()
                local pick

                for key, holder in pairs(holders) do
                    if type(holder) == "table" and holder.CharName then
                        if not mutStall[key] or now >= mutStall[key] then
                            pick = key
                            break
                        end
                    end
                end

                if not pick then
                    why.mutation = "slots em espera (travados ou sem dinheiro)"
                else
                    why.mutation = nil
                    local before = tonumber(d and d.Money) or 0

                    if send("MineRollMutation", pick) then
                        task.wait(2)
                        local after = bothData()
                        local money = tonumber(after and after.Money) or before

                        if money < before then
                            stats.mutations += 1
                            print("[minebot] rolou mutacao em " .. pick)
                        else
                            mutStall[pick] = os.clock() + 60
                        end
                    end
                end
            end
        end
    end
end)

-- encantamento: um dado por vez, categoria generica.
-- O altar fica no mundo (bindAltarPrompt), entao o servidor pode exigir
-- que voce esteja perto dele - se nunca consumir dado, e isso.
task.spawn(function()
    while true do
        task.wait(cfg.enchantEvery)
        if state.enchant then
            local _, mine = bothData()
            local dice = 0

            if okCfg and MineConfig.GetEnchantDiceCount then
                local okD, n = pcall(MineConfig.GetEnchantDiceCount, mine)
                if okD then dice = tonumber(n) or 0 end
            end

            if dice < 1 then
                why.enchant = "sem dado de encantamento"
            else
                local back = root() and root().Position or nil

                if cfg.travel and not goTo(workspace:FindFirstChild("EnchantAltar")) then
                    why.enchant = "nao cheguei no EnchantAltar"
                else
                    why.enchant = nil

                    if send("MineRollEnchant", 1) then
                        stats.enchants += 1
                        print("[minebot] rolou encantamento (tinha " .. dice .. " dados)")
                    end

                    if cfg.travel and cfg.returnAfter and back then
                        task.wait(1)
                        tpTo(back)
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
main.Size = UDim2.fromOffset(312, 640)
main.Position = UDim2.new(0, 24, 0.5, -320)
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

local y = 42
local function toggle(label, key)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -24, 0, 26)
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
    led.Position = UDim2.new(1, -46, 0, 5)
    led.BackgroundColor3 = OFF
    led.BorderSizePixel = 0
    led.Parent = row
    Instance.new("UICorner", led).CornerRadius = UDim.new(0, 9)

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
        print("[minebot] " .. label .. ": " .. tostring(state[key]))
    end)

    y += 30
end

toggle("auto minerar", "mine")
toggle("auto bau", "chest")
toggle("auto vender", "sell")
toggle("auto equipar", "equip")
toggle("auto picareta", "pickaxe")
toggle("auto caverna", "zone")
toggle("auto skill", "skill")
toggle("auto summon", "summon")
toggle("auto crate", "crate")
toggle("auto pocao", "potion")
toggle("auto mystery", "mystery")
toggle("auto miner", "miner")
toggle("auto mutacao", "mutation")
toggle("auto encanto", "enchant")

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.fromOffset(12, y + 4)
info.Size = UDim2.new(1, -24, 0, 150)
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
            "nodes no plot: %d\nnode mais perto: %s\nswings: %d  (%.0f/min)\nbaus: %d   vendidos: %d   picaretas: %d\ncavernas: %d   skills: %d\nzona: %s",
            #nodeList(),
            dist and string.format("%.1f studs", dist) or "-",
            stats.swings, stats.swings / mins,
            stats.chests, stats.sells, stats.picks,
            stats.zones, stats.skills,
            d and tostring(d.CurrentZone or "?") or "?"
        )

        local pend = {}
        for mode, reason in pairs(why) do
            if state[mode] and reason then pend[#pend + 1] = mode .. ": " .. reason end
        end
        if #pend > 0 then
            info.Text = info.Text .. "\n\n" .. table.concat(pend, "\n")
        end
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
