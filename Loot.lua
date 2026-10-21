--[[
   KahLua Konfer - a loot distribution addon.
     Git: https://github.com/kahluamods/konfer
     E-mail: me@cruciformer.com

   Please refer to the file LICENSE.txt for the Apache License, Version 2.0.

   Copyright 2008-2026 Kean Johnston. All rights reserved.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
]]

local K = LibStub:GetLibrary("Kore")
local JSON = LibStub:GetLibrary("LibJsonLua")

local konfer = K:GetAddon("Konfer")
local cfgm = konfer.configmethods
local KU = K.Users
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local KLD = konfer.KLD
local MakeFrame = KUI.MakeFrame

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tconcat = table.concat
local tsort = table.sort
local tostring, tonumber = tostring, tonumber
local strfmt = string.format
local strsub = string.sub
local strlen = string.len
local strfind = string.find
local strlower = string.lower
local strmatch = string.match
local gmatch = string.gmatch
local pairs, ipairs = pairs, ipairs
local printf = K.printf
local unpack = unpack
local GetTime = GetTime

local icolor = K.icolor
local white = konfer.white
local class = konfer.class
local shortclass = konfer.shortclass
local aclass = konfer.aclass
local shortaclass = konfer.shortaclass
local debug = konfer.debug

--
-- This file contains all of the UI handling code for the loot panel, as well as all loot manipulation functions. This is a
-- fairly complicated UI with lots of moving parts so it's a good idea to understand what is going on here.
--
-- We have 3 panels - loot distribution (qf.assign), the item editor (qf.itemedit) and the loot history page (qf.history).
-- Only the first two are vaguely interesting. The history page is just a list with a few simple buttons.
--
-- The loot page is divided into 5 main regions:
-- top left - the list of roll lists (qf.lists)
-- bottom left - the list of members of the selected list (qf.members)
-- top right - the loot selection list (qf.lootwin is the frame,
--   qf.lootwin.slist and qf.lootscroll is the actual scroll list). It also
--   contains all of the buttons for controlling loot distribution. These are
--   only displayed for the master looter. These buttons are all children of
--   qf.lootwin. .oclbids is for open / close bids. It toggles between the two.
--   .orpause either starts an open roll or pauses one in progress. And last
--   .remcancel is either the button to remove a bid item or to cancel a bid
--   or open roll.
-- middle right is the loot rules frame, the open roll timer frame and the
--   auto loot assignment confirmation frame. This is also known as the ALF
--   frame and one of those three pages is selected with select_alf().
--   qf.lootrules, qf.lootroll and qf.autoloot are the shortcuts for these
--   3 frames, only one of which can ever be visible at a time.
-- bottom right - the bidders / rollers frame. This is where the list of
--   bidders or rollers is displayed, along with buttons for both normal users
--   and the master looter to control those bidders / bids. qf.bidders is the
--   enclosing frame. The bid pane is the scroll list of bidders
--   (qf.bidscroll) and under it Bid on item and Retract bid (qf.mybid,
--   qf.myretract), which are everybody's. .buttons, in the panel under
--   Candidates, holds the master looter's and admins' .forcebid, which bids the
--   candidate selected, and .forceret, which takes the selected bidder's bid
--   back. Undo (qf.undobutton) is on the History tab. All of the bid pane
--   is in .bidpane, and while a roll is open
--   .rollpane stands in its place: the list of rollers (qf.rollscroll) and
--   .rollpane.remove, the master looter's alone, which takes the roller
--   selected out of the roll. The buttons a player rolls with are on the
--   roll frame (qf.lootroll).
--
-- The ALF frame is the middle right frame and it is used for 3 different
-- things using select_alf():
-- ALF_LOOT - the loot rules frame. This is the frame shown while bids are
--   open or before open rolls are started. This contains all of the class
--   specific check boxes (for class filtering), the role filter, the guild
--   rank filter, and the strict armor / class checkboxes. The containing
--   frame is qf.lootrules and has the following children:
--   .warrior, .paladin, .druid etc for all 12 classes
--   .role - the drop down for the user role
--   .rank - the dropdown for the guild rank
--   .nextrank - the button for moving to the next lower rank
--   .strictarmour - checkbox for strict armor filtering
--   .strictrole - checkbox for strict role filtering
--   The two strict boxes are what the filters are, staying as the master looter leaves them from one item to the next and
--   set from a list's own only when the list changes. Every item picked (LISEL) and every change (FLTCH) carries them.
-- ALF_CONFIRM - the confirmation frame, put up by put_confirm to ask the master looter one of two things (see THE WIN):
--   whether to go through with an item's own instructions naming who has it, and, in a policy with no costing box, whether
--   to hand an item somebody has won to them. Its base is qf.autoloot and its widget children are:
--   .item (and qf.autoassign_item) - "Item:" and the item's link
--   .str (and qf.autoassign_msg) - the question
--   .ok and .cancel - confirm_ok and confirm_cancel
--   What they act on is set on qf.autoloot:
--   .what - "instructions" or "handout"
--   .win - the win, as THE WIN describes one
--   .delivery - for a hand-out, the hand-out, as deliveries describes one
--

--
-- Engine state, and file-scoped because it is genuinely singular: one raid is running, one policy is active, one item is up.
-- The item editor and the history are a different matter -- an inactive policy still has both, and browsing them is the
-- whole reason its window stays alive -- so what those two select and edit lives on their own window's widget table as
-- qf.selitemid, qf.iinfo and qf.sorteditems.
--
local lootlistid = nil
local members = nil
local memberid = nil
local biditem = nil

--
-- The kinds of bid the open bid takes, their codes run together ("MOT"). The master looter's own config says, and everybody
-- else is told with the bid (BIDOP), so that what Bid on item offers is what is being taken whatever a raider's own copy of
-- the config says. Nil while no bid is open.
--
local openkinds = nil

--
-- Whether the open bid takes an amount, "!ms 150" rather than "!ms". The master looter's policy says for its current config
-- (BidAmounts), and everybody else is told with the bid (BIDOP), so that the amount box beside Bid on item shows exactly
-- while one is wanted. Nil while no bid is open.
--
local openamounts = nil

--
-- The countdown on the open bid where the config's bids are timed (bid_timer), nil where they are not and while
-- no bid is open: { endtime, timeout, lastwarn, ticker, paused }. Everybody runs one, from what BIDOP told them, so that
-- every raider's Bids panel says how long is left, but only the master looter's closes the bids, exactly as Close bids
-- does. A bid in the last bid_extend seconds puts the close back to bid_extend from then, and the raid is told (XBIDS), so
-- that nobody wins by bidding a moment before the end. The master looter may pause it, PAUSED then being the seconds that
-- were left, and resume it, and the raid is told both (PBIDS).
--
local bidclock = nil

-- The index into konfer.raid.bossloot of the currently selected loot item.
local selectedloot = nil

-- Data table of the currently selected loot item.
--  idx - same as selectedloot above.
--  itemid - the item ID
--  filter - the class filter
--  role - the role filter
--  list - the desired roll list
--  rank - the rank filter
--  loot - konfer.raid.bossloot[selectedloot]
--     slot - the loot slot index for Blizzard API functions
--     itemid - the item ID
--     ilink - the item link text
--     quant - the number of this item on the corpse
--     boe - true if the item is BoE
--     strict - the strict class filter
--     relaxed - the relaxed class filter
local lootitem = nil

local lootroll = nil

-- Table of people who have bid on the current item.
local bidders = nil
--
-- The master looter's: the bidders as the raid was last told them (send_bidders), so an unchanged list is not sent again.
-- ALL is the whole list, and OWN each bidder's own row by uid as a silent auction whispered it to them.
--
local sentbidders = { own = {} }
-- Index into bidders of the currently selected bidder and that user's uid.
local selectedbidder = nil
local selectedbiduid = nil

--
-- Every widget this page builds. There is one window and it shows the active policy, which is also the policy the loot
-- engine runs, so the page the user is looking at and the page loot is being handed out on are always the same one.
--
local qf = {}

--
-- True while the active window's list of roll lists is being redrawn. Redrawing a scroll list deselects its row before the
-- row is selected again, and that passing deselection is not the master looter leaving the list: acted on, it would empty
-- the candidates and throw away every bidder in the middle of a bid.
--
local refreshing_lists = false

-- The same for the loot list, while it is redrawn with the item already selected kept selected. See RefreshBossLoot.
local redrawing_loot = false

--
-- The dialogs this page puts up are kept on the widget table rather than in file locals because each is built once, with
-- callbacks closed over the window that raised it, and is then reopened rather than remade.
--
-- There is one window and it shows the active policy, so these are the mod's and are named as the mod's, without a policy
-- prefix. A policy's own frames are the prefixed ones and hang off the policy. What that costs is that a callback built
-- here outlives whichever policy happened to be active when it was built, so every one of them reads konfer.apol when it
-- runs rather than capturing a policy.
--

--
-- This can have 4 possible values:
-- nil - No rolling taking place
-- 1   - roll actively underway.
-- 2   - active roll paused.
-- 3   - roll paused and window closed.
local rolling = nil

--
-- The kinds of roll, keyed by the low end of the hundred each is rolled in, which is how the game reports a roll. They rank
-- in the order of their ranges, main spec, off spec, transmog, vanity, and within one kind the higher roll wins. HIST is the
-- loot history's word for an item won on it, SETTING the config setting that turns rolls of it on and BIDSETTING the one
-- that turns bids of it on (main spec is always on), NAME what a roll of it is called in the list of rollers, USAGE how a
-- raider is told to make one, TOP what the master looter is told of the best of them and PHRASE what a bid of it is
-- called in a sentence.
--
-- WORDS are the whispers that bid it in this locale, "!os" being an off spec bid, the first of them the one a raider is
-- taught. ENGLISH are the ones every locale answers besides, because players type "ms" and "os" whatever language their
-- client is in. Each kind is a whisper command of its own (see the loop below), so there is no word for bidding as such.
--
local ROLL_KINDS = {
  [1]   = { hist = "M", name = L["Main"], label = L["Main"], words = L["BIDWORDS_MAIN"], english = "ms main mainspec bid",
            usage = L["'/roll' for main spec"], top = L["top main spec rollers: %s"], phrase = L["main spec"] },
  [101] = { hist = "O", setting = "offspec_rolls", bidsetting = "offspec_bids", name = L["Off-spec"], label = L["Off spec"],
            words = L["BIDWORDS_OFFSPEC"], english = "os off offspec", usage = L["'/roll 101-200' for off-spec"],
            top = L["top off-spec rollers: %s"], phrase = L["off spec"] },
  [201] = { hist = "T", setting = "transmog_rolls", bidsetting = "transmog_bids", name = L["Transmog"], label = L["Transmog"],
            words = L["BIDWORDS_TRANSMOG"], english = "transmog xmog tm xm", usage = L["'/roll 201-300' for transmog"],
            top = L["top transmog rollers: %s"], phrase = L["transmog"] },
  [301] = { hist = "V", setting = "vanity_rolls", bidsetting = "vanity_bids", name = L["Vanity"], label = L["Vanity"],
            words = L["BIDWORDS_VANITY"], english = "vanity", usage = L["'/roll 301-400' for vanity"],
            top = L["top vanity rollers: %s"], phrase = L["vanity"] },
}

--
-- The kinds of claim somebody can make on an item, a bid or a roll alike, best first. A kind is named everywhere by its
-- code, the letter the loot history records it under, so a bid travels as "O" and a roll as the hundred it was rolled in.
-- A new kind is one entry in ROLL_KINDS and nothing else: every list of kinds, button and whispered word is made from it.
--
local KIND_ORDER = {}
local KIND_BY_CODE = {}

for minr, kind in pairs(ROLL_KINDS) do
  kind.minr = minr
  tinsert(KIND_ORDER, minr)
  KIND_BY_CODE[kind.hist] = kind
end

tsort(KIND_ORDER)

--
-- Every kind is a whisper command of the platform's standard set, "bidM" to "bidV", which RegisterPolicy copies onto every
-- policy with the rest. What follows the word is the amount, where the running config's bids take one.
--
for _, minr in ipairs(KIND_ORDER) do
  local kind = ROLL_KINDS[minr]
  local words, seen = {}, {}

  for w in gmatch(kind.words .. " " .. kind.english, "%S+") do
    local lw = strlower(w)

    if (not seen[lw]) then
      seen[lw] = true
      tinsert(words, lw)
    end
  end

  kind.whisper = "bid" .. kind.hist
  konfer.std_whisperwords[kind.whisper] = words
  konfer.std_whispers[kind.whisper] = function(pol, uid, sender, nick, arg)
    return konfer:WhisperedBid(uid, kind.hist, arg)
  end
end

--
-- The kinds of bid CFG takes, as codes, best first: main spec always, and the others its Bid options have turned on. Every
-- policy has every kind, and a config that wants no more than main spec simply turns the rest off.
--
local function bid_kinds(cfg)
  local out = {}

  for _, minr in ipairs(KIND_ORDER) do
    local kind = ROLL_KINDS[minr]

    if (not kind.bidsetting or (cfg and cfg.settings[kind.bidsetting])) then
      tinsert(out, kind.hist)
    end
  end

  return out
end

--
-- The same for anybody outside this file, an item's tooltip naming a price for each: { code, name } best first, NAME what a
-- bid of it is called on a line of its own.
--
function konfer:BidKinds(cfg)
  local out = {}

  for _, code in ipairs(bid_kinds(cfg)) do
    tinsert(out, { code = code, name = (KIND_BY_CODE[code].phrase:gsub("^%l", string.upper)) })
  end

  return out
end

--
-- Where each kind of bid stands in CFG, by code, or each kind of roll where ROLLS is set: the lower the tier the better, and
-- two kinds on one tier stand level, so that it is the list that decides between two bids and the roll itself between two
-- rolls. The config's kind order says which kind outranks which: main spec over off spec, off spec over transmog and over
-- vanity, and transmog over vanity. Main spec is never below anything. A choice between two kinds the config does not both
-- take is not the config's to make, its box being dark, and stands as the strict order does. Rolls stand in the strict order
-- unless the config's policy ranks them by the kind order too (rollorder in Policy.lua), as PUG, which has no bids, does.
--
local function kind_tiers(cfg, rolls)
  local st = cfg.settings
  local ordered = not rolls or cfg:GetPolicy().rollorder
  local taken = {}

  if (rolls) then
    for _, minr in ipairs(KIND_ORDER) do
      local kind = ROLL_KINDS[minr]

      taken[kind.hist] = (not kind.setting or st[kind.setting]) and true or false
    end
  else
    for _, code in ipairs(bid_kinds(cfg)) do
      taken[code] = true
    end
  end

  local function over(name, a, b)
    if (not ordered or not taken[a] or not taken[b]) then
      return 1
    end

    return st[name] and 1 or 0
  end

  local t = { M = 0 }

  t.O = over("main_over_offspec", "M", "O")
  t.T = t.O + over("offspec_over_transmog", "O", "T")
  t.V = math.max(t.O + over("offspec_over_vanity", "O", "V"), t.T + over("transmog_over_vanity", "T", "V"))

  return t
end

--
-- Whether a bid in CFG names an amount as well as a kind, which is its policy's to say (BidAmounts). DKP running auctions
-- says yes; every other policy and config bids a kind alone.
--
local function bids_take_amounts(cfg)
  local _, yes = cfg:PolicyCall("BidAmounts", false)

  return yes and true or false
end

--
-- What the active policy says ILINK costs, "75+" or "125" (PriceText), or nil. It is the master looter's to say, and everybody
-- else is sent it with the loot (OLOOT, ALOOT) and again as bids open on the item (BIDOP), the price having perhaps changed
-- since, a raider's copy of the config not hearing of its settings changing.
--
function konfer:LootPrice(ilink)
  local cfg = self.apol and self.apol.cfg

  if (not cfg or not ilink) then
    return nil
  end

  local _, text = cfg:PolicyCall("PriceText", nil, ilink)

  return text
end

--
-- The kind a bid names, as its code, nothing at all being main spec. Nil for anything that is not a kind.
--
local function bid_kind_named(what)
  if (what == nil or what == "") then
    return "M"
  end

  return KIND_BY_CODE[what] and what or nil
end

--
-- Whether a roll from MINR to MAXR is one CFG takes: a kind it has turned on, rolled over that kind's whole hundred.
--
local function roll_kind_on(cfg, minr, maxr)
  local kind = ROLL_KINDS[minr]

  return kind ~= nil and maxr == minr + 99 and (not kind.setting or cfg.settings[kind.setting]) and true or false
end

--
-- The top of UID's range for a roll of the kind from MINR in the roll open now, out of its hundred: the whole hundred,
-- unless the roll carries an award and the policy has shortened UID's range for that kind (RollCeiling in Policy.lua), as
-- PUG's decay does, so that a raider decayed to 90 rolls 1-90 for main spec and 101-190 for off spec.
--
function konfer:RollTop(cfg, uid, minr)
  local kind = ROLL_KINDS[minr]

  if (not lootroll or not lootroll.awards or not uid or not kind or not cfg) then
    return 100
  end

  local _, top = cfg:PolicyCall("RollCeiling", nil, uid, kind.hist)

  top = tonumber(top)

  return (top and top >= 1 and top < 100) and floor(top) or 100
end

--
-- Where UID stands among the rollers of one tier in the roll open now, ahead of what they rolled, lower standing better: all
-- level, unless the policy ranks them (RollPriority in Policy.lua), as PUG's soft reserves do in any roll and its +1s in a
-- roll that carries an award.
--
function konfer:RollPriority(cfg, uid, minr)
  local kind = ROLL_KINDS[minr]

  if (not lootroll or not uid or not kind or not cfg) then
    return 0
  end

  local _, prio = cfg:PolicyCall("RollPriority", 0, uid, kind.hist, lootroll.ilink, lootroll.awards)

  return tonumber(prio) or 0
end

--
-- Whether the item selected is spoken for, never to be rolled or bid on, the uid it is claimed for, nil where it names
-- nobody the config holds, and whether winning it that way is an award on the list it is given out on (ItemClaim in
-- Policy.lua).
--
function konfer:ItemClaim()
  local ilink = lootitem and lootitem.loot and lootitem.loot.ilink
  local cfg = self.apol and self.apol.cfg

  if (not ilink or not cfg) then
    return false
  end

  local _, claimed, uid, award = cfg:PolicyCall("ItemClaim", false, ilink)
  local who = (claimed and uid and cfg.uids[uid]) and uid or nil

  return claimed and true or false, who, (who and award) and true or false
end

--
-- The item selected on the loot list, its place on it and the loot itself as konfer.raid.bossloot holds it, or nil with
-- none selected, and whether a bid or a roll is open on it.
--
function konfer:SelectedLoot()
  if (not selectedloot or not lootitem) then
    return nil
  end

  return selectedloot, lootitem.loot, (rolling ~= nil or biditem ~= nil)
end

-- How to make each roll CFG takes, and how to cancel one, for a sentence telling a raider.
local function roll_usage(cfg)
  local parts = {}

  for minr = 1, 301, 100 do
    if (roll_kind_on(cfg, minr, minr + 99)) then
      tinsert(parts, ROLL_KINDS[minr].usage)
    end
  end

  tinsert(parts, L["'/roll 1-1' to cancel a roll"])

  return tconcat(parts, ", ")
end

--
-- The rolls shown in the list of rollers while a roll is open, best first, each { uid = uid, roll = roll, kind = minr }. The
-- master looter works it out as rolls arrive and sends it to the raid whole (TROLL), so every client shows the same list.
-- SELECTEDROLLER is the uid of the one picked in it, which is who the master looter's Remove takes out.
--
local rollrows = nil
local selectedroller = nil

--
-- The amount box beside Bid on item shown, ONOFF, or taken away, and the row of Bid on item and Retract bid laid out again
-- around it so that the whole of it stays centred under the list of bidders.
--
local function show_amount_box(onoff)
  if (not qf.mybidrow) then
    return
  end

  local GAP = KUI.WIDGET_GAP
  local w = qf.mybid:GetWidth()
  local x = 0

  if (onoff) then
    x = qf.myamount:GetWidth() + GAP
  end

  qf.myamount:SetShown(onoff and true or false)
  qf.mybid:ClearAllPoints()
  qf.mybid:SetPoint("TOPLEFT", qf.mybidrow, "TOPLEFT", x, 0)
  qf.myretract:ClearAllPoints()
  qf.myretract:SetPoint("TOPLEFT", qf.mybidrow, "TOPLEFT", x + w + GAP, 0)
  qf.mybidrow:SetWidth(x + 2 * w + GAP)
end

--
-- The panels on the Loot page read as disabled, their titles dimmed, while there is nothing in them to use. Every one of
-- them is that way while no loot is being handed out: Lists and Loot while there is no loot, Candidates while there is no
-- list selected as well, Constraints while there is no item selected, and Bids / rolls while there is no bid or roll open on it either.
--
-- Worked out from the state above rather than told, and called wherever that state changes. The lists in Lists and Candidates,
-- and the search box under Candidates, go with their panels, so that nobody picks a list or a candidate while nothing is
-- being looted.
--
local function sync_loot_panels()
  local looting = konfer.apol ~= nil and konfer.raid.bossloot ~= nil
  local hasitem = looting and selectedloot ~= nil

  if (qf.lootlistspanel) then
    local candidates = looting and lootlistid ~= nil

    qf.lootlistspanel:SetEnabled(looting)
    qf.lists:SetEnabled(looting)
    qf.candidatespanel:SetEnabled(candidates)
    qf.members:SetEnabled(candidates)
    qf.membersearch:SetEnabled(candidates)
    qf.lootpanel:SetEnabled(looting)
    qf.constraintspanel:SetEnabled(hasitem)
    qf.bidspanel:SetEnabled(hasitem and (biditem ~= nil or rolling ~= nil))

    -- The panel says what it is showing: a roll, a bid and how long it has left where it closes by itself, or neither yet.
    local bidtitle = bidclock and white(strfmt(L["Bids close in %s"],
      ("%.1f"):format(math.max(0, bidclock.paused or (bidclock.endtime - GetTime())))))

    qf.bidspanel:SetTitleText((rolling and L["Roll status"]) or (biditem and (bidtitle or L["Bid status"])) or L["Bids / rolls"])
  end

  -- Anybody may bid while bids are open. Retract bid is lit by having a bid in, which refresh_bidders knows. A policy that
  -- takes no bids has neither (AssignPage.hide).
  if (qf.mybid) then
    -- While the master looter is giving an item its price (open_close_bids) the box is theirs, until bids open or the item changes.
    if (qf.myamount.pricing and (qf.myamount.pricing ~= selectedloot or biditem or rolling)) then
      qf.myamount.pricing = nil
    end

    qf.mybidrow:SetShown(konfer:TakesBids())
    qf.mybid:SetEnabled(biditem ~= nil and not rolling)
    show_amount_box((biditem ~= nil and openamounts and not rolling) or qf.myamount.pricing ~= nil)

    if (not biditem) then
      qf.myretract:SetEnabled(false)
    end
  end

  -- The buttons under Candidates are only for the master looter and the config's admins.
  if (qf.bidders and qf.bidders.buttons) then
    qf.bidders.buttons:SetShown((konfer:AmIML() or konfer:PolicyAdmin(konfer.apol)) and true or false)
  end
end

--
-- The top right division of the loot assignment page serves 3 main purposes: loot selection, assignment confirmation and
-- open rolls. Only one of these can be active at a time as they all overlay each other. This function ensures that only one
-- of these three frames is active.
--
local ALF_LOOT    = 1
local ALF_CONFIRM = 2
local ALF_ROLL    = 3

local function select_alf(which)
  local frames = { [ALF_LOOT] = qf.lootrules, [ALF_CONFIRM] = qf.autoloot, [ALF_ROLL] = qf.lootroll }

  -- The panel is the roll's while one is open, and says so. A bid leaves the constraints up for everybody to see.
  if (qf.constraintspanel) then
    qf.constraintspanel:SetTitleText((which == ALF_ROLL and L["Roll progress"]) or L["Constraints"])
  end

  for w, f in pairs(frames) do
    if (w ~= which) then
      f:Hide()
    end
  end

  if (frames[which]) then
    frames[which]:Show()
  end
end

local function hide_popup()
  if (konfer.popupwindow) then
    konfer.popupwindow:Hide()
    konfer.popupwindow = nil
  end
end

--
-- We have a few places where we have very similar widgets, such as the class filtering stuff. All of the containing widgets
-- have sub-widgets of the same name and all of them have the same requirement of needing to either be enabled/disabled or
-- have their value set according to a filter string. These three functions are helpers for those cases and do the busy work
-- in this one place rather than repeating it in several places.
--
local function classes_setenabled(tbl, onoff)
  local onoff = onoff or false

  for k, v in pairs(K.IndexClass) do
    if (v.w and tbl[v.w]) then
      tbl[v.w]:SetEnabled(onoff)
    end
  end
end

-- Every box in the grid ticked or not, without throwing: this is putting a state on screen, never somebody's edit.
local function classes_setchecked(tbl, onoff)
  local onoff = onoff or false

  for k, v in pairs(K.IndexClass) do
    if (v.w and tbl[v.w]) then
      tbl[v.w]:SetChecked(onoff, true)
    end
  end
end

local function classes_cfilter(tbl, cfilter)
  for k, v in pairs(K.IndexClass) do
    if (v.w and tbl[v.w]) then
      tbl[v.w]:SetChecked(cfilter[k])
    end
  end
end

--
-- The class checkboxes are a grid of three columns in this order, and every grid of them is built by classes_create, so that
-- two on one page line up and the helpers above find each checkbox under its class's widget name. The classes later
-- expansions brought follow the first nine, each only where Kore says the client has it.
--
local CLASS_GRID = {
  K.CLASS_WARRIOR, K.CLASS_PALADIN, K.CLASS_HUNTER,
  K.CLASS_SHAMAN,  K.CLASS_DRUID,   K.CLASS_ROGUE,
  K.CLASS_MAGE,    K.CLASS_WARLOCK, K.CLASS_PRIEST,
}

if (K.CLASS_DEATHKNIGHT) then
  tinsert(CLASS_GRID, K.CLASS_DEATHKNIGHT)
end
if (K.CLASS_MONK) then
  tinsert(CLASS_GRID, K.CLASS_MONK)
end
if (K.CLASS_DEMONHUNTER) then
  tinsert(CLASS_GRID, K.CLASS_DEMONHUNTER)
end
if (K.CLASS_EVOKER) then
  tinsert(CLASS_GRID, K.CLASS_EVOKER)
end
local CLASS_GRID_COLS = 3
local CLASS_COLGAP = 5

-- The font the class names are in, and are measured in, so that the longest of them fit beside their neighbours.
local CLASS_FONT = "GameFontWhiteTiny"

--
-- How wide a column of the grid is: the longest class name plus a gap, which is a question about the locale rather than a
-- number, after CHECKBOX_SIZE of box and INTERNAL_GAP before its text starts. The longest class names the game has had are
-- measured but never shown, so that the grid does not change shape the day this runs somewhere they exist.
--
local function classes_colwidth()
  local cnames = { "Death Knight", "Demon Hunter" }

  for k, v in pairs(K.IndexClass) do
    if (v.c and not v.ign) then
      tinsert(cnames, v.c)
    end
  end

  return KUI.CHECKBOX_SIZE + KUI.INTERNAL_GAP + KUI:WidestString(cnames, CLASS_FONT) + CLASS_COLGAP
end

--
-- Build the grid in TBL with its top at YPOS, each checkbox in TBL under its class's widget name and starting enabled or not
-- as ENABLED says. ONCHANGE is called as ONCHANGE(checkbox, event, value, class, user) whenever one changes. Returns the y
-- below the grid, a standard gap under its last row.
--
local function classes_create(tbl, ypos, enabled, onchange)
  local colw = classes_colwidth()

  for i, cls in ipairs(CLASS_GRID) do
    local col = (i - 1) % CLASS_GRID_COLS
    local cb = KUI:CreateCheckBox({ x = colw * col, y = ypos, enabled = enabled,
      label = { text = K.IndexClass[cls].c, font = CLASS_FONT } }, tbl)

    cb:Catch("OnValueChanged", function(this, evt, val, user)
      onchange(this, evt, val, cls, user)
    end)
    tbl[K.IndexClass[cls].w] = cb

    if (col == CLASS_GRID_COLS - 1 or i == #CLASS_GRID) then
      ypos = ypos - cb:GetHeight() - KUI.WIDGET_GAP
    end
  end

  return ypos
end

--
-- Check to see if any of the current raiders are not on the currently selected list.
--
local function check_missing_members(self)
  if (not self.apol.cfg:Announces("ann_missing") or not self.raid.uidmap or not lootlistid) then
    return
  end

  local mwarn = self:ListWarnings(lootlistid)
  local missing = {}

  --
  -- Somebody in the config is warned about under their uid and somebody the config has never heard of under their name,
  -- there being no uid to use. The two cannot collide, a uid being four hex characters and a name carrying its realm, so
  -- one table holds both and each raider is still named once.
  --
  for k,v in pairs(KRP.players) do
    local uid = v["konfer_uid"]

    if (not uid) then
      if (not mwarn[v.name]) then
        mwarn[v.name] = true
        tinsert(missing, shortaclass(v))
      end
    elseif (not mwarn[uid]) then
      if (not self.apol.cfg:IsInList(uid, lootlistid)) then
        mwarn[uid] = true
        tinsert(missing, shortaclass(self.apol.cfg:UserNameClass(uid)))
      end
    end
  end

  if (#missing == 0) then
    return
  end

  local lootlist = self.apol.cfg.lists[lootlistid]
  self.apol:info("%s%s", strfmt(self.apol:Str("NOT_ON_LIST"), lootlist.name), tconcat(missing, ", "))
end

--
-- The fields of an item's instructions, which are the keys the item editor's unsaved changes are kept under. The platform's
-- widgets and the policy's own panel both edit them, in the item's edit buffer.
--
local ITEM_FIELDS = { "cfilter", "ignore", "ignorequal", "list", "role", "rank", "nextuser", "nextdrop", "autodel",
  "awardlist", "autoassign", "pdata" }

--
-- A field's value in the one form it is compared in. Ignore or auto-assign reset a whole buffer, leaving fields nil where a
-- stored item reads false, "0" or nobody, and an item the user has not touched must not read as changed for it.
--
local function item_value(key, v)
  if (key == "cfilter") then
    local cf = {}

    for k in pairs(K.IndexClass) do
      cf[k] = (type(v) == "table" and v[k]) and true or false
    end

    return cf
  elseif (key == "ignore" or key == "ignorequal" or key == "nextdrop" or key == "autodel") then
    return v and true or false
  elseif (key == "list" or key == "awardlist") then
    return (v and v ~= "") and v or "0"
  elseif (key == "role" or key == "rank") then
    return tonumber(v) or 0
  elseif (key == "nextuser") then
    return (v and v ~= "" and v ~= 0) and v or nil
  elseif (key == "autoassign") then
    return v or konfer.AUTOASSIGN_NOBODY
  end

  return v
end

--
-- The user has written an edit into the item's edit buffer. Every field is handed to the item editor's unsaved changes,
-- which keep only what differs from what is stored. An edit that was not the user's, a widget being set, is no change.
--
local function changed(res, user)
  if (not user or not qf.selitemid or not qf.iinfo) then
    return
  end

  for _, f in ipairs(ITEM_FIELDS) do
    qf.itempending:Set(f, item_value(f, qf.iinfo[f]))
  end
end

local function lootrules_setenabled(self, val)
  if (not qf or not qf.lootrules) then
    return
  end

  local pp = self.apol
  local val = val or false
  local onoff = self:AmIML() and val

  classes_setenabled(qf.lootrules, onoff)
  qf.lootrules.role:SetEnabled(onoff)
  qf.lootrules.strictarmour:SetEnabled(onoff)
  qf.lootrules.strictrole:SetEnabled(onoff)

  --
  -- The rank filter is offered only where the config says to filter by guild rank at all and this character has a guild to
  -- be ranked in, which is what cfg:RankFiltering asks.
  --
  local ranked = onoff and pp and pp.cfg:RankFiltering()

  qf.lootrules.rank:SetEnabled(ranked)
  qf.lootrules.nextrank:SetEnabled(ranked)
end

--
-- The loot rules with no item to be about: every class, no role and no rank, which is what an item that says nothing about
-- any of them has. Set without throwing, there being no item for a change to be written to.
--
local function lootrules_empty()
  if (not qf or not qf.lootrules) then
    return
  end

  classes_setchecked(qf.lootrules, true)
  qf.lootrules.role:SetValue(0, true)
  qf.lootrules.rank:SetValue(0, true)
end

-- Whether a roll or bids are open on an item right now.
function konfer:RollOrBidOpen()
  return (rolling ~= nil or biditem ~= nil) and true or false
end

-- Whether the active policy takes bids at all, which one that only ever rolls says it does not (AssignPage.hide "bids").
function konfer:TakesBids()
  local pp = self.apol

  return not (pp and pp.AssignPage and pp.AssignPage.hide and pp.AssignPage.hide.bids)
end

--
-- Whether the item selected is owed a first roll, among those the policy keeps it for before anybody else (FirstRoll in
-- Policy.lua). Only a policy that takes no bids has one, the bids button being free to open it.
--
function konfer:FirstRoll()
  local ilink = lootitem and lootitem.loot and lootitem.loot.ilink
  local cfg = self.apol and self.apol.cfg

  if (not ilink or not cfg or self:TakesBids()) then
    return false
  end

  local _, owed = cfg:PolicyCall("FirstRoll", false, ilink)

  return owed and true or false
end

--
-- Whether the bids button opens something of the policy's own on the item selected, no first roll being owed, with Open
-- roll lit beside it (AssignPage.firstroll.Offers in Policy.lua).
--
function konfer:FirstRollOffers()
  local pp = self.apol
  local fr = pp and pp.AssignPage and pp.AssignPage.firstroll
  local ilink = lootitem and lootitem.loot and lootitem.loot.ilink

  if (not fr or not fr.Offers or not ilink or not pp.cfg or self:TakesBids()) then
    return false
  end

  local _, offers = self:PolicyHook(pp, "AssignPage.firstroll.Offers", false, fr.Offers, pp.currentid, ilink)

  return offers and true or false
end

--
-- Nobody rolled in the first roll just ended. The policy is told, which is what lets everybody in, and the Candidates are
-- drawn again. The master looter runs this as the roll ends and everybody else as EROLL tells them.
--
function konfer:FirstRollUnanswered()
  local ilink = lootroll and lootroll.ilink
  local cfg = self.apol and self.apol.cfg

  if (ilink and cfg) then
    cfg:PolicyCall("FirstRollUnanswered", nil, ilink)
    self:RefreshLootMembers()
  end
end

--
-- What the bids button says while it is not closing anything, and its tooltip: Open bids, or the first roll of POL, the
-- active policy unless given, where it takes no bids (AssignPage.firstroll in Policy.lua), in the policy's words for the
-- item selected where it has words that depend on the item.
--
function konfer:LabelBidsButton(pol)
  local pp = pol or self.apol or {}
  local ap = pp.AssignPage
  local fr = (ap and ap.hide and ap.hide.bids and ap.firstroll) or nil
  local b = qf.lootwin and qf.lootwin.oclbids
  local ilink = lootitem and lootitem.loot and lootitem.loot.ilink
  local text, tip = fr and fr.text, fr and fr.tooltip

  if (fr and fr.Label and ilink and pp == self.apol and pp.cfg) then
    local _, t, tt = self:PolicyHook(pp, "AssignPage.firstroll.Label", nil, fr.Label, pp.currentid, ilink)

    text, tip = t or text, tt or tip
  end

  if (b) then
    b:SetText(text or L["Open bids"])
    b.tiptitle = text or L["TIP052.0"]
    b.tiptext = tip or L["TIP052"]
  end
end

--
-- Whether UID meets the Constraints on the item selected, as their bid or roll would be held to them, telling nobody: a
-- class ticked, which is armour too where strict class armour is, a guild rank the filter admits where the config filters
-- by rank, and under the strict role filter the role of either of their specs. Somebody with no class or role recorded
-- passes, as their bid would. The Candidates are those who meet them.
--
function konfer:MeetsConstraints(uid)
  local cfg = self.apol and self.apol.cfg
  local name, class = nil, nil

  if (cfg and uid) then
    name, class = cfg:UserNameClass(uid)
  end

  if (not lootitem or not name or not qf.lootrules) then
    return true
  end

  local ci = class and K.IndexClass[class]

  if (ci and ci.w and qf.lootrules[ci.w] and not qf.lootrules[ci.w]:GetChecked()) then
    return false
  end

  if (cfg:RankFiltering() and lootitem.rank and lootitem.rank > 0) then
    local gi = K.guild.roster.name[name]
    local ri = gi and K.guild.roster.id[gi].rank or nil

    if (not cfg:RankPermits(ri, lootitem.rank)) then
      return false
    end
  end

  if (qf.lootrules.strictrole:GetChecked() and lootitem.role and lootitem.role ~= K.ROLE_UNSET) then
    local ms, os = KU:Roles(KU:Find(name))

    local function fits(r)
      return not r or r == K.ROLE_UNSET or r == lootitem.role
    end

    if (not fits(ms) and not fits(os)) then
      return false
    end
  end

  return true
end

local function lootbid_setenabled(val)
  if (not qf or not qf.lootwin or not qf.bidders) then
    return
  end

  local val = val or false
  local onoff = konfer:AmIML() and val

  -- An item the policy has claimed is never rolled or bid on, so neither opens on it (ItemClaim in Policy.lua).
  local open = onoff and (rolling ~= nil or not konfer:ItemClaim())

  -- An item owed a first roll has it opened from the bids button, and Open roll waits until nobody has rolled in it. One the
  -- policy offers something of its own on has that from the bids button, Open roll lit beside it.
  local first = open and rolling == nil and biditem == nil and konfer:FirstRoll()
  local offers = open and rolling == nil and biditem == nil and not first and konfer:FirstRollOffers()

  -- Kept so that a change of Candidates can put the buttons right again (RefreshLootMembers).
  qf.lootwin.onoffer = val

  -- What a first roll is called may follow the item and what has become of it, so the button is named again with nothing open.
  if (rolling == nil and biditem == nil) then
    konfer:LabelBidsButton()
  end

  -- Open bids, which is End roll while a roll is open, is dark for a policy that takes no bids, but for its first roll or
  -- what it offers in its place.
  qf.lootwin.oclbids:SetEnabled(open and (rolling ~= nil or konfer:TakesBids() or first or offers))
  qf.lootwin.orpause:SetEnabled(open and not first)
  qf.lootwin.remcancel:SetEnabled(onoff)
end

--
-- Whether USER, of class CLASS, meets the class restriction on the item. The class is the one the config recorded, so a user
-- whose class was never filled in has none, and is let through rather than held to a filter there is nothing to check them
-- against. That is the same answer verify_user_role gives somebody with no spec set. Somebody refused is told, through the
-- mod where VIAMOD says the bid came through it (TellBidder).
--
local function verify_user_class(user, class, what, viamod)
  local ci = class and K.IndexClass[class]
  local w = ci and ci.w

  if (not w) then
    return true
  end

  if (not qf.lootrules[w]:GetChecked()) then
    local clist = {}
    for k,v in pairs(K.IndexClass) do
      if (v.w) then
        if (qf.lootrules[v.w]:GetChecked()) then
          tinsert(clist, v.c)
        end
      end
    end
    konfer:TellBidder(strfmt(L["%s: you do not meet the current class restrictions (%s) - %s ignored."],
      L["MODTITLE"], tconcat(clist, ", "), what), user, viamod)
    return false
  end
  return true
end

--
-- Whether the character called USER, of class CLASS, meets the role an item is restricted to for a bid or roll WHAT. Each
-- of a user's two specs answers for one kind of claim: a main spec bid or roll is held to the role their main spec plays,
-- and an off spec roll, OFFSPEC, to the role of their off spec. A user with no spec set for that is let through, and the
-- master looter told. Somebody refused is told as verify_user_class tells them.
--
local function verify_user_role(user, class, offspec, what, viamod)
  if (not lootitem or not qf.lootrules.strictrole:GetChecked() or lootitem.role == K.ROLE_UNSET) then
    return true
  end

  local msrole, osrole = KU:Roles(KU:Find(user))
  local urole = offspec and osrole or msrole

  if (urole == lootitem.role) then
    return true
  end

  if (urole == K.ROLE_UNSET) then
    konfer.apol:info(L["user %q has no role defined - permitting %s."], shortaclass(user, class), what)
    return true
  end

  local msg = offspec and L["%s: you do not meet the current role requirement (%q). Your off spec role is %q - %s ignored."]
    or L["%s: you do not meet the current role requirement (%q). Your main spec role is %q - %s ignored."]

  konfer:TellBidder(strfmt(msg, L["MODTITLE"], K.RoleName(lootitem.role), K.RoleName(urole), what), user, viamod)
  return false
end

--
-- Put the confirmation frame up over the item selected, asking MSG about UID. WHAT says what its Ok and Cancel do
-- (confirm_ok, confirm_cancel): "handout" hands the item WIN's winner won to them, D being that hand-out, "instructions"
-- goes through with the item's own instructions giving it to WIN's winner, or ignores them, and "autoassign" hands it to
-- the enchanter or master looter it is set to go to, D being that hand-out, or leaves it on offer. See THE WIN.
--
-- Somebody not in the group cannot be given anything, so nothing is put up about them, and that answers false.
--
local function put_confirm(self, uid, msg, what, win, d)
  local name = uid and uid ~= "" and konfer.apol.cfg:UserName(uid)

  if (not lootitem or not selectedloot or not name or not KRP.players or not KRP.players[name]) then
    return false
  end

  qf.autoassign_item:SetText(strfmt(L["Item: %s"], lootitem.loot.ilink))
  qf.autoassign_msg:SetText(msg)
  qf.autoloot.what = what
  qf.autoloot.win = win
  qf.autoloot.delivery = d
  lootrules_setenabled(self, false)
  lootbid_setenabled(false)
  select_alf(ALF_CONFIRM)

  return true
end

function konfer:PauseResumeRoll(pause, timeout)
  if (not lootroll) then
    return
  end

  if (pause) then
    if (rolling == 1) then
      rolling = 2
    end
  else
    if (rolling == 2) then
      rolling = 1
      lootroll.endtime = GetTime() + timeout
    end
  end
end

--
-- Start an open roll or pause one that is currently in progress. Called when the Open Roll / Pause button is pressed. While
-- timed bids are open the same button pauses their countdown and resumes it (PauseBidClock). FIRST opens the policy's first
-- roll instead (FirstRoll in Policy.lua), from the bids button, which is a roll like any other until nobody rolls in it.
--
local function open_roll_or_pause(self, first)
  local tr = qf.lootwin

  if (not rolling and biditem and self:BidClockRunning()) then
    local pause = not self:BidClockPaused()

    self:PauseBidClock(pause)
    tr.orpause:SetText(pause and L["Resume"] or L["Pause"])
    return
  end

  if (rolling) then
    if (rolling == 1) then
      local rem = floor(lootroll.endtime - GetTime()) + 1
      tr.orpause:SetText(L["Resume"])
      rolling = 2
      if (rem < 6) then
        rem = self.apol.cfg.settings.roll_extend + 1
      end
      lootroll.resume = rem
      self.apol:CSendAM(self.apol.currentid, "PROLL", "ALERT", true, 0)
    else
      lootroll.endtime = GetTime() + lootroll.resume
      lootroll.lastwarn = nil
      self.apol:CSendAM(self.apol.currentid, "PROLL", "ALERT", false, lootroll.resume)
      lootroll.resume = nil
      tr.orpause:SetText(L["Pause"])
      rolling = 1
    end
  else
    -- Whether the roll carries an award is the policy's to say, and a roll that awards nothing is all a policy without an opinion gets.
    local _, sroll = self.apol.cfg:PolicyCall("RollAwards", false, lootlistid, lootitem.loot.ilink)

    sroll = sroll and true or false

    if (IsShiftKeyDown()) then
      sroll = not sroll
    end

    -- A roll on the one list a policy keeps for itself and nobody sees (onelist) is not said to be on any list.
    if (sroll and not self.apol.onelist) then
      local lootlist = self.apol.cfg.lists[lootlistid]

      self:SendWarning(L["MODTITLE"] .. ": " .. strfmt(self.apol:Str("AWARD_ROLL"),
                       lootlist.name, lootitem.loot.ilink, self.apol.cfg.settings.roll_timeout))
    else
      self:SendWarning(L["MODTITLE"] .. ": " .. strfmt(L["Roll for %s within %d seconds."], lootitem.loot.ilink,
        self.apol.cfg.settings.roll_timeout))
    end

    -- Whatever the policy has to say about who may roll, PUG an item's reservers (RollNotice in Policy.lua).
    local _, notice = self.apol.cfg:PolicyCall("RollNotice", nil, lootitem.loot.ilink)

    if (type(notice) == "string" and notice ~= "") then
      self:SendText(L["MODTITLE"] .. ": " .. notice)
    end

    if (self.apol.cfg.settings.ann_roll_usage) then
      self:SendText(strfmt(L["%s: type %s."], L["MODTITLE"], roll_usage(self.apol.cfg)))
    end

    qf.lootroll.StartRoll(sroll)
    lootroll.first = first and true or nil
  end
end

--
-- Hand-outs asked of the game and not yet seen to happen, keyed by loot slot. The game gives no answer to being asked (see
-- KLD.GiveMasterLoot): an item has gone when its slot clears, and one still waiting when the loot window closes never went,
-- a winner with full bags or out of range simply not getting it. So what handing an item out means for the loot list and the
-- history waits here until the item has actually gone.
--
-- What the decision itself did is not here and does not wait. An award and its history row are written when the win is
-- decided (see THE WIN), and they stand whether or not the item then arrives; Undo is how a hand-out that never happens is
-- put back.
--
-- Each entry is { slot, idx, ilink, name, uid, itemid, history, listid, recorded }. HISTORY is the code the history row is
-- written with and LISTID the list it names, if any, and RECORDED says the decision already wrote one, so none is written
-- here.
--
local deliveries = {}

--
-- Whether the config makes WHICH, one of the announcements on the Config page's Loot tab's Announcements menu, read by its
-- setting. One its policy takes off the menu (ConfigLootPage.hide) is never made, whatever the config says, a setting
-- nobody can see being one nobody can turn off. Every announcement on the menu is read through here.
--
function cfgm:Announces(which)
  local pol = self:GetPolicy()
  local hide = pol and pol.ConfigLootPage and pol.ConfigLootPage.hide

  return self.settings[which] and not (hide and hide[which])
end

--
-- Where loot is announced for POL when its config says WHERE: 0 nowhere, 1 in guild chat and 2 in raid chat. A policy that
-- takes In guild chat off Announce loot (ConfigLootPage.hide.announce_guild) announces it nowhere instead.
--
function konfer:LootAnnouncedTo(pol, where)
  local hide = pol and pol.ConfigLootPage and pol.ConfigLootPage.hide

  if (where == 1 and hide and hide.announce_guild) then
    return 0
  end

  return where
end

--
-- Tell the raid, the guild and this player that UID won ILINK. An award is the policy's to put into words (WinText), on
-- LISTID from the history row it made for it, HOW and PDATA; anything else, or a policy with nothing to say, is the
-- platform's plain line.
--
local function announce_win(self, uid, ilink, listid, how, pdata)
  local cfg = self.apol.cfg
  local who = K.DisplayName(cfg:UserName(uid))
  local text = nil

  if (strmatch(how or "", "^%l")) then
    local _, said = cfg:PolicyCall("WinText", nil, how, listid, pdata, who, ilink)
    text = said
  end

  if (type(text) ~= "string" or text == "") then
    text = strfmt(L["%s won %s. Grats!"], who, ilink)
  end

  local ts = strfmt("%s: %s", L["MODTITLE"], text)

  if (cfg:Announces("ann_winners_raid")) then
    self:SendText(ts)
  end

  printf(icolor, "%s", ts)

  if (cfg:Announces("ann_winners_guild")) then
    self:SendGuildText(ts)
  end
end

--
-- The item in D has reached who it was given to, or is to be picked up off the body or the chest: write its history row
-- unless the decision already did, and take it off the loot list. What winning it did was done when it was decided.
--
local function complete_hand_out(self, d)
  if (d.uid and not d.recorded) then
    self.apol.cfg:AddLootHistory(K.time(), d.ilink, d.uid, d.history, d.listid)
  end

  -- Without master loot the item is in the collecting leader's bags, and reaches anybody else by trade (GroupLoot.lua).
  self:OweTrade(d.ilink, d.name)

  --
  -- IDX is the item's place on the loot list when this runs at once. One the game has had to be asked about is found again by
  -- its slot and its link, the list having had time to change, the link telling apart the items added by hand, which all
  -- share slot 0.
  --
  if (d.idx) then
    self:RemoveItemByIdx(d.idx, false)
    return
  end

  for k, v in ipairs(self.raid.bossloot or {}) do
    if (v.slot == d.slot and v.ilink == d.ilink) then
      self:RemoveItemByIdx(k, false)
      break
    end
  end
end

--
-- Ask for the hand-out in D. The item goes when the game says it has, so this only asks, and answers whether the game could
-- be asked at all. An item added by hand is in no loot window and is handed over by the master looter themselves, so it is done at once.
--
local function hand_out(self, d)
  -- @debug-start@
  -- Made up loot goes to nobody, but leaves the loot list as though it had, so that what happens can be seen.
  if (self.testloot) then
    self.apol:info(L["made up loot is not handed out."])
    complete_hand_out(self, d)
    return true
  end
  -- @debug-end@

  if (d.slot == 0) then
    complete_hand_out(self, d)
    return true
  end

  d.idx = nil
  deliveries[d.slot] = d

  local rv = KLD.GiveMasterLoot(d.slot, d.name)

  if (rv == 0) then
    return true
  end

  deliveries[d.slot] = nil

  if (rv == 2) then
    self.apol:err(L["%s cannot be given %s."], d.name, d.ilink)
  else
    self.apol:err(L["%s cannot be given %s while the loot window is closed."], d.name, d.ilink)
  end

  return false
end

--
-- KLD saw the slot clear, so the item has gone to TARGET.
--
function konfer:LootAssigned(slot, target)
  local d = deliveries[slot]

  if (not d or d.name ~= target) then
    return
  end

  deliveries[slot] = nil
  complete_hand_out(self, d)
end

--
-- The loot window closed with the item still in SLOT. It never reached TARGET, and stays unrecorded as given.
--
function konfer:LootNotAssigned(slot, target)
  local d = deliveries[slot]

  deliveries[slot] = nil

  if (d) then
    self.apol:err(L["%s did not reach %s, whose bags may be full or who may be out of range."], d.ilink, K.DisplayName(target))
  end
end

--
-- A new look at the loot starts with nothing asked of the game.
--
function konfer:ForgetDeliveries()
  deliveries = {}
end

--
-- THE WIN
--
-- What becomes of an item once a bid or a roll on it has ended, or once the master looter has said yes to its own
-- instructions naming who has it, which is the same as that person winning a bid.
--
-- Somebody won it, so the win is decided and the item distributed.
--
--   A policy with a costing box (costing = true: EP/GP and DKP) puts the win to the master looter in it first, with the
--   price filled in for them to type over and the list it is charged on. Whichever of Full price, 25%, 50% or 75% off and
--   Free they press is both the charge and the confirmation. The award is made at that cost, written and announced, and the
--   item handed to the winner where "Auto-assign loot when bids close" says to.
--
--   Any other policy, Suicide Kings, awards it at once, writes it and announces it. Where that same setting says to hand it
--   over, the winner being in the group and the item on a corpse, it asks "shall I auto-loot this to X?" first.
--
-- Nobody won it, nobody having bid or rolled, so the config's "when there are no successful bids" is done at once and nobody
-- is asked: an open roll where it says to try one, and otherwise a BoE to the master looter where it says so, anything else
-- to the first of tonight's enchanters who can have it, and failing that the master looter. There is no award and nothing
-- is announced about who has it.
--
-- An item set to go to the enchanter or the master looter is not won either. Picking it asks the master looter whether to
-- hand it over (put_autoassign), and yes does just that: no award, no costing box, nothing announced, a D or A row.
--
-- Either way the item leaves the loot list. A hand-out the game refuses is delivery failing, not the decision, which stands:
-- the item leaves the list all the same, to be picked up off the body or the chest.
--
-- A win is:
--   uid, ilink, itemid, slot   who won what, and where it is on the corpse, 0 for an item added by hand
--   idx                        its place on the loot list when it was won
--   via, kind                  how it was won, "bid", "roll" or "assign", and the kind of bid or roll, as HistoryEntry has them
--   listid                     the list the award lands on, nil for a win that carries none: a plain roll, or an item's own
--                              instructions naming no list. The costing box's list choice changes it.
--   wonon                      the list it was bid or rolled on, which a row the platform writes names
--   history                    the platform's row for a win that carries no award: the roll's kind, or A for instructions
--   autodel                    the item's instructions are used up once it has been won
--   bids                       for a bid won, every bid as it stood when bids closed, ranked winner first, each { uid,
--                              kind, tier, amount }, which is what the policy prices it from (Cost); nil otherwise
--
local DISCOUNTS = { { 0.75, L["25% off"] }, { 0.5, L["50% off"] }, { 0.25, L["75% off"] }, { 0, L["Free"] } }

-- What the win costs at full price on the list it is charged on, as the policy prices it, and 0 with no list or no price.
local function win_cost(self, win)
  if (not win.listid) then
    return 0
  end

  local _, cost = self.apol.cfg:PolicyCall("Cost", nil, win.listid, win.uid, win.ilink, win.kind, win.bids)

  return tonumber(cost) or 0
end

--
-- Where the item in WIN is on the loot list now. The list may have changed while the costing box was up, so the place it had
-- when it was won is checked, and it is looked for by its slot, or for one added by hand by its link, when that has moved.
--
local function win_index(self, win)
  local bl = self.raid.bossloot or {}
  local at = bl[win.idx]

  if (at and at.slot == win.slot and at.ilink == win.ilink) then
    return win.idx
  end

  for k, v in ipairs(bl) do
    if (v.slot == win.slot and v.ilink == win.ilink) then
      return k
    end
  end

  return nil
end

-- The hand-out of the item in WIN to UID, as a delivery (see deliveries above).
local function win_delivery(self, win, uid)
  return {
    slot = win.slot, idx = win_index(self, win), ilink = win.ilink, name = self.apol.cfg:UserName(uid), uid = uid,
    itemid = win.itemid,
  }
end

--
-- Hand the item in D over, the decision about it already made. Where the game can be asked to, because who it goes to is in
-- the group and "Auto-assign loot when bids close" is on, it is, and the item leaves the loot list when the game says it
-- has gone (hand_out, which finishes an item added by hand at once). Otherwise, and when the game will not even take the
-- hand-out on, it leaves the list now, to be picked up off the body or the chest.
--
local function deliver(self, d)
  local kp = d.name and KRP.players and KRP.players[d.name]

  if (kp and kp.subgroup and self.apol.cfg.settings.auto_loot and hand_out(self, d)) then
    return
  end

  complete_hand_out(self, d)
end

--
-- Decide the win in WIN, charging COST, or the policy's own price when that is nil: the award, its history row, the item's
-- instructions forgotten where they say so, and the announcement. Answers whether it was decided, which it is unless the
-- policy's award failed, in which case nothing is done and the policy has said why.
--
local function decide_win(self, win, cost)
  local cfg = self.apol.cfg
  local phow, pdata

  if (win.listid) then
    phow, pdata = cfg:PolicyHistory(win.via, win.listid, win.uid, win.ilink, win.kind, cost)

    local _, ok = cfg:AwardItem(win.listid, win.uid, win.ilink, cfg:CreateRaidList(win.listid), true, nil, nil, win.kind, cost)

    if (not ok) then
      return false
    end

    if (phow) then
      cfg:AddLootHistory(K.time(), win.ilink, win.uid, phow, win.listid, pdata)
    end
  else
    cfg:AddLootHistory(K.time(), win.ilink, win.uid, win.history, win.wonon)
  end

  if (win.autodel and win.itemid) then
    cfg:DeleteItem(win.itemid)
  end

  announce_win(self, win.uid, win.ilink, win.listid, phow, pdata)

  return true
end

-- The loot page once the item is done with, as bids and rolls leave it, ready for the next item.
local function win_done(self)
  self:ResetBidders(true)
  select_alf(ALF_LOOT)
end

-- The loot page with the item selected on offer as any item is, the controls for it live.
local function item_on_offer(self)
  lootrules_setenabled(self, true)
  lootbid_setenabled(true)
  select_alf(ALF_LOOT)
end

--
-- Hand the item WIN decided to its winner. A policy with no costing box asks first, "shall I auto-loot this to X?", where
-- it is to be handed over at all: "Auto-assign loot when bids close" on, the winner in the group and the item on a corpse.
-- A policy with a costing box was asked in it. Where it is not to be handed over it simply leaves the loot list, for the
-- master looter to hand over.
--
local function distribute_win(self, win)
  local cfg = self.apol.cfg
  local d = win_delivery(self, win, win.uid)
  local kp = d.name and KRP.players and KRP.players[d.name]

  d.recorded = true

  if (not self.apol.costing and win.slot ~= 0 and kp and kp.subgroup and cfg.settings.auto_loot) then
    local cname = shortaclass(cfg:UserNameClass(win.uid))

    if (put_confirm(self, win.uid, strfmt(L["AUTOLOOT"], cname), "handout", win, d)) then
      self:ResetBidders(true)
      return
    end
  end

  deliver(self, d)
  win_done(self)
end

--
-- The first of tonight's enchanters who can have the item in LOOT: in the group, and one of the game's candidates for it,
-- or, for one it is not a candidate for or cannot be asked about, near enough to pick it up. The range check takes a unit
-- and says whether it could check at all; one it could not, or that is secret, counts as in range, as KoreParty counts it.
--
local function eligible_dencher(self, loot)
  local klid = loot.slot > 0 and KLD.items and KLD.items[loot.slot]

  for _, uid in ipairs(self.raid.denchersonline or {}) do
    local name = self.apol.cfg:UserName(uid)
    local kp = name and KRP.players and KRP.players[name]

    if (kp) then
      if (klid and klid.candidates[name]) then
        return uid
      end

      local inrange, checked = UnitInRange(kp.unitid)

      if (not K.CanAccess(inrange) or not K.CanAccess(checked) or not checked or inrange) then
        return uid
      end
    end
  end

  return nil
end

--
-- Nobody won the item selected: nobody bid, or, with ISROLL, nobody rolled. See THE WIN above. An item added by hand is in no
-- loot window, so there is no BoE on it to give the master looter.
--
local function nobody_won(self, isroll)
  self:ResetBidders(true)

  if (not isroll and self.apol:Setting("try_roll", self.apol.currentid)) then
    open_roll_or_pause(self)
    return
  end

  if (isroll) then
    self:EndOpenRoll(true)
  end

  if (not lootitem) then
    select_alf(ALF_LOOT)
    return
  end

  local cfg = self.apol.cfg
  local loot = lootitem.loot
  local uid, how = nil, nil

  if (loot.boe and loot.slot > 0 and cfg.settings.boe_to_ml) then
    uid, how = cfg:MyUid(), "B"
  elseif (cfg.settings.disenchant) then
    uid, how = eligible_dencher(self, loot), "D"
  end

  if (not uid) then
    uid, how = cfg:MyUid(), "L"
  end

  deliver(self, {
    slot = loot.slot, idx = selectedloot, ilink = loot.ilink, name = cfg:UserName(uid), uid = uid, itemid = loot.itemid,
    history = how, listid = lootlistid,
  })

  select_alf(ALF_LOOT)
end

--
-- THE COSTING BOX
--
-- Built once and filled for each win: the item, the winner, the list it is charged on and what it costs, the price filled
-- in and the master looter free to type over it. Every button charges its share of that figure and is the confirmation, so
-- there is no Cancel and no closing it without choosing. The window stands aside while it is up and comes back after.
--
-- A roll's win or an item's instructions may also be charged on no list at all, -None-, which is where one carrying no award
-- starts. A won bid always lands on a list, Free being how it is given for nothing.
--
local COSTING_W = 440
local COSTING_ROW_H = 20
local COSTING_FULL_H = 36
-- The space above Full price, setting it apart from the rows it settles.
local COSTING_FULL_GAP = 12

local function costing_dialog(self)
  if (qf.costingdlg) then
    return qf.costingdlg
  end

  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = "KonferCostingDialog", title = konfer.apol:WindowTitle(L["Costing"]),
    border = true, width = COSTING_W, height = 200, canmove = true, canresize = false, blackbg = true, buttons = "CENTER",
    okbutton = { text = L["Full price"], width = COSTING_W - 40, height = COSTING_FULL_H },
  })

  --
  -- The captions are a column as wide as the widest of them, the cost's being whichever policy's word for it is longest,
  -- because the dialog is built once and every policy's win is shown in it.
  --
  local captions = { L["Item"], L["Winner"], L["List"] }

  for _, pol in pairs(konfer.policies) do
    tinsert(captions, pol:Str("COST"))
  end

  local lw = KUI:WidestString(captions, "GameFontNormal")
  local vx = lw + KUI.WIDGET_GAP
  local ypos = 0

  -- A caption and the value beside it, a row of a table.
  local function caption(text, y)
    return KUI:CreateStringLabel({
      x = 0, y = y, width = lw, height = COSTING_ROW_H, autosize = false, justifyh = "RIGHT", font = "GameFontNormal",
      text = text,
    }, dlg)
  end

  local function value(y)
    return KUI:CreateStringLabel({
      x = vx, y = y, width = COSTING_W - 40 - vx, height = COSTING_ROW_H, autosize = false, justifyh = "LEFT",
    }, dlg)
  end

  caption(L["Item"], ypos)
  dlg.item = value(ypos)
  ypos = ypos - COSTING_ROW_H - KUI.WIDGET_GAP

  caption(L["Winner"], ypos)
  dlg.winner = value(ypos)
  ypos = ypos - COSTING_ROW_H - KUI.WIDGET_GAP

  caption(L["List"], ypos)
  dlg.list = KUI:CreateDropDown({
    x = vx, y = ypos, name = "KonferCostingList", itemheight = 16, dwidth = 200, mode = "SINGLE", items = KUI.emptydropdown,
  }, dlg)
  dlg.list:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and dlg.win) then
      dlg.win.listid = (newv ~= "0") and newv or nil
      dlg.ShowCost()
    end
  end)
  ypos = ypos - dlg.list:GetHeight() - KUI.WIDGET_GAP

  dlg.costcap = caption("", ypos)

  -- Up to four digits, the policy's price to start with. An emptied box is that price again.
  dlg.cost = KUI:CreateEditBox({ x = vx, y = ypos, numeric = true, len = 4, charwidth = 4 }, dlg)

  -- What the box says, or the policy's price when it says nothing.
  dlg.Charge = function()
    return tonumber(dlg.cost:GetText() or "") or dlg.fullcost or 0
  end

  --
  -- Charge SHARE of what the box says, and give the item to the winner: the win decided, the box put away, and the item
  -- distributed. Should the policy fail to make the award, it has said why and the box stays up.
  --
  dlg.Settle = function(share)
    local win = dlg.win

    if (not win or not decide_win(self, win, floor(dlg.Charge() * share + 0.5))) then
      return
    end

    dlg.win = nil
    dlg:Hide()
    distribute_win(self, win)
  end

  local bx = vx + dlg.cost:GetWidth() + KUI.WIDGET_GAP

  dlg.discounts = {}

  for i, disc in ipairs(DISCOUNTS) do
    local b = KUI:CreateButton({ x = bx, y = ypos, width = 58, height = COSTING_ROW_H, text = disc[2] }, dlg)

    b:Catch("OnClick", function(this, evt)
      dlg.Settle(disc[1])
    end)

    dlg.discounts[i] = b
    bx = bx + b:GetWidth() + KUI.WIDGET_GAP
  end

  ypos = ypos - COSTING_ROW_H - KUI.WIDGET_GAP

  dlg.OnAccept = function(this)
    this.Settle(1)
  end

  --
  -- The price on the list chosen. With -None- there is nothing to charge, so nothing to type or discount either, and the big
  -- button simply awards the item.
  --
  dlg.ShowCost = function()
    local onlist = dlg.win and dlg.win.listid and true or false

    dlg.fullcost = onlist and win_cost(self, dlg.win) or 0
    dlg.cost:SetText(tostring(dlg.fullcost))
    dlg.cost:SetEnabled(onlist)
    dlg.okbutton:SetText(onlist and L["Full price"] or L["Award item"])

    for _, b in ipairs(dlg.discounts) do
      b:SetEnabled(onlist)
    end
  end

  dlg:Catch("OnHide", function(this, evt)
    qf.mainwin:Show()
  end)

  dlg:SetHeight(0 - ypos - KUI.WIDGET_GAP + COSTING_FULL_GAP + dlg.rings.top + dlg.rings.bottom)

  qf.costingdlg = dlg
  return dlg
end

-- Put WIN to the master looter in the costing box.
local function put_costing(self, win)
  local cfg = self.apol.cfg
  local dlg = costing_dialog(self)

  dlg.win = win
  dlg:SetTitleText(self.apol:WindowTitle(L["Costing"]))
  dlg.item:SetText(win.ilink)
  dlg.winner:SetText(aclass(cfg:UserNameClass(win.uid)))
  dlg.costcap:SetText(self.apol:Str("COST"))

  -- -None-, the "0" ListChoices leads with, for anything but a won bid.
  local lists = {}

  for _, v in ipairs(cfg:ListChoices()) do
    if (v.value ~= "0" or win.via ~= "bid") then
      tinsert(lists, v)
    end
  end

  dlg.list:UpdateItems(lists)
  dlg.list:SetValue(win.listid or "0", true)
  dlg.ShowCost()

  lootrules_setenabled(self, false)
  lootbid_setenabled(false)
  qf.mainwin:Hide()
  dlg:Show()
end

--
-- Somebody has won the item selected, by a bid, a roll or the item's own instructions: decide it and distribute it, through
-- the costing box for a policy that has one. See THE WIN above. Should the policy fail to make the award, it has said why and
-- the item is back on offer.
--
local function award_win(self, win)
  if (self.apol.costing) then
    put_costing(self, win)
    return
  end

  if (not decide_win(self, win, nil)) then
    item_on_offer(self)
    return
  end

  distribute_win(self, win)
end

--
-- The item selected has instructions giving it to WIN's winner. The master looter is always asked whether to go through
-- with them (confirm_ok, confirm_cancel): yes is that person winning it as a bid is won, and no leaves the item on offer as
-- any item is.
--
local function put_instructions(self, win)
  local cfg = self.apol.cfg
  local cuser = shortclass(cfg:UserNameClass(win.uid))
  local msg = strfmt(L["AUTOASSIGN"], cuser)

  -- The one list a policy keeps for itself and nobody sees (onelist) is not said to be where the award lands.
  if (win.listid and not self.apol.onelist) then
    msg = msg .. " " .. strfmt(self.apol:Str("AWARD_AUTO"), white(cfg.lists[win.listid].name))
  end

  if (not put_confirm(self, win.uid, msg, "instructions", win)) then
    item_on_offer(self)
  end
end

--
-- Who the item in LOOT goes to, its instructions II setting it to go to the enchanter or the master looter, and the letter
-- the loot history records that under: the first of tonight's enchanters the game will let have it, D, and otherwise the
-- master looter, A. Nil when the game will let nobody it names have it. An item added by hand is in no loot window, so
-- being in the group is enough for it, the same rule a bid on one is held to.
--
local function autoassign_target(self, ii, loot)
  if (ii.autoassign ~= konfer.AUTOASSIGN_ENCHANTER and ii.autoassign ~= konfer.AUTOASSIGN_ML) then
    return nil
  end

  local klid = loot.slot > 0 and KLD.items and KLD.items[loot.slot]

  local function can_have(name)
    if (loot.slot == 0) then
      return (name and KRP.players and KRP.players[name]) and true or false
    end

    return (name and klid and klid.candidates[name]) and true or false
  end

  if (ii.autoassign == konfer.AUTOASSIGN_ENCHANTER) then
    for _, uid in ipairs(self.raid.denchersonline or {}) do
      if (can_have(self.apol.cfg:UserName(uid))) then
        return uid, "D"
      end
    end
  end

  --
  -- The master looter running loot is an admin of the config, so they have a uid in it. One that somehow does not is left
  -- to be offered like any other item rather than handed over as a row nothing can name.
  --
  local ml = self:LootRunner()
  local mlp = ml and KRP.players and KRP.players[ml]

  if (mlp and mlp.konfer_uid and can_have(ml)) then
    return mlp.konfer_uid, "A"
  end

  return nil
end

--
-- The item selected is set to go to the enchanter or the master looter. The master looter is asked whether to (confirm_ok,
-- confirm_cancel): yes hands it over, written as D or A with nothing charged, announced or asked after, and no leaves it on
-- offer as any item is. Answers whether anything was asked, which it is not when nobody it names can have the item.
--
local function put_autoassign(self, loot, ii)
  local uid, how = autoassign_target(self, ii, loot)

  if (not uid) then
    return false
  end

  local cfg = self.apol.cfg

  return put_confirm(self, uid, strfmt(L["AUTOASSIGN"], shortclass(cfg:UserNameClass(uid))), "autoassign", nil, {
    slot = loot.slot, idx = selectedloot, ilink = loot.ilink, name = cfg:UserName(uid), uid = uid, itemid = loot.itemid,
    history = how,
  })
end

--
-- Ok on the confirmation frame. A hand-out, a winner's or one an item is set to go to, asks the game to hand the item over,
-- and one it refuses is delivery failing, so the item leaves the list all the same. Instructions gone through with are the
-- named person winning the item.
--
local function confirm_ok(self)
  local li = qf.autoloot
  local what, win, d = li.what, li.win, li.delivery

  li.what, li.win, li.delivery = nil, nil, nil

  if (what == "instructions") then
    select_alf(ALF_LOOT)
    award_win(self, win)
    return
  end

  if ((what == "handout" or what == "autoassign") and not hand_out(self, d)) then
    complete_hand_out(self, d)
  end

  win_done(self)
end

--
-- Cancel. A hand-out not asked for is the master looter handing the item over themselves, so it leaves the list as given.
-- Instructions not gone through with, a winner or an enchanter or master looter they name, leave the item on offer as any
-- item is.
--
local function confirm_cancel(self)
  local li = qf.autoloot
  local what, d = li.what, li.delivery

  li.what, li.win, li.delivery = nil, nil, nil

  if (what == "handout") then
    complete_hand_out(self, d)
    win_done(self)
    return
  end

  item_on_offer(self)
end

--
-- OnUpdate script handler for the open roll timer bar. This needs to examine the remaining time, move the bar and set its
-- color accordingly (it changes from green to red gradualy as the timeout gets closer and closer) and deals with the timer
-- expiring. There are actually two versions of this. One is for the master looter and the other for everyone else. The
-- former does all kinds of checking and processing based on the timeout and the latter simply updates the spark.
--
local function rolltimer_onupdate_user()
  local rlf = qf.lootroll

  if (not lootroll) then
    rlf.timerbar:SetScript("OnUpdate", nil)
    return
  end

  if (rolling >= 2) then
    return
  end

  local now = GetTime()
  local remt = lootroll.endtime - now
  -- The timeout is whatever the master looter sent, and the game's Lua raises "Division by zero" every frame on a 0.
  local pct = ((lootroll.timeout or 0) > 0) and (remt / lootroll.timeout) or 0
  rlf.SetTimer(pct)
  rlf.timertext:SetText(strfmt(L["Roll closing in %s"], ("%.1f"):format(remt)))
end

local function rolltimer_onupdate_ml(self)
  local rlf = qf.lootroll

  if (not lootroll) then
    rlf.timerbar:SetScript("OnUpdate", nil)
    return
  end

  if (rolling >= 2) then
    return
  end

  local now = GetTime()
  if (now > lootroll.endtime) then
    rlf.timerbar:SetScript("OnUpdate", nil)
    rolling = nil
    sync_loot_panels()

    --
    -- Everybody else's roll is ended (EROLL) once it is known not to be tied. A tie carries on as the roll off (RROLL), which
    -- a roll already ended would have nothing to restrict. UNANSWERED says it was a first roll nobody rolled in.
    --
    local function ended(unanswered)
      if (self:AmIML()) then
        self.apol:CSendAM(self.apol.currentid, "EROLL", "ALERT", unanswered and true or false)
      end
    end

    lootroll.sorted = lootroll.sorted or {}

    local cfg = self.apol.cfg

    --
    -- The master looter is told the best five of each kind that anybody rolled.
    --
    for minr = 1, 301, 100 do
      local top = {}

      for i = 1, #lootroll.sorted do
        local ru = lootroll.rollers[lootroll.sorted[i]]

        if (ru.minr == minr and #top < 5) then
          tinsert(top, shortaclass(cfg:UserNameClass(lootroll.sorted[i])) .. " [" .. ru.roll .. "]")
        end
      end

      if (#top > 0) then
        self.apol:info(ROLL_KINDS[minr].top, tconcat(top, ", "))
      end
    end

    local winner = lootroll.sorted[1]
    if (winner) then
      local ilink = lootitem.loot.ilink
      local winname = cfg:UserName(winner)
      local nwinners = 1
      local winners = {}
      local winnames = {}
      -- Each of the tied by the kind they rolled, which their range in the roll again is held to (rlf_onevent).
      winners[winner] = lootroll.rollers[winner].held or lootroll.rollers[winner].minr
      -- The names are only ever said in raid chat, so they are the names as the game shows them.
      tinsert(winnames, K.DisplayName(winname))
      --
      -- A tie is the same roll within its range from kinds standing level and rollers the policy stands level: a main spec
      -- 50 beats an off spec 150 outright where main spec outranks off spec, and ties with it where the config has them
      -- level, and a +1 never ties with somebody who has none.
      --
      local winroll = lootroll.rollers[winner].roll
      local winbase = lootroll.rollers[winner].base
      local wintier = lootroll.rollers[winner].tier
      local winprio = lootroll.rollers[winner].prio
      for i = 2, #lootroll.sorted do
        local ruid = lootroll.sorted[i]
        local rr = lootroll.rollers[ruid]
        if (rr.base == winbase and rr.tier == wintier and rr.prio == winprio) then
          winners[ruid] = rr.held or rr.minr
          tinsert(winnames, K.DisplayName(cfg:UserName(ruid)))
          nwinners = nwinners + 1
        end
      end

      if (nwinners > 1) then
        -- Deal with ties here.
        if (self.apol.cfg.settings.ann_roll_ties) then
          self:SendText(strfmt(L["%s: the following users tied with %d: %s. Roll again."], L["MODTITLE"],
            winroll, tconcat(winnames, ", ")))
        end
        winnames = nil
        lootroll.rollers = {}
        lootroll.sorted = nil
        lootroll.restrict = winners
        self:ShowRollers({})
        rlf.SetTieText(winners)
        lootroll.endtime = GetTime() + self.apol.cfg.settings.roll_timeout + 1
        lootroll.lastwarn = nil
        rolling = 1
        sync_loot_panels()
        rlf.timerbar:SetScript("OnUpdate", function() rolltimer_onupdate_ml(self) end)
        self.apol:CSendAM(self.apol.currentid, "RROLL", "ALERT", ilink, self.apol.cfg.settings.roll_timeout, winners)
        return
      end

      -- A tie rolled off is won as the kind the winner tied in, the roll off itself being out of one range whatever kind.
      local winbase = lootroll.rollers[winner].held or lootroll.rollers[winner].minr
      local lh = ROLL_KINDS[winbase] and ROLL_KINDS[winbase].hist or "M"

      --
      -- A roll-off settles a bid the policy could not, so the winner has won the bid, of the kind they bid, and the roll was
      -- only how they were told apart. A roll that carries an award lands it on the list it was rolled on, and a plain roll
      -- carries none. What becomes of it is THE WIN's, once the roll is taken down whole, the system chat it listens to
      -- included. A winner who has left the group since rolling still wins.
      --
      local win = {
        uid = winner, ilink = ilink, itemid = lootitem.loot.itemid, slot = lootitem.loot.slot, idx = selectedloot,
        via = lootroll.rolloff and "bid" or "roll", kind = lootroll.rolloff and lootroll.rolloff[winner] or lh,
        listid = lootroll.awards and lootlistid or nil, wonon = lootlistid, history = lh,
        bids = lootroll.rolloff and lootroll.bids or nil,
      }

      ended()
      self:EndOpenRoll(true)
      award_win(self, win)
    else -- No winner because no-one rolled
      --
      -- Nobody rolling in a first roll (FirstRoll in Policy.lua) puts the item back on offer for Open roll, rather than
      -- sending it wherever an item nobody rolls for goes, every client being told so the policy can let everybody in.
      --
      local first = lootroll.first

      ended(first)
      self.apol:info(L["no-one rolled for %s."], lootitem.loot.ilink)

      if (first) then
        self:FirstRollUnanswered()
        self:EndOpenRoll(true)
        item_on_offer(self)
      else
        nobody_won(self, true)
      end
    end

    return
  end

  local remt = lootroll.endtime - now
  local warnt = floor(remt)
  local pct = remt / (self.apol.cfg.settings.roll_timeout + 1)
  rlf.SetTimer(pct)
  rlf.timertext:SetText(strfmt(L["Roll closing in %s"], ("%.1f"):format(remt)))

  if (warnt < 5) then
    if (not lootroll.lastwarn or warnt ~= lootroll.lastwarn) then
      lootroll.lastwarn = warnt
      if (self.apol.cfg.settings.ann_countdown) then
        self:SendText(strfmt(L["%s: roll closing in: %d"], L["MODTITLE"], warnt+1))
      end
    end
  end
end

--
-- This is called when a valid player has typed /roll. UID is theirs in the config the raid is running against, which is the
-- only kind of roller there is: the roll was read off a chat line naming a character, and rlf_onevent turned that name into
-- a uid or refused it there.
--
-- The name is needed again here to whisper them and to ask the game about them, and it comes back out of the uid rather
-- than being carried alongside it, so that a rename mid-raid cannot leave the two disagreeing.
--
local function player_rolled(self, uid, roll, minr, maxr)
  if (not rolling) then
    return
  end

  local cfg = self.apol.cfg
  local player, pclass = cfg:UserNameClass(uid)
  local cancel = (minr == 1 and maxr == 1)
  local rp

  --
  -- A roll off after a tie is between the tied, and whatever kind they roll it as it is a plain roll over their own range,
  -- out of a hundred unless it has been shortened for the kind they tied in (rlf_onevent).
  --
  if (lootroll.restrict and not cancel) then
    roll = roll - minr + 1
    minr, maxr = 1, maxr - minr + 1
  end

  --
  -- An item's role restriction holds a main spec roll to the first spec's role and an off spec roll to the second's. Transmog
  -- and vanity rolls are for somebody who wants the item whatever their spec, so no role is asked of them.
  --
  local function role_ok(kind)
    if (lootroll.restrict or (kind ~= 1 and kind ~= 101) or rp.verified[kind]) then
      return true
    end

    if (not verify_user_role(player, pclass, kind == 101, L["roll"])) then
      return false
    end

    rp.verified[kind] = true
    return true
  end

  if (lootroll.rollers[uid]) then
    --
    -- Somebody rolling again in another range is changing the kind of their roll, which is hard to get right the first
    -- time. The roll they have keeps its place in its hundred and moves to the new range, so that nobody gets a second
    -- chance at a better number. Changing to a kind with a role restriction asks it, and a refusal leaves the roll they had.
    --
    rp = lootroll.rollers[uid]
    if ((rp.minr == minr) and (rp.maxr == maxr)) then
      self:SendWhisper(strfmt(L["%s: you already rolled %d. New roll ignored."], L["MODTITLE"], rp.roll), player)
      return
    end

    if (not cancel) then
      if (not role_ok(minr)) then
        return
      end
    end

    -- Its place in its range, which is not the same length in every kind where the policy has shortened some of them.
    if (not cancel and rp.maxr ~= 1 and maxr - minr ~= rp.maxr - rp.minr) then
      rp.base = floor(rp.base * (maxr - minr + 1) / (rp.maxr - rp.minr + 1) + 0.5)
    end

    --
    -- The raid is told of a roll changing kind, however it was changed, which is all anybody without the mod has to go on:
    -- a /roll in another range shows them a number that never counts, and the Roll button's change shows them nothing.
    --
    if (not cancel and not lootroll.restrict and rp.maxr ~= 1 and rp.minr ~= minr) then
      self:SendText(strfmt(L["%s: %s changed their %s roll to %s."], L["MODTITLE"], K.DisplayName(player),
        ROLL_KINDS[rp.minr].phrase, ROLL_KINDS[minr].phrase))
    end

    rp.base = math.max(1, math.min(rp.base, cancel and rp.base or maxr - minr + 1))
    rp.minr = minr
    rp.maxr = maxr
    rp.roll = rp.base + minr - 1
  else
    if (cancel) then
      return
    end
    if (lootroll.restrict) then
      if (not lootroll.restrict[uid]) then
        self:SendWhisper(strfmt(L["%s: sorry you are not allowed to roll right now."], L["MODTITLE"]), player)
        return
      end
    else
      --
      -- Check to see if they are eligible for loot. We may have a case here where no-one is marked as a master loot
      -- candidate because the raid leader had loot set incorrectly, and subsequently changed it to master looting. In this
      -- case we don't want to block the user from rolling.
      --
      local loot = lootitem.loot
      local slot = loot.slot
      if (slot > 0) then
        -- Slot 0 is for manually added items
        local klid = KLD.items[slot]
        if (not klid.candidates[player]) then
          self:SendWhisper(strfmt(L["%s: you are not eligible to receive loot - %s ignored."], L["MODTITLE"],
            L["roll"]), player)
          return
        end
      end

      --
      -- Verify that they meet the class requirements
      --
      if (not verify_user_class(player, pclass, L["roll"])) then
        return
      end

      --
      -- The policy may keep somebody out of the roll of its own accord, PUG anybody but the reservers of an item soft
      -- reserved by somebody here, and says why.
      --
      local kind = ROLL_KINDS[minr] and ROLL_KINDS[minr].hist
      local _, allowed, why = cfg:PolicyCall("MayRoll", true, uid, kind, lootroll.ilink)

      if (not allowed) then
        self:SendWhisper(strfmt("%s: %s", L["MODTITLE"], why or L["you may not roll on this item."]), player)
        return
      end

      rp = { verified = {} }

      if (not role_ok(minr)) then
        return
      end
    end

    -- BASE is the roll within its range, which is what stays the same if they change the kind of it. HELD is the kind a
    -- tied raider rolling again tied in, which is what their range and standing are still those of.
    rp = rp or { verified = {} }
    rp.roll = roll
    rp.base = roll - minr + 1
    rp.minr = minr
    rp.maxr = maxr
    rp.held = lootroll.restrict and tonumber(lootroll.restrict[uid]) or nil
    lootroll.rollers[uid] = rp
  end

  --
  -- Everybody still in the roll, best first: by where their kind stands (kind_tiers), then by where the policy stands them
  -- among their tier (konfer:RollPriority, PUG's fewest +1s first), then by the roll within its range, which between two of
  -- one kind is the roll itself. The whole of it is shown in the Bids / rolls list and sent to the raid, so every client
  -- shows the same rolls in the same order.
  --
  local tiers = kind_tiers(cfg, true)

  lootroll.sorted = {}
  for k,v in pairs(lootroll.rollers) do
    if (v.maxr ~= 1) then
      v.tier = tiers[ROLL_KINDS[v.minr].hist] or 0
      v.prio = self:RollPriority(cfg, k, v.held or v.minr)
      tinsert(lootroll.sorted, k)
    end
  end
  tsort(lootroll.sorted, function(a, b)
    local ra, rb = lootroll.rollers[a], lootroll.rollers[b]

    if (ra.tier ~= rb.tier) then
      return ra.tier < rb.tier
    end

    if (ra.prio ~= rb.prio) then
      return ra.prio < rb.prio
    end

    if (ra.base ~= rb.base) then
      return ra.base > rb.base
    end

    return ra.minr < rb.minr
  end)

  local rows = {}

  for _, ruid in ipairs(lootroll.sorted) do
    tinsert(rows, { uid = ruid, roll = lootroll.rollers[ruid].roll, kind = lootroll.rollers[ruid].minr })
  end

  self:ShowRollers(rows)
  self.apol:CSendAM(self.apol.currentid, "TROLL", "ALERT", rows)

  --
  -- If this roll arrived within 5 seconds of the timeout reset the timeout back up to 5 seconds.
  --
  local now = GetTime()
  local rem = floor(lootroll.endtime - now) + 1
  if (rem < 6) then
    lootroll.endtime = now + self.apol.cfg.settings.roll_extend + 1
    self.apol:CSendAM(self.apol.currentid, "XROLL", "ALERT", self.apol.cfg.settings.roll_extend)
  end
end

--
-- A roll arrives as a line of system chat naming a character, which is the one place in the engine a person turns up as a
-- name. It becomes a uid here and is a uid everywhere after, and somebody the config does not hold is told so and stops
-- here: an item is won from a list, and there is no place on any list to move somebody the config has never heard of.
-- On retail a roll made during a boss fight is a secret value, and does not count.
--
local function rlf_onevent(self, this, evt, arg1, ...)
  if (evt == "CHAT_MSG_SYSTEM") then
    if (not K.CanAccess(arg1)) then
      return
    end

    local plr, roll, minr, maxr = K.Deformat(arg1, RANDOM_ROLL_RESULT)
    local player = K.CanonicalName(plr, nil)

    -- Somebody out of the group is not in the roll, except over made up loot, which is looked at out of a group.
    local outside = player and not (KRP.players and KRP.players[player])

    outside = outside and not self.testloot -- @debug-delete@

    if (outside) then
      player = nil
    end

    local uid = player and self.apol.cfg:FindUser(player)

    debug(5, "system chat %q read as a roll of %s by %s (%s) from %s to %s", tostring(arg1), tostring(roll), tostring(plr),
      tostring(uid), tostring(minr), tostring(maxr))

    if (player and not uid and roll and minr and maxr) then
      self:SendWhisper(strfmt(L["%s: you were not found in the user list. Contact an admin for help."],
        L["MODTITLE"]), player)
      return
    end

    --
    -- A roll is over the roller's whole range of a kind the config takes: the hundred, or less where the policy has shortened
    -- it (konfer:RollTop), a tied raider rolling again being held to the range of the kind they tied in. A hundred from
    -- somebody whose range is shorter is refused and they are told theirs.
    --
    if (uid and roll and minr and maxr) then
      local cfg = self.apol.cfg
      local top = self:RollTop(cfg, uid, lootroll and lootroll.restrict and tonumber(lootroll.restrict[uid]) or minr)
      local kindok = roll_kind_on(cfg, minr, minr + 99)

      if ((minr == 1 and maxr == 1) or (kindok and maxr == minr + top - 1)) then
        -- @debug-start@
        -- To force a tie, /run KONFER_ROLL_TIE = 42: everybody's first roll on an item reads as that in its range. Roll-offs
        -- are left alone.
        local tie = tonumber(_G.KONFER_ROLL_TIE)

        if (tie and maxr > minr and lootroll and not lootroll.restrict and not lootroll.rollers[uid]) then
          roll = math.max(minr, math.min(minr + floor(tie) - 1, maxr))
        end
        -- @debug-end@
        player_rolled(self, uid, roll, minr, maxr)
      elseif (kindok and maxr == minr + 99) then
        self:SendWhisper(strfmt(L["%s: your roll is %d-%d."], L["MODTITLE"], minr, minr + top - 1), player)
      else
        self:SendWhisper(strfmt(L["%s: invalid roll. Use %s."], L["MODTITLE"], roll_usage(cfg)), player)
      end
    end
  end
end

--
-- Either remove an item or cancel a bid / roll.
--
local function remove_or_cancel(self)
  local tr = qf.lootwin

  if (rolling) then
    if (self.apol.cfg:Announces("ann_cancel")) then
      self:SendWarning(strfmt(L["%s: %s cancelled!"], L["MODTITLE"], L["roll"]))
    end
    self:EndOpenRoll()
    return
  end

  if (biditem) then
    if (self.apol.cfg:Announces("ann_cancel")) then
      self:SendWarning(strfmt(L["%s: %s cancelled!"], L["MODTITLE"], L["bid"]))
    end
    self:ResetBidders(false)
    lootbid_setenabled(true)
    self.apol:CSendAM(self.apol.currentid, "BICAN", "ALERT")
    return
  end

  if (selectedloot) then
    self:RemoveItemByIdx(selectedloot, false)
  end
end

--
-- Roll and Retract on the roll frame F, side by side and centred, everybody's, the master looter's included, as Bid on item
-- and Retract bid are while bids are open. Roll is ONROLL, given nothing to put up the kinds of roll this one takes, and a
-- hundred to make that kind of roll, a double click being main spec without asking (ONROLL's second argument true). Retract
-- is ONRETRACT, which takes this character's own roll back, and is lit once they have one in. F.TAKES is the set of
-- hundreds the roll open now takes.
--
local function build_roll_buttons(f, onroll, onretract)
  local GAP = KUI.WIDGET_GAP
  local w = KUI:WidestString({ L["ROLL_BUTTON"], L["Retract"] }) + 24
  local rf = MakeFrame("Frame", nil, f.block)

  rf:SetSize(2 * w + GAP, 24)
  f.rows = { rf }
  f.takes = {}

  f.roll = KUI:CreateButton({ x = 0, y = 0, width = w, text = L["ROLL_BUTTON"], enabled = false, doubleclick = true }, rf)
  f.roll:Catch("OnClick", function(this, evt, ...)
    onroll(nil)
  end)
  f.roll:Catch("OnDoubleClick", function(this, evt, ...)
    onroll(1, true)
  end)

  f.cancel = KUI:CreateButton({ x = w + GAP, y = 0, width = w, text = L["Retract"], enabled = false }, rf)
  f.cancel:Catch("OnClick", function(this, evt, ...)
    onretract()
  end)
end

--
-- Bid on the open item, KIND being the kind of bid as its code, or take this character's bid back. The master looter's own
-- goes straight in and everybody else's goes to the master looter, whichever button it came from.
--
--
-- The master looter's: UID, already in the roll, wants theirs to be of the kind rolled from MINR. It goes the way a second
-- /roll in another range does, keeping its place in its hundred, so nothing is rolled again and nobody gets a second number.
--
function konfer:ChangeRollKind(uid, minr)
  minr = tonumber(minr)

  if (not rolling or not uid or not minr or not lootroll.rollers[uid]) then
    return
  end

  if (not roll_kind_on(self.apol.cfg, minr, minr + 99)) then
    return
  end

  local top = self:RollTop(self.apol.cfg, uid, lootroll.restrict and tonumber(lootroll.restrict[uid]) or minr)

  player_rolled(self, uid, lootroll.rollers[uid].roll, minr, minr + top - 1)
end

--
-- A roll button, pressed. The first roll is made through the game, which is what everybody else reads, over this
-- character's own range (konfer:RollTop). Once in, pressing another kind only says so to the master looter, a second /roll
-- being a number nobody needs.
--
local function roll_kind_pressed(self, minr)
  local mine = self.apol.cfg and self.apol.cfg:MyUid()
  local rolled = false

  for _, v in ipairs(rollrows or {}) do
    if (mine and v.uid == mine) then
      rolled = true
    end
  end

  if (not rolled) then
    local held = lootroll and lootroll.restrict and tonumber(lootroll.restrict[mine or ""])

    RandomRoll(minr, minr + self:RollTop(self.apol.cfg, mine, held or minr) - 1)
  elseif (self:AmIML()) then
    self:ChangeRollKind(mine, minr)
  elseif (self:LootRunner()) then
    self.apol:CSendWhisperAM(self.apol.currentid, self:LootRunner(), "RKIND", "ALERT", minr)
  end
end

--
-- The amount a bid made from the buttons carries: nothing where the open bid takes none, and where it does, what is typed
-- in the box beside Bid on item as a whole number, which is also what Force bid bids for somebody. Where nothing that is
-- one is typed there, false, the player having been told to type one first.
--
local function amount_for_bid(self)
  if (not openamounts) then
    return nil
  end

  local typed = qf.myamount and strmatch(qf.myamount:GetText() or "", "^%s*(%d+)%s*$")
  local amount = typed and tonumber(typed) or nil

  if (not amount) then
    self.apol:err(L["type what you bid in the box beside %s first."], L["Bid on item"])
    return false
  end

  return amount
end

local function bid_mine(self, kind, amount)
  if (self:AmIML()) then
    self:NewBidder(self.apol.cfg:MyUid(), kind, amount, true)
  elseif (self:LootRunner()) then
    self.apol:CSendWhisperAM(self.apol.currentid, self:LootRunner(), "BIDME", "ALERT", biditem, kind, amount)
  end

  -- The amount is spent with the bid, so the box is left empty and nobody is still typing in it.
  if (amount and qf.myamount) then
    qf.myamount:SetText("")
    qf.myamount:ClearFocus()
  end
end

local function retract_mine(self)
  if (self:AmIML()) then
    self:RetractBidder(self.apol.cfg:MyUid())
  elseif (self:LootRunner()) then
    self.apol:CSendWhisperAM(self.apol.currentid, self:LootRunner(), "BIDRT", "ALERT", biditem)
  end
end

--
-- The Bids / rolls panel BB while a roll is open, a pane of its own standing where the bid one does: the rollers, best first,
-- the full width of the panel, and under them, centred, Remove, the master looter's alone, which takes the one selected out
-- of the roll. The list stops short of the foot to leave Remove its room, whoever is looking.
--
-- A row is what they rolled, who they are and the kind of roll it was, each in a column of its own at a fixed place in the
-- row so that the three line up down the list. The roll, in brackets, is set left in a column as wide as the widest roll can
-- be, and the kind left in one as wide as the widest of their names, against the row's right edge. The name has what is
-- between. The roll and the kind are in the list's own yellow, the name in its class colour.
--
--
-- The right hand end of a row in the Bids / rolls list, a bid's and a roll's alike: the roles of the claimant's main spec and
-- off spec against the row's edge, and before them, in a column as wide as the widest, the kind of claim, in FONT. The
-- name runs up to rf.kind.
--
local CLAIM_EDGE = 8
local CLAIM_ROLES_W = 12 + 2 + 12

local function claim_row_end(rf, font)
  local names = {}

  for _, k in pairs(ROLL_KINDS) do
    tinsert(names, "[" .. k.name .. "]")
  end

  rf.osrole = KUI:CreateRoleIcon(rf, 12)
  rf.osrole:SetPoint("RIGHT", rf, "RIGHT", 0 - CLAIM_EDGE, 0)
  rf.msrole = KUI:CreateRoleIcon(rf, 12)
  rf.msrole:SetPoint("RIGHT", rf.osrole, "LEFT", -2, 0)

  rf.kind = rf:CreateFontString(nil, "ARTWORK", font)
  rf.kind:SetJustifyH("LEFT")
  rf.kind:SetJustifyV("MIDDLE")
  rf.kind:SetPoint("TOPRIGHT", rf, "TOPRIGHT", 0 - CLAIM_EDGE - CLAIM_ROLES_W - KUI.WIDGET_GAP, -2)
  rf.kind:SetPoint("BOTTOMRIGHT", rf, "BOTTOMRIGHT", 0 - CLAIM_EDGE - CLAIM_ROLES_W - KUI.WIDGET_GAP, 2)
  rf.kind:SetWidth(KUI:WidestString(names, font))
end

local function build_roll_pane(self, bb)
  local GAP = KUI.WIDGET_GAP
  local BTN_W = 100
  local BTN_H = 24
  local EDGE = 8
  local FONT = "GameFontNormalSmallLeft"
  local ROLL_W = KUI:WidestString({ "[400]" }, FONT)

  local rp = MakeFrame("Frame", nil, bb)
  rp:SetAllPoints(bb)
  rp:Hide()
  bb.rollpane = rp

  rp.remove = KUI:CreateButton({ x = 0, y = 0, width = BTN_W, height = BTN_H, text = L["Remove"], enabled = false,
    tooltip = { title = "$$", text = L["TIP091"] } }, rp)
  rp.remove:ClearAllPoints()
  rp.remove:SetPoint("BOTTOM", rp, "BOTTOM", 0, 0)

  -- Taking somebody out of the roll is their own 1-1 roll made for them, so it goes through the one path a roll ever takes.
  rp.remove:Catch("OnClick", function(this, evt, ...)
    if (rolling and selectedroller) then
      player_rolled(self, selectedroller, 1, 1, 1)
    end
  end)

  -- As the bid pane's: the list's space stops the button's height short of the foot, and what its whole rows leave over is
  -- the gap between them and the button.
  local sframe = MakeFrame("Frame", nil, rp)
  sframe:SetPoint("TOPLEFT", rp, "TOPLEFT", 0, 0)
  sframe:SetPoint("BOTTOMRIGHT", rp, "BOTTOMRIGHT", 0, BTN_H)

  local function column(rf, justify)
    local fs = rf:CreateFontString(nil, "ARTWORK", FONT)
    fs:SetJustifyH(justify)
    fs:SetJustifyV("MIDDLE")
    return fs
  end

  local arg = {
    name = "KonferRollersScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      -- Only the master looter picks a roller, there being nothing for anybody else to do with one.
      local rf = KUI.NewItemHelper(objp, num, "KonferRollerButton", 160, 16, nil, nil, function(this, idx)
        if (not self:AmIML()) then
          return true
        end
      end, nil)

      rf.roll = column(rf, "LEFT")
      rf.roll:SetPoint("TOPLEFT", rf, "TOPLEFT", EDGE, -2)
      rf.roll:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", EDGE, 2)
      rf.roll:SetWidth(ROLL_W)

      claim_row_end(rf, FONT)

      rf.text:ClearAllPoints()
      rf.text:SetPoint("TOPLEFT", rf.roll, "TOPRIGHT", GAP + GAP, 0)
      rf.text:SetPoint("BOTTOMRIGHT", rf.kind, "BOTTOMLEFT", 0 - GAP, 0)

      return rf
    end,
    setitem = function(objp, idx, slot, btn)
      local ru = rollrows[idx]
      local kind = ROLL_KINDS[ru.kind]
      local nm, cls = self.apol.cfg:UserNameClass(ru.uid)

      btn.roll:SetText("[" .. tostring(ru.roll) .. "]")
      btn.kind:SetText(kind and ("[" .. kind.name .. "]") or "")
      konfer:SetRoleIcons(btn.msrole, btn.osrole, self.apol.cfg, ru.uid)

      return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
        return nm and shortaclass(nm, cls) or ru.uid
      end)
    end,
    selectitem = function(objp, idx, slot, btn, onoff)
      if (onoff and rollrows and rollrows[idx]) then
        selectedroller = rollrows[idx].uid
      else
        onoff = false
        selectedroller = nil
      end

      rp.remove:SetEnabled(onoff and self:AmIML())
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }

  qf.rollscroll = KUI:CreateScrollList(arg, sframe)
end

local function rlist_newitem(objp, num)
  local rf = KUI.NewItemHelper(objp, num, "KonferLListButton", 155, 16, nil, nil, nil, nil)

  rf:SetScript("OnClick", function(this)
    if (not konfer:AmIML()) then
      return
    end

    local idx = this:GetID()
    --
    -- Be careful to only reset bidders when we have actually switched to a different list by clicking on it.
    --
    if (not lootlistid or lootlistid ~= konfer.apol.sortedlists[idx].id) then
      -- The following will set lootlistid and lootlist and populate the members scroll list with the list members.
      this:GetParent():GetParent():SetSelected(idx, true, true)
      konfer:ResetBidList()
      konfer.apol:CSendAM(konfer.apol.currentid, "LLSEL", "ALERT", lootlistid, true)
      if ((biditem or (lootroll and lootroll.awards)) and konfer.apol.cfg:Announces("ann_bidchanges")) then
        local lootlist = konfer.apol.cfg.lists[lootlistid]
        konfer:SendWarning(L["MODTITLE"] .. ": " .. strfmt(L["Bid list changed to %q for %s."], lootlist.name,
          lootitem.loot.ilink))
      end
      check_missing_members(konfer)
    end
  end)
  return rf
end

function konfer:RestrictedRoll(ilink, timeout, winners)
  if (not lootroll) then
    return
  end

  -- Kept, so that this character's own roll buttons roll the range of the kind they tied in.
  lootroll.restrict = winners
  self:ShowRollers({})
  qf.lootroll.SetTieText(winners)

  --
  -- WINNERS is the set of uids allowed to roll again, so a client the config does not hold this character in is not one of
  -- them and Roll goes dark, which is the same answer the master looter would whisper back. Retract waits on a roll in.
  --
  qf.lootroll.roll:SetEnabled(winners[konfer.apol.cfg:MyUid() or ""] and true or false)

  select_alf(ALF_ROLL)
  lootroll.timeout = timeout
  lootroll.endtime = GetTime() + timeout + 1
  rolling = 1
  sync_loot_panels()
  qf.lootroll.timerbar:SetScript("OnUpdate", function() rolltimer_onupdate_user() end)
end

function konfer:ExtendRoll(timeout)
  if (lootroll and rolling == 1) then
    lootroll.endtime = GetTime() + timeout + 1
  end
end

--
-- Show ROWS, everybody in the roll best first as { uid = uid, roll = roll, kind = minr }, in the list of rollers. The master
-- looter works them out and every other client is sent them (TROLL). Whoever was selected stays selected if still in it.
--
function konfer:ShowRollers(rows)
  local olduid = selectedroller
  local sel = nil

  rollrows = rows or {}
  selectedroller = nil
  qf.bidders.rollpane.remove:SetEnabled(false)

  for k, v in ipairs(rollrows) do
    if (v.uid == olduid) then
      sel = k
    end
  end

  qf.rollscroll.itemcount = #rollrows
  qf.rollscroll:UpdateList()
  qf.rollscroll:SetSelected(sel, true, true)

  -- There is a roll of your own to cancel only once it is among them.
  local mine = self.apol.cfg and self.apol.cfg:MyUid()
  local rolled = false

  for _, v in ipairs(rollrows) do
    if (mine and v.uid == mine) then
      rolled = true
    end
  end

  qf.lootroll.cancel:SetEnabled(rolled)
end

local function rlist_setitem(objp, idx, slot, btn)
  btn:SetText(konfer.apol.cfg.lists[konfer.apol.sortedlists[idx].id].name)
  btn:SetID(idx)
  btn:Show()
end

local function rlist_selectitem(objp, idx, slot, btn, onoff)
  local onoff = onoff or false

  --
  -- A row deselected by the list being redrawn is not the master looter leaving the list, and acting on it would empty the
  -- candidates and throw away every bidder in the middle of a bid.
  --
  if (refreshing_lists) then
    return
  end

  hide_popup()

  if (onoff) then
    lootlistid = konfer.apol.sortedlists[idx].id
    local lootlist = konfer.apol.cfg.lists[lootlistid]

    --
    -- The rank filter a list carries, or none at all. A rank filter belongs to a list rather than to the config, so there is
    -- nothing above the list to fall back to.
    --
    qf.lootrules.rank:SetValue(lootlist.def_rank or 0)

    --
    -- Set the strict enforcing options
    --
    qf.lootrules.strictarmour:SetChecked(lootlist.strictcfilter)
    qf.lootrules.strictrole:SetChecked(lootlist.strictrfilter)
  else
    lootlistid = nil
  end

  -- Updates members, memberid
  konfer:RefreshLootMembers()
end

--
-- The menu a right click on a candidate puts up at the pointer while bids are open: a force bid of each kind the config
-- takes, and under a spacer a force retract when they have a bid in. Made once and handed its items each time.
--
local candmenu = nil

-- Put the menu up at the pointer holding ITEMS.
local function show_menu(items)
  if (not candmenu) then
    -- The policy window's, so that it stands over the window rather than under it.
    candmenu = KUI:CreatePopupMenu({ name = "KonferCandidateMenu", itemheight = 16, escclose = true, items = items },
      konfer.mainwin)
  else
    candmenu:UpdateItems(items)
  end

  local x, y = GetCursorPosition()
  local scale = candmenu:GetEffectiveScale()

  candmenu:ClearAllPoints()
  -- Just clear of the pointer, so that the menu's corner is not under it for the second click of a double click.
  candmenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 4, y / scale)
  candmenu:Show()
end

--
-- Roll pressed (build_roll_buttons): with MINR, make that kind of roll, a DOUBLE click's first click having put up the menu
-- its second takes away; without, put up the kinds of roll the open one takes, headed by the item, or roll main spec where
-- that is all it takes.
--
function konfer:MyRoll(minr, double)
  local takes = qf.lootroll and qf.lootroll.takes or {}

  if (double and candmenu) then
    candmenu:Hide()
  end

  if (minr) then
    roll_kind_pressed(self, minr)
    return
  end

  local items = { { text = lootroll and lootroll.ilink or "", title = true } }

  for _, m in ipairs(KIND_ORDER) do
    if (takes[m]) then
      tinsert(items, { text = strfmt(L["Roll %s"], ROLL_KINDS[m].phrase), value = m, checkable = false, keep = false,
        func = function(item, created)
          if (not created) then
            roll_kind_pressed(self, m)
          end
        end })
    end
  end

  if (#items < 3) then
    roll_kind_pressed(self, 1)
    return
  end

  show_menu(items)
end

local function candidate_menu(uid)
  local ahide = konfer.apol and konfer.apol.AssignPage and konfer.apol.AssignPage.hide or {}

  --
  -- A policy with no Force bid has none here either (AssignPage.hide). In an auction the bid forced is for the amount the
  -- master looter has typed beside Bid on item (amount_for_bid), which is how a raider too slow to bid is helped.
  --
  if (not uid or not biditem or not bidders or ahide.forcebid) then
    return
  end

  -- Headed by who it is for, in their class colour.
  local items = { { text = shortaclass(konfer.apol.cfg:UserNameClass(uid)), title = true } }

  for _, code in ipairs(bid_kinds(konfer.apol.cfg)) do
    tinsert(items, { text = strfmt(L["Force %s"], KIND_BY_CODE[code].phrase), value = code, checkable = false, keep = false,
      func = function(item, created)
        if (not created) then
          local amount = amount_for_bid(konfer)

          if (amount ~= false) then
            konfer:NewBidder(uid, code, amount)
          end
        end
      end })
  end

  for _, b in ipairs(bidders) do
    if (b.uid == uid) then
      tinsert(items, { text = "-" })
      tinsert(items, { text = L["Force retract"], value = "retract", checkable = false, keep = false,
        func = function(item, created)
          if (not created) then
            konfer:RetractBidder(uid)
          end
        end })
      break
    end
  end

  show_menu(items)
end

--
-- Bid on item, pressed. A config taking main spec alone is bid main spec. One taking more asks which, in the same menu
-- headed by the item, and a bid already in changes to the kind picked. Where the open bid takes an amount, the bid is for
-- what is typed in the box beside the button, and nothing is bid until something is.
--
local function my_bid_pressed(self)
  local kinds = {}
  local amount = amount_for_bid(self)

  if (amount == false) then
    return
  end

  -- What the open bid takes, as the master looter said when opening it.
  for code in (openkinds or "M"):gmatch(".") do
    if (KIND_BY_CODE[code]) then
      tinsert(kinds, code)
    end
  end

  if (#kinds < 2) then
    bid_mine(self, "M", amount)
    return
  end

  -- The item up for bids, which every client holds in the loot it was sent, where only the master looter selects one.
  local loot = biditem and self.raid.bossloot and self.raid.bossloot[biditem]
  local items = { { text = loot and loot.ilink or "", title = true } }

  for _, code in ipairs(kinds) do
    tinsert(items, { text = strfmt(L["Bid %s"], KIND_BY_CODE[code].phrase), value = code, checkable = false, keep = false,
      func = function(item, created)
        if (not created) then
          bid_mine(self, code, amount)
        end
      end })
  end

  show_menu(items)
end

--
-- Bid on item and Retract bid, everybody's, centred along the foot of the bid pane under the list of bidders. Bid is live
-- while bids are open and Retract while you have one in (refresh_bidders). Where the open bid takes an amount the box it is
-- typed in stands to their left, the three centred together, and it is not there at all otherwise (show_amount_box).
--
local function build_my_bid_buttons(self, bb)
  local GAP = KUI.WIDGET_GAP
  local w = KUI:WidestString({ L["Bid on item"], L["Retract bid"] }) + 24

  local row = MakeFrame("Frame", nil, bb.bidpane)
  row:SetSize(2 * w + GAP, 24)
  row:SetPoint("BOTTOM", bb, "BOTTOM", 0, 0)
  qf.mybidrow = row

  qf.myamount = KUI:CreateEditBox({ x = 0, y = -2, numeric = true, len = 5, charwidth = 6,
    tooltip = { title = "$$", text = L["TIP118"] } }, row)
  qf.myamount:Hide()

  --
  -- Where the master looter is giving an item its price as bids open (open_close_bids), Enter opens them at what was typed,
  -- leaving the box empty for their own bid. Nothing typed, or Escape, opens nothing.
  --
  qf.myamount:Catch("OnEnterPressed", function(this, evt, value)
    local idx = qf.myamount.pricing
    local price = tonumber(strmatch(value or "", "^%s*(%d+)%s*$"))

    if (not idx) then
      return
    end

    qf.myamount.pricing = nil
    qf.myamount:SetText("")

    if (price and idx == selectedloot and not biditem and not rolling and lootlistid) then
      self:StartBids(price)
    else
      sync_loot_panels()
    end
  end)
  qf.myamount:Catch("OnEscapePressed", function(this, evt)
    if (qf.myamount.pricing) then
      qf.myamount.pricing = nil
      qf.myamount:SetText("")
      sync_loot_panels()
    end
  end)

  --
  -- A click asks which kind. A double click is main spec without asking: its first click has put the menu up, and the second
  -- takes it away again and bids. Where main spec is all there is the first click has already bid it.
  --
  qf.mybid = KUI:CreateButton({ x = 0, y = 0, width = w, text = L["Bid on item"], enabled = false, doubleclick = true }, row)
  qf.mybid:Catch("OnClick", function(this, evt, ...)
    my_bid_pressed(self)
  end)
  qf.mybid:Catch("OnDoubleClick", function(this, evt, ...)
    if (#bid_kinds(self.apol.cfg) > 1) then
      if (candmenu) then
        candmenu:Hide()
      end

      local amount = amount_for_bid(self)

      if (amount ~= false) then
        bid_mine(self, "M", amount)
      end
    end
  end)

  qf.myretract = KUI:CreateButton({ x = w + GAP, y = 0, width = w, text = L["Retract bid"], enabled = false }, row)
  qf.myretract:Catch("OnClick", function(this, evt, ...)
    retract_mine(self)
  end)
end

local function mlist_newitem(objp, num)
  local bname = "KonferLMListButton" .. tostring(num)
  local rf = MakeFrame("Button", bname, objp.content)

  rf:SetWidth(155)
  rf:SetHeight(16)
  KUI:RowHighlight(rf)

  --
  -- As the Lists page's members: against the row's right edge the roles of the candidate's main spec and off spec, MARKS_GAP
  -- before them the enchanter marker, right justified, and the name up to that. Frozen and reserved say nothing about who
  -- may have an item, so enchanter is the only marker a candidate carries.
  --
  local mfont = "GameFontNormalSmall"
  local MARKS_GAP = 8

  rf.osrole = KUI:CreateRoleIcon(rf, 12)
  rf.osrole:SetPoint("RIGHT", rf, "RIGHT", 0 - KUI.WIDGET_GAP, 0)
  rf.msrole = KUI:CreateRoleIcon(rf, 12)
  rf.msrole:SetPoint("RIGHT", rf.osrole, "LEFT", -2, 0)

  local si = rf:CreateFontString(nil, "ARTWORK", mfont)
  si:ClearAllPoints()
  si:SetPoint("RIGHT", rf.msrole, "LEFT", 0 - MARKS_GAP, 0)
  si:SetWidth(KUI:WidestString({ konfer:UserMarkers(true, false, false) }, mfont))
  si:SetHeight(16)
  si:SetJustifyH("RIGHT")
  si:SetJustifyV("MIDDLE")
  rf.indicators = si

  -- Where they stand, in a column of its own at the row's left, and the name clear of it, an alt's hung from its main's.
  local ps = rf:CreateFontString(nil, "ARTWORK", mfont)
  ps:ClearAllPoints()
  ps:SetPoint("TOPLEFT", rf, "TOPLEFT", 0, 0)
  ps:SetPoint("BOTTOMRIGHT", rf, "BOTTOMLEFT", 25, 0)
  ps:SetJustifyH("LEFT")
  ps:SetJustifyV("MIDDLE")
  rf.pos = ps

  -- As on the Lists page, the name starts a gap past the policy's standing column, and an alt's connector starts there too.
  local NAME_GAP = 5
  local NAME_X = 25 + NAME_GAP

  local nm = rf:CreateFontString(nil, "ARTWORK", mfont)
  nm:ClearAllPoints()
  nm:SetPoint("TOPLEFT", rf, "TOPLEFT", NAME_X, 0)
  nm:SetPoint("BOTTOMRIGHT", si, "BOTTOMLEFT", 0 - KUI.WIDGET_GAP, 0)
  nm:SetJustifyH("LEFT")
  nm:SetJustifyV("MIDDLE")
  -- One line, a name too long for it ending in an ellipsis rather than running on over the icons.
  nm:SetWordWrap(false)
  rf.name = nm

  rf.SetText = function(self, postext, name, ench, frozen, res, tree)
    local colw, font = konfer:StandingColumn(konfer.apol)
    local namex = colw + NAME_GAP
    local indent = KUI:SetRowTree(self, tree, namex, 0)

    self.pos:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", colw, 0)
    self.pos:SetFontObject(font)
    self.name:SetPoint("TOPLEFT", self, "TOPLEFT", namex + indent, 0)
    self.name:SetText(name)
    self.indicators:SetText(konfer:UserMarkers(ench))
    self.pos:SetText((tree or postext == "") and "" or ("[" .. tostring(postext) .. "]"))
  end

  -- Who the row is, spelled out, to the list's left, clear of the constraints and bids beside it, and what the policy says
  -- about them on the list the loot is going to.
  rf:HookScript("OnEnter", function(this)
    local pp = konfer.apol

    if (this.uid and pp and pp.cfg) then
      konfer:ShowUserTooltip(this, pp.cfg, this.uid, true, "ANCHOR_LEFT", lootlistid)
    end
  end)
  rf:HookScript("OnLeave", function(this)
    GameTooltip:Hide()
  end)

  -- A right click selects the candidate as a left one does and puts up what can be done for them.
  rf:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  rf:SetScript("OnClick", function(this, button)
    qf.membersearch:ClearFocus()
    if (not konfer:AmIML()) then
      return
    end
    qf.membersearch:SetText("")
    local idx = this:GetID()
    this:GetParent():GetParent():SetSelected(idx, true, true)

    if (button == "RightButton") then
      candidate_menu(members[idx] and members[idx].id)
    end
  end)

  return rf
end

local function mlist_setitem(objp, idx, slot, btn)
  local m = members[idx]
  local uid = m.id
  local at = tostring(m.standing or m.idx)
  local acfg = konfer.apol.cfg
  local ench = acfg:IsEnchanter(uid)
  local frozen = acfg:IsFrozen(uid)
  local res = acfg:IsReserved(uid)

  -- Everybody listed is in the raid, so in class colour.
  if (uid and acfg.uids[uid]) then
    btn:SetText(at, shortaclass(acfg:UserNameClass(uid)), ench, frozen, res)
  else
    btn:SetText("", "", ench, frozen, res)
  end

  btn.uid = uid and acfg.uids[uid] and uid or nil
  btn.standing = btn.uid and at or nil
  konfer:SetRoleIcons(btn.msrole, btn.osrole, acfg, btn.uid)
  btn:SetID(idx)
  btn:Show()
end

local function mlist_selectitem(objp, idx, slot, btn, onoff)
  local onoff = onoff or false

  if (onoff) then
    local mid = members[idx].id
    memberid = mid
  else
    memberid = nil
  end

  -- During a roll the same button is the off spec roll, which has nothing to do with who is selected.
  if (not rolling) then
    qf.bidders.forcebid:SetEnabled(konfer:AmIML() and onoff and biditem ~= nil)
  end
end

local function lloot_on_click(self, this)
  local idx = this:GetID()

  if (IsModifiedClick("CHATLINK")) then
    ChatFrameUtil.InsertLink(self.raid.bossloot[idx].ilink)
    return
  end

  if (not self:AmIML()) then
    return
  end

  self:OfferLoot(idx)
end

--
-- Put item IDX of the loot list on offer, as the master looter picking it does, its instructions and the policy's claim on
-- it asked again, its filters and its list, and the raid told. A policy whose claim on the item has just been decided, a
-- council's vote, offers it again this way. Nothing changes while a bid or a roll is open, Cancel being how one is left.
--
function konfer:OfferLoot(idx)
  if (not idx or not self.raid.bossloot or not self.raid.bossloot[idx] or not self:AmIML() or rolling or biditem) then
    return
  end

  --
  -- Ok we have a new loot item. Process it. Note that this could be the same item that was previously selected. We want to
  -- process it all over again in case they had messed with ranks, armor class filters etc. By clicking on it we make the
  -- assumption the user wanted to reset everything but the two strict filters, which stay as they were left.
  --
  local loot = self.raid.bossloot[idx]
  local itemid = loot.itemid
  local slot = loot.slot
  local cf = nil
  local role = 0
  local slist = nil
  local rank = nil

  if (self.iitems[itemid]) then
    cf = self.iitems[itemid].cfilter
  end

  --
  -- An ignored item keeps its instructions but none of them is in use. One normally never gets this far, being left off the
  -- loot list, but an item added by hand is put there whatever it says.
  --
  local ii = self.apol.cfg.items[itemid]
  if (ii and not ii.ignore) then
    --
    -- What we need to check for here are class loot filters, role filters, and specific user assignments. We will always
    -- send out a selection event with the filters, but we will deal with specific user assignments right here and now,
    -- giving the ML the option of actually assigning the loot if the user is in the raid and eligible to receive the loot.
    --
    cf = ii.cfilter or cf
    role = ii.role or role
    slist = (ii.list and self.apol.cfg.lists[ii.list]) and ii.list or slist
    rank = ii.rank or rank
  end

  -- A list named by the item or as the default that has since been deleted names nothing.
  local deflist = self.apol.cfg.settings.def_list

  if (not slist and deflist and self.apol.cfg.lists[deflist]) then
    slist = deflist
  end

  if (slist ~= nil) then
    local slp = self.apol.cfg.lists[slist]
    if (not rank and slp) then
      rank = slp.def_rank
    end
  else
    if (lootlistid) then
      slist = lootlistid
      if (not rank) then
        rank = self.apol.cfg.lists[lootlistid].def_rank
      end
    end
  end

  --
  -- Neither the item nor the list supplied a rank, so fall back to no rank filtering. A config that does not filter by guild
  -- rank at all takes none either, whatever a list or an item is still carrying from when it did: the bid check refuses to
  -- apply one, and a disabled dropdown naming a rank reads as a filter that is being applied.
  --
  rank = (rank and self.apol.cfg:RankFiltering()) and rank or 0

  -- The strict filters stay as they were left, unless the item goes to another list, whose own they then become.
  local sarmour = qf.lootrules.strictarmour:GetChecked()
  local srole = qf.lootrules.strictrole:GetChecked()

  if (slist and slist ~= lootlistid) then
    local slp = self.apol.cfg.lists[slist]

    sarmour = slp.strictcfilter and true or false
    srole = slp.strictrfilter and true or false
  end

  if (not cf) then
    if (sarmour) then
      cf = loot.strict
    else
      cf = loot.relaxed
    end
  end

  --
  -- We start out by enabling the loot control buttons here. However, SelectLootItem may, in its ML-specific portion, disable
  -- them if it switches to the autoassign panel for example. We also start out with the main loot frame, which again can be
  -- switched out by SelectLootItem.
  --
  select_alf(ALF_LOOT)

  if (slist) then
    lootrules_setenabled(self, true)
    lootbid_setenabled(true)

    self:SelectLootItem(idx, cf, role, slist, rank, sarmour, srole)
    self.apol:CSendAM(self.apol.currentid, "LISEL", "ALERT", idx, cf, role, slist, rank, sarmour, srole)
    check_missing_members(self)
  else
    -- Nothing names a list to run the bid on, and saying nothing would look like the click did not register.
    self.apol:info(L["there is no roll list for %s. Select a roll list first."], self.raid.bossloot[idx].ilink)
  end
end

local function llist_newitem(objp, num)
  local bname = "KonferBLListButton" .. tostring(num)
  local rf = MakeFrame("Button", bname, objp.content)
  local nfn = "GameFontNormalSmallLeft"

  rf:SetWidth(270)
  rf:SetHeight(16)
  KUI:RowHighlight(rf)

  local text = rf:CreateFontString(nil, "ARTWORK", nfn)
  text:ClearAllPoints()
  text:SetPoint("TOPLEFT", rf, "TOPLEFT", 8, -2)
  text:SetPoint("BOTTOMRIGHT", rf, "BOTTOMRIGHT", -8, 2)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("MIDDLE")
  rf.text = text

  --
  -- The tooltip is shown to the master looter when the config says so, to any other admin always, and to a raider who is no
  -- admin as they said on the Options page (konfer.chardb.nolootips). Holding Shift turns that round, showing it where it
  -- would not be and hiding it where it would. It is worked out again as Shift goes up or down while the pointer is on the row.
  --
  local function loot_tip(this)
    local cfg = konfer.apol.cfg
    local want = true

    if (konfer:AmIML()) then
      want = cfg.settings.tooltips
    elseif (not cfg:MyStatus()) then
      want = not konfer.chardb.nolootips
    end

    if (IsShiftKeyDown()) then
      want = not want
    end

    if (not want) then
      if (GameTooltip:IsOwned(this)) then
        GameTooltip:Hide()
      end
    else
      local ilink = konfer.raid.bossloot[this:GetID()].ilink
      GameTooltip:SetOwner(this, "ANCHOR_NONE")
      GameTooltip:SetHyperlink(ilink)
      GameTooltip:Show()

      --
      -- Beside the Loot panel, its top level with the top of the word Loot in the panel's title: against the panel's right
      -- side where the screen has room for it, and otherwise against its left. The word gives the height and the panel the
      -- side, so the tooltip is hung from the word and moved out to the panel's edge. Only once it is shown is it the width it
      -- will be. Everything is measured on screen and turned into the tooltip's own units at the end.
      --
      -- The game hangs what is equipped beside it, in the shopping tooltips, while the link is being set, on whichever side
      -- of the tooltip has more of the screen, and that is back over the panel when the tooltip is on its left. So the room
      -- asked for counts them too, and they are then hung again on the side the tooltip went, the item nearest the panel and
      -- what is equipped further out, as the game does everywhere else.
      --
      local win = qf.lootpanel
      local plate = qf.lootpanel.titletext or qf.lootpanel
      local ws, ps, ts = win:GetEffectiveScale(), plate:GetEffectiveScale(), GameTooltip:GetEffectiveScale()
      local need = GameTooltip:GetWidth() * ts
      local shown = {}

      for _, st in ipairs({ _G.ShoppingTooltip1, _G.ShoppingTooltip2 }) do
        if (st and st:IsShown()) then
          need = need + st:GetWidth() * st:GetEffectiveScale()
          tinsert(shown, st)
        end
      end

      local fits = win:GetRight() * ws + need <= UIParent:GetRight() * UIParent:GetEffectiveScale()
      local near, far = "TOPLEFT", "TOPRIGHT"

      GameTooltip:ClearAllPoints()

      if (fits) then
        GameTooltip:SetPoint("TOPLEFT", plate, "TOPRIGHT", (win:GetRight() * ws - plate:GetRight() * ps) / ts, 0)
      else
        GameTooltip:SetPoint("TOPRIGHT", plate, "TOPLEFT", (win:GetLeft() * ws - plate:GetLeft() * ps) / ts, 0)
        near, far = "TOPRIGHT", "TOPLEFT"
      end

      local prev = GameTooltip

      for i, st in ipairs(shown) do
        st:ClearAllPoints()
        st:SetPoint(near, prev, far, 0, (i == 1) and -10 or 0)
        prev = st
      end
    end
  end

  -- Hooked rather than set, since the row's hover mark (KUI:RowHighlight above) uses them too.
  rf:HookScript("OnEnter", function(this, evt, ...)
    this:RegisterEvent("MODIFIER_STATE_CHANGED")
    loot_tip(this)
  end)
  rf:SetScript("OnEvent", function(this, evt, ...)
    loot_tip(this)
  end)
  rf:HookScript("OnLeave", function(this, evt, ...)
    this:UnregisterEvent("MODIFIER_STATE_CHANGED")
    GameTooltip:Hide()
  end)

  rf.SetText = function(self, txt)
    self.text:SetText(txt)
  end

  rf:SetScript("OnClick", function(this) lloot_on_click(konfer, this) end)

  return rf
end

local function llist_setitem(objp, idx, slot, btn)
  local loot = konfer.raid.bossloot[idx]
  local price = konfer:AmIML() and konfer:LootPrice(loot.ilink) or loot.price

  btn:SetText(white(price and (price .. " " .. loot.ilink) or loot.ilink))
  btn:SetID(idx)
  btn:Show()
end

local function llist_selectitem(objp, idx, slot, btn, onoff)
  local onoff = onoff or false

  if (not onoff and not redrawing_loot) then
    lootrules_setenabled(konfer, false)
    lootbid_setenabled(false)
    lootrules_empty()
  end
end

--
-- Row IX of the list of bidders: in the policy's standing column their standing, or where the bid takes an amount what they
-- bid, which is all that matters in an auction, their name, the kind of bid where the config takes more than the one kind,
-- and their roles. A raider shows the standing and the amount the master looter sent, whatever its own copy of the list
-- says, and a uid it holds no name for as the uid.
--
local function bidlist_row(self, btn, ix)
  local b = bidders[ix]
  local nm, cls = self.apol.cfg:UserNameClass(b.uid)
  local colw, font = konfer:StandingColumn(self.apol)
  local kind = (#bid_kinds(self.apol.cfg) > 1) and KIND_BY_CODE[b.kind or "M"]
  local shown = openamounts and b.amount or b.standing

  btn.pos:SetFontObject(font)
  btn.pos:SetWidth(colw)
  btn.pos:SetText("[" .. tostring(shown or "?") .. "]")
  btn.kind:SetText(kind and ("[" .. kind.name .. "]") or "")
  konfer:SetRoleIcons(btn.msrole, btn.osrole, self.apol.cfg, b.uid)

  return nm and shortaclass(nm, cls) or b.uid
end

--
-- A bidder clicked in the list of bidders is selected in Candidates as well, so that Force bid acts on the one clicked.
-- Only a click does it: the list reselecting its row as it is drawn again leaves Candidates as the master looter left it.
--
local function select_candidate(uid)
  if (not uid or not members or not qf.members) then
    return
  end

  for k, v in ipairs(members) do
    if (v.id == uid) then
      qf.members:SetSelected(k, true, true)
      return
    end
  end
end

local function blist_selectitem(objp, idx, slot, btn, onoff)
  local onoff = onoff or false

  if (onoff and bidders and bidders[idx]) then
    selectedbidder = idx
    selectedbiduid = bidders[idx].uid
  else
    onoff = false
    selectedbidder = nil
    selectedbiduid = nil
  end

  qf.bidders.forceret:SetEnabled(onoff)
end

--
-- The stored record an edit buffer IINFO says, which is what saving the item editor writes and sends. A field at its
-- nothing value is left out. An ignored item keeps the rest of its instructions: ignoring it puts them out of use rather
-- than out of existence, so that unignoring it later finds them where they were, and everything that acts on them asks
-- about Ignore first.
--
local function item_record(iinfo)
  local rec = { ilink = iinfo.ilink, ignore = iinfo.ignore and true or nil }
  local cs = {}
  local ns = 0

  for k,v in pairs(K.IndexClass) do
    if (iinfo.cfilter and iinfo.cfilter[k]) then
      cs[k] = "1"
      ns = ns + 1
    else
      cs[k] = "0"
    end
  end

  if (ns > 0) then
    rec.cfilter = tconcat(cs)
  end

  if (iinfo.role and iinfo.role ~= 0) then
    rec.role = iinfo.role
  end

  if (iinfo.list and iinfo.list ~= "" and iinfo.list ~= "0") then
    rec.list = iinfo.list
  end

  if (iinfo.rank) then
    rec.rank = iinfo.rank
  end

  if (iinfo.nextdrop and iinfo.nextuser and iinfo.nextuser ~= "" and iinfo.nextuser ~= 0) then
    rec.user = iinfo.nextuser
    if (iinfo.awardlist and iinfo.awardlist ~= "0") then
      rec.awardlist = iinfo.awardlist
    end
    if (iinfo.autodel) then
      rec.del = true
    end
  end

  if (iinfo.autoassign and iinfo.autoassign ~= konfer.AUTOASSIGN_NOBODY) then
    rec.autoassign = iinfo.autoassign
  end

  if (iinfo.ignorequal) then
    rec.ignorequal = true
  end

  -- What the config's policy keeps on the item for itself, which the platform stores and sends and never reads.
  if (iinfo.pdata ~= nil) then
    rec.pdata = iinfo.pdata
  end

  return rec
end

--
-- Item ITEMID as it is stored, in the form of an edit buffer.
--
-- konfer.iitems is the one thing here that really is the mod's: it is what Konfer knows about WoW's items rather than anything about a config.
--
local function stored_iinfo(itemid)
  local pp = konfer.apol
  local ii = itemid and pp and pp.cfg and pp.cfg.items[itemid]

  if (not ii) then
    return nil
  end

  local dcf = ""
  local iinfo = { ilink = ii.ilink }

  if (konfer.iitems[itemid] and konfer.iitems[itemid].cfilter) then
    dcf = konfer.iitems[itemid].cfilter
  end

  iinfo.cfilter = {}

  local ics = ii.cfilter or dcf

  for k,v in pairs(K.IndexClass) do
    iinfo.cfilter[k] = (strsub(ics, k, k) == "1")
  end

  iinfo.ignore = ii.ignore or false
  iinfo.ignorequal = ii.ignorequal or false
  iinfo.list = ii.list or "0"
  iinfo.role = ii.role or 0
  iinfo.rank = ii.rank or 0
  iinfo.nextuser = ii.user or nil
  iinfo.nextdrop = iinfo.nextuser ~= nil
  iinfo.autodel = ii.del or false
  iinfo.awardlist = ii.awardlist or "0"
  iinfo.autoassign = ii.autoassign or konfer.AUTOASSIGN_NOBODY
  iinfo.pdata = ii.pdata

  return iinfo
end

--
-- What is stored for field KEY of the item the editor's changes are to, which is the item selected when they were made.
--
local function item_saved(key)
  local iinfo = stored_iinfo(qf.itempending and qf.itempending.picked)

  if (not iinfo) then
    return nil
  end

  return item_value(key, iinfo[key])
end

--
-- Fill the edit buffer with the selected item as it stands on screen, unsaved changes included. Everything the item editor
-- does happens against this buffer, and saving the tab is what writes it back.
--
local function setup_iinfo(self)
  local iinfo = stored_iinfo(qf.selitemid)

  if (not iinfo) then
    return
  end

  for _, f in ipairs(ITEM_FIELDS) do
    if (qf.itempending:Has(f)) then
      iinfo[f] = qf.itempending:Value(f)
    end
  end

  qf.iinfo = iinfo
end

local function ilist_setitem(objp, idx, slot, btn)
  btn:SetText(qf.sorteditems[idx].link)
  btn:SetID(idx)
  btn:Show()
end

--
-- Item instructions and the policy's own panel on the item editor read as disabled, their titles dimmed, while no item is selected.
--
local function sync_item_panels()
  local hasitem = qf.selitemid ~= nil

  if (qf.iteminstpanel) then
    qf.iteminstpanel:SetEnabled(hasitem)
  end
  if (qf.policyitemspanel) then
    qf.policyitemspanel:SetEnabled(hasitem)
  end
end

--
-- The History tab's buttons clear, export or broadcast the loot history, so they are disabled while the list has nothing in
-- it. Everybody keeps and trims their own history, so Clear is for all. Undo is the admins' and Broadcast the master
-- looter's, lit only once konfer.HISTORY_BCAST_GAP has passed since the last (cfg.histsent), a timer lighting it again then.
-- The second row closes up around whichever of its buttons are hidden and stays centred.
--
local function sync_history_buttons()
  local any = (qf.histlist.itemcount or 0) > 0
  local pp = konfer.apol
  local cfg = pp and pp.cfg
  local wait = cfg and ((cfg.histsent or 0) + konfer.HISTORY_BCAST_GAP - K.time()) or 0

  for _, b in ipairs(qf.histbuttons) do
    b:SetEnabled(any)
  end

  qf.undobutton:SetShown(konfer:PolicyAdmin(pp) and true or false)
  qf.histbcast:SetShown((cfg ~= nil and konfer:AmIML()) and true or false)
  qf.histbcast:SetEnabled(any and wait <= 0)

  if (wait > 0 and not qf.histbcast.waiting) then
    qf.histbcast.waiting = true
    K:ScheduleTimer(function()
      qf.histbcast.waiting = nil
      sync_history_buttons()
    end, wait)
  end

  local x = 0

  for _, b in ipairs(qf.histrow2.buttons) do
    if (b:IsShown()) then
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", qf.histrow2, "TOPLEFT", x, 0)
      x = x + b:GetWidth() + KUI.WIDGET_GAP
    end
  end

  qf.histrow2:SetWidth(math.max(x - KUI.WIDGET_GAP, 1))
end

--
-- Tell the policy's own panel on the item editor about the item being edited, if it has a panel: the selected item and
-- its edit buffer, or nil for both with nothing selected. Called whenever anything the policy's options depend on changes,
-- which is the selection, the buffer being reset under them, and the choice of lists. The selection is also what the
-- editor's panels are dimmed by, so they are brought into line here as well.
--
--
-- Who the next drop of the item may go to without a roll: -Nobody-, which is "" and means it is rolled for as usual, then
-- everybody in the config by name. The users change while the window is open, so the choice is made again whenever the
-- menu opens and whenever the item editor is refreshed, a dropdown only being able to show a value it offers.
--
local function nextuser_items()
  local cfg = konfer.apol and konfer.apol.cfg
  local items = { { text = K.NOBODY_STR, value = "" } }

  if (not cfg) then
    return items
  end

  local names = {}

  for k in pairs(cfg.uids) do
    tinsert(names, { text = shortaclass(cfg:UserNameClass(k)), value = k })
  end

  tsort(names, function(a, b)
    return strlower(cfg:UserName(a.value) or "") < strlower(cfg:UserName(b.value) or "")
  end)

  for _, v in ipairs(names) do
    tinsert(items, v)
  end

  return items
end

--
-- Put the item's instructions about who gets it on screen: the list a roll for it is on, who the next drop goes to, and,
-- only while that is somebody, whether the item then leaves the item list and the list the award is made on. The choices
-- of list and of person are made afresh every time, the lists and the users being able to change under the editor, and the
-- award list says what an award is in the active policy's words. Nothing here is an edit, so no widget throws.
--
local function show_nextdrop()
  local io = qf.itemopts
  local pp = konfer.apol

  if (not io or not io.speclist or not pp) then
    return
  end

  local iinfo = qf.selitemid and qf.iinfo or nil
  local llist = (pp.cfg and pp.sortedlists) and pp.cfg:ListChoices() or KUI.emptydropdown
  local nd = iinfo and iinfo.nextdrop and true or false

  io.awardlist.label:SetText(pp:Str("AWARD_ITEMLIST"))
  io.speclist:UpdateItems(llist)
  io.awardlist:UpdateItems(llist)
  io.nextuser:UpdateItems(nextuser_items())

  io.speclist:SetValue(iinfo and iinfo.list or "0", true)
  io.nextuser:SetValue((nd and iinfo.nextuser) or "", true)
  io.autodel:SetChecked(nd and iinfo.autodel and true or false, true)
  io.awardlist:SetValue(nd and iinfo.awardlist or "0", true)
end

local function item_selection()
  local pp = konfer.apol
  local ip = pp.ItemsPage

  sync_item_panels()
  show_nextdrop()

  if (ip and ip.ItemSelection and pp.itemsframe) then
    local iinfo = qf.selitemid and qf.iinfo or nil

    konfer:PolicyHook(pp, "ItemsPage.ItemSelection", nil, ip.ItemSelection, pp.itemsframe, pp.currentid, qf.selitemid, iinfo)
  end
end

local function enable_uvalues(io, en)
  local pp = konfer.apol
  local en = en or false

  classes_setenabled(io, en)
  io.role:SetEnabled(en)
  io.defrank:SetEnabled(en and pp and pp.cfg:RankFiltering())

  -- What hangs off the next drop means something only while it goes to somebody.
  local nd = en and qf.iinfo and qf.iinfo.nextdrop and true or false

  io.speclist:SetEnabled(en)
  io.nextuser:SetEnabled(en)
  io.autodel:SetEnabled(nd)
  io.awardlist:SetEnabled(nd)
end

--
-- Put the selected item's instructions on screen, unsaved changes included. Nothing here is an edit, so no widget throws.
-- An item assigned to somebody without a roll, or ignored, has nothing else here to say about who gets it, so those
-- options are out of reach while it is.
--
local function show_item()
  local io = qf.itemopts

  setup_iinfo(konfer)

  local iinfo = qf.iinfo
  local auto = iinfo.autoassign ~= konfer.AUTOASSIGN_NOBODY

  io.ignore:SetChecked(iinfo.ignore, true)
  io.autoassign:SetValue(iinfo.autoassign, true)
  io.ignorequal:SetChecked(iinfo.ignorequal, true)
  classes_cfilter(io, iinfo.cfilter)
  io.role:SetValue(iinfo.role, true)
  io.defrank:SetValue(iinfo.rank or 0, true)

  io.ignorequal:SetEnabled(not iinfo.ignore and not auto)
  io.autoassign:SetEnabled(not iinfo.ignore)
  enable_uvalues(io, not iinfo.ignore and not auto)
end

--
-- Every widget in the item instructions lit or dark. Dark because no item is selected, each shows nothing as well: a box
-- unticked, a choice with nothing chosen. What they show is the selected item's, and with none they have nothing to say.
-- Set without throwing, there being no item for an edit to be written to.
--
-- A dropdown and a checkbox are known by the SetValue and SetChecked KoreUI puts on the widget itself, rawget seeing only
-- those and never the game's own methods of the same names, which a slider has.
--
local function itemopts_setenabled(onoff)
  for _, v in pairs({ qf.itemopts:GetChildren() }) do
    if (v.SetEnabled) then
      v:SetEnabled(onoff)
    end

    if (not onoff) then
      if (rawget(v, "SetValue")) then
        v:SetValue(nil, true)
      elseif (rawget(v, "SetChecked")) then
        v:SetChecked(false, true)
      end
    end
  end
end

local function ilist_selectitem(objp, idx, slot, btn, onoff)
  local onoff = onoff or false

  itemopts_setenabled(onoff)

  -- Delete is in a panel of its own under the list rather than among the options, and needs an item selected.
  qf.itemdelbtn:SetEnabled(onoff)

  -- The editor's unsaved changes are to the item selected. See PS.Pick.
  qf.itempending:Pick(onoff and qf.sorteditems[idx] and qf.sorteditems[idx].id or nil)

  if (not onoff) then
    qf.selitemid = nil
    item_selection()
    return
  end

  qf.selitemid = qf.sorteditems[idx].id
  hide_popup()
  show_item()
  item_selection()
end

--
-- The foot of Item instructions RS, from YPOS down: the list a roll for the item is on, who the next drop goes to without a
-- roll, whether it then leaves the item list, and the list the award is made on. Every policy has them, the award list's
-- words being the policy's own. Each writes its edit into the item's edit buffer and says so, and giving the next drop back
-- to -Nobody- forgets everything that hung off it.
--
local function build_nextdrop(self, rs, ypos)
  local arg = {
    x = 0, y = ypos, name = "KonferItemSpecificList", dwidth = 200, mode = "SINGLE", itemheight = 16,
    items = KUI.emptydropdown, enabled = false,
    label = { text = L["Roll on specific list"], pos = "TOP" },
    tooltip = { title = "$$", text = L["TIP060"] },
  }
  rs.speclist = KUI:CreateDropDown(arg, rs)
  rs.speclist:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.iinfo) then
      qf.iinfo.list = newv
      changed(nil, user)
    end
  end)
  ypos = ypos - rs.speclist:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  arg = {
    x = 0, y = ypos, name = "KonferItemNextUser", dwidth = 200, mode = "SINGLE", itemheight = 16,
    items = nextuser_items(), enabled = false,
    label = { text = L["Assign next drop to"], pos = "TOP" },
    tooltip = { title = "$$", text = strfmt(L["TIP062"], K.NOBODY_STR) },
  }
  rs.nextuser = KUI:CreateDropDown(arg, rs)
  rs.nextuser:Catch("OnClick", function(this, evt, _, shown)
    if (shown) then
      this:UpdateItems(nextuser_items())
    end
  end)
  rs.nextuser:Catch("OnValueChanged", function(this, evt, newv, user)
    local ii = qf.iinfo
    local uid = newv or ""

    if (not user or not ii) then
      return
    end

    ii.nextdrop = uid ~= ""
    ii.nextuser = (uid ~= "") and uid or nil

    if (uid == "") then
      ii.autodel = false
      ii.awardlist = "0"
    end

    changed(nil, user)
    show_nextdrop()
    enable_uvalues(rs, not ii.ignore and ii.autoassign == self.AUTOASSIGN_NOBODY)
  end)
  ypos = ypos - rs.nextuser:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  arg = {
    x = 24, y = ypos, label = { text = L["Auto-Remove when assigned"] }, enabled = false,
    tooltip = { title = "$$", text = L["TIP064"] },
  }
  rs.autodel = KUI:CreateCheckBox(arg, rs)
  rs.autodel:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and qf.iinfo) then
      qf.iinfo.autodel = val
      changed(nil, user)
    end
  end)
  ypos = ypos - rs.autodel:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 24, y = ypos, name = "KonferItemAwardList", dwidth = 200, mode = "SINGLE", itemheight = 16,
    items = KUI.emptydropdown, enabled = false,
    label = { text = L["POLICY_AWARD_ITEMLIST"], pos = "TOP" },
    tooltip = { title = "$$", text = L["TIP065"] },
  }
  rs.awardlist = KUI:CreateDropDown(arg, rs)
  rs.awardlist:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.iinfo) then
      qf.iinfo.awardlist = newv
      changed(nil, user)
    end
  end)

  qf.itempending:Watch(rs.speclist, "list")
  qf.itempending:Watch(rs.nextuser, "nextuser", "nextdrop")
  qf.itempending:Watch(rs.autodel, "autodel")
  qf.itempending:Watch(rs.awardlist, "awardlist")

  -- Where the award list ends, which is where the panel does.
  return ypos - rs.awardlist:GetHeight()
end

--
-- A history row's item shows its tooltip under the pointer and goes into chat on a modified click. Clicking a row does not
-- select it: there is nothing to do with a selected history entry.
--
local function hist_newrow(cl, row, num)
  row:HookScript("OnEnter", function(this)
    if (this.whatlink) then
      GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT", 0, 18)
      GameTooltip:SetHyperlink(this.whatlink)
      GameTooltip:Show()
    end
  end)

  row:HookScript("OnLeave", function(this)
    GameTooltip:Hide()
  end)

  row:SetScript("OnClick", function(this)
    if (IsModifiedClick("CHATLINK")) then
      ChatFrameUtil.InsertLink(this.whatlink)
    end
  end)
end

-- The platform's own ways an item leaves, the upper case HOWs of the loot history. A lower case HOW is a policy's, and says itself.
local histhow = {
  ["D"] = L["Disenchanted"],
  ["R"] = L["Won roll"],
  ["M"] = L["Main spec roll"],
  ["O"] = L["Off spec roll"],
  ["T"] = L["Transmog roll"],
  ["V"] = L["Vanity roll"],
  ["B"] = L["BoE assigned to ML"],
  ["L"] = L["Assigned to ML"],
  ["A"] = L["Auto-assigned"],
  ["U"] = L["Undo"],
}

--
-- Who an entry went to, as a name. With COLOUR, in their class colour, as the list shows it, and without, plain, as the list
-- sorts it.
--
-- An entry names a uid and nothing else, an item only ever being given to somebody the config holds. One this config does
-- not know is drawn as the uid itself, which is what UserNameClass does with any uid it cannot place, and says the user list
-- is behind this admin's history rather than quietly naming the wrong person.
--
-- Like the sorts below it, this reads the active policy's config when it runs rather than one captured when the list was built.
local function hist_who(who, colour)
  local name, cls = konfer.apol.cfg:UserNameClass(who)

  return colour and shortaclass(name, cls) or name
end

local function hist_setitem(cl, idx, slot, row)
  local cfp = konfer.apol.cfg
  local when, what, who, how, listid, pdata = unpack(cfp.history[idx])
  local htext, wtext = cfp:HistoryText(what, how, listid, pdata, true)

  -- Displayed in local time.
  row:SetCell(konfer.HIST_WHEN, date("%m-%d %H:%M", when))
  row:SetCell(konfer.HIST_WHAT, wtext)
  row:SetCell(konfer.HIST_WHO, hist_who(who, true))
  row:SetCell(konfer.HIST_HOW, htext)
  row.whatlink = what
  row:Show()
end

--
-- The History tab's list, into PARENT, newest first until a header says otherwise. Every column but When sorts by what it
-- shows rather than by what is stored: What by the item's name rather than its link, which starts with the quality's colour,
-- or by the policy's words where it gave some, and Who and How by the words drawn.
--
-- Those sorts read the active policy's config when they run, not when the list was built. The list is built once and the
-- policy under it changes, so a config captured here would sort tonight's history by last month's names.
--
local function create_history_list(self, parent)
  local function itemname(link)
    return strlower(strmatch(link or "", "%[(.-)%]") or link or "")
  end

  -- A row's How and What in plain words, as whoever owns its HOW says them.
  local function histtext(row)
    return konfer.apol.cfg:HistoryText(row[konfer.HIST_WHAT], row[konfer.HIST_HOW], row[konfer.HIST_LIST],
      row[konfer.HIST_PDATA], false)
  end

  local arg = {
    name = "KonferHistoryList",
    sortkey = konfer.HIST_WHEN, descending = true,
    columns = {
      -- Wide enough for the header and its sort arrow, which sits over the right hand end of the button, rather than only
      -- for the stamp below it.
      { key = konfer.HIST_WHEN, text = L["When"], width = 88, sort = true },
      { key = konfer.HIST_WHAT, text = L["What"], width = "fill", sort = function(a, b)
          return itemname(select(2, histtext(a))) < itemname(select(2, histtext(b)))
        end },
      { key = konfer.HIST_WHO, text = L["Who"], width = 88, sort = function(a, b)
          return strlower(hist_who(a[konfer.HIST_WHO]) or "") < strlower(hist_who(b[konfer.HIST_WHO]) or "")
        end },
      { key = konfer.HIST_HOW, text = L["How"], width = 160, sort = function(a, b)
          return strlower(histtext(a)) < strlower(histtext(b))
        end },
    },
    setitem = function(cl, idx, slot, row)
      return hist_setitem(cl, idx, slot, row)
    end,
    newrow = hist_newrow,
  }

  qf.histlist = KUI:CreateColumnList(arg, parent)
  qf.histlist:Catch("OnSort", function()
    self:RefreshHistory()
  end)
end

local function iclass_filter_func(which, evt, val, cls, user)
  if (not user or not qf.iinfo) then
    return
  end

  qf.iinfo.cfilter = qf.iinfo.cfilter or {}
  qf.iinfo.cfilter[cls] = val
  changed(nil, user)
end

local function class_filter_func(which, evt, val, cls, user)
  lootitem.cfilter = lootitem.cfilter or {}
  lootitem.cfilter[cls] = val
  if (konfer:AmIML() and user) then
    konfer.apol:CSendAM(konfer.apol.currentid, "FLTCH", "ALERT", "C", cls, val)
  end

  -- The Candidates are those who meet the Constraints.
  konfer:RefreshLootMembers()
end

--
-- This is what 95% of the mod is all about, the dealing with bids, so I will take a little time here explaining what
-- happens. We can only reach this code if we have a loot item selected. At the time the loot master (LM) starts the loot we
-- assume that the entry conditions for looting have been correctly set (correct roll list, correct armor, role and guild
-- rank filters etc). We create the self.currentbid entry and set the number of bidders to the empty list. We then announce
-- the opening of the bid in raid chat and wait for bids to come in. While a bid is active the ML can change the current roll
-- list (which resets the list of bidders), change the guild rank filter (which doesn't) or the role filter (which does). At
-- some point in time, either when people have bid or no-one is bidding, the ML closes the bid. If there were bidders, the
-- highest person in the list receives the loot. When bids open, the "Open Bid" button changes to "Close Bid" and the
-- "Remove" button changes to "Next List". The "Next List" button will clear any bidders (although why an ML would press it
-- if there were bidders is not clear) and move on to the next list (if there is one). If there is no next list, the option
-- is greyed out. The next list is set in one of two places. First, in the roll list config, there is an option for "Next
-- List after Bid Timeout". If this is set to anything other than -None- and this was the active roll list, move on to the
-- list specified. If -None- was selected in the next list field, the global config option "Try final roll list" if set is
-- used. If none of those are set the "next list" button is greyed out.
--
-- At some point if no bidders have bid on the item the ML can either press the "Close Bid" or "Open Roll" button. If they
-- press "Open Roll" it gives the users an opportunity to roll on the loot. If no-one rolls or if the ML presses "Close Bids"
-- the options set in the config for "When there are no successful bidders" are obeyed. If the item is a BoE item and the
-- option is set, the item is assigned to the ML. If it is not BoE and there are enchanters specified and the enchanters are
-- in the raid and eligible to receive the loot, the item is assigned to that enchanter to be DE'd.
--
--
-- Every bid as it stands, ranked winner first, each { uid, kind, tier, amount }: what a won bid is priced from (Cost).
local function bid_snapshot()
  local out = {}

  for _, b in ipairs(bidders or {}) do
    tinsert(out, { uid = b.uid, kind = b.kind or "M", tier = b.tier or 0, amount = b.amount })
  end

  return out
end

--
-- TIED are the bidders at the top the policy could not tell apart, each carrying the same .tie. A roll among them alone
-- decides it: main spec, those three the only ones whose roll counts, and the winner then has the bid they made, of the kind
-- they made it and for what they bid. A tie in the roll-off is rolled again among the tied, as any roll is. Every bid is
-- kept with the roll for the win to be priced from, the bids themselves being gone once the roll opens.
--
local function start_rolloff(self, tied)
  local cfg = self.apol.cfg
  local ilink = lootitem.loot.ilink
  local timeout = cfg.settings.roll_timeout
  local winners, kinds, names = {}, {}, {}
  local bids = bid_snapshot()

  for _, b in ipairs(tied) do
    winners[b.uid] = true
    kinds[b.uid] = b.kind or "M"
    tinsert(names, K.DisplayName(cfg:UserName(b.uid)))
  end

  self:SendText(strfmt(L["%s: %s are tied for %s. Roll off with /roll."], L["MODTITLE"], tconcat(names, ", "), ilink))

  qf.lootwin.oclbids:SetText(L["End roll"])
  qf.lootwin.oclbids:SetEnabled(true)
  qf.lootwin.orpause:SetText(L["Pause"])
  qf.lootwin.orpause:SetEnabled(true)
  qf.lootwin.remcancel:SetText(K.CANCEL_STR)
  qf.lootwin.remcancel:SetEnabled(true)

  self:StartOpenRoll(ilink, timeout, false, false, false, true)

  lootroll.restrict = winners
  lootroll.rolloff = kinds
  lootroll.bids = bids
  qf.lootroll.SetTieText(winners)

  self.apol:CSendAM(cfg.id, "RROLL", "ALERT", ilink, timeout, winners)
end

local function open_close_bids(self)
  if (rolling) then
    rolling = 1
    lootroll.endtime = GetTime() - 1
    return
  end

  --
  -- The policy's first roll, which the bids button opens under the policy's own name for it (FirstRoll in Policy.lua), or
  -- whatever the policy opens of its own in its place (AssignPage.firstroll.Open), which is all it opens where no first
  -- roll is owed (AssignPage.firstroll.Offers).
  --
  local first = not biditem and self:FirstRoll()

  if (first or (not biditem and self:FirstRollOffers())) then
    local fr = self.apol.AssignPage and self.apol.AssignPage.firstroll

    if (fr and fr.Open) then
      local _, opened = self:PolicyHook(self.apol, "AssignPage.firstroll.Open", false, fr.Open, self.apol.currentid,
        lootitem.loot.ilink)

      if (opened) then
        return
      end
    end

    if (first) then
      open_roll_or_pause(self, true)
    end

    return
  end

  if (biditem) then
    --
    -- Lets see if we had any bidders. If we did, the highest one wins and takes the award. If not we check the config
    -- options for what to do with the item.
    --
    if (qf.bidscroll.itemcount > 0) then
      --
      -- The policy marks bidders it cannot tell apart with the same .tie. When that is the top of the list, nobody has won
      -- yet, and a roll among those tied decides it.
      --
      local top = bidders[1].tie

      if (top ~= nil and bidders[2] and bidders[2].tie == top) then
        local tied = {}

        for _, b in ipairs(bidders) do
          if (b.tie == top) then
            tinsert(tied, b)
          end
        end

        start_rolloff(self, tied)
        return
      end

      --
      -- We have a winning bidder, and the award is to land on the list they won on. The bids close, and what becomes of
      -- the item is THE WIN's. A winner who has left the group since bidding still wins; only handing the item over needs
      -- them here.
      --
      local win = {
        uid = bidders[1].uid, ilink = lootitem.loot.ilink, itemid = lootitem.loot.itemid, slot = lootitem.loot.slot,
        idx = selectedloot, via = "bid", kind = bidders[1].kind, listid = lootlistid, wonon = lootlistid,
        bids = bid_snapshot(),
      }

      self:ResetBidders(true)
      award_win(self, win)
      return
    end

    if (self.apol.cfg:Announces("ann_no_bids")) then
      self:SendText(strfmt(L["%s: no successful bids for %s."], L["MODTITLE"], lootitem.loot.ilink))
    end

    nobody_won(self, false)
  else
    -- We are starting a new bid.
    if (not lootlistid) then
      return
    end

    --
    -- Shift asks for the item's price first, where the policy lets the master looter set one (setprice in Policy.lua). The
    -- amount box is put up for it, and Enter there opens the bids at that price.
    --
    if (IsShiftKeyDown() and self.apol.setprice) then
      qf.myamount.pricing = selectedloot
      qf.myamount:SetText("")
      sync_loot_panels()
      qf.myamount:SetFocus()
      self.apol:info(L["type the price of %s and press Enter."], lootitem.loot.ilink)
      return
    end

    self:StartBids()
  end
end

--
-- The master looter's: bids open on the loot item selected, at PRICE where the master looter set one as they opened (Shift
-- and Open bids), which stands for the item while it is on the loot list in place of what the policy would make it
-- (konfer:BidPrice), and otherwise at the policy's own.
--
function konfer:StartBids(price)
  local lootlist = self.apol.cfg.lists[lootlistid]
  local st = self.apol.cfg.settings
  local timeout = st.bid_timer and tonumber(st.bid_timeout) or 0

  lootitem.loot.bidprice = price

  self:ResetBidders(true)
  self:OpenBid(selectedloot, nil, nil, timeout)

  qf.bidders.forcebid:SetEnabled(memberid ~= nil and true or false)
  qf.lootwin.oclbids:SetText(L["Close bids"])
  qf.lootwin.remcancel:SetText(K.CANCEL_STR)

  -- Timed bids can be paused, with the button that otherwise opens a roll.
  if (timeout > 0) then
    qf.lootwin.orpause:SetText(L["Pause"])
  end

  lootbid_setenabled(true)
  self:RefreshBossLoot(selectedloot)

  local ilink = lootitem.loot.ilink
  local cost = self:LootPrice(ilink)
  local priced = cost and (cost .. " " .. ilink) or ilink

  self.apol:CSendAM(self.apol.currentid, "BIDOP", "ALERT", biditem, timeout, openkinds, openamounts, cost or false)

  if (timeout > 0) then
    self:SendWarning(L["MODTITLE"] .. ": " .. strfmt(L["Bids now open for %s on the %q list, for %d seconds."],
      priced, lootlist.name, timeout))
  else
    self:SendWarning(L["MODTITLE"] .. ": " .. strfmt(L["Bids now open for %s on the %q list."], priced, lootlist.name))
  end

  if (self.apol.cfg:Announces("ann_bid_usage")) then
    self:SendText(strfmt(L["%s: to bid on %s, whisper %s %s. For general help using %s, whisper an admin %s."],
      L["MODTITLE"], ilink, K.DisplayName(K.player.name), self:BidUsage(), L["MODTITLE"], self:WhisperCommand("help")))
  end
end

--
-- The price the master looter set for ILINK as bids opened on it (konfer:StartBids), for POL's config CFGID, nil where none
-- was set. Only the active policy's current config has loot, and only the master looter sets a price.
--
function konfer:BidPrice(pol, cfgid, ilink)
  if (pol ~= self.apol or cfgid ~= pol.currentid or not self.raid.bossloot or not ilink) then
    return nil
  end

  for _, v in ipairs(self.raid.bossloot) do
    if (v.ilink == ilink and v.bidprice) then
      return v.bidprice
    end
  end

  return nil
end

--
-- The countdown on an open bid that closes by itself (see bidclock), TIMEOUT seconds from now. Every client runs it to say
-- how long is left, and the master looter's closes the bids when it runs out, as Close bids would, counting the last five
-- seconds down to the raid where the config says to.
--
function konfer:StartBidClock(timeout)
  self:StopBidClock()

  if (not timeout or timeout <= 0) then
    return
  end

  bidclock = { endtime = GetTime() + timeout, timeout = timeout }

  --
  -- The Bids panel's title is the countdown: held as wide as the panel less 16 each side, clear of the panel's corners, so
  -- that it stands still as its digits change, which asks its customtitle to draw the countdown in it (DrawBidClock).
  --
  if (qf.bidspanel) then
    qf.bidspanel:SetTitleWidth(qf.bidspanel:GetWidth() - 16 - 16)
  end

  bidclock.ticker = K:ScheduleRepeatingTimer(function()
    if (not bidclock or bidclock.paused) then
      return
    end

    local remt = bidclock.endtime - GetTime()

    if (not self:AmIML()) then
      return
    end

    if (remt <= 0) then
      self:StopBidClock()

      if (biditem and not rolling) then
        open_close_bids(self)
      end

      return
    end

    local warnt = math.floor(remt)

    if (warnt < 5 and warnt ~= bidclock.lastwarn) then
      bidclock.lastwarn = warnt

      if (self.apol.cfg.settings.ann_countdown) then
        self:SendText(strfmt(L["%s: bids closing in %d"], L["MODTITLE"], warnt + 1))
      end
    end
  end, 0.25)
end

function konfer:StopBidClock()
  local was = bidclock

  if (was and was.ticker) then
    K:CancelTimer(was.ticker)
  end

  bidclock = nil

  -- The title goes back to measuring itself against its words, which asks it to draw again, and with no clock it draws nothing.
  if (was and qf.bidspanel) then
    qf.bidspanel:SetTitleWidth(nil)
  end
end

--
-- The Bids panel's title while bids are timed, drawn into BOX, the plate's innards (its customtitle): the roll
-- timer's fill, as high as the roll timer's bar and across the middle of the box, running down from green to red with the
-- time left, and the roll timer's spark at its end, and on the plate the time left to a tenth of a second, as the roll
-- timer says it. Answers whether it drew, which it does while the clock runs.
--
-- It is drawn afresh every frame, as the roll timer is, by the box's own OnUpdate, which runs only while the box is shown.
-- The clock's ticker closes the bids and counts the last seconds down to the raid, and draws nothing.
--
function konfer:DrawBidClock(box)
  if (not bidclock) then
    return false
  end

  local remt = math.max(0, bidclock.paused or (bidclock.endtime - GetTime()))

  --
  -- In white, as the roll timer says its time. The plate is held to a width while the clock runs, so saying the time does
  -- not ask for the box to be drawn again.
  --
  qf.bidspanel:SetTitleText(white(strfmt(L["Bids close in %s"], ("%.1f"):format(remt))))

  local FILL_H = 16

  if (not box.fill) then
    box.fill = KUI:CreatePiece(box, "TimerFill", { layer = "ARTWORK", accent = KUI.COLOR_GREEN })
    box.fill:Box():SetPoint("LEFT", box, "LEFT", 0, 0)
    box.fill:Box():SetHeight(FILL_H)
    box.fill:Box():SetWidth(math.max(box:GetWidth(), 0.01))
    box.fill:Layout()

    box.spark = KUI:CreatePiece(box, "TimerSpark", { layer = "ARTWORK", sublevel = 1, accent = KUI.COLOR_WHITE })
    box.spark:Box():SetSize(12, FILL_H + 20)
    box.spark:Layout()

    box:SetScript("OnUpdate", function(this)
      konfer:DrawBidClock(this)
    end)
  end

  local w = box:GetWidth()
  local p = math.min(1, remt / bidclock.timeout)
  local spark = box.spark:Box()

  box.fill:SetAccent({ r = 1 - p, g = p, b = 0 })
  box.fill:Box():SetWidth(math.max(p * w, 0.01))
  spark:ClearAllPoints()
  spark:SetPoint("CENTER", box, "LEFT", p * w, 0)

  return true
end

--
-- A bid has come in while the bids are counting down. On the master looter, one in the config's last bid_extend seconds puts
-- the close back to that far off and tells the raid (XBIDS). Everybody else is told the SECS it now has left. A paused
-- countdown is not near its end, and is left alone.
--
function konfer:ExtendBidClock(secs)
  if (not bidclock or bidclock.paused) then
    return
  end

  local now = GetTime()

  if (secs) then
    bidclock.endtime = now + secs
    bidclock.lastwarn = nil
    return
  end

  local extend = tonumber(self.apol.cfg.settings.bid_extend) or 0

  if (extend > 0 and bidclock.endtime - now < extend) then
    bidclock.endtime = now + extend
    bidclock.lastwarn = nil
    self.apol:CSendAM(self.apol.currentid, "XBIDS", "ALERT", extend)
  end
end

-- Whether the open bid is counting down, paused or not, and whether it is paused.
function konfer:BidClockRunning()
  return bidclock ~= nil
end

function konfer:BidClockPaused()
  return (bidclock and bidclock.paused) and true or false
end

--
-- Pause the countdown, PAUSE true, or resume it, as the roll timer is paused. Paused, it stands still at what was left,
-- nothing closes and a late bid holds nothing open. The master looter, whose button it is, gives a countdown resumed with
-- less than the config's bid_extend left that much, as a roll is given its extension, and tells the raid either way
-- (PBIDS). Everybody else is told, TOLD being the seconds the master looter resumed it with.
--
function konfer:PauseBidClock(pause, told)
  if (not bidclock) then
    return
  end

  local now = GetTime()
  local secs = told

  if (pause) then
    if (not bidclock.paused) then
      bidclock.paused = math.max(0, bidclock.endtime - now)
    end
  elseif (bidclock.paused) then
    secs = secs or math.max(bidclock.paused, tonumber(self.apol.cfg.settings.bid_extend) or 0)
    bidclock.endtime = now + secs
    bidclock.paused = nil
    bidclock.lastwarn = nil
  end

  if (told == nil) then
    self.apol:CSendAM(self.apol.currentid, "PBIDS", "ALERT", pause and true or false, secs or 0)
  end
end

--
-- Tell the other admins what item ITEMID's instructions are now, all of them. An ignored item's travel with it, as they are
-- kept with it (see item_record).
--
function cfgm:SendCHITM(itemid, ii)
  local ignore = ii.ignore or false

  local cfilter = ""
  if (ii.cfilter) then
    cfilter = ii.cfilter
  end

  local role = 0
  if (ii.role and ii.role ~= 0) then
    role = ii.role
  end

  local list = ""
  if (ii.list and ii.list ~= "0") then
    list = ii.list
  end

  local rank = 0
  if (ii.rank) then
    rank = ii.rank
  end

  local user = ""
  if (ii.user) then
    user = ii.user
  end

  local awardlist = false
  if (ii.user and ii.awardlist) then
    awardlist = ii.awardlist
  end

  local delete = false
  if (ii.user and ii.del) then
    delete = true
  end

  local autoassign = konfer.AUTOASSIGN_NOBODY
  if (ii.autoassign) then
    autoassign = ii.autoassign
  end

  local ignorequal = false
  if (ii.ignorequal) then
    ignorequal = true
  end

  -- The policy's own, false for none so that the slot is there either way.
  local pdata = false
  if (ii.pdata ~= nil) then
    pdata = ii.pdata
  end

  self:AdminEvent("CHITM", itemid, ignore, cfilter, role, list, rank, user, awardlist, delete, autoassign, ignorequal, pdata)
end

--
-- The item qualities the exports name, by the number the game gives each, and the colour a link of that quality is written
-- in, for a client that writes a link's quality as a colour rather than as a code.
--
local EXPORT_QUALITIES = {
  { id = "0", v = "poor",      colour = "9d9d9d" },
  { id = "1", v = "common",    colour = "ffffff" },
  { id = "2", v = "uncommon",  colour = "1eff00" },
  { id = "3", v = "rare",      colour = "0070dd" },
  { id = "4", v = "epic",      colour = "a335ee" },
  { id = "5", v = "legendary", colour = "ff8000" },
  { id = "6", v = "artifact",  colour = "e6cc80" },
  { id = "7", v = "heirloom",  colour = "00ccff" },
}

local QUALITY_BY_COLOUR = {}

for k, v in ipairs(EXPORT_QUALITIES) do
  QUALITY_BY_COLOUR[v.colour] = v.id
end

--
-- The quality of the item LINK is of, as the exports number it: from the quality code a link carries on a client that writes
-- one, from its colour otherwise, and from the game for a colour that is no quality's. Common when nothing says.
--
local function link_quality(link)
  local code = strmatch(link, "|cnIQ(%d+):")

  if (code) then
    return code
  end

  local colour = strmatch(link, "|c%x%x(%x%x%x%x%x%x)")
  local known = colour and QUALITY_BY_COLOUR[strlower(colour)]

  if (known) then
    return known
  end

  local _, _, quality = C_Item.GetItemInfo(link)

  return quality and tostring(quality) or "1"
end

-- The name LINK shows, or ITEMID for a link that shows none.
local function link_name(link, itemid)
  return strmatch(link, "|h%[(.-)%]|h") or itemid
end

--
-- The loot history as a JSON document. The whole thing is built as one Lua table and handed to LibJsonLua, so every name in
-- it is quoted and escaped by the encoder rather than by us; an item called Jeeves's Spare Parts or a realm written in
-- Cyrillic is the encoder's problem and not this function's.
--
-- History names a user, an item, a list and a platform way by id and says what each one is once, in its own array, so that
-- a hundred entries naming the same person carry the name once. A class is named by its Kore number as two digits, the
-- unknown class being 00. A row given out on no list has no l. A policy's row carries its own words for How (h) and What (x)
-- as plain text, and its pdata (p) as it was stored.
--
local function make_json_string(self, pp)
  local cfp = pp.cfg
  local classes = { { id = "00", v = "unkclass" } }
  local ulist = {}
  local llist = {}
  local wlist = {}
  local ilist = {}
  local uul = {}
  local lul = {}
  local iil = {}
  local iql = {}
  local ehl = {}

  for k,v in pairs(K.IndexClass) do
    if (v.u) then
      tinsert(classes, { id = strfmt("%02d", k), v = strlower(tostring(v.u)) })
    end
  end

  -- The platform's ways an item leaves, the upper case HOWs.
  for _, id in ipairs({ "D", "R", "M", "O", "T", "V", "B", "A", "U" }) do
    tinsert(wlist, { id = id, n = histhow[id] })
  end

  for k,v in ipairs(EXPORT_QUALITIES) do
    tinsert(iql, { id = v.id, v = v.v })
  end

  --
  -- An entry names a uid, and one this config does not hold is exported under that uid with no name and no class rather
  -- than dropped, so that a row is never silently missing from what was exported.
  --
  for k,v in pairs(cfp.history) do
    local when, what, who, how, listid, pdata = unpack(v)
    local name, cls = pp.cfg:UserNameClass(who)

    if (not uul[who]) then
      uul[who] = true
      tinsert(ulist, { id = who, n = name, c = strfmt("%02d", cls or 0) })
    end

    local itemid = strmatch(what, "item:(%d+)") or "0"
    local iqv = link_quality(what)
    local iname = link_name(what, itemid)

    if (not (iil[itemid])) then
      iil[itemid] = true
      tinsert(ilist, { id = itemid, n = iname, q = iqv })
    end

    -- A list since deleted is still named, by its id, so the row keeps saying which list it was.
    if (listid and not lul[listid]) then
      lul[listid] = true
      tinsert(llist, { id = listid, n = cfp.lists[listid] and cfp.lists[listid].name or "???" })
    end

    local row = { d = K.YMDStamp(when), t = K.HMStamp(when), id = itemid, u = who, w = how, l = listid or nil }

    if (strmatch(how or "", "^%l")) then
      local htext, wtext = cfp:HistoryText(what, how, listid, pdata, false)

      row.h = htext
      row.x = (wtext ~= what) and wtext or nil
      row.p = pdata
    end

    tinsert(ehl, row)
  end

  return JSON.encode({ konfer_history = {
    date = K.YMDStamp(), time = K.HMStamp(), classes = classes, users = ulist,
    quals = iql, items = ilist, lists = llist, ways = wlist, history = ehl,
  } })
end

local function export_history_button(self)
  local pp = konfer.apol

  if (not qf.exphistdlg) then
    local ypos = 0
    local arg = {
      x = "CENTER", y = "MIDDLE",
      name = "KonferExportHistoryDialog",
      title = konfer.apol:WindowTitle(L["Export loot history"]),
      border = true,
      width = 400,
      height = 125,
      canmove = true,
      canresize = false,
      escclose = true,
      blackbg = true,
      okbutton = true,
      cancelbutton = true,
    }
    local ret = KUI:CreateDialogFrame(arg)

    -- No limit on its length, 0 being none: a long history is still the whole history.
    arg = {
      x = 0, y = ypos, len = 0,
      label = { text = L["Export string"], pos = "LEFT" },
      tooltip = { title = "$$", text = L["TIP050"], },
    }
    ret.expstr = KUI:CreateEditBox(arg, ret)
    --
    -- Focus is given where the string is put in, never here: Escape puts the text back through SetText, which lands here,
    -- and taking focus again would stop a second Escape ever reaching the dialog.
    --
    ret.expstr:Catch("OnValueChanged", function(this, evt, newv)
      qf.exphistdlg.copymsg:SetShown(newv ~= "")
    end)
    ypos = ypos - ret.expstr:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = 16, y = ypos, width = 300,
      text = L["Press Ctrl+C to copy the export string"],
    }
    ret.copymsg = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - ret.copymsg:GetHeight() - KUI.WIDGET_GAP

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    ret:Catch("OnHide", function(this, evt)
      qf.mainwin:Show()
    end)

    qf.exphistdlg = ret
  end

  qf.mainwin:Hide()
  qf.exphistdlg:SetTitleText(konfer.apol:WindowTitle(L["Export loot history"]))
  qf.exphistdlg:Show()
  local eb = qf.exphistdlg.expstr
  eb:SetText(make_json_string(self, pp))
  eb:SetFocus()
  eb:HighlightText()
  eb:SetCursorPosition(0)
end

local function undo_button(self)
  local pp = konfer.apol
  if (not qf.undodlg) then
    local ypos = 0
    local arg = {
      x = "CENTER", y = "MIDDLE",
      name = "KonferUndoDialog",
      title = konfer.apol:WindowTitle(L["Undo"]),
      border = true,
      width = 420,
      height = 160,
      canmove = true,
      canresize = false,
      escclose = true,
      blackbg = true,
      okbutton = true,
      cancelbutton = true,
    }
    local ret = KUI:CreateDialogFrame(arg)

    --
    -- Every registered policy calls an award something different, the dialog is built once, and what is below this label is
    -- placed by how tall it came out. So it is measured against the longest wording any policy has, and the wording of
    -- whichever policy made the award is set on each open. Sized for the worst case, nothing below it can ever be walked on
    -- by a longer sentence than the one that happened to be up when the dialog was made.
    --
    local longest = pp:Str("AWARD_UNDO")

    for k, v in pairs(konfer.policies) do
      local words = v:Str("AWARD_UNDO")

      if (strlen(words) > strlen(longest)) then
        longest = words
      end
    end

    arg = {
      x = 0, y = ypos, text = longest,
      autosize = true, font = "GameFontNormal", width = 400,
    }
    ret.str1 = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - ret.str1:GetHeight() - KUI.WIDGET_GAP
    local sypos = ypos

    --
    -- Two columns of one table: a caption and the value beside it. The value boxes are bordered and so the taller of each
    -- pair, which makes them the row, and both columns walk down by the same step or the rows come apart.
    --
    arg = {
      x = 70, y = ypos, width = 300, border = true, autosize = false,
      justifyh = "LEFT", height = 20,
    }
    ret.user = KUI:CreateStringLabel(arg, ret)
    local rowstep = ret.user:GetHeight() + KUI.WIDGET_GAP

    ypos = ypos - rowstep
    arg.y = ypos
    ret.list = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - rowstep
    arg.y = ypos
    ret.item = KUI:CreateStringLabel(arg, ret)

    ypos = sypos
    arg = {
      x = 0, y = ypos, width = 64, autosize = false, justifyh = "RIGHT",
      font = "GameFontNormal", text = L["User"], height = ret.user:GetHeight(),
    }
    ret.str2 = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - rowstep
    arg.y = ypos
    arg.text = L["List"]
    ret.str3 = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - rowstep
    arg.y = ypos
    arg.text = L["Item"]
    ret.str4 = KUI:CreateStringLabel(arg, ret)

    ret.OnAccept = function(this)
      qf.undodlg:Hide()

      local urec = self:PopUndo()

      if (self:UndoCount() < 1) then
        qf.undobutton:SetEnabled(false)
      end
      -- An undo the policy could not finish goes back on the stack with what is left of it, to be tried again.
      if (not self:Config(urec.cfgid):UndoAward(urec.uid, urec.ilink, urec.moves, false)) then
        self:PushUndo(urec)
        qf.undobutton:SetEnabled(true)
      end
    end

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    ret:Catch("OnHide", function(this, evt)
      qf.mainwin:Show()
    end)

    qf.undodlg = ret
  end

  --
  -- An award on a list that has since been deleted cannot be put back, so it is dropped rather than offered.
  --
  local function undoable(rec)
    local cfp = self:Config(rec.cfgid)

    if (not cfp) then
      return false
    end

    for k, v in ipairs(rec.moves) do
      if (not cfp.lists[v.listid]) then
        return false
      end
    end

    return true
  end

  local ui = self:PeekUndo()

  while (ui and not undoable(ui)) do
    self:PopUndo()
    ui = self:PeekUndo()
  end

  if (not ui) then
    qf.undobutton:SetEnabled(false)
    return
  end

  --
  -- An award is put back under the wording of the policy that made it, which is the one governing the config it was made
  -- against and not necessarily the policy on screen. Set on every open rather than when the dialog was built, because the
  -- dialog is built once and outlives any number of switches, and a suicide is not a deduction.
  --
  local cfp = self:Config(ui.cfgid)
  local upol = cfp:GetPolicy()

  qf.mainwin:Hide()
  qf.undodlg:SetTitleText(upol:WindowTitle(L["Undo"]))
  qf.undodlg.str1:SetText(upol:Str("AWARD_UNDO"))
  qf.undodlg:Show()

  qf.undodlg.user:SetText(aclass(cfp:UserNameClass(ui.uid)))
  qf.undodlg.list:SetText(cfp.lists[ui.moves[1].listid].name)
  qf.undodlg.item:SetText(ui.ilink or "")
end

--
-- The lists on the Assign loot tab are the lists the loot engine can run a bid on, which are the active policy's, that
-- being the policy the engine runs.
--
-- No active policy, or one with no config, has no lists to show. Both are ordinary states for a mod the user has not set up
-- yet, not something to fall over.
--
local function refresh_loot_lists(self)
  local pp = konfer.apol
  local oldlist = lootlistid
  local oldidx = nil

  if (not pp or not pp.cfg or not pp.sortedlists) then
    qf.lists.itemcount = 0
    qf.lists:UpdateList()
    return
  end

  for k,v in ipairs(pp.sortedlists) do
    if (v.id == oldlist) then
      oldidx = k
    end
  end

  --
  -- With loot up and no list selected, or the one that was gone, the master looter's falls on the config's default list
  -- (def_list), and the raid is told (LLSEL) so that everybody shows the one list. Anybody else waits to be told.
  --
  local deflist = nil

  if (not oldidx and self:AmIML() and self.raid.bossloot) then
    for k, v in ipairs(pp.sortedlists) do
      if (v.id == pp.cfg.settings.def_list) then
        oldidx = k
        deflist = v.id
        break
      end
    end
  end

  qf.lists.itemcount = #pp.sortedlists

  refreshing_lists = true
  qf.lists:UpdateList()
  refreshing_lists = false

  --
  -- This also updates the members list. A list that has gone is deselected for real, and takes its bidders with it.
  --
  qf.lists:SetSelected(oldidx, true, true)

  if (deflist) then
    pp:CSendAM(pp.currentid, "LLSEL", "ALERT", deflist, false)
  end
end

local function set_classes_from_filter(filter)
  local filter = filter or K.classfilters.allclasses

  for k,v in pairs(K.IndexClass) do
    local val = false
    if (strsub(filter, k, k) == "1") then
      val = true
    end
    qf.lootrules[v.w]:SetChecked(val)
  end
end

--
-- Force bid, pressed, for the amount typed beside Bid on item where the open bid takes one. A config taking main spec alone
-- has the candidate bid main spec. One taking more asks which, in the same menu a right click on the candidate puts up. A
-- double click, DOUBLE, is main spec without asking: its first click has put the menu up, and the second takes it away again
-- and bids. Where main spec is all there is the first click has already bid it.
--
local function force_bid(self, double)
  local many = #bid_kinds(self.apol.cfg) > 1

  if (double) then
    if (many) then
      if (candmenu) then
        candmenu:Hide()
      end

      local amount = amount_for_bid(self)

      if (amount ~= false) then
        self:NewBidder(memberid, nil, amount)
      end
    end
  elseif (not many) then
    local amount = amount_for_bid(self)

    if (amount ~= false) then
      self:NewBidder(memberid, nil, amount)
    end
  else
    candidate_menu(memberid)
  end
end

--
-- The bid pane of the Bids / rolls panel BB: the list of bidders, the full width of the panel above the foot that holds
-- Bid on item and Retract bid.
--
local function build_bid_pane(self, bb)
  local arg

  bb.bidpane = MakeFrame("Frame", nil, bb)
  bb.bidpane:SetAllPoints(bb)

  bb.sframe = MakeFrame("Frame", nil, bb.bidpane)
  bb.sframe:ClearAllPoints()
  bb.sframe:SetPoint("TOPLEFT", bb, "TOPLEFT", 0, 0)
  bb.sframe:SetPoint("BOTTOMRIGHT", bb, "BOTTOMRIGHT", 0, 24)

  arg = {
    name = "KonferBiddersScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      local rf = KUI.NewItemHelper(objp, num, "KonferBLBidButton", 155, 16, nil, nil, function(this, idx)
          if (not self:AmIML()) then
            return true
          end

          select_candidate(bidders and bidders[idx] and bidders[idx].uid)
        end, nil)

      -- The standing's column is sized for the policy as the row is drawn, and the name stands the same gap past it as
      -- on the Lists page.
      rf.pos = rf:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
      rf.pos:SetJustifyH("LEFT")
      rf.pos:SetJustifyV("MIDDLE")
      rf.pos:SetPoint("TOPLEFT", rf, "TOPLEFT", CLAIM_EDGE, -2)
      rf.pos:SetPoint("BOTTOMLEFT", rf, "BOTTOMLEFT", CLAIM_EDGE, 2)

      claim_row_end(rf, "GameFontNormalSmallLeft")

      rf.text:ClearAllPoints()
      rf.text:SetPoint("TOPLEFT", rf.pos, "TOPRIGHT", 5, 0)
      rf.text:SetPoint("BOTTOMRIGHT", rf.kind, "BOTTOMLEFT", 0 - KUI.WIDGET_GAP, 0)

      return rf
      end,
    setitem = function(objp, idx, slot, btn)
        return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
          return bidlist_row(self, btn, ix)
        end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return blist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  bb.slist = KUI:CreateScrollList(arg, bb.sframe)
  qf.bidscroll = bb.slist
end

function konfer:InitialiseLootUI()
  local arg
  local mainwin = self.mainwin
  local kmt = mainwin:GetPage(self.LOOT_PAGE)

  qf.mainwin = mainwin

  --
  -- The item editor's unsaved changes, to the selected item's instructions, the policy's own among them. Saving writes the
  -- whole item and tells the other admins with one CHITM, however many of its fields were changed. Both exist from the
  -- moment the page does, because a widget handler writes into the buffer and a refresh sets widgets before any item has
  -- been selected.
  --
  qf.iinfo = {}
  qf.itempending = self.mainwin:NewPending({
    page = self.LOOT_PAGE, tab = self.LOOT_ITEMS_TAB,
    saved = item_saved,
    save = function(changes)
      local pp = konfer.apol
      local itemid = qf.itempending.picked
      local iinfo = stored_iinfo(itemid)

      if (not iinfo) then
        return
      end

      for k, v in pairs(changes) do
        iinfo[k] = v
      end

      local rec = item_record(iinfo)

      pp.cfg.items[itemid] = rec
      pp.cfg:SendCHITM(itemid, rec)
    end,
    reload = function()
      konfer:RefreshItemList()
    end,
  })

  kmt.onclick = function(this, main, sub)
    qf.membersearch:SetEnabled(self:AmIML())
  end

  -- First set up the quick access frames we will be using.
  qf.assign = kmt.tabsbyname[self.LOOT_ASSIGN_TAB].content
  qf.itemedit = kmt.tabsbyname[self.LOOT_ITEMS_TAB].content
  qf.history = kmt.tabsbyname[self.LOOT_HISTORY_TAB].content

  --
  -- Loot tab, Loot Assignment page.
  --
  local ypos = 0

  local cf = qf.assign
  local tbf = kmt.topbar
  local ls = cf.vsplit.leftframe
  local rs = cf.vsplit.rightframe

  --
  -- Four rows of lists. A raid rolls on a handful, and the Candidates under it take everything left but the panel of
  -- buttons at the foot.
  --
  arg = {
    inset = 0, height = 4 * 16,
    name = "KonferLootLSplit", topanchor = true,
    toptitle = L["Lists"],
  }
  ls.hsplit = KUI:CreateHSplit(arg, ls)
  qf.lootlistspanel = ls.hsplit.topinset
  qf.lootlistsplit = ls.hsplit

  local tl = ls.hsplit.topframe
  local bl = ls.hsplit.bottomframe

  --
  -- The search box sits inside the Candidates panel, centred under the list, which stops short of the foot to leave it room.
  --
  KUI:UseAsContainer(bl)

  --
  -- The panel at the foot holds one row of buttons, built with the Bids / rolls panel whose bids they act on, and is exactly
  -- as tall as that row and its rings.
  --
  local CAND_BTN_H = 24

  bl.btnpanel = KUI:CreateInset({}, bl)
  bl.btnpanel:ClearAllPoints()
  bl.btnpanel:SetPoint("BOTTOMLEFT", bl, "BOTTOMLEFT", 0, 0)
  bl.btnpanel:SetPoint("BOTTOMRIGHT", bl, "BOTTOMRIGHT", 0, 0)
  bl.btnpanel:SetHeight(CAND_BTN_H + bl.btnpanel.rings.top + bl.btnpanel.rings.bottom)

  local blpanel = KUI:CreateInset({ title = L["Candidates"] }, bl)
  blpanel:ClearAllPoints()
  blpanel:SetPoint("TOPLEFT", bl, "TOPLEFT", 0, 0)
  blpanel:SetPoint("BOTTOMRIGHT", bl.btnpanel, "TOPRIGHT", 0, 0)
  qf.candidatespanel = blpanel
  qf.candbtnpanel = bl.btnpanel

  local clc = blpanel.content

  local tbl = MakeFrame("Frame", nil, clc)
  tbl:ClearAllPoints()
  tbl:SetPoint("TOPLEFT", clc, "TOPLEFT", 0, 0)
  tbl:SetPoint("BOTTOMRIGHT", clc, "BOTTOMRIGHT", 0, 25)

  arg = {
    name = "KonferLootListsScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      return rlist_newitem(objp, num)
    end,
    setitem = rlist_setitem,
    selectitem = function(objp, idx, slot, btn, onoff)
      return rlist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tl.slist = KUI:CreateScrollList(arg, tl)
  qf.lists = tl.slist

  arg = {
    name = "KonferLootMembersScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      return mlist_newitem(objp, num)
    end,
    setitem = mlist_setitem,
    selectitem = function(objp, idx, slot, btn, onoff)
      return mlist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tbl.slist = KUI:CreateScrollList(arg, tbl)
  qf.members = tbl.slist

  arg = {
    x = 0, y = 2, len = 16, font = "ChatFontSmall",
    width = 170, tooltip = { title = L["User search"], text = L["TIP099"] },
  }
  bl.searchbox = KUI:CreateEditBox(arg, clc)
  bl.searchbox:ClearAllPoints()
  bl.searchbox:SetPoint("BOTTOM", clc, "BOTTOM", 0, 0)
  bl.searchbox:SetHeight(20)
  qf.membersearch = bl.searchbox
  bl.searchbox:Catch("OnEnterPressed", function(this, evt, newv, user)
    this:SetText("")
  end)
  bl.searchbox:Catch("OnValueChanged", function(this, evt, newv, user)
    if (not members) then
      return
    end
    -- The first whose name holds what was typed is selected.
    if (user and newv and newv ~= "") then
      local lnv = strlower(newv)
      for k,v in ipairs(members) do
        local tln = strlower(self.apol.cfg:UserName(v.id) or "")
        if (strfind(tln, lnv, 1, true)) then
          qf.members:SetSelected(k, true, true)
          return
        end
      end
    end
  end)

  --
  -- Right-hand side panel which has the loot list, filter controls and current bidders.
  --
  --
  -- The loot list is five rows, the three buttons under it a gap below, and the panel holds exactly the two. Bids / rolls
  -- under it takes what is left, which on a client with more classes is a row of class checkboxes less.
  --
  local LOOTLIST_H = 5 * 16 + 2
  local LOOTBTN_Y = LOOTLIST_H + 5

  arg = {
    inset = 0, height = LOOTBTN_Y + 24 + 1, name = "KonferLootListHSplit",
    topanchor = true, toptitle = L["Loot"],
  }
  rs.hsplit = KUI:CreateHSplit(arg, rs)
  local tr = rs.hsplit.topframe
  local br = rs.hsplit.bottomframe
  qf.lootwin = tr
  qf.lootpanel = rs.hsplit.topinset

  --
  -- The Bids / rolls panel's title draws its own innards while bids are timed, the countdown they are closing to.
  --
  arg = {
    inset = 0, height = 165, name = "KonferLootFilterHSplit",
    topanchor = true, toptitle = L["Constraints"],
    bottomtitle = { text = L["Bids / rolls"], customtitle = function(plate, box)
      return konfer:DrawBidClock(box)
    end },
  }
  br.hsplit = KUI:CreateHSplit(arg, br)
  local bmf = br.hsplit.topframe
  local bb = br.hsplit.bottomframe
  qf.constraintspanel = br.hsplit.topinset
  qf.bidspanel = br.hsplit.bottominset

  --
  -- The loot rules frame doubles as both the loot rules and the "popup" frame when we auto-assign loot to someone. We do
  -- this so that we do not need to hide the main window and the loot master can see who is in the raid and look at the loot
  -- lists etc. So when we have an item that is auto-assigned to a user in the item database or when a user has won a bid and
  -- we are auto-assigning loot, we hide the loot rules window and display the loot assignment window in its place. We need
  -- to be careful when showing the window again however. If the master looter closes the main Konfer window, when they
  -- re-open it, we need the original loot rules window back. They can always assign loot through the traditional Blizzard interface.
  --
  local bm = MakeFrame("Frame", nil, bmf)
  bm:ClearAllPoints()
  bm:SetPoint("TOPLEFT", bmf, "TOPLEFT", KUI.WIDGET_GAP, 0)
  bm:SetPoint("BOTTOMRIGHT", bmf, "BOTTOMRIGHT", 0, 0)

  local alf = MakeFrame("Frame", nil, bmf)
  alf:ClearAllPoints()
  alf:SetPoint("TOPLEFT", bmf, "TOPLEFT", KUI.WIDGET_GAP, 0 - KUI.WIDGET_GAP)
  alf:SetPoint("BOTTOMRIGHT", bmf, "BOTTOMRIGHT", 0, 0)
  alf:Hide()

  local rlf = MakeFrame("Frame", nil, bmf)
  rlf:ClearAllPoints()
  rlf:SetPoint("TOPLEFT", bmf, "TOPLEFT", KUI.WIDGET_GAP, 0 - KUI.WIDGET_GAP)
  rlf:SetPoint("BOTTOMRIGHT", bmf, "BOTTOMRIGHT", 0, 0)
  rlf:Hide()

  qf.lootrules = bm
  qf.autoloot = alf
  qf.lootroll = rlf
  qf.bidders = bb

  --
  -- Populate the auto-assign frame first. Its pretty simple: the item on a line of its own, "Item:" and its link, and the
  -- question under it, both from the panel's left.
  --
  arg = {
    x = 0, y = 0, width = 1, height = 24, autosize = false, font = "GameFontNormal", text = "", justifyh = "LEFT",
  }
  alf.item = KUI:CreateStringLabel(arg, alf)
  alf.item:ClearAllPoints()
  alf.item:SetPoint("TOPLEFT", alf, "TOPLEFT", 4, 0)
  alf.item:SetPoint("TOPRIGHT", alf, "TOPRIGHT", -4, 0)
  alf.item.label:SetPoint("TOPLEFT", alf.item, "TOPLEFT", 0, 0)
  alf.item.label:SetPoint("BOTTOMRIGHT", alf.item, "BOTTOMRIGHT", 0, 0)
  qf.autoassign_item = alf.item

  arg = {
    x = 0, y = 0, width = 1, height = 1, autosize = false,
    color = {r = 1, g = 0, b = 0, a = 1 }, text = "",
    font = "GameFontNormal", justifyv = "TOP",
  }
  alf.str = KUI:CreateStringLabel(arg, alf)
  alf.str:ClearAllPoints()
  alf.str:SetPoint("TOPLEFT", alf, "TOPLEFT", 4, -30)
  alf.str:SetPoint("BOTTOMRIGHT", alf, "BOTTOMRIGHT", -4, 28)
  alf.str.label:SetPoint("TOPLEFT", alf.str, "TOPLEFT", 0, 0)
  alf.str.label:SetPoint("BOTTOMRIGHT", alf.str, "BOTTOMRIGHT", 0, 0)
  qf.autoassign_msg = alf.str

  --
  -- The two buttons stand on the foot of the panel, which is as tall as the constraints it takes the place of, however many
  -- rows of classes those are.
  --
  arg = {
    x = 40, y = 0, text = K.OK_STR,
  }
  alf.ok = KUI:CreateButton(arg, alf)
  alf.ok:ClearAllPoints()
  alf.ok:SetPoint("BOTTOMLEFT", alf, "BOTTOMLEFT", 40, 0)
  alf.ok:Catch("OnClick", function(this, evt, ...)
    confirm_ok(self)
  end)

  arg = {
    x = 160, y = 0, text = K.CANCEL_STR,
  }
  alf.cancel = KUI:CreateButton(arg, alf)
  alf.cancel:ClearAllPoints()
  alf.cancel:SetPoint("BOTTOMLEFT", alf, "BOTTOMLEFT", 160, 0)
  alf.cancel:Catch("OnClick", function(this, evt, ...)
    confirm_cancel(self)
  end)

  --
  -- Next the roll frame, which while a roll is open stands where the constraints were: the timer, and under it Roll and
  -- Retract, together in the middle of the panel. The rolls themselves are in the Bids / rolls list below it. See
  -- build_roll_buttons for the two buttons.
  --
  -- The timer is the kit's status strip with a fill running down inside it as the roll's time runs out, green while there is
  -- plenty left and red as it closes, and the kit's spark riding the fill's leading edge. It is the width of the panel.
  --
  -- ROLL_GAP stands the buttons off the timer.
  local TIMER_H = 30
  local TIMER_INSET = 12
  local ROLL_GAP = 20
  local rollarea = rlf:GetParent()

  rlf.block = MakeFrame("Frame", nil, rlf)
  rlf.block:SetPoint("LEFT", rollarea, "LEFT", 0, 0)
  rlf.block:SetPoint("RIGHT", rollarea, "RIGHT", 0, 0)
  rlf.block:SetHeight(TIMER_H + ROLL_GAP + 24)

  rlf.timerbarframe = MakeFrame("Frame", "KonferLootRollTimerFrame", rlf.block)
  rlf.timerbarframe:ClearAllPoints()
  rlf.timerbarframe:SetPoint("TOPLEFT", rlf.block, "TOPLEFT", 0, 0)
  rlf.timerbarframe:SetPoint("TOPRIGHT", rlf.block, "TOPRIGHT", 0, 0)
  rlf.timerbarframe:SetHeight(TIMER_H)

  rlf.timerstrip = KUI:CreatePiece(rlf.timerbarframe, "StatusStrip", { layer = "BACKGROUND" })
  rlf.timerstrip:SetBox(rlf.timerbarframe, 0, 0, 0, 0, TIMER_H)

  rlf.timerbar = MakeFrame("Frame", nil, rlf.timerbarframe)
  rlf.timerbar:SetHeight(16)
  rlf.timerbar:ClearAllPoints()
  rlf.timerbar:SetPoint("LEFT", rlf.timerbarframe, "LEFT", TIMER_INSET, 0)
  rlf.timerbar:SetPoint("RIGHT", rlf.timerbarframe, "RIGHT", 0 - TIMER_INSET, 0)

  rlf.timerfill = KUI:CreatePiece(rlf.timerbar, "TimerFill", { layer = "ARTWORK", accent = KUI.COLOR_GREEN })
  rlf.timerfill:Box():SetPoint("TOPLEFT", rlf.timerbar, "TOPLEFT", 0, 0)
  rlf.timerfill:Box():SetPoint("BOTTOMLEFT", rlf.timerbar, "BOTTOMLEFT", 0, 0)
  rlf.timerfill:Box():SetWidth(rlf.timerbar:GetWidth())
  rlf.timerfill:Layout()

  rlf.timertext = rlf.timerbar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rlf.timertext:ClearAllPoints()
  rlf.timertext:SetPoint("LEFT", rlf.timerbar, "LEFT", 0, 0)
  rlf.timertext:SetPoint("RIGHT", rlf.timerbar, "RIGHT", 0, 0)
  rlf.timertext:SetHeight(16)
  rlf.timertext:SetTextColor(1,1,1,1)
  rlf.timertext:SetJustifyH("CENTER")
  rlf.timertext:SetJustifyV("MIDDLE")

  rlf.timerspark = KUI:CreatePiece(rlf.timerbar, "TimerSpark", { layer = "OVERLAY", accent = KUI.COLOR_WHITE })
  rlf.timerspark:Box():SetSize(12, 36)
  rlf.timerspark:Box():SetPoint("CENTER", rlf.timerbar, "RIGHT", 0, 0)
  rlf.timerspark:Layout()

  --
  -- Set the timer to PCT of its time left, from 1 when the roll opens to 0 when it closes.
  --
  rlf.SetTimer = function(pct)
    local w = rlf.timerbar:GetWidth()
    local p = math.max(0, math.min(1, pct))
    local spark = rlf.timerspark:Box()

    rlf.timerfill:SetAccent({ r = 1 - p, g = p, b = 0 })
    rlf.timerfill:Box():SetWidth(math.max(p * w, 0.01))
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", rlf.timerbar, "LEFT", p * w, 0)
  end

  --
  -- While a tie is rolled off, the line centred between the title and the timer names who it is against, or for anybody not
  -- in it who it is between, each in their class colour. WINNERS is the tied as RROLL carries them, keyed by uid, and nil
  -- clears the line.
  --
  rlf.tietext = rlf:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  rlf.tietext:SetPoint("TOPLEFT", rollarea, "TOPLEFT", 0, 0)
  rlf.tietext:SetPoint("BOTTOMRIGHT", rlf.timerbarframe, "TOPRIGHT", 0, 0)
  rlf.tietext:SetJustifyH("CENTER")
  rlf.tietext:SetJustifyV("MIDDLE")

  rlf.SetTieText = function(winners)
    local cfg = self.apol.cfg
    local mine = cfg and cfg:MyUid() or ""
    local names = {}
    local said = nil

    for uid in pairs(winners or {}) do
      if (uid ~= mine) then
        local nm, cls = cfg:UserNameClass(uid)

        tinsert(names, { name = nm or uid, text = nm and shortaclass(nm, cls) or uid })
      end
    end

    tsort(names, function(a, b) return a.name < b.name end)

    for i, n in ipairs(names) do
      said = (not said and n.text) or (i == #names and strfmt(L["%s and %s"], said, n.text)) or (said .. ", " .. n.text)
    end

    if (not said) then
      rlf.tietext:SetText("")
    elseif (winners[mine]) then
      rlf.tietext:SetText(strfmt(L["Tie-breaking roll against %s"], said))
    else
      rlf.tietext:SetText(strfmt(L["Tie-breaking roll between %s"], said))
    end
  end

  --
  -- Roll asks which kind, where the roll takes more than main spec, and makes the one chosen. A double click has put the
  -- menu up with its first click, and its second takes it away again and rolls main spec. A first roll is made through the
  -- game, which is what everybody else reads, and a change of kind after it is only said (roll_kind_pressed).
  --
  build_roll_buttons(rlf, function(minr, double)
    self:MyRoll(minr, double)
  end, function()
    RandomRoll(1, 1)
  end)

  rlf.rows[1]:ClearAllPoints()
  rlf.rows[1]:SetPoint("TOP", rlf.timerbarframe, "BOTTOM", 0, 0 - ROLL_GAP)

  rlf.StartRoll = function(sroll)
    qf.lootwin.oclbids:SetText(L["End roll"])
    qf.lootwin.oclbids:SetEnabled(true)
    qf.lootwin.orpause:SetText(L["Pause"])
    qf.lootwin.orpause:SetEnabled(true)
    qf.lootwin.remcancel:SetText(K.CANCEL_STR)
    qf.lootwin.remcancel:SetEnabled(true)

    local st = self.apol.cfg.settings

    self:StartOpenRoll(lootitem.loot.ilink, st.roll_timeout, st.offspec_rolls, st.transmog_rolls, st.vanity_rolls, sroll)
  end

  --
  -- The master looter putting the window away mid-roll pauses it. A raider closing their own window is only closing a window,
  -- the roll being the master looter's.
  --
  local function rlf_onhide()
    if (rolling == 1 and self:AmIML()) then
      open_roll_or_pause(self)
    end
  end

  rlf:SetScript("OnHide", rlf_onhide)

  --
  -- Now populate the actual loot rules frame
  --
  ypos = classes_create(bm, 0, nil, class_filter_func)

  local flw = KUI:WidestString({ L["User role"], L["Guild rank"] })

  bm.role = KU:CreateRoleDropdown("KonferLootRoleFilter", 0, ypos, bm, nil, flw)
  bm.role:SetEnabled(false)
  bm.role:Catch("OnValueChanged", function(this, evt, newv, user)
    if (self:AmIML() and user) then
      self.apol:CSendAM(self.apol.currentid, "FLTCH", "ALERT", "R", newv)
    end
    if (lootitem) then
      lootitem.role = newv
      self:RefreshLootMembers()
    end
  end)
  ypos = ypos - bm.role:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP
  bm.role:SetValue(0)

  arg = {
    x = 0, y = ypos, mode = "SINGLE", itemheight = 16,
    name = "KonferLootRankFilter", dwidth = 150, items = KUI.emptydropdown,
    label = { text = L["Guild rank"], pos = "LEFT", width = flw },
    tooltip = { title = "$$", text = L["TIP051"], },
  }
  bm.rank = KUI:CreateDropDown(arg, bm)
  bm.rank:Catch("OnValueChanged", function (this, evt, newv, user)
    if (self:AmIML() and user) then
      self.apol:CSendAM(self.apol.currentid, "FLTCH", "ALERT", "G", newv)
    end

    if (lootitem) then
      lootitem.rank = newv
      self:RefreshLootMembers()
    end
  end)
  -- Published because the guild rank list is refilled from Konfer.lua.
  konfer.qf.lootrank = bm.rank

  arg = {
    x = 350, y = ypos, width = 16, height = 16, text = "-",
  }
  bm.nextrank = KUI:CreateButton(arg, bm)
  bm.nextrank:ClearAllPoints()
  bm.nextrank:SetPoint("TOPLEFT", bm.rank.button, "TOPRIGHT", 2, -4)
  bm.nextrank:Catch("OnClick", function (this, evt, ...)
    if (not self:AmIML() or not lootitem or not lootitem.rank) then
      return
    end

    --
    -- Widening the filter goes to the next rank standing strictly lower in the config's order rather than to the next rank
    -- along, so that every press lets somebody new in. Ranks sharing this one's place are admitted already, and stepping
    -- onto one of those would read as a button that does nothing.
    --
    local wider = self.apol.cfg:NextRank(lootitem.rank)

    if (wider) then
      lootitem.rank = wider
      bm.rank:SetValue(wider)
      self.apol:CSendAM(self.apol.currentid, "FLTCH", "ALERT", "G", wider)
    end
  end)
  ypos = ypos - bm.rank:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Strict class armor"] },
    tooltip = { title = "$$", text = L["TIP039"], },
  }
  bm.strictarmour = KUI:CreateCheckBox(arg, bm)
  bm.strictarmour:Catch("OnValueChanged", function(this, evt, val, user)
    if (self:AmIML() and user) then
      local filter = lootitem and (val and lootitem.loot.strict or lootitem.loot.relaxed)

      if (filter) then
        set_classes_from_filter(filter)
      end
      self.apol:CSendAM(self.apol.currentid, "FLTCH", "ALERT", "A", val, filter)
    end
  end)

  arg = {
    x = 150, y = ypos, label = { text = L["Strict role filter"] },
    tooltip = { title = "$$", text = L["TIP040"], },
  }
  bm.strictrole = KUI:CreateCheckBox(arg, bm)
  bm.strictrole:Catch("OnValueChanged", function(this, evt, val, user)
    if (self:AmIML() and user) then
      self.apol:CSendAM(self.apol.currentid, "FLTCH", "ALERT", "L", val)
    end
    if (lootitem) then
      self:RefreshLootMembers()
    end
  end)
  ypos = ypos - bm.strictrole:GetHeight() - KUI.WIDGET_GAP

  --
  -- Constraints is exactly as tall as the constraints and the rings round it, and YPOS has a gap after the last of them.
  -- How many rows the classes take is the client's, so it is measured, not declared.
  --
  local cop = br.hsplit.topinset
  qf.constraintspane = cop
  qf.constraintsh = 0 - ypos + cop.rings.top + cop.rings.bottom
  cop:SetHeight(qf.constraintsh)

  --
  -- The guild rank row, which a policy can hide (AssignPage.hide), and the strict filters under it, which ShowLootPolicyUI
  -- moves up into its room. Where each strict filter was built is read back from its own TOP anchor, as the item editor's
  -- rows are.
  --
  qf.rankrow = {
    widgets = { bm.rank, bm.nextrank },
    step = bm.rank:GetHeight() + KUI.WIDGET_GAP + KUI.DROPDOWN_ADD_GAP,
    under = {},
  }

  for _, w in ipairs({ bm.strictarmour, bm.strictrole }) do
    for i = 1, w:GetNumPoints() do
      local point, rel, _, _, y = w:GetPoint(i)

      if (point == "TOP") then
        tinsert(qf.rankrow.under, { widget = w, rel = rel, y = y })
      end
    end
  end

  --
  -- Set up the buttons for controlling loot, as well as the scrolling list of loot itself. First create the frame that will
  -- contain the scrolling list of loot, as it occupies a full frame. Next to that frame we will have the loot control buttons.
  --
  tr.sframe = MakeFrame("Frame", nil, tr)
  tr.sframe:ClearAllPoints()
  tr.sframe:SetPoint("TOPLEFT", tr, "TOPLEFT", 0, 0)
  tr.sframe:SetPoint("TOPRIGHT", tr, "TOPRIGHT", 0, 0)
  tr.sframe:SetHeight(LOOTLIST_H)

  arg = {
    name = "KonferBossLootScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      return llist_newitem(objp, num)
    end,
    setitem = llist_setitem,
    selectitem = function(objp, idx, slot, btn, onoff)
      return llist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tr.slist = KUI:CreateScrollList(arg, tr.sframe)
  qf.lootscroll = tr.slist
  -- Published because Comms.lua fills it as loot arrives.
  konfer.qf.lootscroll = tr.slist

  ypos = 0 - LOOTBTN_Y

  local LOOTBTN_W = 85

  arg = {
    x = 0, y = ypos, width = LOOTBTN_W, text = L["Open bids"],
    tooltip = { title = L["TIP052.0"], text = L["TIP052"], },
    enabled = false,
  }
  tr.oclbids = KUI:CreateButton(arg, tr)
  tr.oclbids:Catch("OnClick", function(this, evt, ...)
    open_close_bids(self)
  end)

  arg = {
    x = 100, y = ypos, width = LOOTBTN_W, text = L["Open roll"],
    tooltip = { title = L["TIP053.0"], text = L["TIP053"], },
    enabled = false,
  }
  tr.orpause = KUI:CreateButton(arg, tr)
  tr.orpause:Catch("OnClick", function(this, evt, ...)
    open_roll_or_pause(self)
  end)

  arg = {
    x = 200, y = ypos, width = LOOTBTN_W, text = L["Remove"],
    tooltip = { title = L["TIP054.0"], text = L["TIP054"], },
    enabled = false,
  }
  tr.remcancel = KUI:CreateButton(arg, tr)
  tr.remcancel:Catch("OnClick", function(this, evt, ...)
    remove_or_cancel(self)
  end)

  --
  -- The three are placed against each other and the middle one centred on the pane, rather than at fixed offsets, so that
  -- the group stays centred whatever width the pane is given.
  --
  local btngap = 6

  tr.orpause:ClearAllPoints()
  tr.orpause:SetPoint("TOP", tr, "TOP", 0, ypos)

  tr.oclbids:ClearAllPoints()
  tr.oclbids:SetPoint("TOPRIGHT", tr.orpause, "TOPLEFT", 0 - btngap, 0)

  tr.remcancel:ClearAllPoints()
  tr.remcancel:SetPoint("TOPLEFT", tr.orpause, "TOPRIGHT", btngap, 0)

  --
  -- The Bids / rolls panel is one of two panes, as the panel above it is one of three frames: the bid pane, the list of
  -- bidders the full width of the panel, and while a roll is open the roll pane in its place (build_roll_pane). The buttons
  -- that act on a bid are under Candidates. The list's space stops a button's height short of the foot, so that there is
  -- room along it for a bar of them. The list is as many whole rows as that holds, and what they leave over is the gap
  -- between the last of them and the bar.
  --
  build_bid_pane(self, bb)

  --
  -- Force bid and Force retract, side by side in the middle of the panel under Candidates, which is just tall enough for
  -- them. They act on the candidate and the bidder selected, and only the master looter and the config's admins see them.
  --
  local CAND_BTN_W = 100

  bb.buttons = MakeFrame("Frame", nil, bl.btnpanel.content)
  bb.buttons:SetWidth(2 * CAND_BTN_W + KUI.WIDGET_GAP)
  bb.buttons:SetHeight(CAND_BTN_H)
  bb.buttons:SetPoint("TOP", bl.btnpanel.content, "TOP", 0, 0)

  arg = {
    x = 0, y = 0, width = CAND_BTN_W, text = L["Force bid"],
    tooltip = { title = "$$", text = L["TIP056"], },
    enabled = false, doubleclick = true,
  }
  bb.forcebid = KUI:CreateButton(arg, bb.buttons)
  bb.forcebid:Catch("OnClick", function(this, evt, ...)
    force_bid(self)
  end)
  bb.forcebid:Catch("OnDoubleClick", function(this, evt, ...)
    force_bid(self, true)
  end)

  arg = {
    x = CAND_BTN_W + KUI.WIDGET_GAP, y = 0, width = CAND_BTN_W, text = L["Force retract"],
    tooltip = { title = "$$", text = L["TIP057"], },
    enabled = false,
  }
  bb.forceret = KUI:CreateButton(arg, bb.buttons)
  bb.forceret:Catch("OnClick", function(this, evt, ...)
    self:RetractBidder(selectedbiduid)
  end)

  build_my_bid_buttons(self, bb)
  build_roll_pane(self, bb)

  --
  -- Item editor tab, two columns exactly as tall as Item instructions, on the right, which is everything the platform does
  -- with an item; the page under them is left empty. On the left the Items list, the Delete button in a panel of its own
  -- under it, and under that the active policy's own panel, titled with its name, for what only it does (see ItemsPage in
  -- Policy.lua). That panel is as tall as what the policy built there and is not there at all for a policy with nothing to
  -- add, the Items list taking whatever the two below it leave.
  --
  -- How tall the columns are depends on what goes in Item instructions, so they are made with no height here and given one
  -- once the options have been built.
  --
  local cf = qf.itemedit
  local ITEMBTN_H = 24

  arg = {
    inset = 0, height = 0, topanchor = true, name = "KonferItemEditSplit", topborder = false, toppadding = 0,
    bottomborder = false, bottompadding = 0,
  }
  cf.hsplit = KUI:CreateHSplit(arg, cf)

  arg = {
    width = 224, name = "KonferItemEditTopSplit", righttitle = L["Item instructions"],
  }
  cf.vsplit = KUI:CreateVSplit(arg, cf.hsplit.topframe)

  local lsc = cf.vsplit.leftframe

  arg = {
    inset = 0, height = 0, topanchor = false, name = "KonferItemsPolicySplit", bottomtitle = "",
  }
  lsc.polsplit = KUI:CreateHSplit(arg, lsc)
  lsc.polsplit:SetStaticShown(false)
  qf.policyitemssplit = lsc.polsplit
  qf.policyitemspanel = lsc.polsplit.bottominset
  qf.policyitemsslot = lsc.polsplit.bottomframe

  arg = {
    inset = 0, height = ITEMBTN_H, name = "KonferItemsSplit", toptitle = L["Items"],
  }
  lsc.hsplit = KUI:CreateHSplit(arg, lsc.polsplit.topframe)

  local ls = lsc.hsplit.topframe
  local bs = lsc.hsplit.bottomframe
  local rs = cf.vsplit.rightframe
  qf.itemopts = rs
  qf.iteminstpanel = cf.vsplit.rightinset

  arg = {
    name = "KonferItemScrollList",
    itemheight = 16,
    newitem = function(objp, num)
        local rf = KUI.NewItemHelper(objp, num, "KonferIListButton", 200, 16, nil, nil, function(this, ix)
            this:GetParent():GetParent():SetSelected(ix, false, true)
            return true
          end, nil)
        -- Hooked rather than set, since the row's hover mark (KUI.NewItemHelper) uses them too.
        rf:HookScript("OnEnter", function(this, evt, ...)
          local pp = konfer.apol
          local idx = this:GetID()
          GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT", 0, 25)
          GameTooltip:SetHyperlink(pp.cfg.items[qf.sorteditems[idx].id].ilink)
          GameTooltip:Show()
        end)
        rf:HookScript("OnLeave", function(this, evt, ...)
          GameTooltip:Hide()
        end)
        return rf
      end,
    setitem = function(objp, idx, slot, btn)
      return ilist_setitem(objp, idx, slot, btn)
    end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return ilist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  ls.ilist = KUI:CreateScrollList(arg, ls)
  qf.itemlist = ls.ilist

  ypos = 0
  arg = {
    x = 0, y = ypos, label = { text = L["Ignore item"] },
    tooltip = { title = "$$", text = L["TIP059"], },
    enabled = false,
  }
  rs.ignore = KUI:CreateCheckBox(arg, rs)
  rs.ignore:Catch("OnValueChanged", function(this, evt, val, user)
    local io = qf.itemopts

    if (not user or not qf.iinfo) then
      return
    end

    --
    -- Ignoring an item says only that. Everything else here is put out of reach while it is ignored, and left as it is, so
    -- that unticking it finds the item's other instructions where they were.
    --
    qf.iinfo.ignore = val and true or nil
    changed(nil, user)

    local auto = qf.iinfo.autoassign and qf.iinfo.autoassign ~= self.AUTOASSIGN_NOBODY
    io.ignorequal:SetEnabled(not val and not auto)
    io.autoassign:SetEnabled(not val)
    enable_uvalues(io, not val and not auto)
    item_selection()
  end)
  ypos = ypos - rs.ignore:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Ignore item quality"] },
    tooltip = { title = "$$", text = L["TIP097.1"] },
    enabled = false,
  }
  rs.ignorequal = KUI:CreateCheckBox(arg, rs)
  rs.ignorequal:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and qf.iinfo) then
      qf.iinfo.ignorequal = val and true or nil
      changed(nil, user)
    end
  end)
  ypos = ypos - rs.ignorequal:GetHeight() - KUI.WIDGET_GAP

  --
  -- Who the item goes to without a bid or roll, one of a radio group. Anyone but nobody takes the item out of everything else
  -- here: its quality no longer matters and there is nobody else for it to go to, so those options are put out of reach for
  -- as long as it is set, and left as they are, so that setting it back to nobody finds them where they were.
  --
  local aanames = { K.NOBODY_STR, L["Enchanter"], L["Master looter"] }

  arg = {
    name = "KonferItemAutoAssign", mode = "SINGLE", itemheight = 16, x = 0, y = ypos,
    dwidth = KUI:DropDownWidth(aanames), label = { text = L["Auto-assign to"], pos = "LEFT" }, enabled = false,
    items = {
      { text = aanames[1], value = self.AUTOASSIGN_NOBODY, group = "autoassign" },
      { text = aanames[2], value = self.AUTOASSIGN_ENCHANTER, group = "autoassign",
        tooltip = { title = "$$", text = L["TIP097"] } },
      { text = aanames[3], value = self.AUTOASSIGN_ML, group = "autoassign",
        tooltip = { title = "$$", text = L["TIP098"] } },
    },
  }
  rs.autoassign = KUI:CreateDropDown(arg, rs)
  rs.autoassign:Catch("OnValueChanged", function(this, evt, newv, user)
    local io = qf.itemopts
    local auto = newv ~= self.AUTOASSIGN_NOBODY

    if (not user or not qf.iinfo) then
      return
    end

    qf.iinfo.autoassign = newv
    changed(nil, user)
    io.ignorequal:SetEnabled(not auto)
    enable_uvalues(io, not auto)
    item_selection()
  end)
  rs.autoassign:SetValue(self.AUTOASSIGN_NOBODY, true)
  ypos = ypos - rs.autoassign:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  arg = {
    x = 0, y = ypos, text = L["Class restriction"],
    font = "GameFontNormal",
  }
  rs.cflabel = KUI:CreateStringLabel(arg, rs)
  ypos = ypos - rs.cflabel:GetHeight() - KUI.WIDGET_GAP

  ypos = classes_create(rs, ypos, false, function(this, evt, val, cls, user)
    iclass_filter_func(this, evt, val, cls, user)
  end)

  rs.role = KU:CreateRoleDropdown("KonferItemRoleFilter", 0, ypos, rs)
  rs.role:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.iinfo) then
      qf.iinfo.role = newv
      changed(nil, user)
    end
  end)
  ypos = ypos - rs.role:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP
  rs.role:SetValue(0)
  rs.role:SetEnabled(false)

  --
  -- The guild rank a roll for this item starts out filtered to, which overrides the one the list it is rolled on carries.
  -- It is offered only where the config says to filter by guild rank at all and this character has a guild to be ranked in,
  -- which is what cfg:RankFiltering asks, and like the class and role filters beside it it means nothing to an item that
  -- is ignored or assigned to somebody without a roll.
  --
  arg = {
    x = 0, y = ypos, name = "KonferItemRankFilter", dwidth = 175, mode = "SINGLE", itemheight = 16,
    items = KUI.emptydropdown, enabled = false,
    label = { text = L["Initial guild rank filter"], pos = "TOP" },
    tooltip = { title = "$$", text = L["TIP061"] },
  }
  rs.defrank = KUI:CreateDropDown(arg, rs)
  -- Published because the guild rank list is refilled from Konfer.lua.
  konfer.qf.itemrank = rs.defrank
  rs.defrank:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.iinfo) then
      qf.iinfo.rank = tonumber(newv)
      changed(nil, user)
    end
  end)
  ypos = ypos - rs.defrank:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP
  rs.defrank:SetValue(0)
  rs.defrank:SetEnabled(false)

  ypos = build_nextdrop(self, rs, ypos)

  -- The columns are Item instructions' height: what its options use, plus the rings round the panel.
  local insttop = cf.vsplit.rightinset

  qf.iteminstpane = cf.hsplit.topinset
  qf.iteminsth = 0 - ypos + insttop.rings.top + insttop.rings.bottom
  qf.iteminstpane:SetHeight(qf.iteminsth)

  --
  -- The rows from the guild rank filter down, in order, each with the item field it sets, where it was built and how far
  -- it is from the row under it, the last from the foot of the column. A policy can hide some of them (ItemsPage.hide),
  -- and ShowLootPolicyUI moves those under them up by as much. Where a row was built, and against what, is read back from
  -- its own TOP anchor, so whatever its label adds to the place it was asked for is kept when it moves.
  --
  qf.itemrows = {}

  for _, row in ipairs({
    { field = "rank", widget = rs.defrank, step = rs.defrank:GetHeight() + KUI.WIDGET_GAP + KUI.DROPDOWN_ADD_GAP },
    { field = "list", widget = rs.speclist, step = rs.speclist:GetHeight() + KUI.WIDGET_GAP + KUI.DROPDOWN_ADD_GAP },
    { field = "nextuser", widget = rs.nextuser, step = rs.nextuser:GetHeight() + KUI.WIDGET_GAP + KUI.DROPDOWN_ADD_GAP },
    { field = "autodel", widget = rs.autodel, step = rs.autodel:GetHeight() + KUI.WIDGET_GAP },
    { field = "awardlist", widget = rs.awardlist, step = rs.awardlist:GetHeight() },
  }) do
    for i = 1, row.widget:GetNumPoints() do
      local point, rel, _, _, y = row.widget:GetPoint(i)

      if (point == "TOP") then
        row.rel, row.y = rel, y
      end
    end

    tinsert(qf.itemrows, row)
  end

  --
  -- Which widget shows which field, for the changed colour. Every class checkbox shows the one class filter, and the policy's
  -- own options say so for themselves.
  --
  qf.itempending:Watch(rs.ignore, "ignore")
  qf.itempending:Watch(rs.ignorequal, "ignorequal")
  qf.itempending:Watch(rs.autoassign, "autoassign")
  qf.itempending:Watch(rs.role, "role")
  qf.itempending:Watch(rs.defrank, "rank")

  for k, v in pairs(K.IndexClass) do
    if (v.w and rs[v.w]) then
      qf.itempending:Watch(rs[v.w], "cfilter")
    end
  end

  arg = {
    x = 0, y = 0, text = L["Delete"], enabled = false,
    tooltip = { title = "$$", text = L["TIP066"] },
  }
  bs.deletebtn = KUI:CreateButton(arg, bs)
  bs.deletebtn:ClearAllPoints()
  bs.deletebtn:SetPoint("CENTER", bs, "CENTER", 0, 0)
  qf.itemdelbtn = bs.deletebtn
  bs.deletebtn:Catch("OnClick", function(this, evt)
    local pp = konfer.apol
    local ii = qf.selitemid and pp.cfg.items[qf.selitemid]

    if (not ii) then
      return
    end

    -- Every other admin loses the item's instructions too, so it is asked before it is done.
    K.ConfirmationDialog(self, { text = L["Delete item"], owner = pp }, L["DELITEM"], { L["Item: %s"], ii.ilink }, function(kmod, arg)
      local pp = konfer.apol
      konfer:Config(arg.cfgid):DeleteItem(arg.itemid)
    end, { itemid = qf.selitemid, cfgid = pp.currentid }, qf.mainwin, 200)
  end)

  --
  -- History tab. We have a header, then the rest of the panel is a big scrolling list of loot history.
  --
  local cf = qf.history
  local tf = cf.hsplit.topframe
  local bf = cf.hsplit.bottomframe
  ypos = 0

  --
  -- The buttons at the bottom first, two rows of them, each row a frame of its own centred in the panel with the standard
  -- gap between its buttons. The panel's content already stands the standard gap in from its rim, so the first row starts at
  -- its top and the second a gap below the first, and the pane is made exactly as tall as the two rows and that gap.
  --
  local CLEARALL_W, CLEARWEEK_W, CLEARMONTH_W, EXPORT_W, UNDO_W, BCAST_W = 85, 195, 200, 180, 85, 100
  local BTN_H = 24
  local binset = cf.hsplit.bottominset

  binset:SetHeight(BTN_H + KUI.WIDGET_GAP + BTN_H + binset.rings.top + binset.rings.bottom)

  bf.row1 = MakeFrame("Frame", nil, bf)
  bf.row1:SetWidth(CLEARALL_W + CLEARWEEK_W + CLEARMONTH_W + 2 * KUI.WIDGET_GAP)
  bf.row1:SetHeight(BTN_H)
  bf.row1:SetPoint("TOP", bf, "TOP", 0, 0)

  bf.row2 = MakeFrame("Frame", nil, bf)
  bf.row2:SetWidth(EXPORT_W + UNDO_W + BCAST_W + 2 * KUI.WIDGET_GAP)
  bf.row2:SetHeight(BTN_H)
  bf.row2:SetPoint("TOP", bf, "TOP", 0, 0 - BTN_H - KUI.WIDGET_GAP)

  arg = {
    x = 0, y = 0, width = CLEARALL_W, height = BTN_H, text = L["Clear all"],
    tooltip = { title = "$$", text = L["TIP067"], },
  }
  --
  -- Clear the history of everything older than AGE seconds, or all of it for nil, once the user has said yes. What is cleared
  -- cannot be put back, and the three buttons sit side by side, so each asks first, titled with its own words. A raider who
  -- is no admin is told an admin's broadcast can put it back, and where to stop those.
  --
  local function clear_history(title, age)
    local pp = konfer.apol
    local subject = { L["Configuration: %s"], pp.cfg.name }
    local admin = pp.cfg:MyStatus()
    local msg = admin and L["CLEARHISTMSG"] or strfmt(L["CLEARHISTMSG_RAIDER"], white(L["Options"]))

    K.ConfirmationDialog(self, { text = title, owner = pp }, msg, subject, function(kmod, arg)
      local cfp = kmod:Config(arg.cfgid)

      if (not cfp) then
        return
      end

      if (not arg.age) then
        cfp.history = {}
      else
        local cutoff = K.time() - arg.age
        local i = 1

        while (i <= #cfp.history) do
          if (cfp.history[i][konfer.HIST_WHEN] < cutoff) then
            tremove(cfp.history, i)
          else
            i = i + 1
          end
        end
      end

      kmod:RefreshHistory()
    end, { cfgid = pp.currentid, age = age }, qf.mainwin, admin and 200 or 260)
  end

  bf.clearall = KUI:CreateButton(arg, bf.row1)
  bf.clearall:Catch("OnClick", function(this, evt, ...)
    clear_history(L["Clear all"], nil)
  end)

  arg = {
    x = CLEARALL_W + KUI.WIDGET_GAP, y = 0, width = CLEARWEEK_W, height = BTN_H, text = L["Clear all except last week"],
    tooltip = { title = "$$", text = L["TIP068"], },
  }
  bf.clearweek = KUI:CreateButton(arg, bf.row1)
  bf.clearweek:Catch("OnClick", function(this, evt, ...)
    clear_history(L["Clear all except last week"], 604800) -- One week in seconds
  end)

  arg = {
    x = CLEARALL_W + CLEARWEEK_W + 2 * KUI.WIDGET_GAP, y = 0, width = CLEARMONTH_W, height = BTN_H,
    text = L["Clear all except last month"],
    tooltip = { title = "$$", text = L["TIP069"], },
  }
  bf.clearmonth = KUI:CreateButton(arg, bf.row1)
  bf.clearmonth:Catch("OnClick", function(this, evt, ...)
    clear_history(L["Clear all except last month"], 2678400) -- One month in seconds
  end)

  arg = {
    x = 0, y = 0, text = L["Export as JSON"], width = EXPORT_W, height = BTN_H,
    tooltip = { title = "$$", text = L["TIP070.2"], },
  }
  bf.exportjson = KUI:CreateButton(arg, bf.row2)
  bf.exportjson:Catch("OnClick", function(this, evt, ...)
    local pp = konfer.apol
    export_history_button(self)
  end)

  --
  -- Undo puts the last award back. It is the master looter's, and is lit by whether there is an award to undo rather than by
  -- whether the history has anything in it, so it is not one of the buttons sync_history_buttons looks after.
  --
  arg = {
    x = EXPORT_W + KUI.WIDGET_GAP, y = 0, width = UNDO_W, height = BTN_H, text = L["Undo"],
    tooltip = { title = "$$", text = L["TIP058"], },
    enabled = false,
  }
  bf.undo = KUI:CreateButton(arg, bf.row2)
  bf.undo:Catch("OnClick", function(this, evt, ...)
    undo_button(self)
  end)
  qf.undobutton = bf.undo
  -- Published because AwardItem enables it when an award becomes undoable.
  konfer.qf.undobutton = bf.undo

  --
  -- Broadcast sends the master looter's history to everybody using the mod (LHBCS), who add the rows they do not hold. It
  -- is laid out and lit by sync_history_buttons, at most once every konfer.HISTORY_BCAST_GAP seconds.
  --
  arg = {
    x = EXPORT_W + UNDO_W + 2 * KUI.WIDGET_GAP, y = 0, width = BCAST_W, height = BTN_H, text = L["Broadcast"],
    tooltip = { title = "$$", text = L["TIP070.3"], },
    enabled = false,
  }
  bf.histbcast = KUI:CreateButton(arg, bf.row2)
  bf.histbcast:Catch("OnClick", function(this, evt, ...)
    local pp = konfer.apol
    local cfg = pp and pp.cfg

    if (not cfg or not konfer:AmIML() or K.time() < (cfg.histsent or 0) + konfer.HISTORY_BCAST_GAP) then
      return
    end

    cfg.histsent = K.time()
    pp:CSendChannelAM(pp.currentid, "LHBCS", "BULK", cfg.history)
    pp:info(L["loot history broadcast."])
    sync_history_buttons()
  end)
  qf.histbcast = bf.histbcast
  qf.histrow2 = bf.row2
  bf.row2.buttons = { bf.exportjson, bf.undo, bf.histbcast }

  -- Every one of them acts on the history, and none has anything to act on while it is empty. See sync_history_buttons.
  qf.histbuttons = { bf.clearall, bf.clearweek, bf.clearmonth, bf.exportjson }

  create_history_list(self, tf)
  sync_history_buttons()

  sync_item_panels()
end

--
-- Build PP's own panel on the item editor, into the slot the page keeps for it. Once per policy, from konfer:BuildPolicyUI,
-- which is also what makes sure the page itself already exists.
--
-- The policy's options are edited in the item's edit buffer along with the platform's, so it is given what it needs to take
-- part in that: a way to say the user has changed something, which is what makes Update available.
--
function konfer:BuildLootPolicyUI(pp)
  local ip = pp.ItemsPage

  if (not ip or not ip.Construct) then
    return
  end

  pp.itemsframe = MakeFrame("Frame", nil, qf.policyitemsslot)
  pp.itemsframe:ClearAllPoints()
  pp.itemsframe:SetPoint("TOPLEFT", qf.policyitemsslot, "TOPLEFT", 0, 0)
  pp.itemsframe:SetPoint("BOTTOMRIGHT", qf.policyitemsslot, "BOTTOMRIGHT", 0, 0)
  pp.itemsframe:Hide()

  --
  -- What the policy answers is how tall what it built is, which is what the panel is made to hold exactly. A policy that
  -- answers nothing is given ITEMS_POLICY_H.
  --
  local _, h = konfer:PolicyHook(pp, "ItemsPage.Construct", nil, ip.Construct, pp.itemsframe, function()
    changed(nil, true)
  end)

  pp.itemsheight = h
end

--
-- Show or hide PP's panel on the item editor, under the Delete button. The panel is there only when there is something in
-- it, and is as tall as the policy said what it built is, or ITEMS_POLICY_H when it did not say.
--
local ITEMS_POLICY_H = 100

function konfer:ShowLootPolicyUI(pp, onoff)
  if (pp.itemsframe) then
    pp.itemsframe:SetShown(onoff and true or false)
  end

  if (onoff) then
    self:LabelBidsButton(pp)
  end

  if (not onoff) then
    return
  end

  --
  -- Item instructions without the rows the policy hides, those under them moved up into the room and the columns shortened
  -- by as much.
  --
  local hide = (pp.ItemsPage and pp.ItemsPage.hide) or {}
  local up = 0

  for _, row in ipairs(qf.itemrows) do
    row.widget:SetShown(not hide[row.field])
    row.widget:SetPoint("TOP", row.rel, "TOP", 0, row.y + up)

    if (hide[row.field]) then
      up = up + row.step
    end
  end

  qf.iteminstpane:SetHeight(qf.iteminsth - up)

  --
  -- And Assign loot without what the policy hides there: Constraints without the guild rank row, the strict filters moved
  -- up, and the left hand column without the Lists panel or the panel of Force bid and Force retract, Candidates having
  -- what they leave.
  --
  local ahide = (pp.AssignPage and pp.AssignPage.hide) or {}
  local rankup = ahide.rank and qf.rankrow.step or 0

  for _, w in ipairs(qf.rankrow.widgets) do
    w:SetShown(not ahide.rank)
  end

  for _, u in ipairs(qf.rankrow.under) do
    u.widget:SetPoint("TOP", u.rel, "TOP", 0, u.y + rankup)
  end

  qf.constraintspane:SetHeight(qf.constraintsh - rankup)

  local room = qf.candbtnpanel:GetParent()

  qf.lootlistsplit:SetStaticShown(not ahide.lists)
  qf.candbtnpanel:SetShown(not ahide.forcebid)
  qf.candidatespanel:SetPoint("BOTTOMRIGHT", ahide.forcebid and room or qf.candbtnpanel,
    ahide.forcebid and "BOTTOMRIGHT" or "TOPRIGHT", 0, 0)

  local has = pp.itemsframe ~= nil

  -- A policy with nothing to add has no panel at all, not an empty one, and the Items list has the room.
  qf.policyitemssplit:SetStaticShown(has)

  if (has) then
    qf.policyitemspanel:SetTitleText(pp.name)
    qf.policyitemssplit:SetSplitSize(pp.itemsheight or ITEMS_POLICY_H)
  end
end

--
-- Put the item list back on the page. Everything is disabled first because the selection that follows is what re-enables
-- whatever the selected item allows, and the policy is told afterwards whatever that turned out to be.
--
local function refresh_item_list(self, pp, oldidx)
  itemopts_setenabled(false)
  qf.itemopts.cflabel:SetEnabled(true)
  qf.itemdelbtn:SetEnabled(false)

  --
  -- The editor's unsaved changes are held across the rebuild, which deselects the item and selects it again (see PS.Hold).
  -- Let go, what another admin has since replaced is gone, and what is left is put back on screen.
  --
  qf.itempending:Hold()
  qf.itemlist.itemcount = pp.cfg.nitems
  qf.itemlist:UpdateList()
  qf.itemlist:SetSelected(oldidx, true, true)
  qf.itempending:Release()

  if (qf.selitemid) then
    show_item()
  end

  item_selection()
end

--
-- The item editor's unsaved changes, for a policy's own options on it. See ItemsPage.Construct in Policy.lua.
--
function konfer:ItemsPending()
  return qf.itempending
end

--
-- Rebuild the item editor from the config on screen, which is the active policy's.
--
-- The selection is preserved by item id rather than by index, the sort being by name and a rename moving everything below it.
--
function konfer:RefreshItemList()
  local pp = self.apol

  --
  -- Page not built yet, or no config, which is where a policy starts out.
  --
  if (qf.itemlist and pp and pp.cfg) then
    local vt = {}
    local olditem = qf.selitemid or 0
    local oldidx = nil

    qf.sorteditems = {}
    qf.selitemid = nil

    for ik, iv in pairs(pp.cfg.items) do
      vt[ik] = strlower(strmatch(iv.ilink, ".*|h%[(.*)%]|h"))
      tinsert(qf.sorteditems, { id = ik, link = iv.ilink })
    end

    tsort(qf.sorteditems, function(a,b)
      return vt[a.id] < vt[b.id]
    end)

    for ik, iv in pairs(qf.sorteditems) do
      if (iv.id == olditem) then
        oldidx = ik
        break
      end
    end

    refresh_item_list(self, pp, oldidx)
  end
end

--
-- Refreshes the bid scroll list. Attempts to preserve the currently selected bidder. Checks to make sure that all bidders
-- are actually members of the current list, as this could have changed. Removes any bidders that aren't.
--
--
-- The bidders in the order that decides the item, winner first, each with what they stand at on the list. Who wins is the
-- policy's to say (RankBidders): the platform hands the bidders over by the tier the config's Bid options give their kind
-- (kind_tiers), within a tier by what they bid where the bid takes an amount, and then in the list's own order (the
-- policy's Order, through cfg:ListPosition). That is also what a policy with no ranking of its own gets, and whatever
-- order comes back is kept. A bidder's standing is the policy's text for it (PositionText), what the list itself shows.
-- Somebody no longer on the list is no longer bidding.
--
-- Only the master looter works this out. Everybody else is sent the result whole (BIDER), so every client shows the
-- same bidders in the same order whatever its own copy of the list says.
--
local function rank_bidders(self)
  local cfg = self.apol.cfg
  local tiers = kind_tiers(cfg)
  local kept = {}

  for _, b in ipairs(bidders) do
    local pos = cfg:ListPosition(b.uid, lootlistid)

    if (pos) then
      local _, standing = cfg:PolicyCall("PositionText", tostring(pos), lootlistid, b.uid, pos)

      b.idx = pos
      b.standing = standing
      b.tier = tiers[b.kind or "M"] or 0
      tinsert(kept, b)
    end
  end

  tsort(kept, function(a, b)
    if (a.tier ~= b.tier) then
      return a.tier < b.tier
    end

    if ((a.amount or 0) ~= (b.amount or 0)) then
      return (a.amount or 0) > (b.amount or 0)
    end

    return a.idx < b.idx
  end)

  local _, ranked = cfg:PolicyCall("RankBidders", kept, lootlistid, kept, lootitem and lootitem.loot.ilink)

  bidders = (type(ranked) == "table") and ranked or kept
end

--
-- The master looter's: tells the raid the bidders (BIDER), winner first, each { uid, standing, kind, amount }, whenever they
-- differ from what it was last told. A bid, a change of kind or amount, a retraction and the list moving under an open bid
-- all come through here, so a raider's list never lags the master looter's. Silent bidding tells nobody who else is
-- bidding: each bidder is whispered their own row alone, so they see their bid and can retract it, and one who has
-- retracted an empty list.
--
local function send_bidders(self)
  local cfg = self.apol.cfg

  if (not bidders) then
    return
  end

  local rows = {}
  local keys = {}

  for _, b in ipairs(bidders) do
    tinsert(rows, { b.uid, b.standing, b.kind, b.amount })
    tinsert(keys, b.uid .. "=" .. tostring(b.standing) .. "/" .. tostring(b.kind) .. "/" .. tostring(b.amount))
  end

  if (cfg.settings.silent_bid) then
    local own = sentbidders.own
    local tell = {}
    local bidding = {}

    for i, b in ipairs(bidders) do
      bidding[b.uid] = true
      tinsert(tell, { b.uid, keys[i], { rows[i] } })
    end

    for uid in pairs(own) do
      if (not bidding[uid]) then
        tinsert(tell, { uid, nil, {} })
      end
    end

    for _, t in ipairs(tell) do
      local uid, key = t[1], t[2]
      local name = cfg:UserName(uid)

      if (own[uid] ~= key and uid ~= cfg:MyUid() and name and KRP.players and KRP.players[name]) then
        self.apol:CSendWhisperAM(cfg.id, name, "BIDER", "ALERT", t[3])
      end
      own[uid] = key
    end

    return
  end

  local sent = tconcat(keys, " ")

  if (sent ~= sentbidders.all) then
    sentbidders.all = sent
    self.apol:CSendAM(cfg.id, "BIDER", "ALERT", rows)
  end
end

local function refresh_bidders(self)
  -- While a roll is open the list is the rollers.
  if (rolling) then
    self:ShowRollers(rollrows)
    return
  end

  local olduid = selectedbiduid or nil

  selectedbidder = nil
  selectedbiduid = nil

  qf.bidscroll.itemcount = 0
  if (bidders) then
    -- The master looter ranks them afresh, the list having perhaps moved under them. Everybody else shows what they were sent.
    if (self:AmIML()) then
      rank_bidders(self)
      send_bidders(self)
    end

    qf.bidscroll.itemcount = #bidders

    -- Your own bid can be taken back, and the button says so while you have one in.
    local mine = self.apol.cfg:MyUid()
    local inbid = false

    for _, b in ipairs(bidders) do
      if (mine and b.uid == mine) then
        inbid = true
      end
    end

    if (qf.myretract) then
      qf.myretract:SetEnabled(inbid)
    end

    if (olduid) then
      for k,v in ipairs(bidders) do
        if (v.uid == olduid) then
          selectedbidder = k
          break
        end
      end
    end
  end

  qf.bidscroll:UpdateList()
  qf.bidscroll:SetSelected(selectedbidder, true, true)
end

function konfer:RefreshLootMembers()
  local oldmember = memberid or nil
  local oldidx = nil

  memberid = nil
  members = nil

  -- A list the active config does not have, one it had before the config changed, has no members to show.
  local lootlist = lootlistid and self.apol.cfg and self.apol.cfg.lists[lootlistid]

  if (lootlist) then
    if (#lootlist.users > 0) then
      local cfg = self.apol.cfg

      --
      -- In the policy's order for candidates (Order's LOOT), each shown with the policy's word for where they stand, and only
      -- those in the raid, a corpse's item going to nobody who is not. Loot added by hand is the master looter's to give,
      -- a BoE everybody is entitled to among it, so for that the raid's standby count as here too (cfg:IsReserved). On a
      -- tethered list a main stands for every character of theirs, and whichever of them is here is the row in the main's
      -- place, an ordinary one: the main if they are here themselves, and otherwise the alt who is.
      --
      local _, ordered = cfg:PolicyCall("Order", lootlist.users, lootlistid, lootlist.users, true)
      local raidhere = self.raid.uidmap or {}
      local byhand = lootitem and lootitem.loot and lootitem.loot.slot == 0
      local anyone = false

      -- Made up loot is looked at out of a group, so over it everybody on the list is here.
      anyone = self.testloot and true or false -- @debug-delete@

      local function here(u)
        return raidhere[u] or (byhand and cfg:IsReserved(u))
      end

      --
      -- Only those who could have the item: anybody its Constraints would refuse a bid or roll from is left out, and so is
      -- anybody the policy keeps out of a roll on it, PUG all but an item's reservers while their first roll is owed
      -- (MayRoll, asked here with no kind).
      --
      local ilink = lootitem and lootitem.loot and lootitem.loot.ilink

      local function could(u)
        if (not self:MeetsConstraints(u)) then
          return false
        elseif (not ilink) then
          return true
        end

        local _, ok = cfg:PolicyCall("MayRoll", true, u, nil, ilink)

        return ok and true or false
      end

      members = {}

      for k, v in ipairs(ordered) do
        local present = {}

        if (anyone or here(v)) then
          present[1] = v
        elseif (lootlist.tethered) then
          for _, a in ipairs(cfg:UserAlts(v) or {}) do
            if (here(a)) then
              tinsert(present, a)
            end
          end
        end

        if (#present > 0) then
          local _, standing = cfg:PolicyCall("PositionText", tostring(k), lootlistid, v, k)

          for _, u in ipairs(present) do
            if (could(u)) then
              tinsert(members, { id = u, idx = k, standing = standing })
            end
          end
        end
      end

      for k,v in ipairs(members) do
        if (v.id == oldmember) then
          oldidx = k
          break
        end
      end
    end
  end

  --
  -- The candidates are the engine's list's members. The page shows the active policy, which is the policy the engine runs,
  -- so they are always this page's to show.
  --
  if (qf.members) then
    qf.members.itemcount = members and #members or 0
    qf.members:UpdateList()
    qf.members:SetSelected(oldidx, true, true)
  end

  -- The buttons follow the Candidates, a first roll being owed only while somebody it is kept for is among them.
  if (lootitem and qf.lootwin and qf.lootwin.onoffer) then
    lootbid_setenabled(true)
  end

  refresh_bidders(self)
  sync_loot_panels()
end

--
-- Empties the bidders without closing the bid. BIDDERS is a table exactly while BIDITEM is set, so a bid still open after the
-- roll list changes under it carries on with nobody on it, and every caller that closes the bid clears BIDITEM first.
--
function konfer:ResetBidList()

  bidders = biditem and {} or nil
  selectedbidder = nil
  selectedbiduid = nil
  qf.bidscroll.itemcount = 0
  qf.bidscroll:UpdateList()
  qf.bidscroll:SetSelected(nil, false, true)
end

function konfer:ResetBidders(send)

  if (self:AmIML() and send and biditem) then
    self.apol:CSendAM(self.apol.currentid, "BIDCL", "ALERT", biditem)
  end

  biditem = nil
  openkinds = nil
  openamounts = nil
  self:StopBidClock()

  self:ResetBidList()

  self:LabelBidsButton()
  qf.lootwin.orpause:SetText(L["Open roll"])
  qf.lootwin.remcancel:SetText(L["Remove"])
  lootbid_setenabled(false)
  qf.bidders.forcebid:SetEnabled(false)
  qf.bidders.forceret:SetEnabled(false)

  sync_loot_panels()
end

--
-- Redraw the loot list with IDX selected. Redrawing a scroll list deselects its row on the way, and when IDX is the item
-- already selected that passing deselection is not a choice to leave it, so the controls for it are left as they are.
--
function konfer:RefreshBossLoot(idx)

  qf.lootscroll.itemcount = 0
  if (self.raid.bossloot) then
    qf.lootscroll.itemcount = #self.raid.bossloot
  end

  redrawing_loot = (idx ~= nil and idx == selectedloot)
  qf.lootscroll:UpdateList()
  redrawing_loot = false

  qf.lootscroll:SetSelected(idx, true, true)

  -- Loot coming up with no list selected is when the master looter's falls on the default list.
  if (self.raid.bossloot and not lootlistid and qf.lists and self:AmIML()) then
    refresh_loot_lists(self)
  end

  sync_loot_panels()
end

--
-- Redraw the loot list as it stands, keeping what is selected, for when something about its items has been learned.
--
function konfer:RedrawBossLoot()
  self:RefreshBossLoot(selectedloot)
end

function konfer:ResetBossLoot()

  self:EndOpenRoll()
  self:ResetBidders(true)
  selectedloot = nil
  lootitem = nil
  self.raid.bossloot = nil
  self:RefreshBossLoot(nil)
  lootrules_setenabled(self, false)
  lootbid_setenabled(false)
  select_alf(ALF_LOOT)
end

function konfer:SelectLootListByID(list)
  local lid = nil

  for k,v in ipairs(self.apol.sortedlists) do
    if (v.id == list) then
      lid = k
      break
    end
  end

  if (lootlistid ~= list) then
    qf.lists:SetSelected(lid, true, true)
  end

  if (lid) then
    return true
  else
    return false
  end
end

--
-- Called by the OnClick handler for the loot list. Also called from the comms module in response to an LISEL. Sets up
-- selectedloot and lootitem. Because this can be called from comms, this is the wrong place to enable or disable the loot
-- buttons. The enabling of the loot control buttons should be done in the onclick handler, which is only run by the ML.
-- SARMOUR and SROLE are the master looter's two strict filters, which every client's boxes take, nil leaving them be.
--
function konfer:SelectLootItem(idx, filter, role, list, rank, sarmour, srole)
  -- A raider who reloaded, or joined after the loot was sent, holds none, and the master looter's pick names nothing here.
  local loot = self.raid.bossloot and self.raid.bossloot[idx]

  if (not loot) then
    return
  end

  selectedloot = idx
  lootitem = { idx = idx, filter = filter, role = role, list = list, rank = rank, loot = loot }
  sync_loot_panels()

  qf.lootscroll:SetSelected(idx, true, true)

  --
  -- If the item specified a specific list, then select that list now.
  --
  if (list and list ~= "0") then
    if (not self:SelectLootListByID(list)) then
      if (self:AmIML()) then
        self.apol:err(L["item %s names roll list %q, which does not exist."], loot.ilink, tostring(list))
      end
      list = lootlistid
      lootitem.list = list
    end
  end

  -- After the list, whose own strict filters selecting it has just put in the boxes.
  if (sarmour ~= nil) then
    qf.lootrules.strictarmour:SetChecked(sarmour)
  end
  if (srole ~= nil) then
    qf.lootrules.strictrole:SetChecked(srole)
  end

  -- Set up the various filters
  set_classes_from_filter(filter)
  qf.lootrules.role:SetValue(role)
  qf.lootrules.rank:SetValue(rank)

  qf.bidders.forcebid:SetText(L["Force bid"])
  qf.bidders.forceret:SetText(L["Force retract"])

  -- Everything else is only relevant to the master looter.
  if (not self:AmIML()) then
    lootrules_setenabled(self, false)
    lootbid_setenabled(false)
    return
  end

  --
  -- Before the bidding buttons, the instructions of the item that dropped: one that names somebody in the group who can have
  -- it is put to the master looter, who says whether to go through with them (see THE WIN), and so is one setting it to go
  -- to the enchanter or the master looter (put_autoassign).
  --
  local autoloot = false
  local uname = nil

  --
  -- An item the policy has claimed comes before its instructions, PUG's hard reserves and Loot Council's decisions
  -- (ItemClaim in Policy.lua). Claimed for somebody who can have it, it is put to the master looter as instructions are,
  -- an award on the list it is given out on where the claim says so, and otherwise it is theirs to hand out, Open roll and
  -- Open bids staying dark on it whichever way they answer.
  --
  local claimed, cuid, caward = self:ItemClaim()

  if (claimed) then
    uname = cuid and self.raid.uidmap and self.raid.uidmap[cuid]

    local klid = uname and loot.slot > 0 and KLD.items and KLD.items[loot.slot]

    if (uname and (loot.slot == 0 or (klid and klid.candidates[uname]))) then
      put_instructions(self, {
        uid = cuid, ilink = loot.ilink, itemid = loot.itemid, slot = loot.slot, idx = selectedloot, via = "assign",
        listid = caward and lootlistid or nil, wonon = lootlistid, history = "A",
      })
      return
    end
  end

  if (not claimed and loot.slot and loot.itemid and self.apol.cfg.items[loot.itemid]
    and not self.apol.cfg.items[loot.itemid].ignore) then
    local ii = self.apol.cfg.items[loot.itemid]

    if (put_autoassign(self, loot, ii)) then
      return
    end

    if (ii.user and self.raid.uidmap and self.raid.uidmap[ii.user]) then
      uname = self.raid.uidmap[ii.user]

      --
      -- An item added by hand is in no loot window and has no candidates to ask. Being in the group is enough for it, the
      -- same rule a bid on one is held to.
      --
      local klid = loot.slot > 0 and KLD.items and KLD.items[loot.slot]

      if (loot.slot == 0 or (klid and klid.candidates[uname])) then
        autoloot = true
      end
    end

    --
    -- Gone through with, the instructions win it for them as a bid is won, with the award on the list they name. "0", or a
    -- list deleted since, is no award.
    --
    if (autoloot) then
      put_instructions(self, {
        uid = ii.user, ilink = loot.ilink, itemid = loot.itemid, slot = loot.slot, idx = selectedloot, via = "assign",
        listid = ii.awardlist and self.apol.cfg.lists[ii.awardlist] and ii.awardlist or nil, wonon = lootlistid,
        history = "A", autodel = ii.del,
      })
      return
    end
  end

  lootrules_setenabled(self, true)
  lootbid_setenabled(true)

  -- Who the candidates are depends on the item as well as the list, standby counting for loot added by hand.
  self:RefreshLootMembers()
end

function konfer:RemoveItemByIdx(idx, nocmd)

  qf.lootscroll:SetSelected(nil, false, true)

  if (selectedloot == idx) then
    selectedloot = nil
    lootitem = nil
  end

  tremove(self.raid.bossloot, idx)
  qf.lootscroll.itemcount = #self.raid.bossloot
  qf.lootscroll:UpdateList()
  qf.lootscroll:SetSelected(nil, false, true)

  if (not nocmd) then
    self.apol:CSendAM(self.apol.currentid, "BIREM", "ALERT", idx)
  end

  sync_loot_panels()
end

--
-- Retail hides whispers and /roll results from addons inside dungeons and raids, so there a bid whispered to the looter and
-- a roll typed in chat never reach Konfer. The looter is told so, once a raid, when bids or a roll first open in one. Bids
-- made with Bid on item travel as addon messages and still arrive.
--
local function warn_hidden_chat(self)
  if (not K.RETAIL or not self:AmIML() or self.raid.hiddenchatwarned or not IsInInstance()) then
    return
  end

  self.raid.hiddenchatwarned = true
  self.apol:info(L["inside an instance this client cannot read whispers or /roll results, so bids whispered to you and rolls typed in chat go unseen. Bids made with Bid on item still arrive."])
end

--
-- Bids open on loot item IDX, taking the kinds KINDS, their codes run together, and an amount with each where AMOUNTS,
-- closing by themselves in TIMEOUT seconds where that is more than 0. The master looter works them out from its own config
-- and everybody else is told them (BIDOP), along with PRICE, what the item costs, which the loot list shows before it.
--
function konfer:OpenBid(idx, kinds, amounts, timeout, price)

  warn_hidden_chat(self)

  if (amounts == nil) then
    amounts = bids_take_amounts(self.apol.cfg)
  end

  if (price and self.raid.bossloot and self.raid.bossloot[idx]) then
    self.raid.bossloot[idx].price = price
    self:RefreshBossLoot(selectedloot)
  end

  biditem = idx
  openkinds = kinds or tconcat(bid_kinds(self.apol.cfg))
  openamounts = amounts and true or false
  bidders = {}
  sentbidders = { own = {} }

  -- What was bid on the last item is nothing to do with this one.
  if (qf.myamount) then
    qf.myamount:SetText("")
  end

  self:StartBidClock(tonumber(timeout))
  qf.bidscroll.itemcount = 0
  qf.bidscroll:UpdateList()
  qf.bidscroll:SetSelected(nil, false, true)
  sync_loot_panels()
end

--
-- The line the master looter is shown of UID's bid of KIND (its code), for AMOUNT where the bid takes one, or with KIND false
-- of their retracting it. A raider following the bid is shown the same line by the same path (BIDAN), so the two see one
-- line, coloured and worded alike, rather than the raid chat line, which is for raiders without the mod.
--
function konfer:BidInfo(uid, kind, amount)
  local cfg = self.apol and self.apol.cfg
  local rl = cfg and lootlistid and cfg.lists[lootlistid]
  local name, cls = cfg and uid and cfg:UserNameClass(uid)

  if (not rl or not name or not lootitem) then
    return
  end

  local lname = white(rl.name)

  if (not kind) then
    self.apol:info(L["%s %s on %s on the %s list."], shortaclass(name, cls), L["retracted"], lootitem.loot.ilink, lname)
    return
  end

  local phrase = KIND_BY_CODE[kind] and KIND_BY_CODE[kind].phrase or ""

  if (amount) then
    self.apol:info(L["%s bid %d %s on %s on the %s list."], shortaclass(name, cls), amount, phrase, lootitem.loot.ilink,
      lname)
  else
    self.apol:info(L["%s bid %s on %s on the %s list."], shortaclass(name, cls), phrase, lootitem.loot.ilink, lname)
  end
end

-- Whether bids are open on an item, which a raider following them knows as the master looter does.
function konfer:BidOpen()
  return biditem ~= nil
end

--
-- The master looter's: UID's bid, new or changed, told to the master looter and, with ANNOUNCE, to the raid, which a silent
-- auction does not tell. Otherwise the raid hears who bid and who is now winning, and what each bid where the bid takes an
-- amount.
--
local function announce_bid(self, uid, announce)
  local cfg = self.apol.cfg
  local name = cfg:UserName(uid)
  local mine = nil

  for _, b in ipairs(bidders or {}) do
    if (b.uid == uid) then
      mine = b
    end
  end

  if (not mine) then
    return
  end

  self:BidInfo(uid, mine.kind or "M", mine.amount)

  if (not announce or not cfg:Announces("ann_bid_progress")) then
    return
  end

  -- A silent auction tells the raid how many are bidding and nothing more.
  if (cfg.settings.silent_bid) then
    self:SendText(strfmt(L["%s: new bid received. Number of bidders: %d."], L["MODTITLE"], #bidders))
    return
  end

  -- Raiders following the bid are shown it as the master looter is, and the raid chat line below is for those who are not.
  self.apol:CSendAM(cfg.id, "BIDAN", "ALERT", uid, mine.kind or "M", mine.amount or false)

  local top = bidders[1]
  local topname = K.ShortName(cfg:UserName(top.uid))

  if (mine.amount) then
    self:SendText(strfmt(L["%s: %s has bid %d (the highest bid is %d, by %s)."], L["MODTITLE"], K.ShortName(name),
      mine.amount, top.amount or 0, topname))
  else
    self:SendText(strfmt(L["%s: %s (%s) has bid (highest bidder is %s)."], L["MODTITLE"], K.ShortName(name),
      strfmt(self.apol:Str("BID_STANDING"), mine.standing or "?"), topname))
  end
end

--
-- A bid whispered to the master looter: CODE the kind the word named, "!os" off spec, and ARG whatever followed it. That is
-- the amount where the open bid takes one, and ignored where it does not, a raider in the habit of naming one having plainly
-- meant to bid. Anything but a whole number there is not a bid at all, and is answered with how to bid: "!bid os" is among
-- them, "!bid" being main spec and off spec a word of its own.
--
function konfer:WhisperedBid(uid, code, arg)
  local amount = nil

  if (arg and arg ~= "") then
    local n = strmatch(arg, "^(%d+)$")

    if (not n) then
      self:SendWhisper(strfmt(L["%s: that is not a bid. Whisper %s."], L["MODTITLE"], self:BidUsage()),
        self.apol.cfg:UserName(uid))
      return
    end

    amount = tonumber(n)
  end

  return self:NewBidder(uid, code, amount)
end

--
-- Tell NAME why their bid was refused, TEXT, signed with the mod's name. A bid made through the mod, VIAMOD, is answered
-- through it, as one of Konfer's own errors: the player's own here, and anybody else's sent back to them (BIDNO). One
-- whispered is whispered back.
--
function konfer:TellBidder(text, name, viamod)
  if (not viamod) then
    self:SendWhisper(text, name)
    return
  end

  local sig = L["MODTITLE"] .. ": "

  if (strsub(text, 1, strlen(sig)) == sig) then
    text = strsub(text, strlen(sig) + 1)
  end

  if (name == K.player.name) then
    self.apol:err("%s", text)
  else
    self.apol:CSendWhisperAM(self.apol.currentid, name, "BIDNO", "ALERT", text)
  end
end

--
-- Called when a raider whispers a bid or presses Bid on item (the bid arriving over the addon channel), and when the master
-- looter forces one. UID is the bidder, KINDNAME the kind of bid as its code, main spec when nil, and AMOUNT what they bid
-- where the open bid takes an amount. This verifies that the user is eligible to bid on the current item and that they meet
-- the filter requirements, and takes the bid when they are, the raid seeing it among the bidders. Somebody who fails any
-- of the checks is told that fact, and why: through the mod where VIAMOD says the bid came through it (TellBidder), and
-- otherwise in a whisper.
--
function konfer:NewBidder(uid, kindname, amount, viamod)
  --
  -- The reply lands in somebody else's chat frame, and is signed with the mod's name: which policy is running means nothing
  -- to a raider.
  --
  local nick = L["MODTITLE"]
  local u = self.apol.cfg:UserName(uid)

  --
  -- Somebody the config does not hold cannot be told so here, there being nobody to whisper. Whoever turned a name into a
  -- uid says that, which is chat_msg_whisper for a whispered bid and the button itself for a pressed one.
  --
  if (not u) then
    return
  end

  --
  -- The kind of bid, main spec unless they named another. One this config does not take, or a word that is no kind at all,
  -- is refused with the kinds it does take.
  --
  local kind = bid_kind_named(kindname)
  local taken = false

  for _, code in ipairs(bid_kinds(self.apol.cfg)) do
    if (code == kind) then
      taken = true
    end
  end

  if (not taken) then
    self:TellBidder(strfmt(L["%s: that kind of bid is not taken. Whisper %s."], nick, self:BidUsage()), u, viamod)
    return
  end

  -- First check. Am I the master looter?
  if (not self:AmIML()) then
    if (self:LootRunner()) then
      self:TellBidder(strfmt(L["%s: I am not the master looter - %q is."], nick, K.DisplayName(self:LootRunner())), u, viamod)
    else
      self:TellBidder(strfmt(L["%s: I am not the master looter."], nick), u, viamod)
    end
    return
  end

  --
  -- Second check. Do we even have a current bid going? One whose list was deleted from under it has nothing left to bid on,
  -- and neither has one whose item has gone: looting a second source resets the loot table, which can happen with a bid
  -- still open, and the index the bid was opened on then names nothing.
  --
  if (not biditem or not lootlistid or not lootitem or not self.raid.bossloot or not self.raid.bossloot[biditem]) then
    self:TellBidder(strfmt(L["%s: there is no item currently open for bids."], nick), u, viamod)
    return
  end

  --
  -- An amount where the open bid takes one, which a bid must then name, and nothing where it does not.
  --
  if (not openamounts) then
    amount = nil
  elseif (not amount) then
    self:TellBidder(strfmt(L["%s: a bid on this item needs an amount. Whisper %s."], nick, self:BidUsage()), u, viamod)
    return
  end

  local uname, uclass = self.apol.cfg:UserNameClass(uid)

  --
  -- Third check. Are they eligible to receive loot? Need to take into account that we may have no eligible looters because
  -- the raid leader had the wrong loot type set and has just changed it to master looter.
  --
  local slot = self.raid.bossloot[biditem].slot

  --
  -- If the loot was added manually with /konfer addloot it will have a slot of 0, which the API never returns. So we need to
  -- check for that here and avoid looking in KLD for the item because it isn't there. The other alternative is to change the
  -- KLD API to allow us to manually add things to the loot table, but that's more complicated so working around this for now.
  --
  local klid = nil

  --
  -- An item added by hand has no loot candidates to ask. It goes to somebody in the group or on the raid's standby, the
  -- master looter's to give, a BoE everybody is entitled to among it. Made up loot is looked at out of a group, so anybody
  -- the config holds may bid on it.
  --
  local outside = not (KRP.players and KRP.players[u]) and not self.apol.cfg:IsReserved(uid)

  outside = outside and not self.testloot -- @debug-delete@

  if (slot > 0) then
    if KLD.items and KLD.items[slot] then
      klid = KLD.items[slot]
    end

    if (not klid or not klid.candidates[u]) then
      self:TellBidder(strfmt(L["%s: you are not eligible to receive loot - %s ignored."], nick, L["bid"]), u, viamod)
      return
    end
  elseif (outside) then
    self:TellBidder(strfmt(L["%s: you are not eligible to receive loot - %s ignored."], nick, L["bid"]), u, viamod)
    return
  end

  --
  -- A list with nobody on it has no members table at all, and nobody bidding on it is a member.
  --
  local found = false
  for k,v in ipairs(members or {}) do
    if (v.id == uid) then
      found = true
      break
    end
  end

  if (not found) then
    local lootlist = self.apol.cfg.lists[lootlistid]

    self.apol:info(L["%q attempted to bid on the %q list but is not a member."],
      shortaclass(uname, uclass), white(lootlist.name))
    self:TellBidder(strfmt(L["%s: you are not a member of the %q list - bid ignored."], nick, lootlist.name), u, viamod)
    return
  end

  --
  -- The policy may refuse a bid of its own accord, EP/GP one from somebody below its minimum EP and DKP one for more than
  -- the bidder has, and says why.
  --
  local _, allowed, why = self.apol.cfg:PolicyCall("MayBid", true, lootlistid, uid, kind, amount, lootitem.loot.ilink)

  if (not allowed) then
    self:TellBidder(strfmt("%s: %s", nick, why or L["you may not bid on this item."]), u, viamod)
    return
  end

  --
  -- Fourth check. Have they already bid? The same bid again is refused. A bid of another kind or for another amount changes
  -- theirs, the checks below being made against the bid it becomes.
  --
  local already = nil

  for k,v in pairs(bidders) do
    if (v.uid == uid) then
      already = v
    end
  end

  --
  -- Who to whisper is whoever is taking the bids, which is this client: the master looter, or with made up loot and no group,
  -- the player playing one.
  --
  if (already and already.kind == kind and already.amount == amount) then
    self:TellBidder(strfmt(L["%s: you have already bid on that item. Whisper %s the word %q to retract your bid."],
      nick, K.DisplayName(K.player.name), self:WhisperCommand("retract")), u, viamod)
    return
  end

  -- Fifth check. Verify the user matches the currently selected class
  -- and role and rank filters. They are individual checks but we clump them together.
  if (not verify_user_class(u, uclass, L["bid"], viamod)) then
    return
  end

  --
  -- The guild rank filter, where this config filters by rank at all. Ranks sharing a place in the config's rank order are
  -- equivalent, so cfg:RankPermits is asked rather than the two rank indices compared: a filter naming any one of the
  -- ranks standing together admits every one of them. Somebody the guild roster does not hold has no rank to be measured,
  -- and a rank filter is a guild filter, so they do not pass one.
  --
  if (self.apol.cfg:RankFiltering() and lootitem.rank and lootitem.rank > 0) then
    local gi = K.guild.roster.name[u]
    local ri = gi and K.guild.roster.id[gi].rank or nil

    if (not self.apol.cfg:RankPermits(ri, lootitem.rank)) then
      self:TellBidder(strfmt(L["%s: you do not meet the current guild rank requirement (%q) - %s ignored."],
        nick, K.guild.ranks[lootitem.rank], L["bid"]), u, viamod)
      return
    end
  end

  --
  -- The role restriction holds a main spec bid to the first spec's role and an off spec bid to the second's, as it does a
  -- roll. Transmog and vanity are for somebody who wants the item whatever their spec, so no role is asked of them.
  --
  if ((kind == "M" or kind == "O") and not verify_user_role(uname, uclass, kind == "O", L["bid"], viamod)) then
    return
  end

  --
  -- All seems to be in order. Register the user's bid, or change the one they had in. A changed amount is news to the raid
  -- as a new bid is, and a changed kind is told as a roll changing kind is, where the config tells the raid how bids go,
  -- except in a silent auction, which names nobody.
  --
  if (already) then
    local raised = already.amount ~= amount
    local was = already.kind

    already.kind = kind
    already.amount = amount
    refresh_bidders(self)

    if (was ~= kind and not self.apol.cfg.settings.silent_bid and self.apol.cfg:Announces("ann_bid_progress")) then
      self:SendText(strfmt(L["%s: %s changed their %s bid to %s."], L["MODTITLE"], K.ShortName(uname),
        KIND_BY_CODE[was or "M"].phrase, KIND_BY_CODE[kind].phrase))
    end

    if (raised) then
      announce_bid(self, uid, true)
    end
  else
    self:AddBidder(uid, true, kind, amount)
  end

  -- A bid a moment before timed bids close holds them open a little longer.
  self:ExtendBidClock()
end

--
-- How to bid, for a sentence telling a raider: the word for each kind of bid the running config takes, "!ms, !os", and where
-- a bid takes an amount, a word saying one follows. While a bid is open it is the open bid's kinds that are taken.
--
function konfer:BidUsage()
  local cfg = self.apol.cfg
  local parts = {}

  for _, code in ipairs(bid_kinds(cfg)) do
    tinsert(parts, self:WhisperCommand(KIND_BY_CODE[code].whisper))
  end

  local usage = tconcat(parts, ", ")
  local amounts = openamounts

  if (amounts == nil) then
    amounts = bids_take_amounts(cfg)
  end

  if (amounts) then
    usage = strfmt(L["%s followed by your bid"], usage)
  end

  return usage
end

--
-- The master looter's: UID has bid, KIND being the kind of bid as its code and AMOUNT what they bid where the bid takes an
-- amount. They go among the bidders, which are ranked afresh and sent to the raid (refresh_bidders), and with ANNOUNCE the
-- raid is told in chat. A bidder is a uid and who they are is read back out of the config wherever they are drawn, so a
-- rename in the middle of a bid shows the new name at once.
--
function konfer:AddBidder(uid, announce, kind, amount)
  if (not bidders) then
    return
  end

  tinsert(bidders, { uid = uid, kind = kind or "M", amount = amount })
  refresh_bidders(self)
  announce_bid(self, uid, announce)
end

--
-- Everybody but the master looter: the bidders are ROWS, as the master looter ranked them, winner first, each { uid,
-- standing, kind, amount }. They replace whatever was shown, a raider's own copy of the list having no say in who stands
-- where.
--
function konfer:ShowBidders(rows)
  -- A raider who missed the bid opening, by reloading or joining late, has no bid to show. The master looter ranks its own.
  if (not bidders or type(rows) ~= "table" or self:AmIML()) then
    return
  end

  bidders = {}

  for _, row in ipairs(rows) do
    if (type(row) == "table" and row[1]) then
      tinsert(bidders, { uid = row[1], standing = row[2], kind = KIND_BY_CODE[row[3] or "M"] and row[3] or "M",
        amount = tonumber(row[4]) })
    end
  end

  refresh_bidders(self)
end

function konfer:RetractBidder(uid)
  local found = nil

  if (not self:AmIML()) then
    return
  end

  if (rolling) then
    --
    -- If we are rolling for an item and someone retracts, we need to remove them from the list of rollers.
    --
    return
  end

  -- No bid is open, so there is nothing to retract.
  if (not bidders) then
    return
  end

  for k,v in ipairs(bidders) do
    if (v.uid == uid) then
      found = k
      break
    end
  end

  if (found) then
    self:DeleteBidder(uid, true)
  end
end

--
-- The master looter's: UID has retracted. The raid is sent the bidders left (refresh_bidders), and with ANNOUNCE told in chat.
--
function konfer:DeleteBidder(uid, announce)
  local cfg = self.apol.cfg
  local name, class = cfg:UserNameClass(uid)
  local found = nil

  if (not bidders) then
    return
  end

  for k,v in ipairs(bidders) do
    if (v.uid == uid) then
      found = true
      tremove(bidders, k)
      break
    end
  end

  refresh_bidders(self)

  if (not found) then
    return
  end

  self:BidInfo(uid, false)

  if (not announce or not self.apol.cfg:Announces("ann_bid_progress")) then
    return
  end

  -- A silent auction tells the raid how many are bidding and nothing more.
  if (self.apol.cfg.settings.silent_bid) then
    self:SendText(strfmt(L["%s: bid retracted. Number of bidders: %d."], L["MODTITLE"], #bidders))
    return
  end

  -- Raiders following the bid are shown it as the master looter is, and the raid chat line below is for those who are not.
  self.apol:CSendAM(cfg.id, "BIDAN", "ALERT", uid, false, false)

  if (qf.bidscroll.itemcount > 0) then
    self:SendText(strfmt(L["%s: %s has retracted (highest bidder is %s)."], L["MODTITLE"], K.DisplayName(name),
      K.DisplayName(cfg:UserName(bidders[1].uid))))
  else
    self:SendText(strfmt(L["%s: %s has retracted (no other bidders)."], L["MODTITLE"], K.DisplayName(name)))
  end
end

--
-- The undo stack for awards this player made, newest first. It belongs to the raid: an award is undone in the minutes after
-- it is made, by the master looter who made it, and there is nothing to undo tomorrow. Which is why it lives in
-- konfer.raid and goes when that does.
--
-- A record is one award, { cfgid, uid, ilink, moves }. MOVES is what the policy's Award handed back, a { listid, token } for
-- each list it moved, the token opaque everywhere but inside that policy. CFGID is what the undo is made against, and the
-- rest is what the undo dialog puts on screen.
--
function konfer:PushUndo(rec)
  self.raid.undo = self.raid.undo or {}
  tinsert(self.raid.undo, 1, rec)
end

function konfer:UndoCount()
  return self.raid.undo and #self.raid.undo or 0
end

function konfer:PeekUndo()
  return self.raid.undo and self.raid.undo[1] or nil
end

function konfer:PopUndo()
  if (not self.raid.undo) then
    return nil
  end

  local rec = tremove(self.raid.undo, 1)

  if (#self.raid.undo < 1) then
    self.raid.undo = nil
  end

  return rec
end

--
-- UID has won ILINK on list LISTID. What that does to the standings is the policy's business and this is where the platform
-- asks: a suicide for Suicide Kings, gear points for EP/GP, a deduction for DKP.
--
-- RLIST is the raid-present subset of the list in list order. CHAIN says the award also applies to whatever extra list the
-- primary names, which a loot award does and a hand correction of the list does not. NOCMD is for an award another admin
-- already decided and sent us, and NOREFRESH for a caller replaying a batch who will refresh once at the end. COST is what
-- the master looter charged, from the costing box, and nil where the policy's own price stands.
--
-- The policy hands back one entry per list it actually moved, each carrying that list's id and a token the platform does not
-- read. The whole award is one undo record, so a chained award is put back in one go.
--
--
-- The second value is false when the policy's Award raised an error, which it has already reported. The caller then records
-- nothing about the win, since the policy cannot say what it did.
--
function cfgm:AwardItem(listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
  -- @debug-start@
  --
  -- Made up loot is decided and never awarded, an award being what moves a list. The bid or roll it closes still ends as it
  -- would, so that what happens can be seen, with nothing moved and nothing to undo, and the player is told so.
  --
  if (konfer.testloot and not nocmd) then
    konfer.apol:info(L["made up loot is not awarded."])
    return {}, true
  end
  -- @debug-end@

  local ok, moves = self:PolicyCall("Award", nil, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)

  if (not ok) then
    return nil, false
  end

  if (not moves or #moves < 1) then
    return nil, true
  end

  --
  -- An award another admin made and sent us is theirs to undo, and undoing it there reaches us as an event of its own.
  --
  if (nocmd) then
    return moves, true
  end

  konfer:PushUndo({ cfgid = self.id, uid = uid, ilink = ilink, moves = moves })

  if (konfer:AmIML() and self:IsActive() and qf.undobutton) then
    qf.undobutton:SetEnabled(true)
  end

  return moves, true
end

function cfgm:DeleteItem(itemid, nocmd)
  local il = self.items

  if (not il[itemid]) then
    return
  end

  il[itemid] = nil
  self.nitems = self.nitems - 1

  --
  -- RefreshItemList rebuilds the page from the config on screen and drops a selection that no longer exists, so the only
  -- question here is whether that is this config.
  --
  if (self:IsActive()) then
    konfer:RefreshItemList()
  end

  if (not nocmd) then
    self:AdminEvent("RMITM", itemid)
  end
end

--
-- Work out the class filter for an item. Returns the filter, and whether the client had the item data to hand (only the
-- tooltip scan needs it cached; GetItemInfoInstant never misses).
--
function konfer:DeriveItemClassFilter(itemlink)
  local ifs, _, cached = K.GetItemClassFilter(itemlink)

  if (ifs == K.classfilters.allclasses) then
    local slot, icls, isubcls = K.GetItemClassInfo(itemlink)
    if (icls == K.classfilters.weapon) then
      ifs = K.classfilters.weapons[isubcls]
    elseif (icls == K.classfilters.armor) then
      ifs = K.classfilters.strict[isubcls]
      if (slot == "INVTYPE_CLOAK") then
        ifs = K.classfilters.relaxed[isubcls]
      end
    end
  end

  return ifs or K.classfilters.allclasses, cached
end

function cfgm:AddItem(itemid, itemlink, nocmd, cfilter)
  local il = self.items

  if (il[itemid]) then
    return
  end

  -- CFILTER is the master looter's value, sent with MKITM.
  local ifs, cached = cfilter, true

  if (not ifs) then
    ifs, cached = konfer:DeriveItemClassFilter(itemlink)
  end

  il[itemid] = { ilink = itemlink, cfilter = ifs }
  self.nitems = self.nitems + 1

  --
  -- Provisional filters get redone when GET_ITEM_INFO_RECEIVED arrives. This is session data, so nothing provisional is
  -- written to disk.
  --
  if (not cached) then
    local csd = self:Session()

    csd.pendingitems = csd.pendingitems or {}
    -- Keyed by string id, valued with the key the items table actually uses.
    csd.pendingitems[tostring(itemid)] = itemid
    konfer:WatchPendingItems()
  end

  if (not nocmd) then
    self:AdminEvent("MKITM", itemid, itemlink, ifs)
  end

  if (self:IsActive()) then
    konfer:RefreshItemList()
  end
end

--
-- Put the loot history back on the page, from the config on screen.
--
function konfer:RefreshHistory()
  local pp = self.apol

  if (qf.histlist) then
    local nhist = 0

    -- Sorted every time, by whichever column the list is sorted on, since new loot may have arrived.
    if (pp and pp.cfg and pp.cfg.history) then
      nhist = #pp.cfg.history
      qf.histlist:Sort(pp.cfg.history)
    end

    qf.histlist:UpdateList(nhist)
    qf.histlist:SetSelected(nil, false, true)
    sync_history_buttons()
  end
end

--
-- The policy's history row for UID winning ILINK with an award on LISTID, VIA being how it was decided, KIND the kind of
-- bid or roll that won it, as its code, and COST what the master looter charged for it, nil where the policy's own price
-- stands (see HistoryEntry in Policy.lua). Asked before the award is made. Answers nil when the policy keeps no history or
-- gave back a HOW that is not its to give, lower case being the policy's and upper case the platform's.
--
function cfgm:PolicyHistory(via, listid, uid, ilink, kind, cost)
  local _, how, pdata = self:PolicyCall("HistoryEntry", nil, via, listid, uid, ilink, kind, cost)

  if (type(how) ~= "string" or not strmatch(how, "^%l")) then
    return nil
  end

  return how, pdata
end

--
-- A history row's How and What as the History tab draws them, with COLOUR, or as plain words to sort and export by. A
-- platform row is the platform's to say and a policy's row the policy's (HistoryText), an empty string from the policy
-- leaving that column to the platform. What is the item unless the policy says otherwise.
--
function cfgm:HistoryText(what, how, listid, pdata, colour)
  if (strmatch(how or "", "^%l")) then
    local _, htext, wtext = self:PolicyCall("HistoryText", nil, how, listid, pdata, colour)

    return (htext and htext ~= "") and htext or how, (wtext and wtext ~= "") and wtext or what
  end

  return histhow[how] or (colour and white("???") or "???"), what
end

--
-- Record that WHAT went to WHO, and tell everybody holding the config, raiders as well as admins, each of whom keeps and
-- trims a history of their own, a raider only where they asked to (konfer.chardb.recordhistory). A config that keeps no
-- history takes the event and stores nothing, that being a setting of the config's rather than each admin's own, so every
-- copy of it answers the same way.
--
-- LISTID is the list the item was given out on, and false for one given out with no list at all. A missing list is saved
-- as false rather than nil so that the row stays an unbroken array, PDATA after it being there or not.
--
function cfgm:AddLootHistory(when, what, who, how, listid, pdata, norefresh, nocmd)
  --
  -- IMPORTANT: If this changes, change Users.lua too in DeleteUser
  --

  -- @debug-start@
  -- Made up loot goes to nobody, so nothing about it is history.
  if (konfer.testloot and not nocmd) then
    return
  end
  -- @debug-end@

  listid = listid or false

  local ts = { tonumber(when), what, who, how, listid, pdata }

  if (self.settings.history) then
    tinsert(self.history, ts)
  end

  --
  -- RefreshHistory rebuilds the page from the config on screen, so the question is whether that is this config.
  --
  if (not norefresh and self:IsActive()) then
    konfer:RefreshHistory()
  end

  if (not nocmd) then
    self:AddEvent("LHADD", when, what, who, how, listid, pdata)
  end
end

--
-- ROWS, the loot history an admin broadcast (LHBCS), taken into this config's own: each row it does not hold already is
-- added and what it has is kept, a history being its holder's to keep and to trim.
--
function cfgm:TakeLootHistory(rows)
  if (type(rows) ~= "table" or not self.settings.history) then
    return
  end

  local function key(r)
    return strfmt("%s\001%s\001%s\001%s\001%s", tostring(r[1]), tostring(r[2]), tostring(r[3]), tostring(r[4]),
      tostring(r[5]))
  end

  local held = {}
  local added = false

  for _, r in ipairs(self.history) do
    held[key(r)] = true
  end

  for _, r in ipairs(rows) do
    if (type(r) == "table" and tonumber(r[1]) and type(r[2]) == "string" and type(r[3]) == "string"
      and type(r[4]) == "string" and not held[key(r)]) then
      held[key(r)] = true
      tinsert(self.history, { tonumber(r[1]), r[2], r[3], r[4], r[5] or false, r[6] })
      added = true
    end
  end

  if (added and self:IsActive()) then
    konfer:RefreshHistory()
  end
end

--
-- A raider who is no admin of CFG is asked whether to keep the loot history SENDER broadcast, ROWS, as a step for
-- konfer:InTurn. Ok takes it (cfg:TakeLootHistory), Never says this character ignores every such broadcast from now on
-- (konfer.chardb.ignorehistory, a box on the Options page that can be unticked), and Cancel or Escape lets this one go.
--
-- Whichever of Konfer's windows is up stands aside while it is asked and comes back however it is answered. The settings
-- window going away puts the foyer back, it standing in for the foyer, so the foyer is put away again as well and left away.
-- KUI hides the dialog before it throws OnAccept or OnCancel, so what is being answered is kept as LAST when it hides,
-- the next step in turn perhaps having put up another by then.
--
function konfer:OfferLootHistory(cfg, sender, rows)
  self:InTurn(function(after)
    if (self.chardb.ignorehistory) then
      return false
    end

    local dlg = qf.histoffer

    if (not dlg) then
      local WIDTH = 450

      dlg = KUI:CreateDialogFrame({
        x = "CENTER", y = "MIDDLE", name = "KonferHistoryOffer", title = "", border = true, width = WIDTH, height = 200,
        canmove = true, canresize = false, escclose = true, blackbg = true, okbutton = true, cancelbutton = true,
        padding = KUI.WIDGET_GAP,
      })

      -- The config it is about centred at the top, and the question under it, placed as a confirmation dialog places them.
      dlg.config = KUI:CreateStringLabel({ x = "CENTER", y = 0, font = "GameFontNormal", text = "" }, dlg)

      dlg.text = KUI:CreateStringLabel({
        x = 0, y = -31, width = WIDTH - dlg.rings.left - dlg.rings.right, autosize = false, font = "GameFontNormal",
        justifyh = "LEFT", justifyv = "TOP", text = "",
      }, dlg)

      -- Never stands between OK and Cancel.
      dlg.never = KUI:CreateButton({ width = 100, height = dlg.cancelbutton:GetHeight(), text = L["Never"] }, dlg)
      dlg.never:ClearAllPoints()
      dlg.never:SetPoint("BOTTOMRIGHT", dlg.cancelbutton, "BOTTOMLEFT", 0 - KUI.WIDGET_GAP, 0)
      dlg.okbutton:ClearAllPoints()
      dlg.okbutton:SetPoint("BOTTOMRIGHT", dlg.never, "BOTTOMLEFT", 0 - KUI.WIDGET_GAP, 0)

      dlg.never:Catch("OnClick", function(this)
        dlg:Hide()

        local cur = dlg.last

        if (cur) then
          dlg.last = nil
          konfer.chardb.ignorehistory = true
          konfer:RefreshOptionsUI()
        end
      end)

      dlg:Catch("OnAccept", function(this)
        local cur = this.last

        this.last = nil
        if (cur) then
          cur.cfg:TakeLootHistory(cur.rows)
        end
      end)

      dlg:Catch("OnCancel", function(this)
        this.last = nil
      end)

      dlg:Catch("OnHide", function(this)
        local cur = this.current

        this.current = nil
        this.last = cur

        if (not cur) then
          return
        end

        for _, win in ipairs(cur.away) do
          win:Show()
        end

        cur.after()
      end)

      qf.histoffer = dlg
    end

    local suid = cfg:FindUser(sender)
    local who = suid and shortaclass(cfg:UserNameClass(suid)) or K.DisplayName(sender)
    local away = {}

    for _, win in ipairs({ self.settingswin, self.foyerwin, self.mainwin }) do
      if (win and win:IsShown()) then
        tinsert(away, win)
      end
    end

    for _, win in ipairs(away) do
      win:Hide()
    end

    if (self.foyerwin and self.foyerwin:IsShown()) then
      self.foyerwin:Hide()
    end

    dlg.current = { cfg = cfg, rows = rows, away = away, after = after }
    dlg:SetTitleText(cfg:GetPolicy():WindowTitle(L["Received: Loot History"]))
    dlg.config:SetText(strfmt(L["Configuration: %s"], white(cfg.name)))
    dlg.text:SetText(strfmt(L["HISTORY_OFFER"], who, white(K.OK_STR), white(L["Never"]), white(K.CANCEL_STR)))

    local th = dlg.text.label:GetStringHeight()

    dlg.text:SetHeight(th)
    dlg:SetHeight(dlg.rings.top + th + dlg.rings.bottom + 78)
    dlg:Show()
    return true
  end)
end

function konfer:AddLoot(ilink, nocmd, price)
  local added = false

  if (self.raid.bossloot) then
    added = true
  end

  self:AddItemToBossLoot(ilink, 1, 0, price)
  self:RefreshBossLoot(selectedloot)

  if (not added) then
    --
    -- This is the only item. Possibly open the loot window and send out a faked OLOOT event (if we are sending events)
    --
    if (not nocmd) then
      self.apol:CSendAM(self.apol.currentid, "OLOOT", "ALERT", "0", false, { { ilink, 1, self:LootPrice(ilink) or false } })

      if (not self.mainwin:IsVisible()) then
        self.autoshown = true
      end
      self.mainwin:Show()
      self.mainwin:SetPage(self.LOOT_PAGE, self.LOOT_ASSIGN_TAB)
    end
  else
    if (not nocmd) then
      self.apol:CSendAM(self.apol.currentid, "ALOOT", "ALERT", ilink, self:LootPrice(ilink) or false)
    end
  end
end

--
-- Put an award back. MOVES is what the policy's Award handed back, one { listid, token } per list it moved, and only that
-- policy knows what is in a token. Each list is put back newest first, the reverse of the order the award made them in, and
-- taken out of MOVES as it is.
--
-- The item goes back on the loot list and the reversal is recorded in the history, once for the award however many lists it
-- moved. Both are the platform's business whatever the policy did to the standings, and both are done only where the undo
-- is made: the item going back reaches everyone else as ALOOT and the history row as LHADD. The row is the policy's where
-- it says what was given back (HistoryUndo in Policy.lua), and otherwise the platform's "U". An award made by hand, with no
-- item, has no loot to put back and wrote no history to reverse.
--
-- Answers false when the policy failed to put a list back, which it has reported. Nothing of the platform's is done then, and
-- MOVES holds the lists still to put back, so the same undo can be tried again.
--
function cfgm:UndoAward(uid, ilink, moves, nocmd)
  -- The undo names the list the award was made on, the first it moved, the rest being the lists it chained to.
  local listid = moves[1] and moves[1].listid
  local token = moves[1] and moves[1].token

  for i = #moves, 1, -1 do
    local ok = self:PolicyCall("UndoAward", nil, moves[i].listid, uid, ilink, moves[i].token, nocmd)

    if (not ok) then
      return false
    end

    tremove(moves, i)
  end

  if (ilink and not nocmd) then
    local _, how, pdata = self:PolicyCall("HistoryUndo", nil, listid, uid, ilink, token)

    if (type(how) ~= "string" or not strmatch(how, "^%l")) then
      how, pdata = "U", nil
    end

    konfer:AddLoot(ilink, false)
    self:AddLootHistory(K.time(), ilink, uid, how, listid, pdata)
  end

  return true
end

--
-- Open a roll on ILINK for TIMEOUT seconds. ALLOWOS, ALLOWMOG and ALLOWVANITY say whether it takes off spec, transmog and
-- vanity rolls, which are the master looter's config's to say and reach everybody else in OROLL, and AWARDS whether it
-- carries an award, which is what lets a raider's own roll buttons roll the range the policy has given them.
--
function konfer:StartOpenRoll(ilink, timeout, allowos, allowmog, allowvanity, awards)
  local isml = self:AmIML()

  warn_hidden_chat(self)

  if (isml and biditem) then
    self.apol:CSendAM(self.apol.currentid, "BIDCL", "ALERT", biditem)
  end

  biditem = nil
  openkinds = nil
  openamounts = nil
  self:StopBidClock()

  self:ResetBidList()

  lootroll = {}
  lootroll.rollers = {}
  lootroll.awards = awards and true or false
  lootroll.ilink = ilink

  rolling = 1
  sync_loot_panels()

  local bb = qf.bidders
  local rlf = qf.lootroll
  local takes = { [1] = true, [101] = allowos, [201] = allowmog, [301] = allowvanity }

  -- Roll offers the kinds this one takes. Retract waits until you have a roll in.
  rlf.takes = takes
  rlf.roll:SetEnabled(true)
  rlf.cancel:SetEnabled(false)
  rlf.SetTieText(nil)

  -- The roll pane in the bid pane's place, with Remove only for the master looter.
  bb.bidpane:Hide()
  bb.rollpane:Show()
  bb.rollpane.remove:SetShown(isml)

  self:ShowRollers({})

  lootroll.timeout = timeout
  lootroll.endtime = GetTime() + timeout + 1

  if (isml) then
    local st = self.apol.cfg.settings

    qf.lootroll:RegisterEvent("CHAT_MSG_SYSTEM")
    qf.lootroll:SetScript("OnEvent", function(this, evt, arg1, ...) rlf_onevent(self, this, evt, arg1, ...) end)
    qf.lootroll.timerbar:SetScript("OnUpdate", function() rolltimer_onupdate_ml(self) end)
    self.apol:CSendAM(self.apol.currentid, "OROLL", "ALERT", lootitem.loot.ilink, timeout, st.offspec_rolls, st.transmog_rolls,
      st.vanity_rolls, lootroll.awards)
  else
    qf.lootroll.timerbar:SetScript("OnUpdate", function() rolltimer_onupdate_user() end)
  end

  select_alf(ALF_ROLL)
end

function konfer:EndOpenRoll(noswitch)

  if (rolling) then
    if (self:AmIML()) then
      self.apol:CSendAM(self.apol.currentid, "EROLL", "ALERT")
    end
  end

  rolling = nil
  lootroll = nil
  rollrows = nil
  sync_loot_panels()

  qf.bidders.forcebid:SetEnabled(false)
  qf.bidders.forceret:SetEnabled(false)

  -- The bid pane again, and the roll pane put away empty.
  selectedroller = nil
  qf.rollscroll.itemcount = 0
  qf.rollscroll:UpdateList()
  qf.rollscroll:SetSelected(nil, false, true)
  qf.bidders.rollpane:Hide()
  qf.bidders.bidpane:Show()

  self:LabelBidsButton()
  qf.lootwin.orpause:SetText(L["Open roll"])
  qf.lootwin.remcancel:SetText(L["Remove"])
  qf.bidders.forcebid:SetText(L["Force bid"])
  qf.bidders.forceret:SetText(L["Force retract"])

  qf.lootroll:UnregisterEvent("CHAT_MSG_SYSTEM")
  qf.lootroll:SetScript("OnEvent", nil)
  qf.lootroll.timerbar:SetScript("OnUpdate", nil)
  qf.lootroll.SetTieText(nil)

  -- The buttons as the item on offer has them, its first roll or what the policy offers in its place included.
  lootbid_setenabled(selectedloot ~= nil)

  if (not noswitch) then
    select_alf(ALF_LOOT)
  end
end

function konfer:ChangeLootFilter(what, v1, v2)

  if (what == "C") then
    --
    -- The class arrives from another client, which may know a class this one does not, so a box we have no name for is a
    -- filter change there is nothing here to show rather than an error in the middle of a bid.
    --
    local ci = K.IndexClass[v1]
    local w = ci and ci.w

    if (w and qf.lootrules[w]) then
      qf.lootrules[w]:SetChecked(v2)
    end
  elseif (what == "R") then
    qf.lootrules.role:SetValue(v1)
  elseif (what == "G") then
    qf.lootrules.rank:SetValue(v1)
  elseif (what == "A") then
    -- The classes it put in the master looter's boxes come with it, a raider's loot not knowing them.
    qf.lootrules.strictarmour:SetChecked(v1)
    if (v2 and lootitem) then
      set_classes_from_filter(v2)
    end
  elseif (what == "L") then
    qf.lootrules.strictrole:SetChecked(v1)
  end
end

--
-- Called when the list of possible loot lists has changed. We will need to change any dropdowns that contain a list of
-- lists, as well as the list scroll itself. If the current list that is selected has been removed we will need to clear the
-- members list and bidders list too.
--
function konfer:RefreshLootLists(reset)
  local pp = self.apol

  if (qf.lists and pp and pp.cfg) then
    if (reset or (qf.selitemid and not pp.cfg.items[qf.selitemid])) then
      qf.selitemid = nil
    end

    -- The item editor's choices of list are the policy's own, refilled when it is told about the item.
    item_selection()

    refresh_loot_lists(self)
  end
end

--
-- The config the loot session in progress is being run against, which is whatever the active policy had in hand when the
-- session was last started afresh.
--
local sessioncfg = nil

--
-- End the loot session: no list, no item, no bid or roll, and nothing on the corpse.
--
-- A roll is taken down through EndOpenRoll rather than by clearing lootroll here, because a roll is more than that one
-- variable. It is also the rolling state, the system chat the master looter is listening to, and the buttons on the roll
-- frame. Clearing the table and leaving the rest standing left the hook live with nothing behind it, and the next
-- /roll anybody typed went looking for rollers in a table that had gone. NOSWITCH because the panel is put back below.
--
local function end_loot_session(self)
  self:EndOpenRoll(true)

  -- A win still in the costing box has nothing left to be given.
  if (qf.costingdlg and qf.costingdlg:IsShown()) then
    qf.costingdlg.win = nil
    qf.costingdlg:Hide()
  end

  lootlistid = nil
  members = nil
  memberid = nil
  selectedbidder = nil
  selectedbiduid = nil
  sessioncfg = self.apol.currentid

  hide_popup()
  select_alf(ALF_LOOT)

  self:ResetBossLoot()
end

function konfer:CloseLoot()
  end_loot_session(self)
  self:RefreshLootUI(false)
end

-- @debug-start@
--
-- /konfer testloot [itemid ...] puts made up loot on the Assign loot tab, as though this client were master looter and had
-- opened a corpse, so that the page can be seen and used with something in it. /konfer testloot off takes it away again.
--
-- Nothing about it leaves the machine: pretending in Policy.lua stops the policy's loot traffic, the mod's chat is shown
-- rather than said (MakeSends), it is refused in a group, hand_out gives none of it to anybody, and cfg:AwardItem awards
-- none of it, so no list moves. Bids and rolls on it still end as they would, so what happens can be seen.
-- Being out of a group, anybody the config holds may bid on it.
--
local TEST_LOOT = { 19019, 17182, 16922, 18814, 16901, 19137 }

function konfer:TestLoot(input)
  input = input or ""

  if (input == "off") then
    self.testloot = nil
    self:CloseLoot()
    return
  end

  -- A raid made up by /konfer testraid is nobody's but this client's, and is what made up loot is for trying out in.
  if (KRP.in_party and not KRP.pretend) then
    self.err(L["leave the group before making up loot."])
    return
  end

  if (not self:PolicyAdmin(self.apol)) then
    self.err(L["only an admin of the active configuration can make up loot."])
    return
  end

  local ids = {}

  for w in gmatch(input, "%d+") do
    tinsert(ids, tonumber(w))
  end

  if (#ids == 0) then
    ids = TEST_LOOT
  end

  self:CloseLoot()
  self.testloot = true

  for _, id in ipairs(ids) do
    local iname, ilink = C_Item.GetItemInfo(id)

    if (iname and iname ~= "") then
      self:AddItemToBossLoot(ilink, 1, 0)
    else
      self.err(L["still retrieving information for item %d. Please try again in a moment."], id)
    end
  end

  self:RefreshLootUI(false)
  self.mainwin:Show()
  self.mainwin:SetPage(self.LOOT_PAGE, self.LOOT_ASSIGN_TAB)
end
-- @debug-end@

-- @debug-start@
--
-- /konfer testraid makes up a raid of the active config's users, led and master looted by this client (KRP:PretendGroup),
-- so that what a raid does with its loot can be tried out alone, /konfer testloot putting loot in front of it.
-- /konfer testraid off ends it. Nobody in it is there to be told anything, so Kore shows its chat instead of saying it.
--
-- It is this character and up to 39 others: the config's users first, tonight's three enchanters first among them, the
-- config's disenchanters, then its raid enchanters, then anybody, so that there are three whatever the config says. They are
-- tonight's only, set without telling anybody, and the config is not touched. A config with fewer than 39 others, which a
-- PUG config nearly always is, has the raid filled up by name from the people Kore knows that it does not hold, strangers to
-- it as a pickup raid's are, for Add missing to put in.
--
function konfer:TestRaid(input)
  if ((input or "") == "off") then
    KRP:PretendGroup(nil)
    return
  end

  if (KRP.in_party and not KRP.pretend) then
    self.err(L["leave the group before making up a raid."])
    return
  end

  local cfg = self.apol and self.apol.cfg

  if (not cfg or not self:PolicyAdmin(self.apol)) then
    self.err(L["only an admin of the active configuration can make up a raid."])
    return
  end

  local dench = {}
  local set = cfg.settings.denchers or {}

  for i = 1, self.MAX_DENCHERS do
    if (set[i] and cfg.uids[set[i]]) then
      dench[set[i]] = 2
    end
  end

  local others = {}

  for uid in pairs(cfg.uids) do
    if (cfg:UserName(uid) ~= K.player.name) then
      tinsert(others, uid)
      dench[uid] = dench[uid] or (cfg:IsEnchanter(uid) and 1) or 0
    end
  end

  tsort(others, function(a, b)
    if (dench[a] ~= dench[b]) then
      return dench[a] > dench[b]
    end

    return cfg:UserName(a) < cfg:UserName(b)
  end)

  local roster = {}

  for i = 1, math.min(#others, 39) do
    local name, cls = cfg:UserNameClass(others[i])

    tinsert(roster, { name = name, class = cls, level = KU:Level(cfg.uids[others[i]][konfer.CFGUSER_KUID]) })
  end

  local strangers = {}

  for kuid, name in pairs(KU.kuids) do
    if (name ~= K.player.name and not cfg:FindKuid(kuid)) then
      tinsert(strangers, kuid)
    end
  end

  tsort(strangers, function(a, b)
    return KU.kuids[a] < KU.kuids[b]
  end)

  for _, kuid in ipairs(strangers) do
    if (#roster >= 39) then
      break
    end

    tinsert(roster, { name = KU.kuids[kuid], class = KU:Class(kuid), level = KU:Level(kuid) })
  end

  KRP:PretendGroup(roster)

  -- The first three are tonight's enchanters, and with fewer than three others this character makes up the number.
  local me = cfg:MyUid()

  for i = 1, self.MAX_DENCHERS do
    local uid = others[i]

    if (not uid and me) then
      uid, me = me, nil
    end

    cfg:SetRaidDencher(i, uid, true)
  end

  self.info(L["made up a raid of %d."], #roster + 1)
end
-- @debug-end@

function konfer:RefreshLootUI(reset)

  --
  -- A reset redraws everything from nothing, and ends the loot session only when that session belongs to some config other
  -- than the active one. A sync completing, or a config being copied or recovered, asks for a reset too, and none of those is
  -- a reason to cancel the bid or roll the master looter is running. The item editor's selection belongs to each window
  -- rather than to the raid, so clearing it is per window and RefreshItemList does it.
  --
  if (reset and sessioncfg ~= self.apol.currentid) then
    end_loot_session(self)
  end

  if (qf.lists) then
    refresh_loot_lists(self)
  end

  refresh_bidders(self)
  self:RefreshHistory()
  self:RefreshItemList()
  self:RefreshLootMembers()
  self:RefreshBossLoot(selectedloot)

  if (qf.undobutton) then
    qf.undobutton:SetEnabled((self:UndoCount() > 0 and self:AmIML()) and true or false)
  end
end
