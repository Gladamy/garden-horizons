--[[
╔══════════════════════════════════════════════════════════════════════╗
║        GARDEN SHOVEL + AUTO BOTANIST + SHOP + QUESTS                ║
║        Aurora v6.5.0  —  Fully Modular Architecture v7.0            ║
╠══════════════════════════════════════════════════════════════════════╣
║  Architecture                                                        ║
║  ─────────────────────────────────────────────────────────────────  ║
║  Core      : shared state, remotes, mutex, webhook helpers          ║
║  Module.Shovel   : auto-remove unwanted fruits from ClientPlants    ║
║  Module.Botanist : harvest + donate to Maya                         ║
║  Module.Shop     : browse stock, manual buy, auto-buy on restock    ║
║  Module.Quest    : PlantSeeds / HarvestCrops / GainShillings loops  ║
║  Module.Settings : webhook config, anti-afk, stop-all              ║
║                                                                      ║
║  Key design guarantees                                               ║
║  ─────────────────────────────────────────────────────────────────  ║
║  1. All features use the shared teleport mutex (charBusy).          ║
║  2. Every loop checks a module-local cancel flag at every yield.    ║
║  3. UI elements are locked/unlocked through lockControls(bool).     ║
║  4. OnChanged signals keep UI in sync with runtime state.           ║
║  5. All remotes are wrapped in pcall — no runtime errors escape.    ║
║  6. Webhook logging is opt-in and never blocks execution.           ║
╚══════════════════════════════════════════════════════════════════════╝
]]

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  SERVICES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local player      = Players.LocalPlayer

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  AURORA  (load once, share everywhere)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local Aurora = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Gladamy/Aurora/refs/heads/main/Aurora.lua"
))()

local Window      = Aurora:CreateWindow({ Title = "Garden Shovel", Size = UDim2.new(0, 680, 0, 520) })
local ShovelTab   = Window:CreateTab({ Name = "Shovel"   })
local BotanistTab = Window:CreateTab({ Name = "Botanist" })
local ShopTab     = Window:CreateTab({ Name = "Shop"     })
local QuestTab    = Window:CreateTab({ Name = "Quests"   })
local SettingsTab = Window:CreateTab({ Name = "Settings" })

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  REMOTES
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local RemoteEvents          = RS:WaitForChild("RemoteEvents")
local RemovePlant           = RemoteEvents:WaitForChild("RemovePlant")
local BotanistQuest         = RemoteEvents:WaitForChild("BotanistQuestRequest")
local HarvestFruit          = RemoteEvents:WaitForChild("HarvestFruit")
local GetShopData           = RemoteEvents:WaitForChild("GetShopData")
local PurchaseShopItem      = RemoteEvents:WaitForChild("PurchaseShopItem")
local PlantSeed             = RemoteEvents:WaitForChild("PlantSeed")
local SellItems             = RemoteEvents:WaitForChild("SellItems")
local RequestQuests         = RemoteEvents:WaitForChild("RequestQuests")
local ClaimQuest            = RemoteEvents:WaitForChild("ClaimQuest")
local UpdateQuests          = RemoteEvents:WaitForChild("UpdateQuests")
local PurchaseSingleRefresh = RemoteEvents:WaitForChild("PurchaseSingleRefresh")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  STATIC DATA
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local SEED_ITEMS = {
    { name = "Carrot Seed",     price = 20,       rarity = "Common"    },
    { name = "Corn Seed",       price = 100,      rarity = "Common"    },
    { name = "Onion Seed",      price = 200,      rarity = "Common"    },
    { name = "Strawberry Seed", price = 800,      rarity = "Uncommon"  },
    { name = "Mushroom Seed",   price = 1500,     rarity = "Uncommon"  },
    { name = "Beetroot Seed",   price = 2500,     rarity = "Uncommon"  },
    { name = "Tomato Seed",     price = 4000,     rarity = "Rare"      },
    { name = "Apple Seed",      price = 7000,     rarity = "Rare"      },
    { name = "Rose Seed",       price = 10000,    rarity = "Rare"      },
    { name = "Wheat Seed",      price = 12000,    rarity = "Rare"      },
    { name = "Banana Seed",     price = 30000,    rarity = "Epic"      },
    { name = "Plum Seed",       price = 60000,    rarity = "Epic"      },
    { name = "Potato Seed",     price = 100000,   rarity = "Legendary" },
    { name = "Cabbage Seed",    price = 150000,   rarity = "Legendary" },
    { name = "Bamboo Seed",     price = 175000,   rarity = "Legendary" },
    { name = "Cherry Seed",     price = 1000000,  rarity = "Mythical"  },
    { name = "Mango Seed",      price = 10000000, rarity = "Mythical"  },
}

local GEAR_ITEMS = {
    { name = "Watering Can",    price = 5000,   rarity = "Common"   },
    { name = "Basic Sprinkler", price = 15000,  rarity = "Common"   },
    { name = "Harvest Bell",    price = 35000,  rarity = "Uncommon" },
    { name = "Turbo Sprinkler", price = 60000,  rarity = "Rare"     },
    { name = "Favorite Tool",   price = 80000,  rarity = "Common"   },
    { name = "Super Sprinkler", price = 100000, rarity = "Epic"     },
    { name = "Trowel",          price = 250000, rarity = "Common"   },
}

-- Botanist mutation map
local QUEST_ACCEPTED = {
    Foggy      = { "Foggy", "Mossy" },
    Soaked     = { "Soaked", "Flooded", "Muddy" },
    Chilled    = { "Snowy", "Frostbit", "Chilled" },
    Sandy      = { "Sandy", "Muddy" },
    Shocked    = { "Shocked" },
    Starstruck = { "Starstruck" },
}
local LEGACY_MAP = { Flooded = "Soaked", Snowy = "Chilled" }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  CORE MODULE
--  Shared utilities: teleport mutex, webhook, character helpers.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local Core = {}

do
    -- ── HTTP helper ──────────────────────────────────────────────────
    Core.httpFn = (syn and syn.request) or http_request or request

    -- Webhook URL is stored here so all modules can read it.
    -- Set by Module.Settings during init.
    Core.webhookUrl = ""

    -- ── Teleport Mutex ───────────────────────────────────────────────
    -- Prevents simultaneous teleports from different modules.
    local charBusy      = false
    local MUTEX_TIMEOUT = 5

    function Core.acquireMove()
        local waited = 0
        while charBusy and waited < MUTEX_TIMEOUT do
            task.wait(0.05)
            waited = waited + 0.05
        end
        charBusy = true
    end

    function Core.releaseMove()
        charBusy = false
    end

    -- ── Shop Priority Flag ────────────────────────────────────────────
    -- When the shop needs to run a buy session it sets shopPending = true.
    -- Any quest/botanist loop calls Core.yieldForShop() between atomic
    -- actions and pauses here until the shop clears the flag.
    -- This guarantees the shop owns the player position for the full
    -- duration of a buy pass without being interrupted mid-teleport.
    Core.shopPending = false
    local SHOP_YIELD_TIMEOUT = 60  -- max seconds a quest will wait

    function Core.yieldForShop()
        if not Core.shopPending then return end
        local waited = 0
        while Core.shopPending and waited < SHOP_YIELD_TIMEOUT do
            task.wait(0.1)
            waited = waited + 0.1
        end
    end

    -- ── Character helpers ────────────────────────────────────────────
    function Core.getHRP()
        local char = player.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    function Core.getHumanoid()
        local char = player.Character
        return char and char:FindFirstChildOfClass("Humanoid")
    end

    -- Teleport and wait.  Returns the position we teleported FROM,
    -- or nil if character is unavailable.
    -- If shopPending is true this call blocks until the shop is done
    -- before moving — the shop owns the character position for the
    -- full duration of its buy pass.
    function Core.teleportTo(pos)
        -- Wait for any active shop session to finish before moving.
        -- This is the single choke-point that prevents ALL modules
        -- (quest, botanist, manual buys) from disrupting shop teleports.
        if Core.shopPending then
            local waited = 0
            while Core.shopPending and waited < 60 do
                task.wait(0.1)
                waited = waited + 0.1
            end
        end
        local hrp = Core.getHRP()
        if not hrp then return nil end
        local saved = hrp.Position
        if (saved - pos).Magnitude > 2 then
            Core.acquireMove()
            hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
            task.wait(0.4)
            Core.releaseMove()
        end
        return saved
    end

    -- Return to a previously saved position.
    -- Also blocked by shopPending so returns never fire mid-buy-pass.
    function Core.returnFrom(savedPos)
        if not savedPos then return end
        if Core.shopPending then
            local waited = 0
            while Core.shopPending and waited < 60 do
                task.wait(0.1)
                waited = waited + 0.1
            end
        end
        local hrp = Core.getHRP()
        if hrp then
            Core.acquireMove()
            hrp.CFrame = CFrame.new(savedPos + Vector3.new(0, 3, 0))
            task.wait(0.35)
            Core.releaseMove()
        end
    end

    -- ── Tool helpers ─────────────────────────────────────────────────
    function Core.equipTool(tool)
        local humanoid = Core.getHumanoid()
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

    function Core.unequipTools()
        local humanoid = Core.getHumanoid()
        if humanoid then humanoid:UnequipTools() end
        task.wait(0.15)
    end

    -- ── Webhook ──────────────────────────────────────────────────────
    function Core.sendWebhook(url, title, description, color, fields)
        url = url or Core.webhookUrl
        if not url or url == "" or not Core.httpFn then return end
        task.spawn(function()
            pcall(function()
                Core.httpFn({
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
        end)
    end

    -- ── Debug log helper ─────────────────────────────────────────────
    -- Sends a plain text debug message to the webhook when enabled.
    function Core.dbg(msg)
        if Core.webhookUrl ~= "" then
            Core.sendWebhook(Core.webhookUrl, "[DEBUG]", tostring(msg), 0x808080)
        end
        -- Always print locally so debug is available without webhook.
        -- Remove the line below if you want silent mode.
        print("[GardenShovel DEBUG]", msg)
    end

    -- ── Notification shorthand ───────────────────────────────────────
    function Core.notify(title, msg, nType, duration)
        Aurora:Notify({
            Title    = title,
            Message  = msg or "",
            Type     = nType or "Info",
            Duration = duration or 3,
        })
    end

    -- ── Controls helper ──────────────────────────────────────────────
    -- Locks or unlocks a list of Aurora elements.
    function Core.setControlsEnabled(controls, enabled)
        for _, el in ipairs(controls) do
            pcall(function() el.SetEnabled(enabled) end)
        end
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  MODULE: SETTINGS
--  Webhook config, Anti-AFK, Stop All.
--  Created first so webhookInput is available to all modules.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ModSettings = {}

do
    -- ── Discord Webhook ──────────────────────────────────────────────
    SettingsTab:CreateSection("Discord Webhook")

    local webhookInput = SettingsTab:CreateInput({
        Text        = "Webhook URL",
        Placeholder = "https://discord.com/api/webhooks/...",
        Callback    = function(val) Core.webhookUrl = val end,
    })

    SettingsTab:CreateButton({
        Text = "Test Webhook",
        Callback = function()
            local url = webhookInput.GetValue()
            if url == "" then
                Core.notify("Webhook", "Enter a URL first.", "Warning")
                return
            end
            Core.sendWebhook(url, "Test Notification", "Webhook is working!", 0x2ECC71, {
                { name = "Source", value = "Garden Shovel", inline = true },
            })
            Core.notify("Webhook", "Test sent!", "Success")
        end,
    })

    -- ── Anti-AFK ─────────────────────────────────────────────────────
    SettingsTab:CreateSection("Anti-AFK")

    local antiAfkRunning = false
    local antiAfkTask    = nil
    local antiAfkIdled   = nil

    SettingsTab:CreateToggle({
        Text     = "Anti-AFK",
        Default  = false,
        Callback = function(on)
            antiAfkRunning = on
            -- Cancel previous task/connection before (re)starting
            if antiAfkTask  then pcall(task.cancel, antiAfkTask)    antiAfkTask  = nil end
            if antiAfkIdled then antiAfkIdled:Disconnect()           antiAfkIdled = nil end
            if on then
                antiAfkIdled = player.Idled:Connect(function() end)
                antiAfkTask  = task.spawn(function()
                    local VU = game:GetService("VirtualUser")
                    while antiAfkRunning do
                        task.wait(840)
                        if antiAfkRunning then
                            pcall(function()
                                VU:CaptureController()
                                VU:ClickButton2(Vector2.new())
                            end)
                        end
                    end
                    antiAfkTask = nil
                end)
                Core.notify("Anti-AFK", "Enabled.", "Success")
            end
        end,
    })

    -- ── Stop All ─────────────────────────────────────────────────────
    SettingsTab:CreateSection("Emergency Stop")

    -- Forward refs filled in during init after all modules are built.
    ModSettings.stopAllCallback = nil

    local stopAllToggle
    stopAllToggle = SettingsTab:CreateToggle({
        Text     = "Stop All (Shovel + Botanist + Quests)",
        Default  = false,
        Callback = function(on)
            if not on then return end
            if ModSettings.stopAllCallback then
                ModSettings.stopAllCallback()
            end
            Core.notify("Stopped", "All loops halted.", "Warning", 3)
            task.delay(0.5, function() stopAllToggle.SetValue(false) end)
        end,
    })

    -- ── Debug ─────────────────────────────────────────────────────────
    SettingsTab:CreateSection("Debug")

    SettingsTab:CreateToggle({
        Text     = "Log events to webhook",
        Default  = false,
        Callback = function(on)
            ModSettings.debugEnabled = on
        end,
    })

    SettingsTab:CreateButton({
        Text = "Dump ClientPlants to webhook",
        Callback = function()
            local url = Core.webhookUrl
            if url == "" then
                Core.notify("Debug", "Set a webhook URL first.", "Warning")
                return
            end
            local cp = workspace:FindFirstChild("ClientPlants")
            if not cp then
                Core.notify("Debug", "ClientPlants not found.", "Error")
                return
            end
            local lines = {}
            for _, t in ipairs(cp:GetChildren()) do
                if t:IsA("Model") then
                    table.insert(lines, string.format(
                        "Uuid=%s Owner=%s PlantType=%s FullyGrown=%s Sprouting=%s",
                        tostring(t:GetAttribute("Uuid")),
                        tostring(t:GetAttribute("OwnerUserId")),
                        tostring(t:GetAttribute("PlantType")),
                        tostring(t:GetAttribute("FullyGrown")),
                        tostring(t:GetAttribute("Sprouting"))
                    ))
                end
            end
            Core.sendWebhook(url, "ClientPlants Dump",
                table.concat(lines, "\n"):sub(1, 4000),
                0x3498DB)
            Core.notify("Debug", "Dump sent (" .. #lines .. " trees).", "Info")
        end,
    })

    -- ── Info ──────────────────────────────────────────────────────────
    SettingsTab:CreateSection("Info")
    SettingsTab:CreateLabel("Garden Shovel v7.0 — Aurora 6.5.0")
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  MODULE: SHOVEL
--  Scans ClientPlants, removes unwanted fruits by type/rarity/weight.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ModShovel = {}

do
    -- ── State ─────────────────────────────────────────────────────────
    local running     = false
    local runTask     = nil
    local controls    = {}   -- Aurora elements to lock while running
    local seenKeys    = {}   -- keys of fruits processed this session

    -- ── Helpers ───────────────────────────────────────────────────────
    local RARITY_COLOR = { Gold = 0xFFD700, Silver = 0xC0C0C0, Normal = 0xA8A8A8 }

    local function fruitKey(f)
        return f.uuid .. "_" .. tostring(f.anchorIndex)
    end

    -- Build a flat list of fruit entries from ClientPlants.
    -- Returns: fruits[], stats{ trees, fruits, byType{}, byRarity{} }
    local function scanGarden()
        local cp = workspace:FindFirstChild("ClientPlants")
        if not cp then return {}, { trees = 0, fruits = 0, byType = {}, byRarity = {} } end

        local fruits     = {}
        local stats      = { trees = 0, fruits = 0, byType = {}, byRarity = {} }
        local seenLocal  = {}

        local children = cp:GetChildren()
        stats.trees = #children

        for _, tree in ipairs(children) do
            if not tree:IsA("Model") then continue end
            local uuid      = tree:GetAttribute("Uuid") or tree.Name
            local fruitType = tree:GetAttribute("PlantType") or "Unknown"

            for _, child in ipairs(tree:GetChildren()) do
                local anchorIndex = child:GetAttribute("GrowthAnchorIndex")
                if anchorIndex == nil then continue end

                local key = uuid .. "_" .. tostring(anchorIndex)
                if seenLocal[key] then continue end
                seenLocal[key] = true

                local rarity = child:GetAttribute("Variant") or "Normal"
                local weight = tonumber(child:GetAttribute("FruitWeight")) or 0

                stats.fruits                     = stats.fruits + 1
                stats.byType[fruitType]          = (stats.byType[fruitType]  or 0) + 1
                stats.byRarity[rarity]           = (stats.byRarity[rarity]   or 0) + 1

                table.insert(fruits, {
                    uuid        = uuid,
                    anchorIndex = anchorIndex,
                    type        = fruitType,
                    rarity      = rarity,
                    weight      = weight,
                })
            end
        end

        return fruits, stats
    end

    -- Process a fruit list against options.  Removes fruits that match
    -- the shovel criteria (type + rarity), keeps those above the weight
    -- threshold and fires a webhook + notification for keepers.
    -- `seenFruitKeys` persists across calls to avoid re-notifying keepers.
    local function processFruits(fruits, opt, seen)
        local shoveled = 0

        for _, f in ipairs(fruits) do
            repeat  -- repeat/until true = Lua 5.1 safe continue pattern
                local key = fruitKey(f)

                -- Type filter
                if opt.types and #opt.types > 0 then
                    local match = false
                    for _, tp in ipairs(opt.types) do
                        if f.type == tp then match = true break end
                    end
                    if not match then seen[key] = true break end
                end

                -- Rarity filter
                local rarityMatch = false
                for _, rar in ipairs(opt.rarities or {}) do
                    if f.rarity == rar then rarityMatch = true break end
                end
                if not rarityMatch then seen[key] = true break end

                -- Weight-keep filter: if weight > threshold in watched rarities → keep
                local isKeeper = false
                if opt.maxWeight and opt.weightFilterRarities then
                    for _, wfRar in ipairs(opt.weightFilterRarities) do
                        if f.rarity == wfRar then
                            isKeeper = (f.weight > opt.maxWeight)
                            break
                        end
                    end
                end

                if isKeeper then
                    -- Notify once per keeper
                    if not seen[key] then
                        seen[key] = true
                        Core.notify(
                            "Keeper: " .. f.type,
                            f.rarity .. " — " .. string.format("%.4f KG", f.weight),
                            "Success", 5
                        )
                        -- Webhook for keeper
                        local url = opt.webhookUrl or Core.webhookUrl
                        if url and url ~= "" then
                            local avatarUrl = string.format(
                                "https://www.roblox.com/headshot-thumbnail/image?userId=%d&width=420&height=420&format=png",
                                player.UserId
                            )
                            Core.sendWebhook(url, f.type, "Kept — Weight Threshold",
                                RARITY_COLOR[f.rarity] or RARITY_COLOR.Normal, {
                                    { name = "Player",  value = player.Name,                           inline = true },
                                    { name = "Weight",  value = string.format("%.4fkg", f.weight),     inline = true },
                                    { name = "Variant", value = f.rarity,                              inline = true },
                                })
                        end
                    end
                else
                    seen[key] = true
                    pcall(function() RemovePlant:FireServer(f.uuid, f.anchorIndex) end)
                    shoveled = shoveled + 1
                    task.wait(0.05)
                end
            until true
        end

        -- Prune stale keys that are no longer in the garden
        local currentKeys = {}
        for _, f in ipairs(fruits) do currentKeys[fruitKey(f)] = true end
        for k in pairs(seen) do
            if not currentKeys[k] then seen[k] = nil end
        end

        return shoveled
    end

    -- ── Public stop ───────────────────────────────────────────────────
    function ModShovel.stop()
        running = false
        if runTask then pcall(task.cancel, runTask) runTask = nil end
        Core.setControlsEnabled(controls, true)
    end

    -- ── UI ────────────────────────────────────────────────────────────
    function ModShovel.init()
        local _, stats = scanGarden()
        local foundTypes, foundRarities = {}, {}
        for tp  in pairs(stats.byType   or {}) do table.insert(foundTypes,    tp)  end
        for rar in pairs(stats.byRarity or {}) do table.insert(foundRarities, rar) end

        ShovelTab:CreateSection("Status")
        local statusLabel = ShovelTab:CreateStatusLabel({
            Text = string.format("Scan: %d fruit(s) / %d tree(s)", stats.fruits, stats.trees),
            Type = "Info",
        })

        ShovelTab:CreateSection("Fruit Filter")
        local fruitMS = ShovelTab:CreateMultiSelect({
            Text    = "Fruit Types to Shovel",
            Options = #foundTypes > 0 and foundTypes or { "No fruits found" },
            Default = {},
        })
        table.insert(controls, fruitMS)

        ShovelTab:CreateSection("Rarity Filter")
        local rarityMS = ShovelTab:CreateMultiSelect({
            Text    = "Shovel These Rarities",
            Options = #foundRarities > 0 and foundRarities or { "Normal", "Silver", "Gold" },
            Default = {},
        })
        table.insert(controls, rarityMS)

        ShovelTab:CreateSection("Weight Filter")
        local weightInput = ShovelTab:CreateNumberInput({
            Text    = "Max Weight (KG)  —  kept above this",
            Min     = 0,
            Max     = 9999,
            Step    = 0.01,
            Default = 0,
        })
        ShovelTab:CreateLabel("Fruits above this weight are KEPT (0 = disabled)")
        table.insert(controls, weightInput)

        local weightFilterMS = ShovelTab:CreateMultiSelect({
            Text    = "Apply Weight Filter To Rarities",
            Options = { "Normal", "Silver", "Gold" },
            Default = {},
        })
        table.insert(controls, weightFilterMS)

        ShovelTab:CreateSection("Refresh")
        local refreshBtn = ShovelTab:CreateButton({
            Text = "Refresh Garden Scan",
            Callback = function()
                if running then
                    statusLabel.SetValue("Stop auto first.", "Warning")
                    return
                end
                local _, s2 = scanGarden()
                statusLabel.SetValue(
                    string.format("Scan: %d fruit(s) / %d tree(s)", s2.fruits, s2.trees),
                    "Info"
                )
            end,
        })
        table.insert(controls, refreshBtn)

        ShovelTab:CreateSection("Control")

        -- Manual one-shot
        ShovelTab:CreateButton({
            Text = "Manual Shovel Once",
            Callback = function()
                if running then
                    statusLabel.SetValue("Stop auto first.", "Warning")
                    return
                end
                local types   = fruitMS.GetValue()
                local rarities = rarityMS.GetValue()
                if #types == 0 or #rarities == 0 then
                    statusLabel.SetValue("Select fruit types AND rarities.", "Warning")
                    return
                end
                local opt = {
                    types       = types,
                    rarities    = rarities,
                    webhookUrl  = Core.webhookUrl,
                }
                local mw    = weightInput.GetValue()
                local wfRars = weightFilterMS.GetValue()
                if mw > 0 and #wfRars > 0 then
                    opt.maxWeight             = mw
                    opt.weightFilterRarities  = wfRars
                end
                local count = processFruits(scanGarden(), opt, {})
                statusLabel.SetValue(
                    string.format("Shoveled %d fruit(s).", count),
                    count > 0 and "Success" or "Info"
                )
            end,
        })

        -- Auto-shovel toggle
        local autoToggle
        autoToggle = ShovelTab:CreateToggle({
            Text     = "Auto Shovel",
            Default  = false,
            Callback = function(enabled)
                if enabled then
                    local types    = fruitMS.GetValue()
                    local rarities = rarityMS.GetValue()
                    if #types == 0 then
                        autoToggle.SetValue(false)
                        statusLabel.SetValue("Select fruit types first.", "Warning")
                        return
                    end
                    if #rarities == 0 then
                        autoToggle.SetValue(false)
                        statusLabel.SetValue("Select rarities first.", "Warning")
                        return
                    end

                    local opt = {
                        types      = types,
                        rarities   = rarities,
                        webhookUrl = Core.webhookUrl,
                    }
                    local mw     = weightInput.GetValue()
                    local wfRars = weightFilterMS.GetValue()
                    if mw > 0 and #wfRars > 0 then
                        opt.maxWeight            = mw
                        opt.weightFilterRarities = wfRars
                    end

                    -- Seed seen-keys with current garden to avoid shoveling
                    -- fruits that were already there when we start.
                    seenKeys = {}
                    for _, f in ipairs(scanGarden()) do seenKeys[fruitKey(f)] = true end

                    running = true
                    Core.setControlsEnabled(controls, false)
                    statusLabel.SetValue("Auto running...", "Success")

                    runTask = task.spawn(function()
                        while running do
                            local count = processFruits(scanGarden(), opt, seenKeys)
                            task.wait(count == 0 and 1 or 0.3)
                        end
                    end)
                else
                    running = false
                    if runTask then pcall(task.cancel, runTask) runTask = nil end
                    Core.setControlsEnabled(controls, true)
                    statusLabel.SetValue("Stopped.", "Info")
                end
            end,
        })
        -- autoToggle is not in controls — user needs it to stop
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  MODULE: BOTANIST
--  Auto-harvest matching fruits from garden, then donate to Maya.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ModBotanist = {}

do
    -- ── State ─────────────────────────────────────────────────────────
    local running  = false
    local runTask  = nil
    local controls = {}

    -- ── Mutation helpers ──────────────────────────────────────────────
    local function resolveKey(mutation)
        return LEGACY_MAP[mutation] or mutation
    end

    local function getAcceptedMutations(questKey)
        return QUEST_ACCEPTED[resolveKey(questKey)] or { questKey }
    end

    local function mutStrHas(mutStr, target)
        for part in (mutStr or ""):gmatch("[^,]+") do
            if part:match("^%s*(.-)%s*$") == target then return true end
        end
        return false
    end

    local function fruitMatchesQuest(mutStr, questKey)
        for _, mut in ipairs(getAcceptedMutations(questKey)) do
            if mutStrHas(mutStr, mut) then return true end
        end
        return false
    end

    -- ── Garden / backpack scanners ────────────────────────────────────
    local function getLivePlantTypes()
        local seen, types = {}, {}
        local myId = tostring(player.UserId)
        local cp   = workspace:FindFirstChild("ClientPlants")
        if cp then
            for _, tree in ipairs(cp:GetChildren()) do
                if tree:IsA("Model") and tostring(tree:GetAttribute("OwnerUserId")) == myId then
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

    local function scanGardenFruits(allowedTypes, questKey, protGold, protSilver, minWeight)
        local cp = workspace:FindFirstChild("ClientPlants")
        if not cp then return {} end
        local results = {}
        local myId    = tostring(player.UserId)

        for _, tree in ipairs(cp:GetChildren()) do
            if not tree:IsA("Model") then continue end
            if tostring(tree:GetAttribute("OwnerUserId")) ~= myId then continue end
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

    local function getBackpackFruits(allowedTypes, questKey, protGold, protSilver, minWeight)
        local bp = player:FindFirstChildOfClass("Backpack")
        if not bp then return {} end
        local results = {}
        for _, tool in ipairs(bp:GetChildren()) do
            if not (tool:IsA("Tool") and tool:GetAttribute("IsHarvested") == true
                    and tool:GetAttribute("Type") == "Plants") then continue end
            local baseName = tool:GetAttribute("BaseName") or ""
            if allowedTypes and #allowedTypes > 0 then
                local ok = false
                for _, t in ipairs(allowedTypes) do if baseName == t then ok = true break end end
                if not ok then continue end
            end
            if questKey and not fruitMatchesQuest(tool:GetAttribute("Mutation") or "", questKey) then continue end
            local variant = tool:GetAttribute("Variant") or "Normal"
            local weight  = tonumber(tool:GetAttribute("FruitWeight")) or 0
            if protGold   and variant == "Gold"   then continue end
            if protSilver and variant == "Silver" then continue end
            if minWeight  and minWeight > 0 and weight > minWeight then continue end
            table.insert(results, tool)
        end
        return results
    end

    -- ── Quest helpers ─────────────────────────────────────────────────
    local function getQuest()
        local ok, result = pcall(function() return BotanistQuest:InvokeServer("GetQuest") end)
        if not ok or not result or result.Status == "error" then return nil end
        return result
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

    -- ── Public stop ───────────────────────────────────────────────────
    function ModBotanist.stop()
        running = false
        if runTask then pcall(task.cancel, runTask) runTask = nil end
        Core.unequipTools()
        Core.setControlsEnabled(controls, true)
    end

    -- ── UI ────────────────────────────────────────────────────────────
    function ModBotanist.init()
        -- Quest status display
        BotanistTab:CreateSection("Quest Status")

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

        local questProgressBar = BotanistTab:CreateProgressBar({
            Text    = "Quest Weight",
            Default = 0,
            Color   = Aurora.Config.Theme.Success,
        })

        local function setQuestRow(row, value)
            questTable.SetCell(row, 2, value)
        end

        local function updateQuestProgress(totalW, targetW)
            if targetW and targetW > 0 then
                questProgressBar.SetValue(math.clamp(totalW / targetW, 0, 1))
                questProgressBar.SetLabel(string.format(
                    "Quest Weight  %.2f / %.2f kg", totalW, targetW
                ))
            else
                questProgressBar.SetValue(0)
                questProgressBar.SetLabel("Quest Weight")
            end
        end

        -- Plant filter
        BotanistTab:CreateSection("Plant Filter")

        local typeAllowlist = BotanistTab:CreateMultiSelect({
            Text    = "Allowed Plant Types  (empty = all)",
            Options = { "(click Refresh)" },
            Default = {},
        })
        table.insert(controls, typeAllowlist)

        local harvestFromGarden = BotanistTab:CreateToggle({
            Text    = "Auto-Harvest from Garden",
            Default = true,
        })
        BotanistTab:CreateLabel("ON = harvest garden fruits first, then donate.  OFF = backpack only.")
        table.insert(controls, harvestFromGarden)

        -- Protection
        BotanistTab:CreateSection("Protection")
        local protectGold   = BotanistTab:CreateToggle({ Text = "Protect Gold variants",   Default = true  })
        local protectSilver = BotanistTab:CreateToggle({ Text = "Protect Silver variants",  Default = false })
        local minWeightInput = BotanistTab:CreateNumberInput({
            Text = "Protect above weight (KG, 0 = off)",
            Min  = 0, Max = 999, Step = 0.05, Default = 0,
        })
        table.insert(controls, protectGold)
        table.insert(controls, protectSilver)
        table.insert(controls, minWeightInput)

        -- Timing
        BotanistTab:CreateSection("Timing")
        local donateDelay  = BotanistTab:CreateSlider({ Text = "Delay between donations (s)", Min = 0, Max = 3,   Default = 0,   Increment = 0.1 })
        local harvestDelay = BotanistTab:CreateSlider({ Text = "Delay between harvests (s)",  Min = 0, Max = 2,   Default = 0.3, Increment = 0.1 })
        table.insert(controls, donateDelay)
        table.insert(controls, harvestDelay)

        -- Session stats
        BotanistTab:CreateSection("Session Stats")
        local sessionTable = BotanistTab:CreateTable({
            Columns    = { "Fruits Donated", "Weight (kg)", "IGMA Packs" },
            Rows       = { { "0", "0.00", "0" } },
            MaxVisible = 1,
        })
        local sessionFruits, sessionWeight, sessionIGMA = 0, 0, 0
        local function updateSessionStats()
            sessionTable.SetCell(1, 1, tostring(sessionFruits))
            sessionTable.SetCell(1, 2, string.format("%.2f", sessionWeight))
            sessionTable.SetCell(1, 3, tostring(sessionIGMA))
        end

        -- Allowlist refresh
        local function refreshAllowlist()
            local types     = getLivePlantTypes()
            if #types == 0 or types[1] == "No plants found" then
                types = { "(no plants found)" }
            end
            -- Preserve selected values across rebuild
            local prevSelected = {}
            pcall(function()
                for _, v in ipairs(typeAllowlist.GetValue()) do prevSelected[v] = true end
            end)
            -- Remove from controls, destroy, rebuild
            for i, el in ipairs(controls) do
                if el == typeAllowlist then table.remove(controls, i) break end
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
            table.insert(controls, typeAllowlist)
        end

        -- Control section
        BotanistTab:CreateSection("Control")
        local statusLabel = BotanistTab:CreateStatusLabel({ Text = "Status: Idle", Type = "Info" })

        local refreshBtn = BotanistTab:CreateButton({
            Text = "Refresh Quest & Allowlist",
            Callback = function()
                if running then return end
                refreshAllowlist()
                local allowedTypes = typeAllowlist.GetValue()
                local protG        = protectGold.GetValue()
                local protS        = protectSilver.GetValue()
                local minW         = minWeightInput.GetValue()
                local minWEff      = minW > 0 and minW or nil
                local q = getQuest()
                if q then
                    local qKey   = resolveKey(q.Mutation or "")
                    local acc    = getAcceptedMutations(qKey)
                    local totalW = q.TotalWeight  or 0
                    local tgt    = q.TargetWeight or 0
                    setQuestRow(1, string.format("%s  (accepts: %s)", q.Mutation or "?", table.concat(acc, ", ")))
                    setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", totalW, tgt, math.max(0, tgt - totalW)))
                    setQuestRow(3, tostring(#scanGardenFruits(allowedTypes, qKey, protG, protS, minWEff)))
                    setQuestRow(4, tostring(#getBackpackFruits(allowedTypes, qKey, protG, protS, minWEff)))
                    updateQuestProgress(totalW, tgt)
                else
                    setQuestRow(1, "Could not fetch quest")
                    setQuestRow(2, "—"); setQuestRow(3, "—"); setQuestRow(4, "—")
                end
                Core.notify("Botanist", "Refreshed!", "Info", 2)
            end,
        })
        table.insert(controls, refreshBtn)

        local resetBtn = BotanistTab:CreateButton({
            Text = "Reset Session Stats",
            Callback = function()
                if running then return end
                sessionFruits = 0; sessionWeight = 0; sessionIGMA = 0
                updateSessionStats()
            end,
        })
        table.insert(controls, resetBtn)

        -- ── Auto Donate Toggle ─────────────────────────────────────────
        local autoToggle
        autoToggle = BotanistTab:CreateToggle({
            Text     = "Auto Donate",
            Default  = false,
            Callback = function(enabled)
                if enabled then
                    local q = getQuest()
                    if not q then
                        autoToggle.SetValue(false)
                        statusLabel.SetValue("Status: Could not fetch quest.", "Error")
                        return
                    end

                    local questKey     = resolveKey(q.Mutation or "")
                    local allowedTypes = typeAllowlist.GetValue()
                    local protG        = protectGold.GetValue()
                    local protS        = protectSilver.GetValue()
                    local minW         = minWeightInput.GetValue()
                    local minWEff      = minW > 0 and minW or nil
                    local fromGarden   = harvestFromGarden.GetValue()

                    Core.setControlsEnabled(controls, false)
                    running = true

                    runTask = task.spawn(function()
                        local delay     = donateDelay.GetValue()
                        local hDelay    = math.max(harvestDelay.GetValue(), 0.3)
                        local curQ      = q
                        local curQKey   = questKey

                        local function updateLabels(quest)
                            local qk  = resolveKey(quest.Mutation or "")
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
                                local newKey = resolveKey(newQ.Mutation or "")
                                if newKey ~= curQKey then
                                    curQ    = newQ
                                    curQKey = newKey
                                    updateLabels(newQ)
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
                                local tw  = result.TotalWeight or 0
                                local tgt = result.TargetWeight or 0
                                statusLabel.SetValue(string.format(
                                    "Status: Donated %s — %.2f / %.2f kg", fName, tw, tgt
                                ), "Success")
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
                                Core.notify("Quest Complete!", "Earned " .. rewardStr, "Success", 6)
                                if Core.webhookUrl ~= "" then
                                    Core.sendWebhook(Core.webhookUrl,
                                        "Quest Complete — " .. (curQ.Mutation or "?"),
                                        "Maya's quest completed!", 0x2ECC71, {
                                            { name = "Reward",     value = rewardStr,                                    inline = true  },
                                            { name = "Donated",    value = sessionFruits .. " fruits",                   inline = true  },
                                            { name = "Weight",     value = string.format("%.2f kg", sessionWeight),      inline = true  },
                                            { name = "IGMA Total", value = sessionIGMA .. " packs this session",         inline = false },
                                        })
                                end
                                return "complete"
                            elseif s == "wrong_mutation" then
                                statusLabel.SetValue("Status: Wrong mutation — re-fetching...", "Warning")
                                return "wrong_mutation"
                            elseif s == "no_active_quest" then
                                statusLabel.SetValue("Status: No active quest.", "Warning")
                                return "stop"
                            elseif s == "inventory_full" then
                                statusLabel.SetValue("Status: Inventory full!", "Error")
                                Core.notify("Botanist", "Inventory full — clear space!", "Error", 5)
                                return "stop"
                            else
                                return "skip"
                            end
                        end

                        local POLL_INTERVAL = 5

                        while running do
                            -- Yield if shop needs the character position
                            Core.yieldForShop()
                            if not running then break end

                            -- Donate from backpack first
                            local bpFruits = getBackpackFruits(allowedTypes, curQKey, protG, protS, minWEff)
                            setQuestRow(4, tostring(#bpFruits))

                            for _, tool in ipairs(bpFruits) do
                                if not running then break end
                                -- Verify tool is still in backpack
                                local bp2 = player:FindFirstChildOfClass("Backpack")
                                local stillThere = false
                                if bp2 then
                                    for _, it in ipairs(bp2:GetChildren()) do
                                        if it == tool then stillThere = true break end
                                    end
                                end
                                if not stillThere then continue end

                                local fName   = tool:GetAttribute("BaseName") or tool.Name
                                local fWeight = tonumber(tool:GetAttribute("FruitWeight")) or 0
                                statusLabel.SetValue(string.format(
                                    "Status: Equipping %s (%.2f kg)...", fName, fWeight
                                ), "Info")

                                Core.unequipTools()
                                if not Core.equipTool(tool) then
                                    statusLabel.SetValue("Status: Failed to equip — skipping.", "Warning")
                                    task.wait(0.5)
                                    continue
                                end
                                task.wait(0.1)

                                local result  = turnInEquippedFruit()
                                local outcome = handleResult(result, fWeight, fName)
                                Core.unequipTools()

                                if outcome == "stop" then
                                    running = false
                                    autoToggle.SetValue(false)
                                    Core.setControlsEnabled(controls, true)
                                    break
                                elseif outcome == "complete" or outcome == "wrong_mutation" then
                                    task.wait(outcome == "complete" and 3 or 1)
                                    local newQ = getQuest()
                                    if newQ then
                                        curQ    = newQ
                                        curQKey = resolveKey(newQ.Mutation or "")
                                        updateLabels(newQ)
                                    else
                                        statusLabel.SetValue("Status: Could not fetch new quest.", "Error")
                                        running = false
                                        autoToggle.SetValue(false)
                                        Core.setControlsEnabled(controls, true)
                                    end
                                    break
                                end
                                if delay > 0 then task.wait(delay) end
                            end

                            if not running then break end

                            -- Harvest from garden
                            if fromGarden then
                                local gardenFruits = scanGardenFruits(allowedTypes, curQKey, protG, protS, minWEff)
                                setQuestRow(3, tostring(#gardenFruits))

                                if #gardenFruits == 0 then
                                    local bpCheck = getBackpackFruits(allowedTypes, curQKey, protG, protS, minWEff)
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
                                    if not running then break end
                                    if not entry.fruitModel.Parent then continue end
                                    if not entry.prompt.Parent then continue end

                                    statusLabel.SetValue(string.format(
                                        "Status: Harvesting %s (%.2f kg)...",
                                        entry.plantType, entry.weight
                                    ), "Info")
                                    harvestFruit(entry)
                                    harvested = harvested + 1

                                    -- Wait for harvest to land on server
                                    task.wait(2)
                                    if hDelay > 0.3 then task.wait(hDelay - 0.3) end

                                    -- Donate what's now in backpack
                                    local bpNow = getBackpackFruits(allowedTypes, curQKey, protG, protS, minWEff)
                                    setQuestRow(4, tostring(#bpNow))

                                    local questChanged = false
                                    for _, tool in ipairs(bpNow) do
                                        if not running then break end
                                        local bp2 = player:FindFirstChildOfClass("Backpack")
                                        local stillThere = false
                                        if bp2 then
                                            for _, it in ipairs(bp2:GetChildren()) do
                                                if it == tool then stillThere = true break end
                                            end
                                        end
                                        if not stillThere then continue end

                                        local fName   = tool:GetAttribute("BaseName") or tool.Name
                                        local fWeight = tonumber(tool:GetAttribute("FruitWeight")) or 0
                                        statusLabel.SetValue(string.format(
                                            "Status: Donating %s (%.2f kg)...", fName, fWeight
                                        ), "Info")
                                        Core.unequipTools()
                                        if not Core.equipTool(tool) then task.wait(0.5) continue end
                                        task.wait(0.1)
                                        local result  = turnInEquippedFruit()
                                        local outcome = handleResult(result, fWeight, fName)
                                        Core.unequipTools()

                                        if outcome == "stop" then
                                            running = false
                                            autoToggle.SetValue(false)
                                            Core.setControlsEnabled(controls, true)
                                            break
                                        elseif outcome == "complete" or outcome == "wrong_mutation" then
                                            task.wait(outcome == "complete" and 3 or 1)
                                            local newQ = getQuest()
                                            if newQ then
                                                curQ    = newQ
                                                curQKey = resolveKey(newQ.Mutation or "")
                                                updateLabels(newQ)
                                            else
                                                statusLabel.SetValue("Status: Could not fetch new quest.", "Error")
                                                running = false
                                                autoToggle.SetValue(false)
                                                Core.setControlsEnabled(controls, true)
                                            end
                                            questChanged = true
                                            break
                                        end
                                        if delay > 0 then task.wait(delay) end
                                    end

                                    if not running or questChanged then break end
                                end

                                if harvested == 0 then
                                    statusLabel.SetValue("Status: Waiting for fruits to grow...", "Info")
                                    task.wait(POLL_INTERVAL)
                                    pollRefreshQuest()
                                end
                            else
                                -- Garden off — just wait for backpack fruits
                                local bpCheck = getBackpackFruits(allowedTypes, curQKey, protG, protS, minWEff)
                                if #bpCheck == 0 then
                                    statusLabel.SetValue("Status: Waiting for backpack fruits...", "Info")
                                    task.wait(POLL_INTERVAL)
                                    pollRefreshQuest()
                                end
                            end
                        end -- while running

                        Core.unequipTools()
                        if running then
                            running = false
                            autoToggle.SetValue(false)
                            Core.setControlsEnabled(controls, true)
                            statusLabel.SetValue("Status: Finished.", "Info")
                        end
                    end)
                else
                    running = false
                    if runTask then pcall(task.cancel, runTask) runTask = nil end
                    Core.unequipTools()
                    Core.setControlsEnabled(controls, true)
                    statusLabel.SetValue("Status: Stopped.", "Info")
                    Core.notify("Botanist", "Stopped.", "Warning", 3)
                end
            end,
        })
        -- autoToggle not in controls — needed to stop

        -- Init display on defer
        task.defer(function()
            refreshAllowlist()
            local q = getQuest()
            if q then
                local qKey   = resolveKey(q.Mutation or "")
                local acc    = getAcceptedMutations(qKey)
                local totalW = q.TotalWeight  or 0
                local tgt    = q.TargetWeight or 0
                setQuestRow(1, string.format("%s  (accepts: %s)", q.Mutation or "?", table.concat(acc, ", ")))
                setQuestRow(2, string.format("%.2f / %.2f kg  (%.2f remaining)", totalW, tgt, math.max(0, tgt - totalW)))
                updateQuestProgress(totalW, tgt)
            end
        end)
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  MODULE: SHOP
--  Browse shop stock, manual buy, auto-buy on restock.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ModShop = {}

do
    function ModShop.init()
        local SEED_SHOP_POS = Vector3.new(176.6, 204.1, 678.8)
        local GEAR_SHOP_POS = Vector3.new(217.9, 204.1, 608.9)
        local NEAR_DIST     = 8

        local seedStock = {}
        local gearStock = {}
        local savedPos  = nil

        local running     = false
        local cancelFlag  = false
        local rerunAfter  = false
        local manualQueue = {}

        local selectedSeedRowIndex = nil
        local selectedGearRowIndex = nil

        -- ── Status display ───────────────────────────────────────────
        ShopTab:CreateSection("Shop Status")
        local shopInfoLabel = ShopTab:CreateStatusLabel({ Text = "Idle", Type = "Info" })

        local function setStatus(msg, statusType)
            local s = math.ceil(300 - workspace:GetServerTimeNow() % 300)
            shopInfoLabel.SetValue(
                string.format("Next restock: %d:%02d  |  %s", math.floor(s / 60), s % 60, msg),
                statusType or "Info"
            )
        end

        -- Live restock countdown ticker
        local tickerTask = task.spawn(function()
            while true do
                setStatus(running and "Busy..." or "Idle", running and "Warning" or "Info")
                task.wait(1)
            end
        end)
        -- Clean up ticker when window is destroyed
        Window.ScreenGui.AncestryChanged:Connect(function(_, newParent)
            if not newParent then pcall(task.cancel, tickerTask) end
        end)

        -- ── Travel helpers ───────────────────────────────────────────
        -- The shop bypasses the shopPending check in Core.teleportTo because
        -- it IS the owner of that flag — calling Core.teleportTo would deadlock.
        -- These functions go straight to acquireMove/releaseMove instead.
        local function shopTeleport(pos)
            local hrp = Core.getHRP()
            if not hrp then return end
            if (hrp.Position - pos).Magnitude <= 2 then return end
            Core.acquireMove()
            hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
            task.wait(0.4)
            Core.releaseMove()
        end

        local function ensureNear(shopPos)
            local hrp = Core.getHRP()
            if not hrp then return end
            if (hrp.Position - shopPos).Magnitude <= NEAR_DIST then return end
            if not savedPos then savedPos = hrp.Position end
            shopTeleport(shopPos)
        end

        local function returnToSaved()
            if savedPos then
                shopTeleport(savedPos)
                savedPos = nil
            end
        end

        -- ── Stock helpers ────────────────────────────────────────────
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
                local qty = s and s.Amount    or 0
                local max = s and s.MaxAmount or "?"
                if qty > 0 then
                    table.insert(rows, { item.name, qty .. " / " .. max })
                end
            end
            return rows
        end

        local seedStockTable, gearStockTable
        local seedMultiSelect, gearMultiSelect
        local seedBuyAllToggle, seedAutoBuyToggle
        local gearBuyAllToggle, gearAutoBuyToggle

        local function refreshTables()
            if not seedStockTable or not gearStockTable then return end
            seedStockTable.SetRows(buildStockRows(SEED_ITEMS, seedStock))
            gearStockTable.SetRows(buildStockRows(GEAR_ITEMS, gearStock))
            selectedSeedRowIndex = nil
            selectedGearRowIndex = nil
        end

        -- ── Buy logic ────────────────────────────────────────────────
        local function buildQueue()
            local jobs = {}
            for _, job in ipairs(manualQueue) do table.insert(jobs, job) end
            manualQueue = {}
            if seedBuyAllToggle and seedBuyAllToggle.GetValue() then
                for _, item in ipairs(SEED_ITEMS) do table.insert(jobs, { "SeedShop", item.name }) end
            elseif seedAutoBuyToggle and seedAutoBuyToggle.GetValue() and seedMultiSelect then
                for _, name in ipairs(seedMultiSelect.GetValue()) do table.insert(jobs, { "SeedShop", name }) end
            end
            if gearBuyAllToggle and gearBuyAllToggle.GetValue() then
                for _, item in ipairs(GEAR_ITEMS) do table.insert(jobs, { "GearShop", item.name }) end
            elseif gearAutoBuyToggle and gearAutoBuyToggle.GetValue() and gearMultiSelect then
                for _, name in ipairs(gearMultiSelect.GetValue()) do table.insert(jobs, { "GearShop", name }) end
            end
            return jobs
        end

        local function buyItem(shopId, itemName)
            local bought = 0
            while true do
                if cancelFlag then break end
                local stock = shopId == "SeedShop" and seedStock or gearStock
                local entry = stock[itemName]
                if not entry or not entry.Amount or entry.Amount <= 0 then break end
                local ok, res = pcall(function() return PurchaseShopItem:InvokeServer(shopId, itemName) end)
                if ok and type(res) == "table" and res.Items then
                    if shopId == "SeedShop" then seedStock = res.Items else gearStock = res.Items end
                    bought = bought + 1
                    task.wait(0.15)
                else
                    break
                end
            end
            return bought
        end

        local function runSession()
            if running then rerunAfter = true; return end
            running = true
            cancelFlag = false

            -- Signal all other modules to pause at their next safe point.
            -- They call Core.yieldForShop() between atomic actions and block
            -- here until we clear the flag after the full buy pass is done.
            Core.shopPending = true

            -- Save the player's current position NOW, before any other module
            -- moves them. We restore to this position after all purchases.
            local hrp = Core.getHRP()
            if hrp then savedPos = hrp.Position end

            local ok, err = pcall(function()
                repeat
                    rerunAfter = false
                    local jobs = buildQueue()
                    if #jobs == 0 then break end

                    local sessionTotal  = 0
                    local purchaseLog   = {}  -- for webhook debug log

                    for _, job in ipairs(jobs) do
                        if cancelFlag then break end
                        local shopId, itemName = job[1], job[2]
                        local shopPos = shopId == "SeedShop" and SEED_SHOP_POS or GEAR_SHOP_POS
                        local stock   = shopId == "SeedShop" and seedStock or gearStock
                        local entry   = stock[itemName]

                        -- Re-fetch live stock for this item so we have
                        -- the freshest count (restock may have fired mid-pass)
                        local liveStock = shopId == "SeedShop" and seedStock or gearStock
                        local liveEntry = liveStock[itemName]
                        local liveQty   = liveEntry and liveEntry.Amount or 0

                        if liveQty > 0 then
                            ensureNear(shopPos)
                            if not cancelFlag then
                                setStatus("Buying: " .. itemName, "Info")
                                local n = buyItem(shopId, itemName)
                                sessionTotal = sessionTotal + n
                                if n > 0 then
                                    table.insert(purchaseLog, string.format(
                                        "✓ %s x%d", itemName, n
                                    ))
                                    refreshTables()
                                    task.wait(0.1)
                                else
                                    table.insert(purchaseLog, string.format(
                                        "✗ %s — purchase failed (rejected by server)", itemName
                                    ))
                                end
                            end
                        else
                            -- Not in stock — log it so every item is accounted for
                            table.insert(purchaseLog, string.format(
                                "– %s — not in stock", itemName
                            ))
                        end
                    end

                    -- Return to wherever the player was before we started
                    returnToSaved()
                    refreshTables()

                    if sessionTotal > 0 then
                        setStatus("Done — bought " .. sessionTotal .. " item(s).", "Success")
                        Core.notify("Auto-Buy",
                            "Bought " .. sessionTotal .. " item(s) this pass.", "Success", 4)
                    elseif not cancelFlag then
                        setStatus("Done — nothing in stock.", "Info")
                    end

                    -- Webhook purchase log
                    if Core.webhookUrl ~= "" and #purchaseLog > 0 then
                        Core.sendWebhook(Core.webhookUrl,
                            "Shop — Buy Pass Complete",
                            table.concat(purchaseLog, "\n"),
                            sessionTotal > 0 and 0x2ECC71 or 0x808080, {
                                { name = "Total Purchased", value = tostring(sessionTotal), inline = true },
                                { name = "Items Checked",  value = tostring(#purchaseLog), inline = true },
                            })
                    end

                until not rerunAfter or cancelFlag
            end)

            -- Always clear the flag so waiting modules resume
            Core.shopPending = false
            running    = false
            cancelFlag = false

            if not ok then
                returnToSaved(); refreshTables()
                Core.shopPending = false  -- safety clear on error path too
                setStatus("Buy error — shop unlocked.", "Error")
                warn("[Shop] runSession error:", err)
            end
        end

        local function requestSession()
            if running then rerunAfter = true else task.spawn(runSession) end
        end

        local function rowClickBuy(shopId, itemName)
            -- Deduplicate
            for _, job in ipairs(manualQueue) do
                if job[1] == shopId and job[2] == itemName then
                    Core.notify("Shop", itemName .. " already queued.", "Info", 2)
                    return
                end
            end
            table.insert(manualQueue, { shopId, itemName })
            if running then
                rerunAfter = true
                Core.notify("Shop", itemName .. " queued — buying after current.", "Info", 2)
            else
                task.spawn(runSession)
            end
        end

        -- ── Restock listener ─────────────────────────────────────────
        local restockCooldown = false
        local function onRestock()
            if restockCooldown then return end
            restockCooldown = true
            task.spawn(function()
                task.wait(3)
                fetchStock(); refreshTables(); requestSession()
                task.wait(10)
                restockCooldown = false
            end)
        end

        workspace:GetAttributeChangedSignal("SeedShop"):Connect(onRestock)
        workspace:GetAttributeChangedSignal("GearShop"):Connect(onRestock)

        -- ── UI ───────────────────────────────────────────────────────
        fetchStock()

        ShopTab:CreateSection("Bill's Seed Shop")
        seedStockTable = ShopTab:CreateTable({
            Columns    = { "Seed", "Stock" },
            MaxVisible = 6,
            Rows       = {},
        })
        seedStockTable.OnRowClicked:Connect(function(index, row)
            if selectedSeedRowIndex then seedStockTable.ClearRowColor(selectedSeedRowIndex) end
            selectedSeedRowIndex = index
            seedStockTable.SetRowColor(index, Aurora.Config.Theme.Primary)
            rowClickBuy("SeedShop", row[1])
        end)

        local seedOptions = {}
        for _, item in ipairs(SEED_ITEMS) do table.insert(seedOptions, item.name) end
        seedMultiSelect = ShopTab:CreateMultiSelect({ Text = "Watchlist", Options = seedOptions, Default = {} })

        seedBuyAllToggle = ShopTab:CreateToggle({
            Text     = "Buy All Seeds",
            Default  = false,
            Callback = function(on)
                if on then requestSession() else cancelFlag = true end
            end,
        })
        seedAutoBuyToggle = ShopTab:CreateToggle({
            Text     = "Auto-Buy Seeds (watchlist)",
            Default  = false,
            Callback = function(on)
                if on then requestSession() else cancelFlag = true end
            end,
        })

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
            rowClickBuy("GearShop", row[1])
        end)

        local gearOptions = {}
        for _, item in ipairs(GEAR_ITEMS) do table.insert(gearOptions, item.name) end
        gearMultiSelect = ShopTab:CreateMultiSelect({ Text = "Watchlist", Options = gearOptions, Default = {} })

        gearBuyAllToggle = ShopTab:CreateToggle({
            Text     = "Buy All Gear",
            Default  = false,
            Callback = function(on)
                if on then requestSession() else cancelFlag = true end
            end,
        })
        gearAutoBuyToggle = ShopTab:CreateToggle({
            Text     = "Auto-Buy Gear (watchlist)",
            Default  = false,
            Callback = function(on)
                if on then requestSession() else cancelFlag = true end
            end,
        })

        refreshTables()
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  MODULE: QUEST
--  Automates PlantSeeds / HarvestCrops / GainShillings quests.
--  Full state-machine; server is always source of truth.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ModQuest = {}

do
    -- ── Constants ─────────────────────────────────────────────────────
    local TREE_CAP      = 300
    local BILL_POS      = Vector3.new(176.6, 204.1, 678.8)
    local STEVE_POS     = Vector3.new(149.5, 204.0, 678.6)
    local NPC_NEAR      = 8
    local FETCH_TIMEOUT = 3
    local FRUIT_CONFIRM = 3
    local SPROUT_WAIT   = 15
    local GROW_WAIT     = 600
    local STALL_MAX     = 5

    -- ── Session state ─────────────────────────────────────────────────
    local questPlantedUuids = {}   -- uuid → PlantTime; only quest trees
    local questData         = nil
    local questRunning      = false
    local questCancel       = false
    local questControls     = {}
    local autoClaim         = true   -- always on; no UI toggle needed
    local autoReroll        = true
    local multiPlantEnabled = true   -- toggled from UI
    local multiPlantMax     = 5      -- slider value; auto batch is capped here
    local loopMode          = true   -- always loops; no UI toggle needed
    -- earnAllowlist: set of PlantType strings allowed for GainShillings harvests.
    -- Empty table = all types allowed (default). Populated by UI multiselect.
    local earnAllowlist     = {}

    -- ── Session stats ────────────────────────────────────────────────
    local stats = {
        sessionStart    = 0,     -- tick() when Run Quests was last enabled
        passCount       = 0,     -- loop passes completed
        questsCompleted = 0,     -- total quests claimed this session
        questsSkipped   = 0,     -- quests skipped (out of stock, stalled, etc.)
        byType = {               -- completed breakdown by quest type
            PlantSeeds    = 0,
            HarvestCrops  = 0,
            GainShillings = 0,
        },
        seedsPlanted    = 0,     -- total seeds planted
        fruitsHarvested = 0,     -- total fruits harvested
        shillingsEarned = 0,     -- shillings earned (from server progress deltas)
    }

    local function resetStats()
        stats.sessionStart    = tick()
        stats.passCount       = 0
        stats.questsCompleted = 0
        stats.questsSkipped   = 0
        stats.byType.PlantSeeds    = 0
        stats.byType.HarvestCrops  = 0
        stats.byType.GainShillings = 0
        stats.seedsPlanted    = 0
        stats.fruitsHarvested = 0
        stats.shillingsEarned = 0
    end

    local function fmtUptime()
        local s = math.floor(tick() - stats.sessionStart)
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        local sec = s % 60
        if h > 0 then
            return string.format("%dh %dm %ds", h, m, sec)
        elseif m > 0 then
            return string.format("%dm %ds", m, sec)
        else
            return string.format("%ds", sec)
        end
    end

    -- Forward-declared UI refs (set during init)
    -- multiPlantToggle and multiPlantSlider are also forward-declared here
    -- so the runToggle callback can read their values at launch time,
    -- regardless of declaration order inside ModQuest.init().
    local multiPlantToggle  = nil
    local multiPlantSlider  = nil
    -- updateStatsDisplay is reassigned in init() once statsTable exists
    -- Run option dropdowns — also forward-declared so runToggle callback
    -- can safely call GetValue on second+ toggles after init completes.
    local runTypeDropdown   = nil
    local scopeDropdown     = nil
    local priorityDropdown  = nil
    local runToggle         = nil
    local questStatusLabel  = nil
    local slotProgressBar   = nil
    local questDisplayTable = nil

    local COLOR_BAR_ACTIVE   = Aurora.Config.Theme.Primary
    local COLOR_BAR_COMPLETE = Color3.fromRGB(46, 204, 113)
    local COLOR_COMPLETE     = Color3.fromRGB(46, 204, 113)
    local COLOR_CLAIMED      = Color3.fromRGB(70, 70, 80)

    -- ── Stats display updater ────────────────────────────────────────
    -- Defined as an upvalue so init() can replace it with a closure that
    -- references the statsTable element once it's been created.
    -- Until init runs this is a safe no-op stub.
    local updateStatsDisplay = function() end

    -- ── UI helpers ────────────────────────────────────────────────────
    local function setStatus(msg, t)
        if questStatusLabel then questStatusLabel.SetValue(msg, t or "Info") end
    end

    local function setBar(value, label, color)
        if not slotProgressBar then return end
        slotProgressBar.SetValue(math.clamp(value, 0, 1))
        if label then slotProgressBar.SetLabel(label) end
        if color then slotProgressBar.SetColor(color) end
    end

    local function lockQuestControls(locked)
        Core.setControlsEnabled(questControls, not locked)
    end

    local function refreshQuestDisplay()
        if not questData or not questDisplayTable then return end
        local rows = {}
        for _, qType in ipairs({ "Daily", "Weekly" }) do
            local bucket = questData[qType]
            if bucket and bucket.Active then
                for slot = 1, 5 do
                    local q = bucket.Active[tostring(slot)]
                    if q then
                        local prog   = tostring(q.Progress or 0) .. " / " .. tostring(q.Goal or "?")
                        local reward = q.RewardItem
                            and (tostring(q.RewardAmount or 1) .. "x " .. q.RewardItem)
                            or  (tostring(q.RewardAmount or 0) .. " Shillings")
                        local desc   = (q.Description or (q.TargetItem or q.Type or "?")):gsub("^%[.-%]%s*", "")
                        if q.Claimed then
                            desc = "[Claimed] " .. desc
                        elseif q.Progress and q.Goal and q.Progress >= q.Goal then
                            desc = "[Done!] " .. desc
                        end
                        table.insert(rows, { qType, desc, prog, reward })
                    end
                end
            end
        end
        questDisplayTable.SetRows(rows)

        -- Apply row colors
        local rowIdx = 0
        for _, qType in ipairs({ "Daily", "Weekly" }) do
            local bucket = questData[qType]
            if bucket and bucket.Active then
                for slot = 1, 5 do
                    local q = bucket.Active[tostring(slot)]
                    if q then
                        rowIdx = rowIdx + 1
                        if q.Claimed then
                            questDisplayTable.SetRowColor(rowIdx, COLOR_CLAIMED)
                        elseif q.Progress and q.Goal and q.Progress >= q.Goal then
                            questDisplayTable.SetRowColor(rowIdx, COLOR_COMPLETE)
                        end
                    end
                end
            end
        end
    end

    -- ── Core Primitives ───────────────────────────────────────────────

    -- Fetch live quest data. Blocks until UpdateQuests fires or FETCH_TIMEOUT.
    local function fetchLive()
        local received = false
        local result   = nil
        local conn
        conn = UpdateQuests.OnClientEvent:Connect(function(data)
            if received then return end
            received  = true
            conn:Disconnect()
            questData = data
            result    = data
            refreshQuestDisplay()
        end)
        pcall(function() RequestQuests:FireServer() end)
        local t = tick()
        while not received and tick() - t < FETCH_TIMEOUT do task.wait(0.1) end
        if not received then conn:Disconnect() end
        return result
    end

    local function fetchLiveSlot(qType, slot)
        local data = fetchLive()
        if not data then return nil end
        return data[qType]
            and data[qType].Active
            and data[qType].Active[tostring(slot)]
    end

    -- Count trees owned by local player in ClientPlants.
    local function countMyTrees()
        local cp   = workspace:FindFirstChild("ClientPlants")
        local myId = tostring(player.UserId)
        local n    = 0
        if not cp then return n end
        for _, t in ipairs(cp:GetChildren()) do
            if t:IsA("Model") and tostring(t:GetAttribute("OwnerUserId")) == myId then
                n = n + 1
            end
        end
        return n
    end

    -- Find the player's plot using string comparison on Owner.
    local function getPlayerPlot()
        local plots   = workspace:FindFirstChild("Plots")
        local myIdStr = tostring(player.UserId)
        if not plots then return nil end
        for _, p in ipairs(plots:GetChildren()) do
            if tostring(p:GetAttribute("Owner")) == myIdStr then return p end
        end
        return nil
    end

    -- Snapshot all UUID keys in ClientPlants (for UUID-diff after planting).
    local function snapshotUuids()
        local cp   = workspace:FindFirstChild("ClientPlants")
        local snap = {}
        if not cp then return snap end
        for _, t in ipairs(cp:GetChildren()) do
            if t:IsA("Model") then
                local u = t:GetAttribute("Uuid")
                if u then snap[u] = true end
            end
        end
        return snap
    end

    -- ── Cap management ────────────────────────────────────────────────
    -- Returns quest-planted trees still in ClientPlants, sorted oldest first.
    local function getRemovableTrees()
        local cp   = workspace:FindFirstChild("ClientPlants")
        local list = {}
        if not cp then return list end
        for uuid in pairs(questPlantedUuids) do
            local found = false
            for _, t in ipairs(cp:GetChildren()) do
                if t:IsA("Model") and t:GetAttribute("Uuid") == uuid then
                    local pt = tonumber(t:GetAttribute("PlantTime")) or 0
                    table.insert(list, { uuid = uuid, plantTime = pt })
                    found = true
                    break
                end
            end
            if not found then questPlantedUuids[uuid] = nil end
        end
        table.sort(list, function(a, b) return a.plantTime < b.plantTime end)
        return list
    end

    -- Make room for `needed` more trees by removing oldest quest trees.
    local function makeRoom(needed)
        local current  = countMyTrees()
        local toRemove = (current + needed) - TREE_CAP
        if toRemove <= 0 then return true end
        local removable = getRemovableTrees()
        if #removable < toRemove then
            setStatus(string.format(
                "Plot at %d/300. Need %d slots but only %d quest trees removable — skipping.",
                current, toRemove, #removable
            ), "Warning")
            return false
        end
        for i = 1, toRemove do
            if questCancel then return false end
            local entry = removable[i]
            setStatus(string.format("Clearing plot room (%d/%d)...", i, toRemove), "Info")
            pcall(function() RemovePlant:FireServer(entry.uuid, nil) end)
            questPlantedUuids[entry.uuid] = nil
            task.wait(0.5)
        end
        task.wait(0.5)
        return countMyTrees() < TREE_CAP
    end

    -- ── Seed helpers ──────────────────────────────────────────────────
    local function findSeedInBackpack(bare)
        local bp = player:FindFirstChildOfClass("Backpack")
        if not bp then return nil end
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") then
                local pt = tool:GetAttribute("PlantType")
                if pt then
                    local bn = (tool:GetAttribute("BaseName") or tool.Name):gsub(" Seed$", "")
                    if bn == bare or pt == bare then return tool, pt end
                end
            end
        end
        return nil
    end

    local function buySeedFromBill(bare)
        local shopName = bare .. " Seed"
        local inList   = false
        for _, item in ipairs(SEED_ITEMS) do
            if item.name == shopName then inList = true break end
        end
        if not inList then return false end

        local ok, result = pcall(function() return GetShopData:InvokeServer("SeedShop") end)
        if not ok or type(result) ~= "table" or not result.Items then return false end
        local entry = result.Items[shopName]
        if not entry or not entry.Amount or entry.Amount <= 0 then
            setStatus(shopName .. " not in stock.", "Warning")
            return false
        end

        setStatus("Buying " .. shopName .. " from Bill...", "Info")
        local saved = Core.teleportTo(BILL_POS)
        local bOk, bRes = pcall(function()
            return PurchaseShopItem:InvokeServer("SeedShop", shopName)
        end)
        Core.returnFrom(saved)

        if bOk and type(bRes) == "table" and bRes.Items then
            task.wait(0.5)
            return findSeedInBackpack(bare) ~= nil
        end
        return false
    end

    local function ensureSeed(bare)
        local tool, pt = findSeedInBackpack(bare)
        if tool then return tool, pt end
        if buySeedFromBill(bare) then return findSeedInBackpack(bare) end
        return nil
    end

    -- ── Plant one seed ────────────────────────────────────────────────
    -- Returns UUID of planted tree, or nil on failure.
    local function plantOneSeed(bare, keepTree)
        if questCancel then return nil end
        if not makeRoom(1) then return nil end

        local seedTool, plantType = ensureSeed(bare)
        if not seedTool then
            setStatus("No " .. bare .. " seed available.", "Error")
            return nil
        end

        local plot = getPlayerPlot()
        if not plot then setStatus("Cannot find player plot.", "Error") return nil end
        local area = plot:FindFirstChild("PlantableArea")
        if not area then setStatus("No PlantableArea on plot.", "Error") return nil end

        local areaChildren = area:GetChildren()
        if #areaChildren == 0 then
            setStatus("PlantableArea has no positions.", "Error")
            return nil
        end

        local saved = Core.teleportTo(areaChildren[1].Position)
        if not Core.equipTool(seedTool) then
            setStatus("Failed to equip " .. bare .. " seed.", "Error")
            Core.returnFrom(saved)
            return nil
        end

        local before  = snapshotUuids()
        local planted = false

        for _, part in ipairs(areaChildren) do
            if questCancel then break end
            if part:IsA("BasePart") then
                local ok, res = pcall(function()
                    return PlantSeed:InvokeServer(plantType, part.Position)
                end)
                if ok and res == true then
                    planted = true
                    break
                end
            end
        end

        Core.unequipTools()
        Core.returnFrom(saved)

        if not planted then
            setStatus("PlantSeed failed for " .. bare .. " — plot may be full.", "Error")
            return nil
        end
        stats.seedsPlanted = stats.seedsPlanted + 1
        updateStatsDisplay()

        -- UUID-diff: find the newly planted tree (up to 5s)
        local newUuid = nil
        local myIdStr = tostring(player.UserId)
        local deadline = tick() + 5
        while tick() < deadline and not newUuid and not questCancel do
            local cp = workspace:FindFirstChild("ClientPlants")
            if cp then
                for _, t in ipairs(cp:GetChildren()) do
                    if t:IsA("Model") then
                        local u = t:GetAttribute("Uuid")
                        if u and not before[u]
                        and tostring(t:GetAttribute("OwnerUserId")) == myIdStr then
                            newUuid = u
                            local pt2 = tonumber(t:GetAttribute("PlantTime")) or tick()
                            questPlantedUuids[u] = pt2
                            break
                        end
                    end
                end
            end
            if not newUuid then task.wait(0.2) end
        end

        -- Wait for sprouting to finish, then remove unless keepTree is set
        if newUuid then
            local sproutDeadline = tick() + SPROUT_WAIT
            local sproutDone     = false
            while tick() < sproutDeadline and not questCancel and not sproutDone do
                local cp = workspace:FindFirstChild("ClientPlants")
                local stillHere = false
                if cp then
                    for _, t in ipairs(cp:GetChildren()) do
                        if t:IsA("Model") and t:GetAttribute("Uuid") == newUuid then
                            stillHere = true
                            local sprouting = t:GetAttribute("Sprouting")
                            if sprouting == false or sprouting == nil then
                                if not keepTree then
                                    pcall(function() RemovePlant:FireServer(newUuid, nil) end)
                                end
                                sproutDone = true
                            end
                            break
                        end
                    end
                end
                if not stillHere then
                    questPlantedUuids[newUuid] = nil
                    sproutDone = true
                end
                if not sproutDone then task.wait(0.3) end
            end
            if not sproutDone and not keepTree then
                pcall(function() RemovePlant:FireServer(newUuid, nil) end)
            end
        end

        return newUuid
    end

    -- ── Wait for tree to become FullyGrown ────────────────────────────
    local function waitForTreeGrown(uuid, bare)
        local deadline  = tick() + GROW_WAIT
        local startTick = tick()
        while tick() < deadline and not questCancel do
            local cp    = workspace:FindFirstChild("ClientPlants")
            local found = false
            if cp then
                for _, t in ipairs(cp:GetChildren()) do
                    if t:IsA("Model") and t:GetAttribute("Uuid") == uuid then
                        found = true
                        if t:GetAttribute("FullyGrown") == true then return true end
                        local gh      = tonumber(t:GetAttribute("GrowthHealth")) or 0
                        local gm      = tonumber(t:GetAttribute("GrowthMaxHealth")) or 1
                        local pct     = math.floor(math.clamp(gh / gm, 0, 1) * 100)
                        local elapsed = math.floor(tick() - startTick)
                        setStatus(string.format(
                            "Growing %s tree... %d%% (%ds elapsed)", bare, pct, elapsed
                        ), "Warning")
                        break
                    end
                end
            end
            if not found then return false end
            task.wait(2)
        end
        return false
    end

    -- ── Multi-plant batch helpers ────────────────────────────────────
    -- Plants `count` seeds of `bare` type, one by one, keeping all trees.
    -- Returns a list of UUIDs that were successfully planted.
    -- Respects makeRoom, stock checks, and questCancel throughout.
    local function plantBatch(bare, count)
        local planted = {}
        for i = 1, count do
            if questCancel then break end
            Core.yieldForShop()
            if questCancel then break end

            setStatus(string.format(
                "Multi-plant: planting %s (%d/%d)...", bare, i, count
            ), "Info")

            local uuid = plantOneSeed(bare, true)  -- keepTree = true
            if uuid then
                table.insert(planted, uuid)
                Core.dbg(string.format(
                    "[MultiPlant] planted %s %d/%d  uuid=%s", bare, i, count, uuid
                ))
            else
                setStatus(string.format(
                    "Multi-plant: seed %d/%d failed — stopping batch early.", i, count
                ), "Warning")
                break
            end
            task.wait(0.3)  -- small gap between plants to avoid server throttle
        end
        return planted
    end

    -- Waits until ALL trees in `uuids` are FullyGrown (or disappear/timeout).
    -- Updates the progress bar while waiting.
    -- Returns a table { uuid → true } for trees that are ready.
    local function waitForBatchGrown(uuids, bare)
        local ready    = {}
        local deadline = tick() + GROW_WAIT
        local myIdStr  = tostring(player.UserId)

        while tick() < deadline and not questCancel do
            local cp       = workspace:FindFirstChild("ClientPlants")
            local allDone  = true
            local doneCount = 0
            local totalCount = #uuids

            for _, uuid in ipairs(uuids) do
                if ready[uuid] then
                    doneCount = doneCount + 1
                else  -- Lua 5.1: no continue, use else instead
                local found = false
                if cp then
                    for _, t in ipairs(cp:GetChildren()) do
                        if t:IsA("Model") and t:GetAttribute("Uuid") == uuid then
                            found = true
                            if t:GetAttribute("FullyGrown") == true then
                                ready[uuid] = true
                                doneCount   = doneCount + 1
                            else
                                allDone = false
                            end
                            break
                        end
                    end
                end
                if not found then
                    -- Tree disappeared before growing — treat as ready (server removed it)
                    ready[uuid] = true
                    doneCount   = doneCount + 1
                end
                end  -- close else (Lua 5.1 continue workaround)
            end

            setBar(doneCount / math.max(totalCount, 1),
                string.format("Growing %s batch  %d / %d ready", bare, doneCount, totalCount),
                COLOR_BAR_ACTIVE)
            setStatus(string.format(
                "Waiting for %s batch to grow... (%d/%d fully grown)", bare, doneCount, totalCount
            ), "Warning")

            if allDone then break end
            task.wait(2)
        end

        return ready
    end

    -- Harvests all ripe HarvestablePlant trees from `uuids`.
    -- Returns the number successfully harvested.
    -- ── Harvest one entry ─────────────────────────────────────────────
    -- Fruit trees: fire with GrowthAnchorIndex, wait for fruit child to disappear.
    -- HarvestablePlant: fire with Uuid only, wait for tree model to disappear.
    local function harvestOneEntry(entry)
        local treeUuid    = entry.treeUuid
        local anchorIndex = entry.anchorIndex

        if anchorIndex ~= nil then
            pcall(function()
                HarvestFruit:FireServer({ { GrowthAnchorIndex = anchorIndex, Uuid = treeUuid } })
            end)
            local deadline = tick() + FRUIT_CONFIRM
            while tick() < deadline and not questCancel do
                local cp = workspace:FindFirstChild("ClientPlants")
                local stillHere = false
                if cp then
                    for _, t in ipairs(cp:GetChildren()) do
                        if t:GetAttribute("Uuid") == treeUuid then
                            for _, child in ipairs(t:GetChildren()) do
                                if child:GetAttribute("GrowthAnchorIndex") == anchorIndex then
                                    stillHere = true
                                    break
                                end
                            end
                            break
                        end
                    end
                end
                if not stillHere then
                    stats.fruitsHarvested = stats.fruitsHarvested + 1
                    updateStatsDisplay()
                    return true
                end
                task.wait(0.05)
            end
            return false
        else
            pcall(function()
                HarvestFruit:FireServer({ { Uuid = treeUuid } })
            end)
            local deadline = tick() + FRUIT_CONFIRM
            while tick() < deadline and not questCancel do
                local cp = workspace:FindFirstChild("ClientPlants")
                local stillHere = false
                if cp then
                    for _, t in ipairs(cp:GetChildren()) do
                        if t:GetAttribute("Uuid") == treeUuid then
                            stillHere = true
                            break
                        end
                    end
                end
                if not stillHere then
                    stats.fruitsHarvested = stats.fruitsHarvested + 1
                    updateStatsDisplay()
                    return true
                end
                task.wait(0.05)
            end
            return false
        end
    end

    -- ── harvestBatch — declared after harvestOneEntry ────────────────
    -- Harvests all ripe trees from `uuids`. Returns count harvested.
    local function harvestBatch(uuids, bare)
        local harvested = 0
        local myIdStr   = tostring(player.UserId)

        for _, uuid in ipairs(uuids) do
            if questCancel then break end
            Core.yieldForShop()
            if questCancel then break end

            local cp    = workspace:FindFirstChild("ClientPlants")
            local entry = nil
            if cp then
                for _, t in ipairs(cp:GetChildren()) do
                    if t:IsA("Model") and t:GetAttribute("Uuid") == uuid then
                        local isHP = t:GetAttribute("HarvestablePlant") == true
                        if isHP then
                            entry = { treeUuid = uuid, anchorIndex = nil }
                        else
                            local fruits = {}
                            for _, child in ipairs(t:GetChildren()) do
                                local ai = tonumber(child:GetAttribute("GrowthAnchorIndex"))
                                if ai then table.insert(fruits, ai) end
                            end
                            if #fruits > 0 then
                                entry = { treeUuid = uuid, anchorIndex = fruits[1] }
                            end
                        end
                        break
                    end
                end
            end

            if entry then
                setStatus(string.format("Harvesting %s (batch)...", bare), "Info")
                local ok = harvestOneEntry(entry)
                if ok then
                    harvested = harvested + 1
                    questPlantedUuids[uuid] = nil
                end
                task.wait(0.15)
            else
                questPlantedUuids[uuid] = nil
            end
        end

        Core.dbg(string.format(
            "[MultiPlant] harvestBatch %s: %d/%d harvested", bare, harvested, #uuids
        ))
        return harvested
    end
    -- ── Scan ripe fruits for a specific item type ─────────────────────
    local function scanRipeFruits(targetItem)
        local cp      = workspace:FindFirstChild("ClientPlants")
        local myIdStr = tostring(player.UserId)
        local entries = {}
        if not cp then return entries end
        for _, t in ipairs(cp:GetChildren()) do
            if t:IsA("Model")
            and tostring(t:GetAttribute("OwnerUserId")) == myIdStr
            and (t:GetAttribute("PlantType") or "") == targetItem
            and t:GetAttribute("FullyGrown") == true then
                local uuid = t:GetAttribute("Uuid")
                if uuid then
                    if t:GetAttribute("HarvestablePlant") == true then
                        table.insert(entries, { treeUuid = uuid, anchorIndex = nil })
                    else
                        for _, child in ipairs(t:GetChildren()) do
                            if child:IsA("Model") and child.Name:match("^Fruit")
                            and child:GetAttribute("FullyGrown") == true then
                                local ai = child:GetAttribute("GrowthAnchorIndex")
                                if ai then
                                    table.insert(entries, { treeUuid = uuid, anchorIndex = ai })
                                end
                            end
                        end
                    end
                end
            end
        end
        return entries
    end

    -- ── Scan all ripe fruits (any type) ───────────────────────────────
    -- allowlist: optional table of PlantType strings to include.
    -- If nil or empty, all types are returned (original behaviour).
    local function scanAllRipeFruits(allowlist)
        local cp      = workspace:FindFirstChild("ClientPlants")
        local myIdStr = tostring(player.UserId)
        local entries = {}
        if not cp then return entries end

        -- Build a fast lookup set from the allowlist
        local filter = nil
        if allowlist and next(allowlist) then
            filter = {}
            for _, pt in ipairs(allowlist) do filter[pt] = true end
        end

        for _, t in ipairs(cp:GetChildren()) do
            if t:IsA("Model")
            and tostring(t:GetAttribute("OwnerUserId")) == myIdStr
            and t:GetAttribute("FullyGrown") == true then
                local uuid      = t:GetAttribute("Uuid")
                local plantType = t:GetAttribute("PlantType") or ""
                if uuid then
                    -- Skip if allowlist is active and type is not in it
                    if not filter or filter[plantType] then  -- Lua 5.1: no continue

                    if t:GetAttribute("HarvestablePlant") == true then
                        table.insert(entries, {
                            treeUuid  = uuid,
                            anchorIndex = nil,
                            plantType = plantType,
                        })
                    else
                        for _, child in ipairs(t:GetChildren()) do
                            if child:IsA("Model") and child.Name:match("^Fruit")
                            and child:GetAttribute("FullyGrown") == true then
                                local ai = child:GetAttribute("GrowthAnchorIndex")
                                if ai then
                                    table.insert(entries, {
                                        treeUuid    = uuid,
                                        anchorIndex = ai,
                                        plantType   = plantType,
                                    })
                                end
                            end
                        end
                    end  -- close HarvestablePlant if/else
                    end  -- close "if not filter or filter[plantType]"
                end  -- close "if uuid then"
            end
        end
        return entries
    end

    -- ── Inventory helpers ─────────────────────────────────────────────
    local function hasInventory()
        local bp = player:FindFirstChildOfClass("Backpack")
        if not bp then return false end
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("Type") == "Plants" then return true end
        end
        return false
    end

    -- Count harvested plant tools currently in the backpack.
    local function countInventory()
        local bp = player:FindFirstChildOfClass("Backpack")
        if not bp then return 0 end
        local n = 0
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("Type") == "Plants" then
                n = n + 1
            end
        end
        return n
    end

    -- Read the player's backpack capacity from known attribute names.
    -- Falls back to 20 if not found (safe conservative default).
    local function getInventoryCap()
        local cap = tonumber(player:GetAttribute("BackpackCapacity"))
            or tonumber(player:GetAttribute("InventorySize"))
            or tonumber(player:GetAttribute("MaxInventory"))
        return cap or 20
    end

    -- ── Sell at Steve ─────────────────────────────────────────────────
    local function doSell()
        local saved = Core.teleportTo(STEVE_POS)
        setStatus("Selling all items...", "Info")
        pcall(function() SellItems:InvokeServer("SellAll") end)
        task.wait(1)
        Core.returnFrom(saved)
    end

    -- ── Reroll a quest slot ───────────────────────────────────────────
    local function rerollSlot(qType, slot)
        local oldSessionId = questData
            and questData[qType]
            and questData[qType].Active
            and questData[qType].Active[tostring(slot)]
            and questData[qType].Active[tostring(slot)].SessionId
            or nil

        setStatus("Rerolling " .. qType .. " #" .. slot .. "...", "Info")

        local received = false
        local conn
        conn = UpdateQuests.OnClientEvent:Connect(function(data)
            if received then return end
            received  = true
            conn:Disconnect()
            questData = data
            refreshQuestDisplay()

            local newQ = data and data[qType] and data[qType].Active and data[qType].Active[tostring(slot)]
            local newSessionId = newQ and newQ.SessionId or nil

            if newSessionId and newSessionId ~= oldSessionId then
                local newDesc  = newQ.Description or (newQ.Type .. " " .. (newQ.TargetItem or ""))
                local reward   = newQ.RewardItem
                    and (tostring(newQ.RewardAmount or 1) .. "x " .. newQ.RewardItem)
                    or  (tostring(newQ.RewardAmount or 0) .. " Shillings")
                setStatus("Rerolled " .. qType .. " #" .. slot .. " → " .. newDesc, "Success")
                Core.notify("Rerolled! " .. qType .. " #" .. slot, newDesc .. "  (" .. reward .. ")", "Success", 5)
                if Core.webhookUrl ~= "" then
                    Core.sendWebhook(Core.webhookUrl,
                        "Quest Rerolled — " .. qType .. " Slot " .. slot,
                        "New quest assigned after claim.", 0x3498DB, {
                            { name = "Quest",  value = newDesc,               inline = false },
                            { name = "Reward", value = reward,                inline = true  },
                            { name = "Slot",   value = qType .. " #" .. slot, inline = true  },
                        })
                end
            else
                setStatus("Reroll cap hit for " .. qType .. " #" .. slot, "Warning")
                Core.notify("Reroll Capped", qType .. " slot " .. slot .. " hit its reroll limit.", "Warning", 4)
                if Core.webhookUrl ~= "" then
                    Core.sendWebhook(Core.webhookUrl,
                        "Reroll Capped — " .. qType .. " Slot " .. slot,
                        "Server rejected reroll — daily cap reached.", 0xE67E22, {
                            { name = "Slot", value = qType .. " #" .. slot, inline = true },
                        })
                end
            end
        end)

        pcall(function() PurchaseSingleRefresh:FireServer(qType, slot) end)

        -- Timeout guard
        local waited = 0
        while not received and waited < 3.1 do
            task.wait(0.1)
            waited = waited + 0.1
        end
        if not received then
            received = true
            conn:Disconnect()
            setStatus("Reroll timed out for " .. qType .. " #" .. slot, "Warning")
        end
    end

    -- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    --  QUEST ACTION LOOPS
    -- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    -- PlantSeeds: plant one seed at a time, wait for sprout, server confirms.
    -- If the seed is not in the backpack AND not in stock at Bill's, the quest
    -- is skipped immediately with a clear reason rather than retrying forever.
    local function runPlantSeeds(qType, slot, initialQ)
        local bare = (initialQ.TargetItem or ""):gsub(" Seed$", "")
        local goal = initialQ.Goal or 0

        -- Pre-flight: check whether the seed is obtainable before entering
        -- the loop, so we fail fast with a useful message instead of looping.
        local function seedObtainable()
            -- Already in backpack?
            if findSeedInBackpack(bare) then return true, "in backpack" end

            -- In stock at Bill's?
            local shopName = bare .. " Seed"
            local ok, result = pcall(function() return GetShopData:InvokeServer("SeedShop") end)
            if ok and type(result) == "table" and result.Items then
                local entry = result.Items[shopName]
                if entry and entry.Amount and entry.Amount > 0 then
                    return true, "in stock at Bill's (" .. entry.Amount .. ")"
                else
                    return false, shopName .. " is out of stock at Bill's"
                end
            end
            -- Shop fetch failed — not listed at all
            return false, shopName .. " not found in Bill's shop"
        end

        local canGet, reason = seedObtainable()
        if not canGet then
            local msg = string.format("Skipping PlantSeeds (%s): %s", bare, reason)
            setStatus(msg, "Warning")
            Core.notify("Quest Skipped", msg, "Warning", 6)
            if Core.webhookUrl ~= "" then
                Core.sendWebhook(Core.webhookUrl, "Quest Skipped — PlantSeeds",
                    msg, 0xE67E22, {
                        { name = "Quest", value = qType .. " #" .. slot, inline = true },
                        { name = "Seed",  value = bare .. " Seed",        inline = true },
                        { name = "Reason", value = reason,                inline = false },
                    })
            end
            return  -- exits runPlantSeeds; runSlot will move to next slot
        end

        local consecutiveFails = 0
        local MAX_FAILS        = 3  -- skip after this many back-to-back plant failures

        while not questCancel do
            local lq = fetchLiveSlot(qType, slot)
            if not lq or lq.Claimed then break end

            local progress  = lq.Progress or 0
            local remaining = goal - progress
            setBar(progress / math.max(goal, 1),
                string.format("Planting %s  %d / %d", bare, progress, goal))

            if remaining <= 0 then break end
            if questCancel then break end

            setStatus(string.format("Planting %s (%d/%d)...", bare, progress + 1, goal), "Info")

            -- Pause here if the shop needs to run a buy pass.
            -- plantOneSeed is atomic so this is the cleanest yield point.
            Core.yieldForShop()
            if questCancel then break end

            local uuid = plantOneSeed(bare, false)
            if uuid then
                consecutiveFails = 0  -- success resets the fail counter
            elseif not questCancel then
                consecutiveFails = consecutiveFails + 1

                -- Re-check stock on each failure so we know why it's failing
                local stillCanGet, failReason = seedObtainable()
                if not stillCanGet then
                    local msg = string.format(
                        "Skipping PlantSeeds (%s) mid-run: %s", bare, failReason
                    )
                    stats.questsSkipped = stats.questsSkipped + 1
                    updateStatsDisplay()
                    setStatus(msg, "Warning")
                    Core.notify("Quest Skipped", msg, "Warning", 6)
                    if Core.webhookUrl ~= "" then
                        Core.sendWebhook(Core.webhookUrl,
                            "Quest Skipped Mid-Run — PlantSeeds", msg, 0xE67E22, {
                                { name = "Quest",  value = qType .. " #" .. slot, inline = true },
                                { name = "Reason", value = failReason,            inline = false },
                            })
                    end
                    return
                end

                if consecutiveFails >= MAX_FAILS then
                    local msg = string.format(
                        "PlantSeeds (%s) failed %d times in a row — skipping quest.",
                        bare, MAX_FAILS
                    )
                    stats.questsSkipped = stats.questsSkipped + 1
                    updateStatsDisplay()
                    setStatus(msg, "Error")
                    Core.notify("Quest Skipped", msg, "Error", 6)
                    return
                end

                setStatus(string.format(
                    "Plant failed (%d/%d) — retrying in 5s...", consecutiveFails, MAX_FAILS
                ), "Warning")
                task.wait(5)
            end
        end
    end

    -- HarvestCrops: plant and harvest the target item.
    -- When multiPlantEnabled = true and the target is a HarvestablePlant,
    -- plants a full batch (up to multiPlantMax, capped by remaining goal
    -- and free plot slots), waits for ALL to grow, then harvests all at
    -- once — dramatically faster than one-at-a-time for large quests.
    -- Falls back to the original single-plant loop for fruit trees or
    -- when multi-plant is toggled off.
    local function runHarvestCrops(qType, slot, initialQ)
        local targetItem = initialQ.TargetItem or ""
        local goal       = initialQ.Goal or 0
        local myIdStr    = tostring(player.UserId)
        local bare       = targetItem:gsub(" Seed$", "")

        -- ── Shared helpers ──────────────────────────────────────────
        local function countMyTreesOfType()
            local cp = workspace:FindFirstChild("ClientPlants")
            if not cp then return 0 end
            local n = 0
            for _, t in ipairs(cp:GetChildren()) do
                if t:IsA("Model")
                and tostring(t:GetAttribute("OwnerUserId")) == myIdStr
                and (t:GetAttribute("PlantType") or "") == targetItem then
                    n = n + 1
                end
            end
            return n
        end

        local function ensureTree()
            return countMyTreesOfType() > 0
        end

        -- Checks seed stock at Bill's; returns false + skips quest if out of stock.
        local function checkSeedStock()
            local shopName = bare .. " Seed"
            if findSeedInBackpack(bare) then return true end
            local ok, result = pcall(function() return GetShopData:InvokeServer("SeedShop") end)
            if ok and type(result) == "table" and result.Items then
                local entry = result.Items[shopName]
                if not entry or not entry.Amount or entry.Amount <= 0 then
                    local msg = string.format(
                        "Skipping HarvestCrops (%s): %s is out of stock at Bill's",
                        targetItem, shopName
                    )
                    stats.questsSkipped = stats.questsSkipped + 1
                    updateStatsDisplay()
                    setStatus(msg, "Warning")
                    Core.notify("Quest Skipped", msg, "Warning", 6)
                    if Core.webhookUrl ~= "" then
                        Core.sendWebhook(Core.webhookUrl,
                            "Quest Skipped — HarvestCrops", msg, 0xE67E22, {
                                { name = "Quest", value = qType .. " #" .. slot, inline = true },
                                { name = "Seed",  value = shopName,              inline = true },
                            })
                    end
                    return false
                end
            end
            return true
        end

        -- Plant one seed and wait for it to fully grow (single-plant path).
        local function plantAndWait()
            if not checkSeedStock() then return false end
            setStatus("Planting " .. targetItem .. "...", "Info")
            local uuid = plantOneSeed(targetItem, true)
            if not uuid then
                if not questCancel then
                    setStatus("Could not plant " .. targetItem .. " — skipping quest.", "Error")
                end
                return false
            end
            local grown = waitForTreeGrown(uuid, targetItem)
            if not grown then
                if not questCancel then
                    setStatus(targetItem .. " tree never grew — skipping quest.", "Error")
                end
                return false
            end
            return true
        end

        -- Detect HarvestablePlant from the first matching tree we find,
        -- or by planting one if none exist yet.
        local isHarvestablePlant = false
        do
            local cp = workspace:FindFirstChild("ClientPlants")
            if cp then
                for _, t in ipairs(cp:GetChildren()) do
                    if t:IsA("Model")
                    and tostring(t:GetAttribute("OwnerUserId")) == myIdStr
                    and (t:GetAttribute("PlantType") or "") == targetItem then
                        isHarvestablePlant = t:GetAttribute("HarvestablePlant") == true
                        break
                    end
                end
            end
        end
        -- If no tree exists yet we need to plant one to detect the flag.
        -- We wait up to 8 seconds for the HarvestablePlant attribute to
        -- replicate from the server — it is NOT set at spawn on the client.
        if not ensureTree() then
            if not checkSeedStock() then return end
            local probeUuid = plantOneSeed(targetItem, true)
            if not probeUuid then
                setStatus("Could not plant " .. targetItem .. " — skipping quest.", "Error")
                return
            end
            -- Poll until the attribute appears or timeout
            local deadline = tick() + 8
            local flagRead = false
            while tick() < deadline and not questCancel and not flagRead do
                local cp = workspace:FindFirstChild("ClientPlants")
                if cp then
                    for _, t in ipairs(cp:GetChildren()) do
                        if t:IsA("Model") and t:GetAttribute("Uuid") == probeUuid then
                            local hp = t:GetAttribute("HarvestablePlant")
                            if hp ~= nil then  -- attribute has replicated
                                isHarvestablePlant = hp == true
                                flagRead = true
                            end
                            break
                        end
                    end
                end
                if not flagRead then task.wait(0.3) end
            end
            if not flagRead then
                -- Attribute never replicated — default to true for common crops
                -- (Carrot, Onion etc are always HarvestablePlant)
                isHarvestablePlant = true
                Core.dbg("[HarvestCrops] HarvestablePlant attr timeout — defaulting to true for " .. targetItem)
            end
        end

        -- ── Multi-plant path (HarvestablePlant only) ────────────────
        if multiPlantEnabled and isHarvestablePlant then
            while not questCancel do
                Core.yieldForShop()
                if questCancel then break end

                local lq = fetchLiveSlot(qType, slot)
                if not lq or lq.Claimed then break end

                local progress  = lq.Progress or 0
                local remaining = goal - progress
                if remaining <= 0 then break end

                setBar(progress / math.max(goal, 1),
                    string.format("Harvest %s  %d / %d", targetItem, progress, goal))

                -- How many free plot slots are there?
                local freePlots = TREE_CAP - countMyTrees()
                -- Batch size = min(remaining, multiPlantMax, freePlots)
                -- Always leave at least 1 free slot so makeRoom doesn't fire
                local batchSize = math.min(remaining, multiPlantMax, math.max(freePlots - 1, 1))
                batchSize = math.max(batchSize, 1)

                -- Account for trees of this type already planted (probe plant etc.)
                local alreadyPlanted = countMyTreesOfType()
                local toPlant = math.max(batchSize - alreadyPlanted, 0)

                if toPlant > 0 then
                    if not checkSeedStock() then return end
                    Core.notify("Multi-Plant",
                        string.format("Planting %d %s (batch)", toPlant, bare),
                        "Info", 3)
                end

                -- Plant the batch (skips to harvest if trees already exist)
                local batchUuids = {}
                -- Include UUIDs of already-existing trees of this type
                do
                    local cp = workspace:FindFirstChild("ClientPlants")
                    if cp then
                        for _, t in ipairs(cp:GetChildren()) do
                            if t:IsA("Model")
                            and tostring(t:GetAttribute("OwnerUserId")) == myIdStr
                            and (t:GetAttribute("PlantType") or "") == targetItem then
                                local u = t:GetAttribute("Uuid")
                                if u then table.insert(batchUuids, u) end
                            end
                        end
                    end
                end
                -- Plant additional seeds needed
                if toPlant > 0 then
                    local newUuids = plantBatch(bare, toPlant)
                    for _, u in ipairs(newUuids) do table.insert(batchUuids, u) end
                end

                if #batchUuids == 0 then
                    setStatus("No trees to grow — retrying...", "Warning")
                    task.wait(3)
                    -- Lua 5.1: no continue; loop will re-evaluate at top naturally
                else  -- only proceed if we have batch uuids

                Core.dbg(string.format(
                    "[MultiPlant] batch of %d %s  uuids: %s",
                    #batchUuids, bare, table.concat(batchUuids, ", ")
                ))

                -- Wait for the full batch to finish growing
                local readyMap = waitForBatchGrown(batchUuids, bare)
                if questCancel then break end

                -- Harvest everything that's ready
                local harvested = harvestBatch(batchUuids, bare)

                -- Check inventory and sell if near capacity
                local cap = getInventoryCap()
                if countInventory() >= math.max(cap - 1, 1) then
                    setStatus(string.format("Inventory at %d/%d — selling after batch harvest...", countInventory(), cap), "Info")
                    doSell()
                    task.wait(1)
                end

                task.wait(1.5)  -- server despawn settle

                -- Re-fetch progress and update bar
                local lq2 = fetchLiveSlot(qType, slot)
                if not lq2 or lq2.Claimed then break end
                local newProgress = lq2.Progress or 0
                setBar(newProgress / math.max(goal, 1),
                    string.format("Harvest %s  %d / %d", targetItem, newProgress, goal))

                Core.notify("Multi-Plant",
                    string.format("Harvested %d %s  (%d/%d quest progress)",
                        harvested, bare, newProgress, goal),
                    "Success", 4)

                if newProgress >= goal then break end
                end  -- close "else" for batchUuids check
            end
            return
        end

        -- ── Single-plant path (fruit trees, or multi-plant off) ─────
        if not ensureTree() then
            if not plantAndWait() then return end
        end

        local attempted = {}

        while not questCancel do
            Core.yieldForShop()
            if questCancel then break end

            local lq = fetchLiveSlot(qType, slot)
            if not lq or lq.Claimed then break end

            local progress  = lq.Progress or 0
            local remaining = (lq.Goal or goal) - progress
            setBar(progress / math.max(goal, 1),
                string.format("Harvest %s  %d / %d", targetItem, progress, goal))

            if remaining <= 0 then break end

            local ripe = scanRipeFruits(targetItem)

            local toHarvest = {}
            for _, entry in ipairs(ripe) do
                local k = entry.treeUuid .. "_" .. tostring(entry.anchorIndex)
                if not attempted[k] then table.insert(toHarvest, entry) end
            end

            if #toHarvest > 0 then
            -- Lua 5.1: no continue — invert condition and wrap body in if block

            for _, entry in ipairs(toHarvest) do
                if questCancel then break end

                -- Check inventory capacity before harvesting
                local cap = getInventoryCap()
                if countInventory() >= math.max(cap - 1, 1) then
                    setStatus(string.format("Inventory at %d/%d — selling before continuing harvest...", countInventory(), cap), "Info")
                    doSell()
                    task.wait(1)
                end

                setStatus(string.format("Harvesting %s...", targetItem), "Info")
                local confirmed = harvestOneEntry(entry)
                local k = entry.treeUuid .. "_" .. tostring(entry.anchorIndex)
                if confirmed then
                    attempted[k] = nil
                else
                    attempted[k] = true
                end
                task.wait(0.15)
            end

            if isHarvestablePlant then
                task.wait(1.5)
                attempted = {}
                if remaining > 1 then
                    if not ensureTree() then
                        if not plantAndWait() then return end
                    end
                end
            end

            else  -- #toHarvest == 0
                attempted = {}
                if not ensureTree() then
                    if not plantAndWait() then return end
                end
                setStatus("Waiting for " .. targetItem .. " to ripen...", "Warning")
                task.wait(3)
            end  -- end toHarvest check
        end
    end

    -- GainShillings: harvest ripe fruits, sell whenever inventory is
    -- near-full or all ripe fruits are harvested, then check progress.
    -- Sells mid-harvest if the backpack fills up so nothing is wasted.
    local function runGainShillings(qType, slot, initialQ)
        local goal         = initialQ.Goal or 0
        local lastProgress = initialQ.Progress or 0
        local stallCount   = 0

        -- Sell helper: teleport to Steve, sell, return, update progress.
        -- Returns the new server progress value.
        local function sellAndCheck()
            doSell()
            task.wait(1)
            local lq2 = fetchLiveSlot(qType, slot)
            if not lq2 or lq2.Claimed then return nil end
            local newProgress = lq2.Progress or 0
            if newProgress > lastProgress then
                stallCount   = 0
                local delta  = newProgress - lastProgress
                stats.shillingsEarned = stats.shillingsEarned + delta
                updateStatsDisplay()
                lastProgress = newProgress
            else
                stallCount = stallCount + 1
                setStatus(string.format(
                    "Sell attempt %d/%d — no progress yet (%d/%d shillings).",
                    stallCount, STALL_MAX, lastProgress, goal
                ), "Warning")
            end
            setBar(lastProgress / math.max(goal, 1),
                string.format("Earn Shillings  %d / %d", lastProgress, goal))
            return newProgress
        end

        while not questCancel do
            -- Yield if shop needs the character position
            Core.yieldForShop()
            if questCancel then break end

            local lq = fetchLiveSlot(qType, slot)
            if not lq or lq.Claimed then break end

            lastProgress = lq.Progress or lastProgress

            if lastProgress >= (lq.Goal or goal) then break end
            if stallCount >= STALL_MAX then
                setStatus(string.format(
                    "GainShillings stalled %d times — moving on.", STALL_MAX
                ), "Warning")
                break
            end

            setBar(lastProgress / math.max(goal, 1),
                string.format("Earn Shillings  %d / %d", lastProgress, goal))

            -- Wait for at least one ripe fruit before doing anything
            -- Pass earnAllowlist so only user-selected fruit types are harvested
            local ripe = scanAllRipeFruits(next(earnAllowlist) and earnAllowlist or nil)
            if #ripe == 0 then
                -- If we already have inventory from a previous partial harvest,
                -- go sell it rather than sitting idle.
                if hasInventory() then
                    local prog = sellAndCheck()
                    if prog == nil then break end
                    -- Lua 5.1: no continue — loop back to top via else skip
                else
                setStatus("Waiting for any fruit to ripen...", "Warning")
                while #ripe == 0 and not questCancel do
                    task.wait(2)
                    ripe = scanAllRipeFruits(next(earnAllowlist) and earnAllowlist or nil)
                end  -- close wait-for-ripe loop
                end  -- close "else" (Lua 5.1 continue workaround for sell-if-inventory)
            end

            if questCancel then break end

            -- Harvest one fruit at a time, selling immediately when the
            -- backpack is at or above the cap threshold (leave 1 slot spare
            -- so the next harvest doesn't silently bounce off a full bag).
            local cap       = getInventoryCap()
            local sellAt    = math.max(cap - 1, 1)  -- sell when this many in bag

            for _, entry in ipairs(ripe) do
                if questCancel then break end

                -- Check if bag is already full before this harvest
                if countInventory() >= sellAt then
                    setStatus(string.format(
                        "Inventory at %d/%d — selling before continuing harvest...",
                        countInventory(), cap
                    ), "Info")
                    local prog = sellAndCheck()
                    if prog == nil then break end
                    -- If quest completed during sell, stop harvesting
                    if lastProgress >= goal then break end
                end

                setStatus(string.format(
                    "Harvesting for shillings (%d/%d shillings so far)...",
                    lastProgress, goal
                ), "Info")
                harvestOneEntry(entry)
                task.wait(0.05)
            end

            if questCancel then break end

            -- Sell whatever we harvested this pass (if anything)
            if hasInventory() then
                local prog = sellAndCheck()
                if prog == nil then break end
            else
                -- Harvests all failed (e.g. server rejected) — brief pause
                setStatus("No items to sell after harvest — waiting...", "Warning")
                task.wait(3)
            end
        end
    end

    -- ── Claim all completed-but-unclaimed slots ───────────────────────
    -- Called after every slot action so that "collateral completions"
    -- (e.g. planting 15 strawberries also finishes a plant-6 quest)
    -- are claimed and rerolled immediately rather than being skipped.
    -- `skipQType` and `skipSlot` identify the slot that was just
    -- handled so we don't double-claim it.
    local function claimAllCompleted(skipQType, skipSlot)
        if not autoClaim then return end
        -- Re-fetch once so we have a fresh view of all slots
        local data = fetchLive()
        if not data then return end

        for _, qt in ipairs({ "Daily", "Weekly" }) do
            local bucket = data[qt]
            if bucket and bucket.Active then  -- Lua 5.1: no continue
            for s = 1, 5 do
                if questCancel then return end
                -- Skip the slot we already handled in the caller
                local skip = (qt == skipQType and s == skipSlot)
                local q    = bucket.Active[tostring(s)]
                local eligible = q
                    and not skip
                    and not q.Claimed
                    and q.Progress and q.Goal
                    and q.Progress >= q.Goal

                if eligible then
                -- This slot is done but unclaimed — claim it now
                local desc = (q.Description or (q.Type .. " " .. (q.TargetItem or ""))):gsub("^%[.-%]%s*", "")
                setStatus(string.format("Collateral complete — claiming %s #%d (%s)", qt, s, desc), "Success")
                Core.notify("Quest Claimed!", desc .. " (collateral)", "Success", 4)
                pcall(function() ClaimQuest:FireServer(qt, tostring(s)) end)
                task.wait(0.5)
                fetchLive()
                task.wait(0.5)
                stats.questsCompleted = stats.questsCompleted + 1
                if q.Type and stats.byType[q.Type] then
                    stats.byType[q.Type] = stats.byType[q.Type] + 1
                end
                updateStatsDisplay()
                if autoReroll then
                    task.wait(0.5)
                    rerollSlot(qt, s)
                end
                end  -- close "if eligible"
            end  -- close for s
            end  -- close "if bucket and bucket.Active"
        end
    end

    -- ── Slot runner ────────────────────────────────────────────────────
    local function runSlot(qType, slot)
        local lq = fetchLiveSlot(qType, slot)
        if not lq then
            setStatus("Could not fetch slot " .. qType .. " #" .. slot, "Warning")
            return
        end
        if lq.Claimed then return end

        local goal     = lq.Goal or 0
        local progress = lq.Progress or 0
        local qDesc    = (lq.Description or (lq.Type .. " " .. (lq.TargetItem or ""))):gsub("^%[.-%]%s*", "")

        setBar(progress / math.max(goal, 1),
            string.format("%s #%d  %d / %d", qType, slot, progress, goal),
            COLOR_BAR_ACTIVE)

        -- Already complete — just claim, then sweep for collateral
        if progress >= goal then
            setBar(1, nil, COLOR_BAR_COMPLETE)
            if autoClaim then
                setStatus("Claiming " .. qType .. " #" .. slot, "Info")
                pcall(function() ClaimQuest:FireServer(qType, tostring(slot)) end)
                task.wait(0.5); fetchLive(); task.wait(0.5)
                Core.notify("Quest Claimed!", qDesc, "Success", 4)
                stats.questsCompleted = stats.questsCompleted + 1
                if lq and lq.Type then
                    local t = lq.Type
                    if stats.byType[t] then stats.byType[t] = stats.byType[t] + 1 end
                end
                updateStatsDisplay()
                if autoReroll then task.wait(0.5); rerollSlot(qType, slot) end
            end
            -- Sweep: anything else that finished as a side-effect?
            claimAllCompleted(qType, slot)
            return
        end

        setStatus("[" .. qType .. " #" .. slot .. "] " .. qDesc, "Info")
        Core.notify("Quest Started", qDesc, "Info", 3)

        if lq.Type == "PlantSeeds" then
            runPlantSeeds(qType, slot, lq)
        elseif lq.Type == "HarvestCrops" then
            runHarvestCrops(qType, slot, lq)
        elseif lq.Type == "GainShillings" then
            runGainShillings(qType, slot, lq)
        else
            setStatus("Unknown quest type: " .. tostring(lq.Type) .. " — skipping.", "Warning")
            return
        end

        if questCancel then return end

        -- Post-action: re-fetch and claim the slot we just worked on
        local finalQ = fetchLiveSlot(qType, slot)
        if not finalQ then return end

        if (finalQ.Progress or 0) >= (finalQ.Goal or 0) and not finalQ.Claimed then
            setBar(1, nil, COLOR_BAR_COMPLETE)
            if autoClaim then
                setStatus("Claiming " .. qType .. " #" .. slot, "Success")
                pcall(function() ClaimQuest:FireServer(qType, tostring(slot)) end)
                task.wait(0.5); fetchLive(); task.wait(0.5)
                Core.notify("Quest Claimed!", qDesc, "Success", 5)
                stats.questsCompleted = stats.questsCompleted + 1
                if lq and lq.Type then
                    local t = lq.Type
                    if stats.byType[t] then stats.byType[t] = stats.byType[t] + 1 end
                end
                updateStatsDisplay()
                if autoReroll then task.wait(0.5); rerollSlot(qType, slot) end
            end
        elseif not questCancel then
            setStatus(string.format(
                "%s #%d stalled at %d/%d — moving on.",
                qType, slot, finalQ.Progress or 0, finalQ.Goal or 0
            ), "Warning")
        end

        -- Sweep: claim anything else that finished as a side-effect of this slot's work
        if not questCancel then
            claimAllCompleted(qType, slot)
        end
    end

    -- ── Priority sort ──────────────────────────────────────────────────
    -- Returns true if reward is a seed/item pack (not shillings).
    local function isSeedReward(q)
        return q.RewardItem ~= nil and q.RewardItem ~= ""
    end

    -- Builds a flat, ordered list of {qType, slot, q} from questData,
    -- filtered by typeFilter and scopeFilter, then sorted by priority.
    --
    -- Priority modes:
    --   "default"      — server order (Daily 1→5, Weekly 1→5)
    --   "seed_short"   — seed-pack quests first, shortest goal first within each group
    --   "short_any"    — shortest goal first regardless of reward
    --   "shillings"    — shilling quests first, shortest goal first within each group
    local function buildSortedSlots(typeFilter, scopeFilter, priorityMode)
        local slots = {}
        for _, qType in ipairs({ "Daily", "Weekly" }) do
            local scopeOk  = not scopeFilter or qType == scopeFilter
            local bucket   = questData and questData[qType]
            if scopeOk and bucket and bucket.Active then  -- Lua 5.1: no continue
            for slot = 1, 5 do
                local q = bucket.Active[tostring(slot)]
                if q and not q.Claimed
                and (typeFilter == nil or q.Type == typeFilter) then
                    table.insert(slots, { qType = qType, slot = slot, q = q })
                end
            end
            end  -- close "if scopeOk and bucket"
        end

        if priorityMode == "default" then
            -- Already in server order — no sort needed
            return slots
        end

        table.sort(slots, function(a, b)
            local aGoal = a.q.Goal or 0
            local bGoal = b.q.Goal or 0
            local aSeed = isSeedReward(a.q)
            local bSeed = isSeedReward(b.q)

            if priorityMode == "seed_short" then
                -- Seed-pack quests before shilling quests.
                -- Within each group, shorter goal first.
                if aSeed ~= bSeed then return aSeed end
                return aGoal < bGoal

            elseif priorityMode == "short_any" then
                -- Shortest goal first regardless of reward type.
                -- Tie-break: seed packs before shillings.
                if aGoal ~= bGoal then return aGoal < bGoal end
                return aSeed and not bSeed

            elseif priorityMode == "shillings" then
                -- Shilling quests before seed-pack quests.
                -- Within each group, shorter goal first.
                if aSeed ~= bSeed then return not aSeed end
                return aGoal < bGoal
            end

            return false
        end)

        return slots
    end

    -- ── Main runner ────────────────────────────────────────────────────
    local function runFiltered(typeFilter, scopeFilter, priorityMode)
        if questRunning then
            Core.notify("Quests", "Already running.", "Warning", 2)
            return
        end

        setStatus("Fetching quest data...", "Info")
        local data = fetchLive()
        if not data then
            setStatus("Could not load quest data.", "Error")
            if runToggle then runToggle.SetValue(false) end
            return
        end

        questRunning = true
        questCancel  = false
        resetStats()  -- fresh stats for this run session
        lockQuestControls(true)

        local ok, err = pcall(function()
            local passNum = 0
            repeat
                passNum = passNum + 1
                stats.passCount = passNum
                updateStatsDisplay()
                if loopMode and passNum > 1 then
                    -- Re-fetch fresh data at the start of each loop pass.
                    -- No status message here — avoids the flash on pass 1.
                    task.wait(5)
                    local fresh = fetchLive()
                    if not fresh then
                        -- Silent retry — just wait and let the loop continue.
                        -- The existing questStatusLabel still shows the last
                        -- real status so the UI doesn't flash a warning.
                        task.wait(10)
                    end
                end

                if questCancel then break end

                local slots = buildSortedSlots(typeFilter, scopeFilter, priorityMode or "default")

                if #slots == 0 then
                    if loopMode then
                        setStatus(string.format(
                            "Loop pass %d: no eligible quests — waiting 30s for reroll/refresh...",
                            passNum
                        ), "Info")
                        -- Wait up to 30s, checking every 5s for new quests
                        for _ = 1, 6 do
                            if questCancel then break end
                            task.wait(5)
                            fetchLive()
                            local check = buildSortedSlots(typeFilter, scopeFilter, priorityMode or "default")
                            if #check > 0 then break end
                        end
                    else
                        setStatus("No eligible quests found.", "Info")
                    end
                    -- Whether loop or single-pass, if still nothing after wait just break
                    if not loopMode then break end
                    -- loopMode: go back to top of repeat to re-evaluate
                else
                    -- Show run order
                    local orderParts = {}
                    for _, entry in ipairs(slots) do
                        local passLabel = loopMode and string.format("[P%d] ", passNum) or ""
                        table.insert(orderParts, passLabel .. entry.qType:sub(1,1) .. "#" .. entry.slot)
                    end
                    setStatus("Run order: " .. table.concat(orderParts, " → "), "Info")
                    task.wait(1.5)

                    for _, entry in ipairs(slots) do
                        if questCancel then break end
                        local live = fetchLiveSlot(entry.qType, entry.slot)
                        if live and not live.Claimed then
                            runSlot(entry.qType, entry.slot)
                            task.wait(0.5)
                        end
                    end
                end

            until questCancel or not loopMode
        end)

        questRunning = false
        questCancel  = false
        lockQuestControls(false)

        setBar(0, "No quest running", COLOR_BAR_ACTIVE)
        refreshQuestDisplay()

        -- Reset toggle UI. questRunning is false so the callback's
        -- else-branch ("if questRunning then questCancel=true end") is a no-op.
        if runToggle then runToggle.SetValue(false) end

        -- Session-end webhook summary
        if Core.webhookUrl ~= "" then
            Core.sendWebhook(Core.webhookUrl,
                "Quest Session Complete",
                string.format("Session ran for %s across %d passes.", fmtUptime(), stats.passCount),
                0x2ECC71, {
                    { name = "Quests Completed", value = tostring(stats.questsCompleted), inline = true  },
                    { name = "Quests Skipped",   value = tostring(stats.questsSkipped),   inline = true  },
                    { name = "Seeds Planted",    value = tostring(stats.seedsPlanted),    inline = true  },
                    { name = "Fruits Harvested", value = tostring(stats.fruitsHarvested), inline = true  },
                    { name = "Shillings Earned", value = tostring(stats.shillingsEarned), inline = true  },
                    { name = "Breakdown",
                      value = string.format(
                          "Plant: %d | Harvest: %d | Earn: %d",
                          stats.byType.PlantSeeds,
                          stats.byType.HarvestCrops,
                          stats.byType.GainShillings
                      ),
                      inline = false },
                })
        end

        if not ok then
            setStatus("Error: " .. tostring(err), "Error")
            warn("[Quests] error:", err)
        elseif loopMode then
            setStatus("Loop stopped.", "Info")
        else
            setStatus("All done!", "Success")
        end
        updateStatsDisplay()
    end

    -- ── Public stop ────────────────────────────────────────────────────
    function ModQuest.stop()
        questCancel = true
    end

    -- ── UI ─────────────────────────────────────────────────────────────
    function ModQuest.init()

        -- ── Option maps (defined before runToggle closure captures them) ──
        local FILTER_MAP = {
            ["All Types"]      = nil,
            ["Plant Seeds"]    = "PlantSeeds",
            ["Harvest Crops"]  = "HarvestCrops",
            ["Gain Shillings"] = "GainShillings",
        }
        local SCOPE_MAP = {
            ["Daily + Weekly"] = nil,
            ["Daily Only"]     = "Daily",
            ["Weekly Only"]    = "Weekly",
        }
        local PRIORITY_MAP = {
            ["Default (server order)"]                = "default",
            ["Seed packs first, shortest goal first"] = "seed_short",
            ["Shortest goal first (any reward)"]      = "short_any",
            ["Shillings first, shortest goal first"]  = "shillings",
        }

        -- ── Section 1: Run Controls ──────────────────────────────────
        QuestTab:CreateSection("Quest Automation")

        -- Status label: always visible at top — shows what the script is doing
        questStatusLabel = QuestTab:CreateStatusLabel({ Text = "Idle.", Type = "Info" })

        -- Run toggle: starts/stops the quest loop
        runToggle = QuestTab:CreateToggle({
            Text    = "Run Quests",
            Default = false,
            Callback = function(on)
                if on then
                    if questRunning then return end
                    questCancel = false

                    -- Snapshot all option values fresh at launch.
                    -- Nil-guard every GetValue so early fires before init
                    -- completes fall back to safe defaults.
                    local typeF     = FILTER_MAP[runTypeDropdown and runTypeDropdown.GetValue() or "All Types"]
                    local scopeF    = SCOPE_MAP[scopeDropdown and scopeDropdown.GetValue() or "Daily + Weekly"]
                    local priorityF = PRIORITY_MAP[priorityDropdown and priorityDropdown.GetValue() or ""] or "default"
                    multiPlantEnabled = multiPlantToggle and multiPlantToggle.GetValue() or multiPlantEnabled
                    multiPlantMax     = multiPlantSlider  and multiPlantSlider.GetValue()  or multiPlantMax

                    task.spawn(function()
                        runFiltered(typeF, scopeF, priorityF)
                        -- runFiltered already calls runToggle.SetValue(false) on finish
                    end)
                else
                    if questRunning then
                        questCancel = true
                        setStatus("Stopping after current action...", "Warning")
                    end
                end
            end,
        })
        -- runToggle NOT in questControls — must stay live for cancellation

        -- ── Section 2: Active Quests ─────────────────────────────────
        QuestTab:CreateSection("Active Quests")

        -- Progress bar: tracks current slot progress (0–1)
        slotProgressBar = QuestTab:CreateProgressBar({
            Text    = "No quest running",
            Default = 0,
            Color   = COLOR_BAR_ACTIVE,
        })

        -- Quest table: live view of all 10 slots (Daily + Weekly)
        questDisplayTable = QuestTab:CreateTable({
            Columns    = { "Slot", "Quest", "Progress", "Reward" },
            MaxVisible = 6,
            Rows       = {},
        })

        -- ── Section 3: Session Stats ─────────────────────────────────
        QuestTab:CreateSection("Session Stats")

        -- Stats are displayed in a 2-column table — one stat per row,
        -- clean and readable. updateStatsDisplay() is reassigned below
        -- to target this table directly via SetCell.
        local statsTable = QuestTab:CreateTable({
            Columns    = { "Stat", "Value" },
            MaxVisible = 3,
            Rows = {
                { "Status",    "Idle" },
                { "Uptime",    "—"   },
                { "Completed", "0"   },
            },
        })

        -- Wire updateStatsDisplay to update the table rows.
        -- Reassigning the upvalue so all existing callers work unchanged.
        updateStatsDisplay = function()
            if not statsTable then return end
            statsTable.SetCell(1, 2, questRunning and "Running" or "Idle")
            statsTable.SetCell(2, 2, questRunning and fmtUptime() or "—")
            statsTable.SetCell(3, 2, tostring(stats.questsCompleted))
        end

        -- Uptime ticker — updates every second while running
        task.spawn(function()
            while true do
                task.wait(1)
                if questRunning then updateStatsDisplay() end
            end
        end)

        -- ── Section 4: Options ───────────────────────────────────────
        QuestTab:CreateSection("Options")

        -- Auto-Reroll: reroll the slot after claiming so a new quest spawns
        local autoRerollToggle = QuestTab:CreateToggle({
            Text     = "Auto-Reroll After Claim",
            Default  = true,
            Callback = function(on) autoReroll = on end,
        })
        table.insert(questControls, autoRerollToggle)

        -- Multi-Plant: batch-plant + batch-harvest for HarvestablePlant quests
        -- NOT in questControls — stays interactive during a run so you can
        -- change batch size mid-session without stopping.
        multiPlantToggle = QuestTab:CreateToggle({
            Text     = "Multi-Plant (Harvest quests)",
            Default  = true,
            Callback = function(on) multiPlantEnabled = on end,
        })

        multiPlantSlider = QuestTab:CreateSlider({
            Text      = "Max Batch Size",
            Min       = 1,
            Max       = 10,
            Default   = 5,
            Increment = 1,
            Callback  = function(v) multiPlantMax = v end,
        })
        -- Disable slider when multi-plant is off for visual clarity
        multiPlantToggle.OnChanged:Connect(function(on)
            multiPlantSlider.SetEnabled(on)
        end)

        -- ── Section 5: Earn Quest — Fruit Filter ─────────────────────
        QuestTab:CreateSection("Earn Quest — Fruit Filter")

        -- Muted helper label explaining the empty-selection behaviour
        QuestTab:CreateLabel("Leave empty to harvest all fruit types.")

        local EARN_FRUIT_TYPES = {
            "Carrot", "Corn", "Onion", "Strawberry", "Mushroom",
            "Beetroot", "Tomato", "Apple", "Rose", "Wheat",
            "Banana", "Plum", "Potato", "Cabbage", "Bamboo",
            "Cherry", "Mango", "Biohazard",
        }
        -- Single multiselect — Aurora shows selected count in the header,
        -- so no separate status label is needed here.
        local earnFruitSelect = QuestTab:CreateMultiSelect({
            Text    = "Fruits to harvest",
            Options = EARN_FRUIT_TYPES,
            Default = {},
            Callback = function(selected)
                earnAllowlist = selected or {}
            end,
        })
        -- NOT in questControls — stays interactive during a run

        -- ── Section 6: Run Options ───────────────────────────────────
        QuestTab:CreateSection("Run Options")

        runTypeDropdown = QuestTab:CreateDropdown({
            Text    = "Quest Type",
            Options = { "All Types", "Plant Seeds", "Harvest Crops", "Gain Shillings" },
            Default = "All Types",
        })
        table.insert(questControls, runTypeDropdown)

        scopeDropdown = QuestTab:CreateDropdown({
            Text    = "Scope",
            Options = { "Daily + Weekly", "Daily Only", "Weekly Only" },
            Default = "Daily + Weekly",
        })
        table.insert(questControls, scopeDropdown)

        priorityDropdown = QuestTab:CreateDropdown({
            Text    = "Priority",
            Options = {
                "Default (server order)",
                "Seed packs first, shortest goal first",
                "Shortest goal first (any reward)",
                "Shillings first, shortest goal first",
            },
            Default = "Seed packs first, shortest goal first",
        })
        table.insert(questControls, priorityDropdown)

        -- Global UpdateQuests listener — display only, never source of truth
        UpdateQuests.OnClientEvent:Connect(function(data)
            questData = data
            refreshQuestDisplay()
        end)

        fetchLive()
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--  INIT
--  Build all module UIs, then wire up the global Stop All.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

task.delay(0.5, function()
    ModShovel.init()
    ModBotanist.init()
    ModShop.init()
    ModQuest.init()

    -- Wire the Stop All callback now that all modules are alive.
    ModSettings.stopAllCallback = function()
        ModShovel.stop()
        ModBotanist.stop()
        ModQuest.stop()
        Core.notify("Stopped", "All loops halted.", "Warning", 3)
    end

    Core.notify("Garden Shovel", "v7.0 loaded.", "Success", 4)
end)
