-- Scenario tests for AKForeverAutoInviter: lua tests/run.lua  (from the addon's folder)
package.path = "tests/?.lua;" .. package.path
local Mock = require("wowmock")

local passed, failures = 0, {}

local function check(condition, message)
    if not condition then
        error(message or "check failed", 2)
    end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message and (message .. ": ") or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function scenario(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok and #Mock.errors > 0 then
        ok, err = false, "the addon raised an error: " .. tostring(Mock.errors[1])
    end
    if ok and Mock.forbidden > 0 then
        ok, err = false, "the addon did " .. Mock.forbidden .. " forbidden thing(s): a restricted call outside a key press - the client's \"blocked\" popup"
    end
    if ok then
        passed = passed + 1
        Mock.realPrint("  ok    " .. name)
    else
        failures[#failures + 1] = name
        Mock.realPrint("  FAIL  " .. name .. "\n          " .. tostring(err):gsub("\n", "\n          "))
    end
end

-- a client logged in, the addon switched on for this character
local function start(options)
    local ns, state = Mock.install(options)
    Mock.login()
    if not (options and options.off) then
        Mock.slash("on")
    end
    return ns, state
end

local function printed(text)
    for _, line in ipairs(Mock.printed) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

local function lastDecision(ns)
    return ns.db.recent[#ns.db.recent]
end

local function whisper(text, sender, guid)
    Mock.chat("CHAT_MSG_WHISPER", text, sender, guid)
end

local function savedSafe(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == "table" then
        if depth > 12 then
            return false
        end
        for k, v in pairs(value) do
            if type(k) ~= "string" and type(k) ~= "number" then
                return false
            end
            if not savedSafe(v, depth + 1) then
                return false
            end
        end
        return true
    end
    return kind == "string" or kind == "number" or kind == "boolean"
end

Mock.realPrint("AKForeverAutoInviter scenarios")

scenario("nothing is invited until the character is switched on", function()
    local ns = start({ off = true })
    whisper("inv", "Grim-Tusk", "Player-1")
    equal(#Mock.invites, 0, "invites while off")
    Mock.slash("on")
    whisper("inv", "Grim-Tusk", "Player-1")
    equal(#Mock.invites, 1, "invites once on")
    equal(Mock.invites[1], "Grim-Tusk", "the name as the client gave it")
    check(ns:IsEnabled(), "on")
end)

scenario("a stranger whispering the keyword is invited at once when nothing needs looking up", function()
    local ns = start()
    whisper("inv", "Grim-Tusk", "Player-1")
    equal(#Mock.invites, 1)
    equal(lastDecision(ns).outcome, "invited")
    check(printed("invited Grim Tusk"), "said in the chat")
    equal(#Mock.whoQueries, 0, "no /who")
end)

scenario("the keyword must be the whole line, case and punctuation aside, unless 'anywhere' is on", function()
    start()
    whisper("INV!", "A-One")
    whisper("  Invite  ", "B-Two")
    whisper("can you inv me", "C-Three")
    whisper("invent", "D-Four")
    equal(#Mock.invites, 2, "the two whole-line keywords")
    Mock.slash("anywhere on")
    whisper("can you inv me", "C-Three")
    whisper("invent something", "E-Five")
    equal(#Mock.invites, 3, "a word in a line, not a part of a word")
    equal(Mock.invites[3], "C-Three")
end)

scenario("keywords can be replaced", function()
    local ns = start()
    Mock.slash("keywords 123, LFG dm")
    equal(table.concat(ns:GetOption("keywords"), "|"), "123|lfg dm")
    whisper("inv", "A-One")
    whisper("lfg DM", "B-Two")
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "B-Two")
end)

scenario("each chat is heard only when switched on", function()
    start()
    Mock.chat("CHAT_MSG_GUILD", "inv", "G-Mate")
    Mock.chat("CHAT_MSG_SAY", "inv", "S-Near")
    Mock.chat("CHAT_MSG_YELL", "inv", "Y-Near")
    Mock.chat("CHAT_MSG_CHANNEL", "inv", "C-Far")
    equal(#Mock.invites, 0, "whispers only by default")
    Mock.slash("listen guild on")
    Mock.slash("listen say on")
    Mock.slash("listen channel on")
    Mock.chat("CHAT_MSG_GUILD", "inv", "G-Mate")
    Mock.chat("CHAT_MSG_OFFICER", "inv", "O-Fficer")
    Mock.chat("CHAT_MSG_YELL", "inv", "Y-Near")
    Mock.chat("CHAT_MSG_CHANNEL", "inv", "C-Far")
    equal(#Mock.invites, 4)
    Mock.slash("listen whisper off")
    whisper("inv", "W-Hisper")
    equal(#Mock.invites, 4, "whispers switched off")
end)

scenario("a class left off the list is not invited; the class comes from the whisper's GUID", function()
    local ns = start({ guids = { ["Player-R"] = "ROGUE", ["Player-M"] = "MAGE" } })
    Mock.slash("class rogue off")
    whisper("inv", "Sneaky-Pete", "Player-R")
    whisper("inv", "Fire-Ball", "Player-M")
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "Fire-Ball")
    local skipped = ns.db.recent[#ns.db.recent - 1]
    equal(skipped.outcome, "skipped")
    check(skipped.reason:find("Rogue", 1, true), "the reason names the class: " .. tostring(skipped.reason))
    check(printed("not inviting"), "a whisperer's refusal is said")
    equal(#Mock.whoQueries, 0, "the GUID was enough")
    Mock.slash("class all")
    check(ns.Inviter:ClassAllowed("ROGUE"), "all classes back")
end)

scenario("a stranger's level is asked by /who on the next key press, then the invite goes out", function()
    local ns = start()
    Mock.slash("level 10 20")
    whisper("inv", "Grim-Tusk", "Player-1")
    equal(#Mock.invites, 0, "not before the level is known")
    equal(#Mock.whoQueries, 0, "no /who without a key press")
    equal(lastDecision(ns).outcome, "waiting")
    Mock.advance(1)
    Mock.key("W")
    equal(#Mock.whoQueries, 1, "the key press sent the /who")
    equal(Mock.whoQueries[1], 'n-"Grim Tusk"')
    Mock.whoAnswer({ { "Grim-Tusk", 15, "Night Elf", "Druid" } })
    equal(#Mock.chatLines, 0, "the who lines were swallowed")
    equal(#Mock.invites, 1, "invited once the level fit")
    local record = lastDecision(ns)
    equal(record.level, 15)
    equal(record.class, "DRUID", "the class read from 'Night Elf Druid'")
end)

scenario("a level outside the range is refused, and so is a /who that finds nobody", function()
    local ns = start()
    Mock.slash("level 10 20")
    whisper("inv", "Low-Bie", "Player-1")
    Mock.advance(1)
    Mock.key("W")
    Mock.whoAnswer({ { "Low-Bie", 8, "Human", "Warrior" } })
    equal(#Mock.invites, 0)
    check(lastDecision(ns).reason:find("level 8", 1, true), "reason: " .. tostring(lastDecision(ns).reason))
    whisper("inv", "Gone-Away", "Player-2")
    Mock.advance(6)
    Mock.key("A")
    equal(#Mock.whoQueries, 2)
    Mock.whoAnswer({})
    equal(#Mock.invites, 0)
    check(lastDecision(ns).reason:find("nobody", 1, true), "reason: " .. tostring(lastDecision(ns).reason))
end)

scenario("held keys and quick presses respect the gap between /who queries", function()
    start()
    Mock.slash("level 10")
    whisper("inv", "A-One")
    Mock.advance(1)
    Mock.key("W")
    Mock.whoAnswer({ { "A-One", 30, "Human", "Mage" } })
    whisper("inv", "B-Two")
    Mock.advance(0.5)
    Mock.key("S")
    equal(#Mock.whoQueries, 1, "too soon after the last query")
    Mock.advance(5)
    Mock.key("S")
    equal(#Mock.whoQueries, 2, "asked once the gap had passed")
end)

scenario("without a key press for two minutes the request is let go", function()
    local ns = start()
    Mock.slash("level 10")
    whisper("inv", "Patient-One")
    Mock.advance(125)
    equal(lastDecision(ns).outcome, "skipped")
    check(lastDecision(ns).reason:find("key press", 1, true))
    equal(ns.Who:Waiting(), 0)
end)

scenario("guild members and friends are judged by the roster's level, with no /who", function()
    local ns = start({ guild = { { "Guild-Mate", 25, "PRIEST" } }, friends = { { "Old-Pal", 9, "HUNTER" } } })
    Mock.slash("level 10 30")
    whisper("inv", "Guild-Mate")
    whisper("inv", "Old Pal")
    equal(#Mock.whoQueries, 0, "no /who for either")
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "Guild-Mate")
    check(lastDecision(ns).reason:find("level 9", 1, true))
end)

scenario("only guild / only friends keep strangers out", function()
    local ns = start({ guild = { { "Guild-Mate", 25, "PRIEST" } }, friends = { { "Old-Pal", 40, "HUNTER" } } })
    Mock.slash("only guild")
    whisper("inv", "Old-Pal")
    whisper("inv", "Total-Stranger")
    whisper("inv", "Guild-Mate")
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "Guild-Mate")
    Mock.advance(11)
    Mock.slash("only both")
    whisper("inv", "Old-Pal")
    whisper("inv", "Total-Stranger")
    equal(#Mock.invites, 2)
    equal(Mock.invites[2], "Old-Pal")
    check(lastDecision(ns).reason:find("your guild or friends", 1, true))
end)

scenario("no invites when you are not the leader, or the party is full - unless it may become a raid", function()
    local ns, state = start()
    state.group.members = { "P-One" }
    state.group.leader = false
    whisper("inv", "A-One")
    equal(#Mock.invites, 0)
    check(lastDecision(ns).reason:find("leader", 1, true))
    state.group.leader = true
    state.group.members = { "P-One", "P-Two", "P-Three", "P-Four" }
    whisper("inv", "B-Two")
    equal(#Mock.invites, 0)
    check(lastDecision(ns).reason:find("full", 1, true))
    whisper("inv", "P-One")
    Mock.advance(11)
    Mock.slash("raid on")
    whisper("inv", "B-Two")
    equal(Mock.raidConversions, 1, "the party made a raid")
    equal(#Mock.invites, 0, "the invite waits for the raid")
    Mock.advance(1.1)
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "B-Two")
end)

scenario("someone already in the group, your own lines and repeats are left alone", function()
    local ns, state = start()
    state.group.members = { "Party-Pal" }
    whisper("inv", "Party-Pal")
    check(lastDecision(ns).reason:find("already", 1, true))
    Mock.slash("listen say on")
    Mock.chat("CHAT_MSG_SAY", "inv", "Purrdee-Bubson")
    whisper("inv", "A-One")
    whisper("inv", "A-One")
    whisper("inv", "a one")
    equal(#Mock.invites, 1, "one invite for three asks")
    Mock.advance(11)
    whisper("inv", "A-One")
    equal(#Mock.invites, 2, "asked again later: invited again")
end)

-- someone joins your group: the roster changes and the client says so
local function joins(state, name)
    state.group.members[#state.group.members + 1] = name
    Mock.fire("GROUP_ROSTER_UPDATE")
    Mock.advance(0.6)
end

scenario("'raid always' makes any party you lead a raid as soon as somebody joins", function()
    local ns, state = start()
    Mock.slash("raid always")
    check(ns:GetOption("raidAlways") and ns:GetOption("autoRaid"), "always implies a full party too")
    joins(state, "P-One")
    equal(Mock.raidConversions, 1)
    check(printed("made the party a raid"))
    joins(state, "P-Two")
    equal(Mock.raidConversions, 1, "a raid already")
    Mock.slash("raid off")
    check(not ns:GetOption("raidAlways") and not ns:GetOption("autoRaid"))
end)

scenario("'raid always' does nothing while somebody else leads", function()
    local _, state = start()
    Mock.slash("raid always")
    state.group.leader = false
    joins(state, "P-One")
    equal(Mock.raidConversions, 0)
end)

scenario("promote everyone switches the raid's own everyone-is-assistant on, and off again", function()
    local _, state = start()
    Mock.slash("promote all on")
    joins(state, "P-One")
    equal(state.group.everyone, false, "a party has no assistants")
    state.group.raid = true
    joins(state, "P-Two")
    equal(state.group.everyone, true)
    check(printed("everyone in the raid is an assistant"))
    equal(#Mock.promotions, 0, "no one-by-one promotes needed")
    Mock.slash("promote all off")
    Mock.advance(0.6)
    equal(state.group.everyone, false, "switched back off, as we had switched it on")
end)

scenario("the promote list makes listed names assistants as they join, whoever invited them", function()
    local ns, state = start()
    Mock.slash("promote add Tank-Man")
    Mock.slash("promote add healer friend")
    equal(table.concat(ns:GetOption("promoteList"), "|"), "Tank Man|healer friend")
    state.group.raid = true
    joins(state, "Some-Body")
    joins(state, "Tank-Man")
    joins(state, "Healer-Friend")
    equal(#Mock.promotions, 2)
    equal(Mock.promotions[1], "Tank-Man")
    equal(Mock.promotions[2], "Healer-Friend")
    joins(state, "Other-One")
    equal(#Mock.promotions, 2, "an assistant already is not asked again")
    Mock.slash("promote remove tank man")
    equal(#ns:GetOption("promoteList"), 1)
end)

scenario("the window's assistant list writes the promote list", function()
    local ns = start()
    Mock.slash("")
    local boxes = {}
    for _, w in ipairs(Mock.frames) do
        if w.__kind == "EditBox" then
            boxes[#boxes + 1] = w
        end
    end
    local list = boxes[#boxes] -- keywords, min, max, then the promote list
    list:SetFocus()
    list:SetText("Tank-Man, Healer Friend")
    list:ClearFocus()
    equal(table.concat(ns:GetOption("promoteList"), "|"), "Tank Man|Healer Friend")
    equal(list:GetText(), "Tank Man, Healer Friend", "shown back")
end)

scenario("a class cap: no more than 3 druids, counting the group", function()
    local ns, state = start({ guids = { ["G-D"] = "DRUID", ["G-M"] = "MAGE" } })
    state.group.raid = true
    state.group.members = { "Tree-One", "Tree-Two", "Tree-Three", "Fire-One" }
    state.group.classes = { ["Tree-One"] = "DRUID", ["Tree-Two"] = "DRUID", ["Tree-Three"] = "DRUID", ["Fire-One"] = "MAGE" }
    Mock.slash("max druids 3")
    equal(ns:GetOption("classCaps").DRUID, 3, "'druids' read as the class")
    whisper("inv", "Moon-Kin", "G-D")
    whisper("inv", "Frost-Bolt", "G-M")
    equal(#Mock.invites, 1)
    equal(Mock.invites[1], "Frost-Bolt", "a mage passes: no cap on mages")
    local skipped = ns.db.recent[#ns.db.recent - 1]
    check(skipped.reason:find("3 Druids already (max 3)", 1, true), "reason: " .. tostring(skipped.reason))
    check(printed("not inviting"), "the druid who whispered is told why in your chat")
end)

scenario("'max of each' counts you too, and a class's own cap wins over it", function()
    local ns, state = start({ guids = { ["G-S"] = "SHAMAN", ["G-W"] = "WARRIOR" } })
    state.group.members = { "Totem-One" }
    state.group.classes = { ["Totem-One"] = "SHAMAN" }
    Mock.slash("max 2")
    whisper("inv", "Totem-Two", "G-S")
    equal(#Mock.invites, 0, "you and Totem-One are two shamans already")
    Mock.slash("max shaman 3")
    Mock.advance(11)
    whisper("inv", "Totem-Two", "G-S")
    equal(#Mock.invites, 1, "the shaman's own 3 wins over 2 of each")
    Mock.slash("max off")
    check(not ns.Inviter:CapsOn(), "all caps gone")
end)

scenario("invites still out count against the cap, until they lapse", function()
    local ns = start({ guids = { ["G-1"] = "PRIEST", ["G-2"] = "PRIEST", ["G-3"] = "PRIEST" } })
    Mock.slash("max priest 2")
    whisper("inv", "Holy-One", "G-1")
    whisper("inv", "Holy-Two", "G-2")
    whisper("inv", "Holy-Three", "G-3")
    equal(#Mock.invites, 2, "two invited, neither has joined, the third waits for room")
    check(lastDecision(ns).reason:find("2 Priests already", 1, true), "reason: " .. tostring(lastDecision(ns).reason))
    Mock.advance(121)
    whisper("inv", "Holy-Three", "G-3")
    equal(#Mock.invites, 3, "the first two invites lapsed unanswered")
end)

scenario("someone who joined is counted once, not as member and invite both", function()
    local ns, state = start({ guids = { ["G-1"] = "ROGUE", ["G-2"] = "ROGUE" } })
    Mock.slash("max rogue 2")
    whisper("inv", "Stab-One", "G-1")
    state.group.members = { "Stab-One" }
    state.group.classes = { ["Stab-One"] = "ROGUE" }
    whisper("inv", "Stab-Two", "G-2")
    equal(#Mock.invites, 2, "one rogue in the group: room for the second")
    equal(ns.Inviter:ClassCount("ROGUE"), 2, "Stab-One once, Stab-Two on the way")
end)

scenario("with a cap on, a stranger with no GUID class is looked up by /who", function()
    local ns = start()
    Mock.slash("max druid 1")
    whisper("inv", "No-Guid")
    equal(#Mock.invites, 0)
    equal(lastDecision(ns).outcome, "waiting")
    Mock.advance(1)
    Mock.key("W")
    equal(#Mock.whoQueries, 1, "the /who went out for the class")
    Mock.whoAnswer({ { "No-Guid", 30, "Tauren", "Druid" } })
    equal(#Mock.invites, 1, "the first druid fits under a cap of 1")
end)

scenario("the window's class cap boxes write the caps", function()
    local ns = start()
    Mock.slash("")
    local boxes = {}
    for _, w in ipairs(Mock.frames) do
        if w.__kind == "EditBox" then
            boxes[#boxes + 1] = w
        end
    end
    -- keywords, max of each, then one per class in the client's order (warrior first, druid last)
    local capAll, warrior, druid = boxes[2], boxes[3], boxes[11]
    capAll:SetFocus(); capAll:SetText("6"); capAll:ClearFocus()
    druid:SetFocus(); druid:SetText("3"); druid:ClearFocus()
    equal(ns:GetOption("capAll"), 6)
    equal(ns:GetOption("classCaps").DRUID, 3)
    equal(warrior:GetText(), "", "no own cap for warriors")
    druid:SetFocus(); druid:SetText(""); druid:ClearFocus()
    equal(ns:GetOption("classCaps").DRUID, nil, "emptied: the druid cap is gone")
    check(ns.Inviter:Summary():find("max 6 of each", 1, true), ns.Inviter:Summary())
end)

scenario("a secret chat line is skipped without an error", function()
    local ns = start()
    whisper(Mock.SECRET, "A-One")
    whisper("inv", Mock.SECRET)
    equal(#Mock.invites, 0)
    equal(ns.Inviter.stats.secretLines, 2)
end)

scenario("the window opens, shows the options and writes them back", function()
    local ns = start({ off = true })
    Mock.slash("")
    local frame = ns.Panel:Frame()
    check(frame and frame:IsShown(), "shown")
    -- the first checkbox is 'Invite on this character'
    local boxes = {}
    for _, w in ipairs(Mock.frames) do
        if w.__kind == "CheckButton" then
            boxes[#boxes + 1] = w
        end
    end
    check(#boxes >= 1 + 1 + 4 + 9 + 3, "checkboxes: " .. #boxes)
    equal(boxes[1]:GetChecked(), false)
    Mock.click(boxes[1])
    check(ns:IsEnabled(), "the click switched it on")
    -- a class box: the 7th..15th are the classes (after enabled, anywhere, four sources)
    local warrior = boxes[7]
    equal(warrior:GetChecked(), true)
    Mock.click(warrior)
    equal(ns:GetOption("classes").WARRIOR, false)
    whisper("inv", "A-One")
    Mock.slash("")
    check(not frame:IsShown(), "closed")
end)

scenario("the level box: empty max means no upper bound", function()
    local ns = start()
    Mock.slash("level 20 10")
    local min, max = ns.Inviter:LevelRange()
    equal(min, 10, "swapped")
    equal(max, 20)
    Mock.slash("level 5")
    min, max = ns.Inviter:LevelRange()
    equal(min, 5)
    equal(max, nil)
end)

scenario("one profile per character, rules shared, and everything saved is saveable", function()
    local ns = start()
    Mock.slash("level 12")
    whisper("inv", "A-One")
    check(ns.db.chars["Purrdee Bubson - TestRealm"], "the profile key")
    check(ns.db.chars["Purrdee Bubson - TestRealm"].enabled, "on for this character")
    Mock.slash("diag")
    check(savedSafe(AKForeverAutoInviterDB), "only strings, numbers, booleans and tables")
    local saved = AKForeverAutoInviterDB
    local ns2 = Mock.install({ db = saved, playerName = "Purr", surname = "Gola" })
    Mock.login()
    check(not ns2:IsEnabled(), "an alt starts off")
    equal(ns2:GetOption("minLevel"), 12, "the rules are the account's")
end)

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
if #failures > 0 then
    os.exit(1)
end
