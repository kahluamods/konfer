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
local shortaclass = konfer.shortaclass

local tostring = tostring
local strfmt = string.format
local strlower = string.lower
local tinsert = table.insert
local tremove = table.remove
local rand = math.random
local tconcat = table.concat
local tsort = table.sort
local assert = assert
local pairs, ipairs = pairs, ipairs

--
-- Suicide Kings.
--
-- Priority is the roll list itself: the member at index 1 has first claim, and winning an item moves the winner down past
-- the raiders who were eligible for it. There is nothing to store beyond the order, which is why StandingFields is empty --
-- the ordered array Konfer already keeps for every list is the whole of a Suicide Kings standing.
--
-- This descriptor is the policy's entire surface for now. The ordering, bidding and suicide machinery still lives in
-- Loot.lua and Lists.lua and moves here as the platform seam is opened up; until it does, Suicide Kings gets the platform
-- defaults for everything it does not name below, which is exactly the behaviour that code already implements.
--
local sk = {
  handle = "sk",
  name = L["POLICY_SK_NAME"],
  nickname = L["POLICY_SK_NICK"],
  shortnick = L["POLICY_SK_SHORTNICK"],
  desc = L["POLICY_SK_DESC"],
  command = "ksk",
  order = 1,
  accent = KUI.COLOR_RUBY,

  --
  -- Suicide Kings stores no per-member numbers. A member's standing is their position in the list and nothing else.
  --
  StandingFields = {},

  -- A position, and no list holds a hundred.
  standingwidth = 2,

  --
  -- Suicide Kings' own settings, kept in each config's cfg.psettings under this handle and carried between admins as PSSET.
  -- None of them is the platform's business and none is in konfer.defaults.
  --
  -- The first is edited in this policy's own panel on the Config page's Admin tab. The other two are edited on the
  -- platform's Loot tab, because what quality of item is worth distributing and what happens when nobody bids are questions
  -- every policy has to answer, even though the answers belong to whichever policy is answering.
  --
  defaults = {
    suicide_rolls = false, -- Whether winning an open roll costs the winner a suicide
    bid_threshold = 3,     -- The item quality below which an item is not offered at all, rare unless told otherwise
    try_roll = false,      -- Whether nobody bidding opens a roll rather than ending the item
  },

  --
  -- What a raider whispers to ask where they stand. The platform calls that "standing" and Suicide Kings has asked for
  -- "suicide" for twenty years, with "position" answered as well for anybody who does not think of it that way. Only the
  -- words change; what the command does is the platform's and is the same for every policy.
  --
  -- The first is the one the help text tells people to use.
  --
  Whispers = {
    standing = { L["WHISPERCMD_SUICIDE"], L["WHISPERCMD_SUICIDE_ALTERNATE"] },
  },

  --
  -- An award here is a suicide, and the guild has called it that for twenty years. These are the only places the word
  -- appears on screen; nothing in the platform's own pages says it.
  --
  Strings = {
    AWARD_BUTTON    = L["Suicide"],
    AWARD_EXTRALIST = L["Suicide on additional list"],
    AWARD_ITEMLIST  = L["Suicide user on list"],
    AWARD_ROLL      = L["Suicide Roll (on list %q) for %s within %d seconds."],
    AWARD_UNDO      = L["Are you absolutely sure you want to undo this suicide?"],
    AWARD_AUTO      = L["AUTOSUICIDE"],
    BID_STANDING    = L["position %s"],
    ANNOUNCE_RAIDERS = L["raiders' positions on the %q list, top first: "],
    ANNOUNCE_ALL     = L["the %q list from the top: "],
  },

}

--
-- Suicide Kings' art is its cell in each of Konfer's strips. The plaque on its card reads /ksk, so it has one only while that is the command.
--
sk.TitleCard = konfer:PolicyArt("PolicyLogos", sk.order)
sk.Icon = konfer:PolicyArt("PolicyIcons", sk.order)
sk.CommandPlate = (sk.command == "ksk") and konfer:PolicyArt("PolicyCommands", sk.order) or nil

--
-- A member's standing is their place in the list, so the position column is simply the index. This is also what the platform
-- falls back to when a policy names no PositionText, but Suicide Kings states it rather than inheriting it: the index being
-- the standing is the defining claim of this policy, not an accident of how the platform happens to display a row.
--
function sk:PositionText(cfgid, listid, uid, idx)
  return tostring(idx)
end

--
-- The stored order is the priority order. This is the platform default too, and Suicide Kings states it for the same reason
-- it states PositionText: the array being the standing is what this policy is, not a convenience.
--
function sk:Order(cfgid, listid, uids)
  return uids
end

--
-- Bidders resolve by list position, best first. The platform hands them over in the list's order, which for this policy is
-- the array's, so there is nothing to sort. Suicide Kings states it for the same reason it states Order.
--
function sk:RankBidders(cfgid, listid, bidders, ilink)
  return bidders
end

-- Whether an open roll is a suicide roll is this policy's own setting.
function sk:RollAwards(cfgid, listid, ilink)
  return sk:Setting("suicide_rolls", cfgid) and true or false
end

--
-- An award here is a suicide, and its history row says where the winner stood on the list before it, the list itself being
-- the platform's part of the row: "s" for a bid won, "r" for a suicide roll and "a" for an item handed out by its own
-- instructions. PDATA is the position, 0 for somebody not on the list.
--
local HISTORY_VIA = { bid = "s", roll = "r", assign = "a" }

function sk:HistoryEntry(cfgid, via, listid, uid, ilink)
  local cfg = konfer:PolicyConfig(sk, cfgid)

  return HISTORY_VIA[via] or "s", cfg and cfg:ListPosition(uid, listid) or 0
end

--
-- The list's name, with the place the winner was suicided from in front of it where the list shows one. Plain words leave
-- the place off, so that the History tab sorts these by list rather than by the digits of a position.
--
function sk:HistoryText(cfgid, how, listid, pdata, colour)
  local cfg = konfer:PolicyConfig(sk, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local pos = tonumber(pdata) or 0
  local text = rl and rl.name or "???"

  if (colour) then
    text = konfer.white(text)

    if (pos > 0) then
      text = strfmt("[%d] %s", pos, text)
    end
  end

  if (how == "r") then
    text = strfmt(L["%s (suicide roll)"], text)
  end

  return text, ""
end

--
-- The raid is told where the winner stood on the list before the suicide, when they stood anywhere on it.
--
function sk:WinText(cfgid, how, listid, pdata, who, ilink)
  local cfg = konfer:PolicyConfig(sk, cfgid)
  local rl = cfg and listid and cfg.lists[listid]
  local pos = tonumber(pdata) or 0

  if (pos > 0) then
    who = strfmt("%s[%d]", who, pos)
  end

  return strfmt(L["%s won %s on the %q list. Grats!"], who, ilink, rl and rl.name or "???")
end

--
-- WHAT THIS POLICY SAYS ABOUT SOMEBODY ON A LIST
--
-- Who is on a list is the platform's and what they are worth on it is the policy's, so the platform carries a block it
-- never reads and hands it here. For Suicide Kings that block is one number, the position, the array's order being the
-- whole of what this policy claims. EP/GP's would be two numbers and DKP's one of its own.
--
-- There is nothing kept beside the array, so nothing to forget when somebody leaves and MemberRemoved is not implemented.
--
function sk:MemberInfo(cfgid, listid, uid)
  return konfer:Config(cfgid):ListPosition(uid, listid)
end

--
-- Put UID at POS, or on the bottom when that is not a place in the list. Answers where they actually went, which is what
-- the event then carries, so that two clients place them alike rather than each resolving the same request for itself.
--
function sk:SetMemberInfo(cfgid, listid, uid, pos)
  local rl = konfer:Config(cfgid).lists[listid]
  local last = #rl.users + 1

  pos = tonumber(pos) or last

  if (pos < 1 or pos > last) then
    pos = last
  end

  tinsert(rl.users, pos, uid)

  return pos
end

--
-- A whole list's worth. The order is the standing, and the platform already carries the order, so there is nothing here
-- that is not in the membership itself. It is stated rather than left out, because a policy with numbers of its own has
-- to answer and the shape of the answer is the same for all of them.
--
function sk:ListInfo(cfgid, listid)
  return nil
end

function sk:SetListInfo(cfgid, listid, pdata)
end

--
-- WHERE AN INSERT LANDS
--
-- Four dialogs put people onto a list and every one of them asks the same question: on the bottom, or somewhere at
-- random. A position is a standing only in this policy, so the platform reserves a row in each of them and this fills it.
--
-- Kept per place, because importing a whole guild rank and adding one person to a list are not the same question. A fresh
-- list wants shuffling and has always defaulted to it; putting one more person on an established list does not.
--
-- Read when somebody is picked rather than when the box is ticked, the insert popup staying open so a whole raid can go in
-- at once with the box turned on and off between picks.
--
local random_insert = {
  insert     = false,
  import     = true,
  addmissing = false,
}

sk.InsertUI = {
  Construct = function(self, parent, owner, where)
    local arg = {
      x = 0, y = 2, width = 150, parent = parent,
      initialvalue = random_insert[where], label = { text = L["Insert randomly"] },
    }

    local cb = KUI:CreateCheckBox(arg, parent)

    --
    -- The insert popup closes itself when the pointer leaves it, so a control on it has to hold that off while it is being
    -- used. OWNER is that popup, or nil in a dialog, which stays open until it is answered and has no counter to hold.
    --
    if (owner) then
      cb.toplevel = owner
      cb:HookScript("OnEnter", function(this) this.toplevel:StopTimeoutCounter() end)
      cb:HookScript("OnLeave", function(this) this.toplevel:StartTimeoutCounter() end)
    end

    --
    -- Through KUI, because MakeFrame hooks SetFrameLevel to flatten everything under a frame to one above it, which is
    -- right while a window is being built and wrong once one is standing.
    --
    KUI:SetFrameLevelKeeping(cb, parent:GetFrameLevel() + 1)

    cb:Catch("OnValueChanged", function(this, evt, val)
      random_insert[where] = val
    end)

    -- The platform ignores this; SK's own dialogs, which put the row up themselves, want the box to enable.
    return cb
  end,
}

--
-- Where the next insert puts them, which for this policy is a position. The bottom unless that place's box is ticked.
--
function sk:InsertInfo(cfgid, listid, where)
  local rl = konfer:Config(cfgid).lists[listid]
  local last = #rl.users + 1

  return random_insert[where] and rand(last) or last
end

--
-- IMPORTING MEMBERS AND ADDING THE MISSING
--
-- Suicide Kings' own, through the descriptor's ImportList and AddMissing, the platform keeping only what turns names and
-- guild ranks into the config's users (see cfg:ImportNames). What is this policy's is where they land: a place on the list,
-- the bottom unless Insert randomly is ticked, from the same row the insert popup has.
--
-- Each dialog is built once and put up over the policy window, which goes away while it is up and comes back however it is
-- closed. IMPORTING is the config and list the dialog is about while it is up.
--
local importing = {}

local function sk_dialog(name, title, height)
  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = name, title = title, border = true, width = 400, height = height,
    canmove = true, canresize = false, escclose = true, blackbg = true, okbutton = true, cancelbutton = true,
  })

  -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
  dlg:Catch("OnHide", function(t, evt)
    konfer.mainwin:Show()
  end)

  return dlg
end

-- The Insert randomly row for WHERE, one standard row tall, at YPOS on DLG and X in. Answers the next YPOS and the box.
local function sk_insert_row(dlg, where, ypos, x)
  local row = KUI.MakeFrame("Frame", nil, dlg.content)

  row:SetSize(300, 20)
  row:SetPoint("TOPLEFT", dlg.content, "TOPLEFT", x or KUI.WIDGET_GAP, ypos)

  return ypos - 20 - KUI.WIDGET_GAP, sk.InsertUI.Construct(sk, row, nil, where)
end

--
-- Put UID onto LISTID if they are not on it, where WHERE's Insert randomly says, or with no WHERE at the bottom.
--
local function sk_put_on(cfg, listid, uid, where)
  if (not cfg:IsInList(uid, listid)) then
    cfg:InsertMember(uid, listid, where and (sk:InsertInfo(cfg.id, listid, where)) or nil)
  end
end

local importdlg = nil

--
-- Import into LISTID of CFGID a guild rank, or names typed in: separated by commas, or a JSON array, whose order is the
-- point. A guild rank goes in at the bottom or at random, as its Insert randomly says, which is why that row stands under
-- it. Names can set the list to exactly them, in their order, or be added at the bottom of the members it has. Everybody
-- named has to be a user of the config already, and one who is not stops the import and is named, so that nothing half
-- happens. The two halves are one or the other: using either puts the other out of reach, and the guild rank half is out
-- of reach altogether for a character with no guild.
--
-- Where the names go a list export can be pasted instead, this mod's own or the old Konfer Suicide Kings', and one of its
-- lists chosen. Its members stand for names in the list's order, and anybody the config does not hold is made a user with
-- the export's class for them, the export saying who they are as a guild rank does.
--
function sk:ImportList(cfgid, listid)
  if (not importdlg) then
    local ypos = 0 - KUI.WIDGET_GAP
    local dlg = sk_dialog("KonferSKImportDialog", "", 280)

    dlg.Sync = function(this)
      local ranks = (K.player.is_guilded and this.text == "") and true or false

      this.grank:SetEnabled(ranks)
      this.random:SetEnabled(ranks)
      this.names:SetEnabled(this.rank == 0)
      this.list:SetEnabled((this.lists and this.rank == 0) and true or false)
      this.how:SetEnabled(this.text ~= "" and this.rank == 0)
    end

    dlg.curlist = konfer:CurrentListBox(dlg, ypos)
    ypos = ypos - dlg.curlist:GetHeight() - KUI.WIDGET_GAP

    dlg.grank = KUI:CreateDropDown({
      x = 4, y = ypos, dwidth = 175, mode = "SINGLE", itemheight = 16, items = KUI.emptydropdown,
      name = "KonferSKImportRank", label = { text = L["Guild rank to import"], pos = "LEFT" },
    }, dlg)
    dlg.grank:Catch("OnValueChanged", function(t, evt, newv)
      dlg.rank = tonumber(newv) or 0
      dlg:Sync()
    end)
    ypos = ypos - dlg.grank:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    ypos, dlg.random = sk_insert_row(dlg, "import", ypos, 24)

    -- A list export can run past any length worth guessing at, so the box takes as many as are pasted.
    dlg.names = KUI:CreateEditBox({
      x = 4, y = ypos, len = 0, label = { text = L["Names (CSV or JSON)"], pos = "LEFT" },
      tooltip = { title = "$$", text = L["TIP110"] },
    }, dlg)
    dlg.names:Catch("OnValueChanged", function(t, evt, newv)
      local items = {}

      dlg.text = newv or ""
      dlg.lists, dlg.why = nil, nil

      if (konfer:IsExportText(dlg.text)) then
        dlg.lists, dlg.why = konfer:ParseListExport(dlg.text)
      end

      for i, l in ipairs(dlg.lists or {}) do
        tinsert(items, { text = l.name, value = i })
      end

      dlg.listv = 1
      dlg.list:UpdateItems(#items > 0 and items or KUI.emptydropdown)
      dlg.list:SetValue(1)
      dlg:Sync()
    end)
    ypos = ypos - dlg.names:GetHeight() - KUI.WIDGET_GAP

    dlg.list = KUI:CreateDropDown({
      x = 4, y = ypos, dwidth = 175, mode = "SINGLE", itemheight = 16, items = KUI.emptydropdown, enabled = false,
      name = "KonferSKImportList", label = { text = L["List to import"], pos = "LEFT" },
    }, dlg)
    dlg.list:Catch("OnValueChanged", function(t, evt, newv)
      dlg.listv = tonumber(newv) or 1
    end)
    ypos = ypos - dlg.list:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    local hows = {
      { text = L["Set list to imported values"], value = 1 },
      { text = L["Add to existing members"], value = 2 },
      { text = L["Randomly add to members list"], value = 3 },
    }

    dlg.how = KUI:CreateDropDown({
      x = 16, y = ypos, mode = "SINGLE", itemheight = 16, name = "KonferSKImportHow", enabled = false, initialvalue = 1,
      dwidth = KUI:DropDownWidth({ hows[1].text, hows[2].text, hows[3].text }), items = hows,
    }, dlg)
    dlg.how:Catch("OnValueChanged", function(t, evt, newv)
      dlg.howv = newv
    end)
    ypos = ypos - dlg.how:GetHeight()

    -- As tall as what it holds and a little more, what is round the content being whatever the dialog's frame takes.
    dlg:SetHeight(dlg:GetHeight() - dlg.content:GetHeight() - ypos + 20)

    dlg.OnAccept = function(t)
      local cfg = konfer:Config(importing.cfgid)
      local lid = importing.listid

      if (not cfg or not cfg.lists[lid]) then
        dlg:Hide()
        return
      end

      if (dlg.rank ~= 0) then
        for _, uid in ipairs(cfg:ImportGuildRank(lid, dlg.rank)) do
          sk_put_on(cfg, lid, uid, "import")
        end
      elseif (dlg.text ~= "") then
        local uids

        if (konfer:IsExportText(dlg.text)) then
          local l = dlg.lists and dlg.lists[dlg.listv]

          if (not l) then
            sk:err(dlg.why or L["that is not a Konfer list export."])
            return
          end

          uids = cfg:ImportMembers(lid, l.members)
        else
          local names, why = konfer:ParseNames(dlg.text)

          if (not names) then
            sk:err(why)
            return
          end

          local missing

          uids, missing = cfg:ImportNames(lid, names)

          if (#missing > 0) then
            sk:err(L["The following users are missing from the user list: %s"], tconcat(missing, ", "))
            sk:err(L["Import from the CSV string cannot continue until these users are added."])
            return
          end
        end

        if (dlg.howv == 1) then
          cfg:SetMemberList(tconcat(uids, ""), lid)
        elseif (dlg.howv == 3) then
          -- Each at a place of its own among the members there are, the ones added before it included.
          for _, uid in ipairs(uids) do
            if (not cfg:IsInList(uid, lid)) then
              cfg:InsertMember(uid, lid, rand(#cfg.lists[lid].users + 1))
            end
          end
        else
          -- At the bottom in the order given, Insert randomly being the guild rank's.
          for _, uid in ipairs(uids) do
            sk_put_on(cfg, lid, uid)
          end
        end
      end

      dlg:Hide()
      konfer:RefreshAllMemberLists(lid)
    end

    importdlg = dlg
  end

  local dlg = importdlg
  local gitems = { { text = K.NONE_STR, value = 0 } }

  if (K.player.is_guilded) then
    for i = 1, K.guild.numranks do
      tinsert(gitems, { text = K.guild.ranks[i], value = i })
    end
  end

  importing.cfgid, importing.listid = cfgid, listid
  dlg.rank, dlg.text, dlg.howv = 0, "", dlg.howv or 1

  dlg.grank:UpdateItems(gitems)
  dlg.grank:SetValue(0)
  dlg.names:SetText("")
  dlg.how:SetValue(dlg.howv)
  dlg:Sync()
  konfer:ShowCurrentList(dlg.curlist, cfgid, listid)
  dlg:SetTitleText(sk:WindowTitle(L["Import list members"]))

  konfer.mainwin:Hide()
  dlg:Show()
end

local missingdlg = nil

--
-- Put onto LISTID of CFGID the raiders who are not on it, or everybody the config holds who is not.
--
function sk:AddMissing(cfgid, listid)
  if (not missingdlg) then
    local ypos = 0
    local dlg = sk_dialog("KonferSKAddMissingDialog", "", 175)

    dlg.curlist = konfer:CurrentListBox(dlg, ypos)
    ypos = ypos - dlg.curlist:GetHeight() - KUI.WIDGET_GAP

    local items = {
      { text = L["Add missing raid members"], value = 1 },
      { text = L["Add all missing members"], value = 2 },
    }

    dlg.what = KUI:CreateDropDown({
      x = KUI.WIDGET_GAP, y = ypos, mode = "SINGLE", itemheight = 16, name = "KonferSKWhoMissing",
      dwidth = KUI:DropDownWidth({ items[1].text, items[2].text }), items = items, initialvalue = 1,
      label = { text = L["Select"], pos = "LEFT" },
    }, dlg)
    dlg.what:Catch("OnValueChanged", function(t, evt, newv)
      dlg.whatv = tonumber(newv)
    end)
    ypos = ypos - dlg.what:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    sk_insert_row(dlg, "addmissing", ypos)

    dlg.OnAccept = function(t)
      local cfg = konfer:Config(importing.cfgid)
      local lid = importing.listid
      local rl = cfg and cfg.lists[lid]

      if (rl) then
        for _, uid in ipairs(cfg:MissingFromList(lid, dlg.whatv == 1)) do
          sk_put_on(cfg, lid, uid, "addmissing")
          sk:info(L["added %s to list %q at position %s."], shortaclass(cfg:UserNameClass(uid)), konfer.white(rl.name),
            konfer.white(tostring(cfg:ListPosition(uid, lid))))
        end
      end

      dlg:Hide()
      konfer:RefreshAllMemberLists(lid)
    end

    missingdlg = dlg
  end

  local dlg = missingdlg

  importing.cfgid, importing.listid = cfgid, listid
  dlg.whatv = 1
  dlg.what:SetValue(1)
  konfer:ShowCurrentList(dlg.curlist, cfgid, listid)
  dlg:SetTitleText(sk:WindowTitle(L["Add missing members"]))

  konfer.mainwin:Hide()
  dlg:Show()
end

--
-- MOVING A MEMBER BY HAND
--
-- This is Suicide Kings' own and nothing of it is the platform's. What a hand move means here is a place in the array,
-- because the array is the standing; EP/GP and DKP move somebody by changing a number and have no use for any of it.
--
-- DIR is 1 to move them down one, 2 to move them up one, 0 to send them to the extreme bottom and 3 to king them. A
-- direction that is none of the four moves nobody, rather than taking them out of the list and putting them nowhere.
--
-- The whole raw list, and it moves over frozen members too. An award is the one that has to know who was in the raid; a
-- hand move is the list as it stands.
--
function sk:MoveMember(cfgid, uid, listid, dir)
  local cfp = konfer:Config(cfgid)
  local rl = cfp and cfp.lists[listid]

  if (not rl or (dir ~= 0 and dir ~= 1 and dir ~= 2 and dir ~= 3)) then
    return true
  end

  local ul = rl.users
  local up = nil

  for k, v in ipairs(ul) do
    if (v == uid) then
      up = k
      break
    end
  end

  if (not up) then
    return true
  end

  local m = tremove(ul, up)

  if (dir == 0) then
    tinsert(ul, m)
  elseif (dir == 3) then
    tinsert(ul, 1, m)
  elseif (dir == 1) then
    tinsert(ul, (up ~= #ul + 1) and up + 1 or up, m)
  elseif (dir == 2) then
    tinsert(ul, (up ~= 1) and up - 1 or up, m)
  end

  if (cfp:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end

  return false
end

--
-- Move UID down list LISTID, past the raiders in RLIST who were eligible for the item. Modifies the stored order in place,
-- records nothing and sends nothing. Returns the members who moved, in the order they were in before the move, which is what putting it back needs.
--
-- First find the user being suicided in the raiders list. Anyone above them is not subject to moving, so discount those.
-- Once the user is found, add their current position to the movers list and every raider below them after it, so movers
-- holds everyone actually affected and the slot each currently sits in. Then it is a matter of moving the first to the
-- bottom and everyone else up one.
--
-- The wrinkle is a frozen member. Their position has to stay put even when they were in the raid, so they are left out of
-- movers. One exception: a frozen member who is themselves the one being suicided is treated as if they were not, and goes
-- to the bottom like anybody else.
--
-- NOREFRESH suppresses the member list rebuild, for a caller replaying a batch of events who will refresh once at the end.
--
local function suicide_user(cfgid, listid, rlist, uid, norefresh)
  local cfp = konfer:Config(cfgid)

  if (not cfp or not cfp.lists[listid]) then
    return nil
  end

  local lu = cfp.lists[listid].users
  local found = false
  local movers = {}

  for i = 1, #rlist do
    if (rlist[i] == uid) then
      found = true
      break
    end
  end

  --
  -- This should never happen but hey, whats a simple check.
  --
  if (not found) then
    return nil
  end

  local foundfirst = false
  for i = 1, #lu do
    found = false
    local j = 1
    while (j <= #rlist) do
      if (lu[i] == rlist[j]) then
        found = true
        break
      end
      j = j + 1
    end

    if (found) then
      if (lu[i] == uid) then
        foundfirst = true
      end
      if (foundfirst) then
        if (lu[i] == uid or not konfer:Config(cfgid):IsFrozen(lu[i])) then
          tinsert(movers, i)
        end
      end
    end
  end

  --
  -- This checks to ensure that the first user in the movers list is actually the userid being suicided. If not, it means
  -- that for some reason the user was not in the list and we therefore have nothing to do. If we only have one entry in
  -- movers, nobody eligible stands below the winner, and winning still costs them their place: they are moved to the extreme
  -- bottom of the list, below everybody present or not, and everyone below them except frozen users moves up one slot.
  --
  if (lu[movers[1]] ~= uid) then
    return nil
  end

  if (#movers == 1) then
    --
    -- Add every user that isn't frozen after the user's current position to the movers list. This will effectively move the
    -- user to the bottom of the list and move everyone else (that is unfrozen) up one slot. If there are no users below the
    -- user being suicided it means they are already at the bottom of the list and we have nothing to do.
    --
    local p = movers[1]
    if (p == #lu) then
      return nil
    end
    for i = p+1, #lu do
      if (not konfer:Config(cfgid):IsFrozen(lu[i])) then
        tinsert(movers, i)
      end
    end
  end

  --
  -- Final step. Adjust the actual list users array according to movers, having first taken a copy of who was where, which is
  -- what undoing the move needs and is what this hands back.
  --
  local nmoved = #movers
  local moved = {}

  for i = 1, nmoved do
    moved[i] = lu[movers[i]]
  end

  local nmove = nmoved - 1
  for i = 1, nmove do
    lu[movers[i]] = lu[movers[i+1]]
  end
  lu[movers[nmove+1]] = uid

  if (not norefresh) then
    konfer:RefreshAllMemberLists()
  end

  return moved
end

--
-- Winning an item moves you below the raiders who were eligible for it.
--
-- RLIST is the raid-present subset of the list in list order, because a suicide moves the winner only past players who could
-- actually have won it. CHAIN says to apply the same move to whatever extra list the primary names, which is what a loot
-- award does and a hand correction of the list does not. NOCMD suppresses the event, for a move another admin already
-- decided and sent us, and NOREFRESH the member list rebuild, for a caller replaying a batch who will refresh once at the
-- end. Those last two are the platform's own convention for a mutator, not anything particular to this policy.
--
-- Returns one entry per list actually moved, each carrying that list's id and an opaque token, which for Suicide Kings is
-- the members who moved in the order they were in beforehand. A chained award moves two lists and so hands back two, and the
-- platform puts one undo record on the stack for each.
--
function sk:Award(cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh)
  local ll = konfer:Config(cfgid).lists[listid]
  local moves = {}

  --
  -- A tethered list holds mains only, so an alt's win is the main's suicide. That is worked out once, by whoever makes the
  -- award, and the event carries the member actually moved. Another admin's alt links may differ, so one applying that event works nothing out again.
  --
  local ia, ruid = konfer:Config(cfgid):IsAlt(uid)

  if (nocmd or not ia or not ll.tethered) then
    ruid = uid
  end

  local token = suicide_user(cfgid, listid, rlist, ruid, norefresh)

  if (token) then
    tinsert(moves, { listid = listid, token = token })

    if (not nocmd) then
      konfer:Config(cfgid):AddEvent("SULST", listid, ruid, tconcat(rlist, ""))
    end
  end

  if (chain and ll.extralist and ll.extralist ~= "0" and ll.extralist ~= listid) then
    local trlist = konfer:Config(cfgid):CreateRaidList(ll.extralist)
    local etoken = suicide_user(cfgid, ll.extralist, trlist, ruid, norefresh)

    if (etoken) then
      tinsert(moves, { listid = ll.extralist, token = etoken })

      if (not nocmd) then
        konfer:Config(cfgid):AddEvent("SULST", ll.extralist, ruid, tconcat(trlist, ""))
      end
    end
  end

  return moves
end

--
-- Put a suicide back. TOKEN is what Award returned: the members who moved, in the order they were in beforehand, the first
-- of whom is the one who was suicided. That is UID, or UID's main when an alt won on a tethered list, so the token rather
-- than UID says who goes back.
--
-- The suicide moved each of them into the slot of the one before, and the first into the last slot. So the slot member I+1
-- holds now is the one member I held before, and the slot the first holds now is the last member's.
--
function sk:UndoAward(cfgid, listid, uid, ilink, token, nocmd)
  local movers = token
  local mpos = {}

  for k,v in ipairs(movers) do
    local il, lp = konfer:Config(cfgid):IsInList(v, listid)
    assert(il)
    tinsert(mpos, lp)
  end

  local ncount = #movers
  local lu = konfer:Config(cfgid).lists[listid].users

  for i = 1, ncount - 1 do
    lu[mpos[i+1]] = movers[i]
  end

  lu[mpos[1]] = movers[ncount]

  if (konfer:Config(cfgid):IsActive()) then
    konfer:RefreshAllMemberLists()
  end

  if (not nocmd) then
    konfer:Config(cfgid):AddEvent("SUNDO", listid, tconcat(movers, ""), uid, ilink)
  end
end

--
-- Build Suicide Kings' own options into PARENT, which is the frame the config panel sets aside for whichever policy a config
-- runs. Everything in here is the policy's: the platform hands over a frame and never looks inside it again, so a policy is
-- free to lay its options out however suits it.
--
-- The widgets are kept on the policy rather than on the frame so that RefreshConfigUI below can find them without being told
-- where they went, along with the config they are showing, which is the one the Admin tab has selected and not necessarily
-- the one this window has in hand.
--
function sk:CreateConfigUI(parent)
  local ypos = 0
  local arg

  self.cfgui = {}

  --
  -- The roll itself is the platform's and its settings are on the loot tab, but what winning one costs the winner is the
  -- policy's answer, and here that answer is a suicide.
  --
  arg = {
    x = 0, y = ypos, label = { text = L["Enable suicide rolls by default"] },
    tooltip = { title = "$$", text = L["TIP093"] },
  }
  self.cfgui.suicideroll = KUI:CreateCheckBox(arg, parent)

  --
  -- The setting is this policy's own, held with the rest of the tab's changes until the tab is saved. See konfer:AdminPending.
  --
  self.cfgui.suicideroll:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and self.cfgui.cfgid) then
      konfer:AdminPending():Set("p.suicide_rolls", val and true or false)
    end
  end)
  konfer:AdminPending():Watch(self.cfgui.suicideroll, "p.suicide_rolls")
  ypos = ypos - self.cfgui.suicideroll:GetHeight()

  -- The height the options took, which is what the panel round them is made.
  return 0 - ypos
end

--
-- Put CFGID's values back into the options built above, CFGID being the config the Admin tab has selected. Called when that
-- selection changes and when the roll lists do.
--
function sk:RefreshConfigUI(cfgid)
  local cfp = self.cfgui and konfer:PolicyConfig(self, cfgid)

  if (not cfp) then
    return
  end

  self.cfgui.cfgid = cfgid
  self.cfgui.suicideroll:SetChecked(konfer:AdminPending():Value("p.suicide_rolls"), true)
end

--
-- The options above can be used only while the Admin tab has a configuration selected, which is also when their panel's
-- title is lit. With none, they are about no config at all.
--
function sk:EnableConfigUI(onoff, cfgid)
  if (not self.cfgui) then
    return
  end

  if (not onoff) then
    self.cfgui.cfgid = nil
  end

  self.cfgui.suicideroll:SetEnabled(onoff)
end

--
-- Suicide Kings' panel on the Lists page, titled Position: the buttons that move the selected member about the list. They
-- act on whatever MemberSelection last said was selected, which is kept on the panel's own frame, and are enabled only where
-- the move would do something.
--
local function lists_member_selection(client, cfgid, listid, uid, pos)
  client.selection = uid and { cfgid = cfgid, listid = listid, uid = uid } or nil

  local adm = uid and konfer:PolicyAdmin(sk) and true or false
  local up = adm and pos > 1
  local down = adm and pos < #sk:Members(cfgid, listid)

  client.kingbutton:SetEnabled(up)
  client.upbutton:SetEnabled(up)
  client.downbutton:SetEnabled(down)
  client.awardbutton:SetEnabled(down)
end

--
-- The buttons are two rows of this, with the standard gap between them, and the panel is exactly that tall.
--
local LISTS_BTN_H = 24

--
-- DIR is 2 for up one, 1 for down one, 3 for the top and 0 for the bottom, as sk:MoveMember takes it.
--
local function lists_move(client, dir)
  local sel = client.selection

  if (not sel) then
    return
  end

  if (konfer.popupwindow) then
    konfer.popupwindow:Hide()
    konfer.popupwindow = nil
  end

  --
  -- Sending a member to the bottom while a raid is on is a suicide rather than a move. Ninety nine times in a hundred,
  -- adjusting a member by hand during a raid is fixing a mis-loot, and the suicide would have happened on its own had the
  -- item gone to the right person. Doing repairs to the list outside a raid means what it says instead, so that goes through
  -- sk:MoveMember and lands them at the extreme bottom. A config the raid is not being run against is outside it, whoever is in the group.
  --
  if (dir == 0 and konfer.raid.uidmap and konfer:Config(sel.cfgid):IsActive()) then
    local rlist = konfer:Config(sel.cfgid):CreateRaidList(sel.listid)
    konfer:Config(sel.cfgid):AwardItem(sel.listid, sel.uid, nil, rlist, false)
  else
    konfer:Config(sel.cfgid):AddEvent("SUMOV", sel.uid, sel.listid, dir)
    sk:MoveMember(sel.cfgid, sel.uid, sel.listid, dir)
  end
end

local function lists_construct(client)
  local arg = {
    x = 0, y = 0, width = 98, height = LISTS_BTN_H, text = L["Move up"], enabled = false,
    tooltip = { title = "$$", text = L["TIP033"] },
  }
  client.upbutton = KUI:CreateButton(arg, client)
  client.upbutton:Catch("OnClick", function(this, evt)
    lists_move(client, 2)
  end)

  arg.x = 100
  arg.text = L["Move down"]
  arg.tooltip = { title = "$$", text = L["TIP034"] }
  client.downbutton = KUI:CreateButton(arg, client)
  client.downbutton:Catch("OnClick", function(this, evt)
    lists_move(client, 1)
  end)

  arg.x = 0
  arg.y = 0 - client.downbutton:GetHeight() - KUI.WIDGET_GAP
  arg.text = L["King"]
  arg.tooltip = { title = "$$", text = L["TIP032"] }
  client.kingbutton = KUI:CreateButton(arg, client)
  client.kingbutton:Catch("OnClick", function(this, evt)
    lists_move(client, 3)
  end)

  arg.x = 100
  arg.text = sk:Str("AWARD_BUTTON")
  arg.tooltip = { title = "$$", text = L["TIP035"] }
  client.awardbutton = KUI:CreateButton(arg, client)
  client.awardbutton:Catch("OnClick", function(this, evt)
    lists_move(client, 0)
  end)
end

sk.ListsPage = {
  title = L["Position"],
  height = LISTS_BTN_H + KUI.WIDGET_GAP + LISTS_BTN_H,
  Construct = lists_construct,
  MemberSelection = lists_member_selection,
}

konfer:RegisterPolicy(sk)
