if isServer() then return end

TheFogDescend = TheFogDescend or {}

-- Cache global functions for speed (hot paths)
local getGameTime = getGameTime
local getPlayer = getPlayer
local getSoundManager = getSoundManager
local sendClientCommand = sendClientCommand
local ZombRandFloat = ZombRandFloat
local math_max = math.max
local math_min = math.min
local math_abs = math.abs

local lastHours = nil

local function onServerCommand(module, command, args)
    if module == "TheFogDescend" then
        if command == "playSiren" then
            local soundManager = getSoundManager()
            if soundManager then
                soundManager:PlaySound("TheFogDescend_Siren", false, 1.0)
            end
        elseif command == "checkVehicleStall" then
            local player = getPlayer()
            if not player then return end

            local vehicle = player:getVehicle()
            if not vehicle or vehicle:getDriver() ~= player then return end

            if vehicle:isEngineRunning() then
                -- 2% chance of engine stall every minute
                if ZombRandFloat(0.0, 1.0) < 0.02 then
                    sendClientCommand('vehicle', 'shutOff', {})
                    player:Say("The engine sputtered and died in the thick fog...")
                end
            end
        elseif command == "syncState" then
            TheFogDescend.isEventActive = args.isEventActive
        elseif command == "startEvent" then
            TheFogDescend.isEventActive = true
        elseif command == "stopEvent" then
            TheFogDescend.isEventActive = false
        end
    end
end

local function onGameStart()
    lastHours = nil
    if isClient() then
        sendClientCommand("TheFogDescend", "requestState", {})
    end
end

local function onPlayerUpdate(player)
    -- Only run for the local player
    if not player or not player:isLocalPlayer() then return end

    -- Fast-path optimization: exit immediately if the event is inactive and the player is clean
    local modData = player:getModData()
    local currentToxicity = modData.fogToxicity or 0.0
    if not TheFogDescend.isEventActive and currentToxicity <= 0 then
        lastHours = nil
        return
    end

    if not player:isAlive() then
        modData.fogToxicity = 0.0
        lastHours = nil
        return
    end

    local currentHours = getGameTime():getWorldAgeHours()
    if not lastHours or currentHours < lastHours then
        lastHours = currentHours
    else
        local dt = currentHours - lastHours
        lastHours = currentHours

        -- Accumulate toxicity only when game clock advances
        if dt > 0 and dt <= 24 then
            -- Determine if toxic fog is enabled and active
            local toxicFogEnabled = LivingWorldFramework.GetConfig("TheFogDescend", "ToxicFogEnabled")
            if toxicFogEnabled == nil then
                error("[TheFogDescend] LivingWorldFramework config 'ToxicFogEnabled' is missing or nil!")
            end

            local isSafe = true
            if toxicFogEnabled and TheFogDescend.isEventActive then
                if player.isGodMod and player:isGodMod() then
                    isSafe = true
                else
                    -- Check if player is outside of a building
                    local square = player:getCurrentSquare()
                    local isOutside = not square or square:isOutside()
                    
                    if isOutside then
                        -- Check if wearing a valid gas mask
                        local hasMask = false
                        local wornItems = player:getWornItems()
                        if wornItems then
                            for i = 0, wornItems:size() - 1 do
                                externItem = wornItems:get(i)
                                local item = externItem:getItem()
                                if item then
                                    local fullType = item:getFullType()
                                    local shortType = item:getType()
                                    local isGasMask = TheFogDescend.gasMasks[fullType] or TheFogDescend.gasMasks[shortType]
                                    if not isGasMask and item.hasTag then
                                        isGasMask = item:hasTag("gasmask") or item:hasTag("base:gasmask")
                                    end
                                    if isGasMask and item:getCondition() > 0 then
                                        hasMask = true
                                        break
                                    end
                                end
                            end
                        end

                        if not hasMask then
                            isSafe = false
                        end
                    end
                end
            end

            local deathHours = LivingWorldFramework.GetConfig("TheFogDescend", "ToxicityDeathHours")
            if not deathHours or deathHours <= 0 then
                error("[TheFogDescend] LivingWorldFramework config 'ToxicityDeathHours' is missing, nil, or invalid!")
            end

            if isSafe then
                -- Reduce toxicity slowly (1h of exposure = 2h of safe)
                currentToxicity = math_max(0.0, currentToxicity - dt / (deathHours * 2))
            else
                -- Increase toxicity
                currentToxicity = math_min(1.0, currentToxicity + dt / deathHours)
            end
            modData.fogToxicity = currentToxicity

            -- Direct health reduction for precise death timing (applied on hourly ticks)
            if currentToxicity >= 1.0 then
                local bodyDamage = player:getBodyDamage()
                if bodyDamage then bodyDamage:ReduceGeneralHealth(100.0) end
            elseif currentToxicity > 0.1 then
                local bodyDamage = player:getBodyDamage()
                if bodyDamage then
                    local scale = (currentToxicity - 0.1) / 0.9
                    local baseDamageRate = 100.0 / (deathHours * 0.9)
                    local healthDamage = dt * baseDamageRate * scale * 2
                    bodyDamage:ReduceGeneralHealth(healthDamage)
                end
            end

            -- Coughing effect (2% chance per minute if exposed and toxicity > 0.05)
            if not isSafe and currentToxicity > 0.05 then
                if ZombRandFloat(0.0, 1.0) < (dt * 1.2) then
                    player:Say("*Cough* *Wheeze*")
                    local x = player:getX()
                    local y = player:getY()
                    local z = player:getZ()
                    if addSound then
                        addSound(player, x, y, z, 15, 15)
                    end
                end
            end
        end
    end

    -- Apply visual, stats and moodle toxicity effects on EVERY frame
    if currentToxicity > 0 then
        local bodyDamage = player:getBodyDamage()
        if bodyDamage then
            -- Set poison level to trigger Sickness/Fever moodle (0 to 100 in PZ)
            bodyDamage:setPoisonLevel(currentToxicity * 45)
        end

        -- Degrade body stats
        local stats = player:getStats()
        if stats then
            -- Set minimum fatigue based on toxicity
            local currentFatigue = stats:getFatigue()
            stats:setFatigue(math_max(currentFatigue, currentToxicity * 0.9))

            -- Decrease endurance
            local currentEndurance = stats:getEndurance()
            stats:setEndurance(math_min(currentEndurance, 1.0 - (currentToxicity * 0.8)))

            -- Increase pain
            local currentPain = stats:getPain()
            stats:setPain(math_max(currentPain, currentToxicity * 80))
        end
    else
        -- Clear poison level if toxicity is completely gone
        local bodyDamage = player:getBodyDamage()
        if bodyDamage and bodyDamage:getPoisonLevel() > 0 then
            bodyDamage:setPoisonLevel(0)
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onGameStart)
Events.OnPlayerUpdate.Add(onPlayerUpdate)


