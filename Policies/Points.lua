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

if (not K) then
  return
end

local konfer = K:GetAddon("Konfer")
local L = konfer.L
local KUI = konfer.KUI
local KRP = LibStub:GetLibrary("KoreParty")
local KC = konfer.KC
local KU = K.Users
local JSON = LibStub:GetLibrary("LibJsonLua")

local white = konfer.white
local shortaclass = konfer.shortaclass

local _G = _G
local tostring, tonumber, type = tostring, tonumber, type
local pairs, ipairs, next, select, unpack = pairs, ipairs, next, select, unpack
local strfmt = string.format
local strmatch = string.match
local strlower = string.lower
local strupper = string.upper
local strgsub = string.gsub
local strsub = string.sub
local gmatch = string.gmatch
local tinsert = table.insert
local tremove = table.remove
local tconcat = table.concat
local tsort = table.sort
local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min
local GetTime = GetTime
local GetDifficultyInfo = GetDifficultyInfo

--
-- Points policies: EP/GP and DKP, each keeping a number or two for every member of a list that the raid earns and loot spends.
--
-- Both earn the same way. Points go to everybody in the raid, and a share of them to those on standby, for whatever the
-- config's awards say, a boss kill offering one, on a timer, or by hand, and every so often a percentage comes off
-- everybody's to keep the numbers from growing without end. Both price an item the same way, by its slot and its level or
-- by a fixed price for each slot, with the item editor's value in place of either. What differs is what the numbers are and
-- what winning does to them, and that is each policy's own: EP/GP ranks by the ratio of two numbers and charges the second,
-- DKP ranks by one and spends it.
--
-- So this file is the half they share, and neither policy is a special case of the other. A policy hands points:Setup a
-- SPEC saying what its numbers are and what its own words for everything are, before it registers, and hands points:Events
-- the registered policy for the events the shared half sends. Each keeps its own event names: an award of EP and an award
-- of DKP are different events of different policies that happen to be answered by the same code.
--
-- SPEC is:
--   tag        what the frames built here are named with, "Konfer" .. TAG .. "AwardDialog"
--   fields     the numbers a member of a list has, in the order they travel, { "ep", "gp" } or { "dkp" }
--   earn       which of them an award adds to, which a journal entry for an award also records its amount under
--   charge     which of them winning an item moves, the price added to GP or taken off DKP
--   decays     which of them a decay takes its percentage off
--   decaybase  (cfgid) -> { field = base }, for a policy where a number decays towards a base rather than towards nothing,
--              EP/GP's GP towards base GP (ApplyDecay). Nil for none
--   decayswitch the setting that turns decay on, for a policy where decaying at all is the config's choice. A policy that
--              names none always decays
--   floors     (cfgid) -> { field = least }, for each number that never falls below some amount, EP/GP's EP and DKP's
--              balance below nothing unless the config lets it go negative: a penalty bigger than what a member has, or a
--              number set by hand below it, leaves them at the least. Nil for none
--   events     the policy's names for the seven events sent here: award, set, decay, timer, timerq, awset and awdel
--   clm        what a Classic Loot Manager roster of this policy's kind is, for importing one: { type = CLM's point type,
--              numbers = function(player, config) -> the player's FIELDS }, PLAYER and CONFIG being an exported player
--              and the roster's settings. Nil for a policy CLM has nothing like
--   words     the policy's own words for what is shown here, by key:
--                FIELDS          { field = label } for each of FIELDS, what the Adjust dialog and the journal call them
--                AWARDED         "%d EP awarded on %q to %d members. %s"
--                AWARD_FROZEN    "%s is frozen and earns no EP."
--                AWARD_NOTRAID   an award to the raid made while in none
--                AWARD_NOBODY    an award whose choice of who matches nobody
--                TIMED_REASON    what timed points are awarded for
--                BOSS_NOLIST     "%s died, but there is no list selected to award EP on."
--                AWARD_TITLE     "Award EP on %s", the award dialog's title
--                DECAY_TITLE     the decay dialog's title
--                PANEL_TITLE     the Lists page panel's title
--                AWARD_BUTTON    "Award EP"
--                TIMER_START     "Start timed EP"
--                TIMER_STOP      "Stop timed EP"
--                TIMED_EVERY     "%d EP every %s", what timed points award and how often
--                TIP_AWARD, TIP_ADJUST, TIP_DECAY, TIP_TIMER, TIP_AWARDFILTER, TIP_CUSTOM   the tooltips
--                JOURNAL_AWARDED "%d EP awarded by %s"
--                JOURNAL_HELP    what the journal command says it does
--                AWARD_HELP      what the award command says it does
--                TIME_AMOUNT, TIME_EVERY   "Timed EP" and "EP every", the words before a list's two timed boxes
--                DOUBLES         "GP doubles every (levels)"
--                UNIT            "GP", what the classic formula works out and what a price on an item's tooltip is in
--                LIFE_EARNED     "Lifetime EP", a member's tooltip's word for what they have earned
--                LIFE_CHARGED    "Lifetime GP", and for what they have been charged
--                ADV_WARNING, COSTING_CLASSIC, COSTING_EXAMPLE, COSTING_FIXED   the Advanced tab's explanations
--                CUSTOM_PRICE    "Custom GP value"
--
-- What it builds onto the policy is documented where each piece is made. The policy's own hooks, Order, RankBidders, Award
-- and the rest, are its own, and any method of the same name it defines itself is left alone.
--
local points = konfer.points

--
-- THE PRICE OF AN ITEM
--
-- What a slot with a gear value of 1 costs: the classic formula's price at the standard item level, and the fixed model's
-- price. Both points policies count in it, so that GP and DKP are the same size, and it is what EP/GP's base GP starts at,
-- one standard item.
--
local PRICE_BASE = 100

points.PRICE_BASE = PRICE_BASE

--
-- The item slots gear is priced by, each with the equip locations that fall in it and its multiplier, which is the gear
-- value a config starts with under the classic costing model and, times PRICE_BASE, the price it starts with under the
-- fixed. The multipliers are the original EPGP's, but for neck, back, wrist and finger at 0.5 rather than its 0.56, and
-- the relic's 0.667 rounded to fit the four characters a value is typed in. OTHER is everything with no slot of its own, a
-- tier token among them.
--
local SLOTS = {
  { key = "HEAD",     mult = 1,     locs = { "INVTYPE_HEAD" } },
  { key = "NECK",     mult = 0.5,   locs = { "INVTYPE_NECK" } },
  { key = "SHOULDER", mult = 0.75,  locs = { "INVTYPE_SHOULDER" } },
  { key = "CLOAK",    mult = 0.5,   locs = { "INVTYPE_CLOAK" } },
  { key = "CHEST",    mult = 1,     locs = { "INVTYPE_CHEST", "INVTYPE_ROBE" } },
  { key = "WRIST",    mult = 0.5,   locs = { "INVTYPE_WRIST" } },
  { key = "HAND",     mult = 0.75,  locs = { "INVTYPE_HAND" } },
  { key = "WAIST",    mult = 0.75,  locs = { "INVTYPE_WAIST" } },
  { key = "LEGS",     mult = 1,     locs = { "INVTYPE_LEGS" } },
  { key = "FEET",     mult = 0.75,  locs = { "INVTYPE_FEET" } },
  { key = "FINGER",   mult = 0.5,   locs = { "INVTYPE_FINGER" } },
  { key = "TRINKET",  mult = 1.25,  locs = { "INVTYPE_TRINKET" } },
  { key = "WEAPON",   mult = 1.5,   locs = { "INVTYPE_WEAPON" } },
  { key = "2HWEAPON", mult = 2,     locs = { "INVTYPE_2HWEAPON" } },
  { key = "MAINHAND", mult = 1.5,   locs = { "INVTYPE_WEAPONMAINHAND" } },
  { key = "OFFHAND",  mult = 0.5,   locs = { "INVTYPE_WEAPONOFFHAND", "INVTYPE_HOLDABLE" }, label = L["Off hand"] },
  { key = "SHIELD",   mult = 1.5,   locs = { "INVTYPE_SHIELD" }, label = L["Shield"] },
  { key = "RANGED",   mult = 2,     locs = { "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT" } },
  { key = "THROWN",   mult = 0.5,   locs = { "INVTYPE_THROWN" } },
  { key = "RELIC",    mult = 0.67,  locs = { "INVTYPE_RELIC" } },
  { key = "OTHER",    mult = 1,     locs = {}, label = L["Other"] },
}

--
-- The two costing models. Classic prices an item by the formula, its slot's gear value a multiplier of what that comes to;
-- fixed makes the gear value the price itself, whatever the item's level.
--
local COST_CLASSIC = "classic"
local COST_FIXED = "fixed"

points.COST_CLASSIC = COST_CLASSIC
points.COST_FIXED = COST_FIXED

-- Slot S's gear value to start with under MODEL: its multiplier, or under the fixed model the price that makes.
local function slot_default(s, model)
  if (model == COST_FIXED) then
    return floor(PRICE_BASE * s.mult + 0.5)
  end

  return s.mult
end

local SLOT_OF = {}

for _, s in ipairs(SLOTS) do
  for _, loc in ipairs(s.locs) do
    SLOT_OF[loc] = s.key
  end
end

--
-- The item level an item costs exactly its slot's multiplier times PRICE_BASE at, the first raid tier's of each game.
-- The price doubles for every ilvl_denom levels above it and halves for as many below. Both are the config's to change.
--
local STANDARD_ILVL = { [0] = 66, [1] = 115, [2] = 200, [3] = 359, [4] = 463 }

--
-- The settings the shared half reads, in each policy's cfg.psettings beside its own and carried between admins as PSSET
-- with them, and what they are unless the policy's defaults say otherwise. Every slot's price_ setting is added to these
-- by points:Setup, from the policy's own costing model.
--
points.DEFAULTS = {
  standby_pct = 100,      -- What somebody on standby gets of an award to the raid, as a percentage
  decay_pct = 10,         -- What a decay takes off, the default in the Decay dialog
  cost_model = COST_FIXED, -- How an item's price is worked out, COST_FIXED or COST_CLASSIC
  std_ilvl = STANDARD_ILVL[K.EXPANSION] or 640,
  ilvl_denom = 30,
  mult_O = 0.8,           -- What an off spec win costs, as a fraction of the main spec price
  mult_T = 0.7,           -- Transmog
  mult_V = 0.7,           -- Vanity
}

local function num(pol, which, cfgid)
  return tonumber(pol:Setting(which, cfgid)) or tonumber(pol.defaults[which]) or 0
end

--
-- AWARDS
--
-- What a config awards points for, made on the Admin tab and chosen from whenever points are awarded by hand or a boss dies.
-- Each is a description, which the journal records it as, an amount, and who it is for as the award dialog's Award to and
-- Filter have it: the whole list, or those matching some ticks, from the raid, the raid and standby, or everybody, guild
-- members only or not. Who is picked by name, and the member selected, are tonight's people, chosen when it is awarded and
-- never kept.
--
-- They are the policy's data on the config (cfg:PolicyData), awards, a table of id to { d, a, p, g, t }: the description,
-- the amount, the pool (AwardPoints), the guild, "in", "out" or nil, and the set of ticks, nil for none. Each is set and
-- deleted by an event of its own, the entry and nothing else, so two admins changing two awards change the two they changed.
--
-- An id is made as a list's is, KC.CreateNewID, so two admins making one at once never give out the same id, and one is
-- never given twice, so a list whose boss kill award (its list option boss_award) has been deleted finds none rather than
-- whatever was made after it. A new config starts with four whose ids are words, which a made id never is: BOSS_AWARD,
-- what every list's boss kill starts on, and WIPE_AWARD, what every list's wipe on a boss starts on, among them.
--
local BOSS_AWARD = "boss"
local WIPE_AWARD = "wipe"
local AWARD_POOLS = { active = true, standby = true, everyone = true }
local AWARD_GUILDS = { ["in"] = true, out = true }

points.CONFIGDATA = {
  awards = {
    [BOSS_AWARD] = { d = L["Boss kill"], a = 10, p = "standby" },
    [WIPE_AWARD] = { d = L["Boss wipe"], a = 1, p = "active" },
    ontime = { d = L["On time"], a = 5 },
    finish = { d = L["Raid finished"], a = 5 },
  },
}

-- AW as it is kept, or nil where it is not an award at all, another admin's word for one being taken as it arrived.
local function clean_award(aw)
  if (type(aw) ~= "table" or type(aw.d) ~= "string" or not tonumber(aw.a)) then
    return nil
  end

  local ticks = {}

  if (type(aw.t) == "table") then
    for k, v in pairs(aw.t) do
      if (type(k) == "string" and v) then
        ticks[k] = true
      end
    end
  end

  return { d = aw.d, a = tonumber(aw.a), p = AWARD_POOLS[aw.p] and aw.p or "standby", g = AWARD_GUILDS[aw.g] and aw.g or nil,
    t = next(ticks) and ticks or nil }
end

-- The table CFG keeps its awards in.
local function award_table(pol, cfg)
  local pd = cfg:PolicyData(pol.handle)

  if (type(pd.awards) ~= "table") then
    pd.awards = {}
  end

  return pd.awards
end

-- CFGID's awards, each as clean_award has it.
local function awards_of(pol, cfgid)
  local cfg = konfer:PolicyConfig(pol, cfgid)
  local out = {}

  if (not cfg) then
    return out
  end

  for id, aw in pairs(award_table(pol, cfg)) do
    out[id] = (type(id) == "string") and clean_award(aw) or nil
  end

  return out
end

--
-- AWARDS, as awards_of has them, as { id, aw, a, d } in the order they are offered in: by description, then by id. A and D
-- are the award's amount and description again, the names a column list sorts its rows by.
--
local function sorted_awards(awards)
  local out = {}

  for id, aw in pairs(awards) do
    tinsert(out, { id = id, aw = aw, a = aw.a, d = aw.d })
  end

  tsort(out, function(a, b)
    local da, db = strlower(a.aw.d), strlower(b.aw.d)

    if (da ~= db) then
      return da < db
    end

    return a.id < b.id
  end)

  return out
end

-- The choice of AWARDS a dropdown offers, FIRST before them all, standing for none of them, with the value "0".
local function award_choices(awards, first)
  local items = { { text = first, value = "0" } }

  for _, s in ipairs(sorted_awards(awards)) do
    tinsert(items, { text = s.aw.d, value = s.id })
  end

  return items
end

--
-- The methods every points policy is given, each called on the policy, so SELF is the policy throughout.
--
local P = {}

--
-- STANDINGS
--
-- Who on LISTID answers for UID, which is UID, or on a tethered list their main, whose numbers they are. Nil for somebody the
-- list does not hold.
--
local function member_of(cfg, listid, uid)
  local ison, muid = cfg:UserOrAltInList(uid, listid)

  return ison and muid or nil
end

points.MemberOf = member_of

--
-- The list the policy is working on, the one picked on the Lists page or else the config's default, which a boss kill
-- awards on and the Raid page shows everybody's numbers on. Nil for neither.
--
function P:CurrentList()
  local cfg = self.cfg
  local listid = (self.panel and self.panel.listid) or (cfg and cfg.settings.def_list)

  return (cfg and listid and cfg.lists[listid]) and listid or nil
end

--
-- LIFETIME TOTALS
--
-- Beside a member's numbers on a list, kept with them in the list's standings and never decayed: everything they have been
-- awarded (earned, penalties taking it down), everything they have been charged for loot (charged, an undone charge
-- taking it back), and what each decay has taken off each number that decays (decayed_ep, decayed_gp, decayed_dkp). Only
-- awards, charges and decay move them. Numbers set by hand, or brought by somebody put on a list, move the numbers alone.
--
-- They are a list's, as the numbers are, so a config's Friday run is kept apart from its main raid by being a list of its
-- own, and on a tethered list they are the main's. Every admin moves them from the same events, so they agree as the
-- numbers do, and a config travelling whole carries them beside the numbers.
--
local function lifetime_keys(pol)
  local keys = { "earned", "charged" }

  for _, f in ipairs(pol.points.decays) do
    tinsert(keys, "decayed_" .. f)
  end

  return keys
end

-- N more of what lifetime total KEY counts, on the standings record ST.
local function add_lifetime(st, key, n)
  st[key] = (st[key] or 0) + (tonumber(n) or 0)
end

-- What a member was awarded, and what a member was charged, each added to its lifetime total. A policy's own awards and
-- charges, DKP's zero-sum shares among them, come through these.
function points.Earned(st, n)
  add_lifetime(st, "earned", n)
end

function points.Charged(st, n)
  add_lifetime(st, "charged", n)
end

--
-- UID's lifetime totals on LISTID of CFGID, their main's on a tethered list: { earned, charged, decayed = { field = n } }.
-- Nil for somebody the list does not hold.
--
function P:Lifetime(cfgid, listid, uid)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local muid = cfg and cfg.lists[listid] and member_of(cfg, listid, uid)

  if (not muid) then
    return nil
  end

  local st = self:Standings(cfgid, listid, muid)
  local out = { earned = st.earned or 0, charged = st.charged or 0, decayed = {} }

  for _, f in ipairs(self.points.decays) do
    out.decayed[f] = st["decayed_" .. f] or 0
  end

  return out
end

--
-- WHAT THIS POLICY SAYS ABOUT SOMEBODY ON A LIST
--
-- Their numbers, in the order the spec gives them, then their lifetime totals in the order lifetime_keys gives them, which
-- is what IMLST carries. The array's order means nothing to a points policy, so somebody put on a list always goes on the
-- bottom and stands wherever their numbers put them.
--
local function numbers_of(pol, cfgid, listid, uid)
  local st = pol:Standings(cfgid, listid, uid)
  local out = {}

  for i, f in ipairs(pol.points.fields) do
    out[i] = st[f] or 0
  end

  for _, k in ipairs(lifetime_keys(pol)) do
    tinsert(out, st[k] or 0)
  end

  return out
end

local function take_numbers(pol, st, v)
  local nf = #pol.points.fields

  for i, f in ipairs(pol.points.fields) do
    st[f] = tonumber(v[i]) or 0
  end

  for i, k in ipairs(lifetime_keys(pol)) do
    st[k] = tonumber(v[nf + i]) or 0
  end
end

function P:MemberInfo(cfgid, listid, uid)
  return numbers_of(self, cfgid, listid, uid)
end

function P:SetMemberInfo(cfgid, listid, uid, pdata)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local rl = cfg.lists[listid]
  local st = self:Standings(cfgid, listid, uid)

  tinsert(rl.users, uid)

  if (type(pdata) == "table") then
    take_numbers(self, st, pdata)
  end

  return numbers_of(self, cfgid, listid, uid)
end

--
-- A whole list's worth: every member's numbers, the list's journal and when it was last decayed, for a config travelling
-- whole. The journal (rl.journal) and the time (rl.lastdecay) are the list's own and set only by this policy's events.
--
function P:ListInfo(cfgid, listid)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local rl = cfg and cfg.lists[listid]

  if (not rl) then
    return nil
  end

  local s = {}

  for _, uid in ipairs(rl.users) do
    s[uid] = numbers_of(self, cfgid, listid, uid)
  end

  return { s = s, j = rl.journal, d = rl.lastdecay }
end

function P:SetListInfo(cfgid, listid, pdata)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local rl = cfg and cfg.lists[listid]

  if (not rl or type(pdata) ~= "table") then
    return
  end

  for uid, v in pairs(pdata.s or {}) do
    if (type(v) == "table") then
      take_numbers(self, self:Standings(cfgid, listid, uid), v)
    end
  end

  if (type(pdata.j) == "table") then
    rl.journal = K.CopyTable(pdata.j, {})
  end

  rl.lastdecay = tonumber(pdata.d)
end

--
-- What ILINK costs to win as KIND. The price the master looter gave it as bids opened, where the policy lets them (setprice in
-- Policy.lua, konfer:BidPrice), else the item's custom value where the item editor gives it one. Otherwise, under the classic
-- costing model, its slot's gear value times PRICE_BASE, doubling every ilvl_denom item levels above the config's
-- standard, and under the fixed model its slot's gear value as it stands. Then the kind's own multiplier for anything that
-- is not main spec. Nil for an item the game cannot yet say anything about.
--
-- A token's slot is the slot of the gear it turns into (konfer:TokenEquipLoc), at the token's own item level. One that turns
-- into more than one slot has none, and costs what OTHER does.
--
function P:ItemPrice(cfgid, ilink, kind)
  if (not ilink) then
    return nil
  end

  local cfg = konfer:PolicyConfig(self, cfgid)
  local itemid = strmatch(ilink, "item:(%d+)")
  local ii = cfg and itemid and cfg.items and cfg.items[itemid]
  local price = (self.setprice and konfer:BidPrice(self, cfgid, ilink)) or (ii and tonumber(ii.pdata))

  if (not price) then
    local _, _, _, ilvl, _, _, _, _, equiploc = C_Item.GetItemInfo(ilink)

    if (not ilvl) then
      return nil
    end

    local slot = SLOT_OF[konfer:TokenEquipLoc(itemid) or equiploc or ""] or "OTHER"

    price = num(self, "price_" .. slot, cfgid)

    if (self:Setting("cost_model", cfgid) ~= COST_FIXED) then
      local denom = num(self, "ilvl_denom", cfgid)

      if (denom <= 0) then
        denom = 30
      end

      price = PRICE_BASE * 2 ^ ((ilvl - num(self, "std_ilvl", cfgid)) / denom) * price
    end
  end

  if (kind and kind ~= "M") then
    price = price * num(self, "mult_" .. kind, cfgid)
  end

  return floor(price + 0.5)
end

--
-- WHAT THE TOOLTIPS SAY
--
-- An item's tooltip (ItemTooltip in Policy.lua): what ILINK costs on CFGID as each kind of bid the config takes. Where bids
-- name an amount (BidAmounts), it is the least each may bid instead (MinimumBid), titled so, and nothing for a kind the
-- config sets no least for. Transmog and vanity costing the same, as they do unless their multipliers differ, are one
-- line. Nil where there is nothing to say, an item the game cannot price yet among them.
--
function P:ItemTooltip(cfgid, ilink)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (not cfg) then
    return nil
  end

  local least = self.MinimumBid and self.BidAmounts and self:BidAmounts(cfgid)
  local lines = {}
  local at = {}

  for _, k in ipairs(konfer:BidKinds(cfg)) do
    local n

    if (least) then
      n = self:MinimumBid(cfgid, ilink, k.code)
    else
      n = self:ItemPrice(cfgid, ilink, k.code)
    end

    if (n) then
      tinsert(lines, { k.name, strfmt("%d %s", n, self.points.words.UNIT), n = n })
      at[k.code] = #lines
    end
  end

  if (#lines == 0) then
    return nil
  end

  -- Vanity always comes after transmog, so taking its line out leaves transmog's where it was.
  if (at.T and at.V and lines[at.T].n == lines[at.V].n) then
    lines[at.T][1] = L["Transmog / vanity"]
    tremove(lines, at.V)
  end

  return { title = strfmt(least and L["%s minimum bids (%s)"] or L["%s prices (%s)"], self.name, cfg.name), lines = lines }
end

--
-- A member's tooltip on LISTID (UserTooltip in Policy.lua): each of their numbers as it stands, then what they have earned
-- and been charged in their lifetime, each only where it says something: never a total of nothing, and never one the same
-- as the number it stands beside, which is the number awards add to for what was earned and, where charges move a number of
-- their own, GP, that number for what was charged. Nil for somebody the list does not hold.
--
function P:UserTooltip(cfgid, listid, uid)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local muid = cfg and cfg.lists[listid] and member_of(cfg, listid, uid)

  if (not muid) then
    return nil
  end

  local spec = self.points
  local W = spec.words
  local st = self:Standings(cfgid, listid, muid)
  local lines = {}

  for _, f in ipairs(spec.fields) do
    tinsert(lines, { strfmt(L["Current %s"], W.FIELDS[f]), tostring(st[f] or 0) })
  end

  local earned, charged = st.earned or 0, st.charged or 0
  local against = (spec.charge ~= spec.earn) and (st[spec.charge] or 0) or 0

  if (earned ~= 0 and earned ~= (st[spec.earn] or 0)) then
    tinsert(lines, { W.LIFE_EARNED, tostring(earned) })
  end

  if (charged ~= 0 and charged ~= against) then
    tinsert(lines, { W.LIFE_CHARGED, tostring(charged) })
  end

  return lines
end

--
-- WHAT A BROADCAST CHANGED
--
-- A player holding a copy of a config keeps up with it as its events arrive, and misses any made while they were offline or
-- out of earshot. The next broadcast brings those, and the player is told what it did to their own numbers: before it is
-- taken (BroadcastArriving in Policy.lua) their numbers on each list are kept, by list, and once it is in place
-- (BroadcastArrived) every list whose numbers came out different gets a line saying what each was and is now. So does a
-- list they are no longer on. A list they are on for the first time counts as having held nothing.
--
function P:BroadcastArriving(cfgid)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local me = cfg and cfg:MyUid()

  if (not me) then
    return nil
  end

  local out = {}

  for listid, rl in pairs(cfg.lists) do
    local muid = member_of(cfg, listid, me)

    if (muid) then
      local st = self:Standings(cfgid, listid, muid)
      local vals = {}

      for _, f in ipairs(self.points.fields) do
        vals[f] = st[f] or 0
      end

      out[listid] = { name = rl.name, vals = vals }
    end
  end

  return out
end

function P:BroadcastArrived(cfgid, before)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local me = cfg and cfg:MyUid()

  if (not me or type(before) ~= "table") then
    return
  end

  local W = self.points.words

  for listid, rl in pairs(cfg.lists) do
    local muid = member_of(cfg, listid, me)

    if (muid) then
      local st = self:Standings(cfgid, listid, muid)
      local was = before[listid] and before[listid].vals or {}
      local parts = {}

      for _, f in ipairs(self.points.fields) do
        local o, n = was[f] or 0, st[f] or 0

        if (o ~= n) then
          tinsert(parts, strfmt(L["%s %d to %d (%+d)"], W.FIELDS[f], o, n, n - o))
        end
      end

      if (#parts > 0) then
        self:info(L["your numbers on %q changed: %s."], rl.name, tconcat(parts, ", "))
      end
    end
  end

  for listid, b in pairs(before) do
    if (not (cfg.lists[listid] and member_of(cfg, listid, me))) then
      self:info(L["you are no longer on %q."], b.name)
    end
  end
end

--
-- THE JOURNAL
--
-- What was done to a list's numbers that the loot history does not say: every decay, for good, and for a month every award
-- and whatever else the policy records there itself, DKP's zero-sum shares. Entries are appended by the events that make
-- them, on every admin alike, so each copy of a list holds the same record.
--
-- Each is t, when, k, "e" for an award, "d" for a decay and whatever the policy's own are, by, the uid of the admin who made
-- it, and u, the uids it reached run together. An award adds the amount each member in the raid had, under the name of the
-- number it added to, ep or dkp, and r, its reason, and a decay pct. The Lists page's Journal tab shows them.
--
local MONTH = 30 * 86400

function points.Journal(cfg, listid, entry)
  local rl = cfg.lists[listid]

  if (not rl) then
    return
  end

  rl.journal = rl.journal or {}
  tinsert(rl.journal, entry)

  --
  -- Anything but a decay older than a month from the newest is dropped, counted from the entry's own time rather than this
  -- client's clock so that every copy drops the same ones.
  --
  local keep = {}

  for _, e in ipairs(rl.journal) do
    if (e.k == "d" or (tonumber(e.t) or 0) >= (tonumber(entry.t) or 0) - MONTH) then
      tinsert(keep, e)
    end
  end

  rl.journal = keep
end

--
-- AWARDING POINTS
--
-- RAID gets AMOUNT each and STANDBY gets SBAMOUNT each, both lists of the uids on LISTID that are credited, which on a
-- tethered list are mains. The sender works out who is who from what it can see of the group, and every other admin applies
-- that rather than their own view of it.
--
-- A penalty that meets a number's floor (Floor) takes off only what the member had, and their lifetime total loses the same.
--

-- The least the number F may be on CFGID, from the spec's floors, nil for no least at all.
function P:Floor(cfgid, f)
  local floors = self.points.floors and self.points.floors(cfgid)

  return floors and floors[f]
end

-- V, or LEAST where V is below it.
local function at_least(least, v)
  return least and max(least, v) or v
end

function P:ApplyAward(cfg, listid, when, amount, raid, sbamount, standby, reason, by, norefresh)
  if (not cfg.lists[listid]) then
    return
  end

  local earn = self.points.earn
  local least = self:Floor(cfg.id, earn)

  local function give(uid, n)
    local st = self:Standings(cfg.id, listid, uid)
    local was = st[earn] or 0

    st[earn] = at_least(least, was + n)
    points.Earned(st, st[earn] - was)
  end

  for _, uid in ipairs(raid) do
    give(uid, amount)
  end

  for _, uid in ipairs(standby) do
    give(uid, sbamount)
  end

  -- Those on standby received it only if their share came to anything.
  local got = tconcat(raid, "") .. ((sbamount ~= 0) and tconcat(standby, "") or "")

  points.Journal(cfg, listid, { t = when, k = "e", [earn] = amount, by = by, u = got, r = reason })

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
    self:RefreshJournal()
  end
end

--
-- Whether UID, a member of LISTID, is in the raid: themselves, or on a tethered list an alt of theirs. What it answers is
-- the uid of the character who is here, false for nobody.
--
local function here(cfg, listid, uid)
  local map = konfer.raid.uidmap

  if (not map) then
    return false
  end

  if (map[uid]) then
    return uid
  end

  if (cfg.lists[listid].tethered) then
    for _, alt in ipairs(cfg:UserAlts(uid) or {}) do
      if (map[alt]) then
        return alt
      end
    end
  end

  return false
end

points.Here = here

--
-- Whether the character PUID, in the raid when INRAID, passes the award dialog's choice WHO: WHO.guild says guild members
-- only ("in") or non guild members only ("out") or either (nil), and WHO.ticks, a set of "r:<rank>", "c:<class>", "o:<role>"
-- and "g:<raid group>", is passed by matching any one of them. Nothing ticked is passed by everybody.
--
local function award_passes(cfg, puid, inraid, who)
  local name, cls = cfg:UserNameClass(puid)
  local pl = inraid and KRP.players and KRP.players[name]
  local ri = K.guild.roster.name and K.guild.roster.name[name]
  local rank = (pl and pl.is_guilded and pl.guildrankidx) or (ri and K.guild.roster.id[ri] and K.guild.roster.id[ri].rank)

  if (who.guild == "in" and not rank) then
    return false
  end

  if (who.guild == "out" and rank) then
    return false
  end

  if (not next(who.ticks)) then
    return true
  end

  local role = KU:Roles(cfg.uids[puid][konfer.CFGUSER_KUID])

  return (rank and who.ticks["r:" .. rank]) or who.ticks["c:" .. tostring(cls)] or who.ticks["o:" .. tostring(role)]
    or (pl and who.ticks["g:" .. tostring(pl.subgroup)]) or false
end

--
-- Award AMOUNT on LISTID of CFGID for REASON, an amount below nothing being a penalty, taken off everybody it reaches the
-- same way. With UID, to that member alone. Without, to the raid, and to those on standby their share of it: everybody on
-- the list who is here, or reserved, as the raid list counts them. WHO, from the award dialog, narrows that down: WHO.pool
-- says who it is chosen from, and the rest is what award_passes asks of each. WHO.named, a set of members from the award
-- command or the dialog's These users (NamedMembers), is the whole of the award instead, each given all of it.
--
-- A frozen member earns nothing at all, however it is given: they are left out of an award to the raid, to standby or to the
-- whole list, and one to them by name is refused.
--
function P:AwardPoints(cfgid, listid, amount, reason, uid, who)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local amount = tonumber(amount)
  local W = self.points.words

  if (not cfg or not cfg.lists[listid] or not amount or amount == 0) then
    return false
  end

  local raid, standby = {}, {}
  local sbamount = floor(amount * num(self, "standby_pct", cfgid) / 100 + 0.5)

  if (uid) then
    local muid = member_of(cfg, listid, uid)

    if (not muid) then
      return false
    end

    if (cfg:IsFrozen(muid)) then
      self:err(W.AWARD_FROZEN, shortaclass(cfg:UserNameClass(muid)))
      return false
    end

    tinsert(raid, muid)
  elseif (who and who.named) then
    --
    -- Those named, whoever and wherever they are: the whole of it, naming somebody being the decision. A frozen member named
    -- is said to be and left out.
    --
    for _, ruid in ipairs(cfg.lists[listid].users) do
      if (who.named[ruid] and cfg:IsFrozen(ruid)) then
        self:err(W.AWARD_FROZEN, shortaclass(cfg:UserNameClass(ruid)))
      elseif (who.named[ruid]) then
        tinsert(raid, ruid)
      end
    end

    if (#raid == 0) then
      self:err(W.AWARD_NOBODY)
      return false
    end
  else
    local taken = {}

    --
    -- Those picked by name, whoever they are: in the raid the whole of it, and anybody else the standby share, as everyone
    -- on the list is given it. The pool and the filter are never asked about them.
    --
    if (who and who.pick) then
      for _, ruid in ipairs(cfg.lists[listid].users) do
        if (who.pick[ruid] and not cfg:IsFrozen(ruid)) then
          tinsert(here(cfg, listid, ruid) and raid or standby, ruid)
          taken[ruid] = true
        end
      end
    end

    --
    -- Who it is chosen from: the raid alone ("active"), the raid and standby ("standby", and what is given without a WHO),
    -- or everybody on the list ("everyone"), anybody not in the raid taking the standby share, reserved or not. Picks alone
    -- with nothing ticked are the whole of the award, and this is not asked.
    --
    if (not who or not who.pick or next(who.ticks)) then
      local pool = who and who.pool or "standby"

      if (pool ~= "everyone" and not konfer.raid.uidmap) then
        self:err(W.AWARD_NOTRAID)
        return false
      end

      local members = (pool == "everyone") and cfg.lists[listid].users or cfg:CreateRaidList(listid)

      for _, ruid in ipairs(members) do
        local puid = here(cfg, listid, ruid)

        if (taken[ruid] or cfg:IsFrozen(ruid)) then
          -- Picked by name, and already given it, or frozen, and given none.
        elseif (puid) then
          if (not who or award_passes(cfg, puid, true, who)) then
            tinsert(raid, ruid)
          end
        elseif (pool ~= "active" and (not who or award_passes(cfg, ruid, false, who))) then
          tinsert(standby, ruid)
        end
      end
    end

    if (#raid == 0 and #standby == 0) then
      self:err(W.AWARD_NOBODY)
      return false
    end
  end

  local when = K.time()
  local by = cfg:MyUid()

  reason = reason or ""
  self:ApplyAward(cfg, listid, when, amount, raid, sbamount, standby, reason, by)
  cfg:AddEvent(self.points.events.award, listid, when, amount, tconcat(raid, ""), sbamount, tconcat(standby, ""), reason,
    by)

  -- Everybody given any, the standby share or the whole of it.
  self:info(W.AWARDED, amount, cfg.lists[listid].name, #raid + ((sbamount ~= 0) and #standby or 0), reason)

  return true
end

--
-- The members of LISTID of CFGID that TEXT names, as a set of uid, and the words in it that name nobody on the list, in the
-- order typed. TEXT is names or #uids, any mix, separated by commas or spaces, which is what pasting a column of names
-- gives. A name is a character's, with or without its realm, and on a tethered list an alt named is their main.
--
function P:NamedMembers(cfgid, listid, text)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local named, misses = {}, {}

  for word in gmatch(text or "", "[^,%s]+") do
    local uid

    if (strsub(word, 1, 1) == "#") then
      uid = strsub(word, 2)
      uid = cfg and cfg.uids[uid] and uid or nil
    else
      uid = cfg and cfg:FindUser(word)
    end

    local muid = uid and cfg.lists[listid] and member_of(cfg, listid, uid)

    if (muid) then
      named[muid] = true
    else
      tinsert(misses, word)
    end
  end

  return named, misses
end

--
-- AMOUNT on LISTID of CFGID for REASON to the members TEXT names (NamedMembers), each given the whole of it. Anybody it names
-- who is not on the list is said and left out, and everybody else is still given it. Answers whether anybody was.
--
function P:AwardNamed(cfgid, listid, amount, reason, text)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local named, misses = self:NamedMembers(cfgid, listid, text)

  if (not cfg or not cfg.lists[listid]) then
    return false
  end

  if (#misses > 0) then
    self:err(L["nobody on %q is called %s."], cfg.lists[listid].name, tconcat(misses, ", "))
  end

  if (not next(named)) then
    if (#misses == 0) then
      self:err(self.points.words.AWARD_NOBODY)
    end

    return false
  end

  return self:AwardPoints(cfgid, listid, amount, reason, nil, { named = named })
end

--
-- SETTING A MEMBER'S NUMBERS BY HAND
--
-- VALS are the numbers in the spec's order, one a nil for any left as they were.
--
function P:ApplySet(cfg, listid, uid, vals, norefresh)
  if (not cfg.lists[listid]) then
    return
  end

  local st = self:Standings(cfg.id, listid, uid)

  for i, f in ipairs(self.points.fields) do
    st[f] = at_least(self:Floor(cfg.id, f), tonumber(vals[i]) or st[f] or 0)
  end

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end
end

-- UID's numbers on LISTID set by hand, given in the spec's order after UID, on a tethered list their main's.
function P:SetNumbers(cfgid, listid, uid, ...)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local muid = cfg and cfg.lists[listid] and member_of(cfg, listid, uid)

  if (not muid) then
    return false
  end

  local vals = {}

  for i = 1, #self.points.fields do
    vals[i] = tonumber((select(i, ...))) or 0
  end

  self:ApplySet(cfg, listid, muid, vals)
  cfg:AddEvent(self.points.events.set, listid, muid, unpack(vals))

  return true
end

--
-- DECAY
--
-- PCT off each of the spec's decaying numbers of each of UIDS on LISTID, rounded to the nearest point. Who is decayed is
-- decided by whoever decays and carried by uid in the event, a rank being a thing each client sees the guild's roster for.
--
-- A number with a base in BASES, a table of field to base the policy's decaybase gave, decays as though the base were part
-- of it and it could never fall below the base: (V + BASE) less PCT, less the base again, and never below nothing. That is
-- EP/GP's GP over its base GP, which is the original EP/GP's decay exactly without the base being stored. The bases are the
-- ones the decay was made with and travel in its event, so an admin holding another base GP still decays as the sender did.
--
-- What each decay takes off each number is added to that number's lifetime total of decay.
--
local function decayed(v, pct, base)
  v = tonumber(v) or 0

  if (not base) then
    return floor(v * (100 - pct) / 100 + 0.5)
  end

  return max(0, floor((v + base) * (100 - pct) / 100 - base + 0.5))
end

function P:ApplyDecay(cfg, listid, when, pct, uids, by, bases, norefresh)
  if (not cfg.lists[listid]) then
    return
  end

  bases = (type(bases) == "table") and bases or {}

  for _, uid in ipairs(uids) do
    local st = self:Standings(cfg.id, listid, uid)

    for _, f in ipairs(self.points.decays) do
      local was = st[f] or 0

      st[f] = decayed(was, pct, tonumber(bases[f]))
      add_lifetime(st, "decayed_" .. f, was - st[f])
    end
  end

  -- When the list was last decayed, which is what says when it may be again. The newest, should a sync replay out of order.
  local rl = cfg.lists[listid]

  rl.lastdecay = max(tonumber(rl.lastdecay) or 0, tonumber(when) or 0)

  points.Journal(cfg, listid, { t = when, k = "d", pct = pct, by = by, u = tconcat(uids, "") })

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
    self:RefreshJournal()
  end
end

--
-- A list is decayed at most once every DECAY_EVERY, counted from rl.lastdecay, which every admin sets from the same decay
-- event and a config arriving whole carries in ListInfo. What is left of that for LISTID of CFGID, in seconds, 0 when due.
--
local DECAY_EVERY = 5 * 86400

-- Whether CFGID's lists decay at all (the SPEC's decayswitch).
function P:DecayOn(cfgid)
  local sw = self.points.decayswitch

  return (not sw) or (self:Setting(sw, cfgid) and true or false)
end

function P:DecayCooldown(cfgid, listid)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local last = rl and tonumber(rl.lastdecay)

  if (not last) then
    return 0
  end

  return max(0, last + DECAY_EVERY - K.time())
end

--
-- Decay PCT on every member of every list in LISTS of CFGID, a set of list ids. A list not due is left alone. PCT is
-- DECAY_MIN_PCT to DECAY_MAX_PCT, as it is wherever one is typed, and anything else decays nobody.
--
local DECAY_MIN_PCT = 1
local DECAY_MAX_PCT = 50

function P:Decay(cfgid, pct, lists)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local pct = tonumber(pct)

  if (not cfg or not pct or pct < DECAY_MIN_PCT or pct > DECAY_MAX_PCT) then
    return 0
  end

  local when = K.time()
  local total = 0
  local bases = self.points.decaybase and self.points.decaybase(cfgid) or nil

  for listid in pairs(lists) do
    local rl = cfg.lists[listid]

    if (rl and self:DecayCooldown(cfgid, listid) > 0) then
      self:err(L["%q is not due for decay yet."], rl.name)
    elseif (rl) then
      local uids = {}

      for _, uid in ipairs(rl.users) do
        tinsert(uids, uid)
      end

      self:ApplyDecay(cfg, listid, when, pct, uids, cfg:MyUid(), bases)
      cfg:AddEvent(self.points.events.decay, listid, when, pct, tconcat(uids, ""), cfg:MyUid(), bases)
      total = total + #uids
    end
  end

  self:info(L["decayed %d members by %d%%."], total, pct)

  return total
end

--
-- TIMED POINTS
--
-- While it runs, an amount is awarded to the raid every so many minutes, on one list, by the master looter. How much and how
-- often are that list's own (its options time_award and time_minutes, on the Lists page's Config tab), read when the timer
-- starts. The rest of the raid's admins hold the same timer, and anybody who lost theirs, to a reload or a disconnect, asks
-- for it back (the timerq event) and is told how far along it is (the timer event), amount and minutes included, so none of
-- them reads the list. Seconds remaining rather than a time of day, which is the one thing every client can agree on.
--
-- pol.timer is { cfgid, listid, amount, minutes, due } with DUE on this client's GetTime(), or nil when none is running.
-- MINUTES is always TIMER_MIN_MINUTES to TIMER_MAX_MINUTES, whatever the list or the timer event says, a timer of none
-- coming due every second.
--
local TIMER_MIN_MINUTES = 1
local TIMER_MAX_MINUTES = 240

function P:TimerState()
  local t = self.timer

  if (not t) then
    return false
  end

  return true, t.listid, t.amount, t.minutes, max(0, t.due - GetTime())
end

function P:SetTimer(cfgid, running, listid, amount, minutes, remaining)
  if (not running) then
    self.timer = nil
  else
    local every = min(max(tonumber(minutes) or 30, TIMER_MIN_MINUTES), TIMER_MAX_MINUTES)

    self.timer = {
      cfgid = cfgid, listid = listid, amount = tonumber(amount) or 0, minutes = every,
      due = GetTime() + (tonumber(remaining) or (every * 60)),
    }
  end

  self:RefreshPanel()
end

--
-- Tell the raid what the timer is doing now. Timed points are the raid's business alone, so it goes to the raid whatever the
-- config's channel, and only the raid hears it, asks after it and answers.
--
local function send_timer(pol, cfgid)
  local running, listid, amount, minutes, remaining = pol:TimerState()

  pol:CSendGroupAM(cfgid, pol.points.events.timer, "ALERT", running, listid, amount, minutes, remaining)
end

function P:StartTimer(cfgid, listid)
  local amount = tonumber(self:ListOption(cfgid, listid, "time_award")) or tonumber(self.listoptions.time_award) or 0
  local minutes = tonumber(self:ListOption(cfgid, listid, "time_minutes")) or tonumber(self.listoptions.time_minutes)

  self:SetTimer(cfgid, true, listid, amount, minutes)
  send_timer(self, cfgid)
end

function P:StopTimer(cfgid)
  self:SetTimer(cfgid, false)
  send_timer(self, cfgid)
end

--
-- Each second: award when the timer comes due, and it is the master looter's to award. Everybody moves their copy on to the
-- next time together, the master looter telling them afterwards so that any drift is put right.
--
local function tick(pol)
  local t = pol.timer

  if (t and GetTime() >= t.due) then
    t.due = t.due + t.minutes * 60

    if (konfer.apol == pol and konfer:AmIML() and konfer:PolicyAdmin(pol)) then
      pol:AwardPoints(t.cfgid, t.listid, t.amount, pol.points.words.TIMED_REASON)
      send_timer(pol, t.cfgid)
    end
  end

  pol:RefreshPanel()
end

--
-- BOSS KILLS
--
-- A boss dying offers the master looter an award on whatever list the Lists page has selected, else the config's default:
-- that list's boss kill award (its option boss_award), filled in and its description naming the boss. A wipe offers the
-- list's wipe award (wipe_award) the same way. Anything in it, the award itself included, is theirs to change before it goes
-- out, and a fight the game ends without anybody dying, a boss reset, is a wipe they can close. A list whose award is none
-- offers nothing.
--
-- The boss is named as the fight was, the encounter's name and then its difficulty as a letter and the size of the group,
-- "Magtheridon N25", which is what the journal keeps of it. The letter is the game's own word on the difficulty, raid
-- finder, mythic, heroic or else normal, and a difficulty the game cannot place has none.
--
local function fight_name(enc)
  local tag = ""

  if (not enc.name) then
    return nil
  end

  if (enc.difficulty and GetDifficultyInfo) then
    local name, _, heroic, _, showheroic, showmythic, _, lfr = GetDifficultyInfo(enc.difficulty)

    if (name) then
      tag = (lfr and L["DIFFICULTY_LFR"]) or (showmythic and L["DIFFICULTY_MYTHIC"])
        or ((heroic or showheroic) and L["DIFFICULTY_HEROIC"]) or L["DIFFICULTY_NORMAL"]
    end
  end

  tag = tag .. (enc.size and tostring(enc.size) or "")

  return (tag ~= "") and (enc.name .. " " .. tag) or enc.name
end

function P:EncounterEnded(enc)
  local pol = self

  if (konfer.apol ~= pol or not pol.cfg or not konfer:AmIML() or not konfer:PolicyAdmin(pol)) then
    return
  end

  local listid = pol:CurrentList()

  if (not listid) then
    if (enc.killed) then
      pol:info(pol.points.words.BOSS_NOLIST, tostring(enc.name))
    end

    return
  end

  local id = pol:ListOption(pol.currentid, listid, enc.killed and "boss_award" or "wipe_award")

  if (awards_of(pol, pol.currentid)[id]) then
    pol:OpenAwardDialog(pol.currentid, listid, id, fight_name(enc))
  end
end

--
-- Ask the raid where timed points have got to, and whoever answers (the timer event) sets the timer here. Only the active
-- policy asks, the timer being the active policy's to run.
--
local function ask_timer(pol)
  if (konfer.apol == pol and pol.currentid) then
    pol:CSendGroupAM(pol.currentid, pol.points.events.timerq, "ALERT")
  end
end

function P:OnActivate(onoff)
  local pol = self

  if (not onoff) then
    return
  end

  if (not pol.pointsticker) then
    pol.pointsticker = K:ScheduleRepeatingTimer(function()
      tick(pol)
    end, 1)
  end

  --
  -- A client coming back, from a reload or a disconnect, asks where the timer had got to once it is in a group. A master
  -- looter whose group is not known yet asks when it is, in MasterLooterChanged.
  --
  K:ScheduleTimer(function()
    if (KRP.in_party and not pol.timer) then
      ask_timer(pol)
    end
  end, 3)
end

--
-- Becoming master looter asks where timed points have got to, whatever this client holds, the master looter being who awards
-- them: one who left the raid and came back, or was handed master loot, puts their countdown right by the one that kept
-- running. One ask, from the one client that needs it, where every raider asking on joining would have every timer answering
-- each. A raid made up by /konfer testraid is this character's to master loot, and asks too.
--
function P:MasterLooterChanged(isml)
  if (isml) then
    ask_timer(self)
  end
end

--
-- DIALOGS
--
-- Each is built once for each policy. Award, Adjust, Decay and the award being defined put the policy window away while they
-- are up and bring it back when they close, however they are closed, and only if it was up to begin with: a boss kill opens
-- the award dialog over whatever is on screen.
--
local function points_dialog(name, height, enteraccept)
  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = name, title = "", border = true, width = 360, height = height,
    canmove = true, canresize = false, escclose = true, blackbg = true, okbutton = true, cancelbutton = true,
    enteraccept = enteraccept,
  })

  dlg:Catch("OnHide", function(t, evt)
    if (dlg.restoremain) then
      dlg.restoremain = nil
      konfer.mainwin:Show()
    end
  end)

  return dlg
end

-- Put DLG up in place of the policy window.
local function over_main(dlg)
  dlg.restoremain = dlg.restoremain or konfer.mainwin:IsShown()
  konfer.mainwin:Hide()
  dlg:Show()
end

-- Size DLG to what it holds, YPOS being where the next thing would have gone.
local function fit(dlg, ypos)
  dlg:SetHeight(dlg:GetHeight() - dlg.content:GetHeight() - ypos + 12)
end

--
-- Who the award dialog gives to, the dialog DLG's choice. DLG.mode is "all", the whole list as the filter has it, "one", the
-- member selected on the Lists page alone, "many", those picked in DLG.picked, "named", those named in the box under Award
-- to (These users), or "some", those matching any of DLG.ticks. The Award to menu has the first four as a radio group, the
-- third with a flyout of everybody on the list to pick from, then the four things a tick can name, each a submenu: the
-- guild's ranks, the classes this game has in their colours, the roles, and the raid groups with anybody in them. Every
-- item's check is read from DLG, so the menu shows what the dialog holds, and it is built afresh each time it opens, the
-- guild, the raid and the list changing under it.
--
-- The list to pick from is everybody on it, those in the raid first and in their class colours, those who are not after
-- them in grey, and each of the two alphabetical.
--
local function pick_items(dlg, cfg, picked)
  local rl = cfg and cfg.lists[dlg.listid]
  local here_, gone = {}, {}

  for _, u in ipairs((rl and rl.users) or {}) do
    local nm, cls = cfg:UserNameClass(u)

    if (nm) then
      local present = here(cfg, dlg.listid, u) and true or false
      local item = { text = K.DisplayName(nm), value = "p:" .. u, uid = u, checked = picked,
        color = present and K.ClassColorsRGBPerc[cls] or { r = 0.5, g = 0.5, b = 0.5 } }

      tinsert(present and here_ or gone, item)
    end
  end

  local function byname(a, b)
    return strlower(a.text) < strlower(b.text)
  end

  tsort(here_, byname)
  tsort(gone, byname)

  for _, v in ipairs(gone) do
    tinsert(here_, v)
  end

  return here_
end

--
-- Whether the Award to item with value V is checked, from what DLG holds. The Multiple raiders ring is on while anybody is
-- picked, and ticks and picks stand together, the award reaching those picked and those the ticks match.
--
local function who_checked(dlg, v)
  if (v == "all" or v == "one" or v == "named") then
    return dlg.mode == v
  elseif (v == "many") then
    return dlg.mode == "some" and next(dlg.picked) ~= nil
  elseif (v:sub(1, 2) == "p:") then
    return dlg.picked[v:sub(3)] and true or false
  end

  return dlg.ticks[v] and true or false
end

local function award_items(pol, dlg)
  local cfg = konfer:PolicyConfig(pol, dlg.cfgid)
  local name = dlg.uid and cfg and cfg.uids[dlg.uid] and shortaclass(cfg:UserNameClass(dlg.uid))
  local ranks, classes, roles, groups = {}, {}, {}, {}

  local function ticked(this)
    return who_checked(dlg, this.value)
  end

  local chosen = ticked
  local picks = pick_items(dlg, cfg, ticked)

  -- None for a character with no guild, whose submenu is then dark (sub). Kore keeps a guild's names after it is left.
  for i, rn in ipairs(K.player.is_guilded and K.guild.ranks or {}) do
    tinsert(ranks, { text = rn, value = "r:" .. i, checked = ticked })
  end

  local ids = {}

  for id in pairs(K.IndexClass) do
    tinsert(ids, id)
  end

  tsort(ids, function(a, b) return K.IndexClass[a].c < K.IndexClass[b].c end)

  for _, id in ipairs(ids) do
    tinsert(classes, { text = K.IndexClass[id].c, value = "c:" .. id, color = K.ClassColorsRGBPerc[id], checked = ticked })
  end

  for _, r in ipairs(K.ROLES) do
    tinsert(roles, { text = K.RoleName(r), value = "o:" .. r, checked = ticked })
  end

  local have = {}

  for _, p in pairs(KRP.players or {}) do
    if ((p.subgroup or 0) > 0) then
      have[p.subgroup] = true
    end
  end

  -- An award being defined is for whoever is in a group on the night, so it offers all eight.
  for g = 1, 8 do
    if (have[g] or dlg.define) then
      tinsert(groups, { text = strfmt(L["Group %d"], g), value = "g:" .. g, checked = ticked })
    end
  end

  -- A submenu with nothing in it is dark, and so is every one while the award is to one member alone or to those named.
  local function sub(key, text, list)
    return { text = text, checkable = false, clickable = false,
      enabled = #list > 0 and dlg.mode ~= "one" and dlg.mode ~= "named",
      submenu = { name = dlg.fname .. key, itemheight = 16, items = list } }
  end

  local items = {
    { text = L["Filtered users"], value = "all", group = "who", keep = false, checked = chosen },
  }

  -- Defining an award, there is nobody tonight to name.
  if (not dlg.define) then
    tinsert(items, { text = strfmt(L["Only to %s"], name or K.NOBODY_STR), value = "one", group = "who", keep = false,
      checked = chosen, enabled = name ~= nil })
    tinsert(items, { text = L["Multiple raiders"], value = "many", group = "who", checked = chosen, enabled = #picks > 0,
      submenu = { name = dlg.fname .. "Picks", itemheight = 16, items = picks } })
    tinsert(items, { text = L["These users"], value = "named", group = "who", keep = false, checked = chosen })
  end

  tinsert(items, { text = "-" })
  tinsert(items, sub("Ranks", L["Guild ranks"], ranks))
  tinsert(items, sub("Classes", L["Class"], classes))
  tinsert(items, sub("Roles", L["Role"], roles))
  tinsert(items, sub("Groups", L["Members of group"], groups))

  return items
end

--
-- Who the choice reaches before it is narrowed: the raid alone, the raid and standby, or everybody on the list, a radio
-- group, and under a spacer guild members only and non guild members only, which together or neither leave guild
-- membership out of it.
--
local function filter_items(dlg)
  local function pool(this)
    return dlg.pool == this.value
  end

  local function flag(this)
    return dlg[this.value] and true or false
  end

  -- Which side of the guild somebody is on means nothing to a character with no guild.
  local function guilded()
    return K.player.is_guilded and true or false
  end

  return {
    { text = L["Active raiders only"], value = "active", group = "pool", checked = pool },
    { text = L["Active and standby raiders"], value = "standby", group = "pool", checked = pool },
    { text = L["Everyone"], value = "everyone", group = "pool", checked = pool },
    { text = "-" },
    { text = L["Guild members only"], value = "inguild", checked = flag, enabled = guilded },
    { text = L["Non guild members only"], value = "outguild", checked = flag, enabled = guilded },
  }
end

--
-- The Award to box says what is chosen, and OK is live only while that is somebody: a member selected, some tick, or
-- something typed in the box of names. An award being defined needs a description and an amount as well, there being
-- nothing to fill either in from later.
--
local function award_sync(pol, dlg)
  local cfg = konfer:PolicyConfig(pol, dlg.cfgid)
  local name = dlg.uid and cfg and cfg.uids[dlg.uid] and shortaclass(cfg:UserNameClass(dlg.uid))
  local named = dlg.names and (dlg.names:GetText() or ""):match("[^,%s]") ~= nil
  local npicked = 0

  for _ in pairs(dlg.picked) do
    npicked = npicked + 1
  end

  local ticks = next(dlg.ticks) ~= nil
  local ok = (dlg.mode == "all") or (dlg.mode == "one" and name ~= nil) or (dlg.mode == "some" and (ticks or npicked > 0))
    or (dlg.mode == "named" and named)

  if (dlg.define) then
    ok = ok and (dlg.desc:GetText() or ""):match("%S") ~= nil and (tonumber(dlg.amount:GetText()) or 0) ~= 0
  end

  if (dlg.names) then
    dlg.names:SetEnabled(dlg.mode == "named")
  end

  if (dlg.mode == "named") then
    dlg.who:SetText(L["These users"])
  elseif (dlg.mode == "one") then
    dlg.who:SetText(strfmt(L["Only to %s"], name or K.NOBODY_STR))
  elseif (dlg.mode == "some" and (npicked > 0 or not ticks)) then
    dlg.who:SetText(strfmt(L["Multiple raiders (%d)"], npicked))
  elseif (dlg.mode == "some") then
    dlg.who:SetText(L["Those ticked"])
  else
    dlg.who:SetText(L["Filtered users"])
  end

  dlg.okbutton:SetEnabled(ok)

  -- One member alone, or those picked by name, is nobody to filter. The filter narrows what the ticks match, never a pick.
  dlg.filter:SetEnabled(dlg.mode == "all" or (dlg.mode == "some" and (ticks or npicked == 0)))
end

--
-- Fill DLG in from the award AW, or empty it for none: the description, naming the boss where a kill opened it, the amount,
-- and who, the whole list or those AW ticks, from its pool and guild members only or not. Nobody is picked by name, and
-- whatever is in the box of names stays there, dark, for These users to be chosen again.
--
local function award_fill(pol, dlg, aw)
  local ticks = {}

  for k in pairs((aw and aw.t) or {}) do
    ticks[k] = true
  end

  dlg.ticks = ticks
  dlg.picked = {}
  dlg.mode = next(ticks) and "some" or "all"
  dlg.pool = (aw and aw.p) or "standby"
  dlg.inguild = (aw and aw.g == "in") and true or false
  dlg.outguild = (aw and aw.g == "out") and true or false

  if (aw) then
    dlg.desc:SetText(dlg.boss and strfmt(L["%s (%s)"], aw.d, dlg.boss) or aw.d)
    dlg.amount:SetText(tostring(aw.a))
  else
    dlg.desc:SetText("")
    dlg.amount:SetText("")
  end

  dlg.who:UpdateItems(award_items(pol, dlg))
  dlg.filter:UpdateItems(filter_items(dlg))
  award_sync(pol, dlg)
end

-- Who DLG is to reach, as AwardPoints takes it.
local function award_who(dlg)
  local guild = nil

  if (dlg.inguild ~= dlg.outguild) then
    guild = dlg.inguild and "in" or "out"
  end

  local some = dlg.mode == "some"

  return { pool = dlg.pool, guild = guild, ticks = some and dlg.ticks or {},
    pick = (some and next(dlg.picked)) and dlg.picked or nil }
end

-- OK on an award being defined saves it, in place of the one edited or as a new one, and selects it.
local function define_accept(pol, dlg)
  local id = dlg.awardid or KC.CreateNewID()
  local who = award_who(dlg)

  dlg:Hide()

  if (pol.awardsui) then
    pol.awardsui.selected = id
  end

  pol:SetAward(dlg.cfgid, id, { d = dlg.desc:GetText(), a = tonumber(dlg.amount:GetText()) or 0, p = who.pool,
    g = who.guild, t = next(who.ticks) and K.CopyTable(who.ticks, {}) or nil })
end

--
-- THE AWARD DIALOG
--
-- What is awarded, how much, and to whom: the whole list, the member selected on the Lists page, raiders picked by name,
-- those named in the box under Award to, or those matching what is ticked, from the raid alone, the raid and standby, or
-- everybody on the list as the filter says.
--
-- The same dialog defines an award, built a second time with DEFINE set. Awarding, a choice of the config's awards stands
-- over the rest, -Custom- before them for none, and choosing one fills the rest in from it or, -Custom-, empties it.
-- Anything filled in may be changed before OK. Defining, that choice is not there, and neither are the member selected,
-- picks by name and the box of names, which are tonight's people and nothing an award keeps.
--
local AWARD_DESC_W = 200

-- Enough for a raid's worth of names pasted from a sign-up sheet, realms and all.
local NAMES_LEN = 1024

local function award_dialog(pol, define)
  local W = pol.points.words
  local fname = "Konfer" .. pol.points.tag .. (define and "Define" or "Award")
  local ypos = 0 - KUI.WIDGET_GAP
  local dlg = points_dialog(fname .. "Dialog", 220)
  local labels = { L["Description"], L["Amount"], L["Award to"] }

  if (not define) then
    tinsert(labels, L["Award"])
    tinsert(labels, L["Users"])
  end

  local lw = KUI:WidestString(labels)

  dlg.define = define
  dlg.fname = fname
  dlg.ticks = {}
  dlg.picked = {}

  if (not define) then
    dlg.choice = KUI:CreateDropDown({
      x = 4, y = ypos, mode = "SINGLE", itemheight = 16, name = fname .. "Choice", dwidth = AWARD_DESC_W,
      items = KUI.emptydropdown, label = { text = L["Award"], pos = "LEFT", width = lw },
    }, dlg)
    dlg.choice:Catch("OnValueChanged", function(this, evt, nv, user)
      if (user) then
        award_fill(pol, dlg, awards_of(pol, dlg.cfgid)[nv])
      end
    end)
    ypos = ypos - dlg.choice:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP
  end

  dlg.desc = KUI:CreateEditBox({
    x = 4, y = ypos, width = AWARD_DESC_W, len = 64, label = { text = L["Description"], pos = "LEFT", width = lw },
  }, dlg)
  ypos = ypos - dlg.desc:GetHeight() - KUI.WIDGET_GAP

  -- Four digits and a minus, an amount taken off being a penalty, which a box only for digits would have no way to type.
  dlg.amount = KUI:CreateEditBox({
    x = 4, y = ypos, charwidth = 5, len = 5, label = { text = L["Amount"], pos = "LEFT", width = lw },
  }, dlg)
  ypos = ypos - dlg.amount:GetHeight() - KUI.WIDGET_GAP

  local WHO_W = 170

  dlg.who = KUI:CreateDropDown({
    x = 4, y = ypos, mode = "MULTI", itemheight = 16, name = fname .. "Who", dwidth = WHO_W,
    title = { text = L["Filtered users"] }, items = KUI.emptydropdown,
    label = { text = L["Award to"], pos = "LEFT", width = lw },
  }, dlg)

  -- What the two boxes hold matters to OK only while an award is being defined. Caught here, Award to being there to sync.
  dlg.desc:Catch("OnValueChanged", function()
    award_sync(pol, dlg)
  end)
  dlg.amount:Catch("OnValueChanged", function()
    award_sync(pol, dlg)
  end)
  dlg.who:Catch("OnClick", function(this, evt, _, shown)
    if (shown) then
      this:UpdateItems(award_items(pol, dlg))
      award_sync(pol, dlg)
    end
  end)

  --
  -- Put every check on the menu as it stands open, submenus included, back to what the dialog holds, so a pick or a tick
  -- that was let go never shows as still made.
  --
  local function show_checks(frames)
    for _, f in ipairs(frames or {}) do
      if (f.checkmark and type(f.value) == "string") then
        f.checked = who_checked(dlg, f.value)
        f.checkmark:SetShown(f.checked)
      end

      if (f.menuframe) then
        show_checks(f.menuframe.iframes)
      end
    end
  end

  --
  -- Choosing the whole list, the member selected or These users forgets the ticks and the picks. Picking raiders and
  -- ticking ranks, classes, roles or groups stand together, and the last of them let go leaves nobody chosen.
  --
  dlg.who:Catch("OnItemChecked", function(this, evt, item, v, checked)
    if (v == "all" or v == "one" or v == "named") then
      if (checked) then
        dlg.mode = v
        dlg.ticks = {}
        dlg.picked = {}
      end
    elseif (v == "many") then
      if (checked) then
        dlg.mode = "some"
      end
    elseif (type(v) == "string" and v:sub(1, 2) == "p:") then
      dlg.picked[v:sub(3)] = checked or nil
      dlg.mode = "some"
    elseif (v) then
      dlg.ticks[v] = checked or nil
      dlg.mode = "some"
    end

    show_checks(this.dropdown and this.dropdown.iframes)
    award_sync(pol, dlg)
  end)

  dlg.filter = KUI:CreateDropDown({
    x = 4 + lw + 4 + WHO_W + 8, y = ypos, mode = "MULTI", itemheight = 16, name = fname .. "Filter",
    dwidth = KUI:DropDownWidth({ L["Filter"] }), title = { text = L["Filter"] }, items = KUI.emptydropdown,
    tooltip = { title = "$$", text = W.TIP_AWARDFILTER },
  }, dlg)
  dlg.filter:Catch("OnClick", function(this, evt, _, shown)
    if (shown) then
      this:UpdateItems(filter_items(dlg))
    end
  end)
  dlg.filter:Catch("OnItemChecked", function(this, evt, item, v, checked)
    if (v == "active" or v == "standby" or v == "everyone") then
      if (checked) then
        dlg.pool = v
      end
    elseif (v) then
      dlg[v] = checked and true or false
    end
  end)
  ypos = ypos - dlg.who:GetHeight() - KUI.DROPDOWN_ADD_GAP

  --
  -- The names These users awards, pasted or typed, by name or by #uid, separated by commas or spaces. It is always there and
  -- dark until These users is chosen, so that the dialog does not change size under the pointer.
  --
  if (not define) then
    ypos = ypos - KUI.WIDGET_GAP
    dlg.names = KUI:CreateEditBox({
      x = 4, y = ypos, width = WHO_W + 8 + KUI:DropDownWidth({ L["Filter"] }), len = NAMES_LEN, enabled = false,
      label = { text = L["Users"], pos = "LEFT", width = lw }, tooltip = { title = "$$", text = L["TIP_AWARD_NAMES"] },
    }, dlg)
    dlg.names:Catch("OnValueChanged", function()
      award_sync(pol, dlg)
    end)
    ypos = ypos - dlg.names:GetHeight() - KUI.WIDGET_GAP
  end

  fit(dlg, ypos)

  if (define) then
    dlg.OnAccept = function(t)
      define_accept(pol, dlg)
    end
  else
    dlg.OnAccept = function(t)
      local uid = (dlg.mode == "one") and dlg.uid or nil
      local amount, reason = tonumber(dlg.amount:GetText()), dlg.desc:GetText()
      local done

      if (dlg.mode == "named") then
        done = pol:AwardNamed(dlg.cfgid, dlg.listid, amount, reason, dlg.names:GetText())
      else
        done = pol:AwardPoints(dlg.cfgid, dlg.listid, amount, reason, uid, award_who(dlg))
      end

      if (done) then
        dlg:Hide()
      end
    end
  end

  return dlg
end

--
-- Award points on LISTID of CFGID. The dialog starts on the award AWARDID, filled in from it, and for a boss kill with
-- BOSS's name in its description, or on -Custom- with everything empty. Who starts as the award says, or the whole list,
-- the raid and standby, or with UID the member it was opened for.
--
function P:OpenAwardDialog(cfgid, listid, awardid, boss, uid)
  local pol = self
  local W = pol.points.words

  pol.dialogs = pol.dialogs or {}
  pol.dialogs.award = pol.dialogs.award or award_dialog(pol, false)

  local dlg = pol.dialogs.award
  local awards = awards_of(pol, cfgid)
  local aw = awardid and awards[awardid]

  dlg.cfgid, dlg.listid, dlg.boss = cfgid, listid, boss
  dlg.uid = uid or (pol.panel and pol.panel.uid)
  dlg.names:SetText("")
  dlg.choice:UpdateItems(award_choices(awards, L["-Custom-"]))
  dlg.choice:SetValue(aw and awardid or "0", true)
  award_fill(pol, dlg, aw)

  if (uid) then
    dlg.mode = "one"
    award_sync(pol, dlg)
  end

  dlg:SetTitleText(pol:WindowTitle(strfmt(W.AWARD_TITLE, konfer:PolicyConfig(pol, cfgid).lists[listid].name)))
  over_main(dlg)
end

--
-- Define an award of CFGID, the config picked on the Admin tab: a new one, or AWARDID as it stands.
--
function P:OpenAwardEditor(cfgid, awardid)
  local pol = self

  pol.dialogs = pol.dialogs or {}
  pol.dialogs.define = pol.dialogs.define or award_dialog(pol, true)

  local dlg = pol.dialogs.define
  local aw = awardid and awards_of(pol, cfgid)[awardid]

  dlg.cfgid, dlg.listid, dlg.uid, dlg.boss = cfgid, nil, nil, nil
  dlg.awardid = aw and awardid or nil
  award_fill(pol, dlg, aw)
  dlg:SetTitleText(pol:WindowTitle(aw and L["Edit award"] or L["Create award"]))
  over_main(dlg)

  -- A new award starts with the keyboard in its description, the first thing it needs.
  if (not aw) then
    dlg.desc:SetFocus()
  end
end

--
-- Set a member's numbers by hand. Every one of the spec's numbers on one line, centred: a row exactly as wide as them all,
-- each field being its label, the gap after it and the box, which holds six digits and shows them all. The keyboard starts
-- on the first, and Tab goes on to the next. The box for a number is named by it, DLG.ep or DLG.dkp.
--
function P:OpenAdjustDialog(cfgid, listid, uid)
  local pol = self
  local spec = pol.points

  pol.dialogs = pol.dialogs or {}

  if (not pol.dialogs.adjust) then
    local ypos = 0 - KUI.WIDGET_GAP
    local dlg = points_dialog("Konfer" .. spec.tag .. "AdjustDialog", 150, true)
    local SPACE = 24
    local row = KUI.MakeFrame("Frame", nil, dlg.content)
    local x = 0
    local h = 0

    row:SetPoint("TOP", dlg.content, "TOP", 0, ypos)

    for i, f in ipairs(spec.fields) do
      local label = spec.words.FIELDS[f]
      local lw = KUI:WidestString({ label })

      if (i > 1) then
        x = x + SPACE
      end

      dlg[f] = KUI:CreateEditBox({
        x = x, y = 0, charwidth = 6, numeric = true, len = 6, label = { text = label, pos = "LEFT", width = lw },
      }, row)

      x = x + lw + KUI.INTERNAL_GAP + dlg[f]:GetWidth()
      h = dlg[f]:GetHeight()
    end

    row:SetSize(x, h)
    ypos = ypos - h

    fit(dlg, ypos)

    dlg.OnAccept = function(t)
      local vals = {}

      for i, f in ipairs(spec.fields) do
        vals[i] = tonumber(dlg[f]:GetText())
      end

      pol:SetNumbers(dlg.cfgid, dlg.listid, dlg.uid, unpack(vals))
      dlg:Hide()
    end

    pol.dialogs.adjust = dlg
  end

  local dlg = pol.dialogs.adjust
  local cfg = konfer:PolicyConfig(pol, cfgid)
  local muid = cfg and member_of(cfg, listid, uid)
  local vals = muid and numbers_of(pol, cfgid, listid, muid) or {}

  dlg.cfgid, dlg.listid, dlg.uid = cfgid, listid, uid

  for i, f in ipairs(spec.fields) do
    dlg[f]:SetText(tostring(vals[i] or 0))
  end

  dlg:SetTitleText(pol:WindowTitle(strfmt(L["Adjust %s"], shortaclass(cfg:UserNameClass(uid)))))
  over_main(dlg)

  dlg[spec.fields[1]]:SetFocus()
end

--
-- Decay: by how much, and on which lists, every member of each. What it would touch is counted as the choice changes, so the
-- number of members is on screen before anything happens to them.
--
function P:OpenDecayDialog(cfgid)
  local pol = self
  local cfg = konfer:PolicyConfig(pol, cfgid)

  pol.dialogs = pol.dialogs or {}

  if (not pol.dialogs.decay) then
    local ypos = 0 - KUI.WIDGET_GAP
    local dlg = points_dialog("Konfer" .. pol.points.tag .. "DecayDialog", 220)
    local lw = KUI:WidestString({ L["Decay %"], L["Lists"] })

    dlg.Count = function(this)
      local lcfg = konfer:PolicyConfig(pol, this.cfgid)
      local n = 0

      for listid in pairs(this.lists) do
        n = n + #(lcfg and lcfg.lists[listid] and lcfg.lists[listid].users or {})
      end

      this.preview:SetText(strfmt(L["%d members will be decayed."], n))
    end

    dlg.pct = KUI:CreateEditBox({
      x = 4, y = ypos, charwidth = 2, numeric = true, len = 2, label = { text = L["Decay %"], pos = "LEFT", width = lw },
    }, dlg)
    ypos = ypos - dlg.pct:GetHeight() - KUI.WIDGET_GAP

    dlg.listdd = KUI:CreateDropDown({
      x = 4, y = ypos, mode = "MULTI", itemheight = 16, name = "Konfer" .. pol.points.tag .. "DecayLists", dwidth = 175,
      items = KUI.emptydropdown, title = { text = L["Lists"] }, label = { text = L["Lists"], pos = "LEFT", width = lw },
    }, dlg)
    dlg.listdd:Catch("OnItemChecked", function(t, evt, item, value, checked)
      dlg.lists[value] = checked and true or nil
      dlg:Count()
    end)
    ypos = ypos - dlg.listdd:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    dlg.preview = KUI:CreateStringLabel({ x = 4, y = ypos, width = 300, text = "", autosize = false }, dlg)
    ypos = ypos - 16

    fit(dlg, ypos)

    -- A percentage typed past either end of the range decays by that end, as the Admin tab's box saves one.
    dlg.OnAccept = function(t)
      local pct = tonumber(dlg.pct:GetText())

      pol:Decay(dlg.cfgid, pct and min(max(pct, DECAY_MIN_PCT), DECAY_MAX_PCT), dlg.lists)
      dlg:Hide()
    end

    pol.dialogs.decay = dlg
  end

  local dlg = pol.dialogs.decay
  local litems = {}

  dlg.cfgid = cfgid
  dlg.lists = {}

  -- Every list that is due, ticked. One that is not is there, dark, and cannot be ticked.
  for listid, rl in pairs(cfg.lists) do
    local due = pol:DecayCooldown(cfgid, listid) == 0

    dlg.lists[listid] = due or nil
    tinsert(litems, { text = rl.name, value = listid, enabled = due,
      checked = function() return dlg.lists[listid] and true or false end })
  end

  tsort(litems, function(a, b) return a.text < b.text end)

  dlg.listdd:UpdateItems(litems)
  dlg.pct:SetText(tostring(num(pol, "decay_pct", cfgid)))
  dlg:Count()
  dlg:SetTitleText(pol:WindowTitle(pol.points.words.DECAY_TITLE))
  over_main(dlg)
end

--
-- THE LISTS PAGE
--
-- The policy's panel on the Lists page: the four things an admin does to a list's numbers, awarding points, setting a
-- member's by hand, decaying, and running timed points. Under Decay, how long until the selected list is due for it again,
-- and under the timer what timed points are doing. A member's numbers are the members list's standing column.
--
local LISTS_BTN_H = 24
local LISTS_TINY_H = 10
local LISTS_WIDE_W = 165    -- The Announce buttons' width, above the panel on the Lists page

--
-- What is left of a decay cooldown in days, hours and minutes, leaving out days and hours there are none of, the minutes
-- rounded up so that it never reads 0m while it runs.
--
local function cooldown_text(secs)
  local m = ceil(secs / 60)
  local d, h = floor(m / 1440), floor(m / 60) % 24
  local parts = {}

  if (d > 0) then
    tinsert(parts, strfmt(L["%dd"], d))
  end

  if (h > 0) then
    tinsert(parts, strfmt(L["%dh"], h))
  end

  tinsert(parts, strfmt(L["%dm"], m % 60))

  return tconcat(parts, " ")
end

local function minutes_text(n)
  return (n == 1) and L["1 minute"] or strfmt(L["%d minutes"], n)
end

--
-- How long until the next timed award: in whole minutes counted up, so that the last of them reads 1 rather than 0, then
-- from 15 seconds in whole seconds and from 5 in tenths of one, as an open roll counts down.
--
local function next_text(secs)
  if (secs <= 5) then
    return strfmt(L["%.1fs"], max(0, secs))
  elseif (secs <= 15) then
    return strfmt(L["%ds"], ceil(secs))
  end

  return strfmt(L["%dm"], max(1, ceil(secs / 60)))
end

--
-- The panel is worked out again every second by the timed points tick, so a label or a button is only given a new text, or
-- told whether it can be pressed, when that differs from what it shows already, and an unchanged second redraws nothing. It
-- is asked what it shows rather than what it was last told here, so nothing set on it anywhere else can put the two out of
-- step.
--
local function show_text(lbl, text)
  if ((lbl.label:GetText() or "") ~= text) then
    lbl:SetText(text)
  end
end

local function show_button(btn, onoff, text)
  if (text and btn:GetText() ~= text) then
    btn:SetText(text)
  end

  if ((btn:IsEnabled() and true or false) ~= onoff) then
    btn:SetEnabled(onoff)
  end
end

-- Under the timer's button, what it awards and how often, and how long until the next (next_text), or nothing.
local function timer_status(pol)
  local running, _, amount, minutes, remaining = pol:TimerState()

  if (running) then
    show_text(pol.panel.timerstatus, strfmt(pol.points.words.TIMED_EVERY, amount, minutes_text(minutes)) .. "\n"
      .. strfmt(L["EPGP_TIMED_NEXT"], next_text(remaining)))
  else
    show_text(pol.panel.timerstatus, "")
  end
end

function P:RefreshPanel()
  local client = self.panel
  local W = self.points.words

  if (not client or not client.awardbutton) then
    return
  end

  local cfgid = self.currentid
  local adm = cfgid and konfer:PolicyAdmin(self) and true or false
  local listid = client.listid

  show_button(client.awardbutton, adm and listid ~= nil)
  show_button(client.adjustbutton, adm and listid ~= nil and client.uid ~= nil)
  local decays = (cfgid ~= nil) and self:DecayOn(cfgid)
  local cd = (decays and listid) and self:DecayCooldown(cfgid, listid) or 0

  show_button(client.decaybutton, adm and decays and listid ~= nil and cd == 0)
  show_text(client.decaycd, (cd > 0) and cooldown_text(cd) or "")

  local running = self:TimerState()

  show_button(client.timerbutton, adm and (running or (listid ~= nil and konfer.raid.uidmap ~= nil)),
    running and W.TIMER_STOP or W.TIMER_START)
  timer_status(self)
end

local function lists_construct(pol, client)
  local W = pol.points.words
  local BW = 98
  local ypos = 0

  pol.panel = client

  client.awardbutton = KUI:CreateButton({ x = 0, y = ypos, width = BW, height = LISTS_BTN_H, text = W.AWARD_BUTTON,
    enabled = false, tooltip = { title = "$$", text = W.TIP_AWARD } }, client)
  client.awardbutton:Catch("OnClick", function()
    pol:OpenAwardDialog(pol.currentid, client.listid)
  end)

  client.adjustbutton = KUI:CreateButton({ x = 100, y = ypos, width = BW, height = LISTS_BTN_H, text = L["Adjust"],
    enabled = false, tooltip = { title = "$$", text = W.TIP_ADJUST } }, client)
  client.adjustbutton:Catch("OnClick", function()
    pol:OpenAdjustDialog(pol.currentid, client.listid, client.uid)
  end)
  ypos = ypos - LISTS_BTN_H - KUI.WIDGET_GAP

  --
  -- Decay and timed points each have a line of their own, centred, the timer's button as wide as the Announce buttons above
  -- the panel so that its longer words fit. Under each, in the tiny font and as wide as its button: how long until Decay may
  -- be pressed, and timed points' two lines.
  --
  client.decaybutton = KUI:CreateButton({ x = "CENTER", y = ypos, width = BW, height = LISTS_BTN_H, text = L["Decay"],
    enabled = false, tooltip = { title = "$$", text = W.TIP_DECAY } }, client)
  client.decaybutton:Catch("OnClick", function()
    pol:OpenDecayDialog(pol.currentid)
  end)
  ypos = ypos - LISTS_BTN_H

  client.decaycd = KUI:CreateStringLabel({ x = "CENTER", y = ypos, width = BW, height = LISTS_TINY_H, text = "",
    autosize = false, font = "GameFontNormalTiny2", justifyh = "CENTER" }, client)
  client.decaycd.label:SetPoint("TOPLEFT", client.decaycd, "TOPLEFT", 0, 0)
  client.decaycd.label:SetPoint("BOTTOMRIGHT", client.decaycd, "BOTTOMRIGHT", 0, 0)
  ypos = ypos - LISTS_TINY_H - KUI.WIDGET_GAP

  client.timerbutton = KUI:CreateButton({ x = "CENTER", y = ypos, width = LISTS_WIDE_W, height = LISTS_BTN_H,
    text = W.TIMER_START, enabled = false, tooltip = { title = "$$", text = W.TIP_TIMER } }, client)
  client.timerbutton:Catch("OnClick", function()
    if (pol.timer) then
      pol:StopTimer(pol.currentid)
    elseif (client.listid) then
      pol:StartTimer(pol.currentid, client.listid)
    end
  end)
  ypos = ypos - LISTS_BTN_H

  client.timerstatus = KUI:CreateStringLabel({ x = "CENTER", y = ypos, width = LISTS_WIDE_W,
    height = LISTS_TINY_H + LISTS_TINY_H, text = "", autosize = false, font = "GameFontNormalTiny2", justifyh = "CENTER",
    justifyv = "TOP" }, client)
  client.timerstatus.label:SetPoint("TOPLEFT", client.timerstatus, "TOPLEFT", 0, 0)
  client.timerstatus.label:SetPoint("BOTTOMRIGHT", client.timerstatus, "BOTTOMRIGHT", 0, 0)

  -- Tenths of a second are more than the once a second tick shows, so while it is up the countdown puts itself right every
  -- frame, which changes nothing at all while what it shows has not.
  client.timerstatus:SetScript("OnUpdate", function()
    timer_status(pol)
  end)

  pol:RefreshPanel()
end

--
-- THE JOURNAL TAB
--
-- A list's journal on a tab of the Lists page, newest first: when, who made it, the amount each member in the raid had or
-- the decay, and why. Hovering an entry names everybody it reached, in their class colours. There is nothing to do with an
-- entry, so clicking one selects nothing. An entry of the policy's own is drawn by its JournalText.
--
-- The tab has the whole page, the column of lists hidden under it, so it chooses its list for itself, in a dropdown centred
-- at its foot. Each time the tab is shown that starts on the config's default list, or on the list selected on the page
-- where the config has none, and choosing another here leaves the page's selection where it was.
--
local JOURNAL_WHEN, JOURNAL_WHO, JOURNAL_WHAT, JOURNAL_WHY = 1, 2, 3, 4

--
-- How wide a line of names in an entry's tooltip runs before the next starts. The names are packed into lines here rather
-- than wrapped by the tooltip, whose width would have to be set on GameTooltip, which every addon shares and nothing resets.
--
local JOURNAL_TIP_WIDTH = 320

-- A column of amounts headed with the number they are of, EP or DKP, here and in the Awards panel.
local EARN_COL_W = 48

-- Where the list chooser starts: the config's default list where it has one, otherwise the list selected on the page.
local function journal_start(pol, client)
  local cfg = client.cfgid and konfer:PolicyConfig(pol, client.cfgid)
  local def = cfg and cfg.settings.def_list

  if (def and cfg.lists[def]) then
    return def
  end

  return client.pagelist
end

function P:RefreshJournal()
  local client = self.journaltab

  if (not client) then
    return
  end

  local cfg = client.cfgid and konfer:PolicyConfig(self, client.cfgid)
  local rl = cfg and client.listid and cfg.lists[client.listid]
  local rows, at = {}, {}

  for i, e in ipairs((rl and rl.journal) or {}) do
    tinsert(rows, e)
    at[e] = i
  end

  -- Two made in the same second stand in the order they were made, the later above.
  tsort(rows, function(a, b)
    local ta, tb = tonumber(a.t) or 0, tonumber(b.t) or 0

    if (ta ~= tb) then
      return ta > tb
    end

    return at[a] > at[b]
  end)

  client.rows = rows
  client.list:UpdateList(#rows)
end

--
-- Another admin has brought config CFGID up to date. The Journal tab and the Lists page's panel show the policy's own reading
-- of a config, which the platform does not redraw for a policy that is not the active one, so each is redrawn if it shows
-- CFGID.
--
function P:ConfigSynced(cfgid, how)
  if (self.journaltab and self.journaltab.cfgid == cfgid) then
    self:RefreshJournal()
  end

  if (self.currentid == cfgid) then
    self:RefreshPanel()
  end
end

--
-- What an entry of the journal says in the What and Why columns, and on the first line of its tooltip. The two the shared
-- half makes, an award and a decay, are said here. Any other is the policy's own, and its JournalText says it.
--
local function journal_text(pol, e, by)
  local W = pol.points.words

  if (e.k == "d") then
    return strfmt("-%d%%", tonumber(e.pct) or 0), L["Decay"], strfmt(L["%d%% decay by %s"], tonumber(e.pct) or 0, by)
  elseif (e.k == "e") then
    local amount = tonumber(e[pol.points.earn]) or 0

    return tostring(amount), e.r or "", strfmt(W.JOURNAL_AWARDED, amount, by)
  elseif (pol.JournalText) then
    return pol:JournalText(e, by)
  end

  return "", "", ""
end

local function journal_setitem(pol, idx, row)
  local client = pol.journaltab
  local e = client.rows[idx]
  local cfg = client.cfgid and konfer:PolicyConfig(pol, client.cfgid)
  local by = (cfg and e.by) and shortaclass(cfg:UserNameClass(e.by)) or K.NOBODY_STR
  local what, why = journal_text(pol, e, by)

  row.entry = e
  -- Displayed in local time.
  row:SetCell(JOURNAL_WHEN, date("%m-%d %H:%M", tonumber(e.t) or 0))
  row:SetCell(JOURNAL_WHO, by)
  row:SetCell(JOURNAL_WHAT, what)
  row:SetCell(JOURNAL_WHY, why)
  row:Show()
end

local function journal_tooltip(pol, row)
  local e = row.entry
  local cfgid = pol.journaltab.cfgid
  local cfg = e and cfgid and konfer:PolicyConfig(pol, cfgid)

  if (not cfg) then
    return
  end

  local by = e.by and shortaclass(cfg:UserNameClass(e.by)) or K.NOBODY_STR
  local names = {}

  for _, uid in ipairs(konfer:SplitRaidList(e.u or "")) do
    local name, cls = cfg:UserNameClass(uid)

    tinsert(names, { plain = K.DisplayName(name) or "", text = shortaclass(name, cls) })
  end

  tsort(names, function(a, b)
    return strlower(a.plain) < strlower(b.plain)
  end)

  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine((select(3, journal_text(pol, e, by))))

  -- The names run on with a space between each, as many to a line as JOURNAL_TIP_WIDTH holds.
  local line, plain = "", ""

  for _, n in ipairs(names) do
    local more = (plain == "") and n.plain or (plain .. " " .. n.plain)

    if (plain ~= "" and KUI:MeasureStrWidth(more, "GameTooltipText") > JOURNAL_TIP_WIDTH) then
      GameTooltip:AddLine(line)
      line, plain = n.text, n.plain
    else
      line = (line == "") and n.text or (line .. " " .. n.text)
      plain = more
    end
  end

  if (line ~= "") then
    GameTooltip:AddLine(line)
  end

  GameTooltip:Show()
end

local function journal_construct(pol, client)
  pol.journaltab = client

  -- The list whose journal it is, centred at the foot of the tab as the config selector is set in the top bar.
  client.listsel = KUI:CreateDropDown({
    x = 0, y = 0, name = "Konfer" .. pol.points.tag .. "JournalListDropdown", itemheight = 16, dwidth = 150,
    items = KUI.emptydropdown,
  }, client)
  client.listsel:ClearAllPoints()
  client.listsel:SetPoint("BOTTOM", client, "BOTTOM", 0, 0)
  client.listsel:Catch("OnValueChanged", function(this, evt, nv, user)
    if (user) then
      client.listid = nv
      pol:RefreshJournal()
    end
  end)

  client:HookScript("OnShow", function(this)
    this.listid = journal_start(pol, this)
    this.listsel:SetValue(this.listid, true)
    pol:RefreshJournal()
  end)

  -- The entries fill the rest of the tab above it, their header standing 6 off the tabs.
  local lframe = KUI.MakeFrame("Frame", nil, client)

  lframe:SetPoint("TOPLEFT", client, "TOPLEFT", 0, -6)
  lframe:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0, client.listsel:GetHeight() + KUI.WIDGET_GAP)

  client.rows = {}
  client.list = KUI:CreateColumnList({
    name = "Konfer" .. pol.points.tag .. "JournalList",
    columns = {
      { key = JOURNAL_WHEN, text = L["When"], width = 88 },
      { key = JOURNAL_WHO, text = L["Who"], width = 88 },
      { key = JOURNAL_WHAT, text = pol.points.words.FIELDS[pol.points.earn], width = EARN_COL_W },
      { key = JOURNAL_WHY, text = L["Reason"], width = "fill" },
    },
    setitem = function(cl, idx, slot, row)
      return journal_setitem(pol, idx, row)
    end,
    newrow = function(cl, row, n)
      row:HookScript("OnEnter", function(this)
        journal_tooltip(pol, this)
      end)

      row:HookScript("OnLeave", function(this)
        GameTooltip:Hide()
      end)

      row:SetScript("OnClick", function(this)
      end)
    end,
  }, lframe)
end

--
-- The list selected on the page, or the lists refreshed: the dropdown offers the config's lists as they now stand, and the
-- page's list is kept for the tab to start from. The journal shown stays on the one chosen here while it exists, and
-- another config, or that list gone, starts again where the tab would.
--
-- A refresh deselects the page's list and selects it again, so a list is the page's and nothing, within one config, is not.
--
local function journal_list_selection(pol, client, cfgid, listid)
  local cfg = cfgid and konfer:PolicyConfig(pol, cfgid)
  local items = {}
  local fresh = cfgid ~= client.cfgid

  for _, v in ipairs(cfg and cfg:ListChoices() or {}) do
    if (cfg.lists[v.value]) then
      tinsert(items, v)
    end
  end

  client.cfgid = cfgid

  if (fresh or listid) then
    client.pagelist = listid
  end

  if (fresh or not (cfg and client.listid and cfg.lists[client.listid])) then
    client.listid = journal_start(pol, client)
  end

  client.listsel:UpdateItems(items)
  client.listsel:SetValue(client.listid, true)
  client.listsel:SetEnabled(#items > 0)
  pol:RefreshJournal()
end

--
-- IMPORTING MEMBERS AND ADDING THE MISSING
--
-- Where somebody lands on a list means nothing here, their numbers deciding where they stand, so importing is a matter of
-- who: a guild rank, or names typed in, separated by commas or as a JSON array, set as the whole list or added to it.
-- Everybody new starts at nothing. Or a roster of Classic Loot Manager's, from its standings exported as JSON and pasted
-- where the names go, whose members come with their numbers, which replace any they have here.
--
local function member_dialog(name, height)
  local dlg = points_dialog(name, height)

  dlg:Catch("OnHide", function(t, evt)
    konfer.mainwin:Show()
  end)

  return dlg
end

--
-- The rosters of this policy's kind in TEXT, a CLM export of standings in JSON, in the export's order. Nil and why when TEXT
-- is not one or holds none.
--
local function clm_rosters(pol, text)
  local ok, t = pcall(JSON.decode, text)
  local rosters = ok and type(t) == "table" and type(t.standings) == "table" and t.standings.roster

  if (type(rosters) ~= "table") then
    return nil, L["that is not a CLM standings export."]
  end

  local out = {}

  for _, r in ipairs(rosters) do
    if (pol.points.clm and type(r) == "table" and r.type == pol.points.clm.type and type(r.standings) == "table") then
      tinsert(out, r)
    end
  end

  if (#out == 0) then
    return nil, strfmt(L["that export has no %s roster."], pol.name)
  end

  return out
end

--
-- The members of R, a CLM roster, onto LISTID of CFG with CLM's numbers for them, set as the whole list with SETALL or added
-- to it. Somebody the config does not hold is made a user with CLM's class, as a guild import makes them.
--
local function import_clm(pol, cfg, listid, r, setall)
  local spec = pol.points
  local players, members, vals = {}, {}, {}

  for _, pl in ipairs(type(r.standings.player) == "table" and r.standings.player or {}) do
    if (type(pl) == "table" and type(pl.name) == "string") then
      local cls = type(pl.class) == "string" and K.ClassIndex[strupper(strgsub(pl.class, " ", ""))] or nil

      tinsert(players, pl)
      tinsert(members, { name = pl.name, class = cls })
    end
  end

  local uids, byindex = cfg:ImportMembers(listid, members)

  for i, pl in ipairs(players) do
    if (byindex[i]) then
      local nums = spec.clm.numbers(pl, type(r.config) == "table" and r.config or {})

      for f = 1, #spec.fields do
        nums[f] = floor((tonumber(nums[f]) or 0) + 0.5)
      end

      vals[byindex[i]] = nums
    end
  end

  if (setall) then
    cfg:SetMemberList(tconcat(uids, ""), listid)
  else
    for _, uid in ipairs(uids) do
      if (not cfg:IsInList(uid, listid)) then
        cfg:InsertMember(uid, listid)
      end
    end
  end

  for _, uid in ipairs(uids) do
    pol:ApplySet(cfg, listid, uid, vals[uid], true)
    cfg:AddEvent(spec.events.set, listid, uid, unpack(vals[uid]))
  end
end

function P:ImportList(cfgid, listid)
  local pol = self
  local tag = pol.points.tag

  pol.dialogs = pol.dialogs or {}
  pol.importing = pol.importing or {}

  if (not pol.dialogs.import) then
    local ypos = 0 - KUI.WIDGET_GAP
    local dlg = member_dialog("Konfer" .. tag .. "ImportDialog", 250)

    dlg.Sync = function(this)
      this.grank:SetEnabled((K.player.is_guilded and this.text == "") and true or false)
      this.names:SetEnabled(this.rank == 0)
      this.roster:SetEnabled((this.rosters and this.rank == 0) and true or false)
      this.how:SetEnabled(this.text ~= "" and this.rank == 0)
    end

    dlg.curlist = konfer:CurrentListBox(dlg, ypos)
    ypos = ypos - dlg.curlist:GetHeight() - KUI.WIDGET_GAP

    dlg.grank = KUI:CreateDropDown({
      x = 4, y = ypos, dwidth = 150, mode = "SINGLE", itemheight = 16, items = KUI.emptydropdown,
      name = "Konfer" .. tag .. "ImportRank", label = { text = L["Guild rank to import"], pos = "LEFT" },
    }, dlg)
    dlg.grank:Catch("OnValueChanged", function(t, evt, newv)
      dlg.rank = tonumber(newv) or 0
      dlg:Sync()
    end)
    ypos = ypos - dlg.grank:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    -- A CLM export runs to tens of thousands of characters, so the box takes as many as are pasted.
    dlg.names = KUI:CreateEditBox({
      x = 4, y = ypos, width = 180, len = 0, label = { text = L["Names (CSV or JSON)"], pos = "LEFT" },
      tooltip = { title = "$$", text = L["TIP_POINTS_IMPORT_NAMES"] },
    }, dlg)
    dlg.names:Catch("OnValueChanged", function(t, evt, newv)
      local items = {}

      dlg.text = newv or ""
      dlg.rosters, dlg.why = nil, nil

      if (konfer:IsExportText(dlg.text)) then
        dlg.rosters, dlg.why = clm_rosters(pol, dlg.text)
      end

      for i, r in ipairs(dlg.rosters or {}) do
        tinsert(items, { text = tostring(r.name or r.uid), value = i })
      end

      dlg.rosterv = 1
      dlg.roster:UpdateItems(#items > 0 and items or KUI.emptydropdown)
      dlg.roster:SetValue(1)
      dlg:Sync()
    end)
    ypos = ypos - dlg.names:GetHeight() - KUI.WIDGET_GAP

    dlg.roster = KUI:CreateDropDown({
      x = 4, y = ypos, dwidth = 150, mode = "SINGLE", itemheight = 16, items = KUI.emptydropdown, enabled = false,
      name = "Konfer" .. tag .. "ImportRoster", label = { text = L["CLM roster"], pos = "LEFT" },
    }, dlg)
    dlg.roster:Catch("OnValueChanged", function(t, evt, newv)
      dlg.rosterv = tonumber(newv) or 1
    end)
    ypos = ypos - dlg.roster:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    local hows = {
      { text = L["Set list to imported values"], value = 1 },
      { text = L["Add to existing members"], value = 2 },
    }

    dlg.how = KUI:CreateDropDown({
      x = 16, y = ypos, mode = "SINGLE", itemheight = 16, name = "Konfer" .. tag .. "ImportHow", enabled = false,
      initialvalue = 2, dwidth = KUI:DropDownWidth({ hows[1].text, hows[2].text }), items = hows,
    }, dlg)
    dlg.how:Catch("OnValueChanged", function(t, evt, newv)
      dlg.howv = newv
    end)
    ypos = ypos - dlg.how:GetHeight()

    fit(dlg, ypos)

    dlg.OnAccept = function(t)
      local cfg = konfer:Config(pol.importing.cfgid)
      local lid = pol.importing.listid

      if (not cfg or not cfg.lists[lid]) then
        dlg:Hide()
        return
      end

      if (dlg.rank ~= 0) then
        for _, uid in ipairs(cfg:ImportGuildRank(lid, dlg.rank)) do
          if (not cfg:IsInList(uid, lid)) then
            cfg:InsertMember(uid, lid)
          end
        end
      elseif (konfer:IsExportText(dlg.text)) then
        local r = dlg.rosters and dlg.rosters[dlg.rosterv]

        if (not r) then
          pol:err(dlg.why or L["that is not a CLM standings export."])
          return
        end

        import_clm(pol, cfg, lid, r, dlg.howv == 1)
      elseif (dlg.text ~= "") then
        local names, why = konfer:ParseNames(dlg.text)

        if (not names) then
          pol:err(why)
          return
        end

        local uids, missing = cfg:ImportNames(lid, names)

        if (#missing > 0) then
          pol:err(L["The following users are missing from the user list: %s"], tconcat(missing, ", "))
          pol:err(L["Import from the CSV string cannot continue until these users are added."])
          return
        end

        if (dlg.howv == 1) then
          cfg:SetMemberList(tconcat(uids, ""), lid)
        else
          for _, uid in ipairs(uids) do
            if (not cfg:IsInList(uid, lid)) then
              cfg:InsertMember(uid, lid)
            end
          end
        end
      end

      dlg:Hide()
      konfer:RefreshAllMemberLists(lid)
    end

    pol.dialogs.import = dlg
  end

  local dlg = pol.dialogs.import
  local gitems = { { text = K.NONE_STR, value = 0 } }

  if (K.player.is_guilded) then
    for i = 1, K.guild.numranks do
      tinsert(gitems, { text = K.guild.ranks[i], value = i })
    end
  end

  pol.importing.cfgid, pol.importing.listid = cfgid, listid
  dlg.rank, dlg.text, dlg.howv = 0, "", dlg.howv or 2

  dlg.grank:UpdateItems(gitems)
  dlg.grank:SetValue(0)
  dlg.names:SetText("")
  dlg.how:SetValue(dlg.howv)
  dlg:Sync()
  konfer:ShowCurrentList(dlg.curlist, cfgid, listid)
  dlg:SetTitleText(pol:WindowTitle(L["Import list members"]))

  konfer.mainwin:Hide()
  dlg:Show()
end

function P:AddMissing(cfgid, listid)
  local pol = self

  pol.dialogs = pol.dialogs or {}
  pol.importing = pol.importing or {}

  if (not pol.dialogs.missing) then
    local ypos = 0
    local dlg = member_dialog("Konfer" .. pol.points.tag .. "AddMissingDialog", 150)

    dlg.curlist = konfer:CurrentListBox(dlg, ypos)
    ypos = ypos - dlg.curlist:GetHeight() - KUI.WIDGET_GAP

    local items = {
      { text = L["Add missing raid members"], value = 1 },
      { text = L["Add all missing members"], value = 2 },
    }

    dlg.what = KUI:CreateDropDown({
      x = KUI.WIDGET_GAP, y = ypos, mode = "SINGLE", itemheight = 16, name = "Konfer" .. pol.points.tag .. "WhoMissing",
      dwidth = KUI:DropDownWidth({ items[1].text, items[2].text }), items = items, initialvalue = 1,
      label = { text = L["Select"], pos = "LEFT" },
    }, dlg)
    dlg.what:Catch("OnValueChanged", function(t, evt, newv)
      dlg.whatv = tonumber(newv)
    end)
    ypos = ypos - dlg.what:GetHeight() - KUI.DROPDOWN_ADD_GAP

    fit(dlg, ypos)

    dlg.OnAccept = function(t)
      local cfg = konfer:Config(pol.importing.cfgid)
      local lid = pol.importing.listid
      local rl = cfg and cfg.lists[lid]

      if (rl) then
        for _, uid in ipairs(cfg:MissingFromList(lid, dlg.whatv == 1)) do
          cfg:InsertMember(uid, lid)
          pol:info(L["added %s to list %q."], shortaclass(cfg:UserNameClass(uid)), white(rl.name))
        end
      end

      dlg:Hide()
      konfer:RefreshAllMemberLists(lid)
    end

    pol.dialogs.missing = dlg
  end

  local dlg = pol.dialogs.missing

  pol.importing.cfgid, pol.importing.listid = cfgid, listid
  dlg.whatv = 1
  dlg.what:SetValue(1)
  konfer:ShowCurrentList(dlg.curlist, cfgid, listid)
  dlg:SetTitleText(pol:WindowTitle(L["Add missing members"]))

  konfer.mainwin:Hide()
  dlg:Show()
end

--
-- THE CONFIG PAGE
--
-- A policy's own panel on the Admin tab, and its tabs on the Config page, hold settings of its own. Every one of them is held
-- with the rest of its tab's changes until that tab's save bar is pressed, as "p." and the setting's name. See
-- konfer:AdminPending and konfer:PolicyTabPending, which OWNER.pending names for the fields it holds.
--
-- A number is written into the tab's changes only while what is typed is a number, so a half typed "0." changes nothing yet.
--
-- A box WIDTH wide, or with no WIDTH one that shows CHARS characters, five unless told, and takes as many. A number below MINV
-- or above MAXV, where either is given, is written as that end of the range.
--
function points.NumField(owner, parent, key, label, x, ypos, width, lw, justify, chars, minv, maxv)
  local eb = KUI:CreateEditBox({
    x = x, y = ypos, width = width, charwidth = (not width) and (chars or 5) or nil, len = chars or 8,
    label = { text = label, pos = "LEFT", width = lw, justifyh = justify },
  }, parent)

  eb:Catch("OnValueChanged", function(this, evt, val, user)
    local n = tonumber(val)

    if (user and n and owner.cfgid) then
      owner.pending():Set("p." .. key, min(max(n, minv or n), maxv or n))
    end
  end)

  owner.pending():Watch(eb, "p." .. key)
  owner.fields[key] = eb

  return eb
end

function points.CheckField(owner, parent, key, label, x, ypos, tip)
  local cb = KUI:CreateCheckBox({ x = x, y = ypos, label = { text = label }, tooltip = { title = "$$", text = tip } }, parent)

  cb:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and owner.cfgid) then
      owner.pending():Set("p." .. key, val and true or false)
      owner.checked(key, val and true or false)
    end
  end)

  owner.pending():Watch(cb, "p." .. key)
  owner.checks[key] = cb

  return cb
end

--
-- What the Admin tab's panel of a policy holds OWNER's widgets in, their unsaved changes being the tab's. CHECKED is told
-- whenever a box is ticked or cleared, for a policy whose options light each other.
--
function points.AdminOwner(checked)
  return { fields = {}, checks = {}, pending = function() return konfer:AdminPending() end,
    checked = checked or function() end }
end

--
-- Where the next label starts to follow BOX, the first on its line, whose own label is as wide as its words. GAP, else
-- INTERNAL_GAP, is the space between them, a new clause taking more.
--
local function after_box(box, gap)
  return box.label:GetWidth() + KUI.INTERNAL_GAP + box:GetWidth() + (gap or KUI.INTERNAL_GAP)
end

--
-- How a raid's awards are shared and decayed, into PARENT from YPOS, one line read as a sentence: "Standby gets (%) [100]
-- Decay by (%) [10]", each label as wide as its words and the second box following the first. The standby share holds three
-- characters and the decay two. Answers where the next thing would go. How much timed points award and how often are each
-- list's own, on the Lists page's Config tab (listcfg_construct).
--
function points:EarningFields(pol, owner, parent, ypos)
  local standby = points.NumField(owner, parent, "standby_pct", L["Standby gets (%)"], 0, ypos, nil, nil, nil, 3, 1, 200)

  points.NumField(owner, parent, "decay_pct", L["Decay by (%)"], after_box(standby, 12), ypos, nil, nil, nil, 2,
    DECAY_MIN_PCT, DECAY_MAX_PCT)

  return ypos - 20
end

--
-- THE AWARDS PANEL
--
-- The policy's second panel on the Admin tab (AdminPanel), the awards of the config picked there, a row each of the amount
-- and the description under their headings, by description. Under the list, past a separator, Create, and Edit and Delete
-- for the award selected, centred under the list and not its scroll bar. Create and Edit open the award dialog defining one,
-- and Delete takes the one selected out. None of the three waits for the tab's save bar: each is saved as it is made and
-- goes to the config's other admins as a PSSET.
--
local AWARDS_ROW_H = 16
local AWARDS_BTN_W = 80
local AWARDS_BTN_H = 24

local function awards_buttons(pol)
  local ui = pol.awardsui
  local sel = ui.enabled and ui.selected ~= nil

  ui.create:SetEnabled(ui.enabled)
  ui.edit:SetEnabled(sel)
  ui.delete:SetEnabled(sel)
end

-- Put the list back from the config, in the order its headings say, the award selected staying selected while it is there.
function P:RefreshAwards()
  local ui = self.awardsui
  local cfgid = self.cfgui and self.cfgui.cfgid

  if (not ui) then
    return
  end

  local keep = ui.selected
  local at = nil

  ui.sorted = cfgid and sorted_awards(awards_of(self, cfgid)) or {}
  ui.list:Sort(ui.sorted)
  ui.selected = nil
  ui.list:UpdateList(#ui.sorted)

  for i, s in ipairs(ui.sorted) do
    if (s.id == keep) then
      at = i
    end
  end

  ui.list:SetSelected(at, true, true)
  awards_buttons(self)
end

local function awards_construct(pol, client)
  local fname = "Konfer" .. pol.points.tag .. "Awards"
  local ui = { enabled = false, sorted = {} }

  pol.awardsui = ui

  -- The buttons' row is the list's width, the scroll bar's strip left out, and the three stand in the middle of it.
  local row = KUI.MakeFrame("Frame", nil, client)

  row:SetPoint("BOTTOMLEFT", client, "BOTTOMLEFT", 0, 0)
  row:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0 - KUI.SCROLLBAR_COMPENSATE, 0)
  row:SetHeight(AWARDS_BTN_H)

  local btns = KUI.MakeFrame("Frame", nil, row)
  local step = AWARDS_BTN_W + KUI.WIDGET_GAP

  btns:SetWidth(step + step + AWARDS_BTN_W)
  btns:SetHeight(AWARDS_BTN_H)
  btns:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)

  ui.create = KUI:CreateButton({ x = 0, y = 0, width = AWARDS_BTN_W, height = AWARDS_BTN_H, text = L["Create"],
    enabled = false, tooltip = { title = "$$", text = L["TIP_AWARD_CREATE"] } }, btns)
  ui.create:Catch("OnClick", function()
    pol:OpenAwardEditor(pol.cfgui.cfgid)
  end)

  ui.edit = KUI:CreateButton({ x = step, y = 0, width = AWARDS_BTN_W, height = AWARDS_BTN_H, text = L["Edit"],
    enabled = false, tooltip = { title = "$$", text = L["TIP_AWARD_EDIT"] } }, btns)
  ui.edit:Catch("OnClick", function()
    pol:OpenAwardEditor(pol.cfgui.cfgid, ui.selected)
  end)

  ui.delete = KUI:CreateButton({ x = step + step, y = 0, width = AWARDS_BTN_W, height = AWARDS_BTN_H, text = L["Delete"],
    enabled = false, tooltip = { title = "$$", text = L["TIP_AWARD_DELETE"] } }, btns)
  -- Every other admin loses the award too, and any list whose boss kill it was offers none, so it is asked first.
  ui.delete:Catch("OnClick", function()
    local cfgid = pol.cfgui.cfgid
    local aw = awards_of(pol, cfgid)[ui.selected]

    if (not aw) then
      return
    end

    local function yes(kmod, arg)
      if (ui.selected == arg.id) then
        ui.selected = nil
      end

      pol:DeleteAward(arg.cfgid, arg.id)
    end

    K.ConfirmationDialog(konfer, { text = L["Delete award"], owner = pol }, L["DELAWARD"], { L["Award: %s"], aw.d }, yes,
      { cfgid = cfgid, id = ui.selected }, konfer.mainwin, 140)
  end)

  local above = AWARDS_BTN_H + KUI.WIDGET_GAP

  ui.separator = KUI:CreateSeparator({ x = 0, y = 0 }, client)
  ui.separator:ClearAllPoints()
  ui.separator:SetPoint("BOTTOMLEFT", client, "BOTTOMLEFT", 0, above)
  ui.separator:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0, above)

  -- The list takes the rest, a frame of its own because a scroll list fills whatever it is given.
  local lframe = KUI.MakeFrame("Frame", nil, client)

  lframe:SetPoint("TOPLEFT", client, "TOPLEFT", 0, 0)
  lframe:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0, above + ui.separator:GetHeight() + KUI.WIDGET_GAP)

  --
  -- Two columns under their headings, the amount headed EP or DKP, and the description taking the rest. Either heading sorts
  -- the list by it, starting by description, the order the awards are offered in everywhere else.
  --
  ui.list = KUI:CreateColumnList({
    name = fname .. "List",
    itemheight = AWARDS_ROW_H,
    sortkey = "d",
    columns = {
      { key = "a", text = pol.points.words.FIELDS[pol.points.earn], width = EARN_COL_W, sort = true },
      { key = "d", text = L["Description"], width = "fill", sort = true },
    },
    setitem = function(cl, idx, slot, row)
      local s = ui.sorted[idx]

      row:SetCell("a", s and tostring(s.aw.a) or "")
      row:SetCell("d", s and s.aw.d or "")
    end,
    selectitem = function(cl, idx, slot, row, onoff)
      ui.selected = (onoff and ui.sorted[idx]) and ui.sorted[idx].id or nil
      awards_buttons(pol)
    end,
  }, lframe)
  ui.list:Catch("OnSort", function()
    pol:RefreshAwards()
  end)
end

--
-- A LIST'S BOSS KILL AND WIPE AWARDS, AND ITS TIMED POINTS
--
-- Which of the config's awards a boss kill on a list offers (the list's option boss_award), and which a wipe on a boss
-- offers (wipe_award), each none for nothing, on the Lists page's Config tab. A list starts on the two a config is made with.
--
-- Under them, how much timed points award on the list and how often (time_award and time_minutes), one line read as a
-- sentence, "Timed EP [50] EP every [30] minutes", which is what the timer started on the list awards (StartTimer). Both
-- are held with the rest of the tab's changes until its save bar is pressed, like everything else about a list. The minutes
-- are TIMER_MIN_MINUTES to TIMER_MAX_MINUTES, a number typed past either end held as that end.
--
local function listcfg_construct(pol, client)
  local lp = konfer:ListsPending()
  local lw = KUI:WidestString({ L["Boss kill award"], L["Boss wipe award"] })

  local function award_dd(key, ypos, name, label, tip)
    local dd = KUI:CreateDropDown({
      x = 0, y = ypos, name = "Konfer" .. pol.points.tag .. name, mode = "SINGLE", itemheight = 16,
      dwidth = AWARD_DESC_W, items = KUI.emptydropdown, enabled = false,
      label = { text = label, pos = "LEFT", width = lw }, tooltip = { title = "$$", text = tip },
    }, client)
    dd:Catch("OnValueChanged", function(this, evt, nv, user)
      if (user and client.listid) then
        konfer:ListsPending():Set("p." .. key, nv)
      end
    end)
    lp:Watch(dd, "p." .. key)

    return dd
  end

  client.bossaward = award_dd("boss_award", 0, "BossAward", L["Boss kill award"], L["TIP_BOSS_AWARD"])

  local ypos = 0 - client.bossaward:GetHeight() - KUI.WIDGET_GAP

  client.wipeaward = award_dd("wipe_award", ypos, "WipeAward", L["Boss wipe award"], L["TIP_WIPE_AWARD"])
  ypos = ypos - client.wipeaward:GetHeight() - KUI.WIDGET_GAP

  --
  -- The two boxes are NumField's, whose owner here is the list's changes. A number typed is held only while a list is
  -- selected, which is what the owner's cfgid says: listcfg_selection points it at the list, and at nothing for none.
  --
  local W = pol.points.words

  client.timed = { fields = {}, checks = {}, pending = function() return konfer:ListsPending() end, checked = function() end }

  local amount = points.NumField(client.timed, client, "time_award", W.TIME_AMOUNT, 0, ypos)
  local every = points.NumField(client.timed, client, "time_minutes", W.TIME_EVERY, after_box(amount), ypos, nil, nil, nil,
    3, TIMER_MIN_MINUTES, TIMER_MAX_MINUTES)
  -- The word after the box is the box's, and is dark with it.
  client.minutes = KUI:CreateStringLabel({ text = L["minutes"], font = "GameFontNormal" }, client)
  client.minutes:SetPoint("LEFT", every, "RIGHT", KUI.INTERNAL_GAP, 0)

  return 0 - ypos + 20
end

--
-- The list selected on the page, or the lists or the awards changed: offer the config's awards as they stand, and show the
-- list's, none where it names one there is no longer. The timed boxes show the list's own, and are dark with none.
--
local function listcfg_selection(pol, client, cfgid, listid)
  local awards = cfgid and awards_of(pol, cfgid) or {}

  client.cfgid, client.listid = cfgid, listid
  client.timed.cfgid = listid and cfgid or nil

  for key, dd in pairs({ boss_award = client.bossaward, wipe_award = client.wipeaward }) do
    local v = listid and konfer:ListsPending():Value("p." .. key)

    dd:UpdateItems(award_choices(awards, K.NONE_STR))
    dd:SetValue((v and awards[v]) and v or "0", true)
    dd:SetEnabled(listid ~= nil)
  end

  for key, eb in pairs(client.timed.fields) do
    local v = listid and konfer:ListsPending():Value("p." .. key)

    eb:SetText(v and tostring(v) or "")
    eb:SetEnabled(listid ~= nil)
  end

  client.minutes:SetEnabled(listid ~= nil)
end

--
-- SETTING AND DELETING AN AWARD
--
-- An award is set, made or changed, as a whole, and deleted, each by an event of the policy's own carrying that award
-- alone (the awset and awdel events). Everything here showing CFG's awards is put back after either: the Awards panel where
-- the Admin tab has CFG picked, and a list's boss kill award where CFG is the config in hand.
--
local function awards_changed(pol, cfg)
  if (pol.cfgui and pol.cfgui.cfgid == cfg.id) then
    pol:RefreshAwards()
  end

  local lc = pol.listscfgframe

  if (lc and lc.bossaward and pol.currentid == cfg.id) then
    listcfg_selection(pol, lc, cfg.id, lc.listid)
  end
end

function P:ApplyAwardSet(cfg, id, aw, norefresh)
  local clean = (type(id) == "string") and clean_award(aw)

  if (not clean) then
    return
  end

  award_table(self, cfg)[id] = clean

  if (not norefresh) then
    awards_changed(self, cfg)
  end
end

function P:ApplyAwardDel(cfg, id, norefresh)
  award_table(self, cfg)[id] = nil

  if (not norefresh) then
    awards_changed(self, cfg)
  end
end

-- Make award ID of CFGID, or change it, to AW.
function P:SetAward(cfgid, id, aw)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local clean = cfg and clean_award(aw)

  if (not clean) then
    return false
  end

  self:ApplyAwardSet(cfg, id, clean)
  cfg:AddEvent(self.points.events.awset, id, clean)

  return true
end

function P:DeleteAward(cfgid, id)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (not cfg) then
    return false
  end

  self:ApplyAwardDel(cfg, id)
  cfg:AddEvent(self.points.events.awdel, id)

  return true
end

function P:RefreshConfigUI(cfgid)
  local owner = self.cfgui
  local cfp = owner and konfer:PolicyConfig(self, cfgid)

  if (not cfp) then
    return
  end

  local ap = konfer:AdminPending()

  owner.cfgid = cfgid

  for key, eb in pairs(owner.fields) do
    eb:SetText(tostring(ap:Value("p." .. key) or ""))
  end

  for key, cb in pairs(owner.checks) do
    local v = ap:Value("p." .. key) and true or false

    cb:SetChecked(v, true)
    owner.checked(key, v)
  end

  self:RefreshAwards()

  -- The Lists page's buttons follow the settings, the Decay button waiting on the decayswitch, and its lists offer the awards.
  self:RefreshPanel()

  local lc = self.listscfgframe

  if (lc and lc.bossaward) then
    listcfg_selection(self, lc, self.currentid, lc.listid)
  end
end

function P:EnableConfigUI(onoff, cfgid)
  local owner = self.cfgui

  if (not owner) then
    return
  end

  if (not onoff) then
    owner.cfgid = nil
  end

  for _, eb in pairs(owner.fields) do
    eb:SetEnabled(onoff)
  end

  for _, cb in pairs(owner.checks) do
    cb:SetEnabled(onoff)
  end

  if (onoff) then
    for key, cb in pairs(owner.checks) do
      owner.checked(key, cb:GetChecked() and true or false)
    end
  end

  if (self.awardsui) then
    self.awardsui.enabled = onoff and true or false
    self.awardsui.list:SetEnabled(onoff and true or false)
    self:RefreshAwards()
  end
end

--
-- THE ADVANCED TAB
--
-- A points policy's own tab on the Config page (ConfigTabs): the price of gear, in two panels. Parameters holds what the other
-- kinds of win cost and, beside them, the costing model, with the two settings only the classic model's formula reads stood
-- in under it: the item level an item costs its slot's value times PRICE_BASE at, and how many levels double that. Gear
-- values holds the value of every slot, a multiplier under the classic model and a price under the fixed. Each is laid out
-- in columns, the labels of a column set against their boxes the standard gap from each so that the boxes line up down it,
-- and every box takes four characters. Under the two panels, a warning and what the two models are.
--
local ADV_CHARS = 4
local ADV_COL_GAP = 32
local ADV_GEAR_GAP = 56
local ADV_WARN_INSET = 4
local ADV_WARN_SIDE = 12
local ADV_ROW_H = 20
-- How far the classic model's two settings stand in from the costing model above them.
local ADV_INDENT = 16
-- The space between the warning and what the two models are, and between each part of that.
local ADV_TEXT_GAP = 10
local ADV_PARA_GAP = 5
-- How far the formula's numerator and denominator stand off the line between them, and the fraction off the x = before it.
local ADV_FRAC_GAP = 2
-- The space between the formula and what its x is.
local ADV_WHERE_GAP = 24
-- How far the power stands off the 2 it raises, and how far above the top of the 2 its own top is.
local ADV_POWER_GAP = 1
local ADV_POWER_RAISE = 4

-- The settings only the classic model's formula reads.
local CLASSIC_ONLY = { std_ilvl = true, ilvl_denom = true }

-- What a slot is called: its own word where it has one, else the game's name for its equip location.
local function slot_label(s)
  return s.label or _G[s.locs[1]] or s.key
end

--
-- COLUMNS into CLIENT, each an array of { key, label }. GAP is the space between one column's boxes and the next column's
-- labels. Answers how tall the tallest column is and how wide the lot.
--
local function advanced_columns(owner, client, columns, gap)
  local x = 0
  local most = 0

  for c, col in ipairs(columns) do
    local labels = {}

    for _, r in ipairs(col) do
      tinsert(labels, r[2])
    end

    local lw = (KUI:WidestString(labels))
    local bw = 0

    for i, r in ipairs(col) do
      local eb = points.NumField(owner, client, r[1], r[2], x, 0 - (i - 1) * (ADV_ROW_H + KUI.WIDGET_GAP), nil, lw,
        "RIGHT", ADV_CHARS)

      bw = eb:GetWidth()
    end

    most = max(most, #col)
    x = x + lw + KUI.INTERNAL_GAP + bw

    if (c < #columns) then
      x = x + (gap or ADV_COL_GAP)
    end
  end

  return most * ADV_ROW_H + (most - 1) * KUI.WIDGET_GAP, x
end

--
-- The classic formula set as it would be printed, in the white a formula stands out in: the policy's UNIT = PRICE_BASE
-- · 2 raised to the power x, the multiplication a middle dot so that it is never read as another x, and the x smaller and
-- above the 2. Beside it, x = the fraction, its numerator over a line over its denominator, the words of both halves level
-- with the line. The line is a hairline in the words' colour, as a menu's is. Answers a frame for PARENT, the formula
-- centred across whatever width it is anchored to.
--
local function classic_formula(pol, parent)
  local W = pol.points.words
  local box = KUI.MakeFrame("Frame", nil, parent)
  local base = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  local power = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  local xis = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  local numer = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  local denom = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  local line = box:CreateTexture(nil, "ARTWORK")

  base:SetText(strfmt("%s = %d \194\183 2", W.UNIT, PRICE_BASE))
  power:SetText("x")
  xis:SetText("x =")
  numer:SetText(L["Item level"] .. " - " .. L["Standard item level"])
  denom:SetText(W.DOUBLES)

  local bw = base:GetStringWidth()
  local pw = power:GetStringWidth()
  local xw = xis:GetStringWidth()
  local fw = max(numer:GetStringWidth(), denom:GetStringWidth()) + ADV_FRAC_GAP + ADV_FRAC_GAP
  local liney = numer:GetStringHeight() + ADV_FRAC_GAP
  local wordsy = liney - floor(base:GetStringHeight() / 2)
  local at = 0 - (bw + ADV_POWER_GAP + pw + ADV_WHERE_GAP + xw + ADV_FRAC_GAP + fw) / 2

  base:SetPoint("TOPLEFT", box, "TOP", at, 0 - wordsy)
  at = at + bw + ADV_POWER_GAP
  power:SetPoint("TOPLEFT", box, "TOP", at, 0 - wordsy + ADV_POWER_RAISE)
  at = at + pw + ADV_WHERE_GAP
  xis:SetPoint("TOPLEFT", box, "TOP", at, 0 - wordsy)
  at = at + xw + ADV_FRAC_GAP
  numer:SetPoint("TOP", box, "TOP", at + fw / 2, 0)
  line:SetColorTexture(1, 1, 1, 0.9)
  line:SetSize(fw, 1)
  line:SetPoint("TOPLEFT", box, "TOP", at, 0 - liney)
  denom:SetPoint("TOP", box, "TOP", at + fw / 2, 0 - liney - 1 - ADV_FRAC_GAP)
  box:SetHeight(liney + 1 + ADV_FRAC_GAP + denom:GetStringHeight())

  return box
end

--
-- CFGID is the config picked in the Admin tab's list, or nil with none picked, when there is nothing for these to be about:
-- every box is emptied and disabled, and the panels' titles dimmed, as the Admin tab's own are. Otherwise every widget shows
-- what the tab holds, the classic model's two settings live only under that model.
--
local function advanced_refresh(pol, cfgid)
  local owner = pol.advui

  if (not owner) then
    return
  end

  local has = konfer:PolicyConfig(pol, cfgid) ~= nil

  owner.cfgid = has and cfgid or nil

  for _, p in ipairs(owner.panels) do
    p:SetEnabled(has)
  end

  owner.model:SetEnabled(has)

  if (not has) then
    for _, eb in pairs(owner.fields) do
      eb:SetEnabled(false)
      eb:SetText("")
    end

    return
  end

  local ap = konfer:PolicyTabPending(pol, "advanced")
  local fixed = ap:Value("p.cost_model") == COST_FIXED

  owner.model:SetValue(fixed and COST_FIXED or COST_CLASSIC, true)

  for key, eb in pairs(owner.fields) do
    local v = ap:Value("p." .. key)
    local n = tonumber(v)
    local gear = strmatch(key, "^price_") and true or false

    eb:SetEnabled(not (fixed and CLASSIC_ONLY[key]))

    -- A kind's multiplier is shown as x.yy, and so is a slot's gear value but for the fixed model's, which is a whole price.
    if (n and gear and fixed) then
      eb:SetText(strfmt("%d", floor(n + 0.5)))
    elseif (n and (gear or strmatch(key, "^mult_"))) then
      eb:SetText(strfmt("%.2f", n))
    else
      eb:SetText(tostring(v or ""))
    end
  end
end

local function advanced_construct(pol, tab)
  local W = pol.points.words
  local owner = { fields = {}, pending = function() return konfer:PolicyTabPending(pol, "advanced") end }

  pol.advui = owner

  local kinds = {
    { "mult_O", L["Off spec multiplier"] }, { "mult_T", L["Transmog multiplier"] }, { "mult_V", L["Vanity multiplier"] },
  }
  local classic = { { "std_ilvl", L["Standard item level"] }, { "ilvl_denom", W.DOUBLES } }

  -- Three columns, filled down one before the next.
  local third = ceil(#SLOTS / 3)
  local gear = { {}, {}, {} }

  for i, s in ipairs(SLOTS) do
    tinsert(gear[ceil(i / third)], { "price_" .. s.key, slot_label(s) })
  end

  --
  -- Parameters on top and Gear values under it, each exactly as tall as what it holds, and empty space under them that takes
  -- whatever the window grows by, as the Loot tab has.
  --
  local split = KUI:CreateHSplit({
    inset = 0, height = 0, topanchor = true, name = "Konfer" .. pol.points.tag .. "AdvancedSplit",
    toptitle = L["Parameters"], bottomborder = false, bottompadding = 0,
  }, tab)

  local gearsplit = KUI:CreateHSplit({
    inset = 0, height = 0, topanchor = true, name = "Konfer" .. pol.points.tag .. "GearSplit", toptitle = L["Gear values"],
    bottomborder = false,
  }, split.bottomframe)

  --
  -- The kinds' multipliers down the left. Down the right the costing model, its two choices on the row beside the words, and
  -- stood in under it the classic model's two settings, live only under that model.
  --
  local client = split.topframe
  local lh, lw = advanced_columns(owner, client, { kinds })
  local rx = lw + ADV_COL_GAP
  local model = KUI:CreateRadioGroup({
    x = rx, y = 0 - floor((ADV_ROW_H - KUI.CHECKBOX_SIZE) / 2), spacing = 16, initialvalue = COST_CLASSIC,
    label = { text = L["Costing model"], pos = "LEFT" },
    items = { { text = L["Classic"], value = COST_CLASSIC }, { text = L["Fixed"], value = COST_FIXED } },
  }, client)
  local labels = {}

  for _, r in ipairs(classic) do
    tinsert(labels, r[2])
  end

  local clw = (KUI:WidestString(labels))
  local ypos = 0 - ADV_ROW_H - KUI.WIDGET_GAP

  for _, r in ipairs(classic) do
    points.NumField(owner, client, r[1], r[2], rx + ADV_INDENT, ypos, nil, clw, "RIGHT", ADV_CHARS)
    ypos = ypos - ADV_ROW_H - KUI.WIDGET_GAP
  end

  split:SetSplitSize(max(lh, 0 - ypos - KUI.WIDGET_GAP))

  --
  -- A gear value is a multiplier under one model and a price under the other, so the model chosen brings its own gear values
  -- with it, held with the rest of the tab's changes.
  --
  model:Catch("OnValueChanged", function(this, evt, value, user)
    if (user and owner.cfgid) then
      local ap = owner.pending()

      ap:Set("p.cost_model", value)

      for _, s in ipairs(SLOTS) do
        ap:Set("p.price_" .. s.key, slot_default(s, value))
      end

      advanced_refresh(pol, owner.cfgid)
    end
  end)

  owner.pending():Watch(model, "p.cost_model")
  owner.model = model

  --
  -- The gear values in a frame of their own, exactly as big as they are and centred across the panel, the columns well apart.
  --
  local box = KUI.MakeFrame("Frame", nil, gearsplit.topframe)
  local h, w = advanced_columns(owner, box, gear, ADV_GEAR_GAP)

  box:SetSize(w, h)
  box:SetPoint("TOP", gearsplit.topframe, "TOP", 0, 0)
  gearsplit:SetSplitSize(h)
  owner.panels = { split.topinset, gearsplit.topinset }

  --
  -- Under them, in the space left, a word to anybody who does not know what these are, in a red that warns rather than
  -- alarms, and then what the two costing models are, in the gold of the labels above. Each part runs across the space clear
  -- of its sides and stands under the one before it, as tall as its words wrap to.
  --
  local below = gearsplit.bottomframe
  local prev = nil

  local function stack(part, gap)
    if (prev) then
      part:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0 - gap)
      part:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, 0 - gap)
    else
      part:SetPoint("TOPLEFT", below, "TOPLEFT", ADV_WARN_SIDE, 0 - gap)
      part:SetPoint("TOPRIGHT", below, "TOPRIGHT", 0 - ADV_WARN_SIDE, 0 - gap)
    end

    prev = part
  end

  local function para(text, font, justify, gap)
    local fs = below:CreateFontString(nil, "ARTWORK", font)

    fs:SetJustifyH(justify)
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetText(text)
    stack(fs, gap)

    return fs
  end

  local waist = nil

  for _, s in ipairs(SLOTS) do
    if (s.key == "WAIST") then
      waist = slot_label(s)
    end
  end

  local warn = para(W.ADV_WARNING, "GameFontNormal", "CENTER", ADV_WARN_INSET)

  warn:SetTextColor(0.72, 0.22, 0.22, 1)

  para(strfmt(W.COSTING_CLASSIC, white(L["Classic"])), "GameFontNormalSmall", "LEFT", ADV_TEXT_GAP)
  stack(classic_formula(pol, below), ADV_PARA_GAP)
  para(strfmt(W.COSTING_EXAMPLE, waist), "GameFontNormalSmall", "LEFT", ADV_PARA_GAP)
  para(strfmt(W.COSTING_FIXED, white(L["Fixed"])), "GameFontNormalSmall", "LEFT", ADV_PARA_GAP)
end

--
-- THE ITEM EDITOR
--
-- An item's custom price, what winning it costs as main spec in place of what its level and slot would make it (ItemPrice).
-- It is kept as the item's policy data, digits alone and at most four of them, and an empty box is no custom value. It means
-- nothing to an ignored item.
--
local function items_construct(pol, client, changed)
  local W = pol.points.words

  client.price = KUI:CreateEditBox({
    x = 0, y = 0, numeric = true, len = 4, charwidth = 4, enabled = false,
    label = { text = W.CUSTOM_PRICE, pos = "LEFT" }, tooltip = { title = "$$", text = W.TIP_CUSTOM },
  }, client)

  client.price:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and client.iinfo) then
      client.iinfo.pdata = tonumber(val)
      changed()
    end
  end)

  konfer:ItemsPending():Watch(client.price, "pdata")

  return client.price:GetHeight()
end

local function items_selection(client, cfgid, itemid, iinfo)
  client.iinfo = iinfo

  local price = iinfo and tonumber(iinfo.pdata)

  client.price:SetText(price and tostring(price) or "")
  client.price:SetEnabled(iinfo and not iinfo.ignore and true or false)
end

--
-- THE AWARD COMMAND
--
-- "/keg award list amount names", for a macro or for somebody who would rather type. LIST is a list's name, in double quotes
-- where it has a space in it, AMOUNT a whole number, below nothing for a penalty, and NAMES whoever it is for, as the award
-- dialog's These users takes them (NamedMembers). It awards on the policy's config in hand, for the reason every award made
-- from the command line is given, and only an admin of that config may.
--
local function award_command(pol, input)
  local lname, rest = strmatch(input or "", "^%s*\"([^\"]+)\"%s*(.*)$")

  if (not lname) then
    lname, rest = strmatch(input or "", "^%s*(%S+)%s*(.*)$")
  end

  local amount, names = strmatch(rest or "", "^(%-?%d+)%s+(.*%S)")

  if (not lname or not amount) then
    pol:err("%s/%s %s %s", L["Usage: "], pol.command, L["CMD_AWARD"], L["CMD_AWARD_ARGS"])
    return
  end

  if (not konfer:PolicyAdmin(pol)) then
    pol:err(L["you are not an administrator of this configuration. Your access to it is read-only."])
    return
  end

  local listid = pol.cfg:FindList(lname)

  if (not listid) then
    pol:err(L["there is no list called %q."], lname)
    return
  end

  pol:AwardNamed(pol.currentid, listid, tonumber(amount), L["Command line award"], names)
end

--
-- Build the shared half onto POL, a points policy's descriptor, before it registers. SPEC is as the top of this file has it.
-- Every method above goes onto the policy that has none of that name already, and its pages and tabs are made: the panel on
-- the Lists page, a list's boss kill and wipe awards on its Config tab, the Journal tab beside it and the journal and award
-- commands, the Awards panel on the Admin tab, the Advanced tab on the Config page after any of the policy's own, and its
-- section of the item editor. Every shared setting the policy's defaults leave out is added to them, the awards a config
-- starts with to its configdata where it names none of its own, and the boss kill and wipe awards and what timed points
-- award and how often to its list options, wherever the policy has not declared them itself.
--
function points:Setup(pol, spec)
  pol.points = spec

  for k, fn in pairs(P) do
    if (pol[k] == nil) then
      pol[k] = fn
    end
  end

  pol.defaults = pol.defaults or {}

  for k, v in pairs(points.DEFAULTS) do
    if (pol.defaults[k] == nil) then
      pol.defaults[k] = v
    end
  end

  for _, s in ipairs(SLOTS) do
    if (pol.defaults["price_" .. s.key] == nil) then
      pol.defaults["price_" .. s.key] = slot_default(s, pol.defaults.cost_model)
    end
  end

  pol.configdata = pol.configdata or {}

  for k, v in pairs(points.CONFIGDATA) do
    if (pol.configdata[k] == nil) then
      pol.configdata[k] = v
    end
  end

  pol.ListsPage = pol.ListsPage or {
    title = spec.words.PANEL_TITLE,
    height = LISTS_BTN_H + KUI.WIDGET_GAP + LISTS_BTN_H + LISTS_TINY_H + KUI.WIDGET_GAP + LISTS_BTN_H + LISTS_TINY_H
      + LISTS_TINY_H,
    Construct = function(client)
      return lists_construct(pol, client)
    end,
    -- The list picked is the one being worked on (CurrentList), whose numbers the Raid page shows.
    ListSelection = function(client, cfgid, listid)
      local was = client.listid

      client.listid = listid
      pol:RefreshPanel()

      if (listid ~= was) then
        konfer:RefreshPolicyPages()
      end
    end,
    MemberSelection = function(client, cfgid, listid, uid, pos)
      client.listid = listid
      client.uid = uid
      pol:RefreshPanel()
    end,
    ConfigConstruct = function(client)
      return listcfg_construct(pol, client)
    end,
    ConfigListSelection = function(client, cfgid, listid)
      return listcfg_selection(pol, client, cfgid, listid)
    end,
  }

  pol.listoptions = pol.listoptions or {}

  if (pol.listoptions.boss_award == nil) then
    pol.listoptions.boss_award = BOSS_AWARD
  end

  if (pol.listoptions.wipe_award == nil) then
    pol.listoptions.wipe_award = WIPE_AWARD
  end

  if (pol.listoptions.time_award == nil) then
    pol.listoptions.time_award = 5
  end

  if (pol.listoptions.time_minutes == nil) then
    pol.listoptions.time_minutes = 30
  end

  pol.AdminPanel = pol.AdminPanel or {
    title = L["Awards"],
    Construct = function(client)
      return awards_construct(pol, client)
    end,
  }

  pol.ListsTabs = pol.ListsTabs or {}
  tinsert(pol.ListsTabs, { name = "journal", text = L["Journal"], wholepage = true,
    Construct = function(client)
      return journal_construct(pol, client)
    end,
    ListSelection = function(client, cfgid, listid)
      return journal_list_selection(pol, client, cfgid, listid)
    end,
  })

  -- The journal command: the policy window on the Journal tab, which starts on its list as it always does.
  pol.Commands = pol.Commands or {}
  tinsert(pol.Commands, { word = L["CMD_JOURNAL"], help = spec.words.JOURNAL_HELP, Run = function(input, p)
    konfer.mainwin:Show()
    konfer.mainwin:SetPage(konfer.LISTS_PAGE, p.prefix .. "journal")
  end })

  tinsert(pol.Commands, { word = L["CMD_AWARD"], args = L["CMD_AWARD_ARGS"], help = spec.words.AWARD_HELP,
    Run = function(input, p)
      award_command(p, input)
    end })

  pol.ConfigTabs = pol.ConfigTabs or {}
  tinsert(pol.ConfigTabs, { name = "advanced", text = L["Advanced"], owneronly = true,
    Construct = function(tab, pending)
      return advanced_construct(pol, tab)
    end,
    Refresh = function(client, cfgid)
      return advanced_refresh(pol, cfgid)
    end,
  })

  pol.ItemsPage = pol.ItemsPage or {
    Construct = function(client, changed)
      return items_construct(pol, client, changed)
    end,
    ItemSelection = items_selection,
  }
end

--
-- THE EVENTS
--
-- What the shared half sends, answered for POL, a points policy once it has registered and been given its own copy of the
-- standard set. Each goes into that copy under the policy's own name for it, from its spec.
--
-- Every change to a member's numbers travels as the numbers it came to, never as what they were worked out from, so an admin
-- applying one does exactly what the sender did whatever their own view of the raid, the guild or the item.
--
-- award  listid when amount raid sbamount standby reason by
--        AMOUNT on LISTID at WHEN each to the members in RAID and SBAMOUNT each to those in STANDBY, both strings of uids run
--        together, REASON what it was for, a boss's name, timed points or anything typed, and BY the uid of the admin who
--        awarded it. BY is named rather than taken from the sender, a sync passing on events other admins made.
-- set    listid uid ...
--        UID's numbers on LISTID set by hand, in the spec's order.
-- decay  listid when pct uids by bases
--        PCT taken off the decaying numbers of every one of UIDS on LISTID at WHEN, by BY, the uid of the admin who decayed
--        it. Who was decayed, every member of the list as the sender held it, is named here, so every admin decays the same.
--        BASES, nil for none, is a table of field to the base that number decays towards (ApplyDecay), EP/GP's base GP, as
--        the sender held it, for the same reason.
-- timer  running listid amount minutes remaining
--        What timed points are doing: RUNNING, and if so AMOUNT on LISTID every MINUTES, the next in REMAINING seconds. Sent
--        by an admin who starts or stops it, by the master looter each time it awards, and in answer to timerq.
-- timerq
--        Asked by somebody who has lost track of timed points, to a reload or a disconnect, or on becoming master looter.
--        Whoever holds a running timer and whose word on it is taken says where it has got to, to the one who asked. Nobody
--        else answers, their answer being one that would not be taken.
-- awset  id award
--        The config's award ID made or changed, AWARD being the whole of it, { d, a, p, g, t } as AWARDS has it.
-- awdel  id
--        The config's award ID deleted.
--

--
-- Whether NAME's word on the timer is taken: one of CFG's admins, or anybody elevated in the raid (konfer:RaidRank), there
-- always being somebody. A master looter who was the only admin in the raid, and reloads, still hears where it had got to.
--
local function tells_timer(cfg, name)
  local uid = cfg:FindUser(name)

  return (uid ~= nil and cfg:IsAdmin(uid)) or konfer:RaidRank(name, cfg.id) ~= nil
end

function points:Events(pol)
  local ev = pol.points.events

  pol.ehandlers[ev.award] = function(self, live, sender, proto, p, cmd, cfg, ...)
    local listid, when, amount, raid, sbamount, standby, reason, by = ...

    p:ApplyAward(cfg, listid, tonumber(when) or 0, tonumber(amount) or 0, self:SplitRaidList(raid or ""),
      tonumber(sbamount) or 0, self:SplitRaidList(standby or ""), reason or "", by, not live)
  end

  pol.ehandlers[ev.set] = function(self, live, sender, proto, p, cmd, cfg, listid, uid, ...)
    local vals = {}

    for i = 1, #p.points.fields do
      vals[i] = (select(i, ...))
    end

    p:ApplySet(cfg, listid, uid, vals, not live)
  end

  pol.ehandlers[ev.decay] = function(self, live, sender, proto, p, cmd, cfg, ...)
    local listid, when, pct, uids, by, bases = ...

    p:ApplyDecay(cfg, listid, tonumber(when) or 0, tonumber(pct) or 0, self:SplitRaidList(uids or ""), by, bases, not live)
  end

  pol.ehandlers[ev.awset] = function(self, live, sender, proto, p, cmd, cfg, id, aw)
    p:ApplyAwardSet(cfg, id, aw, not live)
  end

  pol.ehandlers[ev.awdel] = function(self, live, sender, proto, p, cmd, cfg, id)
    p:ApplyAwardDel(cfg, id, not live)
  end

  pol.ihandlers[ev.timer] = function(self, sender, proto, p, cmd, cfg, ...)
    local running, listid, amount, minutes, remaining = ...

    if (sender == K.player.name or not tells_timer(cfg, sender)) then
      return
    end

    p:SetTimer(cfg.id, running and true or false, listid, amount, minutes, remaining)
  end

  pol.ihandlers[ev.timerq] = function(self, sender, proto, p, cmd, cfg, ...)
    local running, listid, amount, minutes, remaining = p:TimerState()

    if (sender == K.player.name or not running or not tells_timer(cfg, K.player.name)) then
      return
    end

    p:CSendWhisperAM(cfg.id, sender, ev.timer, "ALERT", running, listid, amount, minutes, remaining)
  end
end
