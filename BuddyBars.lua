local PREFIX = "BDYBARS"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

BuddyBarsDB = BuddyBarsDB or {}

------------------------------------------------------------
-- Version checking                                       --
------------------------------------------------------------
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = GetMeta("BuddyBars", "Version") or "0"

local function ParseVersion(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- true if version a is newer than version b
local function IsNewer(a, b)
    local x, y = ParseVersion(a), ParseVersion(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

StaticPopupDialogs["BUDDYBARS_UPDATE"] = {
    text = "BuddyBars: Another party member has a newer version (%s). Please update your addon.",
    button1 = OKAY,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local pendingNotice -- version waiting to be shown once combat ends

local function ShowUpdateNotice(ver)
    -- only ever show once per newer version (remembered across sessions)
    local seen = BuddyBarsDB.notifiedVersion
    if seen and not IsNewer(ver, seen) then return end
    if InCombatLockdown() then
        if not pendingNotice or IsNewer(ver, pendingNotice) then pendingNotice = ver end
        return
    end
    BuddyBarsDB.notifiedVersion = ver
    StaticPopup_Show("BUDDYBARS_UPDATE", ver)
end

local data = {}   -- data[shortName] = { level=, xp=, max= }
local bars = {}   -- bars[1..4], one per party slot

------------------------------------------------------------
-- Movable fallback anchor (used if default party frames  --
-- aren't found, e.g. you use a unit-frame addon)         --
------------------------------------------------------------
local anchor = CreateFrame("Frame", "BuddyBarsAnchor", UIParent, "BackdropTemplate")
anchor:SetSize(150, 14)
anchor:SetMovable(true)
anchor:EnableMouse(false)
anchor:RegisterForDrag("LeftButton")
anchor:SetScript("OnDragStart", anchor.StartMoving)
anchor:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    BuddyBarsDB.pos = { p, rp, x, y }
end)
anchor:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
anchor:SetBackdropColor(0, 0.6, 1, 0)

local function RestorePosition()
    anchor:ClearAllPoints()
    local pos = BuddyBarsDB.pos
    if pos then
        anchor:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        anchor:SetPoint("LEFT", UIParent, "LEFT", 220, 100)
    end
end

------------------------------------------------------------
-- Bars                                                   --
------------------------------------------------------------
local function CreateBar(i)
    local bar = CreateFrame("StatusBar", "BuddyBarsBar" .. i, UIParent)
    bar:SetSize(110, 8)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.58, 0.0, 0.55) -- XP purple
    bar:SetMinMaxValues(0, 1)

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0, 0, 0, 0.6)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.text:SetPoint("CENTER")
    bar.text:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE")

    bar:Hide()
    return bar
end

for i = 1, 4 do bars[i] = CreateBar(i) end

local function FindPartyFrame(i)
    -- Retail: PartyFrame.MemberFrameN; Classic: PartyMemberFrameN
    local pf = (PartyFrame and PartyFrame["MemberFrame" .. i]) or _G["PartyMemberFrame" .. i]
    if pf and pf:IsShown() then return pf end
end

local function IsMaxLevel()
    if IsPlayerAtEffectiveMaxLevel then return IsPlayerAtEffectiveMaxLevel() end
    return UnitLevel("player") >= GetMaxPlayerLevel()
end

local function UpdateBars()
    local stackIndex = 0
    for i = 1, 4 do
        local bar = bars[i]
        local unit = "party" .. i
        local name = UnitExists(unit) and UnitName(unit)
        local d = name and data[name]

        if d and d.max and d.max > 0 then
            bar:SetMinMaxValues(0, d.max)
            bar:SetValue(d.xp)
            bar.text:SetText(string.format("%d  -  %.0f%%", d.level, d.xp / d.max * 100))

            bar:ClearAllPoints()
            local pf = FindPartyFrame(i)
            if pf then
                bar:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 4, 4)
            else
                bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(stackIndex * 12) - 2)
                stackIndex = stackIndex + 1
            end
            bar:Show()
        else
            -- no data yet, or max level: nothing to show
            bar:Hide()
        end
    end
end

------------------------------------------------------------
-- Communication                                          --
------------------------------------------------------------
local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInGroup() then return "PARTY" end
end

local function SendMyXP()
    local channel = GroupChannel()
    if not channel then return end
    local max = IsMaxLevel() and 0 or UnitXPMax("player")
    local msg = string.format("XP:%d:%d:%d", UnitLevel("player"), UnitXP("player"), max)
    C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
end

-- Throttle so rapid XP gains (mob kills, quest turn-ins) don't spam
local pending
local function QueueSend()
    if pending then return end
    pending = true
    C_Timer.After(1, function()
        pending = nil
        SendMyXP()
    end)
end

local function SendVersion()
    local channel = GroupChannel()
    if not channel then return end
    C_ChatInfo.SendAddonMessage(PREFIX, "VER:" .. VERSION, channel)
end

local pendingVer
local function QueueVersion()
    if pendingVer then return end
    pendingVer = true
    C_Timer.After(1.5, function()
        pendingVer = nil
        SendVersion()
    end)
end

------------------------------------------------------------
-- Events                                                 --
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "BuddyBars" then
            BuddyBarsDB = BuddyBarsDB or {}
            RestorePosition()
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        -- drop data for people who left
        local present = {}
        for i = 1, 4 do
            local n = UnitExists("party" .. i) and UnitName("party" .. i)
            if n then present[n] = true end
        end
        for n in pairs(data) do
            if not present[n] then data[n] = nil end
        end
        QueueSend()
        QueueVersion()
        UpdateBars()

    elseif event == "PLAYER_XP_UPDATE" then
        QueueSend()

    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitXP can lag a moment after a level-up; wait a bit
        C_Timer.After(2, SendMyXP)

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingNotice then
            local v = pendingNotice
            pendingNotice = nil
            ShowUpdateNotice(v)
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if prefix ~= PREFIX then return end
        local short = Ambiguate(sender, "short")
        if short == UnitName("player") then return end

        local theirVersion = msg:match("^VER:([%d%.]+)$")
        if theirVersion then
            if IsNewer(theirVersion, VERSION) then ShowUpdateNotice(theirVersion) end
            return
        end

        local level, xp, max = msg:match("^XP:(%d+):(%d+):(%d+)$")
        if level then
            data[short] = { level = tonumber(level), xp = tonumber(xp), max = tonumber(max) }
            UpdateBars()
        end
    end
end)

------------------------------------------------------------
-- Slash command: /bb unlock | lock | reset               --
------------------------------------------------------------
SLASH_BUDDYBARS1 = "/buddybars"
SLASH_BUDDYBARS2 = "/bb"
SlashCmdList["BUDDYBARS"] = function(arg)
    arg = (arg or ""):lower()
    if arg == "unlock" then
        anchor:EnableMouse(true)
        anchor:SetBackdropColor(0, 0.6, 1, 0.5)
        print("BuddyBars: drag the blue bar to move the fallback anchor. /bb lock when done.")
    elseif arg == "lock" then
        anchor:EnableMouse(false)
        anchor:SetBackdropColor(0, 0.6, 1, 0)
        print("BuddyBars: locked.")
    elseif arg == "reset" then
        BuddyBarsDB.pos = nil
        RestorePosition()
        print("BuddyBars: position reset.")
    else
        print("BuddyBars: /bb unlock | lock | reset")
    end
end
