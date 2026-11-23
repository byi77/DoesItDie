-- /did native: a probe for Blizzard's AuraContainer (issue #49). Not a feature: it answers, on Forever itself,
-- whether the native aura frames work on DoesItDie's own target frame and nameplate bars, and what (if anything)
-- addon code can learn from them.
--
-- An AuraContainer slot (AddAuraSlot, "HARMFUL|PLAYER") is a button the client shows only while one of your
-- debuffs is on the unit, with bindings the client fills itself: a duration bar that drains with the real time
-- left, an application (stack) bar, a stack count and a duration text. Our code never reads the aura. The probe
-- draws one such slot on the target frame's health bar and on the target's nameplate, as a cyan strip over the
-- lower half of the bar: from the bar's left end (or from the end of our own total, `/did native base`), as long
-- as `size` x the time left. Druids and rogues also get an orange strip in the upper half for Lacerate / Deadly
-- Poison with the stack bar (size x stacks/5 x time left).
--
-- What it checks, all written to DoesItDieDB.nativeLog (saved on /reload or logout):
--   SETUP   which APIs and templates exist, and whether each binding call was accepted
--   LEAK    what our code can read back while a slot shows: the button's IsShown/IsVisible, an OnShow/OnHide hook,
--           an OnUpdate heartbeat on a plain child frame (it stops when the button hides), the timer's value and fill
--           width, the left edge of a frame pinned to the fill's end, the stack bar, the texts, the container's
--           children. "SECRET" = secret value, "ERR" = the call errored, else the value.
--   KILL    a skull pinned to the end of the strip, inside a clip frame that starts where the green health ends:
--           it shows only when (base + native damage left) passes the target's health. The position-only kill icon.
--   AURA    the UNIT_AURA payload (target): which fields are readable in and out of combat.
-- Each LEAK/AURA line is written when what's readable changes, plus a sample every few seconds while a slot shows.
local _, ns = ...

local LOG_MAX = 800
local POLL_SECONDS = 0.25
local SAMPLE_SECONDS = 5
local AURA_LINES_MAX = 120
local WHITE = "Interface\\Buttons\\WHITE8X8"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local MAX_STACKS = 5
local SKULL_SIZE = 14

-- Fallback filter, only if a slot without a spell filter is refused: Classic rank IDs of common DoTs plus every
-- DoT spell ID this session has cast (added at setup). The stack slot: Lacerate (Season of Discovery's rune ID;
-- Forever's own rank IDs come from your casts) and Deadly Poison I-V.
local FALLBACK_IDS = {
    8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835, -- Moonfire
    5570, 24974, 24975, 24976, 24977, -- Insect Swarm
    1079, 9492, 9493, 9752, 9894, 9896, -- Rip
    1822, 1823, 1824, 9904, -- Rake
    339, 1062, 5195, 5196, 9852, 9853, -- Entangling Roots
    172, 6222, 6223, 7648, 11671, 11672, 25311, -- Corruption
    348, 707, 1094, 2941, 11665, 11667, 11668, 25309, -- Immolate
    589, 594, 970, 992, 2767, 10892, 10893, 10894, -- Shadow Word: Pain
    1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295, -- Serpent Sting
    772, 6546, 6547, 6548, 11572, 11573, 11574, -- Rend
}
local STACK_IDS = { 414644, 2818, 2819, 11353, 11354, 25349 }
local STACK_NAMES = { Lacerate = true, ["Deadly Poison"] = true }

local probe = { on = false, size = nil, autoSize = nil, stackSize = nil, stackBase = false }
ns.nativeProbe = probe
local hosts = {} -- [health bar] = host
local plateHost -- the one plate host currently following the target
local seenNames = {} -- DoT names already seen on the current target (their first damage sets the auto size)
local auraLines, auraShape, auraAt = 0, nil, 0
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

local function describe(v)
    if isSecret(v) then return "SECRET" end
    if type(v) == "number" then return string.format("%.4g", v) end
    if type(v) == "string" then return '"' .. v:sub(1, 24) .. '"' end
    return tostring(v)
end

local function errText(err)
    if isSecret(err) or type(err) ~= "string" then return "restricted" end
    return (err:gsub("^.-:%d+: ", ""):sub(1, 90))
end

-- obj:method(...) described: "SECRET", "ERR <text>", "n/a" (no such object or method), or the value(s).
local function read(obj, method, ...)
    if obj == nil then return "n/a" end
    local ok, fn = pcall(function() return obj[method] end)
    if not ok or type(fn) ~= "function" then return "n/a" end
    local results = { pcall(fn, obj, ...) }
    if not results[1] then return "ERR " .. errText(results[2]) end
    if #results <= 2 then return describe(results[2]) end
    local parts = {}
    for i = 2, #results do parts[#parts + 1] = describe(results[i]) end
    return table.concat(parts, "/")
end

-- The same text with every number masked: two samples with the same shape read the same kinds of values.
local function shapeOf(text)
    return (text:gsub("%-?%d+%.?%d*e?[%+%-]?%d*", "#"))
end

local function newFrame(kind, parent)
    local ok, f = pcall(CreateFrame, kind, nil, parent, "DisableUntrustedLayoutScriptsTemplate")
    if ok and f then return f end
    return CreateFrame(kind, nil, parent)
end

local function inCombat()
    return InCombatLockdown and InCombatLockdown() == true
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local apiReported = false
local function apiReady()
    if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
        local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer")
        if loaded ~= true then pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer") end
    end
    local template = "unknown"
    if C_XMLUtil and type(C_XMLUtil.GetTemplateInfo) == "function" then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, "CustomAuraContainerTemplate")
        template = ok and (info ~= nil and "yes" or "no") or "ERR"
    end
    local direction = Enum and Enum.StatusBarTimerDirection
    local property = Enum and Enum.DurationTextBindingProperty
    if not apiReported then
        apiReported = true
        local _, class = UnitClass("player")
        local instance, kind = IsInInstance()
        log(string.format("SETUP client %s, %s, in instance %s (%s), combat %s | CustomAuraContainerTemplate %s"
            .. " | StatusBarTimerDirection %s | DurationTextBindingProperty %s | C_StringUtil.CreateNumericRuleFormatter %s",
            tostring(GetBuildInfo and (GetBuildInfo())), tostring(class), tostring(instance), tostring(kind),
            tostring(inCombat()), template, direction and describe(direction.RemainingTime) or "missing",
            property and describe(property.RemainingPercent) or "missing",
            tostring(C_StringUtil ~= nil and type(C_StringUtil.CreateNumericRuleFormatter) == "function")))
    end
    return template ~= "no"
end

-- Bindings are tried one by one so a refused one doesn't hide the others.
local function bind(slot, label, fn)
    local ok, err = pcall(fn)
    slot.bindings[#slot.bindings + 1] = label .. (ok and " ok" or (" ERR " .. errText(err)))
end

local function initSlot(host, slot, button)
    slot.button = button
    local direction = Enum and Enum.StatusBarTimerDirection
    local property = Enum and Enum.DurationTextBindingProperty
    -- Between the end of the base fill and the end of the scale fill: one application's damage on the health scale.
    bind(slot, "anchor", function()
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", slot.base:GetStatusBarTexture(), "TOPRIGHT")
        button:SetPoint("BOTTOMRIGHT", slot.scale:GetStatusBarTexture(), "BOTTOMRIGHT")
    end)
    -- The strip's half of the bar, clipped to the bar.
    local clip = newFrame("Frame", button)
    slot.clip = clip
    clip:SetClipsChildren(true)
    if slot.stacked then
        clip:SetPoint("TOPLEFT", host.bar, "TOPLEFT")
        clip:SetPoint("BOTTOMRIGHT", host.bar, "RIGHT")
    else
        clip:SetPoint("TOPLEFT", host.bar, "LEFT")
        clip:SetPoint("BOTTOMRIGHT", host.bar, "BOTTOMRIGHT")
    end
    local timer = newFrame("StatusBar", clip)
    slot.timer = timer
    timer:SetStatusBarTexture(WHITE)
    if slot.stacked then timer:SetStatusBarColor(1, 0.55, 0.1, 0.8) else timer:SetStatusBarColor(0.2, 0.9, 1, 0.8) end
    timer:SetMinMaxValues(0, 1)
    timer:SetValue(1)
    if slot.stacked then
        -- An invisible bar filling with the stacks; the timer is as wide as that fill.
        local stacks = newFrame("StatusBar", clip)
        slot.stacks = stacks
        stacks:SetStatusBarTexture(WHITE)
        stacks:SetStatusBarColor(0, 0, 0, 0)
        stacks:SetMinMaxValues(0, MAX_STACKS)
        stacks:SetValue(0)
        stacks:SetPoint("TOPLEFT", button, "TOPLEFT")
        stacks:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT")
        timer:SetPoint("TOP", clip, "TOP")
        timer:SetPoint("BOTTOM", clip, "BOTTOM")
        timer:SetPoint("LEFT", button, "LEFT")
        timer:SetPoint("RIGHT", stacks:GetStatusBarTexture(), "RIGHT")
        bind(slot, "SetApplicationBar", function()
            button:SetApplicationBar(stacks, { minApplications = 0, maxApplications = MAX_STACKS })
        end)
    else
        timer:SetPoint("TOP", clip, "TOP")
        timer:SetPoint("BOTTOM", clip, "BOTTOM")
        timer:SetPoint("LEFT", button, "LEFT")
        timer:SetPoint("RIGHT", button, "RIGHT")
    end
    bind(slot, "SetDurationBar", function()
        button:SetDurationBar(timer, { direction = direction.RemainingTime })
    end)
    -- Texts above the bar: stack count at the left end (stack slot), time left as a percentage at the right end.
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slot.text = text
    if slot.stacked then
        text:SetPoint("BOTTOMLEFT", host.bar, "TOPLEFT", 2, 2)
        bind(slot, "SetApplicationCount", function() button:SetApplicationCount(text) end)
    else
        text:SetPoint("BOTTOMRIGHT", host.bar, "TOPRIGHT", -2, 2)
        bind(slot, "SetDurationText", function()
            local formatter = C_StringUtil.CreateNumericRuleFormatter()
            formatter:SetBreakpoints({ { threshold = 0, format = "%.0f%%", components = { { div = 1, step = 1 } } } })
            slot.formatter = formatter
            button:SetDurationText(text, { textFormat = { formatString = "{}", components = {
                { property = property.RemainingPercent, formatter = formatter } } } })
        end)
    end
    -- Leaks: a hook on the button, a heartbeat child, a 1px frame pinned to the end of the fill.
    bind(slot, "HookScript OnShow/OnHide", function()
        button:HookScript("OnShow", function() slot.hookShown = (slot.hookShown or 0) + 1; log("LEAK " .. slot.name .. " OnShow hook fired") end)
        button:HookScript("OnHide", function() slot.hookHidden = (slot.hookHidden or 0) + 1; log("LEAK " .. slot.name .. " OnHide hook fired") end)
    end)
    local beat = CreateFrame("Frame", nil, button)
    beat:SetSize(1, 1)
    beat:SetPoint("CENTER", button, "CENTER")
    bind(slot, "heartbeat", function() beat:SetScript("OnUpdate", function() slot.beatAt = GetTime() end) end)
    local pin = CreateFrame("Frame", nil, clip)
    slot.pin = pin
    pin:SetSize(1, 1)
    bind(slot, "pin", function() pin:SetPoint("CENTER", timer:GetStatusBarTexture(), "RIGHT") end)
    -- The position-only kill icon: a clip frame from where the green health ends to just past the bar's right end;
    -- a skull centered on the end of the strip shows inside it only once the strip ends past the green.
    if not slot.stacked then
        local killClip = CreateFrame("Frame", nil, button)
        slot.killClip = killClip
        killClip:SetClipsChildren(true)
        local skull = killClip:CreateTexture(nil, "OVERLAY")
        slot.skull = skull
        skull:SetTexture(SKULL)
        skull:SetSize(SKULL_SIZE, SKULL_SIZE)
        bind(slot, "kill icon", function()
            local green = host.bar:GetStatusBarTexture()
            killClip:SetPoint("TOPLEFT", green, "TOPRIGHT", 0, SKULL_SIZE)
            killClip:SetPoint("BOTTOMRIGHT", host.bar, "BOTTOMRIGHT", SKULL_SIZE, -SKULL_SIZE)
            skull:SetPoint("CENTER", timer:GetStatusBarTexture(), "RIGHT")
        end)
    end
    slot.initialized = true
end

local function newSlot(host, name, stacked)
    local slot = { name = host.kind .. "/" .. name, stacked = stacked, bindings = {}, wasBeating = false }
    for _, key in ipairs({ "base", "scale" }) do
        -- Plain, invisible bars on the health scale; their fill ends give the slot its place and length.
        local bar = newFrame("StatusBar", host.parent)
        bar:SetStatusBarTexture(WHITE)
        bar:SetStatusBarColor(0, 0, 0, 0)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        slot[key] = bar
    end
    slot.base:SetAllPoints(host.bar)
    slot.scale:SetPoint("TOPLEFT", slot.base:GetStatusBarTexture(), "TOPRIGHT")
    slot.scale:SetPoint("BOTTOMLEFT", slot.base:GetStatusBarTexture(), "BOTTOMRIGHT")
    slot.scale:SetWidth(100)
    return slot
end

local function spellFilter(stacked)
    local ids, seen = {}, {}
    local function add(id)
        if type(id) == "number" and not isSecret(id) and not seen[id] then seen[id] = true; ids[id] = true end
    end
    for _, id in ipairs(stacked and STACK_IDS or FALLBACK_IDS) do add(id) end
    local own = ns.tracking and ns.tracking.ownDots and ns.tracking.ownDots() or {}
    for _, list in pairs(own) do
        for _, dot in ipairs(list) do
            if not stacked or STACK_NAMES[dot.name] then add(dot.spellID) end
        end
    end
    return ids
end

local function addSlot(host, name, stacked)
    local slot = newSlot(host, name, stacked)
    local init = function(button)
        local ok, err = pcall(initSlot, host, slot, button)
        if not ok then slot.initError = errText(err) end
    end
    local filterText
    local ok, err
    if not stacked then
        -- First without a spell filter: any of your debuffs.
        ok, err = pcall(host.container.AddAuraSlot, host.container, name, "HARMFUL|PLAYER", { initializeFrame = init })
        filterText = "no spell filter"
    end
    if stacked or not ok then
        if not stacked then log("SETUP " .. slot.name .. " slot without a filter refused: " .. errText(err)) end
        local ids = spellFilter(stacked)
        local count = 0
        for _ in pairs(ids) do count = count + 1 end
        ok, err = pcall(host.container.AddAuraSlot, host.container, name, "HARMFUL|PLAYER",
            { candidateFilters = { includeSpellIDs = ids }, initializeFrame = init })
        filterText = count .. " spell IDs"
    end
    log(string.format("SETUP %s AddAuraSlot (%s): %s | initializeFrame %s | %s", slot.name, filterText,
        ok and "ok" or ("ERR " .. errText(err)), slot.initialized and "ran" or (slot.initError and ("ERR " .. slot.initError)
        or "not run yet"), table.concat(slot.bindings, ", ")))
    if ok then host.slots[#host.slots + 1] = slot end
end

local function makeHost(kind, bar, parent)
    local host = { kind = kind, bar = bar, parent = parent, slots = {} }
    local ok, err = pcall(function()
        local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
        host.container = container
        container:SetSize(1, 1)
        container:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 4)
        -- Strata and level before the slots: their frames are made as its children and keep them.
        container:SetFrameStrata("HIGH")
        container:SetFrameLevel(50)
    end)
    log(string.format("SETUP %s container on %s (combat %s): %s", kind, tostring(bar.GetDebugName and bar:GetDebugName()
        or bar), tostring(inCombat()), ok and "created" or ("ERR " .. errText(err))))
    if not ok then return nil end
    addSlot(host, "didAny", false)
    local _, class = UnitClass("player")
    if class == "DRUID" or class == "ROGUE" then addSlot(host, "didStacks", true) end
    return host
end

local function setHostUnit(host, unit)
    if not host or not host.container then return end
    if host.unit ~= unit then
        local ok, err = pcall(host.container.SetUnit, host.container, unit)
        if not ok then log("SETUP " .. host.kind .. " SetUnit(" .. unit .. ") ERR " .. errText(err)) end
        host.unit = unit
    end
    if not host.enabled then
        pcall(host.container.SetEnabled, host.container, true)
        pcall(host.container.Show, host.container)
        host.enabled = true
    end
    pcall(host.container.UpdateAllAuras, host.container)
end

local function disableHost(host)
    if not host or not host.container or not host.enabled then return end
    pcall(host.container.SetEnabled, host.container, false)
    pcall(host.container.Hide, host.container)
    host.enabled, host.unit = false, nil
end

local function plateTokenOf(plate)
    local token = plate.namePlateUnitToken
    if type(token) == "string" and not isSecret(token) then return token end
    for i = 1, 40 do
        if C_NamePlate.GetNamePlateForUnit("nameplate" .. i) == plate then return "nameplate" .. i end
    end
end

local function followTarget()
    if not probe.on then return end
    wipe(seenNames)
    probe.autoSize, probe.stackSize = nil, nil
    local bar = ns.display and ns.display.healthBar and ns.display.healthBar()
    if bar then
        if not hosts[bar] then
            hosts[bar] = makeHost("target", bar, (ns.frameRoot and ns.frameRoot(bar, "target")) or TargetFrame or bar)
                or false
        end
        if hosts[bar] then setHostUnit(hosts[bar], "target") end
    end
    -- The target's nameplate; the plate host of the previous target stops.
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit("target")
    local token = plate and plateTokenOf(plate)
    local plateBar, plateParent = nil, nil
    if plate and token and ns.plateHealthBar then plateBar, plateParent = ns.plateHealthBar(plate, token) end
    if plateHost and plateHost.bar ~= plateBar then disableHost(plateHost) end
    plateHost = nil
    if plateBar then
        if hosts[plateBar] == nil then hosts[plateBar] = makeHost("plate", plateBar, plateParent or plate) or false end
        if hosts[plateBar] then
            plateHost = hosts[plateBar]
            setHostUnit(plateHost, token)
        end
    end
end

---------------------------------------------------------------------------
-- Every POLL_SECONDS: feed the scale bars, then log what can be read back.
---------------------------------------------------------------------------

local function luaTotal(unit)
    if not ns.dotBreakdownForUnit then return 0 end
    local ok, list, total = pcall(ns.dotBreakdownForUnit, unit)
    if not ok then return 0 end
    -- A new DoT's first estimate is one application's whole damage: the strip's length unless /did native <n>.
    for _, entry in ipairs(list or {}) do
        if entry.name and not seenNames[entry.name] and not entry.remote then
            seenNames[entry.name] = true
            if STACK_NAMES[entry.name] then probe.stackSize = entry.damage else probe.autoSize = entry.damage end
            log(string.format("SIZE %s first seen at %s damage", tostring(entry.name), describe(entry.damage)))
        end
    end
    return total or 0
end

local function feed(host, slot)
    local unit = host.unit
    if not unit then return end
    local maxHealth = UnitHealthMax(unit) -- secret on enemies: only StatusBars use it
    local size = probe.size or (slot.stacked and probe.stackSize and probe.stackSize * MAX_STACKS) or probe.autoSize or 0
    local total = luaTotal(unit)
    local base = (probe.stackBase and not slot.stacked) and total or 0
    pcall(slot.base.SetMinMaxValues, slot.base, 0, maxHealth)
    pcall(slot.base.SetValue, slot.base, base)
    pcall(slot.scale.SetMinMaxValues, slot.scale, 0, maxHealth)
    pcall(slot.scale.SetValue, slot.scale, size)
    local width = host.bar:GetWidth()
    if type(width) == "number" and not isSecret(width) and width > 0 then pcall(slot.scale.SetWidth, slot.scale, width) end
end

local function sample(host, slot, now)
    local beating = slot.beatAt ~= nil and now - slot.beatAt < POLL_SECONDS * 2
    local fill = slot.timer and slot.timer:GetStatusBarTexture()
    local greenRight = read(host.bar:GetStatusBarTexture(), "GetRight")
    local parts = {
        "shown=" .. read(slot.button, "IsShown"),
        "visible=" .. read(slot.button, "IsVisible"),
        "heartbeat=" .. tostring(beating),
        "hooks=" .. tostring(slot.hookShown or 0) .. "/" .. tostring(slot.hookHidden or 0),
        "timer=" .. read(slot.timer, "GetValue") .. " of " .. read(slot.timer, "GetMinMaxValues"),
        "fillWidth=" .. read(fill, "GetWidth"),
        "fillRight=" .. read(fill, "GetRight"),
        "pinLeft=" .. read(slot.pin, "GetLeft"),
        "button=" .. read(slot.button, "GetLeft") .. ".." .. read(slot.button, "GetRight"),
        "greenRight=" .. greenRight,
        "text=" .. read(slot.text, "GetText"),
        "children=" .. read(host.container, "GetNumChildren"),
    }
    if slot.stacks then parts[#parts + 1] = "stacks=" .. read(slot.stacks, "GetValue") end
    if slot.skull then parts[#parts + 1] = "skullVisible=" .. read(slot.skull, "IsVisible") end
    local line = table.concat(parts, " ")
    local shape = shapeOf(line)
    if shape ~= slot.shape or (beating and now - (slot.sampledAt or 0) >= SAMPLE_SECONDS) then
        log(string.format("LEAK %s (%s, combat %s, size %s, base %s) %s", slot.name, tostring(host.unit),
            tostring(inCombat()), describe(probe.size or probe.autoSize), tostring(probe.stackBase), line))
        slot.shape, slot.sampledAt = shape, now
    end
    if beating ~= slot.wasBeating then
        log("LEAK " .. slot.name .. " heartbeat " .. (beating and "STARTED (button shown)" or "STOPPED (button hidden)"))
        slot.wasBeating = beating
    end
end

local elapsedSince = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if not probe.on then return end
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < POLL_SECONDS then return end
    elapsedSince = 0
    local now = GetTime()
    for _, host in pairs(hosts) do
        if host and host.enabled then
            for _, slot in ipairs(host.slots) do
                pcall(feed, host, slot)
                local ok, err = pcall(sample, host, slot, now)
                if not ok and not slot.sampleError then
                    slot.sampleError = true
                    log("LEAK " .. slot.name .. " sample ERR " .. errText(err))
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- UNIT_AURA payload (target)
---------------------------------------------------------------------------

local function auraFields(aura)
    if aura == nil then return "none" end
    if isSecret(aura) then return "SECRET" end
    if type(aura) ~= "table" then return describe(aura) end
    local parts = {}
    for _, key in ipairs({ "auraInstanceID", "spellId", "name", "sourceUnit", "isFromPlayerOrPlayerPet", "isHarmful",
        "duration", "expirationTime", "applications" }) do
        local ok, v = pcall(function() return aura[key] end)
        parts[#parts + 1] = key .. "=" .. (ok and describe(v) or "ERR")
    end
    return table.concat(parts, " ")
end

local function listInfo(list)
    if list == nil then return "nil", nil end
    if isSecret(list) then return "SECRET", nil end
    if type(list) ~= "table" then return describe(list), nil end
    local ok, n = pcall(function() return #list end)
    local first = ok and n > 0 and list[1] or nil
    return ok and tostring(n) or "ERR", first
end

local function onUnitAura(unit, info)
    if auraLines >= AURA_LINES_MAX then return end
    local full = info and describe(info.isFullUpdate) or "no payload"
    local added, firstAdded = listInfo(info and info.addedAuras)
    local removed, firstRemoved = listInfo(info and info.removedAuraInstanceIDs)
    local updated = listInfo(info and info.updatedAuraInstanceIDs)
    local line = string.format("full=%s added=%s removed=%s updated=%s", full, added, removed, updated)
    if firstAdded ~= nil then
        line = line .. " | first added: " .. auraFields(firstAdded)
        local id = type(firstAdded) == "table" and not isSecret(firstAdded) and firstAdded.auraInstanceID
        if id ~= nil and not isSecret(id) and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
            line = line .. " | lookup: " .. read(C_UnitAuras, "GetAuraDataByAuraInstanceID", "target", id)
        end
    end
    if firstRemoved ~= nil then line = line .. " | first removed id=" .. describe(firstRemoved) end
    local now = GetTime()
    local shape = shapeOf(line) .. tostring(inCombat())
    if shape ~= auraShape or now - auraAt >= 2 then
        auraShape, auraAt = shape, now
        auraLines = auraLines + 1
        log(string.format("AURA %s (combat %s) %s", tostring(unit), tostring(inCombat()), line))
    end
end

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
    if event == "PLAYER_TARGET_CHANGED" then
        log("TARGET changed")
        followTarget()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if not plateHost and UnitExists("target") then followTarget() end
    elseif event == "UNIT_AURA" then
        onUnitAura(...)
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        log(event == "PLAYER_REGEN_DISABLED" and "COMBAT start" or "COMBAT end")
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and not isSecret(spellID) then
            log("CAST " .. tostring(spellID) .. " " .. tostring(C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)))
        end
    end
end)
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterUnitEvent("UNIT_AURA", "target")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

function probe.enable(quiet)
    if not apiReady() then
        say("Native probe: Blizzard's CustomAuraContainerTemplate isn't there on this client (logged).")
        return
    end
    probe.on = true
    ns.db.nativeProbe = true
    auraLines = 0
    log("PROBE on (size " .. describe(probe.size) .. ", base " .. (probe.stackBase and "our total" or "0") .. ")")
    followTarget()
    if not quiet then
        say("Native probe ON (stays on through /reload). Cyan strip = the game's own aura timer, skull = position-only "
            .. "kill icon. /did native again turns it off.")
        if inCombat() then say("You're in combat: if nothing shows, try again out of combat.") end
    end
end

function probe.disable()
    probe.on = false
    ns.db.nativeProbe = false
    for _, host in pairs(hosts) do if host then disableHost(host) end end
    plateHost = nil
    log("PROBE off")
    say("Native probe OFF. Its log is DoesItDieDB.nativeLog, saved on /reload.")
end

-- /did native [off | base | <damage> | auto | status]
function probe.command(arg)
    arg = strlower(strtrim(arg or ""))
    local number = tonumber(arg)
    if arg == "" then
        if probe.on then probe.disable() else probe.enable() end
    elseif arg == "off" then
        probe.disable()
    elseif arg == "base" then
        probe.stackBase = not probe.stackBase
        say("Native probe strip starts " .. (probe.stackBase and "at the end of DoesItDie's own total." or "at the bar's left end."))
        log("BASE " .. tostring(probe.stackBase))
        if not probe.on then probe.enable(true) end
    elseif arg == "auto" then
        probe.size = nil
        say("Native probe strip length: your newest DoT's damage on the target.")
        if not probe.on then probe.enable(true) end
    elseif number and number >= 0 then
        probe.size = number
        say("Native probe strip length: " .. number .. " damage x the time left.")
        log("SIZE set to " .. number)
        if not probe.on then probe.enable(true) end
    elseif arg == "status" then
        local count = 0
        for _, host in pairs(hosts) do if host then count = count + #host.slots end end
        say(string.format("Native probe %s: %d slots, size %s, %d log lines.", probe.on and "ON" or "OFF", count,
            describe(probe.size or probe.autoSize), ns.db.nativeLog and #ns.db.nativeLog or 0))
    else
        say("/did native [off | base | auto | <damage> | status]")
    end
end
