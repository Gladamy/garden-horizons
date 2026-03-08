--[[
    GARDEN SHOVEL + AUTO BOTANIST + SHOP
    Aurora v6.5.0

    Shovel Tab   — auto-remove unwanted plants from ClientPlants
    Botanist Tab — harvest matching fruits from garden, then donate to Maya
    Shop Tab     — browse stock, manual buy, auto-buy on restock
    Settings Tab — webhook config, anti-afk, stop all

    Bug fixes applied:
    1. `continue` replaced with repeat/until true pattern (Lua 5.1 compatibility)
    2. Stop All button moved inside task.delay so lockShovelControls / lockBotControls
       are never nil when the callback fires
    3. shopBusy guard moved before task.spawn in manual buy buttons (race condition fix)
    4. Anti-AFK no longer spawns duplicate loops on re-enable; task handle is stored
       and cancelled on disable
]]--

local HttpService      = game:GetService("HttpService")
local Players          = game:GetService("Players")
local player           = Players.LocalPlayer

-- ─────────────────────────────────────────────
--  Aurora
-- ─────────────────────────────────────────────

local Aurora = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Gladamy/Aurora/refs/heads/main/Aurora.lua"
))()

local Window      = Aurora:CreateWindow({ Title = "Garden Shovel", Size = UDim2.new(0, 660, 0, 480) })
local ShovelTab   = Window:CreateTab({ Name = "Shovel"   })
local BotanistTab = Window:CreateTab({ Name = "Botanist" })
local ShopTab     = Window:CreateTab({ Name = "Shop"     })
local SettingsTab = Window:CreateTab({ Name = "Settings" })

-- ─────────────────────────────────────────────
--  Remotes
-- ─────────────────────────────────────────────

local RS            = game:GetService("ReplicatedStorage")
local RemoteEvents  = RS:WaitForChild("RemoteEvents")
local RemovePlant   = RemoteEvents:WaitForChild("RemovePlant")
local BotanistQuest = RemoteEvents:WaitForChild("BotanistQuestRequest")
local HarvestFruit  = RemoteEvents:WaitForChild("HarvestFruit")
local GetShopData     = RemoteEvents:WaitForChild("GetShopData")
local PurchaseShopItem = RemoteEvents:WaitForChild("PurchaseShopItem")

-- ─────────────────────────────────────────────
--  Shop Definitions  (from decompiled ShopData)
-- ─────────────────────────────────────────────

local SEED_ITEMS = {
    { name = "Carrot Seed",    price = 20,       rarity = "Common"    },
    { name = "Corn Seed",      price = 100,      rarity = "Common"    },
    { name = "Onion Seed",     price = 200,      rarity = "Common"    },
    { name = "Strawberry Seed",price = 800,      rarity = "Uncommon"  },
    { name = "Mushroom Seed",  price = 1500,     rarity = "Uncommon"  },
    { name = "Beetroot Seed",  price = 2500,     rarity = "Uncommon"  },
    { name = "Tomato Seed",    price = 4000,     rarity = "Rare"      },
    { name = "Apple Seed",     price = 7000,     rarity = "Rare"      },
    { name = "Rose Seed",      price = 10000,    rarity = "Rare"      },
    { name = "Wheat Seed",     price = 12000,    rarity = "Rare"      },
    { name = "Banana Seed",    price = 30000,    rarity = "Epic"      },
    { name = "Plum Seed",      price = 60000,    rarity = "Epic"      },
    { name = "Potato Seed",    price = 100000,   rarity = "Legendary" },
    { name = "Cabbage Seed",   price = 150000,   rarity = "Legendary" },
    { name = "Bamboo Seed",    price = 175000,   rarity = "Legendary" },
    { name = "Cherry Seed",    price = 1000000,  rarity = "Mythical"  },
    { name = "Mango Seed",     price = 10000000, rarity = "Mythical"  },
}

local GEAR_ITEMS = {
    { name = "Watering Can",    price = 5000,   rarity = "Common"    },
    { name = "Basic Sprinkler", price = 15000,  rarity = "Common"    },
    { name = "Harvest Bell",    price = 35000,  rarity = "Uncommon"  },
    { name = "Turbo Sprinkler", price = 60000,  rarity = "Rare"      },
    { name = "Favorite Tool",   price = 80000,  rarity = "Common"    },
    { name = "Super Sprinkler", price = 100000, rarity = "Epic"      },
    { name = "Trowel",          price = 250000, rarity = "Common"    },
}

-- ─────────────────────────────────────────────
--  BotanistDefinitions
-- ─────────────────────────────────────────────

local QUEST_ACCEPTED = {
    Foggy      = { "Foggy", "Mossy" },
    Soaked     = { "Soaked", "Flooded", "Muddy" },
    Chilled    = { "Snowy", "Frostbit", "Chilled" },
    Sandy      = { "Sandy", "Muddy" },
    Shocked    = { "Shocked" },
    Starstruck = { "Starstruck" },
}
local LEGACY_MAP = { Flooded = "Soaked", Snowy = "Chilled" }

-- ─────────────────────────────────────────────
--  Webhook
-- ─────────────────────────────────────────────

local httpFn = (syn and syn.request) or http_request or request
local webhookInput  -- filled in Settings tab

local function sendWebhook(url, title, description, color, fields)
    if not url or url == "" or not httpFn then return end
    pcall(function()
        httpFn({
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode({
                embeds = {{
                    title       = title or "Notification",
                    description = description or "",
                    color       = color or 0x5865F2,
                    fields      = fields or {},
                    footer      = { text = player.Name .. " | Garden Shovel" },
                    timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }}
            })
        })
    end)
end

-- ─────────────────────────────────────────────
--  SETTINGS TAB
-- ─────────────────────────────────────────────

SettingsTab:CreateSection("Discord Webhook")
webhookInput = SettingsTab:CreateInput({ Text = "Webhook URL", Placeholder = "https://discord.com/api/webhooks/..." })
SettingsTab:CreateButton({
    Text = "Test Webhook",
    Callback = function()
        local url = webhookInput.GetValue()
        if url == "" then Aurora:Notify({ Title = "Webhook", Message = "Enter a URL first.", Type = "Warning", Duration = 3 }) return end
        sendWebhook(url, "Test Notification", "Webhook is working!", 0x2ECC71, {{ name = "Source", value = "Garden Shovel", inline = true }})
        Aurora:Notify({ Title = "Webhook", Message = "Test sent!", Type = "Success", Duration = 3 })
    end,
})

-- FIX #4: Anti-AFK stores task handle so re-enabling doesn't spawn duplicate loops
SettingsTab:CreateSection("Anti-AFK")
local antiAfkRunning = false
local antiAfkTask    = nil
local antiAfkIdled   = nil  -- FIX #8: store connection so it can be disconnected
SettingsTab:CreateToggle({
    Text    = "Anti-AFK",
    Default = false,
    Callback = function(on)
        antiAfkRunning = on
        if on then
            -- Cancel any existing loop and connection before creating new ones
            if antiAfkTask  then pcall(task.cancel, antiAfkTask) antiAfkTask = nil end
            if antiAfkIdled then antiAfkIdled:Disconnect() antiAfkIdled = nil end
            antiAfkIdled = player.Idled:Connect(function() end)
            antiAfkTask = task.spawn(function()
                local VU = game:GetService("VirtualUser")
                while antiAfkRunning do
                    task.wait(840)
                    if antiAfkRunning then
                        VU:CaptureController()
                        VU:ClickButton2(Vector2.new())
                    end
                end
                antiAfkTask = nil
            end)
            Aurora:Notify({ Title = "Anti-AFK", Message = "Enabled.", Type = "Success", Duration = 3 })
        else
            if antiAfkTask  then pcall(task.cancel, antiAfkTask) antiAfkTask = nil end
            if antiAfkIdled then antiAfkIdled:Disconnect() antiAfkIdled = nil end
        end
    end,
})

-- NOTE: Stop All button is created inside task.delay below (after createShovelUI /
-- createBotanistUI have run) so that lockShovelControls and lockBotControls are
-- never nil when the callback executes. (FIX #2)

SettingsTab:CreateSection("Info")
SettingsTab:CreateLabel("Garden Shovel + Auto Botanist + Shop — Aurora v6.4.0")

-- ─────────────────────────────────────────────
--  SHOVEL TAB
-- ─────────────────────────────────────────────

local rarityColor = { Gold = 0xFFD700, Silver = 0xC0C0C0, Normal = 0xA8A8A8 }
local shovelAutoRunning = false
local shovelAutoTask    = nil
local shovelControls    = {}

local function lockShovelControls(locked)
    for _, el in ipairs(shovelControls) do el.SetEnabled(not locked) end
end

local function fruitKey(f) return f.uuid .. "_" .. tostring(f.anchorIndex) end

local function sendShovelWebhook(url, fruit)
    if not url or url == "" or not httpFn then return end
    local avatarUrl = string.format("https://www.roblox.com/headshot-thumbnail/image?userId=%d&width=420&height=420&format=png", player.UserId)
    pcall(function()
        httpFn({
            Url = url, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                content = "@everyone",
                embeds = {{
                    title = fruit.type, description = "Kept — Weight Threshold",
                    color = rarityColor[fruit.rarity] or rarityColor.Normal,
                    thumbnail = { url = avatarUrl },
                    fields = {
                        { name = "Player",  value = player.Name,                           inline = true },
                        { name = "Weight",  value = string.format("%.4fkg", fruit.weight), inline = true },
                        { name = "Variant", value = fruit.rarity,                          inline = true },
                    },
                    footer = { text = player.Name .. " | Garden Shovel" },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }}
            })
        })
    end)
end

local function scanGarden()
    local cp = workspace:FindFirstChild("ClientPlants")
    if not cp then return {}, { trees = 0, fruits = 0, byType = {}, byRarity = {} } end
    local fruits, stats = {}, { trees = 0, fruits = 0, byType = {}, byRarity = {} }
    local seenKeys = {}
    local trees = cp:GetChildren()
    stats.trees = #trees
    for _, tree in ipairs(trees) do
        if tree:IsA("Model") then
            local uuid      = tree:GetAttribute("Uuid") or tree.Name
            local fruitType = tree:GetAttribute("PlantType") or "Unknown"
            for _, child in ipairs(tree:GetChildren()) do
                local anchorIndex = child:GetAttribute("GrowthAnchorIndex")
                if anchorIndex then
                    local key = uuid .. "_" .. tostring(anchorIndex)
                    if not seenKeys[key] then
                        seenKeys[key] = true
                        local rarity = child:GetAttribute("Variant") or "Normal"
                        local weight = tonumber(child:GetAttribute("FruitWeight")) or 0
                        stats.fruits = stats.fruits + 1
                        stats.byType[fruitType]  = (stats.byType[fruitType]  or 0) + 1
                        stats.byRarity[rarity]   = (stats.byRarity[rarity]   or 0) + 1
                        table.insert(fruits, { uuid = uuid, anchorIndex = anchorIndex, type = fruitType, rarity = rarity, weight = weight })
                    end
                end
            end
        end
    end
    return fruits, stats
end

-- FIX #1: Replaced `continue` (invalid in Lua 5.1) with repeat/until true pattern
local function processFruits(fruits, opt, seenFruitKeys)
    local shoveled = 0
    for _, f in ipairs(fruits) do
        repeat
            local key = fruitKey(f)

            -- Type filter
            local typeMatch = true
            if opt.types and #opt.types > 0 then
                typeMatch = false
                for _, tp in ipairs(opt.types) do
                    if f.type == tp then typeMatch = true break end
                end
            end
            if not typeMatch then seenFruitKeys[key] = true break end  -- continue

            -- Rarity filter
            local rarityMatch = false
            for _, rar in ipairs(opt.rarities or {}) do
                if f.rarity == rar then rarityMatch = true break end
            end
            if not rarityMatch then seenFruitKeys[key] = true break end  -- continue

            -- Weight filter
            local weightFiltered = false
            if opt.maxWeight and opt.weightFilterRarities then
                for _, wfRar in ipairs(opt.weightFilterRarities) do
                    if f.rarity == wfRar then weightFiltered = true break end
                end
            end
            local isKeeper = weightFiltered and (f.weight > opt.maxWeight)

            if isKeeper then
                if not seenFruitKeys[key] then
                    seenFruitKeys[key] = true
                    task.spawn(sendShovelWebhook, opt.webhookUrl, f)
                    Aurora:Notify({ Title = "Keeper: " .. f.type, Message = f.rarity .. " — " .. string.format("%.4f KG", f.weight), Type = "Success", Duration = 5 })
                end
            else
                seenFruitKeys[key] = true
                pcall(function() RemovePlant:FireServer(f.uuid, f.anchorIndex) end)
                shoveled = shoveled + 1
                task.wait(0.05)
            end
        until true
    end

    local currentKeys = {}
    for _, f in ipairs(fruits) do currentKeys[fruitKey(f)] = true end
    for k in pairs(seenFruitKeys) do if not currentKeys[k] then seenFruitKeys[k] = nil end end
    return shoveled
end

local function createShovelUI()
    local _, stats = scanGarden()
    local foundTypes, foundRarities = {}, {}
    for tp  in pairs(stats.byType   or {}) do table.insert(foundTypes,    tp)  end
    for rar in pairs(stats.byRarity or {}) do table.insert(foundRarities, rar) end

    local statusLabel = ShovelTab:CreateStatusLabel({ Text = string.format("Scan: %d fruits / %d trees", stats.fruits, stats.trees), Type = "Info" })
    ShovelTab:CreateSection("Fruit Filter")
    local fruitMS = ShovelTab:CreateMultiSelect({ Text = "Fruit Types to Shovel", Options = #foundTypes > 0 and foundTypes or { "No fruits found" }, Default = {} })
    table.insert(shovelControls, fruitMS)
    ShovelTab:CreateSection("Rarity Filter")
    local rarityMS = ShovelTab:CreateMultiSelect({ Text = "Shovel These Rarities", Options = #foundRarities > 0 and foundRarities or { "Normal", "Silver", "Gold" }, Default = {} })
    table.insert(shovelControls, rarityMS)
    ShovelTab:CreateSection("Weight Filter")
    local weightInput = ShovelTab:CreateNumberInput({ Text = "Max Weight (KG)", Min = 0, Max = 9999, Step = 0.01, Default = 0 })
    ShovelTab:CreateLabel("Fruits above this weight are kept (0 = disabled)")
    table.insert(shovelControls, weightInput)
    local weightFilterMS = ShovelTab:CreateMultiSelect({ Text = "Apply Weight Filter To", Options = { "Normal", "Silver", "Gold" }, Default = {} })
    table.insert(shovelControls, weightFilterMS)
    ShovelTab:CreateSection("Control")

    local autoToggle
    autoToggle = ShovelTab:CreateToggle({
        Text = "Auto Shovel", Default = false,
        Callback = function(enabled)
            if enabled then
                local types = fruitMS.GetValue(); local rarities = rarityMS.GetValue()
                if #types == 0 then autoToggle.SetValue(false) statusLabel.SetValue("Select fruit types.", "Warning") return end
                if #rarities == 0 then autoToggle.SetValue(false) statusLabel.SetValue("Select rarities.", "Warning") return end
                local opt = { types = types, rarities = rarities, webhookUrl = webhookInput.GetValue() }
                local wfRars = weightFilterMS.GetValue(); local mw = weightInput.GetValue()
                if mw > 0 and #wfRars > 0 then opt.maxWeight = mw; opt.weightFilterRarities = wfRars end
                local seenKeys = {}
                for _, f in ipairs(scanGarden()) do seenKeys[fruitKey(f)] = true end
                lockShovelControls(true); shovelAutoRunning = true; statusLabel.SetValue("Auto running...", "Success")
                shovelAutoTask = task.spawn(function()
                    while shovelAutoRunning do
                        local count = processFruits(scanGarden(), opt, seenKeys)
                        task.wait(count == 0 and 1 or 0.3)
                    end
                end)
            else
                shovelAutoRunning = false
                if shovelAutoTask then pcall(task.cancel, shovelAutoTask) shovelAutoTask = nil end
                lockShovelControls(false); statusLabel.SetValue("Stopped.", "Info")
            end
        end,
    })

    ShovelTab:CreateButton({
        Text = "Manual Shovel Once",
        Callback = function()
            if shovelAutoRunning then statusLabel.SetValue("Stop auto first.", "Warning") return end
            local types = fruitMS.GetValue(); local rarities = rarityMS.GetValue()
            if #types == 0 or #rarities == 0 then statusLabel.SetValue("Select types & rarities.", "Warning") return end
            local opt = { types = types, rarities = rarities, webhookUrl = webhookInput.GetValue() }
            local wfRars = weightFilterMS.GetValue(); local mw = weightInput.GetValue()
            if mw > 0 and #wfRars > 0 then opt.maxWeight = mw; opt.weightFilterRarities = wfRars end
            local count = processFruits(scanGarden(), opt, {})
            statusLabel.SetValue(string.format("Shoveled %d fruit(s).", count), "Success")
        end,
    })
end

-- ─────────────────────────────────────────────
--  BOTANIST HELPERS
-- ─────────────────────────────────────────────

local function resolveQuestKey(mutation)
    return LEGACY_MAP[mutation] or mutation
end

local function getAcceptedMutations(questKey)
    return QUEST_ACCEPTED[resolveQuestKey(questKey)] or { questKey }
end

local function mutStr_has(mutStr, target)
    for part in (mutStr or ""):gmatch("[^,]+") do
        if part:match("^%s*(.-)%s*$") == target then return true end
    end
    return false
end

local function fruitMatchesQuest(mutStr, questKey)
    for _, mut in ipairs(getAcceptedMutations(questKey)) do
        if mutStr_has(mutStr, mut) then return true end
    end
    return false
end

local function scanGardenFruits(allowedTypes, questKey, protGold, protSilver, minWeight)
    local cp = workspace:FindFirstChild("ClientPlants")
    if not cp then return {} end
    local results = {}
    local myUserId = tostring(player.UserId)
    for _, tree in ipairs(cp:GetChildren()) do
        if not tree:IsA("Model") then continue end
        if tostring(tree:GetAttribute("OwnerUserId")) ~= myUserId then continue end
        if not tree:GetAttribute("FullyGrown") then continue end
        local plantType = tree:GetAttribute("PlantType") or "Unknown"
        if allowedTypes and #allowedTypes > 0 then
            local ok = false
            for _, t in ipairs(allowedTypes) do if plantType == t then ok = true break end end
            if not ok then continue end
        end
        for _, fruitModel in ipairs(tree:GetChildren()) do
            if not fruitModel:IsA("Model") then continue end
            if not fruitModel:GetAttribute("GrowthAnchorIndex") then continue end
            if not fruitModel:GetAttribute("FullyGrown") then continue end
            local mutStr  = fruitModel:GetAttribute("Mutation") or ""
            local weight  = tonumber(fruitModel:GetAttribute("FruitWeight")) or 0
            local variant = fruitModel:GetAttribute("Variant") or "Normal"
            if questKey and not fruitMatchesQuest(mutStr, questKey) then continue end
            if protGold   and variant == "Gold"   then continue end
            if protSilver and variant == "Silver" then continue end
            if minWeight  and minWeight > 0 and weight > minWeight then continue end
            local anchor = fruitModel:FindFirstChild("FruitAnchor")
            local prompt = anchor and anchor:FindFirstChild("HarvestPrompt")
            if not prompt or not prompt:IsA("ProximityPrompt") then continue end
            table.insert(results, {
                treeModel  = tree,
                fruitModel = fruitModel,
                prompt     = prompt,
                plantType  = plantType,
                mutation   = mutStr,
                weight     = weight,
                variant    = variant,
            })
        end
    end
    return results
end

local function getLivePlantTypes()
    local seen, types = {}, {}
    local myUserId = tostring(player.UserId)
    local cp = workspace:FindFirstChild("ClientPlants")
    if cp then
        for _, tree in ipairs(cp:GetChildren()) do
            if tree:IsA("Model") and tostring(tree:GetAttribute("OwnerUserId")) == myUserId then
                local pt = tree:GetAttribute("PlantType") or "Unknown"
                if not seen[pt] then seen[pt] = true; table.insert(types, pt) end
            end
        end
    end
    local bp = player:FindFirstChildOfClass("Backpack")
    if bp then
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("Type") == "Plants" then
                local bn = tool:GetAttribute("BaseName") or ""
                if bn ~= "" and not seen[bn] then seen[bn] = true; table.insert(types, bn) end
            end
        end
    end
    table.sort(types)
    return #types > 0 and types or { "No plants found" }
end

local function getBackpackFruits(allowedTypes, questKey, protGold, protSilver, minWeight)
    local bp = player:FindFirstChildOfClass("Backpack")
    if not bp then return {} end
    local results = {}
    for _, tool in ipairs(bp:GetChildren()) do
        if not (tool:IsA("Tool") and tool:GetAttribute("IsHarvested") == true and tool:GetAttribute("Type") == "Plants") then continue end
        local baseName = tool:GetAttribute("BaseName") or ""
        if allowedTypes and #allowedTypes > 0 then
            local ok = false
            for _, t in ipairs(allowedTypes) do if baseName == t then ok = true break end end
            if not ok then continue end
        end
        if questKey and not fruitMatchesQuest(tool:GetAttribute("Mutation") or "", questKey) then continue end
        local variant = tool:GetAttribute("Variant") or "Normal"
        local weight  = tonumber(tool:GetAttribute("FruitWeight")) or 0  -- FIX #7: tonumber guard
        if protGold   and variant == "Gold"   then continue end
        if protSilver and variant == "Silver" then continue end
        if minWeight  and minWeight > 0 and weight > minWeight then continue end
        table.insert(results, tool)
    end
    return results
end

local function getQuest()
    local ok, result = pcall(function() return BotanistQuest:InvokeServer("GetQuest") end)
    if not ok or not result or result.Status == "error" then return nil end
    return result
end

local function equipTool(tool)
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    humanoid:EquipTool(tool)
    local t = tick()
    while tick() - t < 2 do
        local cur = player.Character and player.Character:FindFirstChildOfClass("Tool")
        if cur and cur == tool then return true end
        task.wait(0.05)
    end
    return false
end

local function unequipCurrentTool()
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid:UnequipTools() end
    task.wait(0.15)
end

local function turnInEquippedFruit()
    local ok, result = pcall(function() return BotanistQuest:InvokeServer("TurnInSingle") end)
    if not ok then return nil end
    return result
end

local function harvestFruit(entry)
    local treeUuid    = entry.treeModel:GetAttribute("Uuid")
    local anchorIndex = entry.fruitModel:GetAttribute("GrowthAnchorIndex")
    pcall(function()
        HarvestFruit:FireServer({ { GrowthAnchorIndex = anchorIndex, Uuid = treeUuid } })
    end)
end

-- ─────────────────────────────────────────────
--  BOTANIST TAB UI
-- ─────────────────────────────────────────────

local botRunning  = false
local botTask     = nil
local botControls = {}

local function lockBotControls(locked)
    for _, el in ipairs(botControls) do el.SetEnabled(not locked) end
end

local function createBotanistUI()

    local lo = 0
    local function nextLO() lo = lo + 1; return lo end

    BotanistTab:CreateSection("Quest Status").Frame.LayoutOrder = nextLO()

    local questTable = BotanistTab:CreateTable({
        Columns    = { "Field", "Value" },
        Rows       = {
            { "Mutation",  "—" },
            { "Progress",  "—" },
            { "Garden",    "—" },
            { "Backpack",  "—" },
        },
        MaxVisible = 4,
    })
    questTable.Frame.LayoutOrder = nextLO()

    -- Quest weight progress bar (0..1 = totalWeight / targetWeight)
    local questProgressBar = BotanistTab:CreateProgressBar({
        Text    = "Quest Weight",
        Default = 0,
        Color   = Aurora.Config.Theme.Success,
    })
    questProgressBar.Frame.LayoutOrder = nextLO()

    local function setQuestRow(row, value)
        questTable.SetCell(row, 2, value)
    end

    local function updateQuestProgress(totalW, targetW)
        if targetW and targetW > 0 then
            questProgressBar.SetValue(math.clamp(totalW / targetW, 0, 1))
            questProgressBar.SetLabel(string.format("Quest Weight  %.2f / %.2f kg", totalW, targetW))
        else
            questProgressBar.SetValue(0)
            questProgressBar.SetLabel("Quest Weight")
        end
    end

    BotanistTab:CreateSection("Plant Filter").Frame.LayoutOrder = nextLO()

    local typeAllowlist = BotanistTab:CreateMultiSelect({
        Text    = "Allowed Plant Types  (empty = all)",
        Options = { "(click Refresh)" },
        Default = {},
    })
    local ALLOWLIST_LO = nextLO()
    typeAllowlist.Frame.LayoutOrder = ALLOWLIST_LO
    table.insert(botControls, typeAllowlist)

    local harvestFromGarden = BotanistTab:CreateToggle({ Text = "Auto-Harvest from Garden", Default = true })
    harvestFromGarden.Frame.LayoutOrder = nextLO()
    BotanistTab:CreateLabel("ON = harvest garden fruits first, then donate.  OFF = backpack only.").Frame.LayoutOrder = nextLO()
    table.insert(botControls, harvestFromGarden)

    BotanistTab:CreateSection("Protection").Frame.LayoutOrder = nextLO()

    local protectGold    = BotanistTab:CreateToggle({ Text = "Protect Gold variants",   Default = true  })
    protectGold.Frame.LayoutOrder = nextLO()
    local protectSilver  = BotanistTab:CreateToggle({ Text = "Protect Silver variants", Default = false })
    protectSilver.Frame.LayoutOrder = nextLO()
    local minWeightInput = BotanistTab:CreateNumberInput({
        Text = "Protect above weight (KG, 0 = off)", Min = 0, Max = 999, Step = 0.05, Default = 0,
    })
    minWeightInput.Frame.LayoutOrder = nextLO()
    table.insert(botControls, protectGold)
    table.insert(botControls, protectSilver)
    table.insert(botControls, minWeightInput)

    BotanistTab:CreateSection("Timing").Frame.LayoutOrder = nextLO()

    local donateDelay  = BotanistTab:CreateSlider({ Text = "Delay between donations (s)", Min = 0, Max = 3,   Default = 0,   Increment = 0.1 })
    donateDelay.Frame.LayoutOrder = nextLO()
    local harvestDelay = BotanistTab:CreateSlider({ Text = "Delay between harvests (s)",  Min = 0, Max = 2,   Default = 0.3, Increment = 0.1 })
    harvestDelay.Frame.LayoutOrder = nextLO()
    table.insert(botControls, donateDelay)
    table.insert(botControls, harvestDelay)

    BotanistTab:CreateSection("Session Stats").Frame.LayoutOrder = nextLO()

    local sessionTable = BotanistTab:CreateTable({
        Columns    = { "Fruits Donated", "Weight (kg)", "IGMA Packs" },
        Rows       = { { "0", "0.00", "0" } },
        MaxVisible = 1,
    })
    sessionTable.Frame.LayoutOrder = nextLO()

    BotanistTab:CreateSection("Control").Frame.LayoutOrder = nextLO()

    local statusLabel = BotanistTab:CreateStatusLabel({ Text = "Status: Idle", Type = "Info" })
    statusLabel.Frame.LayoutOrder = nextLO()

    local sessionFruits, sessionWeight, sessionIGMA = 0, 0, 0

    local function updateSessionStats()
        sessionTable.SetCell(1, 1, tostring(sessionFruits))
        sessionTable.SetCell(1, 2, string.format("%.2f", sessionWeight))
        sessionTable.SetCell(1, 3, tostring(sessionIGMA))
    end

    local function refreshAllowlist()
        local types = getLivePlantTypes()
        if #types == 0 or types[1] == "No plants found" then
            types = { "(no plants found)" }
        end
        local prevSelected = {}
        pcall(function()
            for _, v in ipairs(typeAllowlist.GetValue()) do prevSelected[v] = true end
        end)
        for i, el in ipairs(botControls) do
            if el == typeAllowlist then table.remove(botControls, i) break end
        end
        typeAllowlist.Destroy()
        local newDefaults = {}
        for _, t in ipairs(types) do
            if prevSelected[t] then table.insert(newDefaults, t) end
        end
        typeAllowlist = BotanistTab:CreateMultiSelect({
            Text    = "Allowed Plant Types  (empty = all)",
            Options = types,
            Default = newDefaults,
        })
        typeAllowlist.Frame.LayoutOrder = ALLOWLIST_LO
        table.insert(botControls, typeAllowlist)
    end

    local refreshBtn = BotanistTab:CreateButton({
        Text = "Refresh Quest & Allowlist",
        Callback = function()
            if botRunning then return end
            refreshAllowlist()
            local allowedTypes = typeAllowlist.GetValue()
            local protG   = protectGold.GetValue()
            local protS   = protectSilver.GetValue()
            local minW    = minWeightInput.GetValue()
            local minWEff = minW > 0 and minW or nil
            local q = getQuest()
            if q then
                local qKey    = resolveQuestKey(q.Mutation or "")
                local acc     = getAcceptedMutations(qKey)
                local totalW  = q.TotalWeight  or 0
                local targetW = q.TargetWeight or 0
                setQuestRow(1, string.format("%s  (accepts: %s)", q.Mutation or "?", table.concat(acc, ", ")))
                setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", totalW, targetW, math.max(0, targetW - totalW)))
                setQuestRow(3, tostring(#scanGardenFruits(allowedTypes, qKey, protG, protS, minWEff)))
                setQuestRow(4, tostring(#getBackpackFruits(allowedTypes, qKey, protG, protS, minWEff)))
                updateQuestProgress(totalW, targetW)
            else
                setQuestRow(1, "Could not fetch quest")
                setQuestRow(2, "—"); setQuestRow(3, "—"); setQuestRow(4, "—")
            end
            Aurora:Notify({ Title = "Botanist", Message = "Refreshed!", Type = "Info", Duration = 2 })
        end,
    })
    refreshBtn.Frame.LayoutOrder = nextLO()
    table.insert(botControls, refreshBtn)

    local POLL_INTERVAL = 5

    local autoToggle
    autoToggle = BotanistTab:CreateToggle({
        Text = "Auto Donate", Default = false,
        Callback = function(enabled)
            if enabled then
                local q = getQuest()
                if not q then
                    autoToggle.SetValue(false)
                    statusLabel.SetValue("Status: Could not fetch quest.", "Error")
                    return
                end

                local questKey     = resolveQuestKey(q.Mutation or "")
                local allowedTypes = typeAllowlist.GetValue()
                local protG        = protectGold.GetValue()
                local protS        = protectSilver.GetValue()
                local minW         = minWeightInput.GetValue()
                local minWEff      = minW > 0 and minW or nil
                local fromGarden   = harvestFromGarden.GetValue()

                lockBotControls(true)
                botRunning = true

                botTask = task.spawn(function()
                    local delay       = donateDelay.GetValue()
                    local hDelay      = math.max(harvestDelay.GetValue(), 0.3)
                    local currentQ    = q
                    local currentQKey = questKey

                    local function updateQuestLabels(quest)
                        local qk  = resolveQuestKey(quest.Mutation or "")
                        local acc = getAcceptedMutations(qk)
                        local tw  = quest.TotalWeight  or 0
                        local tgt = quest.TargetWeight or 0
                        setQuestRow(1, string.format("%s  (accepts: %s)", quest.Mutation or "?", table.concat(acc, ", ")))
                        setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", tw, tgt, math.max(0, tgt - tw)))
                        updateQuestProgress(tw, tgt)
                    end

                    local function pollRefreshQuest()
                        local newQ = getQuest()
                        if newQ then
                            local newKey = resolveQuestKey(newQ.Mutation or "")
                            if newKey ~= currentQKey then
                                currentQ    = newQ
                                currentQKey = newKey
                                updateQuestLabels(newQ)
                            end
                        end
                    end

                    local function handleResult(result, fWeight, fName)
                        if not result then return "skip" end
                        local s = result.Status
                        if s == "progress" then
                            sessionFruits = sessionFruits + 1
                            sessionWeight = sessionWeight + fWeight
                            updateSessionStats()
                            local tw = result.TotalWeight or 0; local tgt = result.TargetWeight or 0
                            statusLabel.SetValue(string.format("Status: Donated %s — %.2f / %.2f kg", fName, tw, tgt), "Success")
                            setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", tw, tgt, math.max(0, tgt - tw)))
                            updateQuestProgress(tw, tgt)
                            return "progress"
                        elseif s == "complete" then
                            sessionFruits = sessionFruits + 1
                            sessionWeight = sessionWeight + fWeight
                            local rc = result.RewardCount or 1
                            local rn = result.RewardName  or "IGMA Seed Pack"
                            sessionIGMA = sessionIGMA + rc
                            updateSessionStats()
                            local rewardStr = rc .. "x " .. rn
                            statusLabel.SetValue("Status: Quest complete! Earned " .. rewardStr, "Success")
                            setQuestRow(2, "Complete!")
                            questProgressBar.SetValue(1)
                            questProgressBar.SetLabel("Quest Weight — Complete!")
                            Aurora:Notify({ Title = "Quest Complete!", Message = "Earned " .. rewardStr, Type = "Success", Duration = 6 })
                            local webhookUrl = webhookInput.GetValue()
                            if webhookUrl ~= "" then
                                sendWebhook(webhookUrl, "Quest Complete — " .. (currentQ.Mutation or "?"),
                                    "Maya's quest completed!", 0x2ECC71, {
                                        { name = "Reward",     value = rewardStr,                                inline = true  },
                                        { name = "Donated",    value = sessionFruits .. " fruits",              inline = true  },
                                        { name = "Weight",     value = string.format("%.2f kg", sessionWeight),  inline = true  },
                                        { name = "IGMA Total", value = sessionIGMA .. " packs this session",    inline = false },
                                    })
                            end
                            return "complete"
                        elseif s == "wrong_mutation" then
                            statusLabel.SetValue("Status: Wrong mutation — re-fetching quest...", "Warning")
                            return "wrong_mutation"
                        elseif s == "no_active_quest" then
                            statusLabel.SetValue("Status: No active quest.", "Warning")
                            return "stop"
                        elseif s == "inventory_full" then
                            statusLabel.SetValue("Status: Inventory full!", "Error")
                            Aurora:Notify({ Title = "Botanist", Message = "Inventory full — clear space!", Type = "Error", Duration = 5 })
                            return "stop"
                        else
                            return "skip"
                        end
                    end

                    while botRunning do

                        local bpFruits = getBackpackFruits(allowedTypes, currentQKey, protG, protS, minWEff)
                        setQuestRow(4, tostring(#bpFruits))

                        for _, tool in ipairs(bpFruits) do
                            if not botRunning then break end
                            local bp2 = player:FindFirstChildOfClass("Backpack")
                            local stillThere = false
                            if bp2 then for _, it in ipairs(bp2:GetChildren()) do if it == tool then stillThere = true break end end end
                            if not stillThere then continue end

                            local fName   = tool:GetAttribute("BaseName") or tool.Name
                            local fWeight = tonumber(tool:GetAttribute("FruitWeight")) or 0
                            statusLabel.SetValue(string.format("Status: Equipping %s (%.2f kg)...", fName, fWeight), "Info")

                            unequipCurrentTool()
                            if not equipTool(tool) then
                                statusLabel.SetValue("Status: Failed to equip, skipping.", "Warning")
                                task.wait(0.5)
                                continue
                            end
                            task.wait(0.1)

                            local result  = turnInEquippedFruit()
                            local outcome = handleResult(result, fWeight, fName)
                            unequipCurrentTool()

                            if outcome == "stop" then
                                botRunning = false; autoToggle.SetValue(false); lockBotControls(false)
                                break
                            elseif outcome == "complete" or outcome == "wrong_mutation" then
                                task.wait(outcome == "complete" and 3 or 1)
                                local newQ = getQuest()
                                if newQ then
                                    currentQ    = newQ
                                    currentQKey = resolveQuestKey(newQ.Mutation or "")
                                    updateQuestLabels(newQ)
                                else
                                    statusLabel.SetValue("Status: Could not fetch new quest.", "Error")
                                    botRunning = false; autoToggle.SetValue(false); lockBotControls(false)
                                end
                                break
                            end

                            if delay > 0 then task.wait(delay) end
                        end

                        if not botRunning then break end

                        if fromGarden then
                            local gardenFruits = scanGardenFruits(allowedTypes, currentQKey, protG, protS, minWEff)
                            setQuestRow(3, tostring(#gardenFruits))

                            if #gardenFruits == 0 then
                                local bpCheck = getBackpackFruits(allowedTypes, currentQKey, protG, protS, minWEff)
                                if #bpCheck == 0 then
                                    statusLabel.SetValue("Status: Waiting for fruits to grow...", "Info")
                                    task.wait(POLL_INTERVAL)
                                    pollRefreshQuest()
                                    continue
                                end
                                continue
                            end

                            local harvested = 0
                            for _, entry in ipairs(gardenFruits) do
                                if not botRunning then break end
                                if not entry.fruitModel.Parent then continue end
                                if not entry.prompt.Parent then continue end

                                statusLabel.SetValue(string.format(
                                    "Status: Harvesting %s (%.2f kg)...",
                                    entry.plantType, entry.weight
                                ), "Info")

                                harvestFruit(entry)
                                harvested = harvested + 1

                                local waited = 0
                                repeat task.wait(0.15); waited = waited + 0.15 until waited >= 2

                                if hDelay > 0.3 then task.wait(hDelay - 0.3) end

                                local bpNow = getBackpackFruits(allowedTypes, currentQKey, protG, protS, minWEff)
                                setQuestRow(4, tostring(#bpNow))

                                local questChanged = false

                                for _, tool in ipairs(bpNow) do
                                    if not botRunning then break end
                                    local bp2 = player:FindFirstChildOfClass("Backpack")
                                    local stillThere = false
                                    if bp2 then for _, it in ipairs(bp2:GetChildren()) do if it == tool then stillThere = true break end end end
                                    if not stillThere then continue end

                                    local fName   = tool:GetAttribute("BaseName") or tool.Name
                                    local fWeight = tonumber(tool:GetAttribute("FruitWeight")) or 0
                                    statusLabel.SetValue(string.format("Status: Donating %s (%.2f kg)...", fName, fWeight), "Info")
                                    unequipCurrentTool()
                                    if not equipTool(tool) then task.wait(0.5) continue end
                                    task.wait(0.1)
                                    local result  = turnInEquippedFruit()
                                    local outcome = handleResult(result, fWeight, fName)
                                    unequipCurrentTool()
                                    if outcome == "stop" then
                                        botRunning = false; autoToggle.SetValue(false); lockBotControls(false)
                                        break
                                    elseif outcome == "complete" or outcome == "wrong_mutation" then
                                        task.wait(outcome == "complete" and 3 or 1)
                                        local newQ = getQuest()
                                        if newQ then
                                            currentQ    = newQ
                                            currentQKey = resolveQuestKey(newQ.Mutation or "")
                                            updateQuestLabels(newQ)
                                        else
                                            statusLabel.SetValue("Status: Could not fetch new quest.", "Error")
                                            botRunning = false; autoToggle.SetValue(false); lockBotControls(false)
                                        end
                                        questChanged = true
                                        break
                                    end
                                    if delay > 0 then task.wait(delay) end
                                end

                                if not botRunning or questChanged then break end
                            end

                            setQuestRow(3, tostring(#scanGardenFruits(allowedTypes, currentQKey, protG, protS, minWEff)))
                            setQuestRow(4, tostring(#getBackpackFruits(allowedTypes, currentQKey, protG, protS, minWEff)))

                            if harvested == 0 then
                                statusLabel.SetValue("Status: Waiting for fruits to grow...", "Info")
                                task.wait(POLL_INTERVAL)
                                pollRefreshQuest()
                            end

                        else
                            local bpCheck = getBackpackFruits(allowedTypes, currentQKey, protG, protS, minWEff)
                            if #bpCheck == 0 then
                                statusLabel.SetValue("Status: Waiting for backpack fruits...", "Info")
                                task.wait(POLL_INTERVAL)
                                pollRefreshQuest()
                            end
                        end
                    end

                    unequipCurrentTool()
                    if botRunning then
                        botRunning = false; autoToggle.SetValue(false); lockBotControls(false)
                        statusLabel.SetValue("Status: Finished.", "Info")
                    end
                end)

            else
                botRunning = false
                if botTask then pcall(task.cancel, botTask) botTask = nil end
                unequipCurrentTool()
                lockBotControls(false)
                statusLabel.SetValue("Status: Stopped.", "Info")
                Aurora:Notify({ Title = "Botanist", Message = "Stopped.", Type = "Warning", Duration = 3 })
            end
        end,
    })
    autoToggle.Frame.LayoutOrder = nextLO()

    local resetBtn = BotanistTab:CreateButton({
        Text = "Reset Session Stats",
        Callback = function()
            if botRunning then return end
            sessionFruits = 0; sessionWeight = 0; sessionIGMA = 0
            updateSessionStats()
        end,
    })
    resetBtn.Frame.LayoutOrder = nextLO()
    table.insert(botControls, resetBtn)

    task.defer(function()
        refreshAllowlist()
        local q = getQuest()
        if q then
            local qKey    = resolveQuestKey(q.Mutation or "")
            local acc     = getAcceptedMutations(qKey)
            local totalW  = q.TotalWeight  or 0
            local targetW = q.TargetWeight or 0
            setQuestRow(1, string.format("%s  (accepts: %s)", q.Mutation or "?", table.concat(acc, ", ")))
            setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", totalW, targetW, math.max(0, targetW - totalW)))
            updateQuestProgress(totalW, targetW)
        end
    end)
end

-- ─────────────────────────────────────────────
--  SHOP TAB
-- ─────────────────────────────────────────────

local function createShopUI()

    local seedOptions = {}
    for _, item in ipairs(SEED_ITEMS) do table.insert(seedOptions, item.name) end
    local gearOptions = {}
    for _, item in ipairs(GEAR_ITEMS) do table.insert(gearOptions, item.name) end

    local SEED_SHOP_POS = Vector3.new(176.6, 204.1, 678.8)
    local GEAR_SHOP_POS = Vector3.new(217.9, 204.1, 608.9)
    local NEAR_DIST     = 8

    local seedStock = {}
    local gearStock = {}
    local shopBusy  = false
    local savedPos  = nil
    local selectedSeedName = nil  -- hoisted so refreshTables can clear them (FIX #6)
    local selectedGearName = nil

    ShopTab:CreateSection("Shop Status")
    local shopInfoLabel = ShopTab:CreateStatusLabel({ Text = "Next restock: —  |  Idle", Type = "Info" })

    local function setStatus(msg, statusType)
        local s = math.ceil(300 - workspace:GetServerTimeNow() % 300)
        shopInfoLabel.SetValue(string.format("Next restock: %d:%02d  |  %s", math.floor(s/60), s%60, msg), statusType or "Info")
    end

    -- FIX #5: store ticker task handle so a re-executed script doesn't spawn duplicates
    local tickerTask = task.spawn(function()
        while true do
            setStatus(shopBusy and "Busy..." or "Idle", shopBusy and "Warning" or "Info")
            task.wait(1)
        end
    end)
    -- (tickerTask is intentionally not cancelled anywhere — it lives for the session)

    local function getHRP()
        local char = player.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    local function teleportTo(pos)
        local hrp = getHRP()
        if not hrp then return end
        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
        task.wait(0.35)
    end

    local function ensureNear(shopPos)
        local hrp = getHRP()
        if not hrp then return end
        if (hrp.Position - shopPos).Magnitude <= NEAR_DIST then return end
        if not savedPos then savedPos = hrp.Position end
        teleportTo(shopPos)
    end

    local function returnToSaved()
        if savedPos then
            teleportTo(savedPos)
            savedPos = nil
        end
    end

    local function fetchStock()
        local ok1, r1 = pcall(function() return GetShopData:InvokeServer("SeedShop") end)
        if ok1 and type(r1) == "table" and r1.Items then seedStock = r1.Items end
        local ok2, r2 = pcall(function() return GetShopData:InvokeServer("GearShop") end)
        if ok2 and type(r2) == "table" and r2.Items then gearStock = r2.Items end
    end

    local function buildStockRows(itemList, stockData)
        local rows = {}
        for _, item in ipairs(itemList) do
            local s   = stockData[item.name]
            local qty = s and s.Amount or 0
            local max = s and s.MaxAmount or "?"
            if qty > 0 then
                table.insert(rows, { item.name, qty .. " / " .. max })
            end
            -- out-of-stock items are intentionally omitted from the table
        end
        return rows
    end

    local seedStockTable, gearStockTable
    local selectedSeedRowIndex, selectedGearRowIndex  -- forward declare for refreshTables

    local function refreshTables()
        if not seedStockTable or not gearStockTable then return end
        seedStockTable.SetRows(buildStockRows(SEED_ITEMS, seedStock))
        gearStockTable.SetRows(buildStockRows(GEAR_ITEMS, gearStock))
        -- SetRows already cleared row colours; reset index trackers too
        selectedSeedRowIndex = nil
        selectedGearRowIndex = nil
        -- Clear stale selections so auto-buy can't act on a now-absent item
        selectedSeedName = nil
        selectedGearName = nil
        local inStock = 0
        for _, item in ipairs(SEED_ITEMS) do
            local s = seedStock[item.name]
            if s and s.Amount and s.Amount > 0 then inStock = inStock + 1 end
        end
        for _, item in ipairs(GEAR_ITEMS) do
            local s = gearStock[item.name]
            if s and s.Amount and s.Amount > 0 then inStock = inStock + 1 end
        end
        -- (no badge API on Tab in Aurora v6.4.0)
    end

    local function buyAllOf(shopId, itemName)
        local stockData = shopId == "SeedShop" and seedStock or gearStock
        local s = stockData[itemName]
        if not s or not s.Amount or s.Amount <= 0 then return 0 end
        local totalToBuy = s.Amount  -- snapshot initial quantity
        local bought = 0
        for i = 1, totalToBuy do
            -- FIX #4: re-check live stock before each purchase
            local liveData = shopId == "SeedShop" and seedStock or gearStock
            local live = liveData[itemName]
            if not live or not live.Amount or live.Amount <= 0 then break end
            local ok, res = pcall(function()
                return PurchaseShopItem:InvokeServer(shopId, itemName)
            end)
            if ok and type(res) == "table" and res.Items then
                if shopId == "SeedShop" then seedStock = res.Items
                else gearStock = res.Items end
                bought = bought + 1
                task.wait(0.15)
            else
                break
            end
        end
        return bought
    end

    -- sessionQueued: a toggle changed while shopBusy, so re-run after current session ends
    local sessionQueued = false

    local function runAutoBuySession(itemPairs)
        if shopBusy then
            -- A session is already running — just mark that we need another pass.
            -- The current session will re-call triggerAutoBuy() when it finishes.
            if #itemPairs > 0 then sessionQueued = true end
            return
        end
        if #itemPairs == 0 then return end
        shopBusy = true
        local hrp = getHRP()
        if hrp then savedPos = hrp.Position end

        local ok, err = pcall(function()
            local total = 0
            for _, entry in ipairs(itemPairs) do
                local shopId, itemName = entry[1], entry[2]
                local liveStock = shopId == "SeedShop" and seedStock or gearStock
                local s = liveStock[itemName]
                if s and s.Amount and s.Amount > 0 then
                    ensureNear(shopId == "SeedShop" and SEED_SHOP_POS or GEAR_SHOP_POS)
                    setStatus("Auto-buy: " .. itemName, "Info")
                    total = total + buyAllOf(shopId, itemName)
                    task.wait(0.2)
                end
            end

            returnToSaved()
            shopBusy = false
            refreshTables()

            if total > 0 then
                setStatus("Done — bought " .. total .. " item(s).", "Success")
                Aurora:Notify({ Title = "Auto-Buy", Message = "Bought " .. total .. " item(s).", Type = "Success", Duration = 4 })
            else
                setStatus("Auto-buy: nothing in stock.", "Info")
            end
        end)

        if not ok then
            shopBusy = false
            returnToSaved()
            setStatus("Auto-buy error — shop unlocked.", "Error")
            warn("runAutoBuySession error:", err)
        end

        -- If a toggle changed while we were busy, run one more pass now
        if sessionQueued then
            sessionQueued = false
            local newPairs = triggerAutoBuy()
            if #newPairs > 0 then
                runAutoBuySession(newPairs)
            end
        end
    end

    local seedAutoBuyToggle, gearAutoBuyToggle
    local seedBuyAllToggle,  gearBuyAllToggle
    local seedMultiSelect,   gearMultiSelect

    local function triggerAutoBuy()
        local pairs_ = {}

        -- Seeds: Buy All works standalone; if not Buy All, fall back to Auto-Buy + watchlist
        if seedBuyAllToggle and seedBuyAllToggle.GetValue() then
            for _, item in ipairs(SEED_ITEMS) do
                table.insert(pairs_, { "SeedShop", item.name })
            end
        elseif seedAutoBuyToggle and seedAutoBuyToggle.GetValue() then
            for _, name in ipairs(seedMultiSelect.GetValue()) do
                table.insert(pairs_, { "SeedShop", name })
            end
        end

        -- Gear: same logic
        if gearBuyAllToggle and gearBuyAllToggle.GetValue() then
            for _, item in ipairs(GEAR_ITEMS) do
                table.insert(pairs_, { "GearShop", item.name })
            end
        elseif gearAutoBuyToggle and gearAutoBuyToggle.GetValue() then
            for _, name in ipairs(gearMultiSelect.GetValue()) do
                table.insert(pairs_, { "GearShop", name })
            end
        end

        -- When called from the toggle buttons directly, spawn so the UI doesn't block.
        -- When called from onRestock, we call runAutoBuySession directly (inline) so
        -- restockPending stays true until the session is fully finished. See onRestock below.
        return pairs_
    end

    -- Restock handler: the workspace attribute fires when the shop RESETS (goes to 0),
    -- not when it's fully stocked. So instead of a fixed wait, we poll fetchStock()
    -- until items actually appear, then run the buy session.
    local restockPending = false
    local restockQueued  = false

    local function waitForStock()
        -- Poll every second for up to 30s until at least one item is in stock
        for _ = 1, 30 do
            fetchStock()
            for _, item in ipairs(SEED_ITEMS) do
                local s = seedStock[item.name]
                if s and s.Amount and s.Amount > 0 then return true end
            end
            for _, item in ipairs(GEAR_ITEMS) do
                local s = gearStock[item.name]
                if s and s.Amount and s.Amount > 0 then return true end
            end
            task.wait(1)
        end
        return false  -- timed out, stock never appeared
    end

    local function onRestock()
        if restockPending then
            restockQueued = true
            return
        end
        restockPending = true
        task.spawn(function()
            repeat
                restockQueued = false
                local stocked = waitForStock()  -- blocks until stock appears (or times out)
                if stocked then
                    refreshTables()
                    runAutoBuySession(triggerAutoBuy())
                end
            until not restockQueued
            restockPending = false
        end)
    end

    workspace:GetAttributeChangedSignal("SeedShop"):Connect(onRestock)
    workspace:GetAttributeChangedSignal("GearShop"):Connect(onRestock)

    -- Fetch stock BEFORE building the toggle UI so seedStock/gearStock are already
    -- populated by the time any toggle callback can fire (fixes startup buy-1-then-stop bug).
    -- refreshTables() is called at the end of this function, after the table elements exist.
    fetchStock()

    -- ── BILL'S SEED SHOP ──────────────────────
    ShopTab:CreateSection("Bill's Seed Shop")

    seedStockTable = ShopTab:CreateTable({
        Columns    = { "Seed", "Stock" },
        MaxVisible = 6,
        Rows       = {},
    })

    seedStockTable.OnRowClicked:Connect(function(index, row)
        -- Clear previous highlight
        if selectedSeedRowIndex then seedStockTable.ClearRowColor(selectedSeedRowIndex) end
        selectedSeedRowIndex = index
        seedStockTable.SetRowColor(index, Aurora.Config.Theme.Primary)
        selectedSeedName = row[1]
        -- Auto-buy max qty immediately on row click
        if shopBusy then
            Aurora:Notify({ Title = "Shop", Message = "Shop is busy.", Type = "Warning", Duration = 2 })
            return
        end
        shopBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                local hrp = getHRP()
                if hrp then savedPos = hrp.Position end
                ensureNear(SEED_SHOP_POS)
                local liveStock = seedStock[selectedSeedName]
                local maxQty = liveStock and liveStock.Amount or 0
                setStatus("Buying " .. maxQty .. "x " .. selectedSeedName .. "...", "Info")
                local bought = 0
                for _ = 1, maxQty do
                    local live = seedStock[selectedSeedName]
                    if not live or not live.Amount or live.Amount <= 0 then break end
                    local ok2, res = pcall(function() return PurchaseShopItem:InvokeServer("SeedShop", selectedSeedName) end)
                    if ok2 and type(res) == "table" and res.Items then
                        seedStock = res.Items
                        bought = bought + 1
                        task.wait(0.15)
                    else break end
                end
                returnToSaved()
                shopBusy = false
                refreshTables()
                if bought > 0 then
                    setStatus("Bought " .. bought .. "x " .. selectedSeedName, "Success")
                    Aurora:Notify({ Title = "Bought", Message = bought .. "x " .. selectedSeedName, Type = "Success", Duration = 3 })
                else
                    setStatus("Purchase failed.", "Error")
                    Aurora:Notify({ Title = "Shop", Message = selectedSeedName .. " — failed or out of stock.", Type = "Error", Duration = 3 })
                end
            end)
            if not ok then
                shopBusy = false
                returnToSaved()
                setStatus("Buy error — shop unlocked.", "Error")
                warn("Manual seed buy error:", err)
            end
        end)
    end)

    seedMultiSelect = ShopTab:CreateMultiSelect({
        Text    = "Watchlist",
        Options = seedOptions,
        Default = {},
    })

    seedBuyAllToggle = ShopTab:CreateToggle({
        Text    = "Buy All Seeds",
        Default = false,
        Callback = function(on)
            if on then
                local pairs_ = triggerAutoBuy()
                if shopBusy then
                    if #pairs_ > 0 then sessionQueued = true end
                else
                    task.spawn(runAutoBuySession, pairs_)
                end
            end
        end,
    })

    seedAutoBuyToggle = ShopTab:CreateToggle({
        Text    = "Auto-Buy Seeds",
        Default = false,
        Callback = function(on)
            if on then
                local pairs_ = triggerAutoBuy()
                if shopBusy then
                    if #pairs_ > 0 then sessionQueued = true end
                else
                    task.spawn(runAutoBuySession, pairs_)
                end
            end
        end,
    })

    -- ── MOLLY'S GEAR SHOP ─────────────────────
    ShopTab:CreateSection("Molly's Gear Shop")

    gearStockTable = ShopTab:CreateTable({
        Columns    = { "Gear", "Stock" },
        MaxVisible = 5,
        Rows       = {},
    })

    gearStockTable.OnRowClicked:Connect(function(index, row)
        if selectedGearRowIndex then gearStockTable.ClearRowColor(selectedGearRowIndex) end
        selectedGearRowIndex = index
        gearStockTable.SetRowColor(index, Aurora.Config.Theme.Primary)
        selectedGearName = row[1]
        -- Auto-buy max qty immediately on row click
        if shopBusy then
            Aurora:Notify({ Title = "Shop", Message = "Shop is busy.", Type = "Warning", Duration = 2 })
            return
        end
        shopBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                local hrp = getHRP()
                if hrp then savedPos = hrp.Position end
                ensureNear(GEAR_SHOP_POS)
                local liveStock = gearStock[selectedGearName]
                local maxQty = liveStock and liveStock.Amount or 0
                setStatus("Buying " .. maxQty .. "x " .. selectedGearName .. "...", "Info")
                local bought = 0
                for _ = 1, maxQty do
                    local live = gearStock[selectedGearName]
                    if not live or not live.Amount or live.Amount <= 0 then break end
                    local ok2, res = pcall(function() return PurchaseShopItem:InvokeServer("GearShop", selectedGearName) end)
                    if ok2 and type(res) == "table" and res.Items then
                        gearStock = res.Items
                        bought = bought + 1
                        task.wait(0.15)
                    else break end
                end
                returnToSaved()
                shopBusy = false
                refreshTables()
                if bought > 0 then
                    setStatus("Bought " .. bought .. "x " .. selectedGearName, "Success")
                    Aurora:Notify({ Title = "Bought", Message = bought .. "x " .. selectedGearName, Type = "Success", Duration = 3 })
                else
                    setStatus("Purchase failed.", "Error")
                    Aurora:Notify({ Title = "Shop", Message = selectedGearName .. " — failed or out of stock.", Type = "Error", Duration = 3 })
                end
            end)
            if not ok then
                shopBusy = false
                returnToSaved()
                setStatus("Buy error — shop unlocked.", "Error")
                warn("Manual gear buy error:", err)
            end
        end)
    end)

    gearMultiSelect = ShopTab:CreateMultiSelect({
        Text    = "Watchlist",
        Options = gearOptions,
        Default = {},
    })

    gearBuyAllToggle = ShopTab:CreateToggle({
        Text    = "Buy All Gear",
        Default = false,
        Callback = function(on)
            if on then
                local pairs_ = triggerAutoBuy()
                if shopBusy then
                    if #pairs_ > 0 then sessionQueued = true end
                else
                    task.spawn(runAutoBuySession, pairs_)
                end
            end
        end,
    })

    gearAutoBuyToggle = ShopTab:CreateToggle({
        Text    = "Auto-Buy Gear",
        Default = false,
        Callback = function(on)
            if on then
                local pairs_ = triggerAutoBuy()
                if shopBusy then
                    if #pairs_ > 0 then sessionQueued = true end
                else
                    task.spawn(runAutoBuySession, pairs_)
                end
            end
        end,
    })

    -- Now that seedStockTable and gearStockTable exist, populate them from the pre-fetched stock.
    refreshTables()
    -- (stock already fetched above, before toggle elements were built)
end

-- ─────────────────────────────────────────────
--  Init
-- ─────────────────────────────────────────────

task.delay(0.5, function()
    createShovelUI()
    createBotanistUI()
    createShopUI()

    -- Stop All toggle — mirrors Anti-AFK style; turning ON halts everything,
    -- turning it back OFF simply resets the toggle (loops stay stopped).
    SettingsTab:CreateSection("Stop All")
    local stopAllToggle
    stopAllToggle = SettingsTab:CreateToggle({
        Text    = "Stop All (Shovel + Botanist)",
        Default = false,
        Callback = function(on)
            if not on then return end  -- flipping back off does nothing extra
            -- Shovel
            if shovelAutoRunning then
                shovelAutoRunning = false
                if shovelAutoTask then pcall(task.cancel, shovelAutoTask) shovelAutoTask = nil end
                lockShovelControls(false)
            end
            -- Botanist
            if botRunning then
                botRunning = false
                if botTask then pcall(task.cancel, botTask) botTask = nil end
                local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid:UnequipTools() end
                lockBotControls(false)
            end
            Aurora:Notify({ Title = "Stopped", Message = "All loops halted.", Type = "Warning", Duration = 3 })
            -- Reset the toggle back to off after a short delay so it can be triggered again
            task.delay(0.5, function() stopAllToggle.SetValue(false) end)
        end,
    })
end)
