local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local RenderText = require("ui/rendertext")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Scoring = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "") .. "scoring.lua")
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)") or "")

-- Hide simpleUI topbar while Behold is active (prevents clock/WiFi overlay on game).
-- Saves the current state and restores it when the game closes.
local _topbar_was_hidden = false
local _topbar_original_state = nil
local function _hideSimpleUITopbar()
    if _topbar_was_hidden then return end
    local ok, SUISettings = pcall(require, "infra/sui_store")
    if not ok or not SUISettings then return end
    _topbar_original_state = SUISettings:nilOrTrue("simpleui_topbar_enabled")
    if _topbar_original_state then
        SUISettings:saveSetting("simpleui_topbar_enabled", false)
        local ok2, Topbar = pcall(require, "screens/sui_topbar")
        if ok2 and Topbar and Topbar.invalidateDimCache then
            Topbar.invalidateDimCache()
        end
        _topbar_was_hidden = true
    end
end
local function _restoreSimpleUITopbar()
    if not _topbar_was_hidden then return end
    local ok, SUISettings = pcall(require, "infra/sui_store")
    if ok and SUISettings and _topbar_original_state ~= nil then
        SUISettings:saveSetting("simpleui_topbar_enabled", _topbar_original_state)
        local ok2, Topbar = pcall(require, "screens/sui_topbar")
        if ok2 and Topbar and Topbar.invalidateDimCache then
            Topbar.invalidateDimCache()
        end
    end
    _topbar_was_hidden = false
    _topbar_original_state = nil
end

-- Keying icons are original black/white PNGs in icons/ (not game assets).
-- White variants (*_w.png) are for dark card bands; ImageWidget scales them
-- to fit the requested box, keeping aspect ratio.
local key_icon_cache = {}
local function keyIconWidget(key, size, white)
    size = math.max(8, math.floor(size or 16))
    local cache_key = key .. ":" .. size .. (white and ":w" or ":b")
    local widget = key_icon_cache[cache_key]
    if not widget then
        widget = ImageWidget:new{
            file = PLUGIN_DIR .. "icons/" .. key .. (white and "_w" or "") .. ".png",
            width = size, height = size,
            scale_factor = 0,
            alpha = true,
        }
        key_icon_cache[cache_key] = widget
    end
    return widget
end

local BeholdCamelot = WidgetContainer:extend{
    name = "beholdcamelot",
    is_doc_only = false,
}

local HOLD_INFO = "   ⓘ"

local CARDS = {
    {id="crafts", title="Crafts", names={"Local Craft","Skilled Artisans","Master Builders","Royal Works"}, start=1},
    {id="host", title="Host", names={"Armed Retainers","Household Knights","Royal Host","Assembled Host"}, start=1},
    {id="works", title="Works", names={"Armourers","Stonework","Waterworks","Royal Roads"}, start=1},
    {id="council", title="Council", names={"Galahad","The Round Table","Arthur","Uther Pendragon"}, start=4},
    {id="customs", title="Customs", names={"Customs of the Court","The Pentecostal Oath","Merlin's Counsel","The Holy Grail"}, start=1},
    {id="kin", title="Kin", names={"Gawain","Gareth","Gaheris","The Last Battle"}, start=1},
    {id="lake", title="Lake", names={"Guinevere","Lancelot","Joyous Gard","Sir Bors"}, start=1},
    {id="gaul", title="Gaul", names={"King Claudas","Gaul","Brittany","King Bors"}, start=1},
    {id="allies", title="Allies", names={"Caerleon","Cameliard","Benwick","King Ban"}, start=1},
    {id="wounds", title="Wounds", names={"The Dolorous Stroke","The Wounded Lands","Pellam's Castle","Balin's Fatal Quest"}, start=4},
    {id="grail", title="Grail", names={"Astolat","Corbenic","Percival","Sarras"}, start=1},
    {id="marches", title="Marches", names={"Bedegraine","Cornwall","Logres","Guarding the Realm"}, start=1},
    {id="camelot", title="Camelot", names={"Camelot: Settlement","Camelot: Stronghold","Camelot: Court","Camelot: Royal Seat"}, start=1},
    {id="dues", title="Dues", names={"Almsgiving","Customary Dues","Royal Levies","Extraordinary Levy"}, start=1},
    {id="trade", title="Trade", names={"Grain Stores","Quarries","Wine Merchants","Cloth Merchants"}, start=1},
    {id="claims", title="Claims", names={"Secure a Holding","Extend Protection","Obtain Allegiance","Assert Sovereignty"}, start=1},
}

local REALM_NAMES = { "The Crown", "The Fellowship", "Arthur's Empire", "The Grail Quest" }
local RIVALS = { "Chronicle of the Realm", "Mordred", "Morgan le Fay", "King Lot", "Lucius" }
local GAME_DIFFICULTIES = {
    Casual={rounds=12, starting={"marches", "allies"}},
    Easy={rounds=12, starting={"marches"}},
    Normal={rounds=12, starting={}},
    Hard={rounds=11, starting={}},
    Impossible={rounds=10, starting={}},
}
local RIVAL_DIFFICULTIES = { Casual=-40, Easy=-20, Normal=0, Hard=20, Impossible=40 }
local STRATEGIES = {}
STRATEGIES["Chronicle of the Realm"] = [[PLAN: Maximize final Camelot Renown; there is no rival threshold. Build affordable storage and development, not a fixed round-by-round opening. Degrading Balin's Fatal Quest can fund materials; conquest supports Camelot and later realm costs.

FINISH: Compare each change's Renown gain with lost controlled wealth, abandoned cards and unrest. All active faces score, even in the pile. The Fellowship rewards prosperity; Arthur's Empire rewards Allies; The Grail Quest rewards total levels but needs Galahad. An upgrade is not automatically better. The test walkthroughs validate state consistency, not optimal play.]]
STRATEGIES["Mordred"] = [[TARGET: Win the Renown margin, not just Camelot's score. Each crops removes 4 rival Renown. Almsgiving/Customary Dues and Grain Stores can also score from crops. Caerleon's later faces supply crops, but check their unrest and conversion costs.

WATCH: Each unrest adds 1 rival Renown even when covered; uncovered unrest also costs Camelot 2. Prosperity covers Camelot's penalty but does not remove Mordred's bonus. In The Crown/The Fellowship each navy adds 2 rival Renown. Arthur's Empire adds 2 per level-3+ card; The Grail Quest adds 3.

FINISH: The Fellowship is a useful low-unrest candidate, not a guaranteed best realm. Compare its prosperity score against Arthur's Empire's Allies and its high-level penalty. Avoid late upgrades that improve Camelot less than the rival. You must finish strictly ahead.]]
STRATEGIES["Morgan le Fay"] = [[CHOOSE A FINISH: The Crown/The Fellowship gives Morgan le Fay +6 per active Holding CARD, not per wealth and not only controlled Holdings. Merely abandoning a Holding does not remove that term; changing its active face does.

ARTHUR'S EMPIRE: Each culture cuts 3 rival Renown. Corbenic, Merlin's Counsel and Camelot can supply culture; balance that against Arthur's Empire's 7 Renown per Ally and conversion costs.

THE GRAIL QUEST: Each coin cuts 5 rival Renown. Royal Levies/Extraordinary Levy, trade and coin-rich Allies can help, but unrest and lost culture still matter. Galahad is required; account for all realm upgrade costs.

FINISH: Compare the live margin before committing to a realm. Culture alone is not the Grail Quest plan: coins are. These are scoring-based plans, not proven winning lines.]]
STRATEGIES["King Lot"] = [[PRIORITY: Controlled wealth is powerful: +1 Camelot Renown and -3 rival Renown per extra wealth, before other effects. Develop and retain valuable Holdings; do not sacrifice them for a realm upgrade without counting the loss. Fifteen wealth is a useful target, not a cap or requirement.

MILITARY: At 11 military, their prosperity multiplier drops from 2 to 1. Count whether that whole-score reduction repays the military upgrades and any added unrest. Controlled Gaul can contribute extra military through its scoring effect.

PROSPERITY: Still cover unrest, but excess prosperity also scores for this rival. In The Fellowship, covered excess prosperity gives Camelot +1 but the rival +1 at 11 military, or +2 below it.

FINISH: Favor wealth and a deliberate military threshold over automatic Arthur's Empire/Ally conversion. Win strictly above the rival.]]
STRATEGIES["Lucius"] = [[FIRST DECISION: Their 11-wealth threshold counts wealth on ALL active Holding faces, controlled or not. At 11+, they gain 2 per card without a blue banner. At 10 or less, each navy cuts 6 rival Renown. Check the actual margin on both sides: crossing 11 is not automatically good.

ARTHUR'S EMPIRE: Removes the entire printed-materials term and scores 7 per Ally. Plan abandonment and prerequisites before converting Holdings: conversion changes the wealth branch, loses controlled income and may add unrest.

OTHER REALMS: Each printed available-material icon cuts 2 rival Renown. Stored materials do not count for this term. Above the wealth threshold, blue-banner faces reduce the non-blue penalty; below it, navy matter instead.

FINISH: Keep useful resource faces, compare Arthur's Empire against the current realm, and protect a strictly positive final margin. No fixed three-Ally prescription is guaranteed.]]
local CARD_TYPES = {
    crafts={"Action", "Action", "Action", "Action"},
    host={"Action", "Action", "Action", "Action"},
    works={"Action", "Action", "Action", "Action"},
    council={"Court", "Court", "Court", "Court"},
    customs={"Court", "Court", "Court", "Court"},
    kin={"Court", "Court", "Court", "Court"},
    lake={"Court", "Court", "Holding", "Ally"},
    gaul={"Action", "Holding", "Holding", "Ally"},
    allies={"Holding", "Holding", "Holding", "Ally"},
    wounds={"Action", "Holding", "Holding", "Action"},
    grail={"Holding", "Holding", "Ally", "Court"},
    marches={"Holding", "Holding", "Holding", "Court"},
    camelot={"Provision", "Provision", "Provision", "Provision"},
    dues={"Provision", "Provision", "Provision", "Provision"},
    trade={"Provision", "Provision", "Provision", "Provision"},
    claims={"Action", "Action", "Action", "Action"},
}

-- Values printed in the upper-left corner of Holding faces.  A nil entry is
-- deliberately different from zero: it means the active face is not a Holding.
local HOLDING_WEALTH = {
    lake={nil,nil,4,nil}, gaul={nil,1,2,nil}, allies={1,2,4,nil},
    wounds={nil,2,1,nil}, grail={1,3,nil,nil}, marches={1,2,3,nil},
}

-- A compact action DSL. Each option represents one legal way to resolve the
-- printed action. Costs are completed before benefits become available.
-- Conquests are discrete strength slots; they are not a fungible point pool.
local ACTIONS = {
    crafts={
        {{label="Up to twice: discard and pay 1M to develop 1", repetitions="crafts", repeat_limit=2}},
        {{label="Discard 1; pay up to 2M to develop", costs={discard=1}, repetitions="develop",repeat_limit=2}},
        {{label="Discard 1; pay up to 3M to develop", costs={discard=1}, repetitions="develop",repeat_limit=3}},
        {{label="Pay up to 3M to develop", repetitions="develop",repeat_limit=3}},
    },
    works={
        {{label="Discard 1; pay up to 2M for different developments", costs={discard=1}, repetitions="develop",repeat_limit=2, different=true}},
        {{label="Pay up to 2M for different developments", repetitions="develop",repeat_limit=2, different=true}},
        {{label="Pay up to 3M to develop", repetitions="develop",repeat_limit=3}},
        {{label="Pay up to 4M to develop", repetitions="develop",repeat_limit=4}},
    },
    host={
        {{label="Pay 2P: conquer strength 1", costs={population=2}, conquests={1}}, {label="Degrade 1: conquer strength 1", costs={degrade=1}, conquests={1}}},
        {{label="Pay 3P: conquer strength 2", costs={population=3}, conquests={2}}, {label="Pay 2P: conquer strength 1", costs={population=2}, conquests={1}}, {label="Degrade 1: conquer strength 1", costs={degrade=1}, conquests={1}}},
        {{label="Up to three conquests: choose payment for each", repetitions="host3", repeat_limit=3}},
        {{label="Up to twice: pay 1P to conquer 2 or degrade 1", repetitions="host4", repeat_limit=2}},
    },
    council={
        {{label="Degrade an Court; develop 2", costs={degrade_court=1}, develop=2}},
        {{label="Up to twice: discard to store 1P", repetitions="council_store", repeat_limit=2}},
        {{label="Discard an Court; store 1P", costs={discard_court=1}, store_population=1}},
        {{label="Degrade 1; store 1P", costs={degrade=1}, store_population=1}},
    },
    customs={
        {{label="Ignore a discard/degrade cost; draw 1", draw=1, interrupt=true}},
        {{label="Degrade 1; develop controlled 1", costs={degrade=1}, develop_controlled=1}, {label="Abandon 1; develop controlled 1", costs={abandon=1}, develop_controlled=1}},
        {{label="Discard 1; draw its prosperity", costs={discard=1}, counsel="draw"}, {label="Discard 2; conquer by second card's unrest", costs={discard=2}, counsel="conquer"}},
        {{label="Abandon holdings; develop OR degrade by total wealth", flexible_abandon=true}},
    },
    kin={
        {{label="Add +1 to current conquest", conquer_boost=1, interrupt=true}},
        {{label="Pay 1P; store 2M", costs={population=1}, store_materials=2}},
        {{label="Store 1M per controlled coin icon", store_materials_by_bags=true}},
        {{label="Passive card", passive=true}},
    },
    lake={
        {{label="Passive response to storing population", passive=true}},
        {{label="Pay 1P; conquer strength 1", costs={population=1}, conquests={1}}},
        {{label="Store opposite of current stored resources", store_opposite=true}},
        {{label="Abandon holdings; conquer their wealth +2", flexible_abandon=true, conquer_from_abandon=true}},
    },
    gaul={
        {{label="Passive card", passive=true}}, {{label="Passive scoring card", passive=true}},
        {{label="On conquest: store 2P", on_conquer=true, store_population=2}},
        {{label="Store 2M", store_materials=2}, {label="Discard 1; store 4M", costs={discard=1}, store_materials=4}},
    },
    allies={
        {{label="No action", passive=true}}, {{label="Draw to 6", draw_to=6}},
        {{label="On conquest: draw 2", on_conquer=true, draw=2}}, {{label="Replacement interrupt", interrupt=true, passive=true}},
    },
    wounds={
        {{label="No action", passive=true}}, {{label="Passive card", passive=true}},
        {{label="Passive card", passive=true}}, {{label="Passive card", passive=true}},
    },
    grail={
        {{label="No action", passive=true}}, {{label="Passive card", passive=true}},
        {{label="Store 2M", store_materials=2}, {label="Store 1P", store_population=1}},
        {{label="Store 1P", store_population=1}, {label="Pay 1M; store 3P", costs={materials=1}, store_population=3}},
    },
    marches={
        {{label="Pay 1P; store 2M", costs={population=1}, store_materials=2}},
        {{label="Discard cards; draw for their coin icons", marches_discard=true}},
        {{label="Pay 1M; store 2P", costs={materials=1}, store_population=2}},
        {{label="Passive scoring card", passive=true}},
    },
    camelot={
        {{label="Discard 1; store P per controlled holding", costs={discard=1}, store_population_by_holdings=true}},
        {{label="Store P per controlled holding", store_population_by_holdings=true}},
        {{label="Store P per controlled holding", store_population_by_holdings=true}, {label="Pay 1M; store one additional P", costs={materials=1}, store_population_by_holdings=true, store_bonus=1}},
        {{label="Store 2P per controlled holding", store_population_by_holdings=true, store_multiplier=2}},
    },
    dues={
        {{label="Degrade 2; develop 1", costs={degrade=2}, develop=1}},
        {{label="Discard up to two: choose 1M or 1P for each", repetitions="taxes2", repeat_limit=2}},
        {{label="Discard up to two: choose 2M or 1P for each", repetitions="taxes3", repeat_limit=2}},
        {{label="Store 2M", store_materials=2}, {label="Store 2P", store_population=2}, {label="Discard 1; store 4M", costs={discard=1}, store_materials=4}, {label="Discard 1; store 3P", costs={discard=1}, store_population=3}},
    },
    trade={
        {{label="Discard 1; store M equal to holding wealth", costs={discard=1}, store_materials_by_wealth=true}},
        {{label="Discard 1; store M equal to holding wealth +1", costs={discard=1}, store_materials_by_wealth=true, store_bonus=1}},
        {{label="Discard 1; store M equal to twice holding wealth", costs={discard=1}, store_materials_by_wealth=true, store_multiplier=2}},
        {{label="Store M equal to twice holding wealth", store_materials_by_wealth=true, store_multiplier=2}},
    },
    claims={
        {{label="Discard 1; pay 2M to develop 1", costs={discard=1,materials=2}, develop=1}, {label="Degrade 1; pay 2M to develop 1", costs={degrade=1,materials=2}, develop=1}, {label="Discard 1; pay 2P for strength 1", costs={discard=1,population=2}, conquests={1}}, {label="Degrade 1; pay 2P for strength 1", costs={degrade=1,population=2}, conquests={1}}},
        {{label="Discard 1; pay 3M to develop 2", costs={discard=1,materials=3}, develop=2}, {label="Degrade 1; pay 3M to develop 2", costs={degrade=1,materials=3}, develop=2}, {label="Discard 1; pay 3P for strength 2", costs={discard=1,population=3}, conquests={2}}, {label="Degrade 1; pay 3P for strength 2", costs={degrade=1,population=3}, conquests={2}}, {label="Discard 1; pay 2P for strength 1", costs={discard=1,population=2}, conquests={1}}, {label="Degrade 1; pay 2P for strength 1", costs={degrade=1,population=2}, conquests={1}}},
        {{label="Discard 1; pay up to 2M to develop", costs={discard=1}, repetitions="develop",repeat_limit=2}, {label="Degrade 1; pay up to 2M to develop", costs={degrade=1}, repetitions="develop",repeat_limit=2}, {label="Discard 1; pay up to 2P to conquer", costs={discard=1}, repetitions="conquer",repeat_limit=2}, {label="Degrade 1; pay up to 2P to conquer", costs={degrade=1}, repetitions="conquer",repeat_limit=2}},
        {{label="Pay up to 2M to develop", repetitions="develop",repeat_limit=2}, {label="Pay up to 2P to conquer", repetitions="conquer",repeat_limit=2}},
    },
}

-- Functional description of each active face.  Short labels keep the card dialog
-- usable on a six-inch screen while still exposing every play-critical field.
local FACE_DATA = {
    crafts={
        {store="1 population", play="Any realm", effect="Resolve up to two repetitions. Each repetition costs one discarded card and 1 material, and grants Develop 1."},
        {store="1 population", play="Any realm", effect="Discard one card, then spend up to 2 materials. Each material grants Develop 1."},
        {store="2 population", play="Any realm", effect="Discard one card, then spend up to 3 materials. Each material grants Develop 1."},
        {store="2 population", play="Any realm", effect="Spend up to 3 materials, gaining Develop 1 for each material spent."},
    },
    host={
        {store="1 material", play="Crown-era only (The Crown/The Fellowship)", effect="Choose: spend 2 population for Conquer 1, or degrade one card for Conquer 1."},
        {store="1 material", play="Any realm", effect="Choose Conquer 2 for 3 population, Conquer 1 for 2 population, or Conquer 1 for degrading a card."},
        {store="2 materials", play="Any realm", effect="Make up to three Conquer 1 attempts. For each, either spend 1 population or degrade one card."},
        {store="2 materials", play="Any realm", effect="Resolve up to two benefits. Each costs 1 population: choose Conquer 2 or Degrade 1."},
    },
    works={
        {store="1 population", play="Any realm", effect="Discard one card and spend up to 2 materials. Develop a different card once for each material."},
        {store="1 population", play="Any realm", effect="Spend up to 2 materials. Develop a different card once for each material."},
        {store="2 population", play="Any realm", effect="Spend up to 3 materials; each grants Develop 1."},
        {store="2 population", play="Any realm", effect="Spend up to 4 materials; each grants Develop 1."},
    },
    council={
        {store="1 population", play="Any realm", effect="Degrade one Court card to gain Develop 2."},
        {store="1 population", play="Any realm", effect="Up to twice, discard one card to generate Store 1 population."},
        {store="1 population", play="Crown-era only (The Crown/The Fellowship)", effect="Discard a Court card to generate Store 1 population. While Lancelot is active, scoring also awards 1 Renown per 2 controlled wealth."},
        {store="1 population", play="Crown-era only (The Crown/The Fellowship)", effect="Degrade one card to generate Store 1 population."},
    },
    customs={
        {store="1 material", play="Crown-era only (The Crown/The Fellowship)", effect="Use during another card's action: waive its discard or degrade cost, then Draw 1."},
        {store="1 material", play="The Crown only", effect="Either degrade one card or abandon one controlled Holding. Then develop a controlled Holding once."},
        {store="1 material", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Discard one card and draw as many cards as its prosperity; alternatively discard a second card and conquer with strength equal to that second card's unrest."},
        {store="1 material", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Abandon any number of controlled Holdings. Their combined wealth becomes either Develop or Degrade points; choose one benefit type."},
    },
    kin={
        {store="1 material", play="Crown-era only (The Crown/The Fellowship)", effect="During conquest, increase its strength by 1. If The Round Table discards this card, refill to six cards after that action."},
        {store="1 material", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Spend 1 population to generate Store 2 materials. When this card is discarded for a different action, you may Draw 1."},
        {store="1 material", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Generate Store materials equal to the total coin icons on controlled Holdings."},
        {store="No available resource", play="Any realm", effect="While active, Quest-era banners do not prevent playing cards. Development and conquest still obey banners. Scoring is -5 in the Crown era, plus 9 if Sarras is active."},
    },
    lake={
        {store="2 materials", play="Crown-era only (The Crown/The Fellowship)", effect="After storing population, you may place Guinevere into storage for free, using her printed material value."},
        {store="2 materials", play="Crown-era only (The Crown/The Fellowship)", effect="Spend 1 population for Conquer 1. At scoring, active Gawain grants 4 prosperity; active Gareth or Gaheris instead adds 3 unrest."},
        {store="3 population", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Generate storage of a resource type equal to the amount of the opposite resource currently stored."},
        {store="2 materials", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Abandon any number of controlled Holdings. Gain one conquest with strength equal to their combined wealth plus 2."},
    },
    gaul={
        {store="1 material", play="Any realm", effect="This card cannot be discarded as payment for another card's action."},
        {store="1 material", play="Crown-era only (The Crown/The Fellowship)", effect="If controlled at scoring, each pair of unrest also contributes one military icon."},
        {store="2 population", play="Any realm", effect="Conquering Brittany triggers Store 2 population."},
        {store="2 materials", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Generate Store 2 materials, or discard one card to generate Store 4 materials."},
    },
    allies={
        {store="1 population", play="Any realm", effect="No action benefit."},
        {store="1 material", play="Any realm", effect="Draw until your hand has six cards."},
        {store="3 population", play="Any realm", effect="Conquering Benwick triggers Draw 2."},
        {store="2 materials", play="Any realm", effect="When a played card would be discarded, you may discard King Ban in its place."},
    },
    wounds={
        {store="2 materials", play="Any realm", effect="No action benefit. This orientation carries 3 unrest."},
        {store="2 population", play="Any realm", effect="Discarding or abandoning this Holding changes its orientation to The Dolorous Stroke."},
        {store="1 population", play="Any realm", effect="On conquest, change this card to The Wounded Lands before taking control."},
        {store="1 material", play="Any realm", effect="Degrading this orientation triggers Store 2 materials."},
    },
    grail={
        {store="2 materials", play="Crown-era only (The Crown/The Fellowship)", effect="No action benefit."},
        {store="No available resource", play="Any realm", effect="Conquering Corbenic requires strength 2, despite its printed wealth."},
        {store="2 materials", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Choose Store 2 materials or Store 1 population."},
        {store="3 population", play="Any realm", requirement="Active Galahad required", effect="Generate Store 1 population; alternatively spend 1 material to generate Store 3 population."},
    },
    marches={
        {store="1 population", play="The Crown only", effect="Spend 1 population to generate Store 2 materials."},
        {store="No available resource", play="Crown-era only (The Crown/The Fellowship)", effect="Discard any number of cards. Draw as many cards as the total coin icons on those discarded cards."},
        {store="1 material", play="Any realm", effect="Spend 1 material to generate Store 2 population."},
        {store="3 population", play="Any realm", requirement="Abandon one controlled Holding", effect="At scoring, every two culture icons grant one additional prosperity."},
    },
    camelot={
        {store="1 population", play="Any realm", effect="Discard one card. Generate Store population equal to the number of controlled Holdings."},
        {store="1 population", play="Any realm", effect="Generate Store population equal to the number of controlled Holdings."},
        {store="2 population", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Generate Store population equal to the number of controlled Holdings. You may spend 1 material to increase this amount by one."},
        {store="2 population", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Generate Store population equal to twice the number of controlled Holdings."},
    },
    dues={
        {store="1 population", play="Any realm", effect="Pay Degrade 2 to gain Develop 1."},
        {store="1 population", play="Any realm", effect="Discard up to two cards. Each independently generates Store 1 material or Store 1 population."},
        {store="1 population", play="Any realm", effect="Discard up to two cards. Each independently generates Store 2 materials or Store 1 population."},
        {store="2 population", play="Quest-era only (Arthur's Empire/The Grail Quest)", effect="Choose Store 2 materials or Store 2 population. Alternatively discard one card for Store 4 materials or Store 3 population."},
    },
    trade={
        {store="1 material", play="Any realm", effect="Discard one card. Generate Store materials equal to the combined wealth of controlled Holdings."},
        {store="2 materials", play="Any realm", effect="Discard one card. Generate Store materials equal to controlled wealth plus one."},
        {store="3 materials", play="Any realm", effect="Discard one card. Generate Store materials equal to twice controlled wealth."},
        {store="3 materials", play="Any realm", effect="Generate Store materials equal to twice controlled wealth."},
    },
    claims={
        {store="1 population", play="Any realm", effect="Discard or degrade one card. Then choose Develop 1 for 2 materials, or Conquer 1 for 2 population."},
        {store="1 population", play="Any realm", effect="Discard or degrade one card. Then choose Develop 2 for 3 materials, Conquer 2 for 3 population, or Conquer 1 for 2 population."},
        {store="2 population", play="Any realm", effect="Discard or degrade one card. Then either spend up to 2 materials for Develop 1 each, or up to 2 population for a separate Conquer 1 each."},
        {store="2 population", play="Any realm", effect="Either spend up to 2 materials for Develop 1 each, or up to 2 population for a separate Conquer 1 each."},
    },
}

-- Final face metadata. Holding wealth is not a
-- store value: Holding faces have no available resource icons.
for id, levels in pairs(CARD_TYPES) do
    for level, kind in ipairs(levels) do
        if kind == "Holding" then FACE_DATA[id][level].store = "No available resource" end
    end
end
FACE_DATA.works[1].play = "Crown-era only (The Crown/The Fellowship)"
FACE_DATA.works[4].store = "3 population"
FACE_DATA.council[1].store = "2 population"
FACE_DATA.customs[3].store = "2 materials"
FACE_DATA.customs[4].store = "3 materials"
FACE_DATA.kin[3].store = "2 materials"
FACE_DATA.lake[1].store = "1 material"
FACE_DATA.grail[3].store = "1 population"
FACE_DATA.camelot[4].store = "3 population"
FACE_DATA.gaul[2].requirement = "Pay 1 material"
FACE_DATA.gaul[4].requirement = "King Ban must be active"

local REALM_DATA = {
    {effect="The Crown uses Crown-era banners. Score 1 Renown per coin icon and include 5 unrest. At round end, abandon one controlled Holding of any wealth and pay 1 material to enter The Fellowship."},
    {effect="The Fellowship uses Crown-era banners. Score 1 Renown per prosperity. At round end, abandon controlled Holdings with at least 3 total wealth to enter Arthur's Empire."},
    {effect="Arthur's Empire uses Quest-era banners. Score 7 Renown per Ally. At round end, abandon controlled Holdings with at least 4 total wealth to enter The Grail Quest; Galahad must be active."},
    {effect="The Grail Quest uses Quest-era banners. Galahad is required to enter this realm. Score the sum of all active card levels divided by 3, rounded down."},
}
local CARD_BY_ID = {}
for _, card in ipairs(CARDS) do CARD_BY_ID[card.id] = card end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    return result
end

local function shuffle(items)
    for i = #items, 2, -1 do
        local j = math.random(i)
        items[i], items[j] = items[j], items[i]
    end
end

local function remove_at(items, index)
    if not index or index < 1 or index > #items then return nil end
    return table.remove(items, index)
end

local function plural(number, singular, plural_form)
    return tostring(number) .. " " .. (number == 1 and singular or (plural_form or singular .. "s"))
end

-- Expand compact resource shorthands for KOReader dialogs, which cannot
-- paint inline icons: "2M" -> "2 materials", "1P" -> "1 population",
-- standalone "M"/"P" -> "materials"/"population".
local function expandResLabel(label)
    local s = tostring(label or "")
    s = s:gsub("(%d+)([MP])%f[^%a]", function(n, k)
        n = tonumber(n)
        if k == "M" then
            return n .. " " .. (n == 1 and "material" or "materials")
        end
        return n .. " population"
    end)
    s = s:gsub("%f[%a]M%f[^%a]", "materials")
    s = s:gsub("%f[%a]P%f[^%a]", "population")
    return s
end


-- The game screen stays mounted for the entire active session. Card details
-- and other temporary workflows are modal overlays above it, so tap callbacks
-- never close and immediately replace the widget that is executing them.
local BeholdCamelotGameScreen = InputContainer:extend{
    name = "beholdcamelot_game",
    covers_fullscreen = true,
}

function BeholdCamelotGameScreen:init()
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.dimen = Geom:new{ x=0, y=0, w=self.screen_w, h=self.screen_h }
    self.tap_holdings = {}
    self.face_cache = {}
    self.face_cache_order = {}
    self.face_cache_limit = 40
    self.ges_events.Tap = { GestureRange:new{ ges="tap", range=self.dimen } }
    self.ges_events.Hold = { GestureRange:new{ ges="hold", range=self.dimen } }
end

function BeholdCamelotGameScreen:getSize()
    return self.dimen
end

function BeholdCamelotGameScreen:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
    return true
end

function BeholdCamelotGameScreen:onClose()
    self.plugin:confirmQuit()
    return true
end

function BeholdCamelotGameScreen:onCloseWidget()
    for _, cached in pairs(self.face_cache or {}) do cached:free() end
    self.face_cache = {}
    self.face_cache_order = {}
    if self.plugin.dialog == self then self.plugin.dialog = nil end
    UIManager:setDirty(nil, "full")
end

function BeholdCamelotGameScreen:addTapHolding(x, y, w, h, callback, hold_callback)
    self.tap_holdings[#self.tap_holdings + 1] = {
        rect=Geom:new{ x=x, y=y, w=w, h=h }, callback=callback, hold_callback=hold_callback,
    }
end

function BeholdCamelotGameScreen:onHold(_, ges)
    for index = #self.tap_holdings, 1, -1 do
        local holding = self.tap_holdings[index]
        if holding.hold_callback and holding.rect:contains(ges.pos) then
            holding.hold_callback()
            return true
        end
    end
    return true
end

function BeholdCamelotGameScreen:onTap(_, ges)
    for index = #self.tap_holdings, 1, -1 do
        local holding = self.tap_holdings[index]
        if holding.rect:contains(ges.pos) then
            holding.callback()
            return true
        end
    end
    return true
end

function BeholdCamelotGameScreen:drawText(bb, text, x, y, w, h, size, bold, color, align_left)
    text = tostring(text or "")
    if text == "" then return end
    w = math.max(1, math.floor(w))
    local face = Font:getFace("smallinfofont", math.max(5, math.floor(size)))
    local draw_text = text
    local measured = RenderText:sizeUtf8Text(0, w, face, draw_text, true, bold or false)
    if measured.x > w then
        draw_text = RenderText:truncateTextByWidth(draw_text, face, w, true, bold or false)
        measured = RenderText:sizeUtf8Text(0, w, face, draw_text, true, bold or false)
    end
    local face_h, ascender = face.ftsize:getHeightAndAscender()
    local text_h = math.ceil(face_h)
    local tx = align_left and math.floor(x) or math.floor(x + math.max(0, (w - measured.x) / 2))
    local ty = math.floor(y + math.max(0, (h - text_h) / 2))
    RenderText:renderUtf8Text(bb, tx, ty + math.floor(ascender + 0.5), face, draw_text,
        true, bold or false, color or Blitbuffer.COLOR_BLACK, w)
end

function BeholdCamelotGameScreen:drawButton(bb, button, x, y, w, h, scale)
    local border = math.max(1, math.floor(scale))
    local shade = button.enabled == false and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    bb:paintRect(x, y, w, h, shade)
    bb:paintBorder(x, y, w, h, border, Blitbuffer.COLOR_BLACK)
    local icon_w = button.hold_callback and math.max(14, math.floor(16 * scale)) or 0
    self:drawText(bb, button.text, x + 3, y + 2, w - 6 - icon_w, h - 4, 10, true,
        button.enabled == false and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK)
    if button.hold_callback then
        self:drawText(bb, "ⓘ", x + w - icon_w - 3, y + 2, icon_w, h - 4, 10, true,
            button.enabled == false and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK)
    end
    if button.enabled ~= false then self:addTapHolding(x, y, w, h, button.callback, button.hold_callback) end
end

local TYPE_SHADE = {
    Provision=Blitbuffer.COLOR_LIGHT_GRAY,
    Action=Blitbuffer.COLOR_DARK_GRAY,
    Holding=Blitbuffer.COLOR_GRAY,
    Court=Blitbuffer.COLOR_WHITE,
    Ally=Blitbuffer.COLOR_BLACK,
}

local function pairedLevel(level)
    return level % 2 == 1 and level + 1 or level - 1
end

local function shortPlay(value)
    if not value or value == "Any realm" then return "ANY REALM" end
    return value:gsub(" only %(.+%)", ""):upper()
end

-- Words that become inline keying icons in descriptive ("rich") text. A trailing
-- "icon"/"icons" word right after an icon is dropped, so "3 coin icons" paints
-- as "3 [coin icon]" instead of "3 [coin icon] icons".
local RICH_ICON_WORDS = {
    military = "military",
    transport = "transport",
    culture = "culture",
    coin = "coin", coins = "coin",
    crop = "crops", crops = "crops",
    luxury = "luxury",
    navy = "navy",
}

-- Symbol sequences that become resource icons in rich text: [M] materials,
-- [P] population (stored values on card bands), /\ holding wealth.
local RICH_SPECIAL = {
    ["[M]"] = "res_materials",
    ["[P]"] = "res_population",
    ["/\\"] = "res_wealth",
}

-- Split a paragraph into layout words; each word is a list of {text} / {icon} tokens.
local function richWords(paragraph)
    local words = {}
    for word in paragraph:gmatch("%S+") do
        local tokens = {}
        local i = 1
        while i <= #word do
            local seq_len = 0
            for seq, key in pairs(RICH_SPECIAL) do
                if word:sub(i, i + #seq - 1) == seq then
                    tokens[#tokens + 1] = { icon = key }
                    seq_len = #seq
                    break
                end
            end
            if seq_len > 0 then
                i = i + seq_len
            else
                local j = i
                if word:sub(i, i):match("%a") then
                while j <= #word and word:sub(j, j):match("%a") do j = j + 1 end
                local alpha = word:sub(i, j - 1)
                local key = RICH_ICON_WORDS[alpha:lower()]
                tokens[#tokens + 1] = key and { icon = key } or { text = alpha }
            else
                while j <= #word and not word:sub(j, j):match("%a") do j = j + 1 end
                tokens[#tokens + 1] = { text = word:sub(i, j - 1) }
            end
            i = j
            end
        end
        words[#words + 1] = tokens
    end
    local out = {}
    for _, tokens in ipairs(words) do
        local prev = out[#out]
        local first = tokens[1]
        if prev and prev[#prev].icon and first and first.text
            and first.text:lower():match("^icons?$") then
            table.remove(tokens, 1)
            if #tokens > 0 then out[#out + 1] = tokens end
        else
            out[#out + 1] = tokens
        end
    end
    return out
end

-- Count inline keying icons in descriptive text, by key (used by tests).
function BeholdCamelotGameScreen:richIconCounts(text)
    local counts = {}
    for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        for _, tokens in ipairs(richWords(paragraph)) do
            for _, t in ipairs(tokens) do
                if t.icon then counts[t.icon] = (counts[t.icon] or 0) + 1 end
            end
        end
    end
    return counts
end
-- Measure using the same DPI-scaled font used to paint, not character counts.
function BeholdCamelotGameScreen:layoutText(text, w, size, bold, rich)
    local font = Font:getFace("smallinfofont", size)
    local fh = font.ftsize:getHeightAndAscender()
    local lines = {}
    local function width(s) return RenderText:sizeUtf8Text(0, 100000, font, s, true, bold or false).x end
    if rich then
        -- Wrap token words; an icon token takes a ~1em square like a wide glyph.
        local icon_adv = math.max(8, math.ceil(fh) - 2)
        local space_w = width(" ")
        local function wordWidth(tokens)
            local tw = 0
            for _, t in ipairs(tokens) do tw = tw + (t.icon and icon_adv or width(t.text)) end
            return tw
        end
        for paragraph in (text .. "\n"):gmatch("(.-)\n") do
            local line, line_w = {}, 0
            local function flush()
                if #line > 0 then lines[#lines + 1] = line end
                line, line_w = {}, 0
            end
            for _, tokens in ipairs(richWords(paragraph)) do
                local tw = wordWidth(tokens)
                if tw > w then
                    -- Overlong word (icons never split): isolate it on its own line.
                    flush()
                    lines[#lines + 1] = { tokens }
                else
                    if line_w > 0 and line_w + space_w + tw > w then flush() end
                    if #line > 0 then line_w = line_w + space_w end
                    line[#line + 1] = tokens
                    line_w = line_w + tw
                end
            end
            flush()
        end
        return lines, math.ceil(fh) + 1
    end
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            local candidate = line == "" and word or line .. " " .. word
            if width(candidate) > w and line ~= "" then lines[#lines+1]=line; line="" end
            -- Split overlong words at UTF-8 character boundaries, never truncate.
            if width(word) > w then
                if line ~= "" then lines[#lines+1]=line; line="" end
                for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                    if width(line..char)>w and line~="" then lines[#lines+1]=line; line="" end
                    line=line..char
                end
            else line = line == "" and word or line .. " " .. word end
        end
        lines[#lines+1]=line
    end
    return lines, math.ceil(fh)+1
end

function BeholdCamelotGameScreen:drawFittedText(bb, text, x, y, w, h, preferred, bold, color, rich)
    local lines, lh, size
    for candidate=preferred,5,-1 do
        size=candidate
        lines,lh=self:layoutText(text,w,size,bold,rich)
        if #lines*lh<=h then break end
    end
    local capacity=math.max(0,math.floor(h/lh))
    for i=1,math.min(#lines,capacity) do
        local yy=y+(i-1)*lh
        if i==capacity and #lines>capacity then
            self:drawText(bb,"Tap card: Full text",x,yy,w,lh,size,bold,color,true)
        elseif rich then
            self:paintRichLine(bb,lines[i],x,yy,w,lh,size,bold,color)
        else
            self:drawText(bb,lines[i],x,yy,w,lh,size,bold,color,true)
        end
    end
    return #lines*lh<=h
end


-- Paint one rich-text line: token words laid out left to right, icons inline.
-- white selects white icon variants (dark bands); center centers the line in w.
function BeholdCamelotGameScreen:paintRichLine(bb, words, x, y, w, h, size, bold, color, white, center)
    local face = Font:getFace("smallinfofont", math.max(5, math.floor(size)))
    local function tw(s) return RenderText:sizeUtf8Text(0, 100000, face, s, true, bold or false).x end
    local space_w = tw(" ")
    local face_h, ascender = face.ftsize:getHeightAndAscender()
    local text_h = math.ceil(face_h)
    local icon_size = math.max(8, text_h - 2)
    local col = color or Blitbuffer.COLOR_BLACK
    local function tok_w(t) return t.icon and icon_size or tw(t.text) end
    local cx = math.floor(x)
    if center then
        local total = 0
        for wi, tokens in ipairs(words) do
            if wi > 1 then total = total + space_w end
            for _, t in ipairs(tokens) do total = total + tok_w(t) end
        end
        cx = math.floor(x + math.max(0, (w - total) / 2))
    end
    local baseline = math.floor(y + math.max(0, (h - text_h) / 2)) + math.floor(ascender + 0.5)
    for wi, tokens in ipairs(words) do
        if wi > 1 then cx = cx + space_w end
        for _, t in ipairs(tokens) do
            if t.icon then
                self:drawKeyIcon(bb, t.icon, math.floor(cx),
                    math.floor(y + math.max(0, (h - icon_size) / 2)), icon_size, white)
                cx = cx + icon_size
            else
                local ww = tw(t.text)
                RenderText:renderUtf8Text(bb, math.floor(cx), baseline, face, t.text,
                    true, bold or false, col, math.max(1, math.floor(x + w - cx)))
                cx = cx + ww
            end
        end
    end
end

-- Paint one keying icon; white selects the white variant for dark bands.
function BeholdCamelotGameScreen:drawKeyIcon(bb, key, x, y, size, white)
    keyIconWidget(key, size, white):paintTo(bb, x, y)
end

-- Paint a flat list of keying icon keys left to right; returns width used.
function BeholdCamelotGameScreen:drawKeyIcons(bb, keys, x, y, size, white)
    if #keys == 0 then return 0 end
    local gap = math.max(2, math.floor(size * 0.18))
    local cx = x
    for _, key in ipairs(keys) do
        self:drawKeyIcon(bb, key, cx, y, size, white)
        cx = cx + size + gap
    end
    return cx - x - gap
end

-- Card band resource summary, e.g. "2 [M] /\ 3"; rich text paints the symbols as icons.
function BeholdCamelotGameScreen:bandResources(id, level)
    local face = FACE_DATA[id] and FACE_DATA[id][level] or {}
    local resources = (face.store or ""):gsub("materials?", "[M]"):gsub("population", "[P]")
    if resources == "No available resource" then resources = "" end
    local wealth = HOLDING_WEALTH[id] and HOLDING_WEALTH[id][level]
    if wealth then resources = resources .. " /\\ " .. wealth end
    return resources
end

function BeholdCamelotGameScreen:drawFace(bb, id, level, x, y, w, h, compact, active)
    local card = CARD_BY_ID[id]
    local face = FACE_DATA[id] and FACE_DATA[id][level] or {}
    local card_type = CARD_TYPES[id] and CARD_TYPES[id][level] or "Unknown"
    local border = active and 3 or 1
    local band_h = math.max(24, math.floor(h * 0.20))
    local shade = TYPE_SHADE[card_type] or Blitbuffer.COLOR_LIGHT_GRAY
    local band_text = shade == Blitbuffer.COLOR_BLACK and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x, y, w, h, border, active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x + border, y + border, w - border * 2, band_h, shade)
    local icons={}
    for _,key in ipairs(Scoring.order) do
        local n=Scoring.faces[id][level].keys[key]
        for i=1,n or 0 do icons[#icons+1]=key end
    end
    local resources = self:bandResources(id, level)
    local row_h=math.floor(band_h/2)
    local left_w=math.floor(w*.16)
    local right_w=math.floor(w*.30)
    self:drawFittedText(bb,"L"..level,x+5,y+border,left_w-5,row_h,compact and 9 or 12,true,band_text)
    self:drawText(bb,card_type:upper(),x+left_w,y+border,w-left_w-right_w,row_h,compact and 8 or 11,true,band_text)
    self:paintRichLine(bb, richWords(resources), x+w-right_w, y+border, right_w-5, row_h,
        compact and 8 or 11, true, band_text, band_text == Blitbuffer.COLOR_WHITE, true)
    -- Keying icon images replace the old ASCII row; white variant on dark bands.
    do
        local icon_size = math.max(8, band_h-row_h-4)
        local white = band_text == Blitbuffer.COLOR_WHITE
        self:drawKeyIcons(bb, icons, x+5, y+border+row_h+2, icon_size, white)
    end
    -- PLAY state moves to the banner's second row, right side (was in body text).
    local play_text = "PLAY: " .. shortPlay(face.play)
    self:drawFittedText(bb, play_text, x+w-right_w, y+border+row_h, right_w-5, row_h,
        compact and 7 or 9, true, band_text)
    local name_y = y + band_h + border
    local name_h = math.max(22, math.floor(h * 0.20))
    local name_text = card.names[level]
    if self.plugin:isReminded(id) then name_text = "★ " .. name_text end
    self:drawFittedText(bb, name_text, x + 5, name_y, w - 10, name_h,
        compact and 14 or 19, true, Blitbuffer.COLOR_BLACK)
    local info_y = name_y + name_h
    local stats=Scoring.faces[id][level]
    local body={face.effect or "No printed action.",
        "Renown: "..Scoring.rules[id][level],"Unrest "..stats.unrest.." / Prosperity "..stats.prosperity}
    if face.requirement then body[#body+1]="DEVELOP: "..face.requirement end
    self:drawFittedText(bb,table.concat(body,"\n"),x+5,info_y,w-10,y+h-info_y-5,
        compact and 10 or 13,false,Blitbuffer.COLOR_BLACK,true)
end

function BeholdCamelotGameScreen:drawRotatedFace(bb, id, level, x, y, w, h, compact, active)
    local key = table.concat({id, level, w, h, compact and 1 or 0, active and 1 or 0, 180}, ":")
    local cached = self.face_cache[key]
    if cached then
        bb:blitFrom(cached, x, y, 0, 0, w, h)
        return
    end
    local temp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    temp:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    self:drawFace(temp, id, level, 0, 0, w, h, compact, active)
    local rotated = temp:rotatedCopy(180)
    bb:blitFrom(rotated, x, y, 0, 0, w, h)
    temp:free()
    self.face_cache[key] = rotated
    self.face_cache_order[#self.face_cache_order + 1] = key
    if #self.face_cache_order > self.face_cache_limit then
        local expired_key = table.remove(self.face_cache_order, 1)
        local expired = self.face_cache[expired_key]
        if expired then expired:free() end
        self.face_cache[expired_key] = nil
    end
end

function BeholdCamelotGameScreen:drawDoubleCard(bb, id, x, y, w, h, compact, active_level)
    local level = active_level or self.plugin.game.levels[id]
    local other = pairedLevel(level)
    local half_h = math.floor(h / 2)
    self:drawFace(bb, id, level, x, y, w, half_h, compact, true)
    self:drawRotatedFace(bb, id, other, x, y + half_h, w, h - half_h, compact, false)
    bb:paintBorder(x, y, w, h, compact and 1 or 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + half_h - 1, w, 2, Blitbuffer.COLOR_BLACK)
end

function BeholdCamelotGameScreen:drawDeckTop(bb, x, y, w, h, compact)
    local top = self.plugin.game.deck[1]
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x, y, w, h, 2, Blitbuffer.COLOR_BLACK)
    if not top then
        self:drawText(bb, "PILE EMPTY", x, y, w, h, 9, true)
    elseif top.marker == "realm" then
        self:drawText(bb, "REALM", x, y, w, math.floor(h / 2), 10, true)
        self:drawText(bb, "ROUND END", x, y + math.floor(h / 2), w, math.ceil(h / 2), 8, false)
    else
        self:drawFace(bb, top.id, self.plugin.game.levels[top.id], x, y, w, h, true, true)
    end
end

function BeholdCamelotGameScreen:focus(index)
    self.view_mode = "focus"
    self.selected_index = index
    self.plugin:refreshBoard(false)
end

function BeholdCamelotGameScreen:overview()
    self.view_mode = "overview"
    self.plugin:refreshBoard(true)
end

function BeholdCamelotGameScreen:moveFocus(delta)
    local count = #self.plugin.game.hand
    if count == 0 then self.selected_index = 0; return end
    local current = self.selected_index or 1
    if current == 0 then current = delta > 0 and 1 or count
    else current = ((current - 1 + delta) % count) + 1 end
    self.selected_index = current
    self.plugin:refreshBoard(false)
end

function BeholdCamelotGameScreen:drawHeader(bb, scale, margin, deck_w, header_h)
    local plugin, game = self.plugin, self.plugin.game
    local w = self.screen_w
    local deck_x = w - deck_w - margin
    local text_w = deck_x - margin * 2
    self:drawText(bb, "BEHOLD: CAMELOT", margin, margin, text_w,
        math.floor(28 * scale), 16, true, nil, true)
    local materials, population, slots = plugin:storedSummary()
    local line_h = math.max(18, math.floor(21 * scale))
    local sy = margin + math.floor(29 * scale)
    self:drawText(bb, string.format("R%d/%d  %s  vs %s", game.round, game.max_rounds,
        REALM_NAMES[game.realm_level], game.rival), margin, sy, text_w, line_h, 10, true, nil, true)
    sy = sy + line_h
    self:paintRichLine(bb, richWords(string.format("Deck %d  Stored %d/4 [M]%d [P]%d  Holdings %d/4", #game.deck,
        slots, materials, population, #game.controlled)), margin, sy, text_w, line_h, 8, false)
    sy = sy + line_h
    local score = plugin:liveScore()
    self:drawText(bb, string.format("SCORE %d%s  (tap for breakdown)", score.total,
        score.rival and (" / Rival " .. score.rival) or ""), margin, sy, text_w, line_h, 9, true, nil, true)
    self:addTapHolding(margin, sy, text_w, line_h, function() plugin:showScoring() end)
    local top = game.deck[1]
    local pile_label = "PILE TOP"
    if top and top.stored then
        pile_label = pile_label .. string.format(" — STORED %s%d",
            top.stored.kind == "materials" and "[M]" or "[P]", top.stored.amount)
    end
    local pile_h = math.max(15, math.floor(18 * scale))
    self:paintRichLine(bb, richWords(pile_label), deck_x, margin, deck_w, pile_h, 8, true, nil, false, true)
    local deck_y = margin + pile_h
    self:drawDeckTop(bb, deck_x, deck_y, deck_w, header_h - deck_y - margin, true)
    self:addTapHolding(deck_x, deck_y, deck_w, header_h - deck_y - margin, function()
        if top and top.marker == "realm" then
            plugin:showRealm()
        else
            self:focus(0)
        end
    end)
end

function BeholdCamelotGameScreen:paintOverview(bb, scale, margin, gap, header_h)
    local w, h = self.screen_w, self.screen_h
    local controls = self.plugin:gameActionButtons()
    local control_cols, control_rows = 3, math.ceil(#controls / 3)
    local control_h = math.max(42, math.floor(48 * scale))
    local controls_total = control_rows * control_h + (control_rows - 1) * gap
    local cards_y = header_h + gap
    local cards_h = h - cards_y - controls_total - margin - gap
    local count = #self.plugin.game.hand
    local card_cols = count > 9 and 4 or 3
    local card_rows = math.max(2, math.ceil(count / card_cols))
    local card_w = math.floor((w - margin * 2 - gap * (card_cols - 1)) / card_cols)
    local card_h = math.floor((cards_h - gap * (card_rows - 1)) / card_rows)
    for index, id in ipairs(self.plugin.game.hand) do
        local col, row = (index - 1) % card_cols, math.floor((index - 1) / card_cols)
        local cx, cy = margin + col * (card_w + gap), cards_y + row * (card_h + gap)
        self:drawDoubleCard(bb, id, cx, cy, card_w, card_h, true)
        local chosen = index
        self:addTapHolding(cx, cy, card_w, card_h, function() self:focus(chosen) end)
    end
    local controls_y = h - controls_total - margin
    local control_w = math.floor((w - margin * 2 - gap * (control_cols - 1)) / control_cols)
    for index, button in ipairs(controls) do
        local col, row = (index - 1) % control_cols, math.floor((index - 1) / control_cols)
        self:drawButton(bb, button, margin + col * (control_w + gap),
            controls_y + row * (control_h + gap), control_w, control_h, scale)
    end
end

function BeholdCamelotGameScreen:focusedCard()
    local index = self.selected_index or 1
    if index == 0 then
        local top = self.plugin.game.deck[1]
        return top and top.id or nil, 0
    end
    if #self.plugin.game.hand == 0 then return nil, 0 end
    if index > #self.plugin.game.hand then index = #self.plugin.game.hand end
    self.selected_index = index
    return self.plugin.game.hand[index], index
end

function BeholdCamelotGameScreen:paintFocus(bb, scale, margin, gap, header_h)
    local w, h = self.screen_w, self.screen_h
    local id, index = self:focusedCard()
    -- A Realm marker has no physical card face.  Avoid changing the view while
    -- painting: doing so previously left the lower board blank until another tap.
    if not id then
        self.view_mode = "overview"
        self:paintOverview(bb, scale, margin, gap, header_h)
        return
    end
    local tab_h = math.max(26, math.floor(31 * scale))
    local tabs_y = header_h + gap
    local tab_w = math.floor((w - margin * 2 - gap * math.max(0, #self.plugin.game.hand - 1))
        / math.max(1, #self.plugin.game.hand))
    local show_playable = self.plugin:showPlayableEnabled()
    for hand_index, hand_id in ipairs(self.plugin.game.hand) do
        local tx = margin + (hand_index - 1) * (tab_w + gap)
        local selected = hand_index == index
        local is_playable = show_playable and self.plugin:isCardPlayable(hand_id)
        bb:paintRect(tx, tabs_y + (selected and 0 or math.floor(tab_h * 0.25)), tab_w,
            selected and tab_h or math.floor(tab_h * 0.75), selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_LIGHT_GRAY)
        bb:paintBorder(tx, tabs_y + (selected and 0 or math.floor(tab_h * 0.25)), tab_w,
            selected and tab_h or math.floor(tab_h * 0.75), 1, Blitbuffer.COLOR_BLACK)
        self:drawText(bb, string.format("%d %s", self.plugin.game.levels[hand_id], CARD_BY_ID[hand_id].names[self.plugin.game.levels[hand_id]]),
            tx + 2, tabs_y, tab_w - 4, tab_h, 7, selected, nil, true)
        -- Playability icon: check for playable, X for not (when setting enabled)
        if show_playable then
            local icon = is_playable and "✓" or "✗"
            self:drawText(bb, icon, tx + tab_w - 14, tabs_y + 2, 12, 10, false, nil, true)
        end
        local chosen = hand_index
        self:addTapHolding(tx, tabs_y, tab_w, tab_h, function() self:focus(chosen) end)
    end
    local action_buttons
    if index == 0 then
        if self.plugin.game.awaiting_draw then
            action_buttons = {{
                text=string.format("Draw one (%d/5)", #self.plugin.game.hand),
                callback=function() self.plugin:manualDraw() end,
            }}
        else
            local playable_text = self.plugin:showPlayableEnabled() and _("Hide playable") or _("Show playable")
            action_buttons = {
                {
                    text=_("Discard top / end turn"),
                    callback=function() self.plugin:endTurnTop() end,
                },
                {
                    text=playable_text,
                    callback=function()
                        self.plugin:toggleShowPlayable()
                        self.plugin:refreshBoard()
                    end,
                },
            }
        end
    else
        action_buttons = self.plugin:focusedCardActions(index)
    end
    action_buttons[#action_buttons+1]={text="Inspect / flip",callback=function() self.plugin:previewCard(id) end}
    local action_cols, action_rows = 3, math.ceil(#action_buttons / 3)
    local action_h = math.max(40, math.floor(46 * scale))
    local actions_total = action_rows * action_h + (action_rows - 1) * gap
    local card_y = tabs_y + tab_h + gap
    local card_h = h - card_y - actions_total - margin - gap
    local card_w = math.min(math.floor(w * 0.74), math.floor(card_h * 0.72))
    local card_x = math.floor((w - card_w) / 2)
    self:drawDoubleCard(bb, id, card_x, card_y, card_w, card_h, false)
    self:addTapHolding(card_x, card_y, card_w, card_h, function() self:overview() end)
    local text_w = math.max(54, math.floor(card_w * 0.20))
    local text_h = math.max(24, math.floor(29 * scale))
    local text_x = card_x + card_w - text_w - 4
    local text_y = card_y + 4
    bb:paintRect(text_x, text_y, text_w, text_h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(text_x, text_y, text_w, text_h, 1, Blitbuffer.COLOR_BLACK)
    self:drawText(bb, "FULL TEXT", text_x + 2, text_y + 1, text_w - 4, text_h - 2, 7, true)
    self:addTapHolding(text_x, text_y, text_w, text_h, function()
        self.plugin:showFullCardText(id)
    end)
    local arrow_w = card_x - margin - gap
    if arrow_w > 20 then
        self:drawText(bb, "‹", margin, card_y, arrow_w, card_h, 30, true)
        self:addTapHolding(margin, card_y, arrow_w, card_h, function() self:moveFocus(-1) end)
        self:drawText(bb, "›", card_x + card_w + gap, card_y, arrow_w, card_h, 30, true)
        self:addTapHolding(card_x + card_w + gap, card_y, arrow_w, card_h, function() self:moveFocus(1) end)
    end
    local actions_y = h - actions_total - margin
    local action_w = math.floor((w - margin * 2 - gap * (action_cols - 1)) / action_cols)
    for action_index, button in ipairs(action_buttons) do
        local col, row = (action_index - 1) % action_cols, math.floor((action_index - 1) / action_cols)
        self:drawButton(bb, button, margin + col * (action_w + gap),
            actions_y + row * (action_h + gap), action_w, action_h, scale)
    end
end

function BeholdCamelotGameScreen:paintTo(bb, x, y)
    local w, h = self.screen_w, self.screen_h
    local scale = math.min(w / 600, h / 800)
    local margin = math.max(6, math.floor(8 * scale))
    local gap = math.max(3, math.floor(5 * scale))
    local deck_w = math.max(105, math.floor(w * 0.29))
    local header_h = math.max(105, math.floor(140 * scale))
    self.tap_holdings = {}
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    self:drawHeader(bb, scale, margin, deck_w, header_h)
    if self.view_mode == "focus" then
        self:paintFocus(bb, scale, margin, gap, header_h)
    else
        self.view_mode = "overview"
        self:paintOverview(bb, scale, margin, gap, header_h)
    end
end

function BeholdCamelot:init()
    math.randomseed(os.time() + tonumber(tostring({}):match("0x(%x+)") or "0", 16) % 997)
    math.random(); math.random(); math.random()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/beholdcamelot.lua")
    self.game = self.settings:readSetting("game")
    self.undo_game = self.settings:readSetting("action_undo")
    if self.game then
        if self.game.action and self.game.action.engine_version~=11 then
            self.settings:saveSetting("legacy_in_progress_backup",copy(self.game))
            self.settings:flush()
            self.legacy_action_blocked=true
        end
        if self.game.awaiting_draw == nil then self.game.awaiting_draw = false end
        self.game.game_difficulty=self.game.game_difficulty or "Normal"
        self.game.rival_difficulty=self.game.rival_difficulty or "Normal"
        self.game.rival_modifier=self.game.rival_modifier or 0
        if self.game.foresight==nil then self.game.foresight=false end
        if self.game.fluid_round==nil then self.game.fluid_round=false end
        if self.game.reminders==nil then self.game.reminders={} end
    end
    self.ui.menu:registerToMainMenu(self)
end

function BeholdCamelot:addToMainMenu(menu_items)
    menu_items.behold_camelot = {
        text = _("Behold: Camelot"),
        sorting_hint = "more_tools",
        callback = function() self:showMainMenu() end,
    }
end

function BeholdCamelot:save()
    self.settings:saveSetting("game", self.game)
    self.settings:saveSetting("action_undo",self.undo_game)
    self.settings:flush()
end

function BeholdCamelot:checkpoint()
    if self.game then self.undo_game = copy(self.game) end
end

function BeholdCamelot:undo()
    if not self.undo_game then
        self:message("Nothing to undo.")
        return
    end
    self.game, self.undo_game = self.undo_game, copy(self.game)
    self:save()
    self:showGame()
end

function BeholdCamelot:closeDialog()
    self:closeOverlay()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
    _restoreSimpleUITopbar()
end

function BeholdCamelot:closeOverlay(refresh)
    if self.overlay then
        UIManager:close(self.overlay)
        self.overlay = nil
    end
    if refresh then self:refreshBoard(true) end
end

-- KOReader's stock ButtonDialog owns its own drawing.  Mark long-pressable
-- choices in their label, while the custom game board draws the same symbol at
-- the right edge of its buttons.
function BeholdCamelot:markHoldButtons(rows)
    for _, row in ipairs(rows or {}) do
        if type(row) == "table" then
            if row.hold_callback and row.text and not tostring(row.text):find(HOLD_INFO, 1, true) then
                row.text = tostring(row.text) .. HOLD_INFO
            else
                self:markHoldButtons(row)
            end
        end
    end
end

function BeholdCamelot:showOverlay(widget)
    self:closeOverlay(false)
    self:markHoldButtons(widget.buttons)
    self.overlay = widget
    UIManager:show(widget)
end

function BeholdCamelot:refreshBoard(full)
    if self.dialog and self.dialog.name == "beholdcamelot_game" then
        UIManager:setDirty(self.dialog, function()
            return full and "full" or "ui", self.dialog.dimen
        end)
    end
end

function BeholdCamelot:message(text, after)
    UIManager:show(InfoMessage:new{ text=text, timeout=2, callback=after })
end

function BeholdCamelot:showNotice(title, text)
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=title .. "\n\n" .. text,
        buttons={{{
            text=_("OK"),
            callback=function() self:closeOverlay(true) end,
        }}},
    })
end

function BeholdCamelot:cardName(id)
    local card = CARD_BY_ID[id]
    local level = self.game.levels[id] or card.start
    return card.names[level]
end

function BeholdCamelot:cardLabel(id)
    return string.format("L%d  %s", self.game.levels[id], self:cardName(id))
end

function BeholdCamelot:cardType(id)
    local level = self.game.levels[id]
    local types = CARD_TYPES[id]
    return types and types[level] or "Unknown"
end

function BeholdCamelot:faceData(id)
    local faces = FACE_DATA[id]
    return faces and faces[self.game.levels[id]] or {}
end

function BeholdCamelot:cardDetails(id)
    local face = self:faceData(id)
    local wealth = self:holdingWealth(id)
    local lines = {
        self:cardLabel(id) .. "  [" .. self:cardType(id) .. "]",
        "STORE VALUE: " .. (face.store or "Not transcribed"),
        "PLAY / CONQUER: " .. (face.play or "Any realm"),
    }
    if wealth then lines[#lines + 1] = "HOLDING WEALTH: " .. wealth end
    if face.requirement then lines[#lines + 1] = "DEVELOP: " .. face.requirement end
    lines[#lines + 1] = "EFFECT: " .. (face.effect or "No printed action.")
    lines[#lines + 1] = "ICONS: " .. Scoring.icons(id, self.game.levels[id])
    lines[#lines + 1] = "CURRENT Renown: " .. self:liveScore().cards[id]
    lines[#lines + 1] = "Renown RULE: " .. Scoring.rules[id][self.game.levels[id]]
    return table.concat(lines, "\n")
end

-- A separate modal keeps the pending chooser mounted and never touches game state.
local CardPreview = BeholdCamelotGameScreen:extend{modal=true,name="beholdcamelot_preview"}
-- Escape/Back dismisses the preview, like KOReader's own dialogs.
CardPreview.key_events = { Close = { { Device.input.group.Back } } }

function CardPreview:onClose()
    UIManager:close(self)
    return true
end

function CardPreview:paintTo(bb,x,y)
    local w,h=self.screen_w,self.screen_h
    local margin=math.max(8,math.floor(w/75))
    local button_h=math.max(42,math.floor(h*.055))
    self.tap_holdings={}
    bb:paintRect(x,y,w,h,Blitbuffer.COLOR_WHITE)
    self:drawText(bb,"PREVIEW ONLY - game level unchanged",margin,margin,w-2*margin,button_h,10,true)
    local card_y=margin+button_h
    local card_h=h-card_y-button_h*2-margin*4
    local card_w=math.min(w-margin*2,math.floor(card_h*.72))
    self:drawDoubleCard(bb,self.card_id,math.floor((w-card_w)/2),card_y,card_w,card_h,false,self.preview_level)
    local function redraw() UIManager:setDirty(self,"ui") end
    local buttons={
        {text="Flip side",callback=function() self.preview_level=((self.preview_level+1)%4)+1; redraw() end},
        {text="Rotate",callback=function() self.preview_level=pairedLevel(self.preview_level); redraw() end},
        {text="Full text",callback=function()
            local id,l=self.card_id,self.preview_level
            local d=FACE_DATA[id][l]
            local wealth=HOLDING_WEALTH[id] and HOLDING_WEALTH[id][l]
            UIManager:show(TextViewer:new{modal=true,title="Preview: "..CARD_BY_ID[id].names[l],
                text="L"..l.." "..CARD_TYPES[id][l].."\nSTORE: "..d.store.."\nPLAY: "..(d.play or "Any realm")
                    ..(wealth and "\nWEALTH: "..wealth or "").."\n"..(d.effect or "No printed action.")
                    .."\n"..Scoring.icons(id,l).."\nVP: "..Scoring.rules[id][l]
                    ..(d.requirement and "\nDEVELOP: "..d.requirement or "")})
        end},
        {text="Back to game / selection",callback=function() self:onClose() end},
    }
    local bw=math.floor((w-margin*3)/2)
    for i,b in ipairs(buttons) do
        self:drawButton(bb,b,margin+((i-1)%2)*(bw+margin),h-margin-button_h*2-margin+math.floor((i-1)/2)*(button_h+margin),bw,button_h,1)
    end
end

function BeholdCamelot:previewCard(id)
    if not id or not CARD_BY_ID[id] then return end
    UIManager:show(CardPreview:new{plugin=self,card_id=id,preview_level=self.game.levels[id]})
end

-- Realm, rival, and icon information is deliberately a drawn three-page view rather
-- than a scrolling text dialog: the Realm page keeps all four upgrade paths
-- visible together, while the Rival page keeps the live arithmetic together.
local RealmRivalScreen = BeholdCamelotGameScreen:extend{modal=true,name="beholdcamelot_realm_rival"}
-- Escape/Back dismisses the Realm/Rival/Icons pages, like KOReader's own dialogs.
RealmRivalScreen.key_events = { Close = { { Device.input.group.Back } } }

-- NV Script banners supplied by the user from patorjk.com's TAAG.
local ASCII_TITLES = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "") .. "titles.lua")

function RealmRivalScreen:drawAsciiTitle(bb, text, x, y, w, scale)
    local lines = {}
    for line in ((ASCII_TITLES[text] or text) .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line:gsub("%s+$", "")
    end
    while lines[#lines] == "" do table.remove(lines) end
    local face, line_h, ascender, widest
    -- Font:getFace already applies DPI scaling. Measure every row, including
    -- descenders, and keep the whole title inside its allocated header.
    local max_h = math.floor(self.screen_h * 0.22)
    for size = 18, 1, -1 do
        face = Font:getFace("smallinfont", size)
        local face_h
        face_h, ascender = face.ftsize:getHeightAndAscender()
        line_h = math.ceil(face_h)
        widest = 0
        for _, line in ipairs(lines) do
            widest = math.max(widest, RenderText:sizeUtf8Text(0, 100000, face, line, false, false).x)
        end
        if widest <= w - 4 and line_h * #lines <= max_h then break end
    end
    -- Center the complete canvas, never individual rows: short rows must keep
    -- their original left edge or the supplied artwork is destroyed.
    -- Pad the top so the tallest glyphs of the first row never clip against
    -- the header edge; the supplied artwork itself is untouched.
    local top_pad = math.max(2, math.floor(3 * scale))
    local tx = math.floor(x + math.max(0, (w - widest) / 2))
    for row, line in ipairs(lines) do
        RenderText:renderUtf8Text(bb, tx, top_pad + y + (row - 1) * line_h + math.floor(ascender + .5),
            face, line, false, false, Blitbuffer.COLOR_BLACK, w)
    end
    return top_pad + line_h * #lines + math.max(4, math.floor(4 * scale))
end

function RealmRivalScreen:onClose()
    if self.plugin.overlay == self then self.plugin.overlay = nil end
    UIManager:close(self)
    self.plugin:refreshBoard(true)
    return true
end

function RealmRivalScreen:realmCellText(level)
    local name = REALM_NAMES[level]
    if level == 4 then
        return REALM_DATA[level].effect .. "\n\nFINAL REALM: no further upgrade."
    end
    local upgrades = {
        "UPGRADE TO THE FELLOWSHIP: abandon 1 controlled Holding of any wealth and pay 1 material.",
        "UPGRADE TO ARTHUR'S EMPIRE: abandon controlled Holdings totaling exactly 3 wealth.",
        "UPGRADE TO THE GRAIL QUEST: abandon controlled Holdings totaling exactly 4 wealth; Galahad must be active.",
    }
    local description = REALM_DATA[level].effect:gsub(" At round end,.*$", "")
    return description .. "\n\nAT ROUND END — " .. upgrades[level]
end

function RealmRivalScreen:drawRealmPage(bb, scale, margin, gap, controls_y, control_h)
    local w = self.screen_w
    local art_h = self:drawAsciiTitle(bb,"The Realm",margin,margin,w-margin*2,scale) + gap
    local art = { "      /\\", "     /  \\", "    /____\\", "    | [] |", "   _|____|_" }
    -- The title itself is the decorative element; the old house glyph is no
    -- longer painted so its space can belong to the four realm descriptions.
    local grid_y = margin + art_h
    local grid_h = controls_y - gap - grid_y
    local cell_w = math.floor((w - margin * 2 - gap) / 2)
    local cell_h = math.floor((grid_h - gap) / 2)
    for level = 1, 4 do
        local col, row = (level - 1) % 2, math.floor((level - 1) / 2)
        local x, y = margin + col * (cell_w + gap), grid_y + row * (cell_h + gap)
        local current = level == self.plugin.game.realm_level
        bb:paintRect(x, y, cell_w, cell_h, current and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE)
        bb:paintBorder(x, y, cell_w, cell_h, current and 3 or 1, Blitbuffer.COLOR_BLACK)
        self:drawText(bb, (current and "* " or "") .. REALM_NAMES[level], x + 4, y + 3, cell_w - 8,
            math.max(18, math.floor(20 * scale)), 14, true)
        self:drawFittedText(bb, self:realmCellText(level), x + 5, y + math.max(20, math.floor(23 * scale)),
            cell_w - 10, cell_h - math.max(25, math.floor(28 * scale)), 18, false, Blitbuffer.COLOR_BLACK, true)
    end
    self:drawButton(bb, {text="RIVAL ›", callback=function() self.page=2; UIManager:setDirty(self,"ui") end},
        margin, controls_y, math.floor((w - margin * 3) / 2), control_h, scale)
    self:drawButton(bb, {text="BACK", callback=function() self:onClose() end},
        math.floor((w + margin) / 2), controls_y, math.floor((w - margin * 3) / 2), control_h, scale)
end

function RealmRivalScreen:drawRivalPage(bb, scale, margin, gap, controls_y, control_h)
    local w = self.screen_w
    local art_h = self:drawAsciiTitle(bb,self.plugin.game.rival,margin,margin,w-margin*2,scale) + gap
    local art = { [=[      .-^^^^-.]=], [=[     /  o  o  \]=], [=[    |    /\    |]=], [=[    |   \____/  |]=], [=[     \  /||\  /]=], [=[      '------']=] }
    -- The rival name is the heading; keep the score panel free for details.
    local score = self.plugin:liveScore()
    local lines = {}
    if not score.rival then
        lines[#lines + 1] = "No rival score. Maximize Camelot's Renown."
        lines[#lines + 1] = "Camelot: " .. score.total .. " Renown"
    else
        local difficulty
        for _, category in ipairs(score.rival_breakdown) do
            if category.label == "Base" then
                lines[#lines + 1]="Base: "..category.points
            elseif category.label == "Unrest" then
                lines[#lines + 1]="Your Unrest: "..score.unrest
                lines[#lines + 1]="Your Prosperity: "..score.prosperity
            elseif category.label:find("Rival difficulty:",1,true) then
                difficulty=category.label..": "..string.format("%+d",category.points)
            else
                -- Labels already name the icon ("Crops", "navy"); no symbol needed.
                lines[#lines + 1]=category.label..": "..category.formula..": "..category.points
            end
        end
        if difficulty then lines[#lines + 1]=difficulty end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "RIVAL TOTAL: " .. score.rival .. " Renown"
        lines[#lines + 1] = "CAMELOT: " .. score.total .. " Renown"
        lines[#lines + 1] = "MARGIN: " .. string.format("%+d", score.total - score.rival) .. " (ties lose)"
    end
    self:drawFittedText(bb, table.concat(lines, "\n"), margin + 4, margin + art_h, w - margin * 2 - 8,
        controls_y - gap - (margin + art_h), 18, false, Blitbuffer.COLOR_BLACK, true)
    local button_w = math.floor((w - margin * 2 - gap * 2) / 3)
    self:drawButton(bb, {text="‹ REALM", callback=function() self.page=1; UIManager:setDirty(self,"ui") end},
        margin, controls_y, button_w, control_h, scale)
    self:drawButton(bb, {text="ICONS ›", callback=function() self.page=3; UIManager:setDirty(self,"ui") end},
        margin + button_w + gap, controls_y, button_w, control_h, scale)
    self:drawButton(bb, {text="BACK", callback=function() self:onClose() end},
        margin + (button_w + gap) * 2, controls_y, button_w, control_h, scale)
end

function RealmRivalScreen:drawIconsPage(bb, scale, margin, gap, controls_y, control_h)
    local w = self.screen_w
    local title_h = math.floor(38 * scale)
    self:drawText(bb, "KEYING ICONS", margin, margin, w-margin*2, title_h, 22, true)
    local intro_h = math.floor(76 * scale)
    self:drawFittedText(bb,
        "Count icons on active card faces throughout your civilization, including the pile. Each printed symbol counts once. Icons matter when a card or scoring rule refers to them.",
        margin+5, margin+title_h, w-margin*2-10, intro_h, 14, false, nil, true)
    local keying = {
        {"military", "Military", "A sword behind a shield."},
        {"transport", "Transport", "Count each transport icon for rules that refer to transport."},
        {"culture", "Culture", "Count each culture icon for rules that refer to culture."},
        {"coin", "Coin", "A keying icon, not stored materials or population."},
        {"crops", "Crops", "A keying icon, separate from prosperity."},
        {"luxury", "Luxury", "Count each luxury icon for luxury-based scoring."},
        {"navy", "Navy", "Count each navy icon for rules that refer to navy."},
    }
    local resources = {
        {"res_materials", "Materials", "Stored goods, shown on card bands."},
        {"res_population", "Population", "Stored people, shown on card bands."},
        {"res_wealth", "Holding wealth", "A Holding's value, shown on card bands."},
    }
    local sections = {
        { title = nil, entries = keying },
        { title = "RESOURCES", entries = resources },
    }
    local start_y = margin + title_h + intro_h + gap
    local header_h = math.floor(24 * scale)
    local total_rows = #keying + #resources
    local row_h = math.floor((controls_y - gap - start_y - header_h) / total_rows)
    local symbol_w = math.floor(w * .20)
    local y = start_y
    for _, section in ipairs(sections) do
        if section.title then
            self:drawText(bb, section.title, margin, y, w - margin * 2, header_h, 14, true, nil, true)
            y = y + header_h
        end
        for _, entry in ipairs(section.entries) do
            bb:paintBorder(margin, y, w-margin*2, row_h, 1, Blitbuffer.COLOR_DARK_GRAY)
            local icon_size = math.max(8, math.min(row_h-8, symbol_w-12))
            self:drawKeyIcon(bb, entry[1], margin+4+math.floor((symbol_w-8-icon_size)/2),
                y+math.floor((row_h-icon_size)/2), icon_size, false)
            local text_x = margin+symbol_w
            local name_h = math.floor(row_h*.40)
            self:drawText(bb, entry[2], text_x, y+2, w-margin-text_x-5, name_h, 18, true, nil, true)
            self:drawFittedText(bb, entry[3], text_x, y+name_h, w-margin-text_x-5, row_h-name_h-4, 14, false, nil, true)
            y = y + row_h
        end
    end
    self:drawButton(bb, {text="‹ RIVAL", callback=function() self.page=2; UIManager:setDirty(self,"ui") end},
        margin, controls_y, math.floor((w - margin * 3) / 2), control_h, scale)
    self:drawButton(bb, {text="BACK", callback=function() self:onClose() end},
        math.floor((w + margin) / 2), controls_y, math.floor((w - margin * 3) / 2), control_h, scale)
end

function RealmRivalScreen:paintTo(bb, x, y)
    local w, h = self.screen_w, self.screen_h
    local scale = math.min(w / 600, h / 800)
    local margin = math.max(6, math.floor(8 * scale))
    local gap = math.max(3, math.floor(5 * scale))
    local control_h = math.max(40, math.floor(46 * scale))
    local controls_y = h - margin - control_h
    self.tap_holdings = {}
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    if self.page == 3 then self:drawIconsPage(bb, scale, margin, gap, controls_y, control_h)
    elseif self.page == 2 then self:drawRivalPage(bb, scale, margin, gap, controls_y, control_h)
    else self:drawRealmPage(bb, scale, margin, gap, controls_y, control_h) end
end

function BeholdCamelot:confirmQuit()
    UIManager:show(ConfirmBox:new{
        text="Are you sure you want to quit? Your game will be saved.",
        ok_text="Save & quit",cancel_text="Keep playing",
        ok_callback=function() self:save(); self:closeOverlay(false); self:closeDialog() end,
    })
end

function BeholdCamelot:showFullCardText(id)
    if not id or not CARD_BY_ID[id] then return end
    self:showOverlay(TextViewer:new{
        modal=true,
        title=self:cardName(id),
        text=self:cardDetails(id),
    })
end

function BeholdCamelot:printedStore(id)
    local value = self:faceData(id).store or ""
    local amount = tonumber(value:match("(%d+)"))
    local kind = value:find("material", 1, true) and "materials" or
        (value:find("population", 1, true) and "population" or nil)
    return kind, amount
end

function BeholdCamelot:holdingWealth(id, level)
    level = level or self.game.levels[id]
    return HOLDING_WEALTH[id] and HOLDING_WEALTH[id][level] or nil
end

function BeholdCamelot:controlledWealth()
    local total = 0
    for _, id in ipairs(self.game.controlled) do total = total + (self:holdingWealth(id) or 0) end
    return total
end

function BeholdCamelot:isCrownEra()
    return self.game.realm_level <= 2
end

function BeholdCamelot:isPlayLegal(id, level, strict_banner)
    level = level or self.game.levels[id]
    local face = FACE_DATA[id] and FACE_DATA[id][level] or {}
    local restriction = face.play or "Any realm"
    if restriction:find("The Crown only", 1, true) then return self.game.realm_level == 1 end
    if restriction:find("Crown-era only", 1, true) then return self:isCrownEra() end
    if restriction:find("Quest-era only", 1, true) then
        if not self:isCrownEra() then return true end
        -- The Last Battle explicitly suspends Quest-era play banners while active.
        return not strict_banner and self.game.levels.kin == 4
    end
    return true
end

function BeholdCamelot:actionGeneratesDraw(option)
    return option.draw or option.draw_to or option.draw_manual or option.discard_draw_production
        or option.marches_discard or option.counsel=="draw"
end

function BeholdCamelot:actionOptions(id)
    local levels = ACTIONS[id]
    return levels and levels[self.game.levels[id]] or {{label="Play as a passive card", passive=true}}
end

-- Returns true if the card in hand has a playable (non-passive) action and is legal to play.
-- Checks resource costs (materials/population), discard/degrade availability.
-- Used for the "show playable cards" highlight setting.
function BeholdCamelot:isCardPlayable(id)
    if not self:isPlayLegal(id) then return false end
    local options = self:actionOptions(id)
    local materials, population = self:storedSummary()
    local hand_size = #self.game.hand
    
    -- Check if any card can be degraded (level > 1)
    local has_degradable = false
    for card_id, level in pairs(self.game.levels) do
        if level > 1 then has_degradable = true; break end
    end
    
    for _, option in ipairs(options) do
        if not option.passive then
            local costs = option.costs or {}
            local can_afford = true
            
            -- Check material costs
            if (costs.materials or 0) > materials then can_afford = false end
            -- Check population costs
            if (costs.population or 0) > population then can_afford = false end
            -- Check discard costs (need other cards in hand to discard)
            if (costs.discard or 0) >= hand_size then can_afford = false end
            -- Check degrade costs (need a card with level > 1)
            if (costs.degrade or 0) > 0 and not has_degradable then can_afford = false end
            -- Check degrade_court (need a Court card with level > 1)
            if (costs.degrade_court or 0) > 0 then
                local has_court = false
                for card_id, level in pairs(self.game.levels) do
                    if level > 1 and card_id:find("court") then has_court = true; break end
                end
                if not has_court then can_afford = false end
            end
            
            if can_afford then return true end
        end
    end
    return false
end

function BeholdCamelot:showPlayableEnabled()
    return self.settings and self.settings:readSetting("show_playable") ~= false
end

function BeholdCamelot:toggleShowPlayable()
    local current = self:showPlayableEnabled()
    self.settings:saveSetting("show_playable", not current)
    self.settings:flush()
    return not current
end

function BeholdCamelot:startPlayAction(index)
    local id = self.game.hand[index]
    if not id then return end
    if self.game.awaiting_draw then self:message("Finish or stop the end-of-turn draw first."); return end
    if not self:isPlayLegal(id) then
        self:showNotice("Illegal play", self:cardName(id) .. " cannot be played under " .. REALM_NAMES[self.game.realm_level] .. ".")
        return
    end
    local options = self:actionOptions(id)
    if self.game.action then
        local interrupts = {}
        for _, option in ipairs(options) do if option.interrupt then interrupts[#interrupts + 1] = option end end
        options = interrupts
        if #options == 0 then self:message("Only a legal interrupt may be played during another action."); return end
    end
    if self.game.round_end then
        local filtered = {}
        for _, option in ipairs(options) do
            if not self:actionGeneratesDraw(option) then
                filtered[#filtered + 1] = option
            end
        end
        options = filtered
        if #options == 0 then self:message("Draw actions cannot be played after the Realm is revealed."); return end
    end
    if #options == 1 then self:beginAction(index, options[1]); return end
    local rows = {}
    for _, option in ipairs(options) do
        local chosen = option
        rows[#rows + 1] = {{text=expandResLabel(chosen.label), callback=function() self:beginAction(index, chosen) end}}
    end
    rows[#rows + 1] = {{text=_("Cancel"), callback=function() self:showGame() end}}
    self:showOverlay(ButtonDialog:new{modal=true, title="Choose how to play " .. self:cardName(id), buttons=rows})
end

function BeholdCamelot:beginAction(index, option)
    local id = self.game.hand[index]
    if not id then self:showGame(); return end
    if self.game.round_end and self:actionGeneratesDraw(option) then
        self:message("Draw actions cannot be played after the Realm is revealed."); return
    end
    if option.on_conquer then
        self:message("This effect triggers when the Holding is conquered; it cannot be played as a separate action."); return
    end
    local interrupted = self.game.action
    if option.conquer_boost and (not interrupted or #(interrupted.conquests or {})==0) then
        self:message("Gawain needs an unresolved conquest to boost."); return
    end
    if id=="allies" and self.game.levels[id]==4 then
        self:message("King Ban is offered when another played card is about to be discarded."); return
    end
    if option.passive then
        self:message("This face has no playable action. Its passive effect still applies. Use the normal end-turn discard if you want to discard it.")
        return
    end
    if id == "customs" and self.game.levels[id] == 1 then
        local key = self:actionCostKey()
        if not interrupted or not key or not (key:find("discard") or key:find("degrade")) then
            self:showNotice("Customs of the Court is a cost interrupt", "Play a card with a discard or degrade cost first, then use Customs of the Court in its cost chooser. Customs of the Court waives that cost and draws 1; it does not degrade Balin's Fatal Quest or another card.")
            return
        end
        interrupted.costs[key] = 0
    end
    if not interrupted then self:checkpoint() end
    remove_at(self.game.hand, index)
    local spec = copy(option)
    if spec.store_materials_by_wealth then
        spec.store_materials = self:controlledWealth() * (spec.store_multiplier or 1) + (spec.store_bonus or 0)
    end
    if spec.store_population_by_holdings then
        spec.store_population = #self.game.controlled * (spec.store_multiplier or 1) + (spec.store_bonus or 0)
    end
    if spec.store_materials_by_bags then
        local count = 0
        for _, controlled_id in ipairs(self.game.controlled) do count=count+(Scoring.faces[controlled_id][self.game.levels[controlled_id]].keys.coin or 0) end
        spec.store_materials = count
    end
    if spec.store_opposite then
        local materials, population = self:storedSummary()
        spec.store_materials, spec.store_population = population, materials
    end
    if interrupted then
        self.game.action_stack = self.game.action_stack or {}
        self.game.action_stack[#self.game.action_stack + 1] = interrupted
    end
    self.game.action = {
        engine_version=11,
        source=id, source_level=self.game.levels[id], source_available=true,
        spec=spec, costs=copy(spec.costs or {}), used={}, developed={},
        conquests=copy(spec.conquests or {}),
    }
    if spec.conquer_boost then
        interrupted.conquests[1]=interrupted.conquests[1]+spec.conquer_boost
        self.game.action.used.special=true
        self.game.action.notices={"Gawain added 1 to the pending conquest strength."}
    end
    self.game.last_event = "Playing " .. self:cardName(id) .. ": " .. expandResLabel(spec.label)
    self:save()
    self:continueActionCosts()
end

function BeholdCamelot:queueEffect(text)
    local a=self.game.action
    local target=a or self.game
    target.notices=target.notices or {}; target.notices[#target.notices+1]=text
end

function BeholdCamelot:showQueuedNotice(after)
    local notices=self.game and self.game.notices
    if not notices or #notices==0 then return false end
    local text=table.remove(notices,1)
    self:save()
    self:showOverlay(ButtonDialog:new{modal=true,title="Automatic effect\n\n"..text,buttons={{{text="OK",callback=after}}}})
    return true
end

function BeholdCamelot:recordDegrade(id)
    local a=self.game.action
    if not a then return end
    a.ineligible=a.ineligible or {}; a.ineligible[id]=true
    if id=="wounds" and self.game.levels[id]==4 then
        if self:actionCostKey() then
            a.pending_triggers=a.pending_triggers or {}
            a.pending_triggers[#a.pending_triggers+1]={store_materials=2,label="Balin's Fatal Quest: store 2 materials"}
        else
            a.spec.store_materials=(a.spec.store_materials or 0)+2
            a.used.store_materials=nil
            self:queueEffect("Balin's Fatal Quest degraded: generated Store 2 materials. The degraded card cannot be stored for this action.")
        end
    end
end

function BeholdCamelot:recordDiscard(id)
    local a=self.game.action
    if id=="wounds" and self.game.levels[id]==2 then
        self.game.levels[id]=1
        self:queueEffect("The discarded/abandoned Wounds automatically degraded to The Dolorous Stroke.")
    end
    if not a then return end
    a.ineligible=a.ineligible or {}; a.ineligible[id]=true
    if id=="kin" and self.game.levels[id]==2 and a.source~="kin" then
        if self:actionCostKey() then
            a.pending_triggers=a.pending_triggers or {}
            a.pending_triggers[#a.pending_triggers+1]={draw=1,optional=true,label="Gareth: optional draw 1"}
        else
            a.optional_draw=(a.optional_draw or 0)+1
            self:queueEffect("Gareth was discarded for another action: an optional Draw 1 is available.")
        end
    elseif id=="kin" and self.game.levels[id]==1 and a.source=="council" and a.source_level==2 then
        a.gawain_refill=true
        self:queueEffect("The Round Table discarded Gawain: after resolving the action, draw to six.")
    end
end

function BeholdCamelot:chooseSpecialInputs()
    local a=self.game.action
    a.input_total=a.input_total or 0
    local rows={}
    local marches=a.spec.marches_discard
    local zone=marches and self.game.hand or self.game.controlled
    for index,id in ipairs(zone) do
        local amount=marches and (Scoring.faces[id][self.game.levels[id]].keys.coin or 0) or (self:holdingWealth(id) or 0)
        if not (marches and id=="gaul" and self.game.levels[id]==1) then
            local chosen,chosen_id=index,id
            rows[#rows+1]={{hold_callback=function() self:previewCard(id) end,text=(marches and "Discard " or "Abandon ")..self:cardLabel(id).." (+"..amount..")",callback=function()
                table.remove(zone,chosen); self.game.deck[#self.game.deck+1]={id=chosen_id}
                a.input_total=a.input_total+amount; self:recordDiscard(chosen_id)
                self:save(); self:chooseSpecialInputs()
            end}}
        end
    end
    local function ready(kind)
        a.special_ready=true; a.used.special=true
        if kind=="draw" then a.spec.draw=a.input_total
        elseif kind=="conquer" then a.conquests={a.input_total+2}
        else a.spec[kind]=a.input_total end
        self:save(); self:showActionResolution()
    end
    if marches and a.input_total>0 then rows[#rows+1]={{text="Draw "..a.input_total,callback=function() ready("draw") end}}
    elseif a.spec.conquer_from_abandon then rows[#rows+1]={{text="Conquer "..(a.input_total+2),callback=function() ready("conquer") end}}
    elseif not marches and a.input_total>0 then
        rows[#rows+1]={{text="Develop "..a.input_total,callback=function() ready("develop") end},{text="Degrade "..a.input_total,callback=function() ready("degrade") end}}
    end
    rows[#rows+1]={{text="Undo entire action",callback=function() self:cancelUnpaidAction("Special action cancelled.") end}}
    self:showOverlay(ButtonDialog:new{modal=true,title=(marches and "Cornwall: discarded coin icons " or "Abandoned wealth ")..a.input_total,buttons=rows})
end

function BeholdCamelot:chooseRepetitions()
    local a=self.game.action
    a.repeat_count=a.repeat_count or 0
    local choices={
        develop={{"Pay 1M: develop 1",{materials=1},"develop",1}},
        conquer={{"Pay 1P: conquer 1",{population=1},"conquest",1}},
        crafts={{"Discard + 1M: develop 1",{discard=1,materials=1},"develop",1}},
        council_store={{"Discard: store 1P",{discard=1},"store_population",1}},
        taxes2={{"Discard: store 1M",{discard=1},"store_materials",1},{"Discard: store 1P",{discard=1},"store_population",1}},
        taxes3={{"Discard: store 2M",{discard=1},"store_materials",2},{"Discard: store 1P",{discard=1},"store_population",1}},
        host3={{"Pay 1P: conquer 1",{population=1},"conquest",1},{"Degrade 1: conquer 1",{degrade=1},"conquest",1}},
        host4={{"Pay 1P: conquer 2",{population=1},"conquest",2},{"Pay 1P: degrade 1",{population=1},"degrade",1}},
    }
    local rows={}
    if a.repeat_count<a.spec.repeat_limit then
        for _,choice in ipairs(choices[a.spec.repetitions]) do
            local c=choice
            rows[#rows+1]={{text=c[1],callback=function()
                for key,n in pairs(c[2]) do a.costs[key]=(a.costs[key] or 0)+n end
                if c[3]=="conquest" then a.conquests[#a.conquests+1]=c[4]
                else a.spec[c[3]]=(a.spec[c[3]] or 0)+c[4] end
                a.repeat_count=a.repeat_count+1
                self:save(); self:chooseRepetitions()
            end}}
        end
    end
    if a.repeat_count>0 then rows[#rows+1]={{text="Pay selected costs ("..a.repeat_count.." repetitions)",callback=function()
        a.repeats_ready=true; self:save(); self:continueActionCosts()
    end}} end
    rows[#rows+1]={{text="Undo entire action",callback=function() self:cancelUnpaidAction("Repetitions cancelled.") end}}
    self:showOverlay(ButtonDialog:new{modal=true,title="Plan repetitions: "..a.repeat_count.." / "..a.spec.repeat_limit,buttons=rows})
end

function BeholdCamelot:actionCostKey()
    local costs = self.game.action and self.game.action.costs or {}
    local selected=self.game.action and self.game.action.selected_cost
    if selected and (costs[selected] or 0)>0 then return selected end
    for _, key in ipairs({"discard_court", "discard_action", "discard", "degrade_court", "degrade_action", "degrade", "abandon", "materials", "population"}) do
        if (costs[key] or 0) > 0 then return key end
    end
end

function BeholdCamelot:continueActionCosts(selected)
    local action = self.game.action
    if not action then self:showGame(); return end
    if action.pending_triggers and #action.pending_triggers>0 then
        local trigger=action.pending_triggers[1]
        local function resume(resolve)
            table.remove(action.pending_triggers,1)
            if not resolve then self:save(); self:continueActionCosts(); return end
            self.game.action_stack=self.game.action_stack or {}
            self.game.action_stack[#self.game.action_stack+1]=action
            self.game.action={engine_version=11,source=action.source,source_level=action.source_level,source_available=false,
                spec=trigger,costs={},used={},developed={},conquests={},ineligible=action.ineligible,
                notices={trigger.label.." triggered during payment. Resolve it before returning to the remaining costs."}}
            self:save(); self:showActionResolution()
        end
        if trigger.optional then
            self:showOverlay(ButtonDialog:new{modal=true,title=expandResLabel(trigger.label),buttons={
                {{text="Resolve trigger",callback=function() resume(true) end}},
                {{text="Decline trigger",callback=function() resume(false) end}},
            }})
        else resume(true) end
        return
    end
    if action.spec.repetitions and not action.repeats_ready then self:chooseRepetitions(); return end
    action.selected_cost=selected
    local pending={}
    for key,n in pairs(action.costs) do if n>0 then pending[#pending+1]=key end end
    table.sort(pending)
    if #pending>1 and not selected then
        local rows={}
        for _,key in ipairs(pending) do local chosen=key
            rows[#rows+1]={{text="Pay "..key.." ("..action.costs[key]..")",callback=function() self:continueActionCosts(chosen) end}}
        end
        rows[#rows+1]={{text="Undo entire action",callback=function() self:cancelUnpaidAction("Payment cancelled.") end}}
        self:showOverlay(ButtonDialog:new{modal=true,title="Choose which cost to pay next",buttons=rows}); return
    end
    local key = self:actionCostKey()
    if not key then
        if (action.spec.flexible_abandon or action.spec.marches_discard) and not action.special_ready then self:chooseSpecialInputs(); return end
        self:showActionResolution(); return
    end
    if key == "materials" or key == "population" then
        self:chooseStoredPayment(key, action.costs[key], function()
            action.costs[key] = 0; self:continueActionCosts()
        end)
    elseif key == "abandon" then
        self:chooseCostHolding("Abandon a controlled Holding (cost)", function(index)
            local id = remove_at(self.game.controlled, index)
            self.game.deck[#self.game.deck + 1] = {id=id}
            self:recordDiscard(id)
            action.costs.abandon = action.costs.abandon - 1
            self:continueActionCosts()
        end)
    else
        local action_only = key:find("_court", 1, true) and "Court" or (key:find("_action", 1, true) ~= nil)
        local degrade = key:find("degrade", 1, true) ~= nil
        self:chooseCostCard((degrade and "Degrade" or "Discard") .. " a card (cost)", action_only, degrade, function(index)
            local id = self.game.hand[index]
            if degrade then
                self:recordDegrade(id)
                self.game.levels[id] = self.game.levels[id] - 1
            else
                local data=Scoring.faces[id][self.game.levels[id]]
                if action.spec.counsel=="draw" then action.spec.draw=data.prosperity end
                if action.spec.counsel=="conquer" and action.costs[key]==1 then action.conquests={data.unrest} end
                remove_at(self.game.hand, index)
                self.game.deck[#self.game.deck + 1] = {id=id}
                self:recordDiscard(id)
            end
            action.costs[key] = action.costs[key] - 1
            self:continueActionCosts()
        end)
    end
end

function BeholdCamelot:chooseCostCard(title, action_only, degrade, callback)
    local rows = {}
    for index, id in ipairs(self.game.hand) do
        local eligible = (not action_only or self:cardType(id) == (type(action_only)=="string" and action_only or "Action")) and (not degrade or self.game.levels[id] > 1)
        local a=self.game.action
        if a and id==a.source then eligible=false end
        if a and self.game.round_end and not degrade and id=="kin" and self.game.levels.kin==1
            and a.source=="council" and a.source_level==2 then eligible=false end
        if a and a.spec.counsel and not degrade then
            local d=Scoring.faces[id][self.game.levels[id]]
            if a.spec.counsel=="draw" and d.prosperity==0 then eligible=false end
            if a.spec.counsel=="conquer" and (a.costs.discard or 0)==1 and d.unrest==0 then eligible=false end
        end
        if eligible and not (id == "gaul" and self.game.levels[id] == 1 and not degrade) then
            local chosen = index
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id), callback=function() callback(chosen) end}}
        end
    end
    local cost_key = self:actionCostKey()
    if cost_key and (cost_key:find("discard") or cost_key:find("degrade")) then
        for index,id in ipairs(self.game.hand) do
            if id=="customs" and self.game.levels.customs==1 and self:isPlayLegal(id) then
                local chosen=index
                rows[#rows+1]={{text="Play Customs of the Court: waive this cost, draw 1",callback=function()
                    self:beginAction(chosen, ACTIONS.customs[1][1])
                end}}
            end
        end
    end
    if #rows == 0 then
        self:cancelUnpaidAction("No legal card can pay this cost.")
        return
    end
    self:showOverlay(ButtonDialog:new{modal=true, title=title, buttons=rows})
end

function BeholdCamelot:chooseCostHolding(title, callback, indices)
    local rows = {}
    for index, id in ipairs(self.game.controlled) do
        if not indices or indices[index] then
            local chosen = index
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id) .. " (wealth " .. tostring(self:holdingWealth(id) or 0) .. ")", callback=function() callback(chosen) end}}
        end
    end
    if #rows == 0 then self:cancelUnpaidAction("No controlled Holding can pay this cost."); return end
    self:showOverlay(ButtonDialog:new{modal=true, title=title, buttons=rows})
end

function BeholdCamelot:chooseStoredPayment(kind, amount, callback)
    if amount <= 0 then callback(); return end
    local rows = {}
    for _, wrapped in ipairs(self:storedEntries()) do
        local entry, deck_index = wrapped.entry, wrapped.index
        if entry.stored.kind == kind then
            rows[#rows + 1] = {{
                text=string.format("%s (%d %s; %d needed)", self:cardName(entry.id), entry.stored.amount, kind, amount),
                callback=function()
                    local paid = entry.stored.amount
                    local removed = remove_at(self.game.deck, deck_index)
                    removed.stored = nil; self.game.deck[#self.game.deck + 1] = removed
                    local left = math.max(0, amount - paid)
                    if left == 0 then callback() else self:chooseStoredPayment(kind, left, callback) end
                end,
            }}
        end
    end
    if #rows == 0 then self:cancelUnpaidAction("Not enough stored " .. kind .. " to pay this cost."); return end
    self:showOverlay(ButtonDialog:new{modal=true, title="Spend stored " .. kind .. " (excess on a card is lost)", buttons=rows})
end

function BeholdCamelot:cancelUnpaidAction(reason)
    if not self.undo_game then
        self:showNotice("Cannot safely undo", "No pre-action snapshot is available. The current state was preserved; no cards were removed.")
        return
    end
    self.game = copy(self.undo_game)
    self:save(); self:showGame(); self:showNotice("Action cancelled", reason .. " The game state was restored.")
end

function BeholdCamelot:discardActionSource(replace)
    local a=self.game.action
    if not a.source_available then return end
    if replace then
        for i,id in ipairs(self.game.hand) do if id=="allies" then
            table.remove(self.game.hand,i); self.game.deck[#self.game.deck+1]={id=id}; self:recordDiscard(id); break
        end end
        self.game.hand[#self.game.hand+1]=a.source
        self:queueEffect("King Ban was discarded instead of "..self:cardName(a.source).."; the played card returned to your hand. Its action still resolves.")
    else
        self.game.deck[#self.game.deck+1]={id=a.source}; self:recordDiscard(a.source)
    end
    a.source_available=false; a.source_discarded=true
    self:save()
end

function BeholdCamelot:prepareSourceDiscard()
    local a=self.game.action
    if not a.source_available or a.reserve_source then return true end
    if not a.final_discard and ((a.spec.store_materials or 0)>0 or (a.spec.store_population or 0)>0) then
        local kind,amount=self:printedStore(a.source)
        local budget=kind=="materials" and a.spec.store_materials or (kind=="population" and a.spec.store_population)
        if amount and budget and amount<=budget and not a.source_choice_made then
            self:showOverlay(ButtonDialog:new{modal=true,title="Do you intend to store the played card?",buttons={
                {{text="Keep played card for storage",callback=function()
                    a.reserve_source=true; a.source_choice_made=true; self:save(); self:showActionResolution()
                end}},
                {{text="Discard before resolving benefits",callback=function()
                    a.source_choice_made=true; self:save(); self:showActionResolution()
                end}},
            }})
            return false
        end
    end
    for _,id in ipairs(self.game.hand) do
        if id=="allies" and self.game.levels.allies==4 and a.source~="allies" then
            self:showOverlay(ButtonDialog:new{modal=true,title="Discard the played card, or use King Ban?",buttons={
                {{text="Discard played card",callback=function() self:discardActionSource(false); self:showActionResolution() end}},
                {{text="Discard King Ban instead",callback=function() self:discardActionSource(true); self:showActionResolution() end}},
            }})
            return false
        end
    end
    self:discardActionSource(false); return true
end

function BeholdCamelot:showActionResolution()
    local action = self.game.action
    if not action then self:showGame(); return end
    if not self:prepareSourceDiscard() then return end
    if action.notices and #action.notices>0 then
        local notice=table.remove(action.notices,1)
        self:showOverlay(ButtonDialog:new{modal=true,title="Automatic effect\n\n"..notice,buttons={{{text="OK",callback=function() self:showActionResolution() end}}}})
        return
    end
    local spec, rows = action.spec, {}
    if (spec.develop or 0) > 0 then rows[#rows + 1] = {{text="Develop (" .. spec.develop .. " left)", callback=function() self:resolveDevelop() end}} end
    if (spec.degrade or 0) > 0 then rows[#rows + 1] = {{text="Degrade (" .. spec.degrade .. " left)", callback=function() self:resolveDegradeBenefit() end}} end
    if #action.conquests > 0 then rows[#rows + 1] = {{text="Conquer (strength " .. action.conquests[1] .. ")", callback=function() self:resolveConquerBenefit() end}} end
    if (spec.store_materials or 0) > 0 then rows[#rows + 1] = {{text="Store materials (" .. spec.store_materials .. " left)", callback=function() self:resolveStoreBenefit("materials") end}} end
    if (spec.store_population or 0) > 0 then rows[#rows + 1] = {{text="Store population (" .. spec.store_population .. " left)", callback=function() self:resolveStoreBenefit("population") end}} end
    if (spec.develop_controlled or 0) > 0 then rows[#rows + 1] = {{text="Develop controlled Holding", callback=function() self:resolveControlledDevelopBenefit() end}} end
    if spec.draw or spec.draw_to then rows[#rows + 1] = {{text="Resolve draw", callback=function() self:resolveActionDraw() end}} end
    if (action.optional_draw or 0)>0 then rows[#rows+1]={{text="Gareth: draw 1 (optional)",callback=function()
        action.optional_draw=action.optional_draw-1; spec.draw=(spec.draw or 0)+1; self:resolveActionDraw()
    end}} end
    if action.guinevere_free and self.game.levels.lake==1 then
        for i,id in ipairs(self.game.hand) do if id=="lake" and not (action.ineligible or {}).lake then
            local index=i
            rows[#rows+1]={{hold_callback=function() self:previewCard("lake") end,text="Guinevere: store for free",callback=function()
                if #self:storedEntries()>=4 then self:message("Storage is full."); return end
                table.remove(self.game.hand,index); self.game.deck[#self.game.deck+1]={id="lake",stored={kind="materials",amount=1}}
                action.guinevere_free=nil; self:save(); self:showActionResolution()
            end}}
        end end
    end
    if spec.draw and action.used.draw then rows[#rows+1]={{text="Stop drawing",callback=function() spec.draw=nil; self:save(); self:showActionResolution() end}} end
    if spec.passive or spec.on_conquer then action.used.passive = true end
    rows[#rows + 1] = {{text=_("Finish action"), callback=function() self:finishAction() end}}
    rows[#rows + 1] = {{text=_("Undo entire action"), callback=function() self:cancelUnpaidAction("The action was undone.") end}}
    self:showOverlay(ButtonDialog:new{modal=true, title="Resolve " .. self:cardName(action.source) .. "\n\n" .. expandResLabel(spec.label or "Triggered effect"), buttons=rows})
end

function BeholdCamelot:payPerUse(kind, amount, after)
    if not amount or amount <= 0 then after(); return end
    self:chooseStoredPayment(kind, amount, after)
end

function BeholdCamelot:canDevelopInto(id, new_level)
    if new_level > 4 then return false, "already at level 4" end
    if not self:isPlayLegal(id, new_level, true) then return false, "the new face's banner is illegal" end
    local face = FACE_DATA[id] and FACE_DATA[id][new_level] or {}
    if face.requirement and face.requirement:find("Galahad", 1, true)
        and not (self.game.levels.council == 1 and self:isCardActive("council")) then
        return false, "Galahad is not active"
    end
    if id=="gaul" and new_level==4 and self.game.levels.allies~=4 then
        return false,"King Ban must be active"
    end
    if CARD_TYPES[id][new_level]=="Ally" or (id=="marches" and new_level==4) then
        local available=0
        for _,holding in ipairs(self.game.controlled) do if holding~=id then available=available+1 end end
        if available==0 then return false,"a different controlled Holding must be abandoned" end
    end
    return true
end

function BeholdCamelot:payDevelopmentRequirement(id,level,after)
    local abandon=CARD_TYPES[id][level]=="Ally" or (id=="marches" and level==4)
    if abandon then
        local allowed={}
        for i,holding in ipairs(self.game.controlled) do if holding~=id then allowed[i]=true end end
        self:chooseCostHolding(CARD_TYPES[id][level]=="Ally" and "Ally: abandon a controlled Holding" or "Guarding the Realm: abandon a controlled Holding",function(index)
            local removed=table.remove(self.game.controlled,index)
            self.game.deck[#self.game.deck+1]={id=removed}; self:recordDiscard(removed)
            after()
        end,allowed)
    elseif id=="gaul" and level==2 then self:chooseStoredPayment("materials",1,after)
    else after() end
end

function BeholdCamelot:isCardActive(id)
    return self.game.levels[id] ~= nil
end

function BeholdCamelot:resolveDevelop()
    local action, rows = self.game.action, {}
    if not action then return end
    for index, id in ipairs(self.game.hand) do
        local new_level = self.game.levels[id] + 1
        local legal, why = self:canDevelopInto(id, new_level)
        local different_ok = not action.spec.different or not action.developed[id]
        if legal and different_ok and id~=action.source then
            local chosen, chosen_id = index, id
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id) .. " -> " .. CARD_BY_ID[id].names[new_level], callback=function()
                self:payPerUse("materials", action.spec.develop_material, function()
                    local apply = function()
                        self.game.levels[chosen_id] = new_level
                        action.spec.develop = action.spec.develop - 1
                        action.used.develop=true; action.developed[chosen_id]=true
                        action.ineligible=action.ineligible or {}; action.ineligible[chosen_id]=true
                        self.game.last_event = CARD_BY_ID[chosen_id].names[new_level-1] .. " developed to " .. CARD_BY_ID[chosen_id].names[new_level] .. "."
                        self:save(); self:showActionResolution()
                    end
                    self:payDevelopmentRequirement(chosen_id,new_level,apply)
                end)
            end}}
        elseif why and not different_ok then
            -- Intentionally omitted: this option requires a different card.
        end
    end
    if #rows == 0 then self:message("No hand card is a legal development target."); return end
    rows[#rows + 1] = {{text=_("Back"), callback=function() self:showActionResolution() end}}
    self:showOverlay(ButtonDialog:new{modal=true, title="Choose a card to develop", buttons=rows})
end

function BeholdCamelot:resolveDegradeBenefit()
    local action, rows = self.game.action, {}
    for index, id in ipairs(self.game.hand) do
        if self.game.levels[id] > 1 and id~=action.source then
            local chosen, chosen_id = index, id
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id), callback=function()
                self:payPerUse("population", action.spec.degrade_population, function()
                    self:recordDegrade(chosen_id)
                    self.game.levels[chosen_id] = self.game.levels[chosen_id] - 1
                    action.spec.degrade = action.spec.degrade - 1; action.used.degrade=true
                    self.game.last_event = CARD_BY_ID[chosen_id].names[self.game.levels[chosen_id]+1] .. " degraded."
                    self:save(); self:showActionResolution()
                end)
            end}}
        end
    end
    if #rows == 0 then self:message("No hand card can be degraded."); return end
    rows[#rows + 1] = {{text=_("Back"), callback=function() self:showActionResolution() end}}
    self:showOverlay(ButtonDialog:new{modal=true, title="Choose a card to degrade", buttons=rows})
end

function BeholdCamelot:resolveConquerBenefit()
    local action, strength, rows = self.game.action, self.game.action.conquests[1], {}
    for index, id in ipairs(self.game.hand) do
        local wealth = self:holdingWealth(id)
        local required=(id=="grail" and self.game.levels[id]==2) and 2 or wealth
        local forces_draw=id=="allies" and self.game.levels[id]==3
        if wealth and required <= strength and self:isPlayLegal(id,nil,true) and id~=action.source and not (self.game.round_end and forces_draw) then
            local chosen, chosen_id = index, id
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id) .. " (wealth " .. wealth .. ")", callback=function()
                local perform = function()
                    local old_count = #self.game.controlled
                    for i,hand_id in ipairs(self.game.hand) do if hand_id==chosen_id then remove_at(self.game.hand,i); break end end
                    local syria_degraded=false
                    if chosen_id == "wounds" and self.game.levels[chosen_id] == 3 then self.game.levels[chosen_id] = 2; syria_degraded=true end
                    self.game.controlled[#self.game.controlled + 1] = chosen_id
                    if chosen_id=="gaul" and self.game.levels[chosen_id]==3 then
                        action.spec.store_population=(action.spec.store_population or 0)+2
                        action.used.store_population=nil
                        self:queueEffect("Brittany conquered: generated Store 2 population.")
                    elseif chosen_id=="allies" and self.game.levels[chosen_id]==3 then
                        action.spec.draw=(action.spec.draw or 0)+2
                        action.used.draw=nil
                        self:queueEffect("Benwick conquered: generated Draw 2.")
                    end
                    table.remove(action.conquests, 1); action.used.conquer=true
                    self.game.last_event = self:cardName(chosen_id) .. " conquered."
                    local after = function()
                        self:save(); self:showActionResolution()
                        if syria_degraded then self:showNotice("Automatic: Pellam's Castle degraded","Pellam's Castle automatically degraded to The Wounded Lands before Camelot took control of it.") end
                    end
                    if old_count >= 4 then
                        local allowed = {}; for i=1,old_count do allowed[i]=true end
                        self:chooseCostHolding("You now control five Holdings. Abandon one of the four previously controlled Holdings.", function(holding_index)
                            local abandoned = remove_at(self.game.controlled, holding_index)
                            self.game.deck[#self.game.deck + 1] = {id=abandoned}
                            self:recordDiscard(abandoned)
                            self.game.last_event = self.game.last_event .. " " .. self:cardName(abandoned) .. " was abandoned automatically as required."
                            self:save(); self:showActionResolution()
                            self:showNotice("Mandatory abandonment", self:cardName(abandoned) .. " was abandoned because Camelot may control no more than four Holdings." .. (syria_degraded and " Pellam's Castle also degraded to The Wounded Lands before control." or ""))
                        end, allowed)
                    else after() end
                end
                self:payPerUse("population", action.spec.conquer_population, function()
                    if action.spec.conquer_degrade then
                        self:chooseCostCard("Degrade a card for this conquest", false, true, function(cost_index)
                            local cost_id = self.game.hand[cost_index]; self:recordDegrade(cost_id); self.game.levels[cost_id] = self.game.levels[cost_id]-1; perform()
                        end)
                    else perform() end
                end)
            end}}
        end
    end
    if #rows == 0 then self:message("No Holding in hand is legal and within conquer strength " .. strength .. "."); return end
    rows[#rows + 1] = {{text=_("Back"), callback=function() self:showActionResolution() end}}
    self:showOverlay(ButtonDialog:new{modal=true, title="Choose a Holding to conquer", buttons=rows})
end

function BeholdCamelot:resolveStoreBenefit(kind)
    local action, key, rows = self.game.action, kind == "materials" and "store_materials" or "store_population", {}
    local remaining = action.spec[key] or 0
    local function addCandidate(id, index, is_source)
        local printed_kind, amount = self:printedStore(id)
        if printed_kind == kind and amount and amount <= remaining and not (action.ineligible or {})[id] and (is_source or id~=action.source) then
            rows[#rows + 1] = {{hold_callback=function() self:previewCard(id) end,text=(is_source and "Played card: " or "") .. self:cardLabel(id) .. " (stores " .. amount .. ")", callback=function()
                if #self:storedEntries() >= 4 then self:message("All four storage slots are occupied."); return end
                if action.spec.store_discard or action.spec.store_discard_per then
                    self:chooseCostCard("Discard a card for this store benefit", false, false, function(cost_index)
                        if self.game.hand[cost_index]==id then self:message("The card being stored cannot also pay its discard cost."); return end
                        local cost_id=remove_at(self.game.hand,cost_index); self.game.deck[#self.game.deck+1]={id=cost_id}; self:recordDiscard(cost_id)
                        action.spec[key] = math.max(0, remaining - amount); action.used.store=true; action.used[key]=true
                        if is_source then action.source_available=false else for i,hand_id in ipairs(self.game.hand) do if hand_id==id then remove_at(self.game.hand,i); break end end end
                        self.game.deck[#self.game.deck+1]={id=id,stored={kind=kind,amount=amount}}
                        if kind=="population" then action.guinevere_free=true end
                        self:save(); self:showActionResolution()
                    end)
                else
                    action.spec[key] = math.max(0, remaining - amount); action.used.store=true; action.used[key]=true
                    if is_source then action.source_available=false else remove_at(self.game.hand,index) end
                    self.game.deck[#self.game.deck+1]={id=id,stored={kind=kind,amount=amount}}
                    if kind=="population" then action.guinevere_free=true end
                    self:save(); self:showActionResolution()
                end
            end}}
        end
    end
    for index,id in ipairs(self.game.hand) do addCandidate(id,index,false) end
    if action.source_available then addCandidate(action.source,nil,true) end
    if #rows == 0 then self:message("No eligible card fits the remaining generated store amount."); return end
    rows[#rows + 1] = {{text=_("Back"), callback=function() self:showActionResolution() end}}
    self:showOverlay(ButtonDialog:new{modal=true,title="Choose a card to store as " .. kind .. " (" .. remaining .. " generated)",buttons=rows})
end

function BeholdCamelot:resolveControlledDevelopBenefit()
    local action, rows = self.game.action, {}
    for index,id in ipairs(self.game.controlled) do
        local new_level = self.game.levels[id]+1
        local legal = self:canDevelopInto(id,new_level)
        if legal then
            local chosen_id=id
            rows[#rows+1]={{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id),callback=function()
                self:payDevelopmentRequirement(chosen_id,new_level,function()
                    local chosen
                    for i,holding in ipairs(self.game.controlled) do if holding==chosen_id then chosen=i; break end end
                    if not chosen then self:cancelUnpaidAction("Development target is no longer controlled."); return end
                    local automatic=self:developControlled(chosen, true)
                    action.spec.develop_controlled=action.spec.develop_controlled-1; action.used.develop_controlled=true
                    if automatic then self:queueEffect(automatic) end
                    self:save(); self:showActionResolution()
                end)
            end}}
        end
    end
    if #rows==0 then self:message("No controlled Holding can legally develop."); return end
    self:showOverlay(ButtonDialog:new{modal=true,title="Choose controlled Holding",buttons=rows})
end

function BeholdCamelot:reachActionRealm()
    local action=self.game.action
    local function stop()
        self.game.round_end=true; action.spec.draw=nil; action.spec.draw_to=nil
        self:queueEffect("The Realm card was reached. Drawing stopped for round end.")
        self:save(); self:showActionResolution()
    end
    if not self.game.fluid_round or self.game.round>=self.game.max_rounds then stop(); return end
    local exposed=self.game.deck[2]
    local warning=exposed and exposed.stored and ("\nContinuing reveals "..self:cardName(exposed.id).." and loses its stored resources.") or ""
    self:showOverlay(ButtonDialog:new{modal=true,title="Fluid Round: stop to develop your realm, or pass into the next round?"..warning,buttons={
        {{text="Stop at Realm",callback=stop}},
        {{text="Continue into next round",callback=function()
            local marker=table.remove(self.game.deck,1); self.game.deck[#self.game.deck+1]=marker
            self.game.round=self.game.round+1; self.game.realm_developed=false; self.game.round_end=false
            self:queueEffect("Fluid Round advanced to round "..self.game.round..". Remaining action draws are preserved.")
            if exposed and exposed.stored then exposed.stored=nil; self:queueEffect(self:cardName(exposed.id).." was revealed and un-stored; its stored resources were lost.") end
            self:save(); self:showActionResolution()
        end}},
    }})
end

function BeholdCamelot:resolveActionDraw(force)
    local action, target = self.game.action, self.game.action.spec.draw_to
    local count = target and math.max(0,target-#self.game.hand) or (self.game.action.spec.draw or 0)
    local top=self.game.deck[1]
    if count<=0 or not top or self.game.round_end then
        action.spec.draw=nil; action.spec.draw_to=nil
        self:save(); self:showActionResolution(); return
    end
    if top.marker=="realm" then
        self:reachActionRealm(); return
    end
    local exposed=self:willRevealStored() or (top.stored and top)
    if exposed and not force then
        self:showOverlay(ButtonDialog:new{modal=true,title="Stored card warning\nDrawing will un-store "..self:cardName(exposed.id).." and lose its resources.",buttons={
            {{text="Draw anyway",callback=function() self:resolveActionDraw(true) end}},
            {{text=action.used.draw and "Stop drawing" or "Undo action (draw benefit not yet resolved)",callback=function()
                if action.used.draw then action.spec.draw=nil; action.spec.draw_to=nil; self:save(); self:showActionResolution()
                else self:cancelUnpaidAction("Drawing stopped before resolving the draw benefit.") end
            end}},
        }})
        return
    end
    table.remove(self.game.deck,1)
    self.game.hand[#self.game.hand+1]=top.id
    if exposed then exposed.stored=nil; self:queueEffect(self:cardName(exposed.id).." became un-stored; its stored resources were lost.") end
    action.spec.draw=target and math.max(0,target-#self.game.hand) or count-1
    action.spec.draw_to=nil; action.used.draw=true
    if action.spec.draw<=0 then action.spec.draw=nil end
    local next_card=self.game.deck[1]
    if next_card and next_card.marker=="realm" then
        self:save(); self:reachActionRealm(); return
    end
    self.game.last_event="Drew "..self:cardName(top.id).."."
    self:save(); self:showActionResolution()
end

function BeholdCamelot:finishAction()
    local action=self.game.action
    if not action then self:showGame(); return end
    if self:actionCostKey() or (action.pending_triggers and #action.pending_triggers>0) then self:continueActionCosts(); return end
    local spec=action.spec
    local missing={}
    if (spec.develop or 0)>0 and not action.used.develop then missing[#missing+1]="develop" end
    if (spec.develop_controlled or 0)>0 and not action.used.develop_controlled then missing[#missing+1]="develop controlled Holding" end
    if (spec.degrade or 0)>0 and not action.used.degrade then missing[#missing+1]="degrade" end
    if #action.conquests>0 and not action.used.conquer then missing[#missing+1]="conquer" end
    if (spec.store_materials or 0)>0 and not action.used.store_materials then missing[#missing+1]="store materials" end
    if (spec.store_population or 0)>0 and not action.used.store_population then missing[#missing+1]="store population" end
    if (spec.draw or spec.draw_to) and not action.used.draw then missing[#missing+1]="draw" end
    if #missing>0 then
        self:message("Resolve at least some of every benefit: "..table.concat(missing,", ")..".")
        return
    end
    if action.gawain_refill then
        action.gawain_refill=nil
        if #self.game.hand<6 and not self.game.round_end then
            spec.draw_to=6; action.used.draw=nil
            self:queueEffect("The Round Table has resolved. Gawain now lets you draw to six.")
            self:save(); self:showActionResolution(); return
        end
    end
    if action.source_available then
        action.reserve_source=nil; action.final_discard=true
        if not self:prepareSourceDiscard() then return end
    end
    local name=self:cardName(action.source)
    local prior
    if self.game.action_stack and #self.game.action_stack>0 then prior=table.remove(self.game.action_stack) end
    self.game.action=prior
    self.game.last_event=name.." resolved. Optional remaining benefits were declined."..(prior and " Resume the interrupted action." or "")
    self:save()
    if prior then self:continueActionCosts() else self:showGame() end
end

function BeholdCamelot:showMainMenu()
    self:closeDialog()
    _hideSimpleUITopbar()
    local buttons = {}
    if self.game and not self.game.finished then
        buttons[#buttons + 1] = {{
            text = _("Resume game"),
            callback = function() self:showGame() end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("New game"),
        callback = function() self:chooseRival() end,
    }}
    local playable_text = self:showPlayableEnabled() and _("Hide playable cards") or _("Show playable cards")
    buttons[#buttons + 1] = {{
        text = playable_text,
        callback = function()
            self:toggleShowPlayable()
            self:showMainMenu()
        end,
    }}
    buttons[#buttons + 1] = {
        { text=_("About"), callback=function() self:showAbout() end },
    }
    buttons[#buttons + 1] = {{ text=_("Close"), callback=function() self:closeDialog() end }}
    self.dialog = ButtonDialog:new{
        title = _("Behold: Camelot - in-hand civilization builder"),
        buttons = buttons,
    }
    UIManager:show(self.dialog)
end

function BeholdCamelot:chooseRival()
    self:closeDialog()
    local rows = {}
    for _, rival in ipairs(RIVALS) do
        local choice = rival
        rows[#rows + 1] = {{
            text = choice,
            callback = function() self:configureNewGame(choice) end,
            hold_callback = function() self:showStrategy(choice) end,
        }}
    end
    rows[#rows + 1] = {{ text=_("Back"), callback=function() self:showMainMenu() end }}
    self:markHoldButtons(rows)
    self.dialog = ButtonDialog:new{ title=_("Choose a rival"), buttons=rows }
    UIManager:show(self.dialog)
end

function BeholdCamelot:configureNewGame(rival)
    self.pending_setup={rival=rival,game_difficulty="Normal",rival_difficulty="Normal",foresight=false,fluid_round=false}
    self:showNewGameOptions()
end

function BeholdCamelot:showNewGameOptions()
    local setup=self.pending_setup
    local buttons={
        {{text="Game: "..setup.game_difficulty,callback=function() self:cycleSetup("game_difficulty",GAME_DIFFICULTIES) end}},
        {{text="Rival: "..setup.rival_difficulty.." ("..string.format("%+d",RIVAL_DIFFICULTIES[setup.rival_difficulty]).." Renown)",callback=function() self:cycleSetup("rival_difficulty",RIVAL_DIFFICULTIES) end}},
        {
            {text="Foresight: "..(setup.foresight and "ON" or "off"),callback=function() setup.foresight=not setup.foresight; self:showNewGameOptions() end},
            {text="Fluid Round: "..(setup.fluid_round and "ON" or "off"),callback=function() setup.fluid_round=not setup.fluid_round; self:showNewGameOptions() end},
        },
        {{text=_("Start game"),callback=function() self:confirmNewGame(setup.rival,setup) end}},
        {{text=_("Back"),callback=function() self:chooseRival() end}},
    }
    local help={
        game_difficulty="Game difficulty changes the starting Holdings and round limit. Casual: Bedegraine + Caerleon, 12 rounds. Easy: Bedegraine, 12 rounds. Normal: no starting Holdings, 12 rounds. Hard: 11 rounds. Impossible: 10 rounds. Tap to cycle; hold to read this description.",
        rival_difficulty="Rival difficulty changes only the rival's final Renown: Casual -40, Easy -20, Normal +0, Hard +20, Impossible +40. Camelot must score strictly more; ties lose. Chronicle of the Realm has no rival score.",
        foresight="Foresight lets you inspect the draw pile's order using Inspect pile. It does not rearrange the pile or change draws. Off keeps that future information hidden.",
        fluid_round="Fluid Round lets you stop at the Realm for the usual round-end procedure, or continue drawing into the next round. Continuing moves the Realm to the bottom and uses another round; it is not a free extra round. The final round cannot continue. Stored-card warnings still apply.",
    }
    local function explain(key,title)
        self:showOverlay(TextViewer:new{modal=true,title=title,text=help[key]})
    end
    buttons[1][1].hold_callback=function() explain("game_difficulty","Game difficulty") end
    buttons[2][1].hold_callback=function() explain("rival_difficulty","Rival difficulty") end
    buttons[3][1].hold_callback=function() explain("foresight","Foresight") end
    buttons[3][2].hold_callback=function() explain("fluid_round","Fluid Round") end
    table.insert(buttons,1,{{text="Opponent: "..setup.rival.." (hold for strategy)",
        callback=function() self:chooseRival() end,hold_callback=function() self:showStrategy(setup.rival) end}})
    self:markHoldButtons(buttons)
    self:closeDialog()
    self.dialog=ButtonDialog:new{title="New game vs "..setup.rival,buttons=buttons}
    UIManager:show(self.dialog)
end

function BeholdCamelot:cycleSetup(key, values)
    local order={"Casual","Easy","Normal","Hard","Impossible"}
    local current=self.pending_setup[key]
    for index,value in ipairs(order) do
        if value==current then self.pending_setup[key]=order[index % #order + 1]; break end
    end
    self:showNewGameOptions()
end

function BeholdCamelot:confirmNewGame(rival, setup)
    if self.game and not self.game.finished then
        UIManager:show(ConfirmBox:new{
            text = _("Abandon the saved game and start over?"),
            ok_text = _("Start over"),
            ok_callback = function() self:newGame(rival, setup) end,
        })
    else
        self:newGame(rival, setup)
    end
end

function BeholdCamelot:newGame(rival, setup)
    self:closeDialog()
    setup=setup or {game_difficulty="Normal",rival_difficulty="Normal",foresight=false,fluid_round=false}
    local ids, levels = {}, {}
    for _, card in ipairs(CARDS) do
        ids[#ids + 1] = card.id
        levels[card.id] = card.start
    end
    shuffle(ids)
    local difficulty=GAME_DIFFICULTIES[setup.game_difficulty] or GAME_DIFFICULTIES.Normal
    local controlled={}
    for _,starting_id in ipairs(difficulty.starting) do
        for index,id in ipairs(ids) do
            if id==starting_id then table.remove(ids,index); controlled[#controlled+1]=id; break end
        end
    end
    local deck = {}
    for _, id in ipairs(ids) do deck[#deck + 1] = { id=id } end
    deck[#deck + 1] = { marker="realm" }
    self.game = {
        version=2,
        rival=rival,
        game_difficulty=setup.game_difficulty,
        rival_difficulty=setup.rival_difficulty,
        rival_modifier=RIVAL_DIFFICULTIES[setup.rival_difficulty] or 0,
        foresight=setup.foresight,
        fluid_round=setup.fluid_round,
        round=1,
        max_rounds=difficulty.rounds,
        realm_level=1,
        realm_developed=false,
        levels=levels,
        deck=deck,
        hand={},
        controlled=controlled,
        awaiting_draw=false,
        round_end=false,
        finished=false,
        last_event="Camelot's story begins.",
        reminders={},
    }
    self.undo_game = nil
    self:drawToFive()
    self:save()
    self:showGame()
end

function BeholdCamelot:storedEntries()
    local entries = {}
    for index, entry in ipairs(self.game.deck) do
        if entry.stored then entries[#entries + 1] = { index=index, entry=entry } end
    end
    return entries
end

function BeholdCamelot:storedSummary()
    local materials, population, slots = 0, 0, 0
    for _, wrapped in ipairs(self:storedEntries()) do
        slots = slots + 1
        if wrapped.entry.stored.kind == "materials" then
            materials = materials + wrapped.entry.stored.amount
        else
            population = population + wrapped.entry.stored.amount
        end
    end
    return materials, population, slots
end

function BeholdCamelot:drawOne()
    if self.game.round_end or #self.game.hand >= 5 or #self.game.deck == 0 then return false end
    local top = self.game.deck[1]
    if top.marker == "realm" then
        if self.game.fluid_round then
            table.remove(self.game.deck,1); self.game.deck[#self.game.deck+1]={marker="realm"}
            if self.game.round>=self.game.max_rounds then self.game.finished=true; return false end
            self.game.round=self.game.round+1; self.game.realm_developed=false
            self.game.last_event="Fluid Round: Realm passed; round "..self.game.round.." began."
            return self:drawOne()
        end
        self.game.round_end = true
        self.game.last_event = "Realm revealed. Resolve round end."
        return false
    end
    if top.stored then
        top.stored = nil
        self.game.last_event = self:cardName(top.id) .. " reached the top and is no longer stored. Tap Draw again to take it."
        return false
    end
    table.remove(self.game.deck, 1)
    self.game.hand[#self.game.hand + 1] = top.id
    return true
end

function BeholdCamelot:drawToFive()
    while #self.game.hand < 5 and self:drawOne() do end
end

function BeholdCamelot:statusText()
    local materials, population, slots = self:storedSummary()
    return string.format(
        "Round %d/%d | %s | %s (%s/%s)%s\nHand %d | Deck %d | Stored %d/4 (M%d P%d) | Holdings %d/4\n%s",
        self.game.round, self.game.max_rounds, REALM_NAMES[self.game.realm_level], self.game.rival,
        self.game.game_difficulty or "Normal", self.game.rival_difficulty or "Normal",
        (self.game.foresight and " Foresight" or "") .. (self.game.fluid_round and " Fluid" or ""),
        #self.game.hand, #self.game.deck, slots, materials, population,
        #self.game.controlled, self.game.last_event or ""
    )
end

function BeholdCamelot:gameHandButtons()
    local buttons = {}
    for index, id in ipairs(self.game.hand) do
        local chosen_index = index
        buttons[#buttons + 1] = {
            text=self:cardLabel(id),
            callback=function() self:showHandCard(chosen_index) end,
        }
    end
    return buttons
end

function BeholdCamelot:gameActionButtons()
    local buttons = {}
    if self.game.action then
        return {
            {text=_("Resume action"),callback=function() self:continueActionCosts() end},
            {text=_("Undo action"),callback=function() self:cancelUnpaidAction("The action was undone.") end},
        }
    end
    if self.game.round_end then
        buttons[#buttons + 1] = {
            text=_("Develop realm"),
            callback=function() self:developRealm() end,
            hold_callback=function() self:showRealmUpgrade() end,
        }
        buttons[#buttons + 1] = { text=_("End round"), callback=function() self:chooseRoundDiscard() end }
    elseif self.game.awaiting_draw then
        buttons[#buttons + 1] = {
            text=string.format("Draw one (%d/5)", #self.game.hand),
            callback=function() self:manualDraw() end,
        }
    else
        buttons[#buttons + 1] = { text=_("Discard top / end turn"), callback=function() self:endTurnTop() end }
    end
    local stored_materials, stored_population, stored_count = self:storedSummary()
    buttons[#buttons + 1] = { text=string.format("Stored (%d)",stored_count), callback=function() self:showStored() end }
    buttons[#buttons + 1] = { text=string.format("Holdings (%d)",#self.game.controlled), callback=function() self:showControlled() end }
    buttons[#buttons + 1] = { text=_("Strategy"), callback=function() self:showStrategy() end }
    buttons[#buttons + 1] = { text=_("Realm / Rival / Icons"), callback=function() self:showRealm() end }
    if self.game.foresight then buttons[#buttons + 1] = { text=_("Inspect pile"), callback=function() self:showDeckOrder() end } end
    buttons[#buttons + 1] = { text=_("Correct game state"), callback=function() self:showCorrectionMenu() end }
    buttons[#buttons + 1] = { text=_("Undo"), callback=function() self:undo() end }
    buttons[#buttons + 1] = { text=_("Finish & score"), callback=function() self:confirmFinish() end }
    buttons[#buttons + 1] = { text=_("Save & close"), callback=function() self:save(); self:closeDialog() end }
    return buttons
end

function BeholdCamelot:toggleReminder(id)
    self.game.reminders = self.game.reminders or {}
    if self.game.reminders[id] then
        self.game.reminders[id] = nil
    else
        self.game.reminders[id] = true
    end
    self:save()
    self:refreshBoard(false)
end

function BeholdCamelot:isReminded(id)
    return self.game.reminders and self.game.reminders[id] or false
end

function BeholdCamelot:focusedCardActions(index)
    if self.game.action then
        local id=self.game.hand[index]
        local can_interrupt=false
        for _,option in ipairs(self:actionOptions(id)) do if option.interrupt then can_interrupt=true end end
        return {
            {text=_("Resume action"),callback=function() self:continueActionCosts() end},
            {text=_("Play interrupt"),enabled=can_interrupt,callback=function() self:startPlayAction(index) end},
            {text=_("Full text"),callback=function() self:showFullCardText(id) end},
        }
    end
    if self.game.awaiting_draw then
        return {{
            text=string.format("Draw one (%d/5)", #self.game.hand),
            callback=function() self:manualDraw() end,
        }}
    end
    local id = self.game.hand[index]
    if not id then return {} end
    local reminder_text = self:isReminded(id) and _("Un-remind") or _("Remind me")
    return {
        { text=_("Play action"), callback=function() self:startPlayAction(index) end },
        { text=_("Full text"), callback=function() self:showFullCardText(id) end },
        { text=reminder_text, callback=function() self:toggleReminder(id) end },
        { text=_("End turn / discard"), callback=function() self:discardHand(index, true) end },
    }
end

function BeholdCamelot:showGame()
    if self.game and self.game.action and self.game.action.engine_version~=11 and self.legacy_action_blocked then
        self:showNotice("Older in-progress action preserved", "This action was saved by an older rules engine and cannot safely resume. A copy is retained in legacy_in_progress_backup. Restore the previous plugin to finish/undo it, or start a new game from the menu. Your save has not been reset.")
        return
    end
    if self:showQueuedNotice(function() self:showGame() end) then return end
    if not self.game then self:showMainMenu(); return end
    if self.game.realm_payment then self:resumeRealmPayment(); return end
    if self.game.finished then self:showGameOver(); return end
    local had_overlay = self.overlay ~= nil
    self:closeOverlay(false)
    if self.dialog and self.dialog.name == "beholdcamelot_game" then
        self:refreshBoard(had_overlay)
        return
    end
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    self.dialog = BeholdCamelotGameScreen:new{ plugin=self }
    UIManager:show(self.dialog)
end

function BeholdCamelot:showHandCard(index)
    local id = self.game.hand[index]
    if not id then self:showGame(); return end
    local rows = {
        {{ text=_("Play action"), callback=function() self:startPlayAction(index) end }},
        {{ text=_("Full text"), callback=function() self:showFullCardText(id) end }},
        {{ text=_("End turn with discard"), callback=function() self:discardHand(index, true) end }},
        {{ text=_("Back"), callback=function() self:showGame() end }},
    }
    self:showOverlay(ButtonDialog:new{
        modal = true,
        title = self:cardDetails(id),
        rows_per_page = { 6, 5, 4 },
        buttons = rows,
    })
end

function BeholdCamelot:realmUpgradeText()
    local level = self.game.realm_level
    if level >= 4 then return "NEXT REALM UPGRADE: none (The Grail Quest is the final realm)." end
    local target = REALM_NAMES[level + 1]
    local cost = {
        "abandon 1 controlled Holding of any wealth and pay 1 material",
        "abandon controlled Holdings totaling exactly 3 wealth",
        "abandon controlled Holdings totaling exactly 4 wealth",
    }
    local lines = { "NEXT REALM UPGRADE: " .. target, "COST: " .. cost[level] .. "." }
    if level == 3 then
        lines[#lines + 1] = self.game.levels.council == 1 and self:isCardActive("council")
            and "REQUIREMENT: Galahad is active."
            or "REQUIREMENT: Galahad must be active (currently not met)."
    end
    if self.game.realm_developed then
        lines[#lines + 1] = "This realm has already developed this round."
    elseif self.game.round_end then
        lines[#lines + 1] = "Available now: resolve this cost with Develop realm."
    else
        lines[#lines + 1] = "Available at round end."
    end
    return table.concat(lines, "\n")
end

function BeholdCamelot:showRealmUpgrade()
    self:showOverlay(TextViewer:new{
        modal=true,
        title="Develop realm cost",
        text=self:realmUpgradeText(),
    })
end

function BeholdCamelot:showRealm()
    self:showOverlay(RealmRivalScreen:new{plugin=self,page=1})
end

function BeholdCamelot:changeLevel(id, delta)
    local old = self.game.levels[id]
    local new = old + delta
    if new < 1 or new > 4 then
        self:message("That card is already at its " .. (new < 1 and "lowest" or "highest") .. " level.")
        return
    end
    self:checkpoint()
    self.game.levels[id] = new
    self.game.last_event = CARD_BY_ID[id].names[old] .. " became " .. CARD_BY_ID[id].names[new] .. "."
    self:save()
    self:showGame()
end

function BeholdCamelot:discardHand(index, end_turn)
    self:checkpoint()
    local id = remove_at(self.game.hand, index)
    if not id then self:showGame(); return end
    self.game.deck[#self.game.deck + 1] = { id=id }
    self:recordDiscard(id)
    self.game.last_event = self:cardName(id) .. " discarded."
    if end_turn then
        self.game.awaiting_draw = #self.game.hand < 5
        self.game.last_event = self.game.last_event .. " Draw manually to refill your hand."
    end
    self:save()
    self:showGame()
end

function BeholdCamelot:storePrintedCard(index)
    local id = self.game.hand[index]
    if not id then self:showGame(); return end
    local kind, amount = self:printedStore(id)
    if not kind or not amount then
        self:message("This face has no available store resource.")
        return
    end
    local stored_entries = self:storedEntries()
    if #stored_entries >= 4 then
        self:message("All four storage slots are occupied.")
        return
    end
    self:storeCard(index, kind, amount)
end

function BeholdCamelot:storeCard(index, kind, amount)
    self:checkpoint()
    local id = remove_at(self.game.hand, index)
    if not id then self:showGame(); return end
    self.game.deck[#self.game.deck + 1] = { id=id, stored={kind=kind, amount=amount} }
    self.game.last_event = string.format("Stored %s for %d %s.", self:cardName(id), amount, kind)
    self:save()
    self:showGame()
end

function BeholdCamelot:conquer(index)
    if #self.game.controlled >= 4 then
        self:message("Four holdings are controlled. Abandon one first.")
        return
    end
    self:checkpoint()
    local id = remove_at(self.game.hand, index)
    if not id then self:showGame(); return end
    self.game.controlled[#self.game.controlled + 1] = id
    self.game.last_event = self:cardName(id) .. " conquered."
    self:save()
    self:showGame()
end

function BeholdCamelot:willRevealStored()
    local next_entry = self.game.deck[2]
    return next_entry and next_entry.stored and next_entry or nil
end

function BeholdCamelot:reachManualRealm()
    local function stop()
        self.game.round_end=true; self.game.awaiting_draw=false
        self:queueEffect("The Realm card was revealed. Drawing stopped for round end.")
        self:save(); self:showGame()
    end
    if not self.game.fluid_round or self.game.round>=self.game.max_rounds then stop(); return end
    local next_card=self.game.deck[2]
    local warning=next_card and next_card.stored and ("\nContinuing un-stores "..self:cardName(next_card.id).." and loses its resources.") or ""
    self:showOverlay(ButtonDialog:new{modal=true,title="Fluid Round: stop at the Realm or continue?"..warning,buttons={
        {{text="Stop at Realm",callback=stop}},
        {{text="Continue into next round",callback=function()
            local marker=table.remove(self.game.deck,1); self.game.deck[#self.game.deck+1]=marker
            self.game.round=self.game.round+1; self.game.realm_developed=false
            self.game.round_end=false; self.game.awaiting_draw=#self.game.hand<5
            self:queueEffect("Fluid Round advanced to round "..self.game.round..".")
            if next_card and next_card.stored then next_card.stored=nil; self:queueEffect(self:cardName(next_card.id).." was revealed and un-stored; its resources were lost.") end
            self:save(); self:showGame()
        end}},
    }})
end

function BeholdCamelot:finishManualDraw()
    self:checkpoint()
    local top = self.game.deck[1]
    if not top then
        self.game.awaiting_draw = false
        self.game.last_event = "The pile is empty."
        self:save(); self:showGame()
        return
    end
    if top.marker == "realm" then
        self:reachManualRealm(); return
    end
    table.remove(self.game.deck, 1)
    self.game.hand[#self.game.hand + 1] = top.id
    local automatic_title, automatic_text
    local revealed = self.game.deck[1]
    if revealed and revealed.stored then
        local stored_name = self:cardName(revealed.id)
        revealed.stored = nil
        automatic_title = "Automatic: stored card released"
        automatic_text = stored_name .. " reached the top of the pile and is no longer stored. Its stored resources were lost."
    elseif revealed and revealed.marker == "realm" then
        self:save(); self:reachManualRealm(); return
    end
    if #self.game.hand >= 5 then self.game.awaiting_draw = false end
    self.game.last_event = "Drew " .. self:cardName(top.id) .. "."
    self:save()
    self:showGame()
    if automatic_title then self:showNotice(automatic_title, automatic_text) end
end

function BeholdCamelot:manualDraw(force)
    if not self.game.awaiting_draw then
        self:message("Drawing is available while manually refilling at the end of a turn.")
        return
    end
    if #self.game.hand >= 5 then
        self.game.awaiting_draw = false
        self:save(); self:showGame()
        return
    end
    local exposed = not force and self:willRevealStored()
    if exposed then
        local name = self:cardName(exposed.id)
        self:showOverlay(ButtonDialog:new{
            modal=true,
            title="Stored card warning\n\nDrawing the current top card will reveal " .. name ..
                ", causing it to become un-stored and lose its stored resources.",
            buttons={
                {{ text=_("Draw anyway"), callback=function()
                    self:closeOverlay(false); self:finishManualDraw()
                end }},
                {{ text=_("Stop drawing"), callback=function()
                    self.game.awaiting_draw = false
                    self.game.last_event = "Stopped drawing to keep " .. name .. " stored."
                    self:save(); self:showGame()
                end }},
            },
        })
        return
    end
    self:finishManualDraw()
end

function BeholdCamelot:endTurnTop()
    if self.game.round_end then return end
    local top = self.game.deck[1]
    if not top or top.marker == "realm" then
        if top then self:reachManualRealm() else self:message("The pile is empty.") end
        return
    end
    self:checkpoint()
    table.remove(self.game.deck, 1)
    top.stored = nil
    self.game.deck[#self.game.deck + 1] = top
    self:recordDiscard(top.id)
    self.game.awaiting_draw = #self.game.hand < 5
    self.game.last_event = self:cardName(top.id) .. " discarded from the top. Draw manually to refill your hand."
    local revealed=self.game.deck[1]
    if revealed and revealed.stored then
        revealed.stored=nil
        self:queueEffect(self:cardName(revealed.id).." was revealed by the discard and un-stored; its resources were lost.")
    elseif revealed and revealed.marker=="realm" then self:save(); self:reachManualRealm(); return end
    self:save()
    self:showGame()
end

function BeholdCamelot:storedRevealText(deck_index)
    local pulls = 0
    for index = 1, deck_index - 1 do
        local entry = self.game.deck[index]
        if entry.marker == "realm" then
            return string.format("%d card%s, then Realm (next round)", pulls, pulls == 1 and "" or "s")
        end
        if entry.id then pulls = pulls + 1 end
    end
    if pulls == 0 then return "at pile top: next pull reveals it" end
    return string.format("reveals after %d card%s", pulls, pulls == 1 and "" or "s")
end

function BeholdCamelot:showStored()
    local entries = self:storedEntries()
    local rows = {}
    for _, wrapped in ipairs(entries) do
        local deck_index = wrapped.index
        local entry = wrapped.entry
        rows[#rows + 1] = {{
            text=string.format("%s - %s %d - %s", self:cardLabel(entry.id), entry.stored.kind,
                entry.stored.amount, self:storedRevealText(deck_index)),
            callback=function() self:showStoredCard(deck_index) end,
        }}
    end
    if #rows == 0 then rows[#rows + 1] = {{ text=_("No stored cards"), enabled=false }} end
    rows[#rows + 1] = {{ text=_("Back"), callback=function() self:showGame() end }}
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=_("Stored resource cards"),
        buttons=rows,
    })
end

function BeholdCamelot:showStoredCard(deck_index)
    local entry = self.game.deck[deck_index]
    if not entry or not entry.stored then self:showStored(); return end
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=self:cardDetails(entry.id) .. string.format("\nSTORED AS: %s %d", entry.stored.kind, entry.stored.amount),
        buttons={
            {{ text=_("Back"), callback=function() self:showStored() end }},
        },
    })
end

function BeholdCamelot:spendStored(deck_index)
    self:checkpoint()
    local entry = remove_at(self.game.deck, deck_index)
    if not entry then self:showStored(); return end
    local amount, kind = entry.stored.amount, entry.stored.kind
    entry.stored = nil
    self.game.deck[#self.game.deck + 1] = entry
    self.game.last_event = string.format("Spent %s (%d %s); excess, if any, was lost.", self:cardName(entry.id), amount, kind)
    self:save()
    self:showGame()
end

function BeholdCamelot:showControlled()
    local rows = {}
    for index, id in ipairs(self.game.controlled) do
        local holding_index = index
        rows[#rows + 1] = {{
            text=self:cardLabel(id),
            callback=function() self:showControlledCard(holding_index) end,
        }}
    end
    if #rows == 0 then rows[#rows + 1] = {{ text=_("No controlled holdings"), enabled=false }} end
    rows[#rows + 1] = {{ text=_("Back"), callback=function() self:showGame() end }}
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=_("Controlled holdings"),
        buttons=rows,
    })
end

function BeholdCamelot:showControlledCard(index)
    local id = self.game.controlled[index]
    if not id then self:showControlled(); return end
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=self:cardDetails(id),
        buttons={
            {{ text=_("Full text"), callback=function() self:showFullCardText(id) end }},
            {{ text=_("Back"), callback=function() self:showControlled() end }},
        },
    })
end

function BeholdCamelot:developControlled(index, resolving_action)
    local id = self.game.controlled[index]
    if not id then return end
    local old = self.game.levels[id]
    if old >= 4 then self:message("Already at level 4."); return end
    if not resolving_action then self:checkpoint() end
    self.game.levels[id] = old + 1
    local new_name = self:cardName(id)
    if self:cardType(id) ~= "Holding" then
        remove_at(self.game.controlled, index)
        self.game.deck[#self.game.deck + 1] = { id=id }
        self.game.last_event = new_name .. " developed into a non-Holding and was discarded automatically."
        self:save()
        if not resolving_action then self:showGame() end
        local automatic=new_name .. " is not a Holding after developing. The rules require it to be discarded immediately, so it was moved to the bottom of the pile."
        if not resolving_action then self:showNotice("Automatic: controlled card discarded",automatic) end
        return automatic
    end
    self.game.last_event = new_name .. " developed while controlled."
    self:save()
    if not resolving_action then self:showControlledCard(index) end
end

function BeholdCamelot:showCorrectionMenu()
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title="Correct game state\n\nThese controls bypass normal action costs. Use them only to repair a mistake or reproduce a physical game.",
        buttons={
            {{text=_("Change a hand card level"), callback=function() self:chooseCorrectionCard("level") end}},
            {{text=_("Store a hand card"), callback=function() self:chooseCorrectionCard("store") end}},
            {{text=_("Control a hand card"), callback=function() self:chooseCorrectionCard("conquer") end}},
            {{text=_("Edit controlled Holdings"), callback=function() self:showCorrectionHoldings() end}},
            {{text=_("Spend/discard stored card"), callback=function() self:showCorrectionStored() end}},
            {{text=_("Back"), callback=function() self:showGame() end}},
        },
    })
end

function BeholdCamelot:chooseCorrectionCard(mode)
    local rows={}
    for index,id in ipairs(self.game.hand) do
        local chosen=index
        rows[#rows+1]={{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id),callback=function()
            if mode=="store" then self:storePrintedCard(chosen)
            elseif mode=="conquer" then self:conquer(chosen, true)
            else
                self:showOverlay(ButtonDialog:new{modal=true,title=self:cardLabel(id),buttons={{
                    {text="Develop +1",callback=function() self:changeLevel(id,1) end},
                    {text="Degrade -1",callback=function() self:changeLevel(id,-1) end},
                },{{text=_("Back"),callback=function() self:showCorrectionMenu() end}}}})
            end
        end}}
    end
    rows[#rows+1]={{text=_("Back"),callback=function() self:showCorrectionMenu() end}}
    self:showOverlay(ButtonDialog:new{modal=true,title="Choose hand card",buttons=rows})
end

function BeholdCamelot:showCorrectionHoldings()
    local rows={}
    for index,id in ipairs(self.game.controlled) do
        local chosen=index
        rows[#rows+1]={{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id),callback=function()
            self:showOverlay(ButtonDialog:new{modal=true,title=self:cardLabel(id),buttons={{
                {text="Develop +1",callback=function() self:developControlled(chosen) end},
                {text="Abandon",callback=function() self:abandonHolding(chosen) end},
            },{{text=_("Back"),callback=function() self:showCorrectionHoldings() end}}}})
        end}}
    end
    rows[#rows+1]={{text=_("Back"),callback=function() self:showCorrectionMenu() end}}
    self:showOverlay(ButtonDialog:new{modal=true,title="Correct controlled Holdings",buttons=rows})
end

function BeholdCamelot:showCorrectionStored()
    local rows={}
    for _,wrapped in ipairs(self:storedEntries()) do
        local deck_index=wrapped.index
        rows[#rows+1]={{text=self:cardName(wrapped.entry.id),callback=function() self:spendStored(deck_index) end}}
    end
    rows[#rows+1]={{text=_("Back"),callback=function() self:showCorrectionMenu() end}}
    self:showOverlay(ButtonDialog:new{modal=true,title="Correct stored cards",buttons=rows})
end

function BeholdCamelot:showDeckOrder()
    local lines={}
    for index,entry in ipairs(self.game.deck) do
        if entry.marker then lines[#lines+1]=index..". REALM"
        else lines[#lines+1]=index..". "..self:cardName(entry.id)..(entry.stored and " [stored]" or "") end
    end
    self:showOverlay(TextViewer:new{modal=true,title="Foresight - pile order",text=table.concat(lines,"\n")})
end

function BeholdCamelot:abandonHolding(index)
    self:checkpoint()
    local id = remove_at(self.game.controlled, index)
    if not id then self:showGame(); return end
    self.game.deck[#self.game.deck + 1] = { id=id }
    self:recordDiscard(id)
    self.game.last_event = self:cardName(id) .. " abandoned."
    self:save()
    self:showGame()
end

function BeholdCamelot:developRealm()
    if not self.game.round_end then self:message("Realm develops only at round end."); return end
    if self.game.realm_developed then self:message("Realm has already developed this round."); return end
    if self.game.realm_level >= 4 then self:message("Realm is already the Grail Quest."); return end
    local target=self.game.realm_level+1
    if target==4 and not (self.game.levels.council==1 and self:isCardActive("council")) then
        self:showNotice("Requirement not met","Galahad must be active to develop into The Grail Quest.")
        return
    end
    self:checkpoint()
    local needed=({1,3,4})[self.game.realm_level]
    self.game.realm_payment={target=target,remaining=needed,material_paid=self.game.realm_level~=1}
    self:save(); self:resumeRealmPayment()
end

function BeholdCamelot:resumeRealmPayment()
    local payment=self.game.realm_payment
    if not payment then return end
    local after=function()
        payment.material_paid=true; self:save()
        self:chooseRealmAbandon(payment.target,payment.remaining)
    end
    if payment.material_paid then after() else self:chooseStoredPayment("materials",1,after) end
end

function BeholdCamelot:chooseRealmAbandon(target, remaining)
    if self:showQueuedNotice(function() self:chooseRealmAbandon(target,remaining) end) then return end
    if remaining<=0 then
        self.game.realm_payment=nil
        self.game.realm_level=target; self.game.realm_developed=true
        self.game.last_event="Realm developed to "..REALM_NAMES[target].." after paying its printed requirement."
        self:save(); self:showGame(); return
    end
    local rows={}
    for index,id in ipairs(self.game.controlled) do
        local wealth=self:holdingWealth(id) or 0
        if wealth>0 and (target==2 or wealth<=remaining) then
            local chosen=index
            rows[#rows+1]={{hold_callback=function() self:previewCard(id) end,text=self:cardLabel(id).." (wealth "..wealth..")",callback=function()
                local abandoned=remove_at(self.game.controlled,chosen)
                self.game.deck[#self.game.deck+1]={id=abandoned}
                self:recordDiscard(abandoned)
                local next_remaining=target==2 and 0 or remaining-wealth
                if self.game.realm_payment then self.game.realm_payment.remaining=next_remaining end
                self:save(); self:chooseRealmAbandon(target,next_remaining)
            end}}
        end
    end
    if #rows==0 then self:cancelUnpaidAction("The exact controlled-wealth requirement cannot be paid."); return end
    self:showOverlay(ButtonDialog:new{modal=true,title=target==2 and "Realm development: abandon one controlled Holding" or "Realm development: abandon exactly "..remaining.." more controlled wealth",buttons=rows})
end

function BeholdCamelot:chooseRoundDiscard()
    if #self.game.hand == 0 then
        self:showOverlay(ButtonDialog:new{modal=true,title="No cards remain in hand. Advance the round without a hand discard?",buttons={
            {{text="Advance round",callback=function() self:advanceRound(nil) end}},
            {{text="Back",callback=function() self:showGame() end}},
        }})
        return
    end
    local rows = {}
    for index, id in ipairs(self.game.hand) do
        local chosen_index = index
        rows[#rows + 1] = {{
            text=self:cardLabel(id),
            callback=function() self:advanceRound(chosen_index) end,
        }}
    end
    rows[#rows + 1] = {{ text=_("Cancel"), callback=function() self:showGame() end }}
    self:showOverlay(ButtonDialog:new{
        modal=true,
        title=_("Discard one card to end the round"),
        buttons=rows,
    })
end

function BeholdCamelot:advanceRound(hand_index)
    self:checkpoint()
    local id = hand_index and remove_at(self.game.hand, hand_index) or nil
    if id then self.game.deck[#self.game.deck + 1] = { id=id }; self:recordDiscard(id) end
    local marker_index
    for index, entry in ipairs(self.game.deck) do
        if entry.marker == "realm" then marker_index = index; break end
    end
    if marker_index then table.remove(self.game.deck, marker_index) end
    self.game.deck[#self.game.deck + 1] = { marker="realm" }
    if self.game.round >= self.game.max_rounds then
        self.game.finished = true
        self.game.last_event = "Round " .. self.game.round .. " complete. Score Camelot and the rival."
        self:save()
        self:showGameOver()
        return
    end
    self.game.round = self.game.round + 1
    self.game.round_end = false
    self.game.realm_developed = false
    self.game.awaiting_draw = #self.game.hand < 5
    self.game.last_event = "Round " .. self.game.round .. " begins. Draw manually to refill your hand."
    self:save()
    self:showGame()
end

function BeholdCamelot:confirmFinish()
    self:showOverlay(ConfirmBox:new{
        modal=true,
        text=_("Finish this game and open the scoring checklist?"),
        ok_text=_("Finish"),
        ok_callback=function()
            self:checkpoint()
            self.game.finished = true
            self.game.last_event = "Game finished."
            self:save()
            self:showGameOver()
        end,
    })
end

function BeholdCamelot:activeCardList()
    local zones = {}
    for _, id in ipairs(self.game.hand) do zones[id] = "hand" end
    for _, entry in ipairs(self.game.deck) do if entry.id then zones[entry.id] = entry.stored and "stored" or "deck" end end
    for _, id in ipairs(self.game.controlled) do zones[id] = "controlled" end
    local lines = {}
    for _, card in ipairs(CARDS) do
        lines[#lines + 1] = string.format("L%d %-20s [%s]", self.game.levels[card.id], self:cardName(card.id), zones[card.id] or "-")
    end
    return table.concat(lines, "\n")
end

function BeholdCamelot:showGameOver()
    if self:showQueuedNotice(function() self:showGameOver() end) then return end
    self:closeDialog()
    local title = string.format("Scoring - %s vs %s", REALM_NAMES[self.game.realm_level], self.game.rival)
    self.dialog = ButtonDialog:new{
        title=title,
        buttons={
            {{ text=_("Score breakdown"), callback=function() self:showScoring() end }},
            {{ text=_("Active card list"), callback=function() self:showActiveCards() end }},
            {{ text=_("New game"), callback=function() self:chooseRival() end }},
            {{ text=_("Close"), callback=function() self:closeDialog() end }},
        },
    }
    UIManager:show(self.dialog)
end

function BeholdCamelot:liveScore()
    return Scoring.calculate(self.game, CARD_TYPES, FACE_DATA, HOLDING_WEALTH)
end

function BeholdCamelot:rivalScoreText(s)
    s=s or self:liveScore()
    if not s.rival then return "RIVAL: Chronicle of the Realm\nNo rival categories or target score. Maximize Camelot's Renown.\nCamelot: "..s.total.." Renown" end
    local lines={"RIVAL: "..self.game.rival.." - "..s.rival.." Renown",
        "Current scoring snapshot. Counts use active faces across your whole civilization unless marked controlled."}
    for _,category in ipairs(s.rival_breakdown) do
        lines[#lines+1]=string.format("\n%s: %+d Renown%s\n%s",category.label,category.points,
            category.active and "" or " (inactive: condition not met)",category.formula)
    end
    lines[#lines+1]=string.format("\nRival total: %d Renown\nCamelot total: %d Renown\nCamelot minus rival: %+d Renown",s.rival,s.total,s.total-s.rival)
    lines[#lines+1]="Camelot must finish strictly ahead; ties lose. This is not a final-result prediction."
    return table.concat(lines,"\n")
end

function BeholdCamelot:showScoring()
    local s = self:liveScore()
    local lines = {string.format("Camelot: %d Renown%s", s.total, s.rival and ("   Rival: " .. s.rival) or ""),
        "Live snapshot, not a prediction of the final result. All oriented cards count, including the pile.",
        string.format("Controlled wealth: %d\nCivilization: %d\nRealm: %d\nUncovered unrest: %d (%d unrest, %d prosperity)",
            s.controlled, s.civ, s.realm, s.penalty, s.unrest, s.prosperity), "", "CARD Renown:"}
    for _,card in ipairs(CARDS) do lines[#lines+1] = self:cardName(card.id)..": "..s.cards[card.id] end
    lines[#lines+1]="\n"..self:rivalScoreText(s)
    lines[#lines+1] = "\nICON LEGEND / TOTALS:"
    for _,key in ipairs(Scoring.order) do lines[#lines+1] = key..": "..s.keys[key] end
    lines[#lines+1] = "\nCamelot wins only with strictly more Renown than its rival."
    if self.game.rival=="Lucius" then lines[#lines+1]="Lucius materials term counts printed available-material icons across the civilization, not stored materials (confirmed)." end
    self:showOverlay(TextViewer:new{ modal=true, title=_("Behold: Camelot - live score"), text=table.concat(lines,"\n") })
end

function BeholdCamelot:showActiveCards()
    UIManager:show(TextViewer:new{
        title=_("Active card faces"),
        text=self:activeCardList(),
    })
end

function BeholdCamelot:showStrategy(rival)
    rival=rival or (self.game and self.game.rival)
    if not rival then return end
    self:showOverlay(TextViewer:new{
        modal=true,
        title=_("Strategy vs ") .. rival,
        text=(STRATEGIES[rival] or STRATEGIES["Chronicle of the Realm"]).."\n\nBanner legend: card bands show resource icons (anvil = materials, bust = population, tower = Holding wealth). Keying icons (see the icon legend on the Realm screen): military (sword behind shield), transport, culture, coin, crops, luxury, navy. Numbers are printed counts, not currently stored resources.",
    })
end

function BeholdCamelot:showAbout()
    self:closeDialog()
    UIManager:show(TextViewer:new{
        title=_("About Behold: Camelot"),
        text=[[Behold: Camelot is an Arthurian realm builder card game for KOReader, inspired by Joe Klipfel's Behold: Rome.

If you enjoy this game, please support Joe Klipfel by buying Behold: Rome:
https://www.thegamecrafter.com/games/behold%3A-rome-standard-edition-

The Arthurian names and descriptive labels are a thematic adaptation, not a literal account of the legends. This project is not affiliated with or endorsed by Joe Klipfel or the publisher.]],
    })
end

return BeholdCamelot
