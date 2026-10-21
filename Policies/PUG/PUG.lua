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
local KU = K.Users

local tinsert = table.insert
local tsort = table.sort
local strlower = string.lower

local tally = konfer.tally

--
-- The pickup raid tool.
--
-- Loot in a pickup raid is rolled for, never bid on, and what carries from one item to the next is who has already won
-- tonight, which softens their next roll (the tally, Tally.lua). What carries from one night to the next is the people
-- themselves: who is worth grouping with again and who is not, and what each plays.
--
-- Its window is laid out after the original KonferPUG's: Raid, first, everybody in the group and what tonight has cost each;
-- Loot, with the corpse and the rolls, and its History; the people, KonferPUG's Raiders; and Config, whose Admin tab has
-- PUG's own options down the whole of its right hand column. Every roll is on the config's one list, which nobody sees, so
-- the Lists page has nothing to do, and a night needs no co-admins, so neither has Sync.
--
local pug = {
  handle = "pug",
  name = L["POLICY_PUG_NAME"],
  nickname = L["POLICY_PUG_NICK"],
  shortnick = L["POLICY_PUG_SHORTNICK"],
  desc = L["POLICY_PUG_DESC"],
  splashwords = L["POLICY_PUG_SPLASH"],
  command = "kpug",
  order = 5,
  accent = KUI.COLOR_AMBER,

  --
  -- The one policy usable in a battleground, and not for loot: there is no master looter in one and the loot is the
  -- battleground itself. What PUG brings there is its knowledge of people. Its user list is load bearing in a way the
  -- others' are not -- who is worth grouping with again and who is not, and what role each plays -- and that matters most among strangers.
  --
  bg = true,

  -- A pickup raid has no guild to talk over, so every PUG config syncs over the raid.
  channel = konfer.CHANNEL_OTHER,

  -- Everybody a PUG config knows rolls on its one list, which nobody ever sees.
  onelist = true,

  -- A pickup raid rolls rather than bids, so the config's kind order, main spec over off spec and so on, ranks its rolls.
  rollorder = true,

  -- A new config takes every kind of roll, main spec over off spec and off spec over transmog, with transmog and vanity level.
  configdefaults = {
    offspec_rolls = true,
    transmog_rolls = true,
    vanity_rolls = true,
    main_over_offspec = true,
    offspec_over_transmog = true,
    transmog_over_vanity = false,
  },

  --
  -- The item quality below which an item is not offered at all, rare unless told otherwise, edited on the platform's Loot tab,
  -- and whether a soft reserve keeps everybody else out of a roll (Reserves.lua), edited on the Admin tab under the tally's
  -- own, which Tally.lua adds.
  --
  defaults = {
    bid_threshold = 3,
    reserves_only = true,
  },

  -- "!sr", what a raider reserved, answered in Reserves.lua.
  Whispers = {
    reserves = { L["WHISPERCMD_RESERVES"], "sr" },
  },

  hidepages = { lists = true },

  --
  -- A pickup raid is not a guild, so Assign loot has no guild rank to filter a roll by, and the item editor none for a roll to
  -- start filtered to. Every roll is on the config's one list, so Assign loot has no Lists panel and the item editor no list to
  -- roll on or to award on, and PUG never bids, so there is no Force bid or Force retract under Candidates.
  --
  AssignPage = {
    hide = { rank = true, lists = true, forcebid = true, bids = true },
  },

  ItemsPage = {
    hide = { rank = true, list = true, awardlist = true },
  },

  -- Nor has the Admin tab Options, its default list, guild rank filtering and rank order, so PUG has the whole right column.
  AdminPage = {
    hide = { options = true },
  },

  --
  -- PUG never bids, so the Loot tab has no Bid options, and Roll options says what becomes of an item nobody rolls for. Nor
  -- does a pickup raid announce its loot or its winners to the master looter's guild, or list raiders missing from a list
  -- nobody sees.
  --
  ConfigLootPage = {
    hide = { bids = true, announce_guild = true, ann_winners_guild = true, ann_missing = true },
  },

  --
  -- Asking where you stand is asking what tonight has cost you, a roll having no standing. A broadcast takes the raid
  -- tonight's reserves and everybody's counts, and somebody taken out of the raid loses theirs.
  --
  Strings = {
    HELP_STANDING = L["TALLY_HELP_STANDING"],
    RAID_BROADCAST = L["TIP_PUG_BROADCAST"],
    RAID_REMOVE = L["TALLY_REMOVE"],
  },

  StandingFields = {},
}

--
-- The tally, with the reserves standing ahead of the +1s in any roll (pug:ReserveStanding in Reserves.lua) and the Raid page
-- kept up out of a group, its Reserves tab being where tonight's reserves are imported before the raid forms.
--
tally:Setup(pug, {
  tag = "PUG",
  events = { pen = "PGPEN", del = "PGDEL", grp = "PGGRP", fin = "PGEND" },
  priority = function(cfg, uid, ilink)
    return pug:ReserveStanding(cfg, uid, ilink)
  end,
  solo = true,
})

--
-- The people are what PUG is for, so its section on the Users page is the player's own notes on whoever is selected, the
-- ratings and the note Kore's user editor shows (KU:CreateUserNotes), and the same notes as there. Nothing in it is the
-- config's: each is saved as it is chosen or typed and never leaves the machine, so the section never says anything changed.
-- The note is NOTE_LINES tall and the section ends at its foot. The page is compact, giving the section the room for them.
--
local NOTE_LINES = 5

--
-- The Admin tab's right hand column, all of it PUG's, Options being every other policy's: the tally's options for the config
-- the tab has selected (Tally.lua), and last whether a soft reserve keeps everybody else out of a roll, which means
-- something in every kind of raid. It answers how tall they are, so the panel is only as big as it needs to be.
--
pug.CreateConfigUI = function(self, parent)
  local ypos = tally:ConfigUI(self, parent, 0, tally:LabelWidth())
  local ui = self.cfgui

  ui.resonly = KUI:CreateCheckBox({
    x = 0, y = ypos, label = { text = L["Soft reserves stop others rolling"] },
    tooltip = { title = "$$", text = L["TIP_PUG_RESONLY"] },
  }, parent)
  ui.resonly:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and ui.cfgid) then
      konfer:AdminPending():Set("p.reserves_only", val and true or false)
    end
  end)
  konfer:AdminPending():Watch(ui.resonly, "p.reserves_only")

  ui.extra = function(on)
    ui.resonly:SetEnabled(on)
  end

  return ui.resonly:GetHeight() - ypos
end

pug.RefreshConfigUI = function(self, cfgid)
  if (not tally:RefreshConfigUI(self, cfgid)) then
    return
  end

  self.cfgui.resonly:SetChecked(konfer:AdminPending():Value("p.reserves_only"), true)
  self.cfgui.sync()
end

pug.EnableConfigUI = function(self, onoff, cfgid)
  tally:EnableConfigUI(self, onoff, cfgid)
end

--
-- A roll is decided by the dice, so nobody stands anywhere: the candidates for an item, and whoever else is drawn from the
-- one list, go by name, and no standing is shown beside them.
--
pug.standingwidth = 0

pug.PositionText = function(self, cfgid, listid, uid, idx)
  return ""
end

pug.Order = function(self, cfgid, listid, uids)
  local cfg = konfer:PolicyConfig(pug, cfgid)
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

pug.UsersPage = {
  title = KU.NOTES_TITLE,
  compact = true,

  Construct = function(client, changed, width)
    client.notes = KU:CreateUserNotes({ prefix = "KonferPUGUsers", lines = NOTE_LINES, width = width }, client)

    return client.notes.minheight
  end,

  UserSelection = function(client, cfgid, uid, pdata)
    local cfg = konfer:PolicyConfig(pug, cfgid)
    local ent = uid and cfg and cfg.uids[uid]
    local kuid = ent and ent[konfer.CFGUSER_KUID]

    client.notes:SetUser(kuid)
    client.notes:SetEnabled(kuid ~= nil)
  end,
}

--
-- Somebody the player has rated a terrible tank made the main tank is warned of, to the player alone, their ratings being
-- their own. A rating for anything else says nothing about tanking, and the main assist has none to check.
--
function pug:StatusChanged(name, status, onoff)
  local kuid = onoff and status == KRP.STATUS_MT and name ~= K.player.name and konfer:IsUsableHere(self) and KU:Find(name)

  if (kuid and KU:Rating(kuid, KU.RATE_TANK) == KU.RATING_TERRIBLE) then
    self:warn(L["PUG_TERRIBLE_TANK"], K.DisplayName(name))
  end
end

-- Tonight's reserves, after Raiders (Reserves.lua).
pug.RaidTabs = {}

-- Words of PUG's own after /kpug, beside the platform's. The development copy has testreserves (Reserves.lua).
pug.Commands = {}

--
-- PUG's art is its cell in each of Konfer's strips. The plaque on its card reads /kpug, so it has one only while that is the command.
--
pug.TitleCard = konfer:PolicyArt("PolicyLogos", pug.order)
pug.Icon = konfer:PolicyArt("PolicyIcons", pug.order)
pug.CommandPlate = (pug.command == "kpug") and konfer:PolicyArt("PolicyCommands", pug.order) or nil

--
-- The foyer's Overview under PUG's description. The platform would draw the config's lists, and PUG's one list is nobody's
-- to see, so it draws nothing and the description says all there is.
--
function pug:PopulateBannerInfo(cfgid)
end

konfer:RegisterPolicy(pug)
tally:Events(pug)
