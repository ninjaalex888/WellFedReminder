--[[
    Well Fed Reminder 1.2.0
    Flashes a food icon whenever you don't have the Well Fed buff, shows a countdown while
    you eat, and warns you before Well Fed runs out so you can top it up. It stays hidden
    in cities and inns, and until you reach level 6.

    Built for WoW: Forever, which runs the modern (Midnight 12.x) addon API including its
    combat restrictions: while you're in combat, aura data is hidden from addons. So the
    addon reads your buffs only out of combat. In combat the icon hides (default), or with
    "/wellfed combat" it keeps counting down from its last reading.

    Type /wellfed (or /wfr) in game for the commands.
]]

local ADDON_NAME = ...

----------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------

local EAT_SECONDS  = 10    -- you must eat/drink this long before Well Fed is applied
local EAT_GRACE    = 2     -- slack before deciding a food/drink doesn't give Well Fed
local RESCAN_EVERY = 2     -- background re-check interval (backs up UNIT_AURA)
local TICK         = 0.2   -- display refresh interval
local TEST_SECONDS = 10
local ICON_SIZE    = 52

local DEFAULT_ICON   = "Interface\\Icons\\Spell_Misc_Food"
local WELL_FED_SPELL = 19705   -- a "Well Fed" spell: real icon, and the name on non-English clients
local FOOD_SPELL     = 433     -- "Food"  (non-English clients only)
local DRINK_SPELL    = 430     -- "Drink" (non-English clients only)

local FONT   = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local PREFIX = "|cffffd200Well Fed Reminder:|r "

local DEFAULTS = {
    enabled       = true,
    locked        = true,
    point         = { "CENTER", "CENTER", 0, 140 },
    scale         = 1,
    warnSeconds   = 120,
    showInCombat  = false,
    instancesOnly = false,
    hideInCities  = true,       -- cities and inns: anywhere the game counts as resting
    minLevel      = 6,          -- stay hidden below this level (1 = every level)
    sound         = true,
    buffNames     = { "Well Fed" },
}

local STYLES = {
    missing  = { r = 1.00, g = 0.15, b = 0.10, label = "Not Well Fed",           anim = "flash" },
    test     = { r = 1.00, g = 0.15, b = 0.10, label = "Test: Not Well Fed",     anim = "flash" },
    expiring = { r = 1.00, g = 0.82, b = 0.00, label = "Well Fed",               anim = "pulse" },
    eating   = { r = 0.35, g = 1.00, b = 0.35, label = "Eating...",              anim = nil },
    unlocked = { r = 0.55, g = 0.80, b = 1.00, label = "Drag me, /wellfed lock", anim = nil },
}

----------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------

local db                        -- WellFedReminderDB, ready after ADDON_LOADED
local frame                     -- the icon
local trackedNames = {}         -- lowercased buff names that count as being fed
local eatingNames  = {}         -- lowercased eat/drink channel buff names
local localized    = {}         -- spell names on non-English clients
local spellIcon                 -- the real Well Fed icon, when it can be resolved
local testUntil
local shownState, shownIcon

local aura = {                  -- the last successful reading of the player's buffs
    known   = false,
    wellFed = nil,              -- { expires = GetTime()-based time or math.huge, icon = ... }
    eating  = nil,              -- { start = GetTime()-based time, icon = ... }
    readAt  = -math.huge,
    pending = true,             -- a reading is owed (restrictions blocked the last attempt)
    fedSeen = false,            -- Well Fed was seen since the last alert sound
    lastError = nil,
}

----------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = CopyDefaults(v, {})
            else
                dst[k] = v
            end
        end
    end
    return dst
end

local function FormatTime(seconds)
    seconds = math.max(0, math.ceil(seconds))
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return tostring(seconds)
end

local function OnOff(value)
    return value and "|cff40ff40on|r" or "|cffff4040off|r"
end

local function PlayAlert()
    local kit = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
    pcall(PlaySound, kit, "Master")
end

-- Secret values (Midnight-era API): addon code may not compare or test them, so every
-- value read from aura data is checked with issecretvalue() before it is used.
local issecretvalue, issecrettable = issecretvalue, issecrettable

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function Plain(v)                 -- the value, or nil if it's secret
    if IsSecret(v) then return nil end
    return v
end

local function IsTrue(fn, ...)          -- true only for a plain, truthy result of fn(...)
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn, ...)
    if not ok or IsSecret(result) then return false end
    return result and true or false
end

local function PlayerLevel()            -- the player's level, or nil if it can't be read
    local ok, level = pcall(UnitLevel, "player")
    if ok and not IsSecret(level) and type(level) == "number" then return level end
    return nil
end

----------------------------------------------------------------------------------------
-- Addon restrictions (combat, boss encounters, PvP matches)
----------------------------------------------------------------------------------------

local RESTRICTION_TYPES = { 0, 1, 2, 3 }    -- Combat, Encounter, ChallengeMode, PvPMatch
if Enum and Enum.AddOnRestrictionType then
    local E = Enum.AddOnRestrictionType
    RESTRICTION_TYPES = {}
    for _, key in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch" }) do
        if E[key] ~= nil then RESTRICTION_TYPES[#RESTRICTION_TYPES + 1] = E[key] end
    end
end

local function AurasRestricted()
    if InCombatLockdown() or IsTrue(UnitAffectingCombat, "player") then return true end
    local isActive = C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive
    if isActive then
        for i = 1, #RESTRICTION_TYPES do
            if IsTrue(isActive, RESTRICTION_TYPES[i]) then return true end
        end
    end
    return false
end

----------------------------------------------------------------------------------------
-- Reading buffs
----------------------------------------------------------------------------------------

local function GetBuff(index)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        return C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
    elseif UnitAura then                                         -- older clients
        local name, icon, _, _, duration, expirationTime = UnitAura("player", index, "HELPFUL")
        if name then
            return { name = name, icon = icon, duration = duration, expirationTime = expirationTime }
        end
    end
    return nil
end

-- Returns true, wellFed, eating   when the buffs could be read
--      or false                    when the data is secret right now
local function ScanAuras()
    local wellFed, eating
    local readable, unreadable = 0, 0

    for i = 1, 255 do
        local data = GetBuff(i)
        if not data then break end

        local name
        if not (issecrettable and issecrettable(data)) then
            name = data.name
        end

        if IsSecret(name) or type(name) ~= "string" then
            unreadable = unreadable + 1
        else
            readable = readable + 1
            local key = string.lower(name)

            if trackedNames[key] then
                local exp = Plain(data.expirationTime)
                local expires = (type(exp) == "number" and exp > 0) and exp or math.huge
                if not wellFed or expires > wellFed.expires then
                    wellFed = { expires = expires, icon = Plain(data.icon) }
                end
            elseif eatingNames[key] then
                local exp, dur = Plain(data.expirationTime), Plain(data.duration)
                local start
                if type(exp) == "number" and type(dur) == "number" and exp > 0 and dur > 0 then
                    start = exp - dur
                end
                if not eating or (start and (not eating.start or start < eating.start)) then
                    eating = { start = start, icon = Plain(data.icon) }
                end
            end
        end
    end

    if not wellFed and unreadable > 0 and readable == 0 then
        return false
    end
    return true, wellFed, eating
end

local function Rescan()
    if AurasRestricted() then
        aura.pending = true
        return false
    end

    local ok, readOK, wellFed, eating = pcall(ScanAuras)
    if not ok then aura.lastError = tostring(readOK) end
    if not ok or not readOK then
        aura.pending = true
        return false
    end

    local now = GetTime()
    if eating and not eating.start then
        eating.start = (aura.eating and aura.eating.start) or now
    end

    aura.known, aura.pending, aura.readAt = true, false, now
    aura.wellFed, aura.eating = wellFed, eating
    if wellFed then
        aura.fedSeen = true
        if wellFed.icon then db.lastIcon = wellFed.icon end
    end
    return true
end

----------------------------------------------------------------------------------------
-- What to show
----------------------------------------------------------------------------------------

-- Returns nil (show nothing) or one of the STYLES keys, plus seconds left for "expiring".
local function ComputeState(now)
    if testUntil then
        if now < testUntil then return "test" end
        testUntil = nil
    end
    if not db.locked then return "unlocked" end
    if not db.enabled then return nil end
    if IsTrue(UnitIsDeadOrGhost, "player") or IsTrue(UnitOnTaxi, "player") then return nil end
    if db.hideInCities and IsTrue(IsResting) then return nil end    -- in a city or inn, fed or not
    local level = PlayerLevel()
    if level and level < db.minLevel then return nil end            -- not the minimum level yet
    if db.instancesOnly and not IsTrue(IsInInstance) then return nil end

    local restricted = AurasRestricted()
    if restricted and not db.showInCombat then return nil end
    if not aura.known then return nil end

    local eat = aura.eating
    local eatingNow = not restricted and eat ~= nil and now < eat.start + EAT_SECONDS + EAT_GRACE

    local wellFed = aura.wellFed
    if wellFed and wellFed.expires > now then
        local remaining = wellFed.expires - now
        if db.warnSeconds > 0 and remaining <= db.warnSeconds then
            if eatingNow then return "eating" end
            return "expiring", remaining
        end
        return nil                                   -- fed, nothing to remind
    end

    if eatingNow then return "eating" end
    return "missing"
end

local function DefaultIcon()
    return db.lastIcon or spellIcon or DEFAULT_ICON
end

local function SetAnimation(kind)
    if kind == "flash" then
        frame.pulse:Stop()
        if not frame.flash:IsPlaying() then frame.flash:Play() end
    elseif kind == "pulse" then
        frame.flash:Stop()
        if not frame.pulse:IsPlaying() then frame.pulse:Play() end
    else
        frame.flash:Stop()
        frame.pulse:Stop()
    end
end

local function Refresh()
    if not frame or not db then return end
    local now = GetTime()
    local state, remaining = ComputeState(now)

    if state == "missing" and aura.fedSeen then      -- Well Fed just dropped
        aura.fedSeen = false
        if db.sound then PlayAlert() end
    end

    if not state then
        if frame:IsShown() then
            SetAnimation(nil)
            frame:EnableMouse(false)
            frame:Hide()
        end
        shownState = nil
        return
    end

    if state ~= shownState then
        shownState = state
        local style = STYLES[state]
        frame.border:SetColorTexture(style.r, style.g, style.b, 1)
        frame.label:SetText(style.label)
        frame.label:SetTextColor(style.r, style.g, style.b)
        frame:EnableMouse(state == "unlocked")
        SetAnimation(style.anim)
        frame:Show()
    end

    local icon, timer = DefaultIcon(), ""
    if state == "expiring" then
        icon = (aura.wellFed and aura.wellFed.icon) or icon
        timer = FormatTime(remaining)
    elseif state == "eating" and aura.eating then
        icon = aura.eating.icon or icon
        local left = aura.eating.start + EAT_SECONDS - now
        timer = left > 0 and FormatTime(left) or ""
    end

    if icon ~= shownIcon then
        frame.icon:SetTexture(icon)
        shownIcon = icon
    end
    frame.timer:SetText(timer)
end

----------------------------------------------------------------------------------------
-- The icon
----------------------------------------------------------------------------------------

local function MakeLoop(target, toAlpha, duration)
    local group = target:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(toAlpha)
    fade:SetDuration(duration)
    fade:SetSmoothing("IN_OUT")
    return group
end

local function CreateIcon()
    local f = CreateFrame("Frame", "WellFedReminderIcon", UIParent)
    f:SetSize(ICON_SIZE, ICON_SIZE)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:Hide()

    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetAllPoints()

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 3, -3)
    f.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.timer = f:CreateFontString(nil, "OVERLAY")
    f.timer:SetFont(FONT, 18, "OUTLINE")
    f.timer:SetPoint("CENTER")

    f.label = f:CreateFontString(nil, "OVERLAY")
    f.label:SetFont(FONT, 12, "OUTLINE")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -4)

    f.flash = MakeLoop(f, 0.15, 0.45)
    f.pulse = MakeLoop(f, 0.55, 0.9)

    f:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        db.point = { point, relativePoint, x, y }
    end)
    return f
end

local function ApplyLayout()
    if not frame then return end
    local p = db.point
    frame:ClearAllPoints()
    frame:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", tonumber(p[3]) or 0, tonumber(p[4]) or 0)
    frame:SetScale(db.scale)
end

----------------------------------------------------------------------------------------
-- Buff names
----------------------------------------------------------------------------------------

local function RebuildNames()
    for k in pairs(trackedNames) do trackedNames[k] = nil end
    for k in pairs(eatingNames) do eatingNames[k] = nil end

    for _, name in ipairs(db.buffNames) do
        if type(name) == "string" and name ~= "" then trackedNames[string.lower(name)] = true end
    end
    if localized.wellFed then trackedNames[string.lower(localized.wellFed)] = true end

    eatingNames["food"], eatingNames["drink"], eatingNames["food & drink"] = true, true, true
    if localized.food then eatingNames[string.lower(localized.food)] = true end
    if localized.drink then eatingNames[string.lower(localized.drink)] = true end
end

local function ResolveSpell(id)
    local name, icon
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and type(n) == "string" and not IsSecret(n) then name = n end
        if C_Spell.GetSpellTexture then
            local ok2, t = pcall(C_Spell.GetSpellTexture, id)
            if ok2 and not IsSecret(t) and t then icon = t end
        end
    elseif GetSpellInfo then
        local ok, n, _, t = pcall(GetSpellInfo, id)
        if ok and type(n) == "string" and not IsSecret(n) then name = n end
        if ok and not IsSecret(t) and t then icon = t end
    end
    return name, icon
end

local function LearnSpellData()
    local wfName, wfIcon = ResolveSpell(WELL_FED_SPELL)
    local locale = GetLocale and GetLocale() or "enUS"

    if locale ~= "enUS" and locale ~= "enGB" then
        localized.wellFed = wfName
        localized.food = (ResolveSpell(FOOD_SPELL))
        localized.drink = (ResolveSpell(DRINK_SPELL))
        spellIcon = wfIcon
    elseif wfName and trackedNames[string.lower(wfName)] then
        spellIcon = wfIcon               -- only trust the icon if the spell really is Well Fed
    end
    RebuildNames()
end

local function FindName(list, name)
    local wanted = string.lower(name)
    for i, existing in ipairs(list) do
        if type(existing) == "string" and string.lower(existing) == wanted then return i end
    end
    return nil
end

----------------------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------------------

local function ShowHelp()
    Print("commands (/wellfed or /wfr):")
    local lines = {
        "  unlock / lock - unlock to drag the icon, lock when done",
        "  test - preview the flashing reminder for 10 seconds",
        string.format("  warn <seconds> - warn before Well Fed runs out, 0 = off (now %d)", db.warnSeconds),
        string.format("  scale <0.5-3> - icon size (now %.2f)", db.scale),
        "  combat - keep showing during combat (now " .. OnOff(db.showInCombat) .. ")",
        "  instance - only remind inside dungeons and raids (now " .. OnOff(db.instancesOnly) .. ")",
        "  city - hide in cities and inns, fed or not (now " .. OnOff(db.hideInCities) .. ")",
        string.format("  level <number> - stay hidden until this level, 1 = every level (now %d)", db.minLevel),
        "  sound - alert sound when Well Fed drops (now " .. OnOff(db.sound) .. ")",
        "  add <buff name> / remove <buff name> / list - which buffs count as fed",
        "  on / off - turn the reminder on or off (now " .. OnOff(db.enabled) .. ")",
        "  status - what the addon sees right now",
        "  reset - restore all defaults",
    }
    for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage(line) end
end

local function PrintStatus()
    local now = GetTime()
    if not aura.known then
        Print("no buff reading yet" .. (aura.lastError and (" (error: " .. aura.lastError .. ")") or ""))
        return
    end
    local wellFed = aura.wellFed
    if wellFed and wellFed.expires > now then
        if wellFed.expires == math.huge then
            Print("Well Fed: active")
        else
            Print("Well Fed: " .. FormatTime(wellFed.expires - now) .. " left")
        end
    else
        Print("Well Fed: missing")
    end
    if db.hideInCities and IsTrue(IsResting) then
        Print("hidden while you're in a city or inn - /wellfed city to change that")
    end
    local level = PlayerLevel()
    if level and level < db.minLevel then
        Print(string.format("hidden until level %d (you're %d) - /wellfed level to change that", db.minLevel, level))
    end
    if AurasRestricted() then
        Print(string.format("buff data is locked right now (combat); last reading %ds ago",
            math.floor(now - aura.readAt)))
    end
    if aura.lastError then Print("last error: " .. aura.lastError) end
end

local function HandleSlash(msg)
    if not db or not frame then return end
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd, rest = string.lower(cmd or ""), rest or ""

    if cmd == "" or cmd == "help" then
        ShowHelp()
    elseif cmd == "unlock" or cmd == "move" then
        db.locked = false
        Print("unlocked - drag the icon where you want it, then type /wellfed lock")
    elseif cmd == "lock" then
        db.locked = true
        Print("locked")
    elseif cmd == "test" then
        testUntil = GetTime() + TEST_SECONDS
        Print("showing a 10 second preview")
    elseif cmd == "warn" then
        local n = tonumber(rest)
        if n and n >= 0 then
            db.warnSeconds = math.floor(n)
            if db.warnSeconds == 0 then
                Print("expiry warning off")
            else
                Print("warning when " .. FormatTime(db.warnSeconds) .. " of Well Fed is left")
            end
        else
            Print("usage: /wellfed warn <seconds>   (0 turns it off)")
        end
    elseif cmd == "scale" then
        local n = tonumber(rest)
        if n and n >= 0.5 and n <= 3 then
            db.scale = n
            ApplyLayout()
            Print(string.format("scale set to %.2f", n))
        else
            Print("usage: /wellfed scale <0.5 - 3>")
        end
    elseif cmd == "combat" then
        db.showInCombat = not db.showInCombat
        Print("show during combat: " .. OnOff(db.showInCombat))
    elseif cmd == "instance" or cmd == "instances" then
        db.instancesOnly = not db.instancesOnly
        Print("only in dungeons and raids: " .. OnOff(db.instancesOnly))
    elseif cmd == "city" or cmd == "cities" then
        db.hideInCities = not db.hideInCities
        Print("hide in cities and inns: " .. OnOff(db.hideInCities))
    elseif cmd == "level" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 100 then
            db.minLevel = math.floor(n)
            if db.minLevel <= 1 then
                Print("showing at every level")
            else
                Print("hidden until level " .. db.minLevel)
            end
        else
            Print("usage: /wellfed level <number>   (1 shows it at every level)")
        end
    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("alert sound: " .. OnOff(db.sound))
        if db.sound then PlayAlert() end
    elseif cmd == "on" or cmd == "enable" then
        db.enabled = true
        Print("enabled")
    elseif cmd == "off" or cmd == "disable" then
        db.enabled = false
        Print("disabled - /wellfed on turns it back on")
    elseif cmd == "add" then
        if rest == "" then
            Print("usage: /wellfed add <buff name>")
        else
            if not FindName(db.buffNames, rest) then table.insert(db.buffNames, rest) end
            RebuildNames()
            aura.pending = true
            Print("now counting \"" .. rest .. "\" as fed")
        end
    elseif cmd == "remove" or cmd == "rm" or cmd == "delete" then
        local index = rest ~= "" and FindName(db.buffNames, rest)
        if rest == "" then
            Print("usage: /wellfed remove <buff name>")
        elseif index then
            local removed = table.remove(db.buffNames, index)
            RebuildNames()
            aura.pending = true
            Print("stopped counting \"" .. removed .. "\"")
            if #db.buffNames == 0 then
                Print("nothing is tracked now, so the reminder will always show - /wellfed add Well Fed")
            end
        else
            Print("not in the list: \"" .. rest .. "\" - see /wellfed list")
        end
    elseif cmd == "list" then
        local names = #db.buffNames > 0 and table.concat(db.buffNames, ", ") or "(none)"
        Print("buffs that count as fed: " .. names)
        if localized.wellFed then Print("plus your client's own name for it: " .. localized.wellFed) end
    elseif cmd == "status" then
        PrintStatus()
    elseif cmd == "reset" then
        WellFedReminderDB = CopyDefaults(DEFAULTS, {})
        db = WellFedReminderDB
        RebuildNames()
        ApplyLayout()
        aura.pending = true
        Print("settings reset")
    else
        Print("unknown command \"" .. cmd .. "\"")
        ShowHelp()
    end

    Refresh()
end

SLASH_WELLFEDREMINDER1 = "/wellfed"
SLASH_WELLFEDREMINDER2 = "/wfr"
SlashCmdList.WELLFEDREMINDER = HandleSlash

----------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------

local RUNTIME_EVENTS = {
    "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "ZONE_CHANGED_NEW_AREA",
    "PLAYER_UPDATE_RESTING",                     -- entering or leaving a city or inn
    "PLAYER_LEVEL_UP",
    "ADDON_RESTRICTION_STATE_CHANGED",           -- Midnight-era clients only
}

local function OnTick()
    if aura.pending or GetTime() - aura.readAt >= RESCAN_EVERY then
        Rescan()
    end
    Refresh()
end

local function Sanitize()
    if type(db.buffNames) ~= "table" then db.buffNames = { "Well Fed" } end
    if type(db.point) ~= "table" then db.point = CopyDefaults(DEFAULTS.point, {}) end
    if type(db.scale) ~= "number" or db.scale < 0.5 or db.scale > 3 then db.scale = 1 end
    if type(db.warnSeconds) ~= "number" or db.warnSeconds < 0 then db.warnSeconds = DEFAULTS.warnSeconds end
    if type(db.minLevel) ~= "number" or db.minLevel < 0 then db.minLevel = DEFAULTS.minLevel end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        WellFedReminderDB = CopyDefaults(DEFAULTS, WellFedReminderDB or {})
        db = WellFedReminderDB
        Sanitize()
        RebuildNames()
        frame = CreateIcon()
        ApplyLayout()

    elseif event == "PLAYER_LOGIN" then
        LearnSpellData()
        for _, name in ipairs(RUNTIME_EVENTS) do
            pcall(self.RegisterEvent, self, name)
        end
        if not (self.RegisterUnitEvent and pcall(self.RegisterUnitEvent, self, "UNIT_AURA", "player")) then
            pcall(self.RegisterEvent, self, "UNIT_AURA")
        end
        C_Timer.NewTicker(TICK, OnTick)
        Rescan()
        Refresh()

    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- the new restriction state only takes effect after this event finishes dispatching
        C_Timer.After(0, function()
            aura.pending = true
            Rescan()
            Refresh()
        end)

    elseif event == "UNIT_AURA" and not IsSecret(arg1) and arg1 ~= "player" then
        return

    else
        aura.pending = true
        Rescan()
        Refresh()
    end
end)
