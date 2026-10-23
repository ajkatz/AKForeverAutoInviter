-- Roster: who is in your guild and on your friends list, with the level and class the client keeps for
-- each - so a guild member's or a friend's level needs no /who.
--
-- Both lists are read from the client's own tables (GetGuildRosterInfo, C_FriendList.GetFriendInfoByIndex)
-- whenever the client says they changed, and asked for again now and then (C_GuildInfo.GuildRoster,
-- C_FriendList.ShowFriends: no key press needed). Names are compared by ns.NameKey, as the two lists may
-- spell them "First-Last" or "First Last".
local _, ns = ...

local Roster = {}
ns.Roster = Roster

local ASK_EVERY = 60

Roster.guild = {}   -- [name key] = { level, class }
Roster.friends = {} -- [name key] = { level, class }
Roster.stats = { guildReads = 0, friendReads = 0, guildSize = 0, friendCount = 0 }

local function readGuild()
    local guild = {}
    local inGuild = ns.Readable(IsInGuild)
    if inGuild and inGuild[1] then
        local counts = ns.Readable(GetNumGuildMembers)
        local total = counts and counts[1]
        for index = 1, (type(total) == "number" and total or 0) do
            local info = ns.Readable(GetGuildRosterInfo, index)
            if info then
                local key = ns.NameKey(info[1])
                if key then
                    local class = type(info[11]) == "string" and info[11] or ns.ClassToken(info[5])
                    guild[key] = { level = type(info[4]) == "number" and info[4] or nil, class = class }
                end
            end
        end
    end
    Roster.guild = guild
    Roster.stats.guildReads = Roster.stats.guildReads + 1
    local size = 0
    for _ in pairs(guild) do
        size = size + 1
    end
    Roster.stats.guildSize = size
end

local function readFriends()
    local friends = {}
    local api = C_FriendList
    if type(api) == "table" then
        local count = ns.Readable(api.GetNumFriends)
        count = count and count[1]
        for index = 1, (type(count) == "number" and count or 0) do
            local info = ns.Readable(api.GetFriendInfoByIndex, index)
            info = info and info[1]
            if type(info) == "table" and not ns.AnySecret(info.name, info.level, info.className) then
                local key = ns.NameKey(info.name)
                if key then
                    -- a friend offline is known with the level they had when last seen: good enough to
                    -- decide, since they whisper you only once online (and the list is then refreshed)
                    friends[key] = { level = type(info.level) == "number" and info.level > 0 and info.level or nil,
                        class = ns.ClassToken(info.className) }
                end
            end
        end
    end
    Roster.friends = friends
    Roster.stats.friendReads = Roster.stats.friendReads + 1
    local size = 0
    for _ in pairs(friends) do
        size = size + 1
    end
    Roster.stats.friendCount = size
end

function Roster:Refresh()
    readGuild()
    readFriends()
end

-- ask the server for fresh lists; the answers come as GUILD_ROSTER_UPDATE / FRIENDLIST_UPDATE
function Roster:Ask()
    if C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function" then
        pcall(C_GuildInfo.GuildRoster)
    elseif type(GuildRoster) == "function" then
        pcall(GuildRoster)
    end
    if C_FriendList and type(C_FriendList.ShowFriends) == "function" then
        pcall(C_FriendList.ShowFriends)
    end
end

-- what the lists know of a name: { guild, friend, level, class }
function Roster:Find(name, guid)
    local key = ns.NameKey(name)
    local g, f = key and self.guild[key], key and self.friends[key]
    local found = { guild = g ~= nil and g ~= false, friend = f ~= nil and f ~= false }
    local entry = g or f
    if entry then
        found.level, found.class = entry.level, entry.class
    end
    -- a friend by GUID, should the list spell the name in a way NameKey does not see through
    if not found.friend and guid and C_FriendList and type(C_FriendList.IsFriend) == "function" then
        local answer = ns.Readable(C_FriendList.IsFriend, guid)
        found.friend = answer and answer[1] and true or false
    end
    return found
end

ns:On("GUILD_ROSTER_UPDATE", readGuild)
ns:On("PLAYER_GUILD_UPDATE", readGuild)
ns:On("FRIENDLIST_UPDATE", readFriends)

ns:Listen("LOGIN", function()
    Roster:Refresh()
    Roster:Ask()
    C_Timer.NewTicker(ASK_EVERY, function()
        ns.SafeCall(Roster.Ask, Roster)
    end)
end)
