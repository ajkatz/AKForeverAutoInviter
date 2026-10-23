-- AKForeverAutoInviter core: namespace, safe calls, event dispatch, message bus, saved variables, the
-- character's profile, names and slash commands.
--
-- The mission of this addon family, built for the WoW: Forever game mode: minimalistic UI additions that
-- bring out the utility Blizzard's UI does not give - minimal in nature, no Lua errors, always smooth. So:
-- every entry point goes through ns.SafeCall, and every error is kept for the report.
--
-- What this addon is for (the user, 2026-10-22): "invite by keyword; restrict by class; restrict by level;
-- restrict by in-guild/friends". Someone says one of your keywords - in a whisper, guild chat, say/yell or a
-- public channel, each a setting - and is invited, if their class is one you allow, their level inside your
-- range, and (when you ask for it) they are in your guild or on your friends list. The invite itself needs
-- no key press on this client (C_PartyInfo.InviteUnit from a timer was answered by the server, measured
-- 2026-10-01); a stranger's level does: see Who.lua.
local ADDON_NAME, ns = ...

ns.name = ADDON_NAME

local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (getMetadata and getMetadata(ADDON_NAME, "Version")) or "dev"
if string.find(ns.version, "@", 1, true) then
    ns.version = "dev" -- a working copy: the packager has not replaced the @project-version@ token
end
ns.version = (string.gsub(ns.version, "^v", ""))

local PRINT_PREFIX = "|cff5ec8e8AutoInviter|r: "

function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    print(PRINT_PREFIX .. table.concat(parts, " "))
end

------------------------------------------------------------------------
-- Secret values. WoW: Forever runs the Midnight-era API, where some values handed to addons may be held
-- but not inspected - a chat line in a fight among them.
------------------------------------------------------------------------
local issecret = type(issecretvalue) == "function" and issecretvalue or nil

function ns.IsSecret(value)
    if issecret then
        return issecret(value) and true or false
    end
    return false
end

function ns.AnySecret(...)
    for i = 1, select("#", ...) do
        if ns.IsSecret((select(i, ...))) then
            return true
        end
    end
    return false
end

-- Call a client function; its results as a list, or nil when it errors or answers with anything secret.
function ns.Readable(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        return nil
    end
    for i = 2, #results do
        if ns.IsSecret(results[i]) then
            return nil
        end
    end
    table.remove(results, 1)
    return results
end

------------------------------------------------------------------------
-- Safe calls: every distinct error is kept for the report.
------------------------------------------------------------------------
ns.errors = {}

local function onError(err)
    err = tostring(err)
    local seen = ns.errors[err]
    ns.errors[err] = (seen or 0) + 1
    if not seen then
        local handler = geterrorhandler and geterrorhandler()
        if handler then
            handler(err)
        end
    end
    return err
end

function ns.SafeCall(fn, ...)
    return xpcall(fn, onError, ...)
end

------------------------------------------------------------------------
-- Session log (ring buffer)
------------------------------------------------------------------------
local LOG_MAX = 160
ns.sessionLog = {}

function ns:Log(kind, data)
    local log = ns.sessionLog
    log[#log + 1] = {
        t = math.floor(GetTime() * 1000) / 1000,
        k = kind,
        d = data,
    }
    if #log > LOG_MAX then
        table.remove(log, 1)
    end
end

------------------------------------------------------------------------
-- Internal message bus
------------------------------------------------------------------------
local listeners = {}

function ns:Listen(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns:Fire(message, ...)
    local list = listeners[message]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], ...)
    end
end

------------------------------------------------------------------------
-- Game events: one frame, handlers per event, every handler in a SafeCall
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}
ns.unknownEvents = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], event, ...)
    end
end)

function ns:On(event, fn)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
            ns.unknownEvents[event] = true
        end
    end
    table.insert(eventHandlers[event], fn)
end

------------------------------------------------------------------------
-- Blocked actions: the client's word on an action it refused an addon - this one or another - with the
-- function's name, since "Interface action failed because of an AddOn" names nothing on screen. Kept for
-- the report; ours said once in the chat.
------------------------------------------------------------------------
ns.blocked = {}
local saidBlocked = {}
for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    ns:On(event, function(_, addon, func) -- handlers get the event first
        addon = (not ns.IsSecret(addon) and type(addon) == "string") and addon or "?"
        func = (not ns.IsSecret(func) and type(func) == "string") and func or "?"
        local record = { event = event, addon = addon, func = func, at = math.floor(GetTime()) }
        ns.blocked[#ns.blocked + 1] = record
        if #ns.blocked > 40 then
            table.remove(ns.blocked, 1)
        end
        ns:Log("blocked", record)
        if addon == ADDON_NAME and not saidBlocked[func] then
            saidBlocked[func] = true
            ns:Print("the client blocked " .. func .. "() for this addon (" .. event .. ") - '/autoinv diag' keeps what led up to it.")
        end
    end)
end

------------------------------------------------------------------------
-- Names. On Forever a character has a first and a last name, and the client spells it "First Last" or
-- "First-Last" depending on the path (GetUnitName(unit, true) and addon messages: a space; the hyphen form
-- is taken by the server as the same name, measured 2026-10-01), possibly with a realm after another
-- hyphen. Two names are the same person when their first two words match, case aside.
------------------------------------------------------------------------
function ns.NameKey(name)
    if type(name) ~= "string" or ns.IsSecret(name) then
        return nil
    end
    local words = {}
    for word in string.gmatch(string.lower(name), "[^%s%-]+") do
        words[#words + 1] = word
        if #words == 2 then
            break
        end
    end
    if #words == 0 then
        return nil
    end
    return table.concat(words, " ")
end

-- "Purrdee-Bubson" -> "Purrdee Bubson", for the chat
function ns.DisplayName(name)
    if type(name) ~= "string" then
        return "?"
    end
    local first, last = string.match(name, "^([^%s%-]+)[%s%-]+([^%s%-]+)")
    if first then
        return first .. " " .. last
    end
    return name
end

------------------------------------------------------------------------
-- Classes: the tokens the client knows (GetClassInfo), with their names as the client words them, so a
-- /who line's "Night Elf Druid" can be read back to DRUID.
------------------------------------------------------------------------
local FALLBACK_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

function ns.Classes()
    if ns.classList then
        return ns.classList
    end
    local list = {}
    local count = ns.Readable(GetNumClasses)
    count = count and count[1]
    if type(count) == "number" and type(GetClassInfo) == "function" then
        for id = 1, count do
            local info = ns.Readable(GetClassInfo, id)
            if info and type(info[1]) == "string" and type(info[2]) == "string" then
                list[#list + 1] = { token = info[2], name = info[1] }
            end
        end
    end
    if #list == 0 then
        for _, token in ipairs(FALLBACK_CLASSES) do
            local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
            list[#list + 1] = { token = token, name = name or (token:sub(1, 1) .. token:sub(2):lower()) }
        end
    end
    ns.classList = list
    return list
end

-- a class as the client words it (either gender) -> its token
function ns.ClassToken(word)
    if type(word) ~= "string" then
        return nil
    end
    local wanted = string.lower(word)
    for _, class in ipairs(ns.Classes()) do
        if string.lower(class.name) == wanted or string.lower(class.token) == wanted then
            return class.token
        end
        for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
            local name = names[class.token]
            if type(name) == "string" and string.lower(name) == wanted then
                return class.token
            end
        end
    end
    return nil
end

function ns.ClassName(token)
    for _, class in ipairs(ns.Classes()) do
        if class.token == token then
            return class.name
        end
    end
    return token or "?"
end

function ns.ClassColored(token, text)
    local color = RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. text .. "|r"
    end
    return text
end

------------------------------------------------------------------------
-- Saved variables: one account-wide table - the rules, alike for every character - and a profile per
-- character (whether this character invites, the window's place), keyed "First Last - Realm" as the client
-- names you since build 70170.
------------------------------------------------------------------------
local OPTION_DEFAULTS = {
    keywords = { "inv", "invite" }, -- said on their own (or, with `anywhere`, as a word in a longer line)
    anywhere = false,
    sources = { whisper = true, guild = false, say = false, channel = false },
    classes = {},                   -- [token] = false: that class is not invited; anything else is
    minLevel = 1,
    maxLevel = nil,                 -- nil: no upper bound
    onlyGuild = false,              -- either list that is on lets a person through
    onlyFriends = false,
    autoRaid = false,               -- a full party becomes a raid before the sixth invite
    raidAlways = false,             -- any party you lead becomes a raid (Promote.lua)
    promoteAll = false,             -- everyone in your raid an assistant
    promoteList = {},               -- ... or these names
}
ns.OPTION_DEFAULTS = OPTION_DEFAULTS

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = copy(v)
    end
    return out
end

local function initDB()
    if type(AKForeverAutoInviterDB) ~= "table" then
        AKForeverAutoInviterDB = {}
        ns.savedStateSource = "none (first run, or the client did not load it)"
    else
        ns.savedStateSource = "client"
    end
    local db = AKForeverAutoInviterDB
    db.schema = db.schema or 1
    db.loads = (db.loads or 0) + 1
    db.options = db.options or {}
    db.chars = db.chars or {}
    db.recent = db.recent or {} -- the last decisions, newest last (Inviter.lua)
    ns.db = db
    ns.cdb = ns.cdb or {} -- a stand-in until the profile is bound at PLAYER_LOGIN
end

-- the name the client puts on the wire, plus the realm
function ns.PlayerKey()
    local name = ns.Readable(GetUnitName, "player", true)
    name = name and name[1]
    if type(name) ~= "string" or name == "" or name == "Unknown" then
        local short = ns.Readable(UnitName, "player")
        name = short and short[1]
    end
    local realm = ns.Readable(GetRealmName)
    realm = realm and realm[1]
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name .. " - " .. (type(realm) == "string" and realm or "?"), name
end

local function bindProfile()
    local key, name = ns.PlayerKey()
    ns.characterKey, ns.playerName = key, name
    if not key then
        ns.cdb = ns.cdb or {}
        return
    end
    ns.db.chars[key] = ns.db.chars[key] or {}
    local carried = ns.cdb
    ns.cdb = ns.db.chars[key]
    for k, v in pairs(carried or {}) do -- anything written before the name was known
        if ns.cdb[k] == nil then
            ns.cdb[k] = v
        end
    end
end

-- an option's value; a table default is copied into the saved options on first read, so it can be changed
function ns:GetOption(key)
    local options = ns.db and ns.db.options
    local value = options and options[key]
    if value == nil then
        value = OPTION_DEFAULTS[key]
        if type(value) == "table" and options then
            value = copy(value)
            options[key] = value
        end
    end
    return value
end

function ns:SetOption(key, value)
    ns.db.options[key] = value
    ns:Fire("OPTION_CHANGED", key, value)
end

function ns:IsEnabled()
    return ns.cdb.enabled == true
end

function ns:SetEnabled(on)
    ns.cdb.enabled = on and true or false
    ns:Fire("OPTION_CHANGED", "enabled", ns.cdb.enabled)
end

------------------------------------------------------------------------
-- Slash commands: modules register their own sub-commands; nothing at all opens the window
------------------------------------------------------------------------
local commands, commandOrder = {}, {}

function ns:RegisterCommand(name, help, fn)
    commands[name] = { help = help, fn = fn }
    commandOrder[#commandOrder + 1] = name
end

ns.defaultCommand = nil -- set by Panel.lua: "/autoinv" opens the window

function ns:PrintHelp()
    ns:Print("v" .. ns.version .. " - |cffffd100/autoinv|r opens the window. Commands:")
    for _, commandName in ipairs(commandOrder) do
        print("   |cffffd100/autoinv " .. commandName .. "|r - " .. commands[commandName].help)
    end
end

SLASH_AKFOREVERAUTOINVITER1 = "/akforeverautoinviter"
SLASH_AKFOREVERAUTOINVITER2 = "/autoinv"
SlashCmdList["AKFOREVERAUTOINVITER"] = function(message)
    local name, rest = string.match(message or "", "^%s*(%S*)%s*(.-)%s*$")
    name = string.lower(name or "")
    local command = commands[name]
    if command then
        ns.SafeCall(command.fn, rest or "")
        return
    end
    if name == "" and ns.defaultCommand then
        ns.SafeCall(ns.defaultCommand)
        return
    end
    ns:PrintHelp()
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
ns:On("ADDON_LOADED", function(_, addonName)
    if addonName ~= ADDON_NAME then
        return
    end
    initDB()
end)

ns:On("PLAYER_LOGIN", function()
    if not ns.db then
        initDB()
    end
    bindProfile()
    ns:Log("login", { version = ns.version, loads = ns.db.loads, savedState = ns.savedStateSource, character = ns.characterKey })
    ns:Fire("LOGIN")
end)
