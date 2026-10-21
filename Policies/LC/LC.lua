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

local tinsert = table.insert
local tsort = table.sort
local tconcat = table.concat
local strfmt = string.format
local strmatch = string.match
local strlower = string.lower

local tally = konfer.tally
local aclass = konfer.aclass

--
-- Loot Council.
--
-- A council decides who an item goes to, and Konfer gives it what it needs to decide and to be seen deciding fairly. Every
-- raider runs Konfer: a council guild asks it of its raiders as it asks anything else, and the character info check shows
-- who has not.
--
-- As an item drops the council votes on everybody here who could have it (Vote.lua), and the raid is shown the counts,
-- never who cast them. Those left level roll off among themselves, and an item the council leaves goes to an open roll like
-- any other, with the tally's +1s or decay where the config runs them (Tally.lua).
--
local lc = {
  handle = "lc",
  name = L["POLICY_LC_NAME"],
  nickname = L["POLICY_LC_NICK"],
  shortnick = L["POLICY_LC_SHORTNICK"],
  desc = L["POLICY_LC_DESC"],
  splashwords = L["POLICY_LC_SPLASH"],
  command = "klc",
  order = 4,
  accent = KUI.COLOR_PURPLE,

  -- Still in beta, which its card in the foyer says with a stamp over the artwork.
  beta = true,

  -- Everybody the config holds is on its one list, which nobody sees: the council decides, not a standing.
  onelist = true,

  -- What the council leaves to a roll is rolled for, never bid on, so the config's kind order ranks its rolls.
  rollorder = true,

  -- A new config's open rolls take main spec and off spec, main over off.
  configdefaults = {
    offspec_rolls = true,
    main_over_offspec = true,
  },

  -- The item quality below which an item is not offered at all, epic unless told otherwise, edited on the platform's Loot tab.
  defaults = {
    bid_threshold = 4,
  },

  hidepages = { lists = true },

  -- No bids, no lists, and so no guild rank filter for a roll, as PUG.
  AssignPage = {
    hide = { rank = true, lists = true, forcebid = true, bids = true },
  },

  ItemsPage = {
    hide = { rank = true, list = true, awardlist = true },
  },

  AdminPage = {
    hide = { options = true },
  },

  ConfigLootPage = {
    hide = { bids = true },
  },

  Strings = {
    HELP_STANDING = L["TALLY_HELP_STANDING"],
    RAID_BROADCAST = L["TIP_LC_BROADCAST"],
    RAID_REMOVE = L["TALLY_REMOVE"],
  },

  StandingFields = {},
}

tally:Setup(lc, {
  tag = "LC",
  events = { pen = "LCPEN", del = "LCDEL", grp = "LCGRP", fin = "LCEND" },
})

-- The item id in ILINK, a link or an id.
function lc.ItemId(ilink)
  if (type(ilink) == "number") then
    return ilink
  end

  return tonumber(strmatch(ilink or "", "item:(%d+)"))
end

--
-- What everybody has been given, from CFG's loot history, by uid: each row naming them as { when, n }, N 1 for an item
-- given and -1 for one given back, an item disenchanted or left with the master looter not being theirs. The Vote page
-- asks for every raider it shows, so it is worked out once for the history as it stands and again only once the history
-- has grown or been trimmed (cfg:Session().lcgiven).
--
local NOT_RECEIVED = { D = true, B = true, L = true }

local function given(cfg)
  local cs = cfg:Session()
  local hist = cfg.history or {}
  local last = hist[#hist]
  local key = #hist .. ":" .. tostring(last and last[1])

  if (cs.lcgiven and cs.lcgiven.key == key) then
    return cs.lcgiven.byuid
  end

  local byuid = {}

  for _, row in ipairs(hist) do
    local who, how = row[3], row[4]

    if (type(who) == "string" and not NOT_RECEIVED[how]) then
      byuid[who] = byuid[who] or {}
      tinsert(byuid[who], { tonumber(row[1]) or 0, (how == "U") and -1 or 1 })
    end
  end

  cs.lcgiven = { key = key, byuid = byuid }

  return byuid
end

-- How many items UID has been given in CFG since SINCE, for the council to weigh.
function lc:WonSince(cfg, uid, since)
  local n = 0

  for _, g in ipairs(given(cfg)[uid] or {}) do
    if (g[1] >= (since or 0)) then
      n = n + g[2]
    end
  end

  return math.max(n, 0)
end

-- Whether the character UID names in CFG is in the group.
function lc:Here(cfg, uid)
  local name = uid and cfg:UserName(uid)

  return (name and KRP.players and KRP.players[name]) and true or false
end

--
-- Who could have the item selected on the loot list in CFG now, the council's to choose from, each { uid, name }, by name:
-- everybody the config holds whom the game would let have it, one of its candidates for the item's loot slot or, for an
-- item added by hand, in the group, and who meets the item's Constraints, as for every policy.
--
function lc:Eligible(cfg)
  local out = {}
  local _, loot = konfer:SelectedLoot()
  local byhand = loot and loot.slot == 0
  local klid = loot and not byhand and loot.slot and konfer.KLD.items and konfer.KLD.items[loot.slot]

  for name in pairs(KRP.players or {}) do
    local uid = cfg:FindUser(name)

    if (uid and (byhand or (klid and klid.candidates[name])) and konfer:MeetsConstraints(uid)) then
      tinsert(out, { uid = uid, name = cfg:UserName(uid) or name })
    end
  end

  tsort(out, function(a, b) return strlower(a.name) < strlower(b.name) end)

  return out
end

-- A raider's name in class colour where they are here, and grey where they are not.
function lc:RaiderText(cfg, uid)
  local name, cls = cfg:UserNameClass(uid)

  if (name and self:Here(cfg, uid)) then
    return aclass(name, cls)
  end

  return "|cff808080" .. (name and K.DisplayName(name) or uid) .. "|r"
end

--
-- WHO HAS AN ITEM
--
-- What becomes of an item is decided per item, as it is selected, and kept here for this session, by its link: SETTLED
-- [cfgid][ilink] is { state, winner, tied, counts }, STATE being "won" (WINNER has it), "tied" (TIED, a set of uids, roll
-- off for it), "open" (everybody rolls) or "voting" (the council is voting). COUNTS is the vote's, by uid, for showing. A
-- decision goes with the award it led to, so a second copy is decided afresh, and one naming nobody who could still have
-- the item, gone from the group, is thrown away. An item whose roll-off nobody rolled in is everybody's to roll for.
--
lc.settled = {}

function lc:Settled(cfgid, ilink)
  local s = self.settled[cfgid]

  return s and s[ilink]
end

function lc:Settle(cfgid, ilink, rec)
  self.settled[cfgid] = self.settled[cfgid] or {}
  self.settled[cfgid][ilink] = rec
end

--
-- What is to become of ILINK in CFGID now: "won" with the winner, "tied" with the set, "vote" where the council has yet to
-- vote on it, "voting" while it does, or nil for an open roll.
--
function lc:Decision(cfgid, ilink)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (not cfg or not self.ItemId(ilink)) then
    return nil
  end

  local rec = self:Settled(cfgid, ilink)

  if (rec) then
    local can = {}

    for _, c in ipairs(self:Eligible(cfg)) do
      can[c.uid] = true
    end

    local live = (rec.state == "open" or rec.state == "voting")

    if (rec.state == "won") then
      live = can[rec.winner] ~= nil
    elseif (rec.state == "tied") then
      for uid in pairs(rec.tied or {}) do
        live = live or can[uid] ~= nil
      end
    end

    if (live) then
      if (rec.state == "open") then
        return nil
      end

      return rec.state, (rec.state == "won") and rec.winner or rec.tied
    end

    self:Settle(cfgid, ilink, nil)
  end

  if (#self:Eligible(cfg) > 0) then
    return "vote"
  end

  return nil
end

function lc:ItemClaim(cfgid, ilink)
  local state, who = self:Decision(cfgid, ilink)

  if (state == "won") then
    return true, who, true
  end

  return false
end

-- A roll-off is owed, and so is the vote while it is open, Open roll dark till they are done.
function lc:FirstRoll(cfgid, ilink)
  local state = self:Decision(cfgid, ilink)

  return state == "tied" or state == "voting"
end

-- Nobody rolled in the roll-off, so the item is everybody's.
function lc:FirstRollUnanswered(cfgid, ilink)
  self:Settle(cfgid, ilink, { state = "open" })
end

--
-- While the council votes on an item, only those who could have it are its Candidates, and in a roll-off only those tied
-- may roll.
--
function lc:MayRoll(cfgid, uid, kind, ilink)
  local state, who = self:Decision(cfgid, ilink)

  if (state == "tied") then
    if (who and who[uid]) then
      return true
    end

    return false, L["LC_ROLLOFF_ONLY"]
  end

  if (state == "voting") then
    local cfg = konfer:PolicyConfig(self, cfgid)

    for _, c in ipairs(self:Eligible(cfg)) do
      if (c.uid == uid) then
        return true
      end
    end

    return false, L["LC_COUNCIL_ONLY"]
  end

  return true
end

-- A roll-off is part of the council's decision, so it costs nobody a +1 however the config counts its open rolls.
local tally_rollawards = lc.RollAwards

function lc:RollAwards(cfgid, listid, ilink)
  if (self:Decision(cfgid, ilink) == "tied") then
    return false
  end

  return tally_rollawards(self, cfgid, listid, ilink)
end

function lc:RollNotice(cfgid, ilink)
  local state, who = self:Decision(cfgid, ilink)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (state ~= "tied" or not cfg) then
    return nil
  end

  local names = {}

  for uid in pairs(who) do
    tinsert(names, K.DisplayName(cfg:UserName(uid) or uid))
  end

  tsort(names)

  return strfmt(L["LC_ROLLOFF_NOTICE"], tconcat(names, ", "))
end

--
-- The bids button is the council's: Council vote while the council has an item to vote on, which opens the vote rather than
-- a roll (Vote.lua), Open roll lit beside it, and Roll-off while those it voted for are level, which opens their roll.
--
lc.AssignPage.firstroll = {
  text = L["Council vote"], tooltip = L["TIP_LC_VOTE"],
  Label = function(cfgid, ilink)
    if (lc:Decision(cfgid, ilink) == "tied") then
      return L["Roll-off"], L["TIP_LC_ROLLOFF"]
    end

    return L["Council vote"], L["TIP_LC_VOTE"]
  end,
  Offers = function(cfgid, ilink)
    return lc:Decision(cfgid, ilink) == "vote"
  end,
}

--
-- THE WIN
--
-- An item the council gave is an award on the one list, with a row of Loot Council's own, "council", PDATA { counts },
-- the votes each raider it was voted on among had, as { uid, n } pairs, and none where it was given without a vote. It
-- costs nothing in the tally, not being a roll won. Everything else won is the tally's.
--
local tally_history = lc.HistoryEntry
local tally_historytext = lc.HistoryText
local tally_wintext = lc.WinText
local tally_award = lc.Award

function lc:HistoryEntry(cfgid, via, listid, uid, ilink, kind, cost)
  if (via ~= "assign") then
    return tally_history(self, cfgid, via, listid, uid, ilink, kind, cost)
  end

  local rec = self:Settled(cfgid, ilink)
  local counts = {}

  for u, n in pairs((rec and rec.counts) or {}) do
    tinsert(counts, { u, n })
  end

  return "council", { counts }
end

function lc:Award(cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
  self:Settle(cfgid, ilink, nil)

  return tally_award(self, cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
end

-- The votes in a council row's PDATA, most first, "3-1".
local function counts_text(pdata)
  local ns = {}

  for _, p in ipairs((type(pdata) == "table" and type(pdata[1]) == "table") and pdata[1] or {}) do
    tinsert(ns, tonumber(p[2]) or 0)
  end

  tsort(ns, function(a, b) return a > b end)

  return (#ns > 0) and tconcat(ns, "-") or nil
end

function lc:HistoryText(cfgid, how, listid, pdata, colour)
  if (how ~= "council") then
    return tally_historytext(self, cfgid, how, listid, pdata, colour)
  end

  local text = L["Council"]
  local votes = counts_text(pdata)

  if (votes) then
    text = text .. " " .. votes
  end

  return colour and konfer.white(text) or text, ""
end

function lc:WinText(cfgid, how, listid, pdata, who, ilink)
  if (how ~= "council") then
    return tally_wintext(self, cfgid, how, listid, pdata, who, ilink)
  end

  local votes = counts_text(pdata)

  return votes and strfmt(L["LC_WIN_VOTE"], who, ilink, votes) or strfmt(L["LC_WIN_COUNCIL"], who, ilink)
end

--
-- THE ADMIN TAB
--
-- Loot Council's options for the config the tab has selected, the tally's for its open rolls (Tally.lua), held with the
-- rest of the tab's changes until the tab is saved.
--
lc.CreateConfigUI = function(self, parent)
  local ypos = tally:ConfigUI(self, parent, 0, tally:LabelWidth())

  return 0 - ypos - KUI.WIDGET_GAP
end

lc.RefreshConfigUI = function(self, cfgid)
  if (tally:RefreshConfigUI(self, cfgid)) then
    self.cfgui.sync()
  end
end

lc.EnableConfigUI = function(self, onoff, cfgid)
  tally:EnableConfigUI(self, onoff, cfgid)
end

-- Nobody stands anywhere on the one list: the candidates go by name, with no standing shown.
lc.PositionText = function(self, cfgid, listid, uid, idx)
  return ""
end

lc.standingwidth = 0

lc.Order = function(self, cfgid, listid, uids)
  local cfg = konfer:PolicyConfig(lc, cfgid)
  local keyed = {}

  for i, uid in ipairs(uids) do
    tinsert(keyed, { uid = uid, i = i, name = strlower(cfg and cfg:UserName(uid) or uid) })
  end

  tsort(keyed, function(a, b)
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

--
-- Loot Council's art is its cell in each of Konfer's strips. The plaque on its card reads /klc, so it has one only while that is the command.
--
lc.TitleCard = konfer:PolicyArt("PolicyLogos", lc.order)
lc.Icon = konfer:PolicyArt("PolicyIcons", lc.order)
lc.CommandPlate = (lc.command == "klc") and konfer:PolicyArt("PolicyCommands", lc.order) or nil

--
-- The foyer's Overview under Loot Council's description. A council decides rather than ranks, so the places on a list the
-- platform would draw there say nothing, and it draws nothing.
--
function lc:PopulateBannerInfo(cfgid)
end

konfer:RegisterPolicy(lc)
tally:Events(lc)
