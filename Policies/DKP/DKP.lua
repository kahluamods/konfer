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
local tconcat = table.concat
local tsort = table.sort
local floor = math.floor
local min = math.min

local member_of = points.MemberOf
local here = points.Here

--
-- Dragon Kill Points.
--
-- Points are a currency: earned by turning up, killing bosses and staying to the end, and spent on loot. The balance is the
-- whole standing, one number on each list, and the list stands in order of who has most.
--
-- How an item is won is the config's to say. At a fixed price, the item costs what its slot and level make it, or what the
-- item editor says, and of those who bid the best kind of bid wins, then whoever has most. At auction, bidders name an
-- amount, "!ms 150", and of the best kind of bid the highest wins, paying what they bid, or where the config says so the
-- next highest bid of the same standing. Either way a tie is rolled off, and the price goes into the costing box for the
-- master looter to discount, and is taken off the winner's balance.
--
-- Earning DKP, decaying it, the journal of both and the price of an item are the half DKP shares with EP/GP, built onto this
-- descriptor by konfer.points (Policies/Points.lua). What is here is what is DKP's own: the balance, and what winning does.
--
local dkp = {
  handle = "dkp",
  name = L["POLICY_DKP_NAME"],
  nickname = L["POLICY_DKP_NICK"],
  shortnick = L["POLICY_DKP_SHORTNICK"],
  desc = L["POLICY_DKP_DESC"],
  command = "kdkp",
  order = 3,
  accent = KUI.COLOR_EMERALD,

  -- Every win is put to the master looter in the costing box, where the price in DKP can be discounted.
  costing = true,

  -- Shift and Open bids gives the item a price of the master looter's, at auction the minimum bid following from it.
  setprice = true,

  StandingFields = { "dkp" },

  -- A balance of up to five digits.
  standingwidth = 5,

  Strings = {
    AWARD_BUTTON    = L["Charge DKP"],
    AWARD_EXTRALIST = L["Charge DKP on additional list"],
    AWARD_ITEMLIST  = L["Charge DKP on list"],
    AWARD_ROLL      = L["DKP Roll (on list %q) for %s within %d seconds."],
    AWARD_UNDO      = L["Are you absolutely sure you want to undo this DKP charge?"],
    AWARD_AUTO      = L["DKP_AUTOCHARGE"],
    BID_STANDING    = L["DKP %s"],
    MEMBERS_STANDING = L["DKP"],
    ANNOUNCE_RAIDERS = L["raiders' DKP on the %q list, most first: "],
    ANNOUNCE_ALL     = L["members of the %q list by DKP, most first: "],
    COST             = L["Cost (DKP)"],
  },
}

--
-- How items are won: at the price the config sets on them, or to the highest bid.
--
local SCHEME_FIXED = "fixed"
local SCHEME_AUCTION = "auction"

--
-- What the least an auction bid may be is: nothing at all, the amount the config sets, or a share of the item's price, half
-- of it unless the config says otherwise.
--
local MINBID_NONE = "none"
local MINBID_VALUE = "value"
local MINBID_PRICE = "price"

--
-- DKP's own settings, kept in each config's cfg.psettings under this handle and carried between admins as PSSET. The ones the
-- shared half reads and that are not set here, the standby share and the price of each slot among them, are added by
-- points:Setup at their shared defaults.
--
-- bid_threshold and try_roll are edited on the platform's Loot tab, as every policy's are. How items are won and what may be
-- bid are the Bidding tab's. The rest are this policy's panel on the Admin tab and its Advanced tab.
--
dkp.defaults = {
  bid_threshold = 3,          -- The item quality below which an item is not offered at all, rare unless told otherwise
  try_roll = false,           -- Whether nobody bidding opens a roll rather than ending the item
  dkp_rolls = false,          -- Whether winning an open roll charges DKP, as winning a bid does
  use_decay = false,          -- Whether a list's DKP decays at all, which the Decay button and decay_pct wait on
  scheme = SCHEME_FIXED,      -- How items are won, SCHEME_FIXED or SCHEME_AUCTION
  second_price = false,       -- At auction, whether the winner pays the next highest bid of the same standing
  min_bid = MINBID_PRICE,     -- At auction, the least a bid may be, one of the MINBID_ choices
  min_bid_value = 10,         -- And what that is where the config sets it
  min_bid_pct = 50,           -- Or what share of the item's price it is where the price sets it
  negative = false,           -- Whether a balance may go negative, a bid then being allowed past what is held
  min_balance_on = false,     -- Whether a balance below min_balance may bid at all
  min_balance = 0,
  zero_sum = false,           -- Whether what a winner spends is shared out among the raid
}

--
-- The Config page's Bidding tab, before the Advanced tab points:Setup adds. See THE BIDDING TAB below.
--
dkp.ConfigTabs = {}

points:Setup(dkp, {
  tag = "DKP",
  fields = { "dkp" },
  earn = "dkp",
  charge = "dkp",
  decays = { "dkp" },
  decayswitch = "use_decay",
  events = { award = "DKAWD", set = "DKSET", decay = "DKDEC", timer = "DKTIM", timerq = "DKTRQ", awset = "DKAWS",
    awdel = "DKAWX" },
  -- CLM's DKP rosters, its point type 0, give what each member holds as points.
  clm = {
    type = 0,
    numbers = function(pl, config)
      return { tonumber(pl.points) or 0 }
    end,
  },
  words = {
    FIELDS = { dkp = L["DKP"] },
    AWARDED = L["%d DKP awarded on %q to %d members. %s"],
    AWARD_FROZEN = L["%s is frozen and earns no DKP."],
    AWARD_NOTRAID = L["DKP can only be awarded to a raid while in one."],
    AWARD_NOBODY = L["nobody here matches who the DKP is for."],
    TIMED_REASON = L["Timed DKP"],
    BOSS_NOLIST = L["%s died, but there is no list selected to award DKP on."],
    AWARD_TITLE = L["Award DKP on %s"],
    DECAY_TITLE = L["Decay DKP"],
    PANEL_TITLE = L["Dragon Kill Points"],
    AWARD_BUTTON = L["Award DKP"],
    TIMER_START = L["Start timed DKP"],
    TIMER_STOP = L["Stop timed DKP"],
    TIMED_EVERY = L["DKP_TIMED_EVERY"],
    TIP_AWARD = L["TIP_DKP_AWARD"],
    TIP_ADJUST = L["TIP_DKP_ADJUST"],
    TIP_DECAY = L["TIP_DKP_DECAY"],
    TIP_TIMER = L["TIP_DKP_TIMER"],
    TIP_AWARDFILTER = L["TIP_EPGP_AWARDFILTER"],
    TIP_CUSTOM = L["TIP_DKP_CUSTOMPRICE"],
    JOURNAL_AWARDED = L["%d DKP awarded by %s"],
    JOURNAL_HELP = L["Opens the journal of DKP awarded, shared and decayed."],
    AWARD_HELP = L["Awards DKP on a list to the members named, by name or by #uid."],
    LIFE_EARNED = L["Lifetime earned"],
    LIFE_CHARGED = L["Lifetime spent"],
    TIME_AMOUNT = L["Timed DKP"],
    TIME_EVERY = L["DKP every"],
    DOUBLES = L["Price doubles every (levels)"],
    UNIT = L["DKP"],
    ADV_WARNING = L["DKP_ADVANCED_WARNING"],
    COSTING_CLASSIC = L["DKP_COSTING_CLASSIC"],
    COSTING_EXAMPLE = L["DKP_COSTING_CLASSIC_EXAMPLE"],
    COSTING_FIXED = L["DKP_COSTING_FIXED"],
    CUSTOM_PRICE = L["Custom DKP price"],
  },
})

--
-- DKP's art is its cell in each of Konfer's strips. The plaque on its card reads /kdkp, so it has one only while that is the command.
--
dkp.TitleCard = konfer:PolicyArt("PolicyLogos", dkp.order)
dkp.Icon = konfer:PolicyArt("PolicyIcons", dkp.order)
dkp.CommandPlate = (dkp.command == "kdkp") and konfer:PolicyArt("PolicyCommands", dkp.order) or nil

local function setting(which, cfgid)
  return dkp:Setting(which, cfgid)
end

local function num(which, cfgid)
  return tonumber(setting(which, cfgid)) or tonumber(dkp.defaults[which]) or 0
end

--
-- STANDINGS
--
local function standings(cfgid, listid, uid)
  return dkp:Standings(cfgid, listid, uid)
end

--
-- UID's balance on LISTID, their main's on a tethered list. Nothing for somebody not on it.
--
function dkp:Numbers(cfgid, listid, uid)
  local cfg = konfer:PolicyConfig(dkp, cfgid)
  local muid = cfg and cfg.lists[listid] and member_of(cfg, listid, uid)

  if (not muid) then
    return 0
  end

  return standings(cfgid, listid, muid).dkp or 0
end

--
-- The members by balance, most first, then by name, so that members on the same balance, a raid's worth of newcomers at
-- nothing among them, stand in an order a reader can find somebody in.
--
function dkp:Order(cfgid, listid, uids)
  local cfg = konfer:PolicyConfig(dkp, cfgid)
  local keyed = {}

  for i, uid in ipairs(uids) do
    tinsert(keyed, { uid = uid, i = i, dkp = standings(cfgid, listid, uid).dkp or 0,
      name = strlower(cfg and cfg:UserName(uid) or uid) })
  end

  tsort(keyed, function(a, b)
    if (a.dkp ~= b.dkp) then
      return a.dkp > b.dkp
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

-- A member's standing is their balance.
function dkp:PositionText(cfgid, listid, uid, idx)
  return strfmt("%d", dkp:Numbers(cfgid, listid, uid))
end

-- What a member is worth, after their name in the foyer's Overview.
function dkp:ValueText(cfgid, listid, uid)
  return strfmt(L["%d DKP"], dkp:Numbers(cfgid, listid, uid))
end

--
-- The Raid page: each raider's balance on the list being worked on (CurrentList), most first. Somebody not on it has none.
--
dkp.RaidPage = {
  columns = {
    { key = "dkp", text = L["DKP"], widest = "00000" },
  },

  Columns = function(cfgid)
    return { dkp = true }, "dkp", false
  end,

  Row = function(cfgid, raider)
    local cfg = konfer:PolicyConfig(dkp, cfgid)
    local listid = dkp:CurrentList()

    if (not cfg or not listid or not raider.uid or not member_of(cfg, listid, raider.uid)) then
      return {}
    end

    return { dkp = dkp:Numbers(cfgid, listid, raider.uid) }
  end,
}

--
-- BIDDING
--
-- A bid names an amount where the config runs its items at auction, and names only a kind where it sells them at a price.
--
function dkp:BidAmounts(cfgid)
  return setting("scheme", cfgid) == SCHEME_AUCTION
end

--
-- The least an auction bid on ILINK of KIND may be, nil where the config sets no least at all: the amount the config sets,
-- or its share of the item's price for that kind, to the nearest whole DKP. The item's price is nil for an item the game
-- cannot say anything about yet, which sets no least rather than refusing every bid.
--
local function auction_minimum(cfgid, ilink, kind)
  local mb = setting("min_bid", cfgid)

  if (mb == MINBID_VALUE) then
    return num("min_bid_value", cfgid)
  elseif (mb == MINBID_PRICE) then
    local price = dkp:ItemPrice(cfgid, ilink, kind)

    return price and floor(price * num("min_bid_pct", cfgid) / 100 + 0.5)
  end

  return nil
end

--
-- The least that may be bid, for an item's tooltip to show at auction in place of a price (ItemTooltip). Nil where the config
-- sets no least, so that a tooltip has nothing to say about the item and shows nothing at all.
--
function dkp:MinimumBid(cfgid, ilink, kind)
  return auction_minimum(cfgid, ilink, kind)
end

-- What ILINK costs as main spec, "125", or at auction the least that may be bid, "75+".
function dkp:PriceText(cfgid, ilink)
  if (dkp:BidAmounts(cfgid)) then
    local least = auction_minimum(cfgid, ilink, "M")

    return least and (least .. "+")
  end

  local price = dkp:ItemPrice(cfgid, ilink, "M")

  return price and tostring(price)
end

--
-- Somebody below the config's minimum balance may not bid at all, where it has one. Otherwise, at auction a bid must be at
-- least the least the config allows and, unless balances may go negative, no more than the bidder has; and at a fixed price,
-- unless balances may go negative, the bidder must have what the item costs as the kind they bid.
--
function dkp:MayBid(cfgid, listid, uid, kind, amount, ilink)
  local bal = dkp:Numbers(cfgid, listid, uid)
  local negative = setting("negative", cfgid)

  if (setting("min_balance_on", cfgid)) then
    local need = num("min_balance", cfgid)

    if (bal < need) then
      return false, strfmt(L["you need %d DKP to bid, and have %d."], need, bal)
    end
  end

  if (setting("scheme", cfgid) == SCHEME_AUCTION) then
    local least = auction_minimum(cfgid, ilink, kind)

    if (least and (amount or 0) < least) then
      return false, strfmt(L["the least you may bid is %d."], least)
    end

    if (not negative and (amount or 0) > bal) then
      return false, strfmt(L["you have %d DKP, so you cannot bid %d."], bal, amount or 0)
    end

    return true
  end

  local price = dkp:ItemPrice(cfgid, ilink, kind)

  if (not negative and price and bal < price) then
    return false, strfmt(L["this costs %d DKP and you have %d."], price, bal)
  end

  return true
end

--
-- The kinds of bid first, as the config's Bid options rank them (.tier), whatever anybody's balance. Then, at auction, the
-- highest bid, and at a fixed price, the most DKP. Bidders still level after that share a tie, and a roll among them decides
-- it when they are at the top.
--
function dkp:RankBidders(cfgid, listid, bidders, ilink)
  local auction = setting("scheme", cfgid) == SCHEME_AUCTION

  for _, b in ipairs(bidders) do
    b.dkp = dkp:Numbers(cfgid, listid, b.uid)
    b.ko = b.tier or 0
    b.by = auction and (b.amount or 0) or b.dkp
  end

  local function same(a, b)
    return a.ko == b.ko and a.by == b.by
  end

  tsort(bidders, function(a, b)
    if (a.ko ~= b.ko) then
      return a.ko < b.ko
    end

    if (a.by ~= b.by) then
      return a.by > b.by
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

-- Whether an open roll charges its winner DKP, which is this policy's own setting.
function dkp:RollAwards(cfgid, listid, ilink)
  return setting("dkp_rolls", cfgid) and true or false
end

--
-- THE AWARD
--
-- What a win costs, which the costing box starts at. At auction a won bid costs what the winner bid, or where the config says
-- so the highest of the other bids of the same standing, the same tier of kind; with no other such bid it costs the least
-- a bid may be, and with no least, what they bid. Anything else, an item at a fixed price, a roll or an item's own
-- instructions, costs the item's price for the kind it was won as.
--
function dkp:Cost(cfgid, listid, uid, ilink, kind, bids)
  if (setting("scheme", cfgid) == SCHEME_AUCTION and type(bids) == "table") then
    local mine = nil

    for _, b in ipairs(bids) do
      if (b.uid == uid) then
        mine = b
      end
    end

    if (mine and mine.amount) then
      if (not setting("second_price", cfgid)) then
        return mine.amount
      end

      local second = nil

      for _, b in ipairs(bids) do
        if (b.uid ~= uid and b.tier == mine.tier and b.amount and (not second or b.amount > second)) then
          second = b.amount
        end
      end

      if (second) then
        return min(second, mine.amount)
      end

      return auction_minimum(cfgid, ilink, kind) or mine.amount
    end
  end

  return dkp:ItemPrice(cfgid, ilink, kind)
end

--
-- DELTA added to UID's balance on LISTID: a charge is negative, and one put back positive. What they have been charged in
-- their lifetime moves the other way.
--
function dkp:ApplyCharge(cfg, listid, uid, delta, norefresh)
  local st = standings(cfg.id, listid, uid)

  st.dkp = (st.dkp or 0) + (tonumber(delta) or 0)
  points.Charged(st, 0 - (tonumber(delta) or 0))

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end
end

--
-- ZERO-SUM
--
-- Where the config says so, what a winner spends is shared out among the raid: everybody on the list who is in it, the winner
-- included, each an equal share, and those on standby the standby share of one, a frozen member none at all. The shares are
-- whole DKP and come to exactly what was spent: each has the whole part of their exact share, and what is left over goes a
-- point at a time to those whose exact shares were furthest past a whole number, their uids settling any tie. SHARES is a
-- table of uid to what each gets, nil where there is nobody to share it with.
--
local function zero_sum_shares(cfg, listid, total)
  local members = {}
  local weight = 0
  local sbw = num("standby_pct", cfg.id) / 100

  for _, ruid in ipairs(cfg:CreateRaidList(listid)) do
    if (not cfg:IsFrozen(ruid)) then
      local w = here(cfg, listid, ruid) and 1 or sbw

      if (w > 0) then
        tinsert(members, { uid = ruid, w = w })
        weight = weight + w
      end
    end
  end

  if (weight <= 0) then
    return nil
  end

  local given = 0

  for _, m in ipairs(members) do
    local exact = total * m.w / weight

    m.n = floor(exact)
    m.frac = exact - m.n
    given = given + m.n
  end

  tsort(members, function(a, b)
    if (a.frac ~= b.frac) then
      return a.frac > b.frac
    end

    return a.uid < b.uid
  end)

  local left = total - given

  for _, m in ipairs(members) do
    if (left <= 0) then
      break
    end

    m.n = m.n + 1
    left = left - 1
  end

  local shares = {}

  for _, m in ipairs(members) do
    if (m.n ~= 0) then
      shares[m.uid] = m.n
    end
  end

  return shares
end

--
-- SHARES, a table of uid to DKP, added to their balances on LISTID at WHEN, shared from ILINK by BY. The journal records it,
-- as k "z", with the total and the item, the one entry naming everybody it reached. A share taken back when the award is
-- undone is the same with every amount negative. A share is earned, and counts in each member's lifetime total of it.
--
function dkp:ApplyShares(cfg, listid, when, shares, ilink, by, norefresh)
  if (not cfg.lists[listid] or type(shares) ~= "table") then
    return
  end

  local total = 0
  local got = {}

  for uid, n in pairs(shares) do
    local st = standings(cfg.id, listid, uid)

    st.dkp = (st.dkp or 0) + (tonumber(n) or 0)
    points.Earned(st, n)
    total = total + (tonumber(n) or 0)
    tinsert(got, uid)
  end

  tsort(got)

  points.Journal(cfg, listid, { t = when, k = "z", total = total, i = ilink, by = by, u = tconcat(got, "") })

  if (not norefresh and cfg:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
    dkp:RefreshJournal()
  end
end

--
-- What a zero-sum entry says on the Journal tab: the total, what it was shared from, and on its tooltip who shared it.
--
function dkp:JournalText(e, by)
  if (e.k ~= "z") then
    return "", "", ""
  end

  local total = tonumber(e.total) or 0

  if (total >= 0) then
    return tostring(total), strfmt(L["Shared from %s"], e.i or "?"), strfmt(L["%d DKP shared by %s"], total, by)
  end

  return tostring(total), strfmt(L["Share of %s taken back"], e.i or "?"), strfmt(L["%d DKP taken back by %s"], 0 - total,
    by)
end

--
-- Winning takes the price off the winner's balance, on a tethered list their main's. The charge is worked out once, by
-- whoever makes the award, and travels as the number it came to (DKCHG), so that another admin applies what was charged
-- rather than working it out again from item data they may not have. Shares of it, where the config is zero-sum, are worked
-- out once too and travel as they came out (DKZSM).
--
-- A loot award, CHAIN, charges the same price again on the list's extra list, wherever the winner is on that one too. Each
-- charge is a move of its own, so undoing the award gives both back. The token is the member charged, what they were
-- charged and the shares made of it, which is all putting it back needs.
--
-- The price is Cost's, which is what the master looter is shown, unless they charged something else there (COST), a
-- discount or nothing at all.
--
function dkp:Award(cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
  local cfg = konfer:PolicyConfig(dkp, cfgid)
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

  local price = tonumber(cost) or dkp:ItemPrice(cfgid, ilink, kind)

  if (not price) then
    dkp:err(L["the price of %s is not known yet, so nothing was charged."], ilink)
    return {}
  end

  local moves = {}
  local when = K.time()
  local by = cfg:MyUid()

  for _, c in ipairs(charged) do
    local shares = nil

    dkp:ApplyCharge(cfg, c[1], c[2], 0 - price, norefresh)

    if (not nocmd) then
      cfg:AddEvent("DKCHG", c[1], c[2], 0 - price)

      if (price > 0 and setting("zero_sum", cfgid)) then
        shares = zero_sum_shares(cfg, c[1], price)

        if (shares) then
          dkp:ApplyShares(cfg, c[1], when, shares, ilink, by, norefresh)
          cfg:AddEvent("DKZSM", c[1], when, shares, ilink, by)
        end
      end
    end

    tinsert(moves, { listid = c[1], token = { c[2], price, shares } })
  end

  return moves
end

function dkp:UndoAward(cfgid, listid, uid, ilink, token, nocmd)
  local cfg = konfer:PolicyConfig(dkp, cfgid)

  if (not cfg or type(token) ~= "table") then
    return
  end

  local price = tonumber(token[2]) or 0

  dkp:ApplyCharge(cfg, listid, token[1], price)

  if (not nocmd) then
    cfg:AddEvent("DKCHG", listid, token[1], price)
  end

  if (type(token[3]) == "table") then
    local back = {}
    local when = K.time()
    local by = cfg:MyUid()

    for u, n in pairs(token[3]) do
      back[u] = 0 - (tonumber(n) or 0)
    end

    dkp:ApplyShares(cfg, listid, when, back, ilink, by)

    if (not nocmd) then
      cfg:AddEvent("DKZSM", listid, when, back, ilink, by)
    end
  end
end

--
-- An award here is a DKP charge, and its history row says what the winner was charged, with the kind of bid: "b" for a bid
-- won, "r" for a DKP roll and "a" for an item handed out by its own instructions. PDATA is { cost, kind }.
--
local HISTORY_VIA = { bid = "b", roll = "r", assign = "a" }

function dkp:HistoryEntry(cfgid, via, listid, uid, ilink, kind, cost)
  return HISTORY_VIA[via] or "b", { tonumber(cost) or dkp:ItemPrice(cfgid, ilink, kind) or 0, kind or "M" }
end

-- A charge undone is "u", PDATA { price } being what the winner was given back, the price in Award's token.
function dkp:HistoryUndo(cfgid, listid, uid, ilink, token)
  return "u", { type(token) == "table" and tonumber(token[2]) or 0 }
end

local KIND_WORD = { O = L["Off-spec"], T = L["Transmog"], V = L["Vanity"] }

function dkp:HistoryText(cfgid, how, listid, pdata, colour)
  local cfg = konfer:PolicyConfig(dkp, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local lname = rl and rl.name or "???"
  local cost, kind = 0, "M"

  if (type(pdata) == "table") then
    cost, kind = tonumber(pdata[1]) or 0, pdata[2] or "M"
  end

  if (how == "u") then
    if (colour) then
      return strfmt(L["Undo: %s, %s"], white(tostring(cost)), white(lname)), ""
    end
    return strfmt(L["Undo: %s, %s"], tostring(cost), lname), ""
  end

  local text

  if (colour) then
    text = strfmt(L["%s DKP, %s"], white(tostring(cost)), white(lname))
  else
    text = strfmt("%s %d", lname, cost)
  end

  if (KIND_WORD[kind]) then
    text = text .. " (" .. KIND_WORD[kind] .. ")"
  end

  if (how == "r") then
    text = strfmt(L["%s (DKP roll)"], text)
  end

  return text, ""
end

function dkp:WinText(cfgid, how, listid, pdata, who, ilink)
  local cfg = konfer:PolicyConfig(dkp, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local cost = type(pdata) == "table" and tonumber(pdata[1]) or 0

  return strfmt(L["%s won %s for %d DKP on the %q list. Grats!"], who, ilink, cost, rl and rl.name or "???")
end

--
-- THE CONFIG PAGE
--
-- DKP's panel on the Admin tab holds how much DKP the raid earns and when, whether a roll charges it, and whether lists decay,
-- the decay percentage being dark while they do not. How items are won is the Bidding tab's, and the price of gear the
-- Advanced tab's.
--
function dkp:CreateConfigUI(parent)
  local owner = points.AdminOwner()
  local ypos = 0

  owner.checked = function(key, on)
    if (key == "use_decay" and owner.fields.decay_pct) then
      owner.fields.decay_pct:SetEnabled(on)
    end
  end

  self.cfgui = owner

  points.CheckField(owner, parent, "dkp_rolls", L["Rolls charge DKP by default"], 0, ypos, L["TIP_DKP_ROLLS"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  points.CheckField(owner, parent, "use_decay", L["Use DKP decay"], 0, ypos, L["TIP_DKP_USEDECAY"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  ypos = points:EarningFields(dkp, owner, parent, ypos)

  return 0 - ypos
end

--
-- THE BIDDING TAB
--
-- DKP's own tab on the Config page, holding how items are won and what may be bid, one choice a line: a fixed price or an
-- auction, and under the auction what its winner pays and the least a bid may be; whether a balance may go negative;
-- the least balance that may bid; and whether what a winner spends is shared among the raid. A choice that means nothing as
-- things are set is dark: the auction's while items are sold at a price, the set amount unless the least bid is one, and the
-- least balance unless there is one. Every change is held with the tab's until its save bar is pressed, as the Advanced
-- tab's are.
--
local BID_INDENT = 20

local function bidding_sync(owner)
  if (not owner.cfgid) then
    return
  end

  local ap = owner.pending()
  local auction = ap:Value("p.scheme") == SCHEME_AUCTION

  owner.checks.second_price:SetEnabled(auction)
  owner.minbid:SetEnabled(auction)
  owner.fields.min_bid_value:SetEnabled(auction and ap:Value("p.min_bid") == MINBID_VALUE)
  owner.fields.min_bid_pct:SetEnabled(auction and ap:Value("p.min_bid") == MINBID_PRICE)
  owner.fields.min_balance:SetEnabled(ap:Value("p.min_balance_on") and true or false)
end

local function bidding_refresh(client, cfgid)
  local owner = dkp.bidui

  if (not owner) then
    return
  end

  local has = konfer:PolicyConfig(dkp, cfgid) ~= nil

  owner.cfgid = has and cfgid or nil
  owner.panel:SetEnabled(has)
  owner.scheme:SetEnabled(has)
  owner.minbid:SetEnabled(has)

  for _, cb in pairs(owner.checks) do
    cb:SetEnabled(has)
  end

  for _, eb in pairs(owner.fields) do
    eb:SetEnabled(has)
  end

  if (not has) then
    for _, eb in pairs(owner.fields) do
      eb:SetText("")
    end

    return
  end

  local ap = owner.pending()

  owner.scheme:SetValue(ap:Value("p.scheme") or SCHEME_FIXED, true)
  owner.minbid:SetValue(ap:Value("p.min_bid") or MINBID_PRICE, true)

  for key, cb in pairs(owner.checks) do
    cb:SetChecked(ap:Value("p." .. key) and true or false, true)
  end

  for key, eb in pairs(owner.fields) do
    eb:SetText(tostring(ap:Value("p." .. key) or ""))
  end

  bidding_sync(owner)
end

local function bidding_construct(tab, pending)
  local owner = { fields = {}, checks = {}, pending = function() return konfer:PolicyTabPending(dkp, "bidding") end }

  owner.checked = function()
    bidding_sync(owner)
  end

  dkp.bidui = owner

  --
  -- One panel exactly as tall as what it holds, and empty space under it that takes whatever the window grows by, as the
  -- Advanced tab has.
  --
  local split = KUI:CreateHSplit({
    inset = 0, height = 0, topanchor = true, name = "KonferDKPBiddingSplit", toptitle = L["Bidding"],
    bottomborder = false,
  }, tab)

  local client = split.topframe
  local ypos = 0

  --
  -- A radio group's choice is held, as a box's is, and lights what hangs off it.
  --
  local function radio(key)
    return function(this, evt, value, user)
      if (user and owner.cfgid) then
        owner.pending():Set("p." .. key, value)
        bidding_sync(owner)
      end
    end
  end

  owner.scheme = KUI:CreateRadioGroup({
    x = 0, y = ypos, spacing = 16, initialvalue = SCHEME_FIXED, label = { text = L["Items won by"], pos = "LEFT" },
    items = {
      { text = L["Fixed price"], value = SCHEME_FIXED, tooltip = { title = "$$", text = L["TIP_DKP_FIXED"] } },
      { text = L["Auction"], value = SCHEME_AUCTION, tooltip = { title = "$$", text = L["TIP_DKP_AUCTION"] } },
    },
  }, client)
  owner.scheme:Catch("OnValueChanged", radio("scheme"))
  owner.pending():Watch(owner.scheme, "p.scheme")
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  points.CheckField(owner, client, "second_price", L["The winner pays the second highest bid"], BID_INDENT, ypos,
    L["TIP_DKP_SECONDPRICE"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  owner.minbid = KUI:CreateRadioGroup({
    x = BID_INDENT, y = ypos, spacing = 16, initialvalue = MINBID_PRICE, label = { text = L["Minimum bid"], pos = "LEFT" },
    items = {
      { text = K.NONE_STR, value = MINBID_NONE },
      { text = L["A set amount"], value = MINBID_VALUE },
      { text = L["The item's price"], value = MINBID_PRICE },
    },
  }, client)
  owner.minbid:Catch("OnValueChanged", radio("min_bid"))
  owner.pending():Watch(owner.minbid, "p.min_bid")
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  -- The set amount and the share of the price on one line under the choice, each lit only while its choice is made.
  local amt = points.NumField(owner, client, "min_bid_value", L["Amount"], BID_INDENT + BID_INDENT, ypos, nil, nil, nil, 5)

  points.NumField(owner, client, "min_bid_pct", L["Share of the price (%)"], BID_INDENT + BID_INDENT
    + amt.label:GetWidth() + KUI.INTERNAL_GAP + amt:GetWidth() + 12, ypos, nil, nil, nil, 3, 1, 100)
  ypos = ypos - 20 - KUI.WIDGET_GAP

  points.CheckField(owner, client, "negative", L["Balances may go negative"], 0, ypos, L["TIP_DKP_NEGATIVE"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  points.CheckField(owner, client, "min_balance_on", L["Minimum balance required to bid"], 0, ypos, L["TIP_DKP_MINBALANCE"])
  ypos = ypos - KUI.CHECKBOX_SIZE - KUI.WIDGET_GAP

  points.NumField(owner, client, "min_balance", L["Minimum balance"], BID_INDENT, ypos, nil, nil, nil, 5)
  ypos = ypos - 20 - KUI.WIDGET_GAP

  points.CheckField(owner, client, "zero_sum", L["Spread item cost across raid (zero sum)"], 0, ypos,
    L["TIP_DKP_ZEROSUM"])
  ypos = ypos - KUI.CHECKBOX_SIZE

  split:SetSplitSize(0 - ypos)
  owner.panel = split.topinset
end

tinsert(dkp.ConfigTabs, 1, { name = "bidding", text = L["Bidding"], owneronly = true, Construct = bidding_construct,
  Refresh = bidding_refresh })

konfer:RegisterPolicy(dkp)
