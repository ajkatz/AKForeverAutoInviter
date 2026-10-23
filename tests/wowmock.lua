-- A small stand-in for the WoW: Forever client, enough to run AKForeverAutoInviter's scenarios: frames,
-- events, timers, chat lines, a group, a guild roster and a friends list, invites, and the who API behind a
-- key press. Nothing here is the real client; what the real client does with invites, who queries and key
-- presses was measured in game and is written in the addon's comments.
local Mock = {}

local realPrint = print
Mock.realPrint = realPrint

local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
Mock.SECRET = SECRET

local G = _G

local FILES = { "Core.lua", "Roster.lua", "Who.lua", "Inviter.lua", "Promote.lua", "Panel.lua" }

------------------------------------------------------------------------
-- Widgets: what the addon reads back is real; everything else does nothing
------------------------------------------------------------------------
local widgetMethods = {}

function widgetMethods.SetPoint(self, ...) self.__points[#self.__points + 1] = { ... } end
function widgetMethods.ClearAllPoints(self) self.__points = {} end
function widgetMethods.GetPoint(self, index)
    local p = self.__points[index or 1]
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end
function widgetMethods.SetSize(self, w, h) self.__width, self.__height = w, h end
function widgetMethods.SetWidth(self, w) self.__width = w end
function widgetMethods.SetHeight(self, h) self.__height = h end
function widgetMethods.GetWidth(self) return self.__width or 0 end
function widgetMethods.GetHeight(self) return self.__height or 0 end
function widgetMethods.Show(self) self.__shown = true; local s = self.__scripts.OnShow; if s then s(self) end end
function widgetMethods.Hide(self) self.__shown = false; local s = self.__scripts.OnHide; if s then s(self) end end
function widgetMethods.SetShown(self, shown) if shown then self:Show() else self:Hide() end end
function widgetMethods.IsShown(self) return self.__shown end
function widgetMethods.SetScript(self, name, fn) self.__scripts[name] = fn end
function widgetMethods.GetScript(self, name) return self.__scripts[name] end
function widgetMethods.RegisterEvent(self, event) self.__events[event] = true end
function widgetMethods.UnregisterEvent(self, event) self.__events[event] = nil end
function widgetMethods.GetParent(self) return self.__parent end
function widgetMethods.GetName(self) return self.__name end
function widgetMethods.SetText(self, text) self.__text = text end
function widgetMethods.GetText(self) return self.__text end
function widgetMethods.SetChecked(self, on) self.__checked = on and true or false end
function widgetMethods.GetChecked(self) return self.__checked or false end
function widgetMethods.HasFocus(self) return self.__focus or false end
function widgetMethods.SetFocus(self) self.__focus = true end
function widgetMethods.ClearFocus(self)
    if self.__focus then
        self.__focus = false
        local s = self.__scripts.OnEditFocusLost
        if s then s(self) end
    end
end
function widgetMethods.EnableKeyboard(self, on) self.__keyboard = on and true or false end
function widgetMethods.SetPropagateKeyboardInput(self, on) self.__propagate = on and true or false end
function widgetMethods.GetPropagateKeyboardInput(self) return self.__propagate or false end
function widgetMethods.StartMoving() end
function widgetMethods.StopMovingOrSizing() end
-- a click: the template's toggle first, then the script
function widgetMethods.Click(self, button)
    if self.__kind == "CheckButton" then
        self.__checked = not self.__checked
    end
    local script = self.__scripts.OnClick
    if script then
        script(self, button or "LeftButton")
    end
end

local function noop() end

local function newWidget(kind, name, parent)
    local w = { __kind = kind, __name = name, __parent = parent, __points = {}, __scripts = {}, __events = {}, __shown = true }
    setmetatable(w, { __index = function(_, key)
        if string.sub(key, 1, 2) == "__" then
            return nil -- the mock's own state, unset
        end
        return widgetMethods[key] or noop
    end })
    w.CreateFontString = function(self, fsName)
        local fs = newWidget("FontString", fsName, self)
        Mock.fontStrings[#Mock.fontStrings + 1] = fs
        return fs
    end
    w.CreateTexture = function(self, tName)
        return newWidget("Texture", tName, self)
    end
    return w
end

------------------------------------------------------------------------
-- Install: a fresh client with the addon loaded
------------------------------------------------------------------------
local CLASSES = {
    { "Warrior", "WARRIOR" }, { "Paladin", "PALADIN" }, { "Hunter", "HUNTER" }, { "Rogue", "ROGUE" }, { "Priest", "PRIEST" },
    { "Shaman", "SHAMAN" }, { "Mage", "MAGE" }, { "Warlock", "WARLOCK" }, { "Druid", "DRUID" },
}

local state

function Mock.install(options)
    options = options or {}
    for _, name in ipairs(Mock.globalNames or {}) do
        G[name] = nil
    end
    Mock.globalNames = {}
    Mock.now = 1000
    Mock.timers = {}
    Mock.frames = {}
    Mock.fontStrings = {}
    Mock.printed = {}
    Mock.errors = {}
    Mock.forbidden = 0
    Mock.hardware = false
    Mock.invites = {}
    Mock.whoQueries = {}
    Mock.chatFilters = {}
    Mock.chatLines = {} -- system lines that reached the chat (not swallowed)
    Mock.raidConversions = 0
    state = {
        playerName = options.playerName or "Purrdee", surname = options.surname or "Bubson", realm = "TestRealm",
        group = { members = {}, leader = true, raid = false, assistant = false },
        guild = options.guild or {},     -- { { "First-Last", level, "TOKEN" } ... }
        friends = options.friends or {}, -- the same
        guids = options.guids or {},     -- [guid] = "TOKEN"
    }
    Mock.state = state
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        Mock.printed[#Mock.printed + 1] = table.concat(parts, " ")
    end
    G.issecretvalue = function(value) return value == SECRET end
    G.geterrorhandler = function()
        return function(err)
            Mock.errors[#Mock.errors + 1] = tostring(err)
        end
    end
    G.GetTime = function() return Mock.now end
    G.time = function() return 1760000000 + math.floor(Mock.now - 1000) end
    G.date = os.date
    G.InCombatLockdown = function() return false end
    G.UIParent = newWidget("Frame", "UIParent")
    G.UISpecialFrames = {}
    G.BackdropTemplateMixin = {}
    G.RAID_CLASS_COLORS = { MAGE = { colorStr = "ff69ccf0" }, ROGUE = { colorStr = "fffff569" }, DRUID = { colorStr = "ffff7d0a" } }
    G.LOCALIZED_CLASS_NAMES_MALE, G.LOCALIZED_CLASS_NAMES_FEMALE = {}, {}
    for _, class in ipairs(CLASSES) do
        G.LOCALIZED_CLASS_NAMES_MALE[class[2]] = class[1]
        G.LOCALIZED_CLASS_NAMES_FEMALE[class[2]] = class[1]
    end
    G.GetNumClasses = function() return #CLASSES end
    G.GetClassInfo = function(id) local c = CLASSES[id]; if c then return c[1], c[2], id end end
    G.C_AddOns = { GetAddOnMetadata = function() return "@project-version@" end }
    G.CreateFrame = function(kind, name, parent)
        local w = newWidget(kind, name, parent or G.UIParent)
        if name then
            G[name] = w
            Mock.globalNames[#Mock.globalNames + 1] = name
        end
        Mock.frames[#Mock.frames + 1] = w
        return w
    end
    G.C_Timer = {
        After = function(delay, fn) Mock.timers[#Mock.timers + 1] = { at = Mock.now + delay, fn = fn } end,
        NewTicker = function(interval, fn)
            local ticker = { at = Mock.now + interval, fn = fn, interval = interval }
            ticker.Cancel = function() ticker.cancelled = true end
            Mock.timers[#Mock.timers + 1] = ticker
            return ticker
        end,
    }
    -- who you are
    G.UnitName = function(unit) if unit == "player" then return state.playerName, state.surname end end
    G.GetUnitName = function(unit, full)
        if unit == "player" then
            return full and (state.playerName .. " " .. state.surname) or state.playerName
        end
        local member = Mock.unitMember(unit)
        if member == "player" then
            return state.playerName .. " " .. state.surname
        end
        if member then
            return (string.gsub(member, "%-", " "))
        end
        return nil
    end
    -- the group's classes: state.group.classes[name], WARRIOR when not given; you are a shaman
    G.UnitClass = function(unit)
        local member = unit == "player" and "player" or Mock.unitMember(unit)
        if member == "player" then
            return "Shaman", "SHAMAN"
        end
        if member then
            local token = state.group.classes[member] or "WARRIOR"
            return token:sub(1, 1) .. token:sub(2):lower(), token
        end
        return nil
    end
    G.GetRealmName = function() return state.realm end
    -- your group: members are the others (party1..)
    G.IsInGroup = function() return #state.group.members > 0 end
    G.IsInRaid = function() return state.group.raid end
    G.GetNumGroupMembers = function() return #state.group.members > 0 and (#state.group.members + 1) or 0 end
    G.UnitIsGroupLeader = function(unit) return unit == "player" and state.group.leader end
    G.UnitIsGroupAssistant = function(unit) return unit == "player" and state.group.assistant end
    -- ranks: [name] = 1 (assistant); the leader (you) is 2, everyone else 0
    state.group.ranks, state.group.everyone, state.group.classes = {}, false, {}
    Mock.promotions = {}
    G.C_PartyInfo = {
        InviteUnit = function(name) Mock.invites[#Mock.invites + 1] = name end,
        ConvertToRaid = function() Mock.raidConversions = Mock.raidConversions + 1; state.group.raid = true end,
        PromoteToAssistant = function(name)
            Mock.promotions[#Mock.promotions + 1] = name
            state.group.ranks[name] = 1
        end,
        SetEveryoneIsAssistant = function(on) state.group.everyone = on and true or false; return true end,
        IsEveryoneAssistant = function() return state.group.everyone end,
    }
    -- raid1 is you, raid2.. the others
    G.GetRaidRosterInfo = function(index)
        if not state.group.raid then return nil end
        if index == 1 then
            return state.playerName .. "-" .. state.surname, 2
        end
        local name = state.group.members[index - 1]
        if name then
            return name, state.group.everyone and 1 or (state.group.ranks[name] or 0)
        end
    end
    G.GetPlayerInfoByGUID = function(guid)
        local class = state.guids[guid]
        if class then
            return class:sub(1, 1) .. class:sub(2):lower(), class, "Human", "Human", 2, "Someone", ""
        end
        return nil
    end
    -- guild and friends
    G.IsInGuild = function() return #state.guild > 0 end
    G.GetNumGuildMembers = function() return #state.guild, #state.guild, #state.guild end
    G.GetGuildRosterInfo = function(index)
        local m = state.guild[index]
        if m then
            return m[1], "Member", 1, m[2], m[3]:sub(1, 1) .. m[3]:sub(2):lower(), "Westfall", "", "", true, 0, m[3]
        end
    end
    G.C_GuildInfo = { GuildRoster = function() end }
    G.ChatFrame_AddMessageEventFilter = function(event, fn)
        if event == "CHAT_MSG_SYSTEM" then Mock.chatFilters[#Mock.chatFilters + 1] = fn end
    end
    G.WHO_NUM_RESULTS = "%d |4player:players; total"
    G.C_FriendList = {
        GetNumFriends = function() return #state.friends end,
        GetFriendInfoByIndex = function(index)
            local f = state.friends[index]
            if f then
                return { name = f[1], level = f[2], className = f[3]:sub(1, 1) .. f[3]:sub(2):lower(), connected = true }
            end
        end,
        IsFriend = function() return false end,
        ShowFriends = function() end,
        -- /who: a key press or a click, or the client's "blocked" popup; the answer comes with Mock.whoAnswer
        SendWho = function(filter)
            if not Mock.hardware then
                Mock.forbidden = Mock.forbidden + 1
                return
            end
            Mock.whoQueries[#Mock.whoQueries + 1] = filter
        end,
        GetNumWhoResults = function() return 0, 0 end,
        GetWhoInfo = function() return nil end,
    }
    G.SlashCmdList = {}
    -- load the addon in TOC order
    local ns = {}
    for _, file in ipairs(FILES) do
        local chunk, err = loadfile(file)
        if not chunk then
            error("cannot load " .. file .. ": " .. tostring(err))
        end
        chunk("AKForeverAutoInviter", ns)
    end
    G.AKForeverAutoInviterDB = options.db
    Mock.ns = ns
    return ns, state
end

------------------------------------------------------------------------
-- Events, time, the player
------------------------------------------------------------------------
-- who a unit is: "player", a member's name, or nil. party1.. are the others; in a raid, raid1 is you
-- and raid2.. the others, as GetRaidRosterInfo orders them
function Mock.unitMember(unit)
    local party = tonumber(string.match(unit, "^party(%d)$") or "")
    if party then
        return not state.group.raid and state.group.members[party] or nil
    end
    local raid = tonumber(string.match(unit, "^raid(%d+)$") or "")
    if raid and state.group.raid then
        if raid == 1 then
            return "player"
        end
        return state.group.members[raid - 1]
    end
    return nil
end

function Mock.fire(event, ...)
    for _, frame in ipairs(Mock.frames) do
        if frame.__events[event] and frame.__scripts.OnEvent then
            frame.__scripts.OnEvent(frame, event, ...)
        end
    end
end

function Mock.login()
    Mock.fire("ADDON_LOADED", "AKForeverAutoInviter")
    Mock.fire("PLAYER_LOGIN")
    Mock.advance(0.2)
end

function Mock.advance(seconds)
    local target = Mock.now + seconds
    while true do
        local soonest, index
        for i, timer in ipairs(Mock.timers) do
            if not timer.cancelled and timer.at <= target and (not soonest or timer.at < soonest.at) then
                soonest, index = timer, i
            end
        end
        if not soonest then
            break
        end
        Mock.now = soonest.at
        if soonest.interval then
            soonest.at = soonest.at + soonest.interval
        else
            table.remove(Mock.timers, index)
        end
        soonest.fn()
    end
    Mock.now = target
end

function Mock.slash(text)
    Mock.hardware = true
    G.SlashCmdList.AKFOREVERAUTOINVITER(text)
    Mock.hardware = false
end

function Mock.click(widget)
    Mock.hardware = true
    widget:Click()
    Mock.hardware = false
end

-- a key going down: every frame that takes the keyboard hears it
function Mock.key(key)
    Mock.hardware = true
    for _, frame in ipairs(Mock.frames) do
        if frame.__keyboard and frame.__scripts.OnKeyDown then
            frame.__scripts.OnKeyDown(frame, key)
        end
    end
    Mock.hardware = false
end

-- a chat line: CHAT_MSG_* with the sender and the GUID in the client's places (1, 2 ... 12)
function Mock.chat(event, text, sender, guid)
    Mock.fire(event, text, sender, "Common", "", sender, "", 0, 0, "", 0, 1, guid)
end

-- a system line through the chat filters, as the client would send it to the chat window
function Mock.system(text)
    for _, filter in ipairs(Mock.chatFilters) do
        if filter(nil, "CHAT_MSG_SYSTEM", text) then
            return true
        end
    end
    Mock.chatLines[#Mock.chatLines + 1] = text
    return false
end

-- the server's answer to a /who: { { "First-Last", level, "Race", "Class" } ... }
function Mock.whoAnswer(results)
    for _, r in ipairs(results) do
        Mock.system(string.format("|Hplayer:%s|h[%s]|h: Level %d %s %s - Westfall", r[1], r[1], r[2], r[3], r[4]))
    end
    Mock.system(#results .. (#results == 1 and " player" or " players") .. " total")
end

return Mock
