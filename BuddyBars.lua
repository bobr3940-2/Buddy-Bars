local ADDON_NAME = ...   -- the addon's folder name, supplied by the client
local PREFIX = "BDYBARS"

BuddyBarsDB = BuddyBarsDB or {}

------------------------------------------------------------
-- Compatibility shims (Retail / Classic Era / Cata / MoP)  --
-- Every client-version-specific API is looked up here once, --
-- with a fallback, so a Blizzard rename can't break load.   --
------------------------------------------------------------
local Chat = C_ChatInfo or {}
local RegisterPrefix = Chat.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local SendAddon      = Chat.SendAddonMessage or SendAddonMessage
if RegisterPrefix then pcall(RegisterPrefix, PREFIX) end

-- 12.0+ "secret values": never compare, index or format one.
local IsSecret = issecretvalue or function() return false end

local PARTY_INSTANCE = (Enum and Enum.PartyCategory and Enum.PartyCategory.Instance)
                    or LE_PARTY_CATEGORY_INSTANCE or 2

-- Send results that mean "try again shortly" (throttle, or 12.0+ lockdown
-- during boss encounters / Mythic+ / rated PvP). Built by name so it is
-- harmless if a name doesn't exist on this client.
local RETRY = {}
do
    local R = Enum and Enum.SendAddonMessageResult
    if R then
        for _, k in ipairs({ "AddonMessageThrottle", "ChannelThrottle", "ChatThrottle",
                             "AddOnMessageLockdown", "AddonMessageLockdown" }) do
            if R[k] then RETRY[R[k]] = true end
        end
    end
end

------------------------------------------------------------
-- Version checking                                       --
------------------------------------------------------------
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = (GetMeta and GetMeta(ADDON_NAME or "BuddyBars", "Version")) or "0"

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
    -- also treat "XP gain turned off" (Retail) like max level: nothing to show
    if IsXPUserDisabled and IsXPUserDisabled() then return true end
    if IsPlayerAtEffectiveMaxLevel then return IsPlayerAtEffectiveMaxLevel() end
    return UnitLevel("player") >= GetMaxPlayerLevel()
end

local function UpdateBars()
    local stackIndex = 0
    for i = 1, 4 do
        local bar = bars[i]
        local unit = "party" .. i
        local name = UnitExists(unit) and UnitName(unit)
        if name and IsSecret(name) then name = nil end
        local d = name and data[name]

        if d and d.max and d.max > 0 then
            local xp = math.min(d.xp, d.max)
            bar:SetMinMaxValues(0, d.max)
            bar:SetValue(xp)
            bar.text:SetText(string.format("%d  -  %.0f%%", d.level, xp / d.max * 100))

            local pf = FindPartyFrame(i)
            local relTo, slot = pf or anchor, pf and 0 or stackIndex
            if not pf then stackIndex = stackIndex + 1 end
            if bar.relTo ~= relTo or bar.slot ~= slot then
                bar.relTo, bar.slot = relTo, slot
                bar:ClearAllPoints()
                if pf then
                    bar:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 4, 4)
                else
                    bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(slot * 12) - 2)
                end
            end
            bar:Show()
        else
            -- no data yet, or max level: nothing to show
            bar.relTo, bar.slot = nil, nil
            bar:Hide()
        end
    end
end

------------------------------------------------------------
-- Communication                                          --
------------------------------------------------------------
local function GroupChannel()
    if IsInGroup(PARTY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInGroup() then return "PARTY" end
end

-- Returns nil (nothing to do), "ok", or "retry" (blocked/throttled; try later).
local function Send(msg)
    local channel = GroupChannel()
    if not channel or not SendAddon then return end
    if Chat.InChatMessagingLockdown and Chat.InChatMessagingLockdown() then
        return "retry"
    end
    local ok, result = pcall(SendAddon, PREFIX, msg, channel)
    if not ok or result == false or RETRY[result] then return "retry" end
    return "ok"
end

local function BuildXPMessage()
    local max = IsMaxLevel() and 0 or UnitXPMax("player")
    return string.format("XP:%d:%d:%d", UnitLevel("player"), UnitXP("player"), max)
end

-- Coalesces bursts (mob kills, quest turn-ins) into one send, built from
-- fresh values at send time, and retries every 5s (up to 12 times) if the
-- client refuses the message, e.g. during a restricted encounter.
local function MakeSender(buildMsg, delay)
    local queued, tries = false, 0
    local queue
    local function fire()
        queued = false
        local status = Send(buildMsg())
        if status == "retry" and tries < 12 then
            tries = tries + 1
            queue(5)
        else
            tries = 0
        end
    end
    function queue(wait)
        if queued then return end
        queued = true
        C_Timer.After(wait or delay, fire)
    end
    return queue, fire
end

local QueueSend, SendMyXP = MakeSender(BuildXPMessage, 1)
local QueueVersion = MakeSender(function() return "VER:" .. VERSION end, 1.5)

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
        if IsSecret(prefix) or IsSecret(msg) or IsSecret(sender) then return end
        if prefix ~= PREFIX or type(msg) ~= "string" then return end
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

-- Party frames can appear/disappear without any event we hear about (Edit
-- Mode layout swaps, raid-style frames toggled, other UI addons), so
-- re-check placement once a second. It's four bars; the cost is negligible.
C_Timer.NewTicker(1, UpdateBars)

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
