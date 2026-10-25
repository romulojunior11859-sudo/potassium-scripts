--[[
    Potassium - dump de scripts (v3, com relatorio)

    TARGET aceita string ou lista:
      ""                    -> so lista os alvos
      "*"                   -> tudo ate MAX_ALL (respeita SKIP)
      "BoxService"          -> todos os matches desse pedaco de nome
      { "A", "B" }          -> todos os matches de qualquer um da lista

    Sempre grava workspace/dumps/_report.txt
]]

local TARGET  = { "Shared.Services", "Shared.Utility", "Shared.Constants" }
local OUT     = "dumps"
local MAX_ALL = 400
local SKIP    = { "PlayerModule", "CmdrClient", "TopbarPlus", "ZonePlus", "PoolerPlus", "CoreGui", "RobloxGui", "PlayerScriptsLoader" }

-- globais do executor pegos direto, sem getfenv
local F_write    = writefile
local F_read     = readfile
local F_isfolder = isfolder
local F_mkfolder = makefolder
local F_bytecode = getscriptbytecode or dumpstring
local F_decomp   = decompile
local F_scripts  = getscripts
local F_modules  = getloadedmodules
local F_nil      = getnilinstances
local F_ident    = identifyexecutor

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local report = {}
local function log(s)
    s = tostring(s)
    report[#report + 1] = s
    print("[dump] " .. s)
end

local function flush()
    if not F_write then
        print("[dump] SEM writefile - relatorio so no console")
        return
    end
    if F_mkfolder and F_isfolder and not F_isfolder(OUT) then pcall(F_mkfolder, OUT) end
    pcall(F_write, OUT .. "/_report.txt", table.concat(report, "\n"))
end

local function main()
    log("== relatorio dump v2 ==")
    log("executor: " .. (F_ident and tostring(F_ident()) or "?"))
    log("jogo: " .. tostring(game.PlaceId) .. " / " .. tostring(game.JobId))

    local caps = {
        { "writefile", F_write }, { "readfile", F_read }, { "makefolder", F_mkfolder },
        { "isfolder", F_isfolder }, { "getscriptbytecode", F_bytecode }, { "decompile", F_decomp },
        { "getscripts", F_scripts }, { "getloadedmodules", F_modules }, { "getnilinstances", F_nil },
    }
    local list = {}
    for _, c in ipairs(caps) do
        list[#list + 1] = c[1] .. "=" .. (type(c[2]) == "function" and "OK" or "FALTA")
    end
    log("api: " .. table.concat(list, "  "))

    if not F_write then
        log("PARADO: sem writefile nao da pra salvar nada")
        return
    end
    if F_mkfolder and F_isfolder and not F_isfolder(OUT) then
        local ok, err = pcall(F_mkfolder, OUT)
        log("makefolder " .. OUT .. ": " .. (ok and "ok" or tostring(err)))
    end

    -- teste de escrita real, pra separar "nao achou script" de "nao escreve"
    local okTest, errTest = pcall(F_write, OUT .. "/_writetest.txt", "ok")
    log("teste de escrita: " .. (okTest and "gravou" or tostring(errTest)))

    -- ---- coleta ----
    local seen, targets = {}, {}
    local function add(inst, origem)
        if typeof(inst) ~= "Instance" or seen[inst] then return end
        if inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script") then
            seen[inst] = true
            targets[#targets + 1] = { inst = inst, origem = origem }
        end
    end

    local sources = {
        { "getscripts", F_scripts }, { "getloadedmodules", F_modules }, { "getnilinstances", F_nil },
    }
    for _, s in ipairs(sources) do
        if s[2] then
            local ok, res = pcall(s[2])
            if ok and type(res) == "table" then
                local before = #targets
                for _, inst in ipairs(res) do add(inst, s[1]) end
                log(s[1] .. ": +" .. (#targets - before) .. " (de " .. #res .. " retornados)")
            else
                log(s[1] .. ": falhou -> " .. tostring(res))
            end
        end
    end

    local roots = {
        lp.Character, lp:FindFirstChild("PlayerScripts"), lp:FindFirstChild("PlayerGui"),
        lp:FindFirstChild("Backpack"), game:GetService("ReplicatedStorage"),
        game:GetService("ReplicatedFirst"), workspace, game:GetService("Lighting"),
    }
    local before = #targets
    for _, r in ipairs(roots) do
        if r then
            local ok, kids = pcall(function() return r:GetDescendants() end)
            if ok then for _, d in ipairs(kids) do add(d, "arvore") end end
        end
    end
    log("varredura da arvore: +" .. (#targets - before))
    log("total de alvos: " .. #targets)

    if #targets == 0 then
        log("nada encontrado - entra num jogo de verdade antes de rodar (no menu nao ha scripts)")
        return
    end

    -- ---- listagem ----
    if type(TARGET) == "string" and TARGET == "" then
        local n = math.min(#targets, 80)
        log("--- primeiros " .. n .. " alvos ---")
        for i = 1, n do
            local t = targets[i]
            log(string.format("%-14s [%s] %s", t.inst.ClassName, t.origem, t.inst:GetFullName()))
        end
        log("preenche TARGET e roda de novo")
        return
    end

    -- ---- dump ----
    local function safeName(inst)
        local n = inst:GetFullName():gsub("[^%w_%-%.]", "_")
        if #n > 110 then n = n:sub(-110) end
        return n
    end

    local function dumpOne(inst)
        local name = safeName(inst)
        local got = false

        if F_bytecode then
            local ok, bc = pcall(F_bytecode, inst)
            if not ok then
                log("bytecode erro em " .. inst.Name .. ": " .. tostring(bc))
            elseif type(bc) ~= "string" or #bc == 0 then
                log("bytecode vazio em " .. inst.Name)
            else
                local path = OUT .. "/" .. name .. ".luac"
                local okW, errW = pcall(F_write, path, bc)
                log(okW and ("OK bytecode -> " .. path .. " (" .. #bc .. " bytes)")
                        or ("write falhou: " .. tostring(errW)))
                got = got or okW
            end
        else
            log("sem getscriptbytecode")
        end

        if F_decomp then
            local ok, src = pcall(F_decomp, inst)
            if not ok then
                log("decompile erro em " .. inst.Name .. ": " .. tostring(src))
            elseif type(src) ~= "string" or #src == 0 then
                log("decompile vazio em " .. inst.Name)
            else
                local path = OUT .. "/" .. name .. ".lua"
                local okW, errW = pcall(F_write, path, src)
                log(okW and ("OK fonte -> " .. path .. " (" .. #src .. " chars)")
                        or ("write falhou: " .. tostring(errW)))
                got = got or okW
            end
        else
            log("sem decompile")
        end

        if not got then log("nada saiu de " .. inst:GetFullName()) end
    end

    if type(TARGET) == "string" and TARGET == "*" then
        local n = 0
        for _, t in ipairs(targets) do
            local full = t.inst:GetFullName()
            local skip = false
            for _, pat in ipairs(SKIP) do
                if full:find(pat, 1, true) then
                    skip = true
                    break
                end
            end
            if not skip then
                n += 1
                if n > MAX_ALL then
                    log("parei no limite de " .. MAX_ALL)
                    break
                end
                dumpOne(t.inst)
                task.wait()
            end
        end
        log("fim - dumpados " .. n)
        return
    end

    local needles = {}
    if type(TARGET) == "table" then
        for _, n in ipairs(TARGET) do needles[#needles + 1] = tostring(n):lower() end
    else
        needles[1] = tostring(TARGET):lower()
    end
    local label = table.concat(needles, ", ")

    local matches = {}
    for _, t in ipairs(targets) do
        local full = t.inst:GetFullName():lower()
        local name = t.inst.Name:lower()
        for _, needle in ipairs(needles) do
            if name:find(needle, 1, true) or full:find(needle, 1, true) then
                matches[#matches + 1] = t
                break
            end
        end
    end

    if #matches == 0 then
        log("nenhum match pra: " .. label)
        log("dica: roda com TARGET = \"\" pra ver os nomes reais")
        return
    end

    log("procurando: " .. label)

    log("matches: " .. #matches)
    for i, t in ipairs(matches) do
        if i > MAX_ALL then
            log("parei no limite de " .. MAX_ALL)
            break
        end
        log("alvo: " .. t.inst:GetFullName())
        dumpOne(t.inst)
        task.wait()
    end
    log("fim")
end

local ok, err = pcall(main)
if not ok then log("ERRO FATAL: " .. tostring(err)) end
flush()
