-- /did native: a probe for Blizzard's AuraContainer (issue #49). Not a feature yet.
--
-- Round 1 (2026-11-23, druid 35, open world; log in the project thread) answered:
--   * Slots (AddAuraSlot, "HARMFUL|PLAYER", with or without a spell filter) work on Blizzard's target frame and
--     nameplates, in and out of combat; the duration bar, application bar and texts all take.
--   * Nothing leaks back: IsShown/IsVisible, bar values and texts are secret, HookScript on the button is refused
--     ("blocked by secret aspects"), an OnUpdate child never runs, measuring any region in it errors ("Can't measure
--     restricted regions"), and in combat touching the button errors ("forbidden object").
--   * UNIT_AURA's payload (spell, duration, source) is readable out of combat and secret in combat.
--   * A skull pinned to the end of the strip, clipped to start where the green ends, shows when it kills.
--
-- Round 2 (this file): one slot per DoT, placed end to end, as a real feature would draw them. Each slot is a button
-- the game shows only while that DoT's aura is on the mob, between the end of the strip before it and that point
-- plus the DoT's whole damage (DoesItDie's own estimate when it was applied, so it drains with the real time left).
-- Lacerate's slot also scales with its stacks (stack bar 0-5). Each slot has its own skull at its end, shown only
-- past the green. The first slot starts at the end of DoesItDie's total for any DoTs that have no slot.
-- In-game 2026-11-23: pinning a strip to the end of another slot's strip doesn't work (it never shows), so each
-- strip starts where DoesItDie's own numbers put it; that layout works.
-- SETUP and SIZE lines go to DoesItDieDB.nativeLog (saved on /reload).
local _, ns = ...

local LOG_MAX = 800
local POLL_SECONDS = 0.1
local WHITE = "Interface\\Buttons\\WHITE8X8"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local MAX_STACKS = 5
local SKULL_SIZE = 14
local COLORS = { { 0.2, 0.9, 1 }, { 1, 0.4, 0.9 }, { 0.6, 1, 0.3 }, { 1, 0.85, 0.2 }, { 1, 0.55, 0.1 }, { 0.6, 0.6, 1 } }

-- The chain, in drawing order. Druid DoTs are known up front (Classic rank IDs; Forever's own IDs join from your
-- casts); every other DoT gets a slot once you cast it (the next time out of combat).
local DRUID_CHAIN = {
    { name = "Rake", ids = { 1822, 1823, 1824, 9904 } },
    { name = "Rip", ids = { 1079, 9492, 9493, 9752, 9894, 9896 } },
    { name = "Moonfire", ids = { 8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835 } },
    { name = "Insect Swarm", ids = { 5570, 24974, 24975, 24976, 24977 } },
    { name = "Lacerate", ids = { 414644 }, stacked = true },
}
local STACKED = { Lacerate = true, ["Deadly Poison"] = true }

local probe = { on = false }
ns.nativeProbe = probe
local chain = {} -- { name, ids = { [id] = true }, stacked }
local chainByName = {}
local dirty = false -- a new DoT or spell ID: the slots are made again out of combat
local hosts = {} -- list of { kind, bar, parent, container, unit, slots }
local fullSize = {} -- [unit key .. name] = { appliedAt, damage }: the DoT's whole damage when it was applied
local pendingCasts = {} -- your casts of the last second, looked for among the target's DoTs
local frame = CreateFrame("Frame")

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

local function log(msg)
    local db = ns.db
    if not db then return end
    db.nativeLog = db.nativeLog or {}
    table.insert(db.nativeLog, string.format("%.1f %s", GetTime(), msg))
    if #db.nativeLog > LOG_MAX then table.remove(db.nativeLog, 1) end
    if db.debug then ns.print("|cff66ccff" .. msg .. "|r") end
end

local function say(msg)
    ns.print(msg)
    log("SAY " .. msg)
end

local function errText(err)
    if isSecret(err) or type(err) ~= "string" then return "restricted" end
    return (err:gsub("^.-:%d+: ", ""):sub(1, 90))
end

local function newFrame(kind, parent)
    local ok, f = pcall(CreateFrame, kind, nil, parent, "DisableUntrustedLayoutScriptsTemplate")
    if ok and f then return f end
    return CreateFrame(kind, nil, parent)
end

local function inCombat()
    return InCombatLockdown and InCombatLockdown() == true
end

local function addToChain(name, id, stacked)
    if type(name) ~= "string" or isSecret(name) then return end
    local spec = chainByName[name]
    if not spec then
        spec = { name = name, ids = {}, stacked = stacked or STACKED[name] or false }
        chain[#chain + 1] = spec
        chainByName[name] = spec
        dirty = true
    end
    if type(id) == "number" and not isSecret(id) and not spec.ids[id] then
        spec.ids[id] = true
        dirty = true
    end
end

local function setupChain()
    if #chain > 0 then return end
    local _, class = UnitClass("player")
    if class == "DRUID" then
        for _, entry in ipairs(DRUID_CHAIN) do
            for _, id in ipairs(entry.ids) do addToChain(entry.name, id, entry.stacked) end
        end
    end
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

-- `start`: the region whose right edge the slot starts at (the base bar's fill, or the previous slot's timer fill).
local function initSlot(host, slot, start, button)
    slot.button = button
    local steps = {}
    local function step(label, fn)
        local ok, err = pcall(fn)
        steps[#steps + 1] = label .. (ok and " ok" or (" ERR " .. errText(err)))
    end
    step("anchor", function()
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", start, "TOPRIGHT")
        button:SetPoint("BOTTOMRIGHT", slot.scale:GetStatusBarTexture(), "BOTTOMRIGHT")
    end)
    -- Drawn over the lower half of the bar, clipped to it.
    local clip = newFrame("Frame", button)
    clip:SetClipsChildren(true)
    clip:SetPoint("TOPLEFT", host.bar, "LEFT")
    clip:SetPoint("BOTTOMRIGHT", host.bar, "BOTTOMRIGHT")
    local timer = newFrame("StatusBar", clip)
    slot.timer = timer
    timer:SetStatusBarTexture(WHITE)
    timer:SetStatusBarColor(slot.color[1], slot.color[2], slot.color[3], 0.85)
    timer:SetMinMaxValues(0, 1)
    timer:SetValue(0) -- until the game fills it: a slot never shown must not push the next one along
    if slot.stacked then
        local stacks = newFrame("StatusBar", clip)
        stacks:SetStatusBarTexture(WHITE)
        stacks:SetStatusBarColor(0, 0, 0, 0)
        stacks:SetMinMaxValues(0, MAX_STACKS)
        stacks:SetValue(0)
        stacks:SetAllPoints(button)
        timer:SetPoint("TOPLEFT", button, "TOPLEFT")
        timer:SetPoint("BOTTOMRIGHT", stacks:GetStatusBarTexture(), "BOTTOMRIGHT")
        step("SetApplicationBar", function()
            button:SetApplicationBar(stacks, { minApplications = 0, maxApplications = MAX_STACKS })
        end)
        local count = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        count:SetPoint("BOTTOMLEFT", host.bar, "TOPLEFT", 2, 2)
        step("SetApplicationCount", function() button:SetApplicationCount(count) end)
    else
        timer:SetAllPoints(button)
    end
    step("SetDurationBar", function()
        button:SetDurationBar(timer, { direction = Enum.StatusBarTimerDirection.RemainingTime })
    end)
    -- This slot's skull: at the end of its strip, inside a clip that starts where the green ends.
    local killClip = CreateFrame("Frame", nil, button)
    killClip:SetClipsChildren(true)
    local skull = killClip:CreateTexture(nil, "OVERLAY")
    skull:SetTexture(SKULL)
    skull:SetSize(SKULL_SIZE, SKULL_SIZE)
    step("kill icon", function()
        killClip:SetPoint("TOPLEFT", host.bar:GetStatusBarTexture(), "TOPRIGHT", 0, SKULL_SIZE)
        killClip:SetPoint("BOTTOMRIGHT", host.bar, "BOTTOMRIGHT", SKULL_SIZE, -SKULL_SIZE)
        skull:SetPoint("CENTER", timer:GetStatusBarTexture(), "RIGHT")
    end)
    slot.steps = table.concat(steps, ", ")
end

local function makeHost(kind, bar, parent)
    local host = { kind = kind, bar = bar, parent = parent, slots = {} }
    local ok, err = pcall(function()
        local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
        host.container = container
        container:SetSize(1, 1)
        container:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 4)
        container:SetFrameStrata("HIGH") -- before the slots: their frames are made as its children
        container:SetFrameLevel(50)
    end)
    if not ok then
        log("SETUP " .. kind .. " container ERR " .. errText(err))
        return nil
    end
    -- The base: DoesItDie's total for DoTs without a slot. The first slot starts at its fill's end.
    local base = newFrame("StatusBar", parent)
    base:SetStatusBarTexture(WHITE)
    base:SetStatusBarColor(0, 0, 0, 0)
    base:SetMinMaxValues(0, 1)
    base:SetValue(0)
    base:SetAllPoints(bar)
    host.base = base
    local start = base:GetStatusBarTexture()
    local made = {}
    for i, spec in ipairs(chain) do
        local slot = { spec = spec, name = spec.name, stacked = spec.stacked, color = COLORS[(i - 1) % #COLORS + 1] }
        if not probe.chainMode then
            -- Where this strip starts: our total for DoTs without a slot plus DoesItDie's own estimate of the DoTs
            -- before it in the chain (the poll sets it). Round 2's first try pinned each strip to the end of the
            -- strip before it instead, and the strips after the first never showed (in-game 2026-11-23: Rip).
            local offset = newFrame("StatusBar", parent)
            offset:SetStatusBarTexture(WHITE)
            offset:SetStatusBarColor(0, 0, 0, 0)
            offset:SetMinMaxValues(0, 1)
            offset:SetValue(0)
            offset:SetAllPoints(bar)
            slot.offset = offset
            start = offset:GetStatusBarTexture()
        end
        -- Invisible bar on the health scale from this slot's start: its fill end is where the slot ends.
        local scale = newFrame("StatusBar", parent)
        scale:SetStatusBarTexture(WHITE)
        scale:SetStatusBarColor(0, 0, 0, 0)
        scale:SetMinMaxValues(0, 1)
        scale:SetValue(0)
        scale:SetPoint("TOPLEFT", start, "TOPRIGHT")
        scale:SetPoint("BOTTOMLEFT", start, "BOTTOMRIGHT")
        scale:SetWidth(100)
        slot.scale = scale
        local slotStart = start
        local ids = {}
        for id in pairs(spec.ids) do ids[id] = true end
        local added, addErr = pcall(host.container.AddAuraSlot, host.container, "did" .. i, "HARMFUL|PLAYER", {
            candidateFilters = { includeSpellIDs = ids },
            initializeFrame = function(button)
                local initOk, initErr = pcall(initSlot, host, slot, slotStart, button)
                if not initOk then slot.steps = "init ERR " .. errText(initErr) end
            end,
        })
        made[#made + 1] = spec.name .. (added and (" ok [" .. tostring(slot.steps) .. "]") or (" ERR " .. errText(addErr)))
        if added and slot.timer then
            host.slots[#host.slots + 1] = slot
            start = slot.timer:GetStatusBarTexture()
        end
    end
    log(string.format("SETUP %s on %s (combat %s): %s", kind, tostring(bar.GetDebugName and bar:GetDebugName() or bar),
        tostring(inCombat()), table.concat(made, " | ")))
    return host
end

local function dropHost(host)
    if not host or not host.container then return end
    pcall(host.container.SetEnabled, host.container, false)
    pcall(host.container.Hide, host.container)
    pcall(host.base.Hide, host.base)
    for _, slot in ipairs(host.slots) do
        pcall(slot.scale.Hide, slot.scale)
        if slot.offset then pcall(slot.offset.Hide, slot.offset) end
    end
end

local function plateTokenOf(plate)
    local token = plate.namePlateUnitToken
    if type(token) == "string" and not isSecret(token) then return token end
    for i = 1, 40 do
        if C_NamePlate.GetNamePlateForUnit("nameplate" .. i) == plate then return "nameplate" .. i end
    end
end

local function useHost(kind, bar, parent, unit)
    for _, host in ipairs(hosts) do
        if host.bar == bar then
            if host.unit ~= unit then
                pcall(host.container.SetUnit, host.container, unit)
                host.unit = unit
            end
            pcall(host.container.SetEnabled, host.container, true)
            pcall(host.container.Show, host.container)
            host.enabled = true
            return host
        end
    end
    local host = makeHost(kind, bar, parent)
    if not host then return nil end
    hosts[#hosts + 1] = host
    pcall(host.container.SetUnit, host.container, unit)
    pcall(host.container.SetEnabled, host.container, true)
    host.unit, host.enabled = unit, true
    return host
end

local function followTarget()
    if not probe.on then return end
    local wanted = {}
    local bar = ns.display and ns.display.healthBar and ns.display.healthBar()
    if bar and UnitExists("target") then
        local host = useHost("target", bar, (ns.frameRoot and ns.frameRoot(bar, "target")) or TargetFrame or bar, "target")
        if host then wanted[host] = true end
    end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit("target")
    local token = plate and plateTokenOf(plate)
    if plate and token and ns.plateHealthBar then
        local plateBar, plateParent = ns.plateHealthBar(plate, token)
        if plateBar then
            local host = useHost("plate", plateBar, plateParent or plate, token)
            if host then wanted[host] = true end
        end
    end
    for _, host in ipairs(hosts) do
        if host.enabled and not wanted[host] then
            pcall(host.container.SetEnabled, host.container, false)
            host.enabled, host.unit = false, nil
        end
    end
end

-- New DoTs or spell IDs: every slot is made again (out of combat; the old containers are switched off).
local function rebuild()
    for _, host in ipairs(hosts) do dropHost(host) end
    wipe(hosts)
    dirty = false
    local names = {}
    for _, spec in ipairs(chain) do names[#names + 1] = spec.name end
    log("REBUILD chain: " .. table.concat(names, ", "))
    followTarget()
end

---------------------------------------------------------------------------
-- Every POLL_SECONDS: each slot's size and the base, from DoesItDie's own numbers.
---------------------------------------------------------------------------

local function feed(host)
    local unit = host.unit
    local ok, list = pcall(ns.dotBreakdownForUnit, unit)
    if not ok then return end
    local keyOk, key = pcall(ns.tracking.unitKey, unit)
    key = keyOk and key or unit
    local byName, base = {}, 0
    for _, entry in ipairs(list or {}) do
        if not entry.remote and chainByName[entry.name] then
            byName[entry.name] = entry
        else
            base = base + (entry.damage or 0)
        end
    end
    local maxHealth = UnitHealthMax(unit) -- secret on enemies: only StatusBars use it
    local width = host.bar:GetWidth()
    pcall(host.base.SetMinMaxValues, host.base, 0, maxHealth)
    pcall(host.base.SetValue, host.base, base)
    local before = base -- DoesItDie's estimate of everything drawn before this slot
    for _, slot in ipairs(host.slots) do
        local entry = byName[slot.name]
        if slot.offset then
            pcall(slot.offset.SetMinMaxValues, slot.offset, 0, maxHealth)
            pcall(slot.offset.SetValue, slot.offset, before)
        end
        before = before + (entry and entry.damage or 0)
        local size = 0
        if entry then
            -- The DoT's whole damage when it was applied (or refreshed, or a stack added).
            local saved = fullSize[tostring(key) .. slot.name]
            if not saved or saved.appliedAt ~= entry.appliedAt or entry.damage > saved.damage + 0.5 then
                saved = { appliedAt = entry.appliedAt, damage = entry.damage }
                fullSize[tostring(key) .. slot.name] = saved
                log(string.format("SIZE %s %s: %.0f (stacks %s)", host.kind, slot.name, entry.damage, tostring(entry.stacks)))
            end
            size = saved.damage
            -- The game scales Lacerate's strip by stacks/5: give it the damage of five stacks.
            if slot.stacked then size = size / math.max(1, entry.stacks or 1) * MAX_STACKS end
        end
        pcall(slot.scale.SetMinMaxValues, slot.scale, 0, maxHealth)
        pcall(slot.scale.SetValue, slot.scale, size)
        if type(width) == "number" and not isSecret(width) and width > 0 then pcall(slot.scale.SetWidth, slot.scale, width) end
    end
end

local elapsedSince = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if not probe.on then return end
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < POLL_SECONDS then return end
    elapsedSince = 0
    if #pendingCasts > 0 then
        local ok, list = pcall(ns.dotBreakdownForUnit, "target")
        local now = GetTime()
        for i = #pendingCasts, 1, -1 do
            local cast = pendingCasts[i]
            local found = false
            for _, entry in ipairs(ok and list or {}) do
                if entry.spellID == cast.spellID and not entry.remote then
                    found = true
                    local before = dirty
                    addToChain(entry.name, cast.spellID)
                    if dirty and not before then log("CHAIN " .. entry.name .. " " .. cast.spellID .. " added (slots made again out of combat)") end
                end
            end
            if found or now - cast.at > 1 then table.remove(pendingCasts, i) end
        end
    end
    if dirty and not inCombat() then rebuild() end
    for _, host in ipairs(hosts) do
        if host.enabled and host.unit then
            local ok, err = pcall(feed, host)
            if not ok and not host.feedError then
                host.feedError = true
                log("FEED " .. host.kind .. " ERR " .. errText(err))
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Events and /did native
---------------------------------------------------------------------------

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        if ns.db and ns.db.nativeProbe and not probe.on then
            C_Timer.After(1, function() if ns.db.nativeProbe and not probe.on then probe.enable(true) end end)
        end
        return
    end
    if not probe.on then return end
    if event == "PLAYER_TARGET_CHANGED" or event == "NAME_PLATE_UNIT_ADDED" then
        followTarget()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        log(event == "PLAYER_REGEN_DISABLED" and "COMBAT start" or "COMBAT end")
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" or isSecret(spellID) then return end
        local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
        log("CAST " .. tostring(spellID) .. " " .. tostring(name))
        -- A DoT the tracking took shows in the target's breakdown a moment later: the poll gives it a slot.
        pendingCasts[#pendingCasts + 1] = { spellID = spellID, at = GetTime() }
    end
end)
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

local function apiReady()
    if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
        local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer")
        if loaded ~= true then pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer") end
    end
    if C_XMLUtil and type(C_XMLUtil.GetTemplateInfo) == "function" then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, "CustomAuraContainerTemplate")
        if ok and info == nil then return false end
    end
    return Enum and Enum.StatusBarTimerDirection ~= nil
end

function probe.enable(quiet)
    if not apiReady() then
        say("Native probe: Blizzard's aura container isn't there on this client (logged).")
        return
    end
    probe.on = true
    ns.db.nativeProbe = true
    setupChain()
    log("PROBE on (round 2: " .. (probe.chainMode and "each strip pinned to the one before" or "strips placed from our numbers") .. ")")
    rebuild()
    if not quiet then
        say("Native probe ON (stays on through /reload): one strip per DoT, end to end, in the lower half of the bar; "
            .. "each has a skull at its end that shows past the green. /did native again turns it off.")
        if inCombat() then say("You're in combat: if nothing shows, try again out of combat.") end
    end
end

function probe.disable()
    probe.on = false
    ns.db.nativeProbe = false
    for _, host in ipairs(hosts) do dropHost(host) end
    wipe(hosts)
    log("PROBE off")
    say("Native probe OFF. Its log is DoesItDieDB.nativeLog, saved on /reload.")
end

-- /did native [off | chain | status]
function probe.command(arg)
    arg = strlower(strtrim(arg or ""))
    if arg == "" then
        if probe.on then probe.disable() else probe.enable() end
    elseif arg == "off" then
        if probe.on then probe.disable() end
    elseif arg == "chain" then
        probe.chainMode = not probe.chainMode
        say(probe.chainMode and "Native probe: each strip now starts at the end of the strip before it (the layout where Rip didn't show)."
            or "Native probe: each strip now starts where DoesItDie's own numbers put it.")
        if probe.on then rebuild() else probe.enable(true) end
    elseif arg == "status" then
        local names = {}
        for _, spec in ipairs(chain) do names[#names + 1] = spec.name end
        say(string.format("Native probe %s: chain %s; %d log lines.", probe.on and "ON" or "OFF",
            #names > 0 and table.concat(names, ", ") or "empty (cast a DoT)", ns.db.nativeLog and #ns.db.nativeLog or 0))
    else
        say("/did native [off | chain | status]")
    end
end
