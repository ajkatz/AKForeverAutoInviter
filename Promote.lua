-- Promote: raid assistant for everyone, or for the names on a list (the user, 2026-10-22: "the option to
-- auto promote everyone and another to auto promote from a list"; promote = the raid's assistant rank, for
-- anyone in the raid however they joined) - and, when asked, any party you lead made a raid at once ("also
-- an option to auto-convert to raid"), since only a raid has assistants.
--
-- Only a raid has the assistant rank, and only its leader hands it out, so nothing happens in a party or
-- while somebody else leads. "Everyone" is the raid's own setting (C_PartyInfo.SetEveryoneIsAssistant -
-- the "Make everyone assistant" box of the raid window), switched back off when you untick it here; the list
-- promotes each listed name as it joins (C_PartyInfo.PromoteToAssistant). Both run on the roster's own
-- updates, gathered into one look half a second later, and work whether or not this character invites.
-- Both calls carry HasRestrictions in the API docs; PromoteToLeader, alike flagged, raised nothing from a
-- timer in the 2026-10-01 probe - to be confirmed in game for these two.
local _, ns = ...

local Promote = {}
ns.Promote = Promote

local SETTLE = 0.5       -- roster updates come in bursts
local RETRY_SECONDS = 10 -- a name promoted is not asked again for this long

Promote.stats = { looks = 0, promoted = 0, everyoneSet = 0, failed = 0 }

local tried = {}           -- [name key] = GetTime() of the last promote
local everyoneByUs = false -- the raid's "everyone" switched on by this addon
local lookQueued = false

local function readable(fn, ...)
    local result = ns.Readable(fn, ...)
    return result and result[1]
end

local function canPromote()
    return readable(IsInRaid) and readable(UnitIsGroupLeader, "player")
end

function Promote:Listed(name)
    local key = ns.NameKey(name)
    if not key then
        return false
    end
    for _, listed in ipairs(ns:GetOption("promoteList")) do
        if ns.NameKey(listed) == key then
            return true
        end
    end
    return false
end

local function setEveryone(on)
    local api = C_PartyInfo and C_PartyInfo.SetEveryoneIsAssistant
    if type(api) ~= "function" then
        return false
    end
    local ok = pcall(api, on)
    ns:Log("everyone_assistant", { on = on, ok = ok })
    if not ok then
        Promote.stats.failed = Promote.stats.failed + 1
        return false
    end
    Promote.stats.everyoneSet = Promote.stats.everyoneSet + 1
    return true
end

local function everyoneIsAssistant()
    if C_PartyInfo and type(C_PartyInfo.IsEveryoneAssistant) == "function" then
        return readable(C_PartyInfo.IsEveryoneAssistant) and true or false
    end
    if type(IsEveryoneAssistant) == "function" then
        return readable(IsEveryoneAssistant) and true or false
    end
    return false
end

local function promote(name)
    local api = C_PartyInfo and C_PartyInfo.PromoteToAssistant
    if type(api) ~= "function" then
        return
    end
    local ok, err = pcall(api, name)
    if not ok then
        Promote.stats.failed = Promote.stats.failed + 1
        ns:Log("promote_failed", { name = name, error = tostring(err) })
        return
    end
    Promote.stats.promoted = Promote.stats.promoted + 1
    ns:Log("promoted", { name = name })
    ns:Print("made " .. ns.DisplayName(name) .. " a raid assistant (on your promote list).")
end

-- any party you lead made a raid, the moment it has somebody in it
local function convertParty()
    if not ns:GetOption("raidAlways") or readable(IsInRaid) or not readable(IsInGroup) or not readable(UnitIsGroupLeader, "player") then
        return false
    end
    local convert = C_PartyInfo and C_PartyInfo.ConvertToRaid
    if type(convert) ~= "function" then
        return false
    end
    local ok = pcall(convert)
    ns:Log("raid_converted", { why = "always", ok = ok })
    if ok then
        Promote.stats.converted = (Promote.stats.converted or 0) + 1
        ns:Print("made the party a raid.")
    else
        Promote.stats.failed = Promote.stats.failed + 1
    end
    return ok
end

function Promote:Look()
    lookQueued = false
    self.stats.looks = self.stats.looks + 1
    if convertParty() then
        return -- the raid's own roster update brings the next look
    end
    if not canPromote() then
        return
    end
    local wantEveryone = ns:GetOption("promoteAll")
    if wantEveryone and not everyoneIsAssistant() then
        if setEveryone(true) then
            everyoneByUs = true
            ns:Print("everyone in the raid is an assistant now.")
        end
    elseif not wantEveryone and everyoneByUs then
        everyoneByUs = false
        if everyoneIsAssistant() then
            setEveryone(false)
        end
    end
    if wantEveryone then
        return -- the list adds nothing to everyone
    end
    if #ns:GetOption("promoteList") == 0 then
        return
    end
    local now = GetTime()
    for index = 1, 40 do
        local info = ns.Readable(GetRaidRosterInfo, index)
        local name, rank = info and info[1], info and info[2]
        if type(name) == "string" and rank == 0 and self:Listed(name) then
            local key = ns.NameKey(name)
            if not tried[key] or now - tried[key] > RETRY_SECONDS then
                tried[key] = now
                promote(name)
            end
        end
    end
end

local function queueLook()
    if lookQueued then
        return
    end
    lookQueued = true
    C_Timer.After(SETTLE, function()
        ns.SafeCall(Promote.Look, Promote)
    end)
end

ns:On("GROUP_ROSTER_UPDATE", queueLook)
ns:On("PARTY_LEADER_CHANGED", queueLook)
ns:Listen("OPTION_CHANGED", function(key)
    if key == "promoteAll" or key == "promoteList" or key == "raidAlways" then
        queueLook()
    end
end)

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function listText()
    local list = ns:GetOption("promoteList")
    return #list > 0 and table.concat(list, ", ") or "nobody"
end

ns:RegisterCommand("promote", "all on|off, add <name>, remove <name>, list, clear - raid assistant for everyone or a list", function(rest)
    local word, arg = string.match(rest, "^(%S*)%s*(.-)%s*$")
    word = string.lower(word or "")
    local list = ns:GetOption("promoteList")
    if word == "all" or word == "everyone" then
        local value = string.lower(arg or "")
        local on
        if value == "on" then on = true elseif value == "off" then on = false else on = not ns:GetOption("promoteAll") end
        ns:SetOption("promoteAll", on)
        ns:Print("raid assistant for everyone: " .. (on and "on" or "off"))
    elseif word == "add" and arg ~= "" then
        if not Promote:Listed(arg) then
            list[#list + 1] = ns.DisplayName(arg)
            ns:SetOption("promoteList", list)
        end
        ns:Print("promote list: " .. listText())
    elseif word == "remove" and arg ~= "" then
        local key = ns.NameKey(arg)
        for index = #list, 1, -1 do
            if ns.NameKey(list[index]) == key then
                table.remove(list, index)
            end
        end
        ns:SetOption("promoteList", list)
        ns:Print("promote list: " .. listText())
    elseif word == "clear" then
        ns:SetOption("promoteList", {})
        ns:Print("promote list: nobody")
    else
        ns:Print("raid assistant for everyone: " .. (ns:GetOption("promoteAll") and "on" or "off") .. "; promote list: " .. listText())
    end
end)

function Promote:Describe()
    return { stats = self.stats, everyoneByUs = everyoneByUs, list = ns:GetOption("promoteList"), all = ns:GetOption("promoteAll") }
end
