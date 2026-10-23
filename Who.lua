-- Who: a stranger's level and class, by a /who for their name - asked on your own next key press.
--
-- A whisper carries the sender's GUID, and the GUID gives the class (GetPlayerInfoByGUID) but no level; the
-- guild roster and the friends list know their own members' levels (Roster.lua). For anyone else the level
-- comes from the server only: one who query by name ('n-"Name"'). C_FriendList.SendWho is restricted to a key
-- press or a click on this client, so the queries RIDE ON YOUR OWN KEY PRESSES, the way AKForeverLFGRadar
-- asks them (proven in game 2026-10-16): a frame hears every key and passes every key on, and a fresh press -
-- this client sends no OnKeyUp, so a key that has not gone down for longer than a held key's repeat is taken
-- as pressed afresh - sends the next query, GAP_SECONDS after the last at the soonest. Nobody is invited
-- while you are away from the keyboard: a name waits WAIT_SECONDS for a key press, then is let go.
--
-- THE ANSWER COMES THROUGH THE CHAT. Results sent to the UI (SetWhoToUi) fire WHO_LIST_UPDATE, which on this
-- flavour opens the group finder's Who tab (seen in AKForeverLFGRadar, round 7). So the results are left on
-- the chat path: each comes as a system line ("[Name]: Level 20 Night Elf Druid <Guild> - Westfall") that a
-- chat filter of ours reads and swallows while a query of ours is out; the count line closes the answer.
local _, ns = ...

local Who = {}
ns.Who = Who

local GAP_SECONDS = 5
local FRESH_AFTER = 1.5
local PENDING_SECONDS = 10
local WAIT_SECONDS = 120

Who.queue = {}     -- { name, key, at (GetTime()), callbacks }, oldest first
Who.pending = nil  -- the query on its way: { entry, at, how, hit }
Who.stats = { asked = 0, answered = 0, found = 0, missing = 0, refused = 0, expired = 0, keyDowns = 0, repeats = 0,
    swallowed = 0, unanswered = 0, byChat = 0, byEvent = 0, filterInstalled = false, armProblem = nil }

local lastAsk = nil
local keys, armed = nil, false
local lastDown = {}

------------------------------------------------------------------------
-- Wanting a name
------------------------------------------------------------------------
-- callback(info) with info = { level, class } once the server answered, or nil (not found, or no key press
-- in time: the second argument says which)
function Who:Want(name, callback)
    local key = ns.NameKey(name)
    if not key then
        callback(nil, "no name")
        return
    end
    for _, entry in ipairs(self.queue) do
        if entry.key == key then
            entry.callbacks[#entry.callbacks + 1] = callback
            return
        end
    end
    self.queue[#self.queue + 1] = { name = name, key = key, at = GetTime(), callbacks = { callback } }
    ns:Log("who_wanted", { name = name })
    ns:Fire("WHO_CHANGED")
end

function Who:Waiting()
    return #self.queue
end

local function finish(entry, info, why)
    for index, queued in ipairs(Who.queue) do
        if queued == entry then
            table.remove(Who.queue, index)
            break
        end
    end
    for _, callback in ipairs(entry.callbacks) do
        ns.SafeCall(callback, info, why)
    end
    ns:Fire("WHO_CHANGED")
end

-- the name to ask now, with the gaps honoured - or nil
function Who:Due()
    local now = GetTime()
    if self.pending then
        return nil
    end
    if lastAsk and now - lastAsk < GAP_SECONDS then
        return nil
    end
    return self.queue[1]
end

------------------------------------------------------------------------
-- Asking - from a key press only
------------------------------------------------------------------------
function Who:Ask(how)
    local entry = self:Due()
    if not entry then
        return false
    end
    local api = C_FriendList
    if type(api) ~= "table" or type(api.SendWho) ~= "function" then
        return false
    end
    -- not SetWhoToUi: results sent to the UI open the finder's Who tab on this flavour; the chat path it is
    local ok, err = pcall(api.SendWho, 'n-"' .. ns.DisplayName(entry.name) .. '"')
    if not ok then
        self.stats.refused = self.stats.refused + 1
        ns:Log("who_refused", { name = entry.name, how = how, error = tostring(err) })
        return false
    end
    self.pending = { entry = entry, at = GetTime(), how = how }
    lastAsk = GetTime()
    self.stats.asked = self.stats.asked + 1
    ns:Log("who_asked", { name = entry.name, how = how })
    return true
end

local function settle(info, by)
    local pending = Who.pending
    Who.pending = nil
    Who.stats.answered = Who.stats.answered + 1
    Who.stats[by] = Who.stats[by] + 1
    if info then
        Who.stats.found = Who.stats.found + 1
    else
        Who.stats.missing = Who.stats.missing + 1
    end
    ns:Log("who_answered", { name = pending.entry.name, level = info and info.level, class = info and info.class, by = by })
    finish(pending.entry, info, info and nil or "not found")
end

-- "Level 20 Night Elf Druid" -> 20, "DRUID": the class is the longest tail of the words the client knows
local function readLevelAndClass(text)
    local level, rest = string.match(text, "Level (%d+) ([^<|]-)%s*[<%-]")
    if not level then
        level, rest = string.match(text, "Level (%d+) ([^<|]-)%s*$")
    end
    if not level then
        return nil
    end
    local class
    local words = {}
    for word in string.gmatch(rest or "", "%S+") do
        words[#words + 1] = word
    end
    for first = 1, #words do
        class = ns.ClassToken(table.concat(words, " ", first))
        if class then
            break
        end
    end
    return tonumber(level), class
end
Who.ReadLevelAndClass = readLevelAndClass

-- the Who tab open, say: the client sends the results to the UI after all, and says so
ns:On("WHO_LIST_UPDATE", function()
    local pending = Who.pending
    if not pending then
        return
    end
    local api = C_FriendList
    local counts = ns.Readable(api.GetNumWhoResults)
    local shown = counts and counts[1]
    for index = 1, (type(shown) == "number" and shown or 0) do
        local info = ns.Readable(api.GetWhoInfo, index)
        info = info and info[1]
        if type(info) == "table" and not ns.AnySecret(info.fullName, info.level, info.filename) and ns.NameKey(info.fullName) == pending.entry.key then
            settle({ level = info.level, class = info.filename or ns.ClassToken(info.classStr) }, "byEvent")
            return
        end
    end
    settle(nil, "byEvent")
end)

local function isCountLine(text)
    if string.find(text, "^%d+ [%a%s]+ total$") then
        return true
    end
    if type(WHO_NUM_RESULTS) == "string" then
        local pattern = string.gsub(WHO_NUM_RESULTS, "%%d", "%%d+"):gsub("|4[^;]*;", "%%a+")
        return string.find(text, pattern) ~= nil
    end
    return false
end

-- while a query of ours is out, its lines are ours: read, and swallowed
local function onSystemMessage(_, _, text)
    local pending = Who.pending
    if not pending or ns.IsSecret(text) or type(text) ~= "string" or GetTime() - pending.at > PENDING_SECONDS then
        return false
    end
    local name = string.match(text, "|Hplayer:([^|:]+)")
    if name and string.find(text, "Level %d+") then
        Who.stats.swallowed = Who.stats.swallowed + 1
        if ns.NameKey(name) == pending.entry.key then
            local level, class = readLevelAndClass(text)
            pending.hit = { level = level, class = class }
        end
        return true
    end
    if isCountLine(text) then
        Who.stats.swallowed = Who.stats.swallowed + 1
        settle(pending.hit, "byChat")
        return true
    end
    return false
end
Who.OnSystemMessage = onSystemMessage

-- a query nobody answered in its time, and names that waited too long for a key press
local function expire()
    local now = GetTime()
    local pending = Who.pending
    if pending and now - pending.at > PENDING_SECONDS then
        Who.stats.unanswered = Who.stats.unanswered + 1
        settle(pending.hit, "byChat")
    end
    for index = #Who.queue, 1, -1 do
        local entry = Who.queue[index]
        if now - entry.at > WAIT_SECONDS and not (Who.pending and Who.pending.entry == entry) then
            Who.stats.expired = Who.stats.expired + 1
            ns:Log("who_expired", { name = entry.name })
            finish(entry, nil, "no key press")
        end
    end
end

------------------------------------------------------------------------
-- The key rider: every key heard and passed on; a fresh press sends the next query
------------------------------------------------------------------------
local function arm()
    if armed or not keys then
        return
    end
    if InCombatLockdown() then
        return -- refused in a fight: PLAYER_REGEN_ENABLED tries again
    end
    local ok = pcall(keys.SetPropagateKeyboardInput, keys, true)
    local passesOn = ok and type(keys.GetPropagateKeyboardInput) == "function" and keys:GetPropagateKeyboardInput() == true
    if not passesOn then
        Who.stats.armProblem = ok and "the client did not confirm that keys are passed on" or "SetPropagateKeyboardInput failed"
        return
    end
    keys:EnableKeyboard(true)
    armed, Who.stats.armProblem = true, nil
end

local function onKeyDown(_, key)
    if ns.IsSecret(key) or type(key) ~= "string" then
        key = "?"
    end
    local now = GetTime()
    Who.stats.keyDowns = Who.stats.keyDowns + 1
    local last = lastDown[key]
    lastDown[key] = now
    if last and now - last < FRESH_AFTER then
        Who.stats.repeats = Who.stats.repeats + 1 -- held, or pressed again at once: no press to the client
        return
    end
    if Who:Due() then
        Who:Ask("key")
    end
end

ns:Listen("LOGIN", function()
    if type(ChatFrame_AddMessageEventFilter) == "function" then
        local ok = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", function(...)
            local swallowed = false
            ns.SafeCall(function(...)
                swallowed = onSystemMessage(...)
            end, ...)
            return swallowed
        end)
        Who.stats.filterInstalled = ok and true or false
    end
    C_Timer.NewTicker(2, function()
        ns.SafeCall(expire)
    end)
    keys = CreateFrame("Frame", "AKForeverAutoInviterKeys", UIParent)
    keys:SetScript("OnKeyDown", function(...)
        ns.SafeCall(onKeyDown, ...)
    end)
    Who.keys = keys
    arm()
end)

ns:On("PLAYER_REGEN_ENABLED", arm)

function Who:Describe()
    local names = {}
    for _, entry in ipairs(self.queue) do
        names[#names + 1] = entry.name
    end
    return { stats = self.stats, waiting = names, pending = self.pending and self.pending.entry.name, armed = armed }
end
