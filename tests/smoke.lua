-- Headless lifecycle/layout smoke test for the persistent Behold: Camelot screen.
local function class(methods)
    local root = methods or {}
    function root:extend(fields)
        fields = fields or {}; fields.__index = fields
        return setmetatable(fields, { __index=self })
    end
    function root:new(fields)
        local object = self:extend(fields)
        if object._init then object:_init() end
        if object.init then object:init() end
        return object
    end
    return root
end

local screen_w, screen_h = 600, 800
local shown, dirty_count = nil, 0
local function geom(fields)
    function fields:contains(pos)
        return pos.x >= self.x and pos.x < self.x + self.w
            and pos.y >= self.y and pos.y < self.y + self.h
    end
    return fields
end

package.preload["ui/widget/container/widgetcontainer"] = function() return class() end
package.preload["ui/widget/container/inputcontainer"] = function()
    return class{ _init=function(self) self.ges_events = {}; self.key_events = {} end }
end
package.preload["ffi/blitbuffer"] = function()
    local module = { COLOR_BLACK=0, COLOR_DARK_GRAY=1, COLOR_GRAY=2, COLOR_LIGHT_GRAY=3, COLOR_WHITE=4, TYPE_BB8=1 }
    local function makebb(w, h)
        return {
            w=w, h=h,
            paintRect=function() end, paintBorder=function() end, blitFrom=function() end,
            rotatedCopy=function(self) return makebb(self.w, self.h) end,
            free=function() end,
        }
    end
    module.new = makebb
    return module
end
package.preload["device"] = function()
    return { screen={ getWidth=function() return screen_w end, getHeight=function() return screen_h end } }
end
package.preload["ui/geometry"] = function() return { new=function(_, fields) return geom(fields) end } end
package.preload["ui/gesturerange"] = function() return { new=function(_, fields) return fields end } end
for _, name in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/textviewer" }) do
    package.preload[name] = function() return { new=function(_, fields) return fields or {} end } end
end
package.preload["datastorage"] = function() return { getSettingsDir=function() return "." end } end
package.preload["luasettings"] = function()
    return { open=function() return { readSetting=function() end, saveSetting=function() end, flush=function() end } end }
end
package.preload["ui/font"] = function()
    return { getFace=function(_, _, size)
        local pixels=size*screen_w/600
        return {pixels=pixels,ftsize={getHeightAndAscender=function() return pixels*1.2,pixels end}}
    end }
end
package.preload["ui/rendertext"] = function()
    return {
        sizeUtf8Text=function(_, _, width, face, text) return { x=math.min(width, #tostring(text) * face.pixels * 0.6) } end,
        truncateTextByWidth=function(_, text, _, width) return text:sub(1, math.max(1, math.floor(width / 7))) end,
        renderUtf8Text=function() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show=function(_, widget) shown=widget end,
        close=function() end,
        setDirty=function() dirty_count=dirty_count + 1 end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end

local project_root=(debug.getinfo(1,"S").source:match("^@(.*/)") or "").."../"
local plugin = dofile(project_root.."beholdcamelot.koplugin/main.lua")
plugin.settings = { saveSetting=function() end, flush=function() end }
plugin.game = {
    rival="Mordred", round=3, max_rounds=12, realm_level=2, realm_developed=false,
    round_end=false, awaiting_draw=false, finished=false, last_event="Camelot is ready for the next action.",
    levels={ crafts=1, host=1, works=1, council=4, customs=1, kin=1,
        lake=1, gaul=1, allies=1, wounds=4, grail=1, marches=1,
        camelot=1, dues=1, trade=1, claims=1 },
    hand={"crafts", "host", "works", "customs", "camelot"},
    controlled={"allies"},
    deck={{id="trade"}, {id="dues", stored={kind="population", amount=1}}, {marker="realm"}},
}

local bb = { paintRect=function() end, paintBorder=function() end, blitFrom=function() end }
for _, dimensions in ipairs({ {600,800}, {758,1024}, {1072,1448}, {1272,1696} }) do
    screen_w, screen_h = dimensions[1], dimensions[2]
    plugin.dialog, plugin.overlay, shown = nil, nil, nil
    plugin:showGame()
    local board = plugin.dialog
    assert(board and board.name == "beholdcamelot_game" and board.paintTo, "persistent game screen was not shown")
    board:paintTo(bb, 0, 0)
    assert(#board.tap_holdings == 17, "expected close, score, pile top, five hand cards, and nine controls")
    for _, holding in ipairs(board.tap_holdings) do
        local rect = holding.rect
        assert(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= screen_w + 1
            and rect.y + rect.h <= screen_h + 1, "tap target escaped the screen")
    end
    board:focus(1)
    board:paintTo(bb, 0, 0)
    assert(board.view_mode == "focus" and board.selected_index == 1,
        "tapping a hand card did not enter focused-card mode")
    assert(#board.tap_holdings == 16, "focused view has unexpected tap target count: " .. #board.tap_holdings)
    assert(next(board.face_cache), "focused view did not cache its rotated card face")
    board:moveFocus(1)
    assert(board.selected_index == 2, "right navigation did not select the next hand card")
    board:moveFocus(-1)
    assert(board.selected_index == 1, "left navigation did not select the previous hand card")
    local actions = plugin:focusedCardActions(1)
    actions[1].callback()
    assert(plugin.dialog == board and plugin.game.action and plugin.game.action.source == "crafts",
        "playing from focused mode did not start a guided action")
    plugin:cancelUnpaidAction("test reset")
    assert(not plugin.game.action and plugin.game.hand[1] == "crafts",
        "undoing a guided action did not restore its source card")
    board:overview()
    assert(board.view_mode == "overview", "tapping the focused card did not restore overview mode")
    print(string.format("Behold: Camelot UI %dx%d: fixed layout and overlay lifecycle passed", screen_w, screen_h))
end

-- End-of-turn refill is manual and warns before exposing a stored card.
plugin.game.hand = {"crafts", "host", "works", "customs"}
plugin.game.deck = {
    {id="trade"},
    {id="dues", stored={kind="population", amount=1}},
    {marker="realm"},
}
plugin.game.awaiting_draw = true
plugin.game.round_end = false
plugin:manualDraw()
assert(plugin.overlay and plugin.overlay.title:find("Stored card warning", 1, true),
    "manual draw did not warn before exposing a stored card")
assert(#plugin.game.hand == 4 and plugin.game.deck[2].stored,
    "warning changed state before the player confirmed")
plugin.overlay.buttons[1][1].callback()
assert(#plugin.game.hand == 5 and plugin.game.deck[1].id == "dues" and not plugin.game.deck[1].stored,
    "confirmed draw did not draw one and release the exposed stored card")
assert(plugin.overlay and plugin.overlay.title:find("Automatic: stored card released", 1, true),
    "automatic stored-card release was not explained")

-- A controlled card that develops away from Holding is discarded immediately.
plugin:closeOverlay(false)
plugin.game.levels.lake = 3
plugin.game.controlled = {"lake"}
plugin.game.deck = {{marker="realm"}}
plugin:developControlled(1)
assert(#plugin.game.controlled == 0 and plugin.game.deck[#plugin.game.deck].id == "lake",
    "non-Holding controlled development was not discarded")
assert(plugin.overlay and plugin.overlay.title:find("Automatic: controlled card discarded", 1, true),
    "automatic controlled-card discard was not explained")

-- Banner restrictions are enforced before an action starts.
plugin.game.realm_level = 1
plugin.game.levels.lake = 4
assert(not plugin:isPlayLegal("lake"), "an Quest-era-only face was legal under The Crown")
plugin.game.realm_level = 3
assert(plugin:isPlayLegal("lake"), "an Quest-era-only face was illegal under Arthur's Empire")

-- A fifth conquest succeeds first, then requires abandoning one of the four
-- previously controlled Holdings.
plugin:closeOverlay(false)
plugin.game.levels.allies, plugin.game.levels.marches = 1, 1
plugin.game.levels.grail, plugin.game.levels.gaul = 1, 2
plugin.game.levels.wounds = 2
plugin.game.hand = {"allies"}
plugin.game.controlled = {"marches", "grail", "gaul", "wounds"}
plugin.game.action = {source="host", source_available=true, spec={label="test conquest"}, used={}, conquests={1}, costs={}}
plugin:resolveConquerBenefit()
plugin.overlay.buttons[1][1].callback()
assert(#plugin.game.controlled == 5, "the fifth Holding was refused before mandatory abandonment")
plugin.overlay.buttons[1][1].callback()
assert(#plugin.game.controlled == 4 and plugin.game.action.used.conquer,
    "mandatory post-conquest abandonment did not restore the four-Holding limit")

-- Developing a hand card into a Ally requires an abandonment first.
plugin:closeOverlay(false)
plugin.game.realm_level = 3
plugin.game.levels.lake, plugin.game.levels.allies = 3, 1
plugin.game.hand, plugin.game.controlled = {"lake"}, {"allies"}
plugin.game.action = {source="crafts", source_available=true,
    spec={label="test development",develop=1}, used={}, developed={}, conquests={}, costs={}}
plugin:resolveDevelop()
plugin.overlay.buttons[1][1].callback()
assert(plugin.overlay and plugin.overlay.title:find("Ally", 1, true),
    "Ally development did not request a controlled Holding abandonment")
plugin.overlay.buttons[1][1].callback()
assert(plugin.game.levels.lake == 4 and #plugin.game.controlled == 0,
    "Ally development did not consume its mandatory abandonment")

assert(dirty_count > 0, "game screen was never marked dirty")
-- Independent scoring-assistant fixtures: all faces L1, then one face changed.
local ids={"gaul","marches","grail","allies","wounds","lake","trade","camelot","host","works","crafts","claims","council","kin","customs","dues"}
local expected={
 {-4,-3,-7},{-7,-7,-2},{-12,-9,-4},{-6,-5,-6},{3,0,-10},{0,-4,-5},
 {-8,-9,-9},{-8,-11,-16},{-7,-10,-12},{-11,-9,-10},{-8,-7,-5},{-7,-6,-7},
 {-6,-7,-13},{6,-1,-1},{-22,-13,-7},{-6,-8,-12},
}
plugin.game.realm_level=1; plugin.game.rival="Morgan le Fay"; plugin.game.controlled={}
for _,id in ipairs(ids) do plugin.game.levels[id]=1 end
local baseline=plugin:liveScore()
assert(baseline.total==-8 and baseline.rival==79, "baseline score: "..baseline.total)
for i,id in ipairs(ids) do for l=2,4 do
 plugin.game.levels[id]=l
 local s=plugin:liveScore()
 assert(s.total==expected[i][l-1], id.." L"..l.." expected "..expected[i][l-1].." got "..s.total)
 plugin.game.levels[id]=1
end end
-- A card in the pile is still active.
plugin.game.hand={}; plugin.game.deck={{id="council"}}
assert(plugin:isCardActive("council"))
plugin.game.rival_modifier=20
assert(plugin:liveScore().rival==99,"rival difficulty was ignored")
plugin.game.rival_modifier=0
-- Customs of the Court is offered while paying a cost, not as an independent degrade.
plugin.game.hand={"customs","wounds"}; plugin.game.levels.wounds=4
plugin.game.awaiting_draw=false; plugin.game.round_end=false; plugin.game.action=nil
plugin:startPlayAction(1)
assert(plugin.game.action==nil and #plugin.game.hand==2,"standalone Customs of the Court consumed a card")
plugin.game.action={source="host",spec={label="test"},costs={discard=1,degrade=1},used={},conquests={}}
plugin:continueActionCosts("discard")
local interrupt
for _,row in ipairs(plugin.overlay.buttons) do if row[1].text:find("Play Customs of the Court",1,true) then interrupt=row[1].callback end end
assert(interrupt,"cost chooser did not offer Customs of the Court")
interrupt()
assert(plugin.game.action.source=="customs" and plugin.game.action_stack[1].costs.discard==0)
plugin.game.action.spec.draw=nil; plugin.game.action.used.draw=true
plugin:finishAction()
assert(plugin.game.action.source=="host" and plugin:actionCostKey()=="degrade","interrupt skipped remaining costs")
assert(plugin.game.levels.wounds==4,"Customs of the Court incorrectly degraded the war")
print("Behold: Camelot UI, 49 scoring fixtures, difficulty and interrupt tests passed")

local function fresh(hand,levels,controlled,deck)
 plugin:closeOverlay(false)
 local ls={}; for _,id in ipairs(ids) do ls[id]=1 end
 for id,l in pairs(levels or {}) do ls[id]=l end
 plugin.game={levels=ls,hand=hand,controlled=controlled or {},deck=deck or {{id="trade"},{id="camelot"},{marker="realm"}},
  realm_level=3,round=1,max_rounds=12,rival="Lucius",round_end=false,awaiting_draw=false}
 plugin:checkpoint()
end
local function click(text)
 for _,row in ipairs(plugin.overlay.buttons) do for _,b in ipairs(row) do if b.text:find(text,1,true) then b.callback(); return end end end
 error("Missing button: "..text.." in "..tostring(plugin.overlay.title))
end
local function notices()
 while plugin.overlay and plugin.overlay.title and plugin.overlay.title:find("Automatic effect",1,true) do click("OK") end
end
fresh({"customs","council"},{customs=3,council=2})
plugin:beginAction(1,plugin:actionOptions("customs")[1]); click("The Round Table")
assert(plugin.game.action.spec.draw==2,"Merlin's Counsel prosperity count")
plugin:resolveActionDraw(); assert(plugin.game.action.spec.draw==1,"draw must advance one card")
fresh({"customs","crafts","wounds","marches"},{customs=3,wounds=4})
plugin:beginAction(1,plugin:actionOptions("customs")[2]); click("Local Craft"); click("Balin's Fatal Quest")
assert(plugin.game.action.conquests[1]==4,"Merlin's Counsel unrest count")
fresh({"customs","host"},{customs=4,allies=2,marches=3},{"allies","marches"})
plugin:beginAction(1,plugin:actionOptions("customs")[1]); click("Abandon"); click("Abandon"); click("Develop 5")
assert(plugin.game.action.spec.develop==5 and not plugin.game.action.spec.degrade and #plugin.game.controlled==0,"The Holy Grail exact wealth/choice")
fresh({"lake","marches"},{lake=4,allies=2},{"allies"})
plugin:beginAction(1,plugin:actionOptions("lake")[1]); click("Abandon"); click("Conquer 4")
assert(plugin.game.action.conquests[1]==4,"Lucius wealth +2")
fresh({"marches","dues","host"},{marches=2,dues=4})
plugin.game.realm_level=2
plugin:beginAction(1,plugin:actionOptions("marches")[1]); click("Extraordinary Levy"); click("Draw 4")
assert(plugin.game.action.spec.draw==4,"Cornwall must count bags not Provision cards")
fresh({"kin","crafts"},{kin=3,gaul=3,allies=2},{"gaul","allies"})
plugin:beginAction(1,plugin:actionOptions("kin")[1])
assert(plugin.game.action.spec.store_materials==3,"Gaheris controlled bags")
fresh({"kin","marches"},{})
plugin.game.realm_level=1
plugin.game.action={source="host",source_level=1,source_available=false,spec={},costs={},conquests={1,2},used={},developed={}}
plugin:beginAction(1,plugin:actionOptions("kin")[1]); notices(); plugin:finishAction()
assert(plugin.game.action.conquests[1]==2 and plugin.game.action.conquests[2]==2,"Gawain boosts only pending conquest")
fresh({"allies","marches"},{allies=4})
plugin.game.action={source="host",source_level=1,source_available=true,spec={},costs={},conquests={1},used={},developed={}}
plugin:showActionResolution(); click("King Ban instead"); notices()
assert(plugin.game.hand[2]=="host" and not plugin.game.action.source_available,"King Ban returns source")
assert(plugin.game.deck[#plugin.game.deck].id=="allies","King Ban discarded")
fresh({"council","wounds","trade"},{council=4,wounds=4})
plugin.game.realm_level=1
plugin:beginAction(1,plugin:actionOptions("council")[1]); click("Balin's Fatal Quest"); notices()
assert(plugin.game.levels.wounds==3 and plugin.game.action.spec.store_materials==2 and plugin.game.action.ineligible.wounds,"War degrade trigger")
fresh({"works"},{},{},{{id="trade"},{id="dues",stored={kind="population",amount=1}},{marker="realm"}})
plugin.game.action={source="allies",source_available=false,spec={draw=2},costs={},conquests={},used={},developed={}}
plugin:resolveActionDraw()
assert(plugin.overlay.title:find("Stored card warning",1,true) and #plugin.game.hand==1 and plugin.game.deck[2].stored,"warning must precede mutation")
click("Draw anyway"); notices()
assert(#plugin.game.hand==2 and not plugin.game.deck[1].stored and plugin.game.action.spec.draw==1,"reveal releases stored card")
fresh({"gaul"},{gaul=3})
plugin.game.action={source="host",source_available=false,spec={},costs={},conquests={2},used={},developed={}}
plugin:resolveConquerBenefit(); click("Brittany"); notices()
assert(plugin.game.action.spec.store_population==2,"Brittany conquest trigger")
fresh({"allies"},{allies=3})
plugin.game.action={source="host",source_available=false,spec={},costs={},conquests={4},used={},developed={}}
plugin:resolveConquerBenefit(); click("Benwick"); notices()
assert(plugin.game.action.spec.draw==2,"Caerleon conquest trigger")
fresh({"kin"},{kin=2})
plugin.game.action={source="council",source_level=2,source_available=false,spec={},costs={},conquests={},used={},developed={}}
plugin:recordDiscard("kin")
assert(plugin.game.action.optional_draw==1,"Gareth discard trigger")
plugin.game.levels.kin=1; plugin:recordDiscard("kin")
assert(plugin.game.action.gawain_refill,"Round Table/Gawain refill trigger")
plugin.game.levels.wounds=2; plugin:recordDiscard("wounds")
assert(plugin.game.levels.wounds==1,"Wounds discard trigger")
print("Special-action calculations, interrupts, triggers and stored-draw timing passed")
fresh({"lake","dues"},{})
plugin.game.action={source="council",source_available=false,spec={store_population=1},costs={},conquests={},used={},developed={}}
plugin:resolveStoreBenefit("population"); click("Almsgiving"); click("Guinevere: store for free")
assert(plugin.game.deck[#plugin.game.deck].id=="lake" and plugin.game.deck[#plugin.game.deck].stored.amount==1,"Guinevere free storage")
fresh({"works"},{},{},{{id="trade"},{id="dues",stored={kind="population",amount=1}},{marker="realm"}})
plugin.game.action={source="allies",source_available=false,spec={draw=2},costs={},conquests={},used={draw=true},developed={}}
plugin:resolveActionDraw(); click("Stop drawing")
assert(plugin.game.deck[2].stored and #plugin.game.hand==1 and not plugin.game.action.spec.draw,"stop must preserve stored card")
fresh({"gaul"},{gaul=3})
plugin:beginAction(1,plugin:actionOptions("gaul")[1])
assert(not plugin.game.action and plugin.game.hand[1]=="gaul","on-conquest effect illegally played standalone")
print("Guinevere storage, voluntary draw stop, and trigger-only guard passed")

-- Combined costs can be paid with one multi-resource card, in either order.
fresh({"crafts","host","works","marches"},{trade=2},{},{{id="trade",stored={kind="materials",amount=2}},{marker="realm"}})
plugin:beginAction(1,plugin:actionOptions("crafts")[1])
click("Discard + 1M"); click("Discard + 1M"); click("Pay selected costs")
assert(plugin.game.action.costs.discard==2 and plugin.game.action.costs.materials==2)
click("Pay materials"); click("Quarries")
assert(plugin.game.action.costs.materials==0 and plugin.game.action.costs.discard==2,"materials-first payment")
click("Retainers"); click("Armourers")
assert(plugin.game.action.spec.develop==2 and not plugin:actionCostKey(),"Crafts must discard once per repetition")
-- Mixed resource store rewards are chosen independently and pooled.
fresh({"dues","host","works","council"},{dues=3,council=2})
plugin:beginAction(1,plugin:actionOptions("dues")[1])
click("Discard: store 2M"); click("Discard: store 1P"); click("Pay selected costs")
click("Retainers"); click("Armourers")
assert(plugin.game.action.spec.store_materials==2 and plugin.game.action.spec.store_population==1)
-- Mixed Host payment methods and mixed level-4 benefits.
fresh({"host","works","marches"},{host=3,works=2},{},{{id="dues",stored={kind="population",amount=1}},{marker="realm"}})
plugin:beginAction(1,plugin:actionOptions("host")[1])
click("Pay 1P"); click("Degrade 1"); click("Pay selected costs")
click("Pay degrade"); click("Stonework"); click("Almsgiving")
assert(#plugin.game.action.conquests==2 and plugin.game.levels.works==1)
fresh({"host","marches"},{host=4},{},{{id="dues",stored={kind="population",amount=2}},{marker="realm"}})
plugin:beginAction(1,plugin:actionOptions("host")[1])
click("conquer 2"); click("degrade 1"); click("Pay selected costs"); click("Almsgiving")
assert(plugin.game.action.conquests[1]==2 and plugin.game.action.spec.degrade==1)

local function developAction(controlled)
 plugin.game.action={source="crafts",source_available=false,spec=controlled and {develop_controlled=1} or {develop=1},costs={},conquests={},used={},developed={}}
end
fresh({"gaul"},{},{},{{id="trade",stored={kind="materials",amount=1}},{marker="realm"}})
plugin.game.realm_level=1; developAction()
plugin:resolveDevelop(); click("King Claudas")
assert(plugin.game.levels.gaul==1,"Gaul developed before paying extra material")
click("Grain Stores"); assert(plugin.game.levels.gaul==2)
fresh({"gaul"},{gaul=3,allies=3,marches=1},{"marches"})
assert(not plugin:canDevelopInto("gaul",4),"King Lot needs King Ban")
plugin.game.levels.allies=4; assert(plugin:canDevelopInto("gaul",4))
fresh({"marches"},{marches=3,allies=1},{"allies"}); developAction()
plugin:resolveDevelop(); click("Logres")
assert(plugin.game.levels.marches==3 and plugin.overlay.title:find("Guarding",1,true))
click("Caerleon"); assert(plugin.game.levels.marches==4 and #plugin.game.controlled==0)
fresh({},{marches=3,allies=1},{"allies","marches"}); developAction(true)
plugin:resolveControlledDevelopBenefit(); click("Logres"); click("Caerleon"); notices()
assert(plugin.game.levels.marches==4 and #plugin.game.controlled==0,"controlled development must re-find target after abandonment")
fresh({},{marches=3},{"marches"})
assert(not plugin:canDevelopInto("marches",4),"cannot abandon the same development target")

local function fluid(round)
 fresh({"works"},{},{},{{id="trade"},{marker="realm"},{id="dues"},{id="camelot"}})
 plugin.game.fluid_round=true; plugin.game.round=round or 1
 plugin.game.action={source="allies",source_available=false,spec={draw=3},costs={},conquests={},used={},developed={}}
end
fluid(); plugin:resolveActionDraw(); click("Continue into next round"); notices()
assert(plugin.game.round==2 and plugin.game.action.spec.draw==2 and not plugin.game.round_end)
plugin:resolveActionDraw(); assert(plugin.game.hand[#plugin.game.hand]=="dues" and plugin.game.action.spec.draw==1)
fluid(); plugin:resolveActionDraw(); click("Stop at Realm"); notices()
assert(plugin.game.round==1 and plugin.game.round_end and not plugin.game.action.spec.draw and plugin.game.deck[1].marker=="realm")
fluid(12); plugin:resolveActionDraw(); notices()
assert(plugin.game.round==12 and plugin.game.round_end,"Fluid Round must not start round 13")
fluid(); plugin.game.deck[3].stored={kind="population",amount=1}; plugin:resolveActionDraw()
assert(plugin.overlay.title:find("loses its stored resources",1,true) and plugin.game.deck[2].stored)
click("Continue into next round"); notices(); assert(not plugin.game.deck[1].stored)
print("Payment ordering, mixed repetitions, development requirements and Fluid Round passed")
-- Hand-calculated all-L1 fixtures for every realm and rival (not generated by
-- the implementation under test): bags=2, sprouts=2, lyres=2, ships=1,
-- military=5, available materials=8, three Holdings, prosperity=2.
local camelot_by_realm={-8,-1,1,2}
local rivals={["Morgan le Fay"]={79,79,94,146},Mordred={87,82,80,80},["King Lot"]={99,99,99,99},Lucius={140,140,116,140}}
for realm=1,4 do for rival,expected in pairs(rivals) do
 fresh({},{}); plugin.game.realm_level=realm; plugin.game.rival=rival
 local s=plugin:liveScore()
 assert(s.total==camelot_by_realm[realm],"realm baseline "..realm..": "..s.total)
 assert(s.rival==expected[realm],rival.." realm "..realm..": "..s.rival)
end end
fresh({},{gaul=2},{"gaul"}); plugin.game.realm_level=1; plugin.game.rival="King Lot"
local s=plugin:liveScore()
assert(s.keys.military==11 and s.rival==94,"controlled Gaul must cross military threshold")
-- An interrupt inside an already-interrupted action must unwind one frame at
-- a time and preserve both remaining cost and generated conquest strength.
fresh({"customs","kin","marches"},{})
plugin.game.realm_level=1
local parent={source="host",source_level=3,source_available=false,spec={label="outer"},costs={discard=1},conquests={1},used={},developed={}}
plugin.game.action=parent
plugin:beginAction(1,plugin:actionOptions("customs")[1])
-- Synthetic pending conquest on the middle frame isolates stack behavior.
local middle=plugin.game.action; middle.conquests={1}
plugin:beginAction(1,plugin:actionOptions("kin")[1]); notices(); plugin:finishAction()
assert(plugin.game.action==middle and middle.conquests[1]==2 and #plugin.game.action_stack==1)
middle.conquests={}; middle.spec.draw=nil; middle.used.draw=true
plugin:finishAction()
assert(plugin.game.action==parent and parent.costs.discard==0 and parent.conquests[1]==1)
print("All-realm/rival arithmetic fixtures and nested-interrupt stack passed")
-- Pay a material cost using storage triggered by an earlier degrade cost.
fresh({"claims","wounds","trade","marches"},{wounds=4,trade=2},{},{{marker="realm"}})
plugin:beginAction(1,plugin:actionOptions("claims")[2]); click("Pay degrade"); click("Balin's Fatal Quest"); notices()
assert(#plugin.game.action_stack==1 and plugin.game.action.spec.store_materials==2)
plugin:resolveStoreBenefit("materials"); click("Quarries"); plugin:finishAction()
assert(plugin.game.action.source=="claims" and plugin.game.action.costs.materials==2)
click("Quarries")
assert(not plugin:actionCostKey() and plugin.game.action.spec.develop==1,"trigger-generated resources must pay later costs")
-- Each distinct store type needs at least partial resolution.
fresh({"host","dues"},{},{},{{marker="realm"}})
plugin.game.action={engine_version=11,source="camelot",source_available=false,spec={store_materials=2,store_population=2},costs={},conquests={},used={},developed={}}
plugin:resolveStoreBenefit("materials"); click("Retainers"); plugin:finishAction()
assert(plugin.game.action and plugin.game.action.used.store_materials and not plugin.game.action.used.store_population)
plugin:resolveStoreBenefit("population"); click("Almsgiving"); plugin:finishAction()
assert(not plugin.game.action,"partial resolution of both store types should suffice")
-- Holding the source is an explicit choice, never automatic.
fresh({"trade","works"},{trade=2},{},{{id="dues"},{marker="realm"}})
plugin:beginAction(1,{label="test store/draw",store_materials=2,draw=1})
assert(plugin.overlay.title:find("intend to store",1,true))
click("Discard before resolving benefits")
assert(not plugin.game.action.source_available and plugin.game.deck[#plugin.game.deck].id=="trade")
fresh({"trade","works"},{trade=2},{},{{id="dues"},{marker="realm"}})
plugin:beginAction(1,{label="test source reservation",store_materials=2})
click("Keep played card for storage")
assert(plugin.game.action.reserve_source and plugin.game.action.source_available and #plugin.game.deck==2)
plugin:resolveStoreBenefit("materials"); click("Played card"); plugin:finishAction()
assert(not plugin.game.action and plugin.game.deck[#plugin.game.deck].stored)
-- Out-of-action discard routes apply Wounds's degradation and explain it.
fresh({},{wounds=2},{"wounds"}); plugin.game.realm_level=1
plugin:chooseRealmAbandon(2,1); click("The Wounded Lands")
assert(plugin.game.levels.wounds==1 and plugin.overlay.title:find("Automatic effect",1,true))
click("OK"); assert(plugin.game.realm_level==2)
fresh({"wounds"},{wounds=2}); plugin:advanceRound(1)
assert(plugin.game.levels.wounds==1 and plugin.overlay.title:find("Automatic effect",1,true))
click("OK")
-- Older action state is preserved and blocked, not guessed into new semantics.
fresh({"works"},{})
plugin.game.action={source="trade",spec={},costs={},used={},conquests={}}
local old_action=plugin.game.action
plugin.legacy_action_blocked=true; plugin:showGame()
assert(plugin.game.action==old_action and plugin.overlay.title:find("Older in-progress",1,true))
plugin.legacy_action_blocked=nil
print("Payment-time triggers, distinct benefits, source timing, Wounds routes and legacy guard passed")
-- The Pentecostal Oath must actually develop a controlled Holding before finishing.
fresh({"customs","works"},{customs=2,works=2,allies=1},{"allies"})
plugin.game.realm_level=1
plugin:beginAction(1,plugin:actionOptions("customs")[1]); click("Stonework")
local oath=plugin.game.action
plugin:finishAction()
assert(plugin.game.action==oath and plugin.game.levels.allies==1,"Oath finished without its controlled development")
plugin:resolveControlledDevelopBenefit(); click("Caerleon")
assert(plugin.game.levels.allies==2 and oath.used.develop_controlled)
plugin:finishAction(); assert(not plugin.game.action,"resolved Oath should finish")
-- Every passive option rejects direct play before consuming cards or costs.
local passive_count=0
for _,id in ipairs(ids) do for level=1,4 do
 fresh({id},{[id]=level})
 for _,option in ipairs(plugin:actionOptions(id)) do if option.passive then
  local old_deck=#plugin.game.deck
  local old_undo=plugin.undo_game
  plugin:beginAction(1,option)
  assert(not plugin.game.action and plugin.game.hand[1]==id and #plugin.game.deck==old_deck and plugin.undo_game==old_undo,
      "passive play mutated state: "..id.." L"..level)
  passive_count=passive_count+1
 end end
end end
assert(passive_count>0)
fresh({"gaul"},{gaul=1}); plugin.game.realm_level=1
plugin:startPlayAction(1)
assert(not plugin.game.action and plugin.game.hand[1]=="gaul","UI path allowed passive play")
plugin:discardHand(1,true)
assert(#plugin.game.hand==0 and plugin.game.awaiting_draw and plugin.game.deck[#plugin.game.deck].id=="gaul",
    "normal end-turn discard must remain available")
print("Oath completion and all "..passive_count.." passive option guards passed")
fresh({"marches"},{marches=2}); plugin.game.realm_level=1; plugin.game.round_end=true
plugin:startPlayAction(1); assert(not plugin.game.action and plugin.game.hand[1]=="marches")
fresh({"customs"},{customs=3}); plugin.game.round_end=true
local original_begin=plugin.beginAction; local selected_option
plugin.beginAction=function(_,index,option) selected_option=option end
plugin:startPlayAction(1); plugin.beginAction=original_begin
assert(selected_option and selected_option.counsel=="conquer","only Merlin's Counsel's non-draw option should remain")
fresh({"lake"},{lake=3,kin=4}); plugin.game.realm_level=1
assert(plugin:isPlayLegal("lake") and not plugin:isPlayLegal("lake",nil,true))
assert(not plugin:canDevelopInto("lake",3),"The Last Battle must not exempt development banners")
plugin.game.action={source="host",spec={},conquests={4},used={},costs={}}
plugin:closeOverlay(false); plugin:resolveConquerBenefit()
assert(not plugin.overlay,"illegal Quest-era conquest must not be offered")
fresh({"works"},{},{},{{id="trade"},{marker="realm"},{id="dues",stored={kind="population",amount=1}}})
plugin.game.fluid_round=true; plugin.game.awaiting_draw=true
plugin:manualDraw(); assert(plugin.game.round==1 and plugin.overlay.title:find("Fluid Round",1,true))
click("Continue into next round"); notices()
assert(plugin.game.round==2 and not plugin.game.deck[1].stored)
fresh({"works"},{},{},{{marker="realm"},{id="trade"}})
plugin.game.fluid_round=true; plugin.game.awaiting_draw=true; plugin.game.round=12
plugin:manualDraw(); notices(); assert(plugin.game.round==12 and plugin.game.round_end)
print("Draw classification, strict banners, and manual Fluid Round passed")
fresh({},{}); plugin.game.round_end=true
plugin:chooseRoundDiscard(); click("Advance round")
assert(plugin.game.round==2 and plugin.game.awaiting_draw,"empty hand cannot trap round end")
fresh({"works"},{}); plugin.undo_game=nil
local preserved=plugin.game
plugin:cancelUnpaidAction("test missing snapshot")
assert(plugin.game==preserved,"missing snapshot must not erase the game")
fresh({"allies"},{allies=3}); plugin.game.round_end=true
plugin.game.action={source="host",spec={},conquests={4},costs={},used={}}
plugin:closeOverlay(false); plugin:resolveConquerBenefit()
assert(not plugin.overlay,"mandatory-draw conquest must not be offered at round end")

-- Bounded randomized UI walks check physical-card conservation after every
-- transition. Alternate real initial decks and synthetic legal orientations.
local function conserved(seed,step)
 local g=plugin.game; local counts={}; local markers=0
 local function add(id) assert(g.levels[id],"unknown card"); counts[id]=(counts[id] or 0)+1 end
 for _,id in ipairs(g.hand) do add(id) end
 for _,id in ipairs(g.controlled) do add(id); assert(plugin:holdingWealth(id),"non-Holding controlled") end
 for _,entry in ipairs(g.deck) do if entry.marker then markers=markers+1 else add(entry.id) end end
 if g.action and g.action.source_available then add(g.action.source) end
 for _,a in ipairs(g.action_stack or {}) do if a.source_available then add(a.source) end end
 for _,id in ipairs(ids) do assert(counts[id]==1,"card conservation seed "..seed.." step "..step.." "..id.." count "..tostring(counts[id])) end
 assert(markers==1 and g.round<=g.max_rounds)
 for _,level in pairs(g.levels) do assert(level>=1 and level<=4) end
end
local walked,completed=0,0
for seed=1,80 do
 math.randomseed(seed)
 plugin:newGame("Mordred",{game_difficulty="Normal",rival_difficulty="Normal",fluid_round=seed%2==0})
 if seed%2==0 then
  for _,id in ipairs(ids) do plugin.game.levels[id]=math.random(4) end
  plugin.game.realm_level=math.random(4)
  local stored=0
  for i=6,#plugin.game.deck do local entry=plugin.game.deck[i]
   if entry.id then local kind,amount=plugin:printedStore(entry.id)
    if kind and stored<4 then entry.stored={kind=kind,amount=amount}; stored=stored+1 end
   end
  end
 end
 for step=1,2000 do
  conserved(seed,step); walked=walked+1
  local g=plugin.game
  if g.finished then completed=completed+1; break end
  if plugin.overlay and plugin.overlay.buttons then
   local choices={}
   for _,row in ipairs(plugin.overlay.buttons) do for _,b in ipairs(row) do if b.callback and b.enabled~=false then choices[#choices+1]=b end end end
   if #choices>0 then choices[math.random(#choices)].callback() else plugin:closeOverlay(false) end
  elseif g.action then plugin:continueActionCosts()
  elseif g.awaiting_draw then plugin:manualDraw()
  elseif g.round_end then
   plugin:advanceRound(#g.hand>0 and math.random(#g.hand) or nil)
  elseif #g.hand>0 and math.random(3)~=1 then plugin:startPlayAction(math.random(#g.hand))
  else plugin:endTurnTop() end
 end
end
print("Randomized UI conservation checks passed over "..walked.." transitions; "..completed.." games completed")
fresh({},{allies=1,marches=2},{"allies","marches"})
plugin.game.realm_level=2; plugin.game.round_end=true
plugin:developRealm(); click("Caerleon")
assert(plugin.game.realm_payment.remaining==2 and plugin.game.realm_level==2)
plugin:closeOverlay(false); plugin:showGame()
click("Cornwall")
assert(plugin.game.realm_level==3 and not plugin.game.realm_payment and #plugin.game.controlled==0)
print("Partially paid realm development resumes correctly")

-- Measure every face at overview dimensions using DPI-scaled font metrics.
for _,dimensions in ipairs({{600,800},{758,1024},{1072,1448},{1272,1696}}) do
    screen_w,screen_h=dimensions[1],dimensions[2]
    plugin.dialog=nil; plugin:showGame()
    local board=plugin.dialog
    local original=board.drawFittedText
    local failures={}
    local banners={}
    board.drawFittedText=function(self,buffer,text,x,y,w,h,size,bold,color)
        local fits=original(self,buffer,text,x,y,w,h,size,bold,color)
        if not fits then failures[#failures+1]=text end
        if text:match("^L%d ") then banners[#banners+1]=text end
        return fits
    end
    for id in pairs(plugin.game.levels) do
        for level=1,4 do board:drawFace(bb,id,level,0,0,math.floor(screen_w*.315),math.floor(screen_h*.15),true,true) end
    end
    assert(#failures==0,"Card overflow at "..screen_w..": "..table.concat(failures,"\n"))
    local banner_text=table.concat(banners,"\n")
    assert(banner_text:find("[M]",1,true) and banner_text:find("[P]",1,true)
        and banner_text:find("/\\ 4",1,true) and banner_text:find("X|4",1,true),"Banner values/icons missing")
    banners={}
    board:drawDoubleCard(bb,"host",0,0,400,500,true,3)
    assert(#banners==2 and banners[1]:find("X|3",1,true) and banners[2]:find("X|4",1,true),"Both card halves need keying icons")
    local lines=board:layoutText("First line\nSecond line",10000,8,false)
    assert(#lines==2 and lines[1]=="First line" and lines[2]=="Second line","Explicit line breaks lost")
end
plugin:chooseRival()
local rival_dialog=plugin.dialog
for i=1,5 do
    local b=rival_dialog.buttons[i][1]
    assert(b.hold_callback)
    b.hold_callback()
    assert(plugin.dialog==rival_dialog and plugin.overlay.title:find(b.text,1,true))
end
plugin:closeOverlay(false)
plugin:configureNewGame("Mordred")
local setup_dialog=plugin.dialog
for _,b in ipairs({setup_dialog.buttons[2][1],setup_dialog.buttons[3][1],setup_dialog.buttons[4][1],setup_dialog.buttons[4][2]}) do
    b.hold_callback()
    assert(plugin.dialog==setup_dialog and #plugin.overlay.text>80)
    assert(plugin.pending_setup.game_difficulty=="Normal" and not plugin.pending_setup.foresight and not plugin.pending_setup.fluid_round)
end
setup_dialog.buttons[1][1].hold_callback()
assert(plugin.overlay.title=="Strategy vs Mordred")
print("All 64 faces fit overview boxes at four resolutions; setup/rival hold help preserves choices")

local function fingerprint(value)
    if type(value)~="table" then return tostring(value) end
    local entries={}
    for k,v in pairs(value) do entries[#entries+1]=tostring(k).."="..fingerprint(v) end
    table.sort(entries)
    return "{"..table.concat(entries,",").."}"
end
fresh({"trade","host","customs"},{trade=2,host=2,customs=1})
plugin.game.action={source="works",spec={develop=2,degrade=2,store_materials=3},used={},developed={},ineligible={}}
for _,open in ipairs({function() plugin:resolveDevelop() end,function() plugin:resolveDegradeBenefit() end,
    function() plugin:resolveStoreBenefit("materials") end}) do
    open()
    local chooser=plugin.overlay
    local before=fingerprint(plugin.game)
    local option=chooser.buttons[1][1]
    assert(option.hold_callback,"Card chooser has no hold preview")
    option.hold_callback()
    local preview=shown
    assert(preview.name=="beholdcamelot_preview" and plugin.overlay==chooser)
    preview:paintTo(bb,0,0)
    local level=preview.preview_level
    preview.tap_holdings[1].callback() -- other physical side
    assert(preview.preview_level==((level+1)%4)+1)
    preview.tap_holdings[2].callback() -- rotate that side
    preview:paintTo(bb,0,0)
    preview.tap_holdings[3].callback()
    assert(shown.title:find("Preview:",1,true) and plugin.overlay==chooser)
    preview:onClose()
    assert(fingerprint(plugin.game)==before,"Preview changed the game/action budget")
    assert(plugin.overlay==chooser,"Preview lost the pending selection")
end
plugin.game.action=nil; plugin:closeOverlay(false); plugin:showGame()
local board=plugin.dialog
local before=fingerprint(plugin.game)
board:paintTo(bb,0,0)
board.tap_holdings[1].callback() -- X
assert(shown.ok_text=="Save & quit" and plugin.dialog==board and fingerprint(plugin.game)==before)
-- Dismissing confirmation leaves the board; only confirming closes it.
shown.ok_callback()
assert(plugin.dialog==nil and fingerprint(plugin.game)==before)
print("Card chooser hold previews, read-only flip/rotate, and quit confirmation passed")

-- Every category must reconcile with the existing live total, including inactive branches.
fresh({}, {})
for _,rival in ipairs({"Morgan le Fay","Mordred","King Lot","Lucius"}) do
    plugin.game.rival=rival
    for realm=1,4 do
        plugin.game.realm_level=realm
        for level=1,4 do
            for id in pairs(plugin.game.levels) do plugin.game.levels[id]=level end
            for _,modifier in ipairs({-40,0,40}) do
                plugin.game.rival_modifier=modifier
                local score=plugin:liveScore()
                local sum,inactive=0,0
                for _,category in ipairs(score.rival_breakdown) do
                    sum=sum+category.points
                    assert(#category.formula>0)
                    if not category.active then assert(category.points==0); inactive=inactive+1 end
                end
                assert(sum==score.rival and inactive>0,"Rival breakdown mismatch")
                assert(score.rival_breakdown[#score.rival_breakdown].points==modifier)
            end
        end
    end
end
local before=fingerprint(plugin.game)
plugin:showRealm()
assert(plugin.overlay.title=="Realm / Rival" and plugin.overlay.text:find("Rival total:",1,true))
assert(plugin.overlay.text:find("printed material icons",1,true) and fingerprint(plugin.game)==before)
plugin.game.rival="Chronicle of the Realm"
plugin:showRealm()
assert(plugin.overlay.text:find("No rival categories",1,true))
assert(#plugin:liveScore().rival_breakdown==0 and plugin:liveScore().rival==nil)
print("Rival category reconciliation across realms, orientations and difficulty modifiers passed")

-- Presentation and save identity are independent from game-state mechanics.
local meta=dofile(project_root.."beholdcamelot.koplugin/_meta.lua")
assert(meta.name=="beholdcamelot" and meta.fullname=="Behold: Camelot")
local menu={}
plugin:addToMainMenu(menu)
assert(menu.behold_camelot and menu.behold_camelot.text=="Behold: Camelot")
plugin:showMainMenu()
for _,row in ipairs(plugin.dialog.buttons) do
 for _,button in ipairs(row) do assert(button.text~="Quick rules") end
end
assert(plugin.showRules==nil)
plugin:showAbout()
assert(shown.title=="About Behold: Camelot" and shown.text:find("Joe Klipfel",1,true))
assert(shown.text:find("buying",1,true) and not shown.text:find("Version ",1,true))
local expected_names={
 crafts={"Local Craft","Skilled Artisans","Master Builders","Royal Works"},
 host={"Armed Retainers","Household Knights","Royal Host","Assembled Host"},
 works={"Armourers","Stonework","Waterworks","Royal Roads"},
 council={"Galahad","The Round Table","Arthur","Uther Pendragon"},
 customs={"Customs of the Court","The Pentecostal Oath","Merlin's Counsel","The Holy Grail"},
 kin={"Gawain","Gareth","Gaheris","The Last Battle"},
 lake={"Guinevere","Lancelot","Joyous Gard","Sir Bors"},
 gaul={"King Claudas","Gaul","Brittany","King Bors"},
 allies={"Caerleon","Cameliard","Benwick","King Ban"},
 wounds={"The Dolorous Stroke","The Wounded Lands","Pellam's Castle","Balin's Fatal Quest"},
 grail={"Astolat","Corbenic","Percival","Sarras"},
 marches={"Bedegraine","Cornwall","Logres","Guarding the Realm"},
 camelot={"Camelot: Settlement","Camelot: Stronghold","Camelot: Court","Camelot: Royal Seat"},
 dues={"Almsgiving","Customary Dues","Royal Levies","Extraordinary Levy"},
 trade={"Grain Stores","Quarries","Wine Merchants","Cloth Merchants"},
 claims={"Secure a Holding","Extend Protection","Obtain Allegiance","Assert Sovereignty"},
}
fresh({}, {})
for id,faces in pairs(expected_names) do
 for level,name in ipairs(faces) do plugin.game.levels[id]=level; assert(plugin:cardName(id)==name) end
end
local settings=require("luasettings")
local original_open=settings.open
local opened_path
settings.open=function(_,path)
 opened_path=path
 return {readSetting=function() return nil end,saveSetting=function() end,flush=function() end}
end
plugin.ui={menu={registerToMainMenu=function() end}}
plugin:init()
assert(opened_path:match("/beholdcamelot%.lua$"))
settings.open=original_open
print("Camelot roster, menu, attribution-only About and isolated save identity passed")
