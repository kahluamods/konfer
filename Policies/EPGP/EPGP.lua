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
local points = konfer.points

local white = konfer.white

local tostring, tonumber, type = tostring, tonumber, type
local pairs, ipairs = pairs, ipairs
local strfmt = string.format
local strlower = string.lower
local tinsert = table.insert
local tsort = table.sort
local floor = math.floor
local max = math.max

local member_of = points.MemberOf

--
-- A priority has two places, which the standing column holds only a size down from the names beside it. The game's smaller
-- fonts are either a single point smaller or white, so this is the names' own font, gold and shadowed, at 8.
--
local STANDING_FONT = CreateFont("KonferEPGPStandingFont")

do
  STANDING_FONT:CopyFontObject("GameFontNormalSmall")
  local path, _, flags = STANDING_FONT:GetFont()

  if (path) then
    STANDING_FONT:SetFont(path, 8, flags)
  end
end

--
-- Effort Points / Gear Points.
--
-- A member earns effort points for turning up and killing things, and gains gear points for the loot they are given.
-- Priority is the ratio of the two, EP over GP, so the player who has contributed most relative to what they have taken is
-- first in line, and winning an item lowers your own priority by raising the denominator rather than by moving you down a
-- list. Every GP total has the config's base GP added before it divides, so that nobody starts at infinity.
--
-- Decay takes the same share off EP and off GP with its base, as the original EP/GP did, and GP never falls below the base.
-- So it leaves alone the priority of anybody whose GP is above the base and lowers only that of somebody at it, a newcomer or
-- somebody sitting on their priority rather than taking loot. The base is kept out of the stored GP all the same, so the
-- config may change it whenever it likes.
--
-- That is why both numbers live in the list's standings table: unlike Suicide Kings, where the order of the roll list is the
-- whole of a standing, here the order is computed from stored values and the array order means nothing. On a tethered list
-- the list holds mains, so the numbers are the person's; on one that is not, every character stands on its own.
--
-- Earning EP, decaying it, the journal of both and the price of an item are the half EP/GP shares with DKP, built onto this
-- descriptor by konfer.points (Policies/Points.lua). What is here is what is EP/GP's own: the ratio, and what winning does.
--
local epgp = {
  handle = "epgp",
  name = L["POLICY_EPGP_NAME"],
  nickname = L["POLICY_EPGP_NICK"],
  shortnick = L["POLICY_EPGP_SHORTNICK"],
  desc = L["POLICY_EPGP_DESC"],
  command = "keg",
  order = 2,
  accent = KUI.COLOR_AZURE,

  -- Every win is put to the master looter in the costing box, where the price in GP can be discounted.
  costing = true,

  StandingFields = { "ep", "gp" },
  standingfont = STANDING_FONT,

  -- A priority: four digits, a point and two places.
  standingwidth = 7,

  Strings = {
    AWARD_BUTTON    = L["Charge GP"],
    AWARD_EXTRALIST = L["Charge GP on additional list"],
    AWARD_ITEMLIST  = L["Charge GP on list"],
    AWARD_ROLL      = L["GP Roll (on list %q) for %s within %d seconds."],
    AWARD_UNDO      = L["Are you absolutely sure you want to undo this GP charge?"],
    AWARD_AUTO      = L["EPGP_AUTOCHARGE"],
    BID_STANDING    = L["PR %s"],
    MEMBERS_STANDING = L["PR"],
    ANNOUNCE_RAIDERS = L["raiders' priority on the %q list, highest first: "],
    ANNOUNCE_ALL     = L["members of the %q list by priority, highest first: "],
    COST             = L["Cost (GP)"],
  },
}

-- What base GP starts at, one standard item: the price of a slot with a gear value of 1.
local GP_BASE = points.PRICE_BASE

--
-- EP/GP's own settings, kept in each config's cfg.psettings under this handle and carried between admins as PSSET. The ones
-- the shared half reads, the standby share, the decay and the price of gear, are added by points:Setup at their shared
-- defaults, but for the costing model: EP/GP prices gear by the classic formula unless the config says otherwise, where DKP
-- prices it by slot. How much timed EP awards and how often are each list's own (listoptions), added by points:Setup the
-- same way.
--
-- bid_threshold and try_roll are edited on the platform's Loot tab, as every policy's are. The rest are this policy's panel
-- on the Admin tab, its Advanced tab, and the dialogs the Lists page's panel opens.
--
epgp.defaults = {
  bid_threshold = 3,      -- The item quality below which an item is not offered at all, rare unless told otherwise
  try_roll = false,       -- Whether nobody bidding opens a roll rather than ending the item
  gp_rolls = false,       -- Whether winning an open roll charges GP, as winning a bid does
  base_gp = GP_BASE,      -- Added to every GP total before it divides EP: one standard item, so a new member is not first in line
  min_ep = 50,            -- The EP a member needs before they win on priority: one short night's, less a quarter
  minep_bars = false,     -- True: below min_ep they may not bid at all. False: they bid, ranked below everybody above it
  cost_model = points.COST_CLASSIC, -- How an item's price is worked out, by its level (classic) or by its slot alone (fixed)
}

points:Setup(epgp, {
  tag = "EPGP",
  fields = { "ep", "gp" },
  earn = "ep",
  charge = "gp",
  decays = { "ep", "gp" },
  floors = function(cfgid)
    return { ep = 0 }
  end,
  -- GP decays towards base GP, as the original EP/GP's did, so decay leaves alone the priority of anybody above it.
  decaybase = function(cfgid)
    return { gp = tonumber(epgp:Setting("base_gp", cfgid)) or GP_BASE }
  end,
  events = { award = "KEGEP", set = "EGSET", decay = "EGDEC", timer = "EGTIM", timerq = "EGTRQ", awset = "EGAWS",
    awdel = "EGAWX" },
  -- CLM's EP/GP rosters, its point type 1, give EP as points and GP as spent. Its GP never falls below the roster's minimum
  -- GP and has it in, where GP here is over base GP, so the minimum comes off.
  clm = {
    type = 1,
    numbers = function(pl, config)
      return { tonumber(pl.points) or 0, max(0, (tonumber(pl.spent) or 0) - (tonumber(config.minGP) or 0)) }
    end,
  },
  words = {
    FIELDS = { ep = L["EP"], gp = L["GP"] },
    AWARDED = L["%d EP awarded on %q to %d members. %s"],
    AWARD_FROZEN = L["%s is frozen and earns no EP."],
    AWARD_NOTRAID = L["EP can only be awarded to a raid while in one."],
    AWARD_NOBODY = L["nobody here matches who the EP is for."],
    TIMED_REASON = L["Timed EP"],
    BOSS_NOLIST = L["%s died, but there is no list selected to award EP on."],
    AWARD_TITLE = L["Award EP on %s"],
    DECAY_TITLE = L["Decay EP and GP"],
    PANEL_TITLE = L["Effort and Gear"],
    AWARD_BUTTON = L["Award EP"],
    TIMER_START = L["Start timed EP"],
    TIMER_STOP = L["Stop timed EP"],
    TIMED_EVERY = L["EPGP_TIMED_EVERY"],
    TIP_AWARD = L["TIP_EPGP_AWARD"],
    TIP_ADJUST = L["TIP_EPGP_ADJUST"],
    TIP_DECAY = L["TIP_EPGP_DECAY"],
    TIP_TIMER = L["TIP_EPGP_TIMER"],
    TIP_AWARDFILTER = L["TIP_EPGP_AWARDFILTER"],
    TIP_CUSTOM = L["TIP_EPGP_CUSTOMGP"],
    JOURNAL_AWARDED = L["%d EP awarded by %s"],
    JOURNAL_HELP = L["Opens the journal of EP awarded and decays."],
    AWARD_HELP = L["Awards EP on a list to the members named, by name or by #uid."],
    LIFE_EARNED = L["Lifetime EP"],
    LIFE_CHARGED = L["Lifetime GP"],
    TIME_AMOUNT = L["Timed EP"],
    TIME_EVERY = L["EP every"],
    DOUBLES = L["GP doubles every (levels)"],
    UNIT = L["GP"],
    ADV_WARNING = L["EPGP_ADVANCED_WARNING"],
    COSTING_CLASSIC = L["EPGP_COSTING_CLASSIC"],
    COSTING_EXAMPLE = L["EPGP_COSTING_CLASSIC_EXAMPLE"],
    COSTING_FIXED = L["EPGP_COSTING_FIXED"],
    CUSTOM_PRICE = L["Custom GP value"],
  },
})

--
-- EP/GP's art is its cell in each of Konfer's strips. The plaque on its card reads /keg, so it has one only while that is the command.
--
epgp.TitleCard = konfer:PolicyArt("PolicyLogos", epgp.order)
epgp.Icon = konfer:PolicyArt("PolicyIcons", epgp.order)
epgp.CommandPlate = (epgp.command == "keg") and konfer:PolicyArt("PolicyCommands", epgp.order) or nil

local function setting(which, cfgid)
  return epgp:Setting(which, cfgid)
end

local function num(which, cfgid)
  return tonumber(setting(which, cfgid)) or tonumber(epgp.defaults[which]) or 0
end

--
-- STANDINGS
--
local function standings(cfgid, listid, uid)
  return epgp:Standings(cfgid, listid, uid)
end

local function priority(cfgid, ep, gp)
  local denom = (tonumber(gp) or 0) + num("base_gp", cfgid)

  if (denom <= 0) then
    denom = 1
  end

  return (tonumber(ep) or 0) / denom
end

--
-- EP, GP and PR for UID on LISTID, their main's on a tethered list. Zeros for somebody not on it.
--
function epgp:Numbers(cfgid, listid, uid)
  local cfg = konfer:PolicyConfig(epgp, cfgid)
  local muid = cfg and cfg.lists[listid] and member_of(cfg, listid, uid)

  if (not muid) then
    return 0, 0, priority(cfgid, 0, 0)
  end

  local st = standings(cfgid, listid, muid)

  return st.ep or 0, st.gp or 0, priority(cfgid, st.ep, st.gp)
end

--
-- The members in priority order. On the list itself, highest PR first and then by name, so that members level on PR, a
-- raid's worth of newcomers at nothing among them, stand in an order a reader can find somebody in. Among the Loot page's
-- candidates (LOOT), who are being chosen between for an item, the most EP breaks a tie on PR before the name does.
--
function epgp:Order(cfgid, listid, uids, loot)
  local cfg = konfer:PolicyConfig(epgp, cfgid)
  local keyed = {}

  for i, uid in ipairs(uids) do
    local st = standings(cfgid, listid, uid)
    tinsert(keyed, { uid = uid, i = i, pr = priority(cfgid, st.ep, st.gp), ep = st.ep or 0,
      name = strlower(cfg and cfg:UserName(uid) or uid) })
  end

  tsort(keyed, function(a, b)
    if (a.pr ~= b.pr) then
      return a.pr > b.pr
    end

    if (loot and a.ep ~= b.ep) then
      return a.ep > b.ep
    end

    if (a.name ~= b.name) then
      return a.name < b.name
    end

    return a.i < b.i
  end)

  local out = {}

  for _, k in ipairs(keyed) do
    tinsert(out, k.uid)
  end

  return out
end

-- A member's standing is their priority.
function epgp:PositionText(cfgid, listid, uid, idx)
  local _, _, pr = epgp:Numbers(cfgid, listid, uid)

  return strfmt("%.2f", pr)
end

-- What a member is worth, after their name in the foyer's Overview.
function epgp:ValueText(cfgid, listid, uid)
  return strfmt(L["PR %s"], epgp:PositionText(cfgid, listid, uid))
end

--
-- The Raid page: each raider's EP, GP and PR on the list being worked on (CurrentList), highest PR first. Somebody not on it
-- has none of the three.
--
epgp.RaidPage = {
  columns = {
    { key = "ep", text = L["EP"], widest = "00000" },
    { key = "gp", text = L["GP"], widest = "00000" },
    { key = "pr", text = L["PR"], widest = "0000.00", format = "%.2f" },
  },

  Columns = function(cfgid)
    return { ep = true, gp = true, pr = true }, "pr", false
  end,

  Row = function(cfgid, raider)
    local cfg = konfer:PolicyConfig(epgp, cfgid)
    local listid = epgp:CurrentList()

    if (not cfg or not listid or not raider.uid or not member_of(cfg, listid, raider.uid)) then
      return {}
    end

    local ep, gp, pr = epgp:Numbers(cfgid, listid, raider.uid)

    return { ep = ep, gp = gp, pr = pr }
  end,
}

--
-- BIDDING
--
-- Somebody below the minimum EP may not bid at all when the config says so. Otherwise they bid and are ranked below everybody
-- who has reached it (RankBidders).
--
function epgp:MayBid(cfgid, listid, uid, kind)
  if (not setting("minep_bars", cfgid)) then
    return true
  end

  local ep = epgp:Numbers(cfgid, listid, uid)
  local need = num("min_ep", cfgid)

  if (ep < need) then
    return false, strfmt(L["you need %d EP to bid, and have %d."], need, ep)
  end

  return true
end

--
-- The kinds of bid first, as the config's Bid options rank them (.tier), whatever anybody's priority. Then those who have
-- reached the minimum EP ahead of those who have not, then highest PR, then most EP. Bidders still level after all of that
-- share a tie, and a roll among them decides it when they are at the top.
--
function epgp:RankBidders(cfgid, listid, bidders, ilink)
  local need = num("min_ep", cfgid)

  for _, b in ipairs(bidders) do
    local ep, gp, pr = epgp:Numbers(cfgid, listid, b.uid)

    b.ep, b.pr = ep, pr
    b.ko = b.tier or 0
    b.met = (ep >= need) and 0 or 1
  end

  local function same(a, b)
    return a.ko == b.ko and a.met == b.met and a.pr == b.pr and a.ep == b.ep
  end

  tsort(bidders, function(a, b)
    if (a.ko ~= b.ko) then
      return a.ko < b.ko
    end

    if (a.met ~= b.met) then
      return a.met < b.met
    end

    if (a.pr ~= b.pr) then
      return a.pr > b.pr
    end

    if (a.ep ~= b.ep) then
      return a.ep > b.ep
    end

    return (a.idx or 0) < (b.idx or 0)
  end)

  local group = 0

  for i, b in ipairs(bidders) do
    if (i == 1 or not same(bidders[i - 1], b)) then
      group = group + 1
    end

    b.tie = group
  end

  return bidders
end

-- Whether an open roll charges its winner GP, which is this policy's own setting.
function epgp:RollAwards(cfgid, listid, ilink)
  return setting("gp_rolls", cfgid) and true or false
end

--
-- THE AWARD
--
-- Winning charges the winner the item's price, on a tethered list their main. The charge is worked out once, by whoever
-- makes the award, and travels as the number it came to (KEGGP), so that another admin applies what was charged rather than
-- working it out again from item data they may not have.
--
-- The token is the member charged and what they were charged, which is all putting it back needs.
--
-- A loot award, CHAIN, charges the same price again on the list's extra list, wherever the winner is on that one too. That is
-- how a guild runs a list for tier tokens and still charges the main list. Each charge is a move of its own, so undoing the
-- award gives both back.
--
-- The price is ItemPrice's, which is what the master looter is shown as the cost, unless they charged something else there
-- (COST), a discount or nothing at all.
--
function epgp:Cost(cfgid, listid, uid, ilink, kind)
  return epgp:ItemPrice(cfgid, ilink, kind)
end

function epgp:ApplyGP(cfg, listid, uid, gp, norefresh)
  local st = standings(cfg.id, listid, uid)

  st.gp = (st.gp or 0) + (tonumber(gp) or 0)
  points.Charged(st, gp)

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end
end

function epgp:Award(cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
  local cfg = konfer:PolicyConfig(epgp, cfgid)
  local rl = cfg and cfg.lists[listid]

  if (not ilink or not rl) then
    return {}
  end

  local lists = { listid }

  if (chain and rl.extralist ~= listid and cfg.lists[rl.extralist or "0"]) then
    tinsert(lists, rl.extralist)
  end

  -- Each list charged, and who on it: the winner, or on a tethered list their main.
  local charged = {}

  for _, lid in ipairs(lists) do
    local muid = member_of(cfg, lid, uid)

    if (muid) then
      tinsert(charged, { lid, muid })
    end
  end

  if (#charged == 0) then
    return {}
  end

  local gp = tonumber(cost) or epgp:ItemPrice(cfgid, ilink, kind)

  if (not gp) then
    epgp:err(L["the price of %s is not known yet, so nothing was charged."], ilink)
    return {}
  end

  local moves = {}

  for _, c in ipairs(charged) do
    epgp:ApplyGP(cfg, c[1], c[2], gp, norefresh)

    if (not nocmd) then
      cfg:AddEvent("KEGGP", c[1], c[2], gp)
    end

    tinsert(moves, { listid = c[1], token = { c[2], gp } })
  end

  return moves
end

function epgp:UndoAward(cfgid, listid, uid, ilink, token, nocmd)
  local cfg = konfer:PolicyConfig(epgp, cfgid)

  if (not cfg or type(token) ~= "table") then
    return
  end

  epgp:ApplyGP(cfg, listid, token[1], 0 - (tonumber(token[2]) or 0))

  if (not nocmd) then
    cfg:AddEvent("KEGGP", listid, token[1], 0 - (tonumber(token[2]) or 0))
  end
end

--
-- An award here is a GP charge, and its history row says what the winner was charged, with the kind of bid: "g" for a bid
-- won, "r" for a GP roll and "a" for an item handed out by its own instructions. PDATA is { gp, kind }.
--
local HISTORY_VIA = { bid = "g", roll = "r", assign = "a" }

function epgp:HistoryEntry(cfgid, via, listid, uid, ilink, kind, cost)
  return HISTORY_VIA[via] or "g", { tonumber(cost) or epgp:ItemPrice(cfgid, ilink, kind) or 0, kind or "M" }
end

local KIND_WORD = { O = L["Off-spec"], T = L["Transmog"], V = L["Vanity"] }

function epgp:HistoryText(cfgid, how, listid, pdata, colour)
  local cfg = konfer:PolicyConfig(epgp, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local lname = rl and rl.name or "???"
  local gp, kind = 0, "M"

  if (type(pdata) == "table") then
    gp, kind = tonumber(pdata[1]) or 0, pdata[2] or "M"
  end

  local text

  if (colour) then
    text = strfmt(L["%s GP, %s"], white(tostring(gp)), white(lname))
  else
    text = strfmt("%s %d", lname, gp)
  end

  if (KIND_WORD[kind]) then
    text = text .. " (" .. KIND_WORD[kind] .. ")"
  end

  if (how == "r") then
    text = strfmt(L["%s (GP roll)"], text)
  end

  return text, ""
end

function epgp:WinText(cfgid, how, listid, pdata, who, ilink)
  local cfg = konfer:PolicyConfig(epgp, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local gp = type(pdata) == "table" and tonumber(pdata[1]) or 0

  return strfmt(L["%s won %s for %d GP on the %q list. Grats!"], who, ilink, gp, rl and rl.name or "???")
end

--
-- THE CONFIG PAGE
--
-- EP/GP's panel on the Admin tab holds what it asks of a raid, who may bid, and how standby shares and decay go. Timed EP is
-- each list's own, on the Lists page's Config tab. The price of gear, a setting for every slot, is its page on the Config
-- page's Advanced tab, which the shared half builds.
--
function epgp:CreateConfigUI(parent)
  local owner = points.AdminOwner()
  local ypos = 0
  local blw = KUI:WidestString({ L["Base GP"] })
  local mlw = KUI:WidestString({ L["Minimum EP"] })

  self.cfgui = owner

  -- Each label as wide as its own words, so it stands the standard gap from its box, and the second pair after the first.
  points.NumField(owner, parent, "base_gp", L["Base GP"], 0, ypos, 60, blw)
  points.NumField(owner, parent, "min_ep", L["Minimum EP"], blw + KUI.INTERNAL_GAP + 60 + 16, ypos, 60, mlw)
  ypos = ypos - 20 - KUI.WIDGET_GAP

  points.CheckField(owner, parent, "minep_bars", L["Below minimum EP cannot bid"], 0, ypos, L["TIP_EPGP_MINEPBARS"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  points.CheckField(owner, parent, "gp_rolls", L["Rolls charge GP by default"], 0, ypos, L["TIP_EPGP_GPROLLS"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  ypos = points:EarningFields(epgp, owner, parent, ypos)

  return 0 - ypos
end

konfer:RegisterPolicy(epgp)
