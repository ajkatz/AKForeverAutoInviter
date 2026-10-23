-- Inviter: hears the keyword, weighs the rules, sends the invite.
--
-- A line in one of the chats you listen to (whispers, guild + officer, say + yell, public channels - each
-- a setting) that is one of your keywords - the whole line, or with `anywhere` a word in it, case aside -
-- makes its sender a candidate. The candidate is then weighed, in this order:
--   1. you can invite: ungrouped, or the group's leader (a raid's assistant too), with room left - a full
--      party is made a raid first when you let it (`raid on`);
--   2. guild / friends: when either list is switched on, the sender must be on one that is;
--   3. class: from the guild roster or friends list, else from the whisper's GUID (GetPlayerInfoByGUID);
--   4. level: from the guild roster or friends list, else by a /who on your next key press (Who.lua).
-- What is not known and not asked for is not looked up: with every class allowed and no level range, a
-- stranger is invited the moment the line arrives. Each decision is kept (the window's Recent list, and
-- `/autoinv log`) with its reason; an invite is said in the chat, and so is a refusal to someone who whispered
-- you - the addon cannot answer them itself (an addon may not chat on this realm, measured 2026-10-01).
local _, ns = ...

local Inviter = {}
ns.Inviter = Inviter

local RECENT_MAX = 30
local REPEAT_SECONDS = 10 -- the same person saying the keyword again within this is one request
local RAID_SETTLE = 1     -- a moment for the new raid to form before the invite

local SOURCE_EVENTS = {
    whisper = { "CHAT_MSG_WHISPER" },
    guild = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER" },
    say = { "CHAT_MSG_SAY", "CHAT_MSG_YELL" },
    channel = { "CHAT_MSG_CHANNEL" },
}
Inviter.SOURCES = { "whisper", "guild", "say", "channel" }
Inviter.SOURCE_LABELS = { whisper = "Whispers", guild = "Guild", say = "Say / Yell", channel = "Channels" }

Inviter.stats = { heard = 0, matched = 0, invited = 0, skipped = 0, secretLines = 0, lookedUp = 0 }

local lastHeard = {} -- [name key] = GetTime()

------------------------------------------------------------------------
-- The keyword
------------------------------------------------------------------------
local function clean(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|H.-|h(.-)|h", "%1")
    return string.lower(text)
end

function Inviter:Matches(text)
    if type(text) ~= "string" or ns.IsSecret(text) then
        return false
    end
    local line = clean(text)
    local bare = string.match(line, "^[%s%p]*(.-)[%s%p]*$") or line
    local anywhere = ns:GetOption("anywhere")
    for _, keyword in ipairs(ns:GetOption("keywords")) do
        local word = string.lower(keyword)
        if word ~= "" then
            if bare == word then
                return true
            end
            if anywhere then
                local escaped = string.gsub(word, "%p", "%%%0")
                if string.find(line, "%f[%w]" .. escaped .. "%f[%W]") then
                    return true
                end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- The rules
------------------------------------------------------------------------
function Inviter:ClassAllowed(token)
    return ns:GetOption("classes")[token] ~= false
end

function Inviter:ClassFilterOn()
    for _, class in ipairs(ns.Classes()) do
        if not self:ClassAllowed(class.token) then
            return true
        end
    end
    return false
end

function Inviter:LevelRange()
    local min = tonumber(ns:GetOption("minLevel")) or 1
    local max = tonumber(ns:GetOption("maxLevel"))
    return min, max
end

function Inviter:LevelFilterOn()
    local min, max = self:LevelRange()
    return min > 1 or max ~= nil
end

-- Class caps (the user, 2026-10-23: "no more than 6 of each class or something or no more than 3 druids"): one
-- number for every class and one per class, the class's own winning. The group is counted - you too - and
-- so is anyone invited in the last INVITE_PENDING seconds who has not joined yet, so a burst of asks cannot
-- go past the cap before the first of them has accepted.
local INVITE_PENDING = 120 -- an invite stands about two minutes
Inviter.pending = {}       -- [name key] = { class, at (GetTime()) }: invited, not in the group yet

function Inviter:ClassCap(token)
    local own = tonumber(ns:GetOption("classCaps")[token])
    if own then
        return own
    end
    return tonumber(ns:GetOption("capAll"))
end

function Inviter:CapsOn()
    if tonumber(ns:GetOption("capAll")) then
        return true
    end
    return next(ns:GetOption("classCaps")) ~= nil
end

-- a stranger's class must be known when a class is left off the list, or any class has a cap
function Inviter:NeedsClass()
    return self:ClassFilterOn() or self:CapsOn()
end

-- the group's members by class token, and their name keys
local function groupMembers()
    local members = {}
    local raid = ns.Readable(IsInRaid)
    local units = {}
    if raid and raid[1] then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end -- a raid's units hold you too
    else
        units[1] = "player"
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        local name = ns.Readable(GetUnitName, unit, true)
        local key = name and ns.NameKey(name[1])
        if key then
            local class = ns.Readable(UnitClass, unit)
            members[key] = class and type(class[2]) == "string" and class[2] or false
        end
    end
    return members
end

-- how many of a class are in the group or on their way into it
function Inviter:ClassCount(token, exceptKey)
    local members = groupMembers()
    local count = 0
    for key, class in pairs(members) do
        if class == token and key ~= exceptKey then
            count = count + 1
        end
    end
    local now = GetTime()
    for key, pending in pairs(self.pending) do
        if members[key] ~= nil or now - pending.at > INVITE_PENDING then
            self.pending[key] = nil -- joined (counted above), or the invite has lapsed
        elseif pending.class == token and key ~= exceptKey then
            count = count + 1
        end
    end
    return count
end

-- a full party may become a raid: asked for, or every party you lead is made one anyway
function Inviter:RaidWhenFull()
    return ns:GetOption("autoRaid") or ns:GetOption("raidAlways")
end

local function rangeText(min, max)
    if max then
        return min .. "-" .. max
    end
    return min .. "+"
end

-- the group's members' name keys
local function groupKeys()
    local keys = {}
    local raid = ns.Readable(IsInRaid)
    local prefix, count = "party", 4
    if raid and raid[1] then
        prefix, count = "raid", 40
    end
    for i = 1, count do
        local name = ns.Readable(GetUnitName, prefix .. i, true)
        local key = name and ns.NameKey(name[1])
        if key then
            keys[key] = true
        end
    end
    return keys
end

-- nil when you may invite now; else the reason you may not, and whether a raid conversion would help
local function groupProblem(key)
    if groupKeys()[key] then
        return "already in your group"
    end
    local grouped = ns.Readable(IsInGroup)
    if not (grouped and grouped[1]) then
        return nil
    end
    local leader = ns.Readable(UnitIsGroupLeader, "player")
    local raid = ns.Readable(IsInRaid)
    raid = raid and raid[1]
    local assistant = raid and ns.Readable(UnitIsGroupAssistant, "player")
    if not ((leader and leader[1]) or (assistant and assistant[1])) then
        return "you are not the group's leader"
    end
    local members = ns.Readable(GetNumGroupMembers)
    members = members and members[1] or 0
    if raid then
        if members >= 40 then
            return "your raid is full"
        end
    elseif members >= 5 then
        return "your party is full", true
    end
    return nil
end
Inviter.GroupProblem = groupProblem

------------------------------------------------------------------------
-- Decisions, kept
------------------------------------------------------------------------
function Inviter:Record(record, outcome, reason)
    record.outcome, record.reason = outcome, reason
    local recent = ns.db.recent
    local found = false
    for _, kept in ipairs(recent) do
        if kept == record then
            found = true
        end
    end
    if not found then
        recent[#recent + 1] = record
        while #recent > RECENT_MAX do
            table.remove(recent, 1)
        end
    end
    ns:Log("decision", { name = record.name, source = record.source, outcome = outcome, reason = reason })
    ns:Fire("RECENT_CHANGED")
end

local function describe(record)
    local who = ns.ClassColored(record.class, ns.DisplayName(record.name))
    if record.level then
        who = who .. " (" .. record.level .. ")"
    end
    return who
end

local function skip(record, reason)
    Inviter.stats.skipped = Inviter.stats.skipped + 1
    Inviter:Record(record, "skipped", reason)
    if record.source == "whisper" then
        ns:Print("not inviting " .. describe(record) .. ": " .. reason .. ".")
    end
end

local function invite(record)
    local api = C_PartyInfo and C_PartyInfo.InviteUnit
    if type(api) ~= "function" then
        skip(record, "this client has no C_PartyInfo.InviteUnit")
        return
    end
    local ok, err = pcall(api, record.name)
    if not ok then
        skip(record, "the invite failed (" .. tostring(err) .. ")")
        return
    end
    Inviter.stats.invited = Inviter.stats.invited + 1
    Inviter.pending[record.key] = { class = record.class, at = GetTime() }
    Inviter:Record(record, "invited", Inviter.SOURCE_LABELS[record.source] or record.source)
    ns:Print("invited " .. describe(record) .. " - " .. string.lower(Inviter.SOURCE_LABELS[record.source] or record.source) .. ".")
end

-- the last steps, once class and level are known as far as they can be
local function decide(record)
    if record.class and not Inviter:ClassAllowed(record.class) then
        skip(record, ns.ClassName(record.class) .. " is not on your class list")
        return
    end
    if not record.class and Inviter:NeedsClass() then
        skip(record, "class unknown")
        return
    end
    local cap = record.class and Inviter:ClassCap(record.class)
    if cap then
        local have = Inviter:ClassCount(record.class, record.key)
        if have >= cap then
            skip(record, string.format("%d %ss already (max %d)", have, ns.ClassName(record.class), cap))
            return
        end
    end
    local min, max = Inviter:LevelRange()
    if record.level then
        if record.level < min or (max and record.level > max) then
            skip(record, "level " .. record.level .. ", you invite " .. rangeText(min, max))
            return
        end
    elseif Inviter:LevelFilterOn() then
        skip(record, "level unknown")
        return
    end
    -- the group may have changed while a /who was out
    local problem, raidWouldHelp = groupProblem(record.key)
    if problem and raidWouldHelp and Inviter:RaidWhenFull() then
        local convert = C_PartyInfo and C_PartyInfo.ConvertToRaid
        if type(convert) == "function" and pcall(convert) then
            ns:Log("raid_converted", { name = record.name })
            Inviter:Record(record, "waiting", "making the party a raid")
            C_Timer.After(RAID_SETTLE, function()
                ns.SafeCall(invite, record)
            end)
            return
        end
    end
    if problem then
        skip(record, problem)
        return
    end
    invite(record)
end

function Inviter:Consider(name, guid, source)
    if not ns:IsEnabled() then
        return
    end
    local key = ns.NameKey(name)
    if not key or key == ns.NameKey(ns.playerName) then
        return
    end
    local now = GetTime()
    if lastHeard[key] and now - lastHeard[key] < REPEAT_SECONDS then
        return
    end
    lastHeard[key] = now
    self.stats.matched = self.stats.matched + 1

    local record = { name = name, key = key, source = source, at = time() }
    local problem, raidWouldHelp = groupProblem(key)
    if problem and not (raidWouldHelp and Inviter:RaidWhenFull()) then
        skip(record, problem)
        return
    end

    local known = ns.Roster:Find(name, guid)
    record.guild, record.friend = known.guild, known.friend
    local onlyGuild, onlyFriends = ns:GetOption("onlyGuild"), ns:GetOption("onlyFriends")
    if onlyGuild or onlyFriends then
        if not ((onlyGuild and known.guild) or (onlyFriends and known.friend)) then
            local lists = onlyGuild and onlyFriends and "your guild or friends" or (onlyGuild and "your guild" or "your friends")
            skip(record, "not in " .. lists)
            return
        end
    end

    record.level, record.class = known.level, known.class
    if not record.class and guid and not ns.IsSecret(guid) and type(GetPlayerInfoByGUID) == "function" then
        local info = ns.Readable(GetPlayerInfoByGUID, guid)
        record.class = info and type(info[2]) == "string" and info[2] or nil
    end

    local needLevel = self:LevelFilterOn() and not record.level
    local needClass = self:NeedsClass() and not record.class
    if needLevel or needClass then
        self.stats.lookedUp = self.stats.lookedUp + 1
        self:Record(record, "waiting", "/who on your next key press")
        if source == "whisper" then
            ns:Print(describe(record) .. " asked for an invite - their " .. (needLevel and "level" or "class") .. " comes by /who on your next key press.")
        end
        ns.Who:Want(name, function(info, why)
            if not info then
                skip(record, why == "no key press" and "no key press to /who them in time" or "the /who found nobody by that name")
                return
            end
            record.level = record.level or info.level
            record.class = record.class or info.class
            decide(record)
        end)
        return
    end
    decide(record)
end

------------------------------------------------------------------------
-- Listening
------------------------------------------------------------------------
local function onChat(source)
    return function(_, text, sender, _, _, _, _, _, _, _, _, _, guid)
        if not ns:IsEnabled() or not ns:GetOption("sources")[source] then
            return
        end
        Inviter.stats.heard = Inviter.stats.heard + 1
        if ns.AnySecret(text, sender) then
            Inviter.stats.secretLines = Inviter.stats.secretLines + 1 -- a fight's chat: not readable, not ours
            return
        end
        if Inviter:Matches(text) then
            Inviter:Consider(sender, guid, source)
        end
    end
end

for source, events in pairs(SOURCE_EVENTS) do
    for _, event in ipairs(events) do
        ns:On(event, onChat(source))
    end
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function onOff(word)
    word = string.lower(word or "")
    if word == "on" or word == "yes" or word == "1" then
        return true
    end
    if word == "off" or word == "no" or word == "0" then
        return false
    end
    return nil
end

function Inviter:Summary()
    local parts = {}
    parts[#parts + 1] = ns:IsEnabled() and "|cff40ff40on|r" or "|cffff4040off|r"
    parts[#parts + 1] = "keywords: " .. table.concat(ns:GetOption("keywords"), ", ") .. (ns:GetOption("anywhere") and " (anywhere)" or "")
    local heard = {}
    for _, source in ipairs(self.SOURCES) do
        if ns:GetOption("sources")[source] then
            heard[#heard + 1] = string.lower(self.SOURCE_LABELS[source])
        end
    end
    parts[#parts + 1] = "from: " .. (#heard > 0 and table.concat(heard, ", ") or "nothing")
    local excluded = {}
    for _, class in ipairs(ns.Classes()) do
        if not self:ClassAllowed(class.token) then
            excluded[#excluded + 1] = class.name
        end
    end
    parts[#parts + 1] = #excluded > 0 and ("not: " .. table.concat(excluded, ", ")) or "every class"
    if self:CapsOn() then
        parts[#parts + 1] = "max " .. self:CapsText()
    end
    parts[#parts + 1] = "level " .. rangeText(self:LevelRange())
    if ns:GetOption("onlyGuild") or ns:GetOption("onlyFriends") then
        parts[#parts + 1] = "only " .. ((ns:GetOption("onlyGuild") and ns:GetOption("onlyFriends")) and "guild + friends" or (ns:GetOption("onlyGuild") and "guild" or "friends"))
    end
    return table.concat(parts, " | ")
end

-- "6 of each, 3 Druids"
function Inviter:CapsText()
    local parts = {}
    local all = tonumber(ns:GetOption("capAll"))
    if all then
        parts[#parts + 1] = all .. " of each"
    end
    local caps = ns:GetOption("classCaps")
    for _, class in ipairs(ns.Classes()) do
        if caps[class.token] then
            parts[#parts + 1] = caps[class.token] .. " " .. class.name .. "s"
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function say()
    ns:Print(Inviter:Summary())
end

ns:RegisterCommand("on", "invite on this character", function()
    ns:SetEnabled(true)
    say()
end)
ns:RegisterCommand("off", "stop inviting on this character", function()
    ns:SetEnabled(false)
    say()
end)
ns:RegisterCommand("status", "the rules in one line", say)

ns:RegisterCommand("keywords", "<word, word ...> - the keywords, comma separated", function(rest)
    local list = {}
    for word in string.gmatch(rest, "[^,]+") do
        word = string.match(word, "^%s*(.-)%s*$")
        if word ~= "" then
            list[#list + 1] = string.lower(word)
        end
    end
    if #list == 0 then
        ns:Print("keywords: " .. table.concat(ns:GetOption("keywords"), ", "))
        return
    end
    ns:SetOption("keywords", list)
    say()
end)

ns:RegisterCommand("anywhere", "on|off - the keyword as a word anywhere in the line, not only on its own", function(rest)
    local value = onOff(rest)
    if value == nil then
        value = not ns:GetOption("anywhere")
    end
    ns:SetOption("anywhere", value)
    say()
end)

ns:RegisterCommand("listen", "whisper|guild|say|channel on|off - where the keyword is heard", function(rest)
    local source, word = string.match(rest, "^(%S+)%s*(%S*)")
    source = source and string.lower(source)
    if source == "whispers" then source = "whisper" elseif source == "yell" then source = "say" elseif source == "channels" then source = "channel" end
    if not source or not SOURCE_EVENTS[source] then
        ns:Print("listen to what? whisper, guild, say or channel")
        return
    end
    local sources = ns:GetOption("sources")
    local value = onOff(word)
    if value == nil then
        value = not sources[source]
    end
    sources[source] = value
    ns:SetOption("sources", sources)
    say()
end)

ns:RegisterCommand("class", "<class> on|off, or all - which classes are invited", function(rest)
    local word, value = string.match(rest, "^(%S+)%s*(%S*)")
    local classes = ns:GetOption("classes")
    if word and string.lower(word) == "all" then
        for token in pairs(classes) do
            classes[token] = nil
        end
        ns:SetOption("classes", classes)
        say()
        return
    end
    local token = ns.ClassToken(word)
    if not token then
        ns:Print("which class? " .. (word or ""))
        return
    end
    local on = onOff(value)
    if on == nil then
        on = not Inviter:ClassAllowed(token)
    end
    if on then classes[token] = nil else classes[token] = false end
    ns:SetOption("classes", classes)
    say()
end)

ns:RegisterCommand("max", "<n> | <class> <n|off> | off - no more than n of each class, or of one class", function(rest)
    local first, second = string.match(rest, "^(%S*)%s*(%S*)")
    first = string.lower(first or "")
    local caps = ns:GetOption("classCaps")
    if first == "" then
        ns:Print("class caps: " .. Inviter:CapsText())
        return
    end
    if first == "off" or first == "none" then
        ns:SetOption("capAll", nil)
        for token in pairs(caps) do
            caps[token] = nil
        end
        ns:SetOption("classCaps", caps)
    elseif tonumber(first) then
        ns:SetOption("capAll", math.max(0, math.floor(tonumber(first))))
    else
        local token = ns.ClassToken(first) or ns.ClassToken((string.gsub(first, "s$", ""))) -- "druids" too
        if not token then
            ns:Print("which class? " .. first)
            return
        end
        local n = tonumber(second)
        caps[token] = n and math.max(0, math.floor(n)) or nil -- "off" (or nothing) takes the class's own cap away
        ns:SetOption("classCaps", caps)
    end
    ns:Print("class caps: " .. Inviter:CapsText())
end)

ns:RegisterCommand("level", "<min> [max] - the levels invited ('level 1' for any)", function(rest)
    local min, max = string.match(rest, "^(%d+)%s*%-?%s*(%d*)")
    min, max = tonumber(min), tonumber(max)
    if not min then
        ns:Print("level " .. rangeText(Inviter:LevelRange()))
        return
    end
    if max and max < min then
        min, max = max, min
    end
    ns:SetOption("minLevel", math.max(1, min))
    ns:SetOption("maxLevel", max)
    say()
end)

ns:RegisterCommand("only", "guild|friends|both|none - invite only your guild and/or friends", function(rest)
    local word = string.lower(rest or "")
    local guild, friends
    if word == "guild" then guild, friends = true, false
    elseif word == "friends" or word == "friend" then guild, friends = false, true
    elseif word == "both" then guild, friends = true, true
    elseif word == "none" or word == "off" or word == "anyone" then guild, friends = false, false
    else
        ns:Print("only guild, friends, both or none")
        return
    end
    ns:SetOption("onlyGuild", guild)
    ns:SetOption("onlyFriends", friends)
    say()
end)

ns:RegisterCommand("raid", "full|always|off - make a full party (or any party you lead) a raid", function(rest)
    local word = string.lower(rest or "")
    if word == "always" then
        ns:SetOption("autoRaid", true)
        ns:SetOption("raidAlways", true)
    elseif word == "full" or word == "on" then
        ns:SetOption("autoRaid", true)
        ns:SetOption("raidAlways", false)
    elseif word == "off" then
        ns:SetOption("autoRaid", false)
        ns:SetOption("raidAlways", false)
    end
    local mode = ns:GetOption("raidAlways") and "any party you lead" or (ns:GetOption("autoRaid") and "a full party" or "off")
    ns:Print("party -> raid: " .. mode)
end)

ns:RegisterCommand("log", "the last decisions", function()
    local recent = ns.db.recent
    if #recent == 0 then
        ns:Print("nobody has asked yet.")
        return
    end
    ns:Print("the last " .. math.min(#recent, 10) .. ":")
    for index = math.max(1, #recent - 9), #recent do
        local record = recent[index]
        print("   " .. date("%H:%M", record.at) .. " " .. describe(record) .. " - " .. tostring(record.outcome) .. (record.reason and (": " .. record.reason) or ""))
    end
end)

ns:RegisterCommand("diag", "write a report into the saved file (and say the short of it)", function()
    local errors = {}
    for err, count in pairs(ns.errors) do
        errors[#errors + 1] = { error = err, count = count }
    end
    ns.db.diag = {
        version = ns.version, at = time(), character = ns.characterKey, savedState = ns.savedStateSource,
        summary = Inviter:Summary(), stats = Inviter.stats, who = ns.Who:Describe(), roster = ns.Roster.stats, promote = ns.Promote:Describe(),
        unknownEvents = ns.unknownEvents, blocked = ns.blocked, errors = errors, log = ns.sessionLog,
    }
    local who = ns.Who.stats
    ns:Print(string.format("heard %d, matched %d, invited %d, skipped %d; /who asked %d, found %d, missing %d, expired %d; guild %d, friends %d; %d errors, %d blocked - written to the saved file at logout or /reload.",
        Inviter.stats.heard, Inviter.stats.matched, Inviter.stats.invited, Inviter.stats.skipped, who.asked, who.found, who.missing, who.expired,
        ns.Roster.stats.guildSize, ns.Roster.stats.friendCount, #errors, #ns.blocked))
end)
