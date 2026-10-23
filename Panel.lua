-- Panel: the settings window ('/autoinv'). On/off for this character, the keywords, where they are heard, the
-- classes, the level range, the guild/friends lists, the raid switch - and the last decisions with their
-- reasons. Every control writes its option at once; nothing to save. Dragged by its title, the place kept per
-- character.
local _, ns = ...

local Panel = {}
ns.Panel = Panel

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local GOLD, DIM = "|cffffd100", "|cff999999"
local WIDTH, PAD, ROW = 360, 12, 22
local RECENT_LINES = 6

local panel
local controls = {} -- refreshed from the options by Panel:Refresh()
local recentLines = {}

------------------------------------------------------------------------
-- Building blocks
------------------------------------------------------------------------
local function heading(parent, text, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    fs:SetText(text)
    return fs
end

local function checkbox(parent, label, x, y, onClick)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(22, 22)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    text:SetText(label)
    box.label = text
    box:SetScript("OnClick", function(self)
        ns.SafeCall(onClick, self:GetChecked() and true or false)
        Panel:Refresh()
    end)
    return box
end

local function inputBox(parent, width, x, y, onCommit)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    box:SetAutoFocus(false)
    local function commit(self)
        ns.SafeCall(onCommit, self:GetText() or "")
        self:ClearFocus()
        Panel:Refresh()
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", function(self)
        ns.SafeCall(onCommit, self:GetText() or "")
        Panel:Refresh()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        Panel:Refresh()
    end)
    return box
end

local function label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------
local function savePlace()
    local point, _, relativePoint, x, y = panel:GetPoint(1)
    ns.cdb.panel = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function place()
    panel:ClearAllPoints()
    local saved = ns.cdb.panel
    if type(saved) == "table" and saved.point then
        panel:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
end

local function build()
    panel = CreateFrame("Frame", "AKForeverAutoInviterPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetWidth(WIDTH)
    panel:SetFrameStrata("HIGH")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SafeCall(savePlace)
    end)
    if type(panel.SetBackdrop) == "function" then
        panel:SetBackdrop(BACKDROP)
        panel:SetBackdropColor(0.05, 0.05, 0.12, 0.92)
    end
    -- Escape closes it, like Blizzard's own windows
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "AKForeverAutoInviterPanel")
    end
    local close = CreateFrame("Button", "AKForeverAutoInviterClose", panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function()
        panel:Hide()
    end)

    local y = -PAD
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
    title:SetText("AutoInviter")
    local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 6, 0)
    version:SetText("v" .. ns.version)
    y = y - ROW

    controls.enabled = checkbox(panel, "Invite on this character", PAD, y, function(on)
        ns:SetEnabled(on)
    end)
    controls.status = label(panel, "", PAD + 190, y - 5)
    y = y - ROW - 4

    heading(panel, "Keywords", y)
    controls.keywords = inputBox(panel, 150, PAD + 74, y + 3, function(text)
        local list = {}
        for word in string.gmatch(text, "[^,]+") do
            word = string.match(word, "^%s*(.-)%s*$")
            if word ~= "" then
                list[#list + 1] = string.lower(word)
            end
        end
        if #list > 0 then
            ns:SetOption("keywords", list)
        end
    end)
    controls.anywhere = checkbox(panel, "anywhere in a line", PAD + 232, y + 4, function(on)
        ns:SetOption("anywhere", on)
    end)
    y = y - ROW - 2

    heading(panel, "Heard in", y)
    y = y - ROW + 4
    controls.sources = {}
    for index, source in ipairs(ns.Inviter.SOURCES) do
        controls.sources[source] = checkbox(panel, ns.Inviter.SOURCE_LABELS[source], PAD + (index - 1) * 84, y, function(on)
            local sources = ns:GetOption("sources")
            sources[source] = on
            ns:SetOption("sources", sources)
        end)
    end
    y = y - ROW - 4

    -- each class: invited or not, and the most of it in the group (empty: the "max of each", or no cap)
    heading(panel, "Classes", y)
    label(panel, "max of each", PAD + 172, y - 2)
    controls.capAll = inputBox(panel, 26, PAD + 240, y + 3, function(text)
        local value = tonumber(text)
        ns:SetOption("capAll", value and math.max(0, math.floor(value)) or nil)
    end)
    y = y - ROW + 4
    controls.classes, controls.caps = {}, {}
    for index, class in ipairs(ns.Classes()) do
        local column, row = (index - 1) % 3, math.floor((index - 1) / 3)
        local x = PAD + column * 112
        local box = checkbox(panel, ns.ClassColored(class.token, class.name), x, y - row * ROW, function(on)
            local classes = ns:GetOption("classes")
            if on then classes[class.token] = nil else classes[class.token] = false end -- nil: allowed
            ns:SetOption("classes", classes)
        end)
        controls.classes[class.token] = box
        controls.caps[class.token] = inputBox(panel, 22, x + 82, y - row * ROW - 1, function(text)
            local caps = ns:GetOption("classCaps")
            local value = tonumber(text)
            caps[class.token] = value and math.max(0, math.floor(value)) or nil
            ns:SetOption("classCaps", caps)
        end)
    end
    y = y - math.ceil(#ns.Classes() / 3) * ROW - 4

    heading(panel, "Level", y)
    label(panel, "from", PAD + 52, y - 2)
    controls.minLevel = inputBox(panel, 32, PAD + 84, y + 3, function(text)
        local value = tonumber(text)
        if value then
            ns:SetOption("minLevel", math.max(1, math.floor(value)))
        end
    end)
    label(panel, "to", PAD + 126, y - 2)
    controls.maxLevel = inputBox(panel, 32, PAD + 146, y + 3, function(text)
        local value = tonumber(text)
        ns:SetOption("maxLevel", value and math.max(1, math.floor(value)) or nil) -- empty: no upper bound
    end)
    label(panel, DIM .. "(empty: any)|r", PAD + 186, y - 2)
    y = y - ROW - 2

    heading(panel, "Only", y)
    controls.onlyGuild = checkbox(panel, "guild members", PAD + 52, y + 4, function(on)
        ns:SetOption("onlyGuild", on)
    end)
    controls.onlyFriends = checkbox(panel, "friends", PAD + 172, y + 4, function(on)
        ns:SetOption("onlyFriends", on)
    end)
    y = y - ROW - 2

    heading(panel, "Raid", y)
    controls.autoRaid = checkbox(panel, "a full party", PAD + 52, y + 4, function(on)
        ns:SetOption("autoRaid", on)
    end)
    controls.raidAlways = checkbox(panel, "any party you lead", PAD + 172, y + 4, function(on)
        ns:SetOption("raidAlways", on)
    end)
    y = y - ROW - 2

    heading(panel, "Assistant", y)
    controls.promoteAll = checkbox(panel, "everyone", PAD + 74, y + 4, function(on)
        ns:SetOption("promoteAll", on)
    end)
    label(panel, "or", PAD + 162, y - 2)
    controls.promoteList = inputBox(panel, 150, PAD + 182, y + 3, function(text)
        local list = {}
        for name in string.gmatch(text, "[^,]+") do
            name = string.match(name, "^%s*(.-)%s*$")
            if name ~= "" then
                list[#list + 1] = ns.DisplayName(name)
            end
        end
        ns:SetOption("promoteList", list)
    end)
    y = y - ROW - 6

    heading(panel, "Recent", y)
    y = y - 16
    for index = 1, RECENT_LINES do
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
        fs:SetWidth(WIDTH - 2 * PAD)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        recentLines[index] = fs
        y = y - 14
    end
    panel:SetHeight(-y + PAD)
    place()
    panel:Hide()
end

------------------------------------------------------------------------
-- Showing the options
------------------------------------------------------------------------
local OUTCOME_COLORS = { invited = "|cff40ff40", skipped = "|cffff6060", waiting = "|cffffd100" }

function Panel:Refresh()
    if not panel or not panel:IsShown() then
        return
    end
    local enabled = ns:IsEnabled()
    controls.enabled:SetChecked(enabled)
    controls.status:SetText(enabled and "|cff40ff40inviting|r" or DIM .. "off|r")
    if not controls.keywords:HasFocus() then
        controls.keywords:SetText(table.concat(ns:GetOption("keywords"), ", "))
    end
    controls.anywhere:SetChecked(ns:GetOption("anywhere"))
    local sources = ns:GetOption("sources")
    for source, box in pairs(controls.sources) do
        box:SetChecked(sources[source] and true or false)
    end
    for token, box in pairs(controls.classes) do
        box:SetChecked(ns.Inviter:ClassAllowed(token))
    end
    local caps = ns:GetOption("classCaps")
    for token, box in pairs(controls.caps) do
        if not box:HasFocus() then
            box:SetText(caps[token] and tostring(caps[token]) or "")
        end
    end
    if not controls.capAll:HasFocus() then
        local all = tonumber(ns:GetOption("capAll"))
        controls.capAll:SetText(all and tostring(all) or "")
    end
    local min, max = ns.Inviter:LevelRange()
    if not controls.minLevel:HasFocus() then
        controls.minLevel:SetText(tostring(min))
    end
    if not controls.maxLevel:HasFocus() then
        controls.maxLevel:SetText(max and tostring(max) or "")
    end
    controls.onlyGuild:SetChecked(ns:GetOption("onlyGuild"))
    controls.onlyFriends:SetChecked(ns:GetOption("onlyFriends"))
    controls.autoRaid:SetChecked(ns:GetOption("autoRaid") or ns:GetOption("raidAlways"))
    controls.raidAlways:SetChecked(ns:GetOption("raidAlways"))
    controls.promoteAll:SetChecked(ns:GetOption("promoteAll"))
    if not controls.promoteList:HasFocus() then
        controls.promoteList:SetText(table.concat(ns:GetOption("promoteList"), ", "))
    end

    local recent = ns.db.recent
    for index = 1, RECENT_LINES do
        local record = recent[#recent - index + 1]
        if record then
            local who = ns.ClassColored(record.class, ns.DisplayName(record.name))
            if record.level then
                who = who .. " " .. record.level
            end
            recentLines[index]:SetText(DIM .. date("%H:%M", record.at) .. "|r " .. who .. " " .. (OUTCOME_COLORS[record.outcome] or "")
                .. tostring(record.outcome) .. "|r" .. (record.reason and (DIM .. " - " .. record.reason .. "|r") or ""))
        elseif index == 1 then
            recentLines[index]:SetText(DIM .. "nobody has asked yet|r")
        else
            recentLines[index]:SetText("")
        end
    end
end

function Panel:Toggle()
    if not panel then
        build()
    end
    panel:SetShown(not panel:IsShown())
    self:Refresh()
end

function Panel:Frame()
    return panel
end

ns.defaultCommand = function()
    Panel:Toggle()
end
ns:RegisterCommand("show", "open or close the window", ns.defaultCommand)

ns:Listen("OPTION_CHANGED", function()
    Panel:Refresh()
end)
ns:Listen("RECENT_CHANGED", function()
    Panel:Refresh()
end)
