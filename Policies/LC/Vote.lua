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

local lc = konfer.policies.lc

--
-- THE VOTE
--
-- An item anybody here could have goes to the council as it is offered. The master looter's Council vote opens the vote on
-- those who could have it now (LCVOP), and every admin of the config in the group is shown it on the Vote page, there while
-- the vote is open and the window raised on it as it opens: each of them with how many items they have won tonight, what
-- they are wearing where the item goes, and how many votes each has. Each one's own client says what they wear, the moment
-- the vote opens (LCGEA). An admin votes for one of them (LCBAL), whispered to the master looter, who counts and whispers
-- the counts back to each admin (LCTAL) and never who cast them. An admin may change their vote until the master looter
-- closes it.
--
-- Close vote decides it (LCVEN): the one with the most votes has the item, put to the master looter as a claim is
-- (ItemClaim in LC.lua); several level, or nobody voted for, roll off among themselves. The raid is told the counts by
-- name. Cancel vote calls it off with nothing decided, the item as it was before the vote. Either way the Vote page goes.
-- A vote is this session's alone: a reload ends it.
--
-- lc.vote is the vote this client is in, { cfgid, ilink, claimants, counts, gear, mine, voted, voters, ballots, ml }:
-- CLAIMANTS those it is among, BALLOTS, by voter, the master looter's alone, ML the master looter's name everybody else's,
-- and MINE whom this admin voted for.
--
lc.vote = nil

-- The inventory slots an item of each equip location is worn in.
local WORN = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
  INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 },
  INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
  INVTYPE_RELIC = { 18 },
}

-- What this character wears where ILINK would go, as links, a token counting as the gear it turns into.
local function wearing(ilink)
  local id = lc.ItemId(ilink)
  local loc = id and (konfer:TokenEquipLoc(id) or select(4, C_Item.GetItemInfoInstant(id)))
  local out = {}

  for _, slot in ipairs(WORN[loc or ""] or {}) do
    local link = GetInventoryItemLink("player", slot)

    if (link) then
      tinsert(out, link)
    end
  end

  return out
end

-- The admins of CFG in the group, by name, the council that votes.
local function council_here(cfg)
  local out = {}

  for name in pairs(KRP.players or {}) do
    local uid = cfg:FindUser(name)

    if (uid and cfg:IsAdmin(uid)) then
      tinsert(out, name)
    end
  end

  return out
end

--
-- THE VOTE PAGE
--
-- An admin's while a vote is open. It stands after the Loot page, so that when the vote ends with it on screen the window
-- goes back to the Loot page, where the item is offered again.
--
local VOTE_BTN_W = 100
local VOTE_BTN_H = 24

local vp = nil

local function refresh_vote()
  if (not vp or not lc.vote) then
    return
  end

  local v = lc.vote
  local cfg = konfer:PolicyConfig(lc, v.cfgid)

  if (not cfg) then
    return
  end

  vp.item:SetText(strfmt(L["Item: %s"], v.ilink))

  vp.rows = {}

  for _, c in ipairs(v.claimants) do
    tinsert(vp.rows, c)
  end

  local sel = vp.list:GetSelected()

  vp.list:UpdateList(#vp.rows)
  vp.list:SetSelected(sel, false, true)

  local picked = sel and vp.rows[sel]

  vp.vote:SetEnabled(picked ~= nil)

  -- Only the master looter, who counts the ballots, closes the vote.
  local ml = v.ballots ~= nil

  vp.close:SetShown(ml)
  vp.cancel:SetShown(ml)

  local mine = v.mine and (cfg:UserName(v.mine) or v.mine)
  local status = strfmt(L["%d of %d have voted."], v.voted or 0, v.voters or 0)

  if (mine) then
    status = strfmt(L["You voted for %s."], K.DisplayName(mine)) .. " " .. status
  end

  vp.status:SetText(status)
end

local function build_vote_page(client)
  local pc = KUI.MakeFrame("Frame", nil, client)

  pc:SetPoint("TOPLEFT", client, "TOPLEFT", 4, -4)
  pc:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", -4, 4)

  vp = {}

  vp.item = KUI:CreateStringLabel({
    x = 0, y = 0, height = 16, autosize = false, font = "GameFontNormal", justifyh = "LEFT", text = "",
  }, pc)
  vp.item:ClearAllPoints()
  vp.item:SetPoint("TOPLEFT", pc, "TOPLEFT", 0, 0)
  vp.item:SetPoint("RIGHT", pc, "RIGHT", 0, 0)

  local holder = KUI.MakeFrame("Frame", nil, pc)

  holder:SetPoint("TOPLEFT", pc, "TOPLEFT", 0, -16 - KUI.WIDGET_GAP)
  holder:SetPoint("BOTTOMRIGHT", pc, "BOTTOMRIGHT", 0, VOTE_BTN_H + KUI.WIDGET_GAP + 16 + KUI.WIDGET_GAP)

  vp.list = KUI:CreateColumnList({
    name = "KonferLCVoteList",
    columns = {
      { key = "who", text = L["Raider"], width = 100 },
      { key = "won", text = L["Won"], width = 40, align = "RIGHT" },
      { key = "wearing", text = L["Wearing"], width = "fill" },
      { key = "votes", text = L["Votes"], width = 40, align = "RIGHT" },
    },
    setitem = function(cl, idx, slot, row)
      local c = vp.rows[idx]
      local v = lc.vote
      local cfg = v and konfer:PolicyConfig(lc, v.cfgid)
      local gear = v and v.gear[c.uid]
      local won = cfg and lc:WonSince(cfg, c.uid, lc:Raid(cfg).started or (K.time() - 6 * 3600))

      row:SetCell("who", cfg and lc:RaiderText(cfg, c.uid) or c.uid)
      row:SetCell("won", tostring(won or 0))
      row:SetCell("wearing", gear and tconcat(gear, " ") or "")
      row:SetCell("votes", tostring((v and v.counts[c.uid]) or 0))
    end,
    selectitem = function(cl, idx, slot, row, onoff)
      if (vp.vote) then
        vp.vote:SetEnabled(onoff and true or false)
      end
    end,
  }, holder)

  vp.status = KUI:CreateStringLabel({
    x = 0, y = 0, height = 16, autosize = false, font = "GameFontNormalSmall", justifyh = "LEFT", text = "",
  }, pc)
  vp.status:ClearAllPoints()
  vp.status:SetPoint("BOTTOMLEFT", pc, "BOTTOMLEFT", 0, VOTE_BTN_H + KUI.WIDGET_GAP)
  vp.status:SetPoint("RIGHT", pc, "RIGHT", 0, 0)

  local function button(text, tip, x, fn)
    local b = KUI:CreateButton({
      width = VOTE_BTN_W, height = VOTE_BTN_H, text = text, tooltip = { title = "$$", text = tip },
    }, pc)

    b:ClearAllPoints()
    b:SetPoint("BOTTOMLEFT", pc, "BOTTOMLEFT", x, 0)
    b:Catch("OnClick", fn)

    return b
  end

  vp.vote = button(L["Vote"], L["TIP_LC_CASTVOTE"], 0, function()
    local i = vp.list:GetSelected()
    local c = i and vp.rows[i]

    if (c) then
      lc:CastVote(c.uid)
    end
  end)

  vp.close = button(L["Close vote"], L["TIP_LC_CLOSEVOTE"], VOTE_BTN_W + KUI.WIDGET_GAP, function()
    lc:CloseVote(false)
  end)

  vp.cancel = button(L["Cancel vote"], L["TIP_LC_CANCELVOTE"], 2 * (VOTE_BTN_W + KUI.WIDGET_GAP), function()
    lc:CloseVote(true)
  end)

  refresh_vote()
end

lc.Pages = lc.Pages or {}
tinsert(lc.Pages, { name = "vote", text = L["Vote"], title = L["Council vote"], order = 3.5, adminonly = true,
  Shown = function()
    return lc.vote ~= nil
  end,
  Construct = build_vote_page, Refresh = refresh_vote })

-- The Vote page, there now for the vote this client is in, and the window raised on it.
local function show_vote()
  konfer:PolicyPagesChanged(lc, "vote")
  refresh_vote()
end

-- The vote has ended, and the Vote page goes.
local function hide_vote()
  konfer:PolicyPagesChanged(lc)
end

-- "/klc vote": the window raised on the Vote page again, for an admin who closed it while the vote is still open.
lc.Commands = lc.Commands or {}
tinsert(lc.Commands, { word = L["CMD_VOTE"], help = L["LC_VOTE_HELP"], Run = function(input, p)
  if (lc.vote) then
    show_vote()
  else
    p:info(L["no council vote is open."])
  end
end })

--
-- THE MASTER LOOTER'S SIDE
--

-- Open the vote on ILINK in CFGID, from the bids button. Answers whether there was a vote to open.
function lc:OpenVote(cfgid, ilink)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (not cfg or not konfer:SelectedLoot()) then
    return false
  end

  if (self.vote and self.vote.cfgid == cfgid and self.vote.ilink == ilink) then
    show_vote()
    return true
  end

  local claimants = self:Eligible(cfg)

  if (#claimants == 0) then
    return false
  end

  local uids = {}

  for _, c in ipairs(claimants) do
    tinsert(uids, c.uid)
  end

  self.vote = { cfgid = cfgid, ilink = ilink, claimants = claimants, counts = {}, gear = {}, ballots = {}, voted = 0,
    voters = #council_here(cfg) }
  self:Settle(cfgid, ilink, { state = "voting" })
  self:CSendGroupAM(cfgid, "LCVOP", "ALERT", ilink, uids)
  konfer:SendText(strfmt(L["LC_VOTE_OPEN"], L["MODTITLE"], ilink))

  -- The master looter's own gear, where they are among them, is answered here as everybody else's is by their own client.
  self:AnswerGear(cfg, ilink, uids)
  show_vote()

  -- Open roll goes dark while the vote is open.
  konfer:RefreshLootMembers()

  return true
end

lc.AssignPage.firstroll.Open = function(cfgid, ilink)
  local state = lc:Decision(cfgid, ilink)

  if (state == "vote" or state == "voting") then
    return lc:OpenVote(cfgid, ilink)
  end

  return false
end

-- Count the ballots and tell every admin in the group the counts, never who cast them.
local function count_ballots(v)
  local counts = {}
  local n = 0

  for _, uid in pairs(v.ballots) do
    counts[uid] = (counts[uid] or 0) + 1
    n = n + 1
  end

  v.counts = counts
  v.voted = n

  local cfg = konfer:PolicyConfig(lc, v.cfgid)

  for _, name in ipairs(council_here(cfg)) do
    if (name ~= K.player.name) then
      lc:CSendWhisperAM(v.cfgid, name, "LCTAL", "ALERT", v.ilink, counts, n, v.voters)
    end
  end

  refresh_vote()
end

-- A ballot for UID from the admin VOTER, while the vote is open and UID one of its claimants.
local function take_ballot(voter, uid)
  local v = lc.vote

  if (not v or not v.ballots) then
    return
  end

  for _, c in ipairs(v.claimants) do
    if (c.uid == uid) then
      v.ballots[voter] = uid
      count_ballots(v)
      return
    end
  end
end

--
-- Close the vote, deciding it, or with CANCEL calling it off with nothing decided, and tell the group.
--
function lc:CloseVote(cancel)
  local v = self.vote

  if (not v or not v.ballots or not konfer:AmIML()) then
    return
  end

  local cfg = konfer:PolicyConfig(self, v.cfgid)

  -- Called off, the item is the council's to vote on again when it is ready, and the raid is told as a cancelled roll is.
  if (cancel) then
    self:CSendGroupAM(v.cfgid, "LCVEN", "ALERT", v.ilink, "cancelled")
    self:VoteEnded(cfg, v.ilink, nil)

    if (cfg:Announces("ann_cancel")) then
      konfer:SendWarning(strfmt(L["%s: %s cancelled!"], L["MODTITLE"], L["vote"]))
    end

    return
  end

  local rec

  -- Everybody it was among is counted, those nobody voted for at nothing, so that what is told and written says so.
  local full = {}

  for _, c in ipairs(v.claimants) do
    full[c.uid] = v.counts[c.uid] or 0
  end

  v.counts = full

  local best, top = 0, {}

  for _, c in ipairs(v.claimants) do
    local n = v.counts[c.uid] or 0

    if (n > best) then
      best, top = n, { c.uid }
    elseif (n == best) then
      tinsert(top, c.uid)
    end
  end

  if (#top == 1) then
    rec = { state = "won", winner = top[1] }
  else
    local set = {}

    for _, uid in ipairs(top) do
      set[uid] = true
    end

    rec = { state = "tied", tied = set }
  end

  rec.counts = v.counts
  self:CSendGroupAM(v.cfgid, "LCVEN", "ALERT", v.ilink, rec.state, rec.winner or rec.tied, v.counts)
  self:VoteEnded(cfg, v.ilink, rec)

  -- The raid is told the counts, by name.
  local parts = {}

  for _, c in ipairs(v.claimants) do
    tinsert(parts, { text = strfmt("%s %d", K.DisplayName(cfg:UserName(c.uid) or c.uid), v.counts[c.uid] or 0),
      n = v.counts[c.uid] or 0 })
  end

  tsort(parts, function(a, b) return a.n > b.n end)

  local words = {}

  for _, p in ipairs(parts) do
    tinsert(words, p.text)
  end

  konfer:SendText(strfmt(L["LC_VOTE_RESULT"], L["MODTITLE"], v.ilink, tconcat(words, ", ")))

  --
  -- Offered again, the item goes to whoever the vote gave it to, or to the roll-off it left. The loot list may have moved
  -- while the council voted, so the item is looked for by its link.
  --
  for i, loot in ipairs(konfer.raid.bossloot or {}) do
    if (loot.ilink == v.ilink) then
      konfer:OfferLoot(i)
      break
    end
  end
end

--
-- Every client: the vote on ILINK in CFG has ended as REC says, nil where it was called off. The decision is kept for the
-- session (lc:Settle), and the Vote page goes.
--
function lc:VoteEnded(cfg, ilink, rec)
  self:Settle(cfg.id, ilink, rec)

  if (self.vote and self.vote.cfgid == cfg.id and self.vote.ilink == ilink) then
    self.vote = nil
    hide_vote()
  end

  if (cfg:IsActive()) then
    konfer:RefreshPolicyPages()
    konfer:RefreshLootMembers()
  end
end

-- Vote for UID, this admin's ballot, the master looter's taken there and then.
function lc:CastVote(uid)
  local v = self.vote

  if (not v) then
    return
  end

  v.mine = uid

  if (v.ballots) then
    take_ballot(K.player.name, uid)
  else
    self:CSendWhisperAM(v.cfgid, v.ml, "LCBAL", "ALERT", v.ilink, uid)
    refresh_vote()
  end
end

-- This character answering a vote on ILINK in CFG that names them among UIDS with what they wear where it would go.
function lc:AnswerGear(cfg, ilink, uids)
  local me = cfg:MyUid()

  for _, uid in ipairs(uids) do
    if (uid == me) then
      local gear = wearing(ilink)

      if (self.vote and self.vote.ilink == ilink) then
        self.vote.gear[me] = gear
        refresh_vote()
      end

      self:CSendGroupAM(cfg.id, "LCGEA", "ALERT", ilink, gear)
      return
    end
  end
end

--
-- LCVOP ilink uids
--   The master looter has opened the vote on ILINK among UIDS. Every admin of the config is shown it, and each of UIDS
--   answers with what they wear.
-- LCGEA ilink links
--   An answer: LINKS, what the sender wears where ILINK would go.
-- LCBAL ilink uid
--   Whispered to the master looter: the sender's vote, for UID.
-- LCTAL ilink counts voted voters
--   Whispered to each admin in the group: the votes each claimant has, by uid, and how many of the council have voted.
-- LCVEN ilink state who counts
--   The vote has ended: STATE "won" and WHO the winner or "tied" and WHO the set level, COUNTS each claimant's votes, or
--   "cancelled" and nothing more, called off with nothing decided.
--
local function from_ml(cfg, sender)
  local suid = cfg:FindUser(sender)

  return suid ~= nil and cfg:IsAdmin(suid) and konfer:IsSenderMasterLooter(sender)
end

lc.ihandlers.LCVOP = function(self, sender, proto, pol, cmd, cfg, ilink, uids)
  if (sender == K.player.name or not from_ml(cfg, sender) or type(ilink) ~= "string" or type(uids) ~= "table") then
    return
  end

  local claimants = {}

  for _, uid in ipairs(uids) do
    if (cfg.uids[uid]) then
      tinsert(claimants, { uid = uid, name = cfg:UserName(uid) or uid })
    end
  end

  lc:Settle(cfg.id, ilink, { state = "voting" })

  if (cfg:MyStatus()) then
    lc.vote = { cfgid = cfg.id, ilink = ilink, claimants = claimants, counts = {}, gear = {}, voted = 0,
      voters = #council_here(cfg), ml = sender }
    show_vote()
  end

  lc:AnswerGear(cfg, ilink, uids)
end

lc.ihandlers.LCGEA = function(self, sender, proto, pol, cmd, cfg, ilink, links)
  local v = lc.vote
  local uid = cfg:FindUser(sender)

  if (not v or v.cfgid ~= cfg.id or v.ilink ~= ilink or not uid or type(links) ~= "table") then
    return
  end

  local gear = {}

  for _, l in ipairs(links) do
    if (type(l) == "string") then
      tinsert(gear, l)
    end
  end

  v.gear[uid] = gear
  refresh_vote()
end

lc.ihandlers.LCBAL = function(self, sender, proto, pol, cmd, cfg, ilink, uid)
  local v = lc.vote
  local suid = cfg:FindUser(sender)

  if (v and v.ballots and v.cfgid == cfg.id and v.ilink == ilink and suid and cfg:IsAdmin(suid)) then
    take_ballot(sender, uid)
  end
end

lc.ihandlers.LCTAL = function(self, sender, proto, pol, cmd, cfg, ilink, counts, voted, voters)
  local v = lc.vote

  if (not v or v.cfgid ~= cfg.id or v.ilink ~= ilink or not from_ml(cfg, sender) or type(counts) ~= "table") then
    return
  end

  v.counts = counts
  v.voted = tonumber(voted) or 0
  v.voters = tonumber(voters) or v.voters
  refresh_vote()
end

lc.ihandlers.LCVEN = function(self, sender, proto, pol, cmd, cfg, ilink, state, who, counts)
  if (sender == K.player.name or not from_ml(cfg, sender) or type(ilink) ~= "string") then
    return
  end

  if (state == "cancelled") then
    lc:VoteEnded(cfg, ilink, nil)
    return
  end

  local rec = { state = state, counts = (type(counts) == "table") and counts or {} }

  if (state == "won" and type(who) == "string") then
    rec.winner = who
  elseif (state == "tied" and type(who) == "table") then
    rec.tied = who
  else
    return
  end

  lc:VoteEnded(cfg, ilink, rec)
end
