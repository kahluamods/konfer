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
local H = LibStub:GetLibrary("KoreHash")

if (not K) then
  return
end

local konfer = K:GetAddon("Konfer")
local cfgm = konfer.configmethods
local KU = K.Users
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local DB = konfer.DB
local LS = konfer.LS
local ZL = konfer.ZL

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local tonumber = tonumber
local max = math.max
local strfmt = string.format
local strlen = string.len
local strsub = string.sub
local strgsub = string.gsub
local strupper = string.upper
local strrep = string.rep
local tconcat = table.concat
local pairs, ipairs = pairs, ipairs
local bxor = bit.bxor
local debug = konfer.debug

--
-- This file contains general purpose utility functions used throughout Konfer.
--

--
-- The markers shown beside somebody on a list, each in brackets of its own: [E] a raid enchanter, [F] frozen, [R] reserved,
-- [?] not consenting to the leader collecting the group's loot (GroupLoot.lua). Empty when there are none.
--
function konfer:UserMarkers(ench, frozen, res, noconsent)
  local s = ""

  if (ench) then
    s = s .. "[" .. L["USER_ENCHANTER"] .. "]"
  end
  if (frozen) then
    s = s .. "[" .. L["USER_FROZEN"] .. "]"
  end
  if (res) then
    s = s .. "[" .. L["USER_RESERVED"] .. "]"
  end
  if (noconsent) then
    s = s .. "[" .. L["USER_NOCONSENT"] .. "]"
  end

  return s
end

--
-- Show the main spec and off spec roles of UID in CFG on a row's two role icons, both blank for no UID. An off spec that
-- would draw the same icon as the main spec is left blank, one icon saying all there is to say about somebody who plays the
-- same part either way.
--
function konfer:SetRoleIcons(msicon, osicon, cfg, uid)
  local ent = cfg and uid and cfg.uids[uid]

  self:SetPersonRoleIcons(msicon, osicon, ent and ent[konfer.CFGUSER_KUID])
end

-- The same for the person KUID, whatever config holds them or none, both blank for no KUID.
function konfer:SetPersonRoleIcons(msicon, osicon, kuid)
  local ms, os = KU:Roles(kuid)

  if (KUI:RoleIconKind(os) == KUI:RoleIconKind(ms)) then
    os = nil
  end

  msicon:SetRole(ms)
  osicon:SetRole(os)
end

--
-- Pack what a row in a list of people shows at its right against EDGE's right, right to left, as every such list has it: the
-- off spec's role ROW_INSET in, the main spec's before it, a gap and the MARKERS, only as wide as their own words. An icon
-- with no role takes no room. Answers what the name should stop short of, the region and the gap to leave before it: EDGE
-- and the inset with nothing shown.
--
local ROW_INSET = 8

function konfer:PackRowRight(edge, osrole, msrole, markers)
  local at, point = edge, "RIGHT"

  for _, icon in ipairs({ osrole, msrole }) do
    if (icon:IsShown()) then
      icon:ClearAllPoints()
      icon:SetPoint("RIGHT", at, point, (at == edge) and (0 - ROW_INSET) or -2, 0)
      at, point = icon, "LEFT"
    end
  end

  local gap = (at == edge) and (0 - ROW_INSET) or (0 - KUI.WIDGET_GAP)

  markers:ClearAllPoints()
  markers:SetPoint("RIGHT", at, point, gap, 0)

  if ((markers:GetText() or "") ~= "") then
    return markers, 0 - KUI.WIDGET_GAP
  end

  return at, gap
end

--
-- The standing column a list of members gives POL: how wide it is, room for the policy's standingwidth characters in
-- brackets in its standingfont, and that font. What goes in it is PositionText in brackets and is never padded out. A
-- policy whose standingwidth is 0 shows no standing, and the column takes no room.
--
function konfer:StandingColumn(pol)
  local font = (pol and pol.standingfont) or "GameFontNormalSmall"
  local chars = (pol and pol.standingwidth) or 2

  if (chars == 0) then
    return 0, font
  end

  return KUI:MeasureStrWidth("[" .. strrep("0", chars) .. "]", font), font
end

--
-- The tooltip for a row naming UID of CFG in one of the lists of people: who they are, what is known of their character,
-- and what the markers on the row stand for, spelled out on a line of their own. Reserved is tonight's raid, so only a
-- list shows it, WITHRES saying this is one. ANCHOR is which side of the row it stands, "ANCHOR_RIGHT" unless told, so
-- that a list can keep it off whatever it would otherwise cover. A row carrying .standing, the policy's PositionText for
-- them, has it in brackets at the right of the name.
--
-- A row on one of the config's roll lists, LISTID, has under a blank line whatever the config's policy says about them on
-- it (UserTooltip in Policy.lua). A row about no list has nothing, there being no list for it to be about. Last comes how
-- this player rates them, where they have rated them at all. Somebody with nothing to say of them but their name has none.
--
function konfer:ShowUserTooltip(row, cfg, uid, withres, anchor, listid)
  local name, cls = cfg:UserNameClass(uid)

  if (not name) then
    return
  end

  GameTooltip:SetOwner(row, anchor or "ANCHOR_RIGHT")

  -- A row on a list says where they stand on it, in the policy's words, to the right of the name.
  if (row.standing and row.standing ~= "") then
    GameTooltip:AddDoubleLine(konfer.aclass(name, cls), "[" .. row.standing .. "]", nil, nil, nil, 1, 1, 1)
  else
    GameTooltip:SetText(konfer.aclass(name, cls))
  end

  KU:AddUserFacts(GameTooltip, cfg.uids[uid][konfer.CFGUSER_KUID])

  local words = {}

  if (cfg:IsEnchanter(uid)) then
    tinsert(words, L["Raid enchanter"])
  end
  if (cfg:IsFrozen(uid)) then
    tinsert(words, L["frozen"])
  end
  if (withres and cfg:IsReserved(uid)) then
    tinsert(words, L["reserved"])
  end

  if (#words > 0) then
    local s = strgsub(tconcat(words, ", "), "^%l", strupper)

    GameTooltip:AddLine(s, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
  end

  local pol = listid and cfg.lists[listid] and cfg:GetPolicy()

  if (pol and pol.UserTooltip) then
    local _, lines = self:PolicyHook(pol, "UserTooltip", nil, pol.UserTooltip, pol, cfg.id, listid, uid)

    if (type(lines) == "table" and #lines > 0) then
      GameTooltip:AddLine(" ")

      for _, l in ipairs(lines) do
        GameTooltip:AddDoubleLine(l[1], l[2], NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b,
          HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
      end
    end
  end

  -- Last of all, under a blank line, how this player rates them, each thing rated in its rating's colour.
  KU:AddUserRatings(GameTooltip, cfg.uids[uid][konfer.CFGUSER_KUID], true)

  -- A tooltip that would say no more than the row it is for, the name and where they stand, is not shown at all.
  if (GameTooltip:NumLines() <= 1) then
    GameTooltip:Hide()
    return
  end

  GameTooltip:Show()
end

--
-- An item's tooltip, the game's own and the one a link clicked in chat opens, and another addon's loot browser where it draws
-- on the game's: what the active policy says the item costs (ItemTooltip in Policy.lua), on the config it has in hand, under
-- a blank line. A raider sees it as much as an admin does, from whatever copy of the config they hold. The comparison
-- tooltips beside one show what is being worn, and say nothing.
--
-- Only gear is asked about, being what a raid hands out: armour, weapons, and the tier tokens traded in for armour, a token
-- being a formality on the way to the piece it stands for (konfer:TokenEquipLoc). Anything else is asked about only where the
-- config's item editor holds it, an admin having put it there to be handed out too.
--
-- How a tooltip says an item was set on it, and which item, differs between the clients (K.HAS_TOOLTIP_DATA): retail runs
-- whatever was added after the game's lines through the tooltip data system, and every classic client fires the tooltip's
-- OnTooltipSetItem.
--
local function displayed_item(tip)
  if (K.HAS_TOOLTIP_DATA) then
    return TooltipUtil.GetDisplayedItem(tip)
  end

  return tip:GetItem()
end

local function item_tooltip(tip)
  local pol = konfer.apol

  if (not pol or not pol.currentid or not pol.ItemTooltip or konfer:IsSuspended()) then
    return
  end

  local tname = tip.GetName and tip:GetName()

  if (tname and strsub(tname, 1, 15) == "ShoppingTooltip") then
    return
  end

  local _, ilink = displayed_item(tip)

  if (not ilink or not K.CanAccess(ilink)) then
    return
  end

  local _, icls = K.GetItemClassInfo(ilink)
  local itemid = ilink:match("item:(%d+)")
  local gear = icls == Enum.ItemClass.Armor or icls == Enum.ItemClass.Weapon or (itemid and konfer:TokenEquipLoc(itemid))

  if (not gear and not (itemid and pol.cfg and pol.cfg.items[itemid])) then
    return
  end

  local _, info = konfer:PolicyHook(pol, "ItemTooltip", nil, pol.ItemTooltip, pol, pol.currentid, ilink)

  if (type(info) ~= "table" or type(info.lines) ~= "table" or #info.lines == 0) then
    return
  end

  tip:AddLine(" ")

  if (info.title) then
    tip:AddLine(info.title, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
  end

  for _, l in ipairs(info.lines) do
    tip:AddDoubleLine(l[1], l[2], NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b,
      HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
  end
end

if (K.HAS_TOOLTIP_DATA) then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, item_tooltip)
else
  GameTooltip:HookScript("OnTooltipSetItem", item_tooltip)
  ItemRefTooltip:HookScript("OnTooltipSetItem", item_tooltip)
end

--
-- True, having told POL why, when NAME is too short to be a config or roll list name. Every place the player types one of
-- those asks this, so the rule and its wording live here rather than at six call sites. See konfer.MIN_NAME_LEN for why
-- there is a minimum at all, and note that nothing checks a name that arrived from another admin.
--
function konfer:NameTooShort(pol, name)
  if (name and strlen(name) >= self.MIN_NAME_LEN) then
    return false
  end

  pol:err(L["a name must be at least %d characters long. Please try again."], self.MIN_NAME_LEN)
  return true
end

--
-- Whether NAME holds rank over this client. Either they hold a guild rank that can read officer chat, which is as close to
-- "is an officer" as the client will tell us, or we are grouped with them and they are the one running the group.
--
-- One rule and one place, because everything an outsider may make us do is gated on the same question. Pushing a
-- configuration at us and making us answer a character info check are both somebody outside this client deciding it should
-- act, and neither is a heavier thing to ask than the other.
--
-- is_rl is not asked after. A raid leader is given is_aorl as well, so is_pl and is_aorl between them cover every way of
-- running a group. A plain party has no assistants and its leader is is_pl alone.
--
-- Both are answered from what the client already knows, so this reads nothing from the config and cannot be out of date.
--
function konfer:IsElevated(name)
  if (K.UserIsRanked(name)) then
    return true
  end

  if (KRP.in_party and KRP.players and KRP.players[name]) then
    local p = KRP.players[name]

    if (p.is_aorl or p.is_pl) then
      return true
    end
  end

  return false
end

--
-- If we use alt tethering, and the alt is in the raid, we need to store the UID of the alt's main, else they will not be moved.
--
-- Raid presence itself (konfer.raid.uidmap) is only ever built for the active policy's current config, the uid to name map
-- being derived from that config's user list. So asking this of some other config gives you that config's list order and
-- its reserved users, with raid membership still coming from the current one. Every caller asks it of the current one.
--
function cfgm:CreateRaidList(listid)
  local raiders = {}
  local ll = self.lists[listid]
  -- With no raid there is nobody in it, only the reserved.
  local inraid = konfer.raid.uidmap or {}
  for k,v in ipairs(ll.users) do
    if (self:IsReserved(v)) then
      tinsert(raiders, v)
    elseif (inraid[v]) then
      tinsert(raiders, v)
    elseif (ll.tethered) then
      for ak,av in ipairs(self:UserAlts(v) or {}) do
        if (inraid[av]) then
          tinsert(raiders, v)
          break
        end
      end
    end
  end
  return raiders
end

function konfer:SplitRaidList(raidlist)
  local raiders = {}

  --
  -- Every caller but one is handing this a field off the wire, so a field that is not a string at all leaves as an empty
  -- list rather than as an error raised inside the comms callback.
  --
  if (type(raidlist) ~= "string") then
    return raiders
  end

  -- The bound stops three short of the end, so a payload that is not a multiple of four ends at the last whole uid.
  for i = 1, strlen(raidlist) - 3, 4 do
    tinsert(raiders, strsub(raidlist, i, i + 3))
  end

  return raiders
end

--
-- How winning an item moves a member is the policy's, and for Suicide Kings it lives in Policies/SK.lua behind the
-- descriptor's Award and UndoAward. What stays here is what every policy needs whatever it does with the answer: working out
-- who was actually in the raid, and recording the change.
--

local function get_event_id(cfg)
  local base = tonumber(date("!%y%m%d%H%M", K.time()) .. "0000")

  cfg.lastevent = max(base, cfg.lastevent or 0) + 1

  return cfg.lastevent
end

--
-- This function is the central processing point for adding an event. Adding events happens when an admin makes a change that
-- results in the running CRC changing and is shared with all admins. This is where the event string is computed. The code in
-- Comms.lua is used to process the events on receipt, and is the code that breaks apart the event string and processes it.
--
local function lowlevel_add_event(cfg, eventname, userevent, ...)
  -- Only an admin's changes are events. Anybody else's copy of a config is theirs to look at, and nothing they do to it goes anywhere.
  if (not cfg:MyStatus()) then
    return
  end

  local _, myadm = cfg:IsAdmin(cfg:MyUid())

  local serialised = LS:Serialize(...)
  assert(serialised)
  local encoded = ZL:EncodeForWoWAddonChannel(serialised)
  assert(encoded)

  --
  -- Each event changes the config checksum. Since we are using XOR to change this running checksum, the exact order doesn't
  -- matter, as a user could sync with other admins in any random order, but as long as any two admins have both processed
  -- the exact same set of events, their shecksum will be the same.
  --
  -- The event is broadcast to the current raid and those admins that are currently online and fully synced with us will
  -- process the event immediately. If an admin is not online, or hasn't synced with us, then we simply queue the event for
  -- that admin.
  --
  local crc = H:CRC32(encoded)
  local oldsum = cfg.cksum
  local newsum = bxor(oldsum, crc)
  local oldeid = cfg.lastevent
  local eid = get_event_id(cfg)
  local scrc, ocrc = K.hexstr(crc), K.hexstr(oldsum)

  cfg.cksum = newsum

  if (konfer.qf and konfer.qf.synctopbar) then
    konfer.qf.synctopbar:SetCurrentCRC()
  end

  if (cfg.syncing) then
    for k,v in pairs(cfg.admins) do
      if (k ~= myadm) then
        if (not v.sync) then
          v.sync = {}
        end
        tinsert(v.sync, { eventname, eid, crc, encoded })
      end
    end
  end

  --
  -- The six values in front of the event's own arguments. policy_commdispatch in Comms.lua takes them off again and is
  -- where they are described; this is the only thing that writes them, and the order has to match there.
  --
  cfg:GetPolicy():CSendAM(cfg.id, eventname, "ALERT", scrc, ocrc, eid, oldeid, userevent or false, encoded)
end

--
-- cfg:AddEvent(eventname, ...)
-- cfg:AdminEvent(eventname, ...)
--
-- The variadic portion is first serialised with LibSerialise, and then encoded for WoW. This is the portion that is CRCed -
-- the encoded, serialised portion. We do not compress any part of the payload as the low level transmit funmction in Kore
-- will do that for us for all traffic. USEREVENT must be set to true if this event is intended for normal, non-admin users
-- to process as well, for example when a loot box is opened or a new item is being rolled for etc.
--
function cfgm:AdminEvent(eventname, ...)
  lowlevel_add_event(self, eventname, false, ...)
end

function cfgm:AddEvent(eventname, ...)
  lowlevel_add_event(self, eventname, true, ...)
end

--
-- Bring the stored variables up to konfer.dbversion, converting through each intermediate format in turn. Returns true if
-- anything was actually changed. Once a database has been upgraded it cannot be reverted.
--
-- There is only one database format today, so there is nothing to convert and this always returns false. When that changes,
-- bump konfer.dbversion in Konfer.lua and add a block here for each step, in ascending order. A version 2 would look like this:
--
--   if (self.frdb.dbversion < 2) then
--     -- Whatever a version 1 database lacks that a version 2 one has. Give
--     -- every new field its default rather than leaving it nil: the rest of
--     -- the mod is written against the current shape only.
--     for kp, pol in pairs(self.policies) do
--       for k,v in pairs(self:PolicyConfigs(pol)) do
--         v.settings.some_new_option = false
--       end
--     end
--     ret = true
--   end
--
-- Note the "<" rather than "==". Once there is a chain of these, a version 1 database has to fall through every block up to
-- the current version, not just the first one, so each block must run for every database older than the version it produces.
--
function konfer:UpdateDatabaseVersion()
  local ret = false

  --
  -- A database created by this version of the mod is stamped with the current version when it is created, so a missing
  -- dbversion means a database that predates the field entirely. There is nothing to convert it from, so just stamp it and leave it alone.
  --
  if (not self.frdb.dbversion) then
    self.frdb.dbversion = self.dbversion
    return ret
  end

  self.frdb.dbversion = self.dbversion
  return ret
end

--
-- Whether SENDER runs the loot of the group we are currently in: its master looter, or without master loot the leader
-- collecting it (konfer:LootRunner). Only they may drive loot distribution, so every comms handler that acts on a
-- distribution message checks this first.
--
function konfer:IsSenderMasterLooter(sender)
  local runner = KRP.in_party and self:LootRunner()

  return (runner and runner == sender) and true or false
end
